CC = gcc
CFLAGS = -O2 -Wall -Wextra -std=gnu99 -D_GNU_SOURCE -mavx2 -O3
LDFLAGS = -lpthread -lrt
TARGET = xdma_stribog_test
SOURCES = xdma_stribog_test.c stribog-hash/src/hash/stribog.c
RESULTS_DIR = results
BENCH_DIR = $(RESULTS_DIR)/benchmarks
COMPARE_DIR = $(RESULTS_DIR)/comparisons

# Создание необходимых директорий
$(RESULTS_DIR):
	mkdir -p $(RESULTS_DIR) $(BENCH_DIR) $(COMPARE_DIR)

$(TARGET): $(SOURCES)
	$(CC) $(CFLAGS) -o $(TARGET) $(SOURCES) $(LDFLAGS)

all: $(TARGET) $(RESULTS_DIR)

clean:
	rm -f $(TARGET) *.o
	rm -rf $(RESULTS_DIR)

install: $(TARGET)
	sudo cp $(TARGET) /usr/local/bin/

uninstall:
	sudo rm -f /usr/local/bin/$(TARGET)

# ==================== ТЕСТИРОВАНИЕ ====================

# Быстрый тест (оба режима)
test-quick: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) test

# Тест только 256-битного режима
test-256: $(TARGET)
	sudo ./$(TARGET) test -d 0 -v

# Тест только 512-битного режима
test-512: $(TARGET)
	sudo ./$(TARGET) test -d 1 -v

# Полный тест с детальным выводом
test-full: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) test -v

# Тест с отключенной валидацией (только производительность)
test-noval: $(TARGET)
	sudo ./$(TARGET) test --no-validate

# ==================== БЕНЧМАРКИ ====================

# Быстрый бенчмарк (512-bit)
bench-quick: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) bench -s 64 -S 8192 -i 10 -w 2

# Бенчмарк 256-битного режима
bench-256: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) bench -d 0 -s 64 -S 65536 -i 50 -w 5 -o $(BENCH_DIR)/bench_256_$(shell date +%Y%m%d_%H%M%S).csv

# Бенчмарк 512-битного режима
bench-512: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) bench -d 1 -s 64 -S 65536 -i 50 -w 5 -o $(BENCH_DIR)/bench_512_$(shell date +%Y%m%d_%H%M%S).csv

# Полный бенчмарк обоих режимов
bench-full: bench-256 bench-512

# Профессиональный бенчмарк (realtime, привязка к ядру)
bench-pro: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) bench -d 1 -s 1024 -S 1048576 -i 1000 -w 100 -c 0 -r -b 256 -o $(BENCH_DIR)/bench_pro_$(shell date +%Y%m%d_%H%M%S).csv

# Бенчмарк с разными размерами блоков
bench-blocks: $(TARGET) $(RESULTS_DIR)
	@echo "=== Testing different block sizes ==="
	sudo ./$(TARGET) bench -d 1 -s 1024 -S 16384 -i 20 -b 1 -o $(BENCH_DIR)/blocks_1_$(shell date +%Y%m%d_%H%M%S).csv
	sudo ./$(TARGET) bench -d 1 -s 1024 -S 16384 -i 20 -b 4 -o $(BENCH_DIR)/blocks_4_$(shell date +%Y%m%d_%H%M%S).csv
	sudo ./$(TARGET) bench -d 1 -s 1024 -S 16384 -i 20 -b 16 -o $(BENCH_DIR)/blocks_16_$(shell date +%Y%m%d_%H%M%S).csv

# ==================== СРАВНЕНИЕ ====================

# Быстрое сравнение (случайные режимы)
compare-quick: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) compare -i 10 -s 64 -S 1024

# Сравнение 256-битного режима
compare-256: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) compare -d 0 -i 100 -s 64 -S 8192 -v

# Сравнение 512-битного режима
compare-512: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) compare -d 1 -i 100 -s 64 -S 8192 -v

# Полное сравнение со случайными режимами
compare-full: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) compare -i 500 -s 64 -S 65536 -b 32

# Интенсивное сравнение (realtime)
compare-pro: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) compare -i 1000 -s 1024 -S 131072 -c 0 -r -v -b 32

# ==================== ИНТЕРАКТИВНЫЙ РЕЖИМ ====================

# Интерактивный режим 256-bit
interactive-256: $(TARGET)
	sudo ./$(TARGET) interactive -d 0

# Интерактивный режим 512-bit
interactive-512: $(TARGET)
	sudo ./$(TARGET) interactive -d 1

# Интерактивный режим с verbose
interactive-verbose: $(TARGET)
	sudo ./$(TARGET) interactive -d 1 -v

# ==================== СЛУЖЕБНЫЕ ЦЕЛИ ====================

