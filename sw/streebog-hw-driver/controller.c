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
#include "../stribog-sw/src/hash/stribog.h"

// XDMA Device Configuration
#define H2C_DEV "/dev/xdma0_h2c_0"      // Host-to-Card DMA channel
#define C2H_DEV "/dev/xdma0_c2h_0"      // Card-to-Host DMA channel
#define USER_DEV "/dev/xdma0_user"      // User logic registers

#define INTER_TEST_DELAY_US 1000        // Delay between tests (microseconds)

// Configuration Structures

// Common configuration shared across all modes
typedef struct {
    int device_mode;            // 0=256-bit, 1=512-bit, -1=random/both
    size_t block_count;         // Number of 64-byte blocks per transaction
    int cpu_core;               // CPU core affinity
    int use_realtime;           // Use real-time scheduling
    int verbose;                // Verbose output flag
} common_config_t;

// Test mode configuration
typedef struct {
    common_config_t common;
    int validate;               // Enable/disable result validation
} test_config_t;

// Interactive mode configuration
typedef struct {
    common_config_t common;
    // No additional parameters needed for interactive mode
} interactive_config_t;

// Benchmark mode configuration
typedef struct {
    common_config_t common;
    size_t min_size;            // Minimum data size for benchmark
    size_t max_size;            // Maximum data size for benchmark
    size_t step_size;           // Step size between measurements (0 = exponential)
    int iterations;             // Number of measurement iterations
    int warmup_iterations;      // Warmup iterations to stabilize performance
    char *output_file;          // CSV output file for results
} bench_config_t;

// Comparison mode configuration (FPGA vs Software)
typedef struct {
    common_config_t common;
    size_t min_size;            // Minimum data size for comparison
    size_t max_size;            // Maximum data size for comparison
    int iterations;             // Number of comparison iterations
} compare_config_t;

// DMA buffer structure for aligned memory allocation
typedef struct {
    uint32_t *h2c_buf;          // Host-to-Card buffer (aligned to 4096 bytes)
    uint32_t *c2h_buf;          // Card-to-Host buffer (aligned to 4096 bytes)
    size_t buffer_size;         // Size of each buffer in bytes
} dma_buffers_t;

// Benchmark results structure
typedef struct {
    size_t data_size;           // Data size in bytes
    double min_time_ns;         // Minimum measured time (nanoseconds)
    double max_time_ns;         // Maximum measured time (nanoseconds)
    double avg_time_ns;         // Average time (nanoseconds)
    double median_time_ns;      // Median time (nanoseconds)
    double throughput_mbs;      // Throughput in MiB/s
} benchmark_result_t;

// Comparison results structure
typedef struct {
    int total_tests;            // Total number of tests performed
    int passed_tests;           // Number of tests that passed
    int failed_tests;           // Number of tests that failed
    double min_time_ns;         // Minimum FPGA execution time
    double max_time_ns;         // Maximum FPGA execution time
    double avg_time_ns;         // Average FPGA execution time
} comparison_results_t;

// XDMA device handle structure
typedef struct {
    int fd_h2c;                 // File descriptor for H2C channel
    int fd_c2h;                 // File descriptor for C2H channel
    int fd_user;                // File descriptor for user logic
    volatile uint32_t *regmap;  // Memory-mapped register space
    size_t block_count;         // Block count for transfers
} xdma_handle_t;

// XDMA Device Management Functions

/**
 * Open XDMA devices and map register space
 *
 * @param handle Pointer to XDMA handle structure
 * @param block_count Number of 64-byte blocks per transfer
 * @return 0 on success, -1 on error
 */
int xdma_open(xdma_handle_t *handle, size_t block_count) {
    handle->fd_h2c = open(H2C_DEV, O_WRONLY);
    handle->fd_c2h = open(C2H_DEV, O_RDONLY);
    handle->fd_user = open(USER_DEV, O_RDWR | O_SYNC);
    handle->block_count = block_count;

    if (handle->fd_h2c < 0 || handle->fd_c2h < 0 || handle->fd_user < 0) {
        perror("Failed to open XDMA devices");
        goto error;
    }

    // Map user logic registers into process memory space
    handle->regmap = (volatile uint32_t *)mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
                                               MAP_SHARED, handle->fd_user, CSR_BASE_ADDR);
    if (handle->regmap == MAP_FAILED) {
        perror("Failed to mmap register space");
        goto error;
    }

    return 0;

