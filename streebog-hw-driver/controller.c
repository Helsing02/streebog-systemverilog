#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <errno.h>
#include <getopt.h>
#include <pthread.h>
#include <sched.h>

#include "regs.h"
// #include "stribog.h"

// Конфигурация XDMA устройств
#define H2C_DEV "/dev/xdma0_h2c_0"
#define C2H_DEV "/dev/xdma0_c2h_0"
#define USER_DEV "/dev/xdma0_user"
#define CONTROL_DEV "/dev/xdma0_control"

#define INTER_TEST_DELAY_US 1000


// Структуры для конфигурации
typedef struct {
    int device_mode;            // 0=256-bit, 1=512-bit (режим устройства)
    size_t block_count;         // количество 64-байтовых блоков за операцию
    int cpu_core;               // привязка к ядру
    int use_realtime;           // реальное время
    int verbose;                // подробный вывод
} common_config_t;

typedef struct {
    common_config_t common;
    int validate;               // проверка результатов
} test_config_t;

typedef struct {
    common_config_t common;
    // Нет дополнительных параметров для interactive mode
} interactive_config_t;

typedef struct {
    common_config_t common;
    size_t min_size;            // минимальный размер данных
    size_t max_size;            // максимальный размер данных
    size_t step_size;           // шаг размера
    int iterations;             // количество итераций
    int warmup_iterations;      // прогрев
    char *output_file;          // файл для результатов
} bench_config_t;

typedef struct {
    common_config_t common;
    size_t min_size;            // минимальный размер данных
    size_t max_size;            // максимальный размер данных
    int iterations;             // количество итераций
} compare_config_t;

typedef struct {
    uint32_t *h2c_buf;
    uint32_t *c2h_buf;
    size_t buffer_size;
} dma_buffers_t;

typedef struct {
    size_t data_size;
    double min_time_ns;
    double max_time_ns;
    double avg_time_ns;
    double median_time_ns;
    double throughput_mbs;
} benchmark_result_t;

typedef struct {
    int total_tests;
    int passed_tests;
    int failed_tests;
    double min_time_ns;
    double max_time_ns;
    double avg_time_ns;
} comparison_results_t;

typedef struct {
    int fd_h2c;
    int fd_c2h;
    int fd_user;
    volatile uint32_t *regmap;
    size_t block_count;
} xdma_handle_t;

int xdma_open(xdma_handle_t *handle, size_t block_count) {
    handle->fd_h2c = open(H2C_DEV, O_WRONLY);
    handle->fd_c2h = open(C2H_DEV, O_RDONLY);
    handle->fd_user = open(USER_DEV, O_RDWR | O_SYNC);
    handle->block_count = block_count;

    if (handle->fd_h2c < 0 || handle->fd_c2h < 0 || handle->fd_user < 0) {
        perror("open XDMA devices");
        goto error;
    }

    handle->regmap = (volatile uint32_t *)mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
                                              MAP_SHARED, handle->fd_user, CSR_BASE_ADDR);
    if (handle->regmap == MAP_FAILED) {
        perror("mmap");
        goto error;
    }

    return 0;

error:
    if (handle->fd_h2c >= 0) close(handle->fd_h2c);
    if (handle->fd_c2h >= 0) close(handle->fd_c2h);
    if (handle->fd_user >= 0) close(handle->fd_user);
    return -1;
}

void xdma_close(xdma_handle_t *handle) {
    if (handle->regmap != MAP_FAILED && handle->regmap != NULL) {
        munmap((void *)handle->regmap, 0x1000);
    }
    if (handle->fd_h2c >= 0) close(handle->fd_h2c);
    if (handle->fd_c2h >= 0) close(handle->fd_c2h);
    if (handle->fd_user >= 0) close(handle->fd_user);

    handle->fd_h2c = -1;
    handle->fd_c2h = -1;
    handle->fd_user = -1;
    handle->regmap = NULL;
}

int get_hash_size(int mode) {
    return mode == 0 ? 32 : 64;
}

static ssize_t write_blocks(int fd, const void *buf, size_t count, size_t block_count, volatile uint32_t *regmap, int mode) {
    regmap[CSR_MODE_ADDR / 4] = mode;

    if (block_count == 0) {
        // Если block_count не задан, используем стандартную запись
        regmap[CSR_TOTAL_NUM_TRANS_ADDR / 4] = 1;
        return write(fd, buf, count);
    }

    const size_t block_size = 64;
    const size_t max_write_size = block_count * block_size;
    const uint8_t *data = (const uint8_t*)buf;
    size_t total_written = 0;
    ssize_t written;

    regmap[CSR_TOTAL_NUM_TRANS_ADDR / 4] = (count + max_write_size - 1) / max_write_size;
    while (count > 0) {
        size_t to_write = (count > max_write_size) ? max_write_size : count;
        written = write(fd, data, to_write);

        if (written < 0) {
            return written; // Ошибка
        }

        total_written += written;
        data += written;
        count -= written;

        if ((size_t)written < to_write) {
            break; // Записали меньше, чем планировали
        }
    }

    return total_written;
}