# Проверка доступности устройств
check-devices:
	@echo "=== Checking XDMA devices ==="
	@ls -la /dev/xdma* 2>/dev/null || echo "XDMA devices not found!"
	@echo "=== Checking Stribog device ==="
	@test -c /dev/xdma0_user && echo "✓ User device present" || echo "✗ User device missing"
	@test -c /dev/xdma0_h2c_0 && echo "✓ H2C device present" || echo "✗ H2C device missing"
	@test -c /dev/xdma0_c2h_0 && echo "✓ C2H device present" || echo "✗ C2H device missing"

# Показать справку
help:
	@echo "=== FPGA Stribog Test Makefile ==="
	@echo ""
	@echo "Building:"
	@echo "  make all          - Build everything"
	@echo "  make clean        - Clean build artifacts"
	@echo "  make install      - Install to /usr/local/bin"
	@echo "  make uninstall    - Uninstall"
	@echo ""
	@echo "Testing:"
	@echo "  make test-quick   - Quick test (both modes)"
	@echo "  make test-256     - Test 256-bit mode only"
	@echo "  make test-512     - Test 512-bit mode only"
	@echo "  make test-full    - Full test with verbose output"
	@echo "  make test-noval   - Test without validation"
	@echo ""
	@echo "Benchmarks:"
	@echo "  make bench-quick  - Quick benchmark (512-bit)"
	@echo "  make bench-256    - 256-bit benchmark"
	@echo "  make bench-512    - 512-bit benchmark"
	@echo "  make bench-full   - Full benchmark both modes"
	@echo "  make bench-pro    - Professional benchmark (realtime)"
	@echo "  make bench-blocks - Test different block sizes"
	@echo ""
	@echo "Comparison:"
	@echo "  make compare-quick - Quick comparison (random modes)"
	@echo "  make compare-256   - Compare 256-bit mode"
	@echo "  make compare-512   - Compare 512-bit mode"
	@echo "  make compare-full  - Full comparison with random modes"
	@echo "  make compare-pro   - Intensive comparison (realtime)"
	@echo ""
	@echo "Interactive:"
	@echo "  make interactive-256     - Interactive 256-bit mode"
	@echo "  make interactive-512     - Interactive 512-bit mode"
	@echo "  make interactive-verbose - Interactive with verbose"
	@echo ""
	@echo "Utilities:"
	@echo "  make check-devices - Check device availability"
	@echo "  make help          - Show this help"

# Показать последние результаты
show-results:
	@echo "=== Latest benchmark results ==="
	@ls -lt $(BENCH_DIR)/*.csv 2>/dev/null | head -5 || echo "No benchmark results found"
	@echo ""
	@echo "=== Latest comparison results ==="
	@ls -lt $(COMPARE_DIR)/*.csv 2>/dev/null | head -5 || echo "No comparison results found"

# Очистка результатов
clean-results:
	rm -rf $(RESULTS_DIR)/*

# Daily test - полный ежедневный тест
daily-test: $(TARGET) $(RESULTS_DIR)
	@echo "=== Starting daily test suite ==="
	@date
	@echo "1. Running quick test..."
	@sudo ./$(TARGET) test --test-both-modes > $(RESULTS_DIR)/daily_test_$(shell date +%Y%m%d).log 2>&1
	@echo "2. Running 256-bit benchmark..."
	@sudo ./$(TARGET) bench -d 0 -s 1024 -S 16384 -i 20 -o $(BENCH_DIR)/daily_256_$(shell date +%Y%m%d).csv >> $(RESULTS_DIR)/daily_test_$(shell date +%Y%m%d).log 2>&1
	@echo "3. Running 512-bit benchmark..."
	@sudo ./$(TARGET) bench -d 1 -s 1024 -S 16384 -i 20 -o $(BENCH_DIR)/daily_512_$(shell date +%Y%m%d).csv >> $(RESULTS_DIR)/daily_test_$(shell date +%Y%m%d).log 2>&1
	@echo "4. Running comparison test..."
	@sudo ./$(TARGET) compare -R -i 50 -s 1024 -S 8192 >> $(RESULTS_DIR)/daily_test_$(shell date +%Y%m%d).log 2>&1
	@echo "=== Daily test completed ==="
	@tail -5 $(RESULTS_DIR)/daily_test_$(shell date +%Y%m%d).log

.PHONY: all clean install uninstall help \
        test-quick test-256 test-512 test-full test-noval \
        bench-quick bench-256 bench-512 bench-full bench-pro bench-blocks \
        compare-quick compare-256 compare-512 compare-full compare-pro \
        interactive-256 interactive-512 interactive-verbose \
        check-devices show-results clean-results daily-test