error:
    if (handle->fd_h2c >= 0) close(handle->fd_h2c);
    if (handle->fd_c2h >= 0) close(handle->fd_c2h);
    if (handle->fd_user >= 0) close(handle->fd_user);
    return -1;
}

/**
 * Close XDMA devices and unmap register space
 *
 * @param handle Pointer to XDMA handle structure
 */
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

/**
 * Get hash size in bytes based on mode
 *
 * @param mode 0 for 256-bit (32 bytes), 1 for 512-bit (64 bytes)
 * @return Hash size in bytes
 */
int get_hash_size(int mode) {
    if (mode == 0) {
        return 32;  // 256-bit mode
    } else if (mode == 1) {
        return 64;  // 512-bit mode
    } else {
        fprintf(stderr, "Warning: Invalid mode %d, defaulting to 512-bit\n", mode);
        return 64;  // Fallback to 512-bit
    }
}

/**
 * Write data to FPGA with optional block-based transfers
 *
 * @param fd File descriptor for H2C channel
 * @param buf Data buffer to write
 * @param count Total number of bytes to write
 * @param block_count Number of 64-byte blocks per transfer (0 for single write)
 * @param regmap Pointer to memory-mapped registers
 * @param mode Hash mode (0=256-bit, 1=512-bit)
 * @return Number of bytes written, or -1 on error
 */
static ssize_t write_blocks(int fd, const void *buf, size_t count, size_t block_count,
                            volatile uint32_t *regmap, int mode) {
    // Set hash mode in hardware register (must be word-aligned)
    regmap[CSR_MODE_ADDR / 4] = mode;

    if (block_count == 0) {
        // Single write operation
        regmap[CSR_TOTAL_NUM_TRANS_ADDR / 4] = 1;
        return write(fd, buf, count);
    }

    const size_t block_size = 64;
    const size_t max_write_size = block_count * block_size;
    const uint8_t *data = (const uint8_t*)buf;
    size_t total_written = 0;
    ssize_t written;

    // Calculate number of DMA transactions needed
    size_t num_transactions = (count + max_write_size - 1) / max_write_size;
    regmap[CSR_TOTAL_NUM_TRANS_ADDR / 4] = num_transactions;

    while (count > 0) {
        size_t to_write = (count > max_write_size) ? max_write_size : count;
        written = write(fd, data, to_write);

        if (written < 0 || (size_t)written < to_write) {
            perror("write_blocks failed");
            return total_written + written;
        }

        total_written += written;
        data += written;
        count -= written;
    }

    return total_written;
}

/**
 * Perform complete hash calculation on FPGA
 *
 * @param handle XDMA device handle
 * @param input_data Pointer to input data
 * @param input_size Size of input data in bytes
 * @param output_hash Buffer for output hash
 * @param mode Hash mode (0=256-bit, 1=512-bit)
 * @return 0 on success, -1 on error
 */
int xdma_hash_calc(xdma_handle_t *handle, const void *input_data, size_t input_size,
                   void *output_hash, int mode) {
    size_t hash_size = get_hash_size(mode);

    // Write data to FPGA
    ssize_t written = write_blocks(handle->fd_h2c, input_data, input_size,
                                   handle->block_count, handle->regmap, mode);
    if (written != (ssize_t)input_size) {
        fprintf(stderr, "Write error: %zd/%zu bytes\n", written, input_size);
        return -1;
    }

    // Read hash result from FPGA
    ssize_t read_bytes = read(handle->fd_c2h, output_hash, hash_size);
    if (read_bytes != (ssize_t)hash_size) {
        fprintf(stderr, "Read error: %zd/%zu bytes\n", read_bytes, hash_size);
        return -1;
    }

    return 0;
}

// Test Vectors (GOST R 34.11-2012 Standard Examples)

typedef struct {
    const char *name;                   // Test case name
    const uint8_t *input;               // Input test data
    size_t input_len;                   // Input length in bytes
    const uint8_t *expected_hash_32;    // Expected 256-bit hash
    const uint8_t *expected_hash_64;    // Expected 512-bit hash
} test_vector_t;

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
    {0}  // Terminator
};