// Универсальная функция для выполнения операции о вычислению хеша
int xdma_hash_calc(xdma_handle_t *handle, const void *input_data, size_t input_size,
                          void *output_hash, int mode) {
    size_t hash_size = get_hash_size(mode);

    // Записываем данные
    ssize_t written = write_blocks(handle->fd_h2c, input_data, input_size,
                                   handle->block_count, handle->regmap, mode);
    if (written != input_size) {
        fprintf(stderr, "Write error: %zd/%zu bytes\n", written, input_size);
        return -1;
    }

    // Читаем результат
    ssize_t read_bytes = read(handle->fd_c2h, output_hash, hash_size);
    if (read_bytes != hash_size) {
        fprintf(stderr, "Read error: %zd/%zu bytes\n", read_bytes, hash_size);
        return -1;
    }

    return 0;
}

// Тестовые векторы
typedef struct {
    const char *name;
    const uint8_t *input;
    size_t input_len;
    const uint8_t *expected_hash_32;
    const uint8_t *expected_hash_64;
} test_vector_t;

// Тестовые векторы
static test_vector_t test_vectors[] = {
    {
        .name = "GOST A1 example",
        .input = (uint8_t*)"012345678901234567890123456789012345678901234567890123456789012",
        .input_len = 63,
        .expected_hash_32 = (uint8_t*)"\x9d\x15\x1e\xef\xd8\x59\x0b\x89\xda\xa6\xba\x6c\xb7\x4a\xf9\x27\x5d\xd0\x51\x02\x6b\xb1\x49\xa4\x52\xfd\x84\xe5\xe5\x7b\x55\x00",
        .expected_hash_64 = (uint8_t*)"\x1b\x54\xd0\x1a\x4a\xf5\xb9\xd5\xcc\x3d\x86\xd6\x8d\x28\x54\x62\xb1\x9a\xbc\x24\x75\x22\x2f\x35\xc0\x85\x12\x2b\xe4\xba\x1f\xfa"
                                      "\x00\xad\x30\xf8\x76\x7b\x3a\x82\x38\x4c\x65\x74\xf0\x24\xc3\x11\xe2\xa4\x81\x33\x2b\x08\xef\x7f\x41\x79\x78\x91\xc1\x64\x6f\x48",
    },
    {
        .name = "GOST A2 example",
        .input = (uint8_t*)"\xd1\xe5\x20\xe2\xe5\xf2\xf0\xe8\x2c\x20\xd1\xf2\xf0\xe8\xe1\xee\xe6\xe8\x20\xe2\xed\xf3\xf6\xe8\x2c\x20\xe2\xe5\xfe\xf2\xfa\x20"
                           "\xf1\x20\xec\xee\xf0\xff\x20\xf1\xf2\xf0\xe5\xeb\xe0\xec\xe8\x20\xed\xe0\x20\xf5\xf0\xe0\xe1\xf0\xfb\xff\x20\xef\xeb\xfa\xea\xfb"
                           "\x20\xc8\xe3\xee\xf0\xe5\xe2\xfb",
        .input_len = 72,
        .expected_hash_32 = (uint8_t*)"\x9d\xd2\xfe\x4e\x90\x40\x9e\x5d\xa8\x7f\x53\x97\x6d\x74\x05\xb0\xc0\xca\xc6\x28\xfc\x66\x9a\x74\x1d\x50\x06\x3c\x55\x7e\x8f\x50",
        .expected_hash_64 = (uint8_t*)"\x1e\x88\xe6\x22\x26\xbf\xca\x6f\x99\x94\xf1\xf2\xd5\x15\x69\xe0\xda\xf8\x47\x5a\x3b\x0f\xe6\x1a\x53\x00\xee\xe4\x6d\x96\x13\x76"
                                      "\x03\x5f\xe8\x35\x49\xad\xa2\xb8\x62\x0f\xcd\x7c\x49\x6c\xe5\xb3\x3f\x0c\xb9\xdd\xdc\x2b\x64\x60\x14\x3b\x03\xda\xba\xc9\xfb\x28",
    },
    {0} // терминатор
};

// Вспомогательные функции (прототипы)
int bind_to_cpu(int cpu_core);
uint64_t get_nanoseconds(void);
double calculate_median(double *times, int n);
int init_dma_buffers(dma_buffers_t *bufs, size_t size);
void cleanup_dma_buffers(dma_buffers_t *bufs);
void print_results(const benchmark_result_t *results, int count);
int save_results_csv(const benchmark_result_t *results, int count, const char *filename);

