# ============================================================================
# FPGA Stribog Hash Accelerator Test Suite Makefile
# ============================================================================

# Compiler and flags
CC = gcc
CFLAGS = -O2 -Wall -Wextra -std=gnu99 -D_GNU_SOURCE -mavx2 -O3
LDFLAGS = -lpthread -lrt
TARGET = controller

# Source files (software implementation for comparison)
SOURCES = controller.c ../stribog-sw/src/hash/stribog.c

# Result directories for organized output
RESULTS_DIR = results
BENCH_DIR = $(RESULTS_DIR)/benchmarks

# Create necessary directories before building
$(RESULTS_DIR) $(BENCH_DIR):
	mkdir -p $@

# BUILD TARGETS

# Main executable target
$(TARGET): $(SOURCES)
	$(CC) $(CFLAGS) -o $(TARGET) $(SOURCES) $(LDFLAGS)

# Build everything including directories
all: $(TARGET) $(RESULTS_DIR)

# Clean build artifacts
clean:
	rm -f $(TARGET) *.o
	rm -rf $(RESULTS_DIR)

# TESTING TARGETS - Verification of correctness

# Test only 256-bit mode
test-256: $(TARGET)
	sudo ./$(TARGET) test -d 0

# Test only 512-bit mode
test-512: $(TARGET)
	sudo ./$(TARGET) test -d 1

# Full test with verbose output
test-full: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) test -v

# Test without validation (for speed)
test-noval: $(TARGET)
	sudo ./$(TARGET) test --no-validate

# BENCHMARK TARGETS - Performance measurement

# Quick benchmark (small data sizes, 512-bit mode)
bench-quick: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) bench -s 64 -S 8192 -i 10 -w 2

# 256-bit benchmark
bench-256: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) bench -d 0 -s 64 -S 65536 -i 50 -w 5 -o $(BENCH_DIR)/bench_256_$(shell date +%Y%m%d_%H%M%S).csv

# 512-bit benchmark
bench-512: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) bench -d 1 -s 64 -S 65536 -i 50 -w 5 -o $(BENCH_DIR)/bench_512_$(shell date +%Y%m%d_%H%M%S).csv

# Full benchmark both modes
bench-full: bench-256 bench-512

# Professional benchmark (realtime priority, CPU affinity, 512-bit)
bench-pro: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) bench -d 1 -s 1024 -S 1048576 -i 1000 -w 100 -c 0 -r -b 256 -o $(BENCH_DIR)/bench_pro_$(shell date +%Y%m%d_%H%M%S).csv

# COMPARISON TARGETS - Hardware vs Software comparison

# Quick comparison (random modes, small data sizes)
compare-quick: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) compare -i 10 -s 64 -S 1024

# Compare 256-bit mode
compare-256: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) compare -d 0 -i 100 -s 64 -S 8192 -v

# Compare 512-bit mode
compare-512: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) compare -d 1 -i 100 -s 64 -S 8192 -v

# Full comparison with random modes
compare-full: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) compare -i 500 -s 64 -S 65536 -b 32

# Intensive comparison (realtime priority)
compare-pro: $(TARGET) $(RESULTS_DIR)
	sudo ./$(TARGET) compare -i 1000 -s 1024 -S 131072 -c 0 -r -v -b 32

# INTERACTIVE TARGETS - Manual testing and debugging

# Interactive mode 256-bit
interactive-256: $(TARGET)
	sudo ./$(TARGET) interactive -d 0

# Interactive mode 512-bit
interactive-512: $(TARGET)
	sudo ./$(TARGET) interactive -d 1

# Interactive mode with verbose output
interactive-verbose: $(TARGET)
	sudo ./$(TARGET) interactive -d 1 -v

# UTILITY TARGETS - System checks and maintenance

# Check XDMA device availability
check-devices:
	@echo "=== Checking XDMA device files ==="
	@test -c /dev/xdma0_user && echo "✓ /dev/xdma0_user (control)" || echo "✗ /dev/xdma0_user missing"
	@test -c /dev/xdma0_h2c_0 && echo "✓ /dev/xdma0_h2c_0 (host-to-card)" || echo "✗ /dev/xdma0_h2c_0 missing"
	@test -c /dev/xdma0_c2h_0 && echo "✓ /dev/xdma0_c2h_0 (card-to-host)" || echo "✗ /dev/xdma0_c2h_0 missing"
	@echo "=== Device permissions ==="
	@ls -l /dev/xdma0_* 2>/dev/null || echo "No XDMA devices found"

# Clean only results (keep executable)
clean-results:
	rm -rf $(RESULTS_DIR)/*

# HELP TARGET - Documentation

# Display help message with available targets
help:
	@echo "=== FPGA Stribog Hash Accelerator Test Suite ==="
	@echo ""
	@echo "BUILD TARGETS:"
	@echo "  all                    Build everything (executable + directories)"
	@echo "  clean                  Remove build artifacts"
	@echo ""
	@echo "TESTING TARGETS (correctness verification):"
	@echo "  test-256               Test only 256-bit mode"
	@echo "  test-512               Test only 512-bit mode"
	@echo "  test-full              Full test with verbose output"
	@echo "  test-noval             Test without validation (for speed)"
	@echo ""
	@echo "BENCHMARK TARGETS (performance measurement):"
	@echo "  bench-quick            Quick benchmark (small data sizes, 512-bit)"
	@echo "  bench-256              256-bit benchmark"
	@echo "  bench-512              512-bit benchmark"
	@echo "  bench-full             Full benchmark both modes"
	@echo "  bench-pro              Professional benchmark (realtime priority)"
	@echo ""
	@echo "COMPARISON TARGETS (HW vs SW):"
	@echo "  compare-quick          Quick hardware/software comparison (random modes)"
	@echo "  compare-256            Compare 256-bit mode"
	@echo "  compare-512            Compare 512-bit mode"
	@echo "  compare-full           Full comparison with random modes"
	@echo "  compare-pro            Intensive comparison (realtime priority)"
	@echo ""
	@echo "INTERACTIVE TARGETS (manual testing):"
	@echo "  interactive-256        Interactive mode for 256-bit"
	@echo "  interactive-512        Interactive mode for 512-bit"
	@echo "  interactive-verbose    Interactive mode with verbose output"
	@echo ""
	@echo "UTILITY TARGETS:"
	@echo "  check-devices          Check XDMA device availability"
	@echo "  clean-results          Clean results directories"
	@echo "  help                   Show this help message"
	@echo ""
	@echo "Note: Most targets require sudo for device access"
	@echo "Results are saved to: $(RESULTS_DIR)/"

# PHONY TARGET DECLARATIONS

.PHONY: all clean help \
        test-256 test-512 test-full test-noval \
        bench-quick bench-256 bench-512 bench-full bench-pro \
        compare-quick compare-256 compare-512 compare-full compare-pro \
        interactive-256 interactive-512 interactive-verbose \
        check-devices clean-results