// Function Prototypes
int bind_to_cpu(int cpu_core);
uint64_t get_nanoseconds(void);
double calculate_median(double *times, int n);
int init_dma_buffers(dma_buffers_t *bufs, size_t size);
void cleanup_dma_buffers(dma_buffers_t *bufs);
void print_results(const benchmark_result_t *results, int count);
int save_results_csv(const benchmark_result_t *results, int count, const char *filename);

// Test Mode Implementation

/**
 * Run test mode: verify FPGA implementation against standard test vectors
 *
 * @param config Test configuration
 * @return 0 if all tests pass, 1 if any test fails
 */
int run_test_mode(test_config_t *config) {
    printf("\n=== TEST MODE (Verification) ===\n");

    dma_buffers_t bufs = {0};
    xdma_handle_t device = {0};
    int result = 1;

    // Initialize DMA buffers (8KB should be enough for test vectors)
    if (init_dma_buffers(&bufs, 8192) != 0) {
        fprintf(stderr, "Failed to initialize DMA buffers\n");
        return 1;
    }

    // Open XDMA devices
    if (xdma_open(&device, config->common.block_count) != 0) {
        cleanup_dma_buffers(&bufs);
        return 1;
    }

    // Determine which modes to test
    int modes_to_test[2];
    int mode_count = 0;

    if (config->common.device_mode == -1) {
        // Test both modes
        modes_to_test[0] = 0;  // 256-bit
        modes_to_test[1] = 1;  // 512-bit
        mode_count = 2;
        printf("Testing both modes: 256-bit and 512-bit\n");
    } else {
        // Test only specified mode
        modes_to_test[0] = config->common.device_mode;
        mode_count = 1;
        printf("Testing %d-bit mode only\n", get_hash_size(config->common.device_mode) * 8);
    }

    int total_passed = 0, total_tests = 0;

    // Test each mode
    for (int mode_idx = 0; mode_idx < mode_count; mode_idx++) {
        int current_mode = modes_to_test[mode_idx];
        int hash_size = get_hash_size(current_mode);
        const uint8_t *expected_hash;

        if (mode_count > 1) {
            printf("\n--- %d-bit Mode Tests ---\n", hash_size * 8);
        }

        int mode_passed = 0, mode_tests = 0;

        // Run all test vectors for this mode
        for (int i = 0; test_vectors[i].name != NULL; i++) {
            test_vector_t *vec = &test_vectors[i];

            // Select expected hash based on mode
            if (current_mode == 0) {
                expected_hash = vec->expected_hash_32;
            } else {
                expected_hash = vec->expected_hash_64;
            }

            // Skip if expected hash is not available for this mode
            if (expected_hash == NULL) {
                printf("Test %d: %s...SKIP (no expected hash for this mode)\n",
                       mode_tests + 1, vec->name);
                continue;
            }

            printf("Test %d: %s...", mode_tests + 1, vec->name);
            fflush(stdout);

            // Prepare input data
            memcpy(bufs.h2c_buf, vec->input, vec->input_len);

            // Calculate hash on FPGA
            if (xdma_hash_calc(&device, bufs.h2c_buf, vec->input_len,
                               bufs.c2h_buf, current_mode) != 0) {
                printf("FAIL (hash calculation failed)\n");
                mode_tests++;
                continue;
            }

            // Validate result
            if (config->validate && memcmp(bufs.c2h_buf, expected_hash, hash_size) != 0) {
                printf("FAIL (hash mismatch)\n");
                if (config->common.verbose) {
                    printf("  Expected: ");
                    for (size_t j = 0; j < hash_size; j++)
                        printf("%02x", expected_hash[j]);
                    printf("\n  Got:      ");
                    for (size_t j = 0; j < hash_size; j++)
                        printf("%02x", ((uint8_t*)bufs.c2h_buf)[j]);
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
               hash_size * 8, mode_passed, mode_tests);

        total_passed += mode_passed;
        total_tests += mode_tests;
    }

    printf("\n=== OVERALL RESULTS ===\n");
    printf("Total: %d/%d tests passed\n", total_passed, total_tests);

    result = (total_passed == total_tests) ? 0 : 1;

    // Cleanup
    xdma_close(&device);
    cleanup_dma_buffers(&bufs);
    return result;
}

// Comparison Mode Implementation

/**
 * Run comparison mode: compare FPGA results with software implementation
 *
 * @param config Comparison configuration
 * @return 0 if all comparisons match, 1 if any mismatch
 */
int run_compare_mode(const compare_config_t *config) {
    printf("\n=== COMPARISON MODE (FPGA vs Software) ===\n");

    dma_buffers_t bufs = {0};
    xdma_handle_t device = {0};
    int result = 1;

    // Validate configuration
    if (config->min_size > config->max_size) {
        fprintf(stderr, "Error: min_size cannot be larger than max_size\n");
        return 1;
    }

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

    // Run comparison iterations
    for (int i = 0; i < config->iterations; i++) {
        // Select mode for this iteration
        int current_mode;
        if (use_random_mode) {
            current_mode = rand() & 0x1;  // Random 0 or 1
        } else {
            current_mode = config->common.device_mode;
        }

        size_t hash_size = get_hash_size(current_mode);

        // Generate random data size within range
        size_t data_size;
        if (config->min_size == config->max_size) {
            data_size = config->min_size;
        } else {
            data_size = config->min_size + rand() % (config->max_size - config->min_size + 1);
        }

        // Generate random test data
        for (size_t j = 0; j < data_size; j++) {
            ((uint8_t*)bufs.h2c_buf)[j] = rand() & 0xFF;
        }

        // FPGA hash calculation with timing
        uint64_t start_fpga = get_nanoseconds();
        int fpga_result = xdma_hash_calc(&device, bufs.h2c_buf, data_size,
                                         bufs.c2h_buf, current_mode);
        uint64_t end_fpga = get_nanoseconds();
        double fpga_time = (double)(end_fpga - start_fpga);

        if (fpga_result != 0) {
            printf("Iteration %d: FPGA hash calculation failed\n", i + 1);
            results.failed_tests++;
            results.total_tests++;
            continue;
        }

        // Software hash calculation with timing
        uint64_t start_sw = get_nanoseconds();

        stribog_ctx_t ctx;
        uint8_t sw_hash[64];  // Buffer for both 256-bit and 512-bit hashes

        stribog_init(&ctx, (current_mode == 0) ? 256 : 512);
        stribog_update(&ctx, (uint8_t*)bufs.h2c_buf, data_size);
        stribog_final(&ctx, sw_hash);

        uint64_t end_sw = get_nanoseconds();
        double sw_time = (double)(end_sw - start_sw);

        // Compare results
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

        // Update min/max times
        if (i == 0 || fpga_time < results.min_time_ns)
            results.min_time_ns = fpga_time;
        if (fpga_time > results.max_time_ns)
            results.max_time_ns = fpga_time;
    }

    // Calculate statistics
    results.avg_time_ns = total_time / config->iterations;

    // Display results in table format
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

    // Cleanup
    xdma_close(&device);
    cleanup_dma_buffers(&bufs);
    return result;
}

// Benchmark Mode Implementation

/**
 * Run benchmark mode: measure FPGA performance across different data sizes
 *
 * @param config Benchmark configuration
 * @return 0 on success, 1 on error
 */
int run_bench_mode(bench_config_t *config) {
    printf("\n=== BENCHMARK MODE (Performance Measurement) ===\n");

    dma_buffers_t bufs = {0};
    xdma_handle_t device = {0};
    int result = 1;

    // Validate configuration
    if (config->min_size > config->max_size) {
        fprintf(stderr, "Error: min_size cannot be larger than max_size\n");
        return 1;
    }

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

    // Calculate number of different sizes to test
    int num_sizes = 0;
    size_t size = config->min_size;

    while (size <= config->max_size) {
        num_sizes++;
        if (config->step_size > 0) {
            size += config->step_size;
        } else {
            size *= 2;  // Exponential scaling
        }
    }

    benchmark_result_t *results = malloc(num_sizes * sizeof(benchmark_result_t));
    if (!results) {
        fprintf(stderr, "Memory allocation failed for results\n");
        goto cleanup;
    }

    // Warmup phase to stabilize performance
    printf("Warming up (%d iterations)...\n", config->warmup_iterations);
    for (int i = 0; i < config->warmup_iterations; i++) {
        xdma_hash_calc(&device, bufs.h2c_buf, 1024, bufs.c2h_buf,
                       (config->common.device_mode == -1) ? 1 : config->common.device_mode);
    }

    // Main measurement loop
    int result_count = 0;
    size = config->min_size;
    srand(time(NULL));  // Seed random number generator for random mode

    for (int i = 0; i < num_sizes; i++) {
        printf("Testing %9zu bytes...", size);
        fflush(stdout);

        // Generate reproducible test data (pseudo-random)
        for (size_t j = 0; j < size/sizeof(uint32_t); j++) {
            bufs.h2c_buf[j] = (j * 2654435761UL);  // Knuth multiplicative hash
        }

        double *times = malloc(config->iterations * sizeof(double));
        if (!times) {
            fprintf(stderr, "Failed to allocate times array\n");
            break;
        }

        double sum = 0.0, min = 1e20, max = 0.0;

        // Measure performance for this data size
        for (int iter = 0; iter < config->iterations; iter++) {
            // Select mode for this iteration
            int current_mode;
            if (use_random_mode) {
                current_mode = rand() & 0x1;  // Random 0 or 1
            } else {
                current_mode = config->common.device_mode;
            }

            uint64_t start = get_nanoseconds();
            // Perform hash calculation
            xdma_hash_calc(&device, bufs.h2c_buf, size, bufs.c2h_buf, current_mode);
            uint64_t end = get_nanoseconds();

            double time_ns = (double)(end - start);
            times[iter] = time_ns;
            sum += time_ns;

            if (time_ns < min) min = time_ns;
            if (time_ns > max) max = time_ns;
        }

        // Calculate statistics
        double avg = sum / config->iterations;
        double median = calculate_median(times, config->iterations);
        double throughput = (size / (1024.0 * 1024.0)) / (avg / 1e9);  // MiB/s
        double hashes_per_second = 1e9 / avg;

        // Store results
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

        // Calculate next data size
        if (config->step_size > 0) {
            size += config->step_size;
        } else {
            size *= 2;
        }

        if (size < config->min_size) break;  // Overflow protection
    }

    // Display results
    printf("\n=== FPGA Benchmark Results ===\n");
    print_results(results, result_count);

    // Save results to CSV file if requested
    if (config->output_file) {
        save_results_csv(results, result_count, config->output_file);
    }

    free(results);

cleanup:
    xdma_close(&device);
    cleanup_dma_buffers(&bufs);
    return result;
}

// Interactive Mode Implementation

/**
 * Run interactive mode: manual testing with user input
 *
 * @param config Interactive configuration
 * @return 0 on success, 1 on error
 */
int run_interactive_mode(interactive_config_t *config) {
    printf("\n=== INTERACTIVE MODE (Manual Testing) ===\n");
    printf("Enter data in hex format (e.g., '48656c6c6f' for 'Hello')\n");
    printf("Type 'quit' to exit\n\n");

    dma_buffers_t bufs = {0};
    xdma_handle_t device = {0};
    int result = 0;

    // Validate device mode
    if (config->common.device_mode == -1) {
        config->common.device_mode = 1;  // Default to 512-bit mode
        printf("Note: Using default 512-bit mode\n");
    }

    if (init_dma_buffers(&bufs, 8192) != 0) {
        fprintf(stderr, "Failed to initialize DMA buffers\n");
        return 1;
    }

    if (xdma_open(&device, config->common.block_count) != 0) {
        cleanup_dma_buffers(&bufs);
        return 1;
    }

    char input[4096];
    int hash_size = get_hash_size(config->common.device_mode);

    while (1) {
        printf("Input (hex): ");
        if (!fgets(input, sizeof(input), stdin)) break;

        // Remove trailing newline
        size_t input_len = strlen(input);
        if (input_len > 0 && input[input_len - 1] == '\n') {
            input[--input_len] = '\0';
        }

        // Check for quit command
        if (strcmp(input, "quit") == 0) break;

        // Validate input
        if (input_len == 0) {
            printf("Error: Empty input\n");
            continue;
        }

        if (input_len % 2 != 0) {
            printf("Error: Hex string must have even length\n");
            continue;
        }

        size_t binary_len = input_len / 2;
        if (binary_len > bufs.buffer_size) {
            printf("Error: Input too large (max %zu bytes)\n", bufs.buffer_size);
            continue;
        }

        // Convert hex string to binary
        for (size_t i = 0; i < binary_len; i++) {
            unsigned int byte;
            if (sscanf(&input[i*2], "%2x", &byte) != 1) {
                printf("Error: Invalid hex character at position %zu\n", i*2);
                break;
            }
            ((uint8_t*)bufs.h2c_buf)[i] = (uint8_t)byte;
        }

        // Perform hash calculation
        uint64_t start = get_nanoseconds();
        int op_result = xdma_hash_calc(&device, bufs.h2c_buf, binary_len,
                                        bufs.c2h_buf, config->common.device_mode);
        uint64_t end = get_nanoseconds();

        if (op_result != 0) {
            printf("Error: Hash calculation failed\n");
            continue;
        }

        // Display results
        printf("Hash: ");
        for (int i = 0; i < hash_size; i++) {
            printf("%02x", ((uint8_t*)bufs.c2h_buf)[i]);
        }
        printf("\nTime: %.2f us\n\n", (end - start) / 1000.0);
    }

    // Cleanup
    xdma_close(&device);
    cleanup_dma_buffers(&bufs);
    return result;
}

// Utility Functions

/**
 * Bind process to specific CPU core
 *
 * @param cpu_core CPU core number (0-based)
 * @return 0 on success, -1 on error
 */
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
            perror("Failed to set CPU affinity");
        }
    }