// Реализация функций режимов
int run_test_mode(test_config_t *config) {
    printf("\n=== TEST MODE ===\n");

    dma_buffers_t bufs = {0};
    xdma_handle_t device = {0};
    int result = 1;

    if (init_dma_buffers(&bufs, 8192) != 0) {
        fprintf(stderr, "Failed to initialize DMA buffers\n");
        return 1;
    }

    if (xdma_open(&device, config->common.block_count) != 0) {
        cleanup_dma_buffers(&bufs);
        return 1;
    }

    // Определяем какие режимы тестировать
    int modes_to_test[2];
    int mode_count = 0;

    if (config->common.device_mode == -1) {
        // Тестируем оба режима
        modes_to_test[0] = 0;
        modes_to_test[1] = 1;
        mode_count = 2;
        printf("Testing both modes: 256-bit and 512-bit\n");
    } else {
        // Тестируем только указанный режим
        modes_to_test[0] = config->common.device_mode;
        mode_count = 1;
        printf("Testing %d-bit mode only\n", get_hash_size(config->common.device_mode) * 8);
    }

    int total_passed = 0, total_tests = 0;

    for (int mode_idx = 0; mode_idx < mode_count; mode_idx++) {
        int current_mode = modes_to_test[mode_idx];
        int hash_size = get_hash_size(current_mode);
        const uint8_t *expected_hash;

        if (mode_count > 1) {
            printf("\n--- %d-bit Mode Tests ---\n", get_hash_size(current_mode));
        }

        int mode_passed = 0, mode_tests = 0;

        for (int i = 0; test_vectors[i].name != NULL; i++) {
            test_vector_t *vec = &test_vectors[i];

            // Выбираем правильный ожидаемый хеш в зависимости от режима
            if (current_mode == 0) {
                expected_hash = vec->expected_hash_32;
            } else {
                expected_hash = vec->expected_hash_64;
            }

            // Проверяем, что ожидаемый хеш не NULL
            if (expected_hash == NULL) {
                printf("Test %d: %s...SKIP (no expected hash for this mode)\n",
                       mode_tests + 1, vec->name);
                continue;
            }

            printf("Test %d: %s...", mode_tests + 1, vec->name);
            fflush(stdout);

            // Запись данных в FPGA и чтение результата
            memcpy(bufs.h2c_buf, vec->input, vec->input_len);
            if (xdma_hash_calc(&device, bufs.h2c_buf, vec->input_len,
                               bufs.c2h_buf, current_mode) != 0) {
                printf("FAIL (hash calc operation failed)\n");
                mode_tests++;
                continue;
            }

            // Проверка результата
            if (config->validate && memcmp(bufs.c2h_buf, expected_hash, hash_size) != 0) {
                printf("FAIL (hash mismatch)\n");
                if (config->common.verbose) {
                    printf("  Expected: ");
                    for (size_t j = 0; j < hash_size; j++) printf("%02x", expected_hash[j]);
                    printf("\n  Got:      ");
                    for (size_t j = 0; j < hash_size; j++) printf("%02x", ((uint8_t*)bufs.c2h_buf)[j]);
                    printf("\n");
                }
            } else {
                printf("PASS\n");
                mode_passed++;
            }
            mode_tests++;
            usleep(INTER_TEST_DELAY_US);
        }

        printf("%d-bit Mode Results: %d/%d tests passed\n",
               get_hash_size(current_mode), mode_passed, mode_tests);

        total_passed += mode_passed;
        total_tests += mode_tests;
    }

    printf("\n=== OVERALL RESULTS ===\n");
    printf("Total: %d/%d tests passed\n", total_passed, total_tests);

    result = (total_passed == total_tests) ? 0 : 1;

cleanup:
    xdma_close(&device);
    cleanup_dma_buffers(&bufs);
    return result;
}