#endif
    return -1;
}

/**
 * Set real-time scheduling priority
 *
 * @return 0 on success, -1 on error
 */
int set_realtime_priority(void) {
#ifdef __linux__
    struct sched_param param = {.sched_priority = 50};

    if (sched_setscheduler(0, SCHED_FIFO, &param) == 0) {
        printf("✓ Set real-time scheduling (SCHED_FIFO, priority=50)\n");
        return 0;
    } else {
        perror("Failed to set real-time scheduling");
        return -1;
    }
#endif
    return -1;
}

/**
 * Get high-resolution timestamp in nanoseconds
 *
 * @return Timestamp in nanoseconds
 */
uint64_t get_nanoseconds(void) {
    struct timespec ts;
#ifdef CLOCK_MONOTONIC_RAW
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
#else
    clock_gettime(CLOCK_MONOTONIC, &ts);
#endif
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

/**
 * Calculate median of an array of doubles
 *
 * @param times Array of time measurements
 * @param n Number of elements in array
 * @return Median value
 */
double calculate_median(double *times, int n) {
    if (n == 0) return 0.0;

    double *copy = malloc(n * sizeof(double));
    if (!copy) return 0.0;

    memcpy(copy, times, n * sizeof(double));

    // Simple bubble sort (acceptable for small n ≤ 100)
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

/**
 * Initialize DMA buffers with proper alignment
 *
 * @param bufs Pointer to DMA buffers structure
 * @param size Buffer size in bytes
 * @return 0 on success, -1 on error
 */
int init_dma_buffers(dma_buffers_t *bufs, size_t size) {
    if (size == 0) return -1;

    // Allocate aligned memory for DMA (4096-byte alignment required)
    if (posix_memalign((void**)&bufs->h2c_buf, 4096, size) != 0) {
        perror("Failed to allocate H2C buffer");
        return -1;
    }

    if (posix_memalign((void**)&bufs->c2h_buf, 4096, size) != 0) {
        perror("Failed to allocate C2H buffer");
        free(bufs->h2c_buf);
        return -1;
    }

    bufs->buffer_size = size;
    memset(bufs->h2c_buf, 0, size);
    memset(bufs->c2h_buf, 0, size);

    return 0;
}

/**
 * Clean up DMA buffers
 *
 * @param bufs Pointer to DMA buffers structure
 */
void cleanup_dma_buffers(dma_buffers_t *bufs) {
    if (bufs->h2c_buf) free(bufs->h2c_buf);
    if (bufs->c2h_buf) free(bufs->c2h_buf);
    bufs->h2c_buf = NULL;
    bufs->c2h_buf = NULL;
    bufs->buffer_size = 0;
}

// Usage Help Functions

void print_test_usage(const char *program_name) {
    printf("Usage: %s test [OPTIONS]\n\n", program_name);
    printf("Run predefined test vectors for Stribog hash algorithm\n\n");
    printf("Options:\n");
    printf("  -d, --device-mode MODE   0=256-bit hash, 1=512-bit hash (default: -1=both)\n");
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
    printf("  -d, --device-mode MODE   0=256-bit hash, 1=512-bit hash (default: -1=random)\n");
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
    printf("  -d, --device-mode MODE   0=256-bit hash, 1=512-bit hash (default: -1=random)\n");
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

// Command Line Parsing Functions

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
            case 'b': config->common.block_count = strtoul(optarg, NULL, 0); break;
            case 'c': config->common.cpu_core = atoi(optarg); break;
            case 'r': config->common.use_realtime = 1; break;
            case 'v': config->common.verbose = 1; break;
            case 'h': print_test_usage(argv[0]); exit(0);
            case 0: config->validate = 0; break;  // --no-validate
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
            case 'b': config->common.block_count = strtoul(optarg, NULL, 0); break;
            case 'c': config->common.cpu_core = atoi(optarg); break;
            case 'r': config->common.use_realtime = 1; break;
            case 's': config->min_size = strtoul(optarg, NULL, 0); break;
            case 'S': config->max_size = strtoul(optarg, NULL, 0); break;
            case 't': config->step_size = strtoul(optarg, NULL, 0); break;
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
            case 'b': config->common.block_count = strtoul(optarg, NULL, 0); break;
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
            case 'b': config->common.block_count = strtoul(optarg, NULL, 0); break;
            case 'c': config->common.cpu_core = atoi(optarg); break;
            case 'r': config->common.use_realtime = 1; break;
            case 's': config->min_size = strtoul(optarg, NULL, 0); break;
            case 'S': config->max_size = strtoul(optarg, NULL, 0); break;
            case 'i': config->iterations = atoi(optarg); break;
            case 'v': config->common.verbose = 1; break;
            case 'h': print_compare_usage(argv[0]); exit(0);
            default: return 1;
        }
    }
    return 0;
}