int run_compare_mode(const compare_config_t *config) {
    printf("\n=== COMPARISON MODE (FPGA vs Software) ===\n");

    dma_buffers_t bufs = {0};
    xdma_handle_t device = {0};
    int result = 1;

    size_t max_buffer_size = config->max_size;
    if (init_dma_buffers(&bufs, max_buffer_size) != 0) {
        fprintf(stderr, "Failed to initialize DMA buffers\n");
        return 1;
    }

    if (xdma_open(&device, config->common.block_count) != 0) {
        cleanup_dma_buffers(&bufs);
        return 1;
    }

    comparison_results_t results = {0};
    double total_time = 0.0;

    int use_random_mode = (config->common.device_mode == -1);

    if (use_random_mode) {
        printf("Mode: Random (256-bit or 512-bit) for each iteration\n");
    } else {
        printf("Mode: Fixed %d-bit\n", get_hash_size(config->common.device_mode) * 8);
    }
    printf("Iterations: %d, Data size range: %zu-%zu bytes\n\n",
           config->iterations, config->min_size, config->max_size);

    srand(time(NULL));

    for (int i = 0; i < config->iterations; i++) {
        // Выбор режима для этой итерации
        int current_mode;
        if (use_random_mode) {
            current_mode = rand() & 0x1; // 0 или 1
        } else {
            current_mode = config->common.device_mode;
        }

        size_t hash_size = get_hash_size(current_mode);

        size_t data_size;
        if (config->min_size == config->max_size) {
            data_size = config->min_size;
        } else {
            data_size = config->min_size + rand() % (config->max_size - config->min_size + 1);
        }

        // Генерация случайных данных
        for (size_t j = 0; j < data_size; j++) {
            ((uint8_t*)bufs.h2c_buf)[j] = rand() & 0xFF;
        }

        // Вычисление хеша на FPGA
        uint64_t start_fpga = get_nanoseconds();

        int fpga_result = xdma_hash_calc(&device, bufs.h2c_buf, data_size,
                                         bufs.c2h_buf, current_mode);
        uint64_t end_fpga = get_nanoseconds();
        double fpga_time = (double)(end_fpga - start_fpga);

        if (fpga_result != 0) {
            printf("Iteration %d: hash calc operation failed\n", i + 1);
            results.failed_tests++;
            results.total_tests++;
            continue;
        }

        // Вычисление хеша программно
        uint64_t start_sw = get_nanoseconds();

        stribog_ctx_t ctx;
        uint8_t sw_hash[64];

        stribog_init(&ctx, (current_mode == 0) ? 256 : 512);
        stribog_update(&ctx, (uint8_t*)bufs.h2c_buf, data_size);
        stribog_final(&ctx, sw_hash);

        uint64_t end_sw = get_nanoseconds();
        double sw_time = (double)(end_sw - start_sw);

        // Сравнение результатов
        int match = memcmp(bufs.c2h_buf, sw_hash, hash_size) == 0;

        if (match) {
            results.passed_tests++;
            if (config->common.verbose) {
                printf("Iteration %d: PASS (size=%zu, FPGA=%.2fµs, SW=%.2fµs)\n",
                       i + 1, data_size, fpga_time/1000.0, sw_time/1000.0);
            }
        } else {
            printf("Iteration %d: FAIL (size=%zu)\n", i + 1, data_size);
            if (config->common.verbose) {
                printf("  FPGA: ");
                for (size_t j = 0; j < hash_size; j++)
                    printf("%02x", ((uint8_t*)bufs.c2h_buf)[j]);
                printf("\n  SW:   ");
                for (size_t j = 0; j < hash_size; j++)
                    printf("%02x", sw_hash[j]);
                printf("\n");
            }
            results.failed_tests++;
        }

        results.total_tests++;
        total_time += fpga_time;

        if (i == 0 || fpga_time < results.min_time_ns) results.min_time_ns = fpga_time;
        if (fpga_time > results.max_time_ns) results.max_time_ns = fpga_time;
    }

    results.avg_time_ns = total_time / config->iterations;

    // Красивый вывод результатов
    printf("\n" "═" "╡ RESULTS ╞" "═" "═══════════════════════════════\n");
    printf("┌──────────────────────┬─────────────┐\n");
    printf("│ Metric               │ Value       │\n");
    printf("├──────────────────────┼─────────────┤\n");
    printf("│ Total Tests          │ %11d │\n", results.total_tests);
    printf("│ Passed Tests         │ %11d │\n", results.passed_tests);
    printf("│ Failed Tests         │ %11d │\n", results.failed_tests);
    printf("│ Success Rate         │ %10.2f%% │\n",
           (double)results.passed_tests / results.total_tests * 100.0);
    printf("├──────────────────────┼─────────────┤\n");
    printf("│ Min FPGA Time        │ %8.2f µs │\n", results.min_time_ns / 1000.0);
    printf("│ Max FPGA Time        │ %8.2f µs │\n", results.max_time_ns / 1000.0);
    printf("│ Avg FPGA Time        │ %8.2f µs │\n", results.avg_time_ns / 1000.0);
    printf("└──────────────────────┴─────────────┘\n");

    result = (results.failed_tests == 0) ? 0 : 1;

cleanup:
    xdma_close(&device);
    cleanup_dma_buffers(&bufs);
    return result;
}