/**
 * Print benchmark results in formatted table
 *
 * @param results Array of benchmark results
 * @param count Number of results
 */
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

/**
 * Save benchmark results to CSV file
 *
 * @param results Array of benchmark results
 * @param count Number of results
 * @param filename Output CSV filename
 * @return 0 on success, -1 on error
 */
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

// Main Function

int main(int argc, char *argv[]) {
    if (argc < 2) {
        print_general_usage(argv[0]);
        return 1;
    }

    const char *command = argv[1];

    // Default configuration for all commands
    common_config_t common_defaults = {
        .device_mode = -1,      // -1 means "both" for test, "random" for bench/compare
        .block_count = 0,
        .cpu_core = -1,
        .use_realtime = 0,
        .verbose = 0
    };

    int result = 0;

    // Parse and execute appropriate command
    if (strcmp(command, "test") == 0) {
        test_config_t config = {
            .common = common_defaults,
            .validate = 1
        };

        if (parse_test_options(argc - 1, argv + 1, &config) != 0) {
            print_test_usage(argv[0]);
            return 1;
        }

        // Set up environment
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

        // Validate configuration
        if (config.min_size > config.max_size) {
            fprintf(stderr, "Error: min_size cannot be larger than max_size\n");
            return 1;
        }

        // Set up environment
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
        config.common.device_mode = 1;  // Default to 512-bit for interactive mode

        if (parse_interactive_options(argc - 1, argv + 1, &config) != 0) {
            print_interactive_usage(argv[0]);
            return 1;
        }

        // Set up environment
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

        // Validate configuration
        if (config.min_size > config.max_size) {
            fprintf(stderr, "Error: min_size cannot be larger than max_size\n");
            return 1;
        }

        // Set up environment
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
        fprintf(stderr, "Error: Unknown command: %s\n\n", command);
        print_general_usage(argv[0]);
        return 1;
    }

    return result;
}