int run_bench_mode(bench_config_t *config) {
    printf("\n=== BENCHMARK MODE ===\n");

    dma_buffers_t bufs = {0};
    xdma_handle_t device = {0};
    int result = 1;

    if (init_dma_buffers(&bufs, config->max_size) != 0) {
        fprintf(stderr, "Failed to initialize DMA buffers\n");
        return 1;
    }

    if (xdma_open(&device, config->common.block_count) != 0) {
        cleanup_dma_buffers(&bufs);
        return 1;
    }

    int use_random_mode = (config->common.device_mode == -1);

    if (use_random_mode) {
        printf("Mode: Random (256-bit or 512-bit) for each iteration\n");
    } else {
        printf("Mode: Fixed %d-bit\n", get_hash_size(config->common.device_mode) * 8);
    }

    // Подготовка размеров данных
    int num_sizes = 0;
    size_t size = config->min_size;

    while (size <= config->max_size) {
        num_sizes++;
        if (config->step_size > 0) {
            size += config->step_size;
        } else {
            size *= 2;
        }
    }

    benchmark_result_t *results = malloc(num_sizes * sizeof(benchmark_result_t));
    if (!results) {
        fprintf(stderr, "Memory allocation failed for results\n");
        goto cleanup;
    }

    // Прогрев
    printf("Warming up...\n");
    for (int i = 0; i < config->warmup_iterations; i++) {
       xdma_hash_calc(&device, bufs.h2c_buf, 1024, bufs.c2h_buf, config->common.device_mode);
    }

    // Основные измерения
    int result_count = 0;
    size = config->min_size;

    for (int i = 0; i < num_sizes; i++) {
        printf("Testing %9zu bytes...", size);
        fflush(stdout);

        // Генерация тестовых данных (совместимо с софтварным бенчмарком)
        for (size_t j = 0; j < size/sizeof(uint32_t); j++) {
            bufs.h2c_buf[j] = (j * 2654435761UL);
        }

        double *times = malloc(config->iterations * sizeof(double));
        if (!times) {
            fprintf(stderr, "Failed to allocate times array\n");
            break;
        }

        double sum = 0.0, min = 1e20, max = 0.0;

        for (int iter = 0; iter < config->iterations; iter++) {
            // Выбор режима для этой итерации
            int current_mode;
            if (use_random_mode) {
                current_mode = rand() & 0x1; // 0 или 1
            } else {
                current_mode = config->common.device_mode;
            }

            uint64_t start = get_nanoseconds();
            // Запись + чтение = один полный цикл обработки
            xdma_hash_calc(&device, bufs.h2c_buf, size, bufs.c2h_buf, current_mode);
            uint64_t end = get_nanoseconds();

            double time_ns = (double)(end - start);
            times[iter] = time_ns;
            sum += time_ns;

            if (time_ns < min) min = time_ns;
            if (time_ns > max) max = time_ns;
        }

        double avg = sum / config->iterations;
        double median = calculate_median(times, config->iterations);
        double throughput = (size / (1024.0 * 1024.0)) / (avg / 1e9);  // MiB/s

        // Также считаем хешей в секунду
        double hashes_per_second = 1e9 / avg;

        results[result_count] = (benchmark_result_t){
            .data_size = size,
            .min_time_ns = min,
            .max_time_ns = max,
            .avg_time_ns = avg,
            .median_time_ns = median,
            .throughput_mbs = throughput
        };
        result_count++;

        printf(" %.2f MiB/s, %.2f hashes/s\n", throughput, hashes_per_second);

        free(times);

        // Следующий размер
        if (config->step_size > 0) {
            size += config->step_size;
        } else {
            size *= 2;
        }

        if (size < config->min_size) break; // защита от переполнения
    }

    // Вывод результатов
    printf("\n=== FPGA Benchmark Results ===\n");
    print_results(results, result_count);

    if (config->output_file) {
        save_results_csv(results, result_count, config->output_file);
    }

    free(results);

cleanup:
    xdma_close(&device);
    cleanup_dma_buffers(&bufs);
    return result;
}

int run_interactive_mode(interactive_config_t *config) {
    printf("\n=== INTERACTIVE MODE ===\n");
    printf("Enter data in hex format (e.g., '48656c6c6f' for 'Hello')\n");
    printf("Type 'quit' to exit\n\n");

    dma_buffers_t bufs = {0};
    xdma_handle_t device = {0};
    int result = 0;

    if (init_dma_buffers(&bufs, 8192) != 0) {
        fprintf(stderr, "Failed to initialize DMA buffers\n");
        return 1;
    }

    if (xdma_open(&device, config->common.block_count) != 0) {
        cleanup_dma_buffers(&bufs);
        return 1;
    }

    char input[4096];
    while (1) {
        printf("Input (hex): ");
        if (!fgets(input, sizeof(input), stdin)) break;

        if (strncmp(input, "quit", 4) == 0) break;

        // Конвертация hex строки в бинарные данные
        size_t input_len = strlen(input) - 1; // минус newline
        if (input_len % 2 != 0) {
            printf("Error: Hex string must have even length\n");
            continue;
        }

        size_t binary_len = input_len / 2;
        if (binary_len > bufs.buffer_size) {
            printf("Error: Input too large (max %zu bytes)\n", bufs.buffer_size);
            continue;
        }

        // Конвертация hex -> binary
        for (size_t i = 0; i < binary_len; i++) {
            sscanf(&input[i*2], "%2hhx", &((uint8_t*)bufs.h2c_buf)[i]);
        }

         // Выполнение операции
        uint64_t start = get_nanoseconds();
        int op_result = xdma_hash_calc(&device, bufs.h2c_buf, binary_len,
                                        bufs.c2h_buf, config->common.device_mode);
        uint64_t end = get_nanoseconds();

        if (op_result != 0) {
            printf("Error: hash calc operation failed\n");
            continue;
        }

        // Вывод результата
        printf("Hash: ");
        for (int i = 0; i < 64; i++) {
            printf("%02x", ((uint8_t*)bufs.c2h_buf)[i]);
        }
        printf("\nTime: %.2f us\n\n", (end - start) / 1000.0);
    }

cleanup:
    xdma_close(&device);
    cleanup_dma_buffers(&bufs);
    return result;
}

// Вспомогательные функции (реализации)
int bind_to_cpu(int cpu_core) {
#ifdef __linux__
    if (cpu_core >= 0) {
        cpu_set_t cpuset;
        CPU_ZERO(&cpuset);
        CPU_SET(cpu_core, &cpuset);

        if (pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset) == 0) {
            printf("✓ Bound to CPU core %d\n", cpu_core);
            return 0;
        } else {
            perror("pthread_setaffinity_np");
        }
    }
#endif
    return -1;
}

int set_realtime_priority(void) {
#ifdef __linux__
    struct sched_param param = {.sched_priority = 50};

    if (sched_setscheduler(0, SCHED_FIFO, &param) == 0) {
        printf("✓ Set real-time scheduling (SCHED_FIFO, priority=50)\n");
        return 0;
    } else {
        perror("sched_setscheduler");
        return -1;
    }
#endif
    return -1;
}

uint64_t get_nanoseconds(void) {
    struct timespec ts;
#ifdef CLOCK_MONOTONIC_RAW
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
#else
    clock_gettime(CLOCK_MONOTONIC, &ts);
#endif
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

double calculate_median(double *times, int n) {
    if (n == 0) return 0.0;

    double *copy = malloc(n * sizeof(double));
    if (!copy) return 0.0;

    memcpy(copy, times, n * sizeof(double));

    // Простая bubble sort для медианы
    for (int i = 0; i < n-1; i++) {
        for (int j = 0; j < n-i-1; j++) {
            if (copy[j] > copy[j+1]) {
                double temp = copy[j];
                copy[j] = copy[j+1];
                copy[j+1] = temp;
            }
        }
    }

    double median = (n % 2 == 0) ?
        (copy[n/2 - 1] + copy[n/2]) / 2.0 :
        copy[n/2];

    free(copy);
    return median;
}

int init_dma_buffers(dma_buffers_t *bufs, size_t size) {
    // Выровненные буферы для DMA
    if (size == 0) return -1;

    if (posix_memalign((void**)&bufs->h2c_buf, 4096, size) != 0) {
        perror("posix_memalign h2c_buf");
        return -1;
    }

    if (posix_memalign((void**)&bufs->c2h_buf, 4096, size) != 0) {
        perror("posix_memalign c2h_buf");
        free(bufs->h2c_buf);
        return -1;
    }

    bufs->buffer_size = size;
    memset(bufs->h2c_buf, 0, size);
    memset(bufs->c2h_buf, 0, size);

    return 0;
}

void cleanup_dma_buffers(dma_buffers_t *bufs) {
    if (bufs->h2c_buf) free(bufs->h2c_buf);
    if (bufs->c2h_buf) free(bufs->c2h_buf);
    bufs->h2c_buf = NULL;
    bufs->c2h_buf = NULL;
    bufs->buffer_size = 0;
}

// Функции парсинга аргументов для каждой подкоманды
void print_test_usage(const char *program_name) {
    printf("Usage: %s test [OPTIONS]\n\n", program_name);
    printf("Run predefined test vectors for Stribog hash algorithm\n\n");
    printf("Options:\n");
    printf("  -d, --device-mode MODE   0=256-bit hash, 1=512-bit hash (default: 1)\n");
    printf("  -b, --block-count N      Number of 64-byte blocks per write (default: 0)\n");
    printf("  -c, --cpu CORE           Bind to CPU core\n");
    printf("  -r, --realtime           Use real-time scheduling\n");
    printf("  -v, --verbose            Verbose output\n");
    printf("  --no-validate            Disable result validation\n");
    printf("  -h, --help               Show this help message\n\n");
}

void print_bench_usage(const char *program_name) {
    printf("Usage: %s bench [OPTIONS]\n\n", program_name);
    printf("Performance benchmarking mode\n\n");
    printf("Options:\n");
    printf("  -d, --device-mode MODE   0=256-bit hash, 1=512-bit hash (default: 1)\n");
    printf("  -b, --block-count N      Number of 64-byte blocks per write (default: 0)\n");
    printf("  -c, --cpu CORE           Bind to CPU core\n");
    printf("  -r, --realtime           Use real-time scheduling\n");
    printf("  -s, --min-size BYTES     Minimum data size (default: 64)\n");
    printf("  -S, --max-size BYTES     Maximum data size (default: 65536)\n");
    printf("  -t, --step-size BYTES    Step size (0=exponential, default: 0)\n");
    printf("  -i, --iterations N       Number of iterations (default: 100)\n");
    printf("  -w, --warmup N           Warmup iterations (default: 10)\n");
    printf("  -o, --output FILE        Output results to CSV file\n");
    printf("  -v, --verbose            Verbose output\n");
    printf("  -h, --help               Show this help message\n\n");
}

void print_interactive_usage(const char *program_name) {
    printf("Usage: %s interactive [OPTIONS]\n\n", program_name);
    printf("Interactive mode for manual testing\n\n");
    printf("Options:\n");
    printf("  -d, --device-mode MODE   0=256-bit hash, 1=512-bit hash (default: 1)\n");
    printf("  -b, --block-count N      Number of 64-byte blocks per write (default: 0)\n");
    printf("  -c, --cpu CORE           Bind to CPU core\n");
    printf("  -r, --realtime           Use real-time scheduling\n");
    printf("  -v, --verbose            Verbose output\n");
    printf("  -h, --help               Show this help message\n\n");
}

void print_compare_usage(const char *program_name) {
    printf("Usage: %s compare [OPTIONS]\n\n", program_name);
    printf("Compare FPGA implementation with software\n\n");
    printf("Options:\n");
    printf("  -d, --device-mode MODE   0=256-bit hash, 1=512-bit hash (default: 1)\n");
    printf("  -b, --block-count N      Number of 64-byte blocks per write (default: 0)\n");
    printf("  -c, --cpu CORE           Bind to CPU core\n");
    printf("  -r, --realtime           Use real-time scheduling\n");
    printf("  -s, --min-size BYTES     Minimum data size (default: 64)\n");
    printf("  -S, --max-size BYTES     Maximum data size (default: 65536)\n");
    printf("  -i, --iterations N       Number of iterations (default: 100)\n");
    printf("  -v, --verbose            Verbose output\n");
    printf("  -h, --help               Show this help message\n\n");
}

void print_general_usage(const char *program_name) {
    printf("Usage: %s <command> [OPTIONS]\n\n", program_name);
    printf("FPGA Stribog Hash Algorithm Test Tool\n\n");
    printf("Commands:\n");
    printf("  test         Run predefined test vectors\n");
    printf("  bench        Performance benchmarking\n");
    printf("  interactive  Interactive mode for manual testing\n");
    printf("  compare      Compare FPGA implementation with software\n");
    printf("\nUse '%s <command> --help' for more information on a specific command.\n", program_name);
}

// Парсинг аргументов для каждой подкоманды
int parse_test_options(int argc, char *argv[], test_config_t *config) {
    static struct option long_options[] = {
        {"device-mode", required_argument, 0, 'd'},
        {"block-count", required_argument, 0, 'b'},
        {"cpu", required_argument, 0, 'c'},
        {"realtime", no_argument, 0, 'r'},
        {"verbose", no_argument, 0, 'v'},
        {"no-validate", no_argument, 0, 0},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:b:c:rvh", long_options, NULL)) != -1) {
        switch (opt) {
            case 'd': config->common.device_mode = atoi(optarg); break;
            case 'b': config->common.block_count = atol(optarg); break;
            case 'c': config->common.cpu_core = atoi(optarg); break;
            case 'r': config->common.use_realtime = 1; break;
            case 'v': config->common.verbose = 1; break;
            case 'h': print_test_usage(argv[0]); exit(0);
            case 0: config->validate = 0; break; // --no-validate
            default: return 1;
        }
    }
    return 0;
}

int parse_bench_options(int argc, char *argv[], bench_config_t *config) {
    static struct option long_options[] = {
        {"device-mode", required_argument, 0, 'd'},
        {"block-count", required_argument, 0, 'b'},
        {"cpu", required_argument, 0, 'c'},
        {"realtime", no_argument, 0, 'r'},
        {"min-size", required_argument, 0, 's'},
        {"max-size", required_argument, 0, 'S'},
        {"step-size", required_argument, 0, 't'},
        {"iterations", required_argument, 0, 'i'},
        {"warmup", required_argument, 0, 'w'},
        {"output", required_argument, 0, 'o'},
        {"verbose", no_argument, 0, 'v'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:b:c:rs:S:t:i:w:o:vh", long_options, NULL)) != -1) {
        switch (opt) {
            case 'd': config->common.device_mode = atoi(optarg); break;
            case 'b': config->common.block_count = atol(optarg); break;
            case 'c': config->common.cpu_core = atoi(optarg); break;
            case 'r': config->common.use_realtime = 1; break;
            case 's': config->min_size = atol(optarg); break;
            case 'S': config->max_size = atol(optarg); break;
            case 't': config->step_size = atol(optarg); break;
            case 'i': config->iterations = atoi(optarg); break;
            case 'w': config->warmup_iterations = atoi(optarg); break;
            case 'o': config->output_file = strdup(optarg); break;
            case 'v': config->common.verbose = 1; break;
            case 'h': print_bench_usage(argv[0]); exit(0);
            default: return 1;
        }
    }
    return 0;
}

int parse_interactive_options(int argc, char *argv[], interactive_config_t *config) {
    static struct option long_options[] = {
        {"device-mode", required_argument, 0, 'd'},
        {"block-count", required_argument, 0, 'b'},
        {"cpu", required_argument, 0, 'c'},
        {"realtime", no_argument, 0, 'r'},
        {"verbose", no_argument, 0, 'v'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:b:c:rvh", long_options, NULL)) != -1) {
        switch (opt) {
            case 'd': config->common.device_mode = atoi(optarg); break;
            case 'b': config->common.block_count = atol(optarg); break;
            case 'c': config->common.cpu_core = atoi(optarg); break;
            case 'r': config->common.use_realtime = 1; break;
            case 'v': config->common.verbose = 1; break;
            case 'h': print_interactive_usage(argv[0]); exit(0);
            default: return 1;
        }
    }
    return 0;
}

int parse_compare_options(int argc, char *argv[], compare_config_t *config) {
    static struct option long_options[] = {
        {"device-mode", required_argument, 0, 'd'},
        {"block-count", required_argument, 0, 'b'},
        {"cpu", required_argument, 0, 'c'},
        {"realtime", no_argument, 0, 'r'},
        {"min-size", required_argument, 0, 's'},
        {"max-size", required_argument, 0, 'S'},
        {"iterations", required_argument, 0, 'i'},
        {"verbose", no_argument, 0, 'v'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:b:c:rs:S:i:vh", long_options, NULL)) != -1) {
        switch (opt) {
            case 'd': config->common.device_mode = atoi(optarg); break;
            case 'b': config->common.block_count = atol(optarg); break;
            case 'c': config->common.cpu_core = atoi(optarg); break;
            case 'r': config->common.use_realtime = 1; break;
            case 's': config->min_size = atol(optarg); break;
            case 'S': config->max_size = atol(optarg); break;
            case 'i': config->iterations = atoi(optarg); break;
            case 'v': config->common.verbose = 1; break;
            case 'h': print_compare_usage(argv[0]); exit(0);
            default: return 1;
        }
    }
    return 0;
}

void print_results(const benchmark_result_t *results, int count) {
    printf("\n%12s %14s %14s %14s %14s %12s\n",
           "Size (bytes)", "Min (ns)", "Max (ns)", "Avg (ns)", "Median (ns)", "Throughput (MB/s)");
    printf("%12s %14s %14s %14s %14s %12s\n",
           "------------", "---------", "---------", "---------", "-----------", "----------------");

    for (int i = 0; i < count; i++) {
        const benchmark_result_t *r = &results[i];
        printf("%12zu %14.2f %14.2f %14.2f %14.2f %12.2f\n",
               r->data_size, r->min_time_ns, r->max_time_ns,
               r->avg_time_ns, r->median_time_ns, r->throughput_mbs);
    }
}

int save_results_csv(const benchmark_result_t *results, int count, const char *filename) {
    FILE *f = fopen(filename, "w");
    if (!f) {
        perror("Failed to open results file");
        return -1;
    }

    fprintf(f, "data_size,min_time_ns,max_time_ns,avg_time_ns,median_time_ns,throughput_mbs\n");

    for (int i = 0; i < count; i++) {
        const benchmark_result_t *r = &results[i];
        fprintf(f, "%zu,%.2f,%.2f,%.2f,%.2f,%.2f\n",
                r->data_size, r->min_time_ns, r->max_time_ns,
                r->avg_time_ns, r->median_time_ns, r->throughput_mbs);
    }

    fclose(f);
    printf("✓ Results saved to %s\n", filename);
    return 0;
}

// Главная функция
int main(int argc, char *argv[]) {
    if (argc < 2) {
        print_general_usage(argv[0]);
        return 1;
    }

    const char *command = argv[1];

    // Общая настройка для всех команд
    common_config_t common_defaults = {
        .device_mode = -1,
        .block_count = 0,
        .cpu_core = -1,
        .use_realtime = 0,
        .verbose = 0
    };

    int result = 0;

    if (strcmp(command, "test") == 0) {
        test_config_t config = {
            .common = common_defaults,
            .validate = 1
        };

        if (parse_test_options(argc - 1, argv + 1, &config) != 0) {
            print_test_usage(argv[0]);
            return 1;
        }

        // Настройка окружения
        if (config.common.use_realtime) {
            bind_to_cpu(config.common.cpu_core >= 0 ? config.common.cpu_core : 0);
            set_realtime_priority();
        } else if (config.common.cpu_core >= 0) {
            bind_to_cpu(config.common.cpu_core);
        }

        result = run_test_mode(&config);

    } else if (strcmp(command, "bench") == 0) {
        bench_config_t config = {
            .common = common_defaults,
            .min_size = 64,
            .max_size = 65536,
            .step_size = 0,
            .iterations = 100,
            .warmup_iterations = 10,
            .output_file = NULL
        };

        if (parse_bench_options(argc - 1, argv + 1, &config) != 0) {
            print_bench_usage(argv[0]);
            return 1;
        }

        if (config.common.use_realtime) {
            bind_to_cpu(config.common.cpu_core >= 0 ? config.common.cpu_core : 0);
            set_realtime_priority();
        } else if (config.common.cpu_core >= 0) {
            bind_to_cpu(config.common.cpu_core);
        }

        result = run_bench_mode(&config);
        if (config.output_file) free(config.output_file);

    } else if (strcmp(command, "interactive") == 0) {
        interactive_config_t config = {
            .common = common_defaults
        };

        if (parse_interactive_options(argc - 1, argv + 1, &config) != 0) {
            print_interactive_usage(argv[0]);
            return 1;
        }

        if (config.common.use_realtime) {
            bind_to_cpu(config.common.cpu_core >= 0 ? config.common.cpu_core : 0);
            set_realtime_priority();
        } else if (config.common.cpu_core >= 0) {
            bind_to_cpu(config.common.cpu_core);
        }

        result = run_interactive_mode(&config);

    } else if (strcmp(command, "compare") == 0) {
        compare_config_t config = {
            .common = common_defaults,
            .min_size = 64,
            .max_size = 65536,
            .iterations = 100
        };

        if (parse_compare_options(argc - 1, argv + 1, &config) != 0) {
            print_compare_usage(argv[0]);
            return 1;
        }

        if (config.common.use_realtime) {
            bind_to_cpu(config.common.cpu_core >= 0 ? config.common.cpu_core : 0);
            set_realtime_priority();
        } else if (config.common.cpu_core >= 0) {
            bind_to_cpu(config.common.cpu_core);
        }

        result = run_compare_mode(&config);

    } else if (strcmp(command, "--help") == 0 || strcmp(command, "-h") == 0) {
        print_general_usage(argv[0]);
        return 0;
    } else {
        fprintf(stderr, "Unknown command: %s\n\n", command);
        print_general_usage(argv[0]);
        return 1;
    }

    return result;
}
