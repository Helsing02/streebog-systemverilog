# Hardware Implementation of GOST R 34.11-2012 (Streebog) Hash Algorithm

## Project Overview

Hardware implementation of the GOST R 34.11-2012 ("Streebog") hash algorithm in SystemVerilog.
The core supports both operational modes: 256-bit and 512-bit hash outputs.

Key algorithm transformations are implemented as separate modules:

* LPSX - composition of linear (L), permutation (P), non-linear (S) and XOR (X) transformations (with optional optimization through combination of L and S transformations via ROM tables).
* L transformation - 64x64 matrix multiplication over GF(2).
* S transformation - non-linear byte substitution via GOST S-boxes (with optional optimization through simplified boolean expressions).
* P transformation - byte permutation within a 64-byte block
* N/Σ adders - 512-bit adders with optional DSP cascade support

## Project Structure

```console
rtl/                    # SystemVerilog source files
├── hash.sv             # Top-level with AXI4-Stream interface and optimization parameters
├── padding.sv          # GOST-compliant padding
├── g_transform.sv      # Compression function g(N, h, m)
├── lpsx_transform.sv   # LPSX transformation composition
├── ls_transform_rom.sv # Optimized LS combination via ROM tables
├── l_transform.sv      # Linear transformation L
├── p_transform.sv      # Permutation P
├── s_transform.sv      # Non-linear substitution S (base version)
├── s_transform_re.sv   # Optimized S via simplified boolean expressions
├── adder_512bit.sv     # 512-bit adder with DSP cascade support
├── matrix_multiplication.sv # Matrix multiplication for L transformation
└── tables/             # ROM tables for LS transformation
    ├── rom_p0.hex      # Table for byte 0
    └── ...             # Tables for bytes 1-7

sim/                    # Verification
├── hash/               # Top-level testbench with DPI-C interface
├── g_transform/        # Compression function testbench
├── lpsx_transform/     # LPSX testbench
├── ls_transform_rom/   # Optimized LS testbench
├── s_transform_re/     # Optimized S testbench
├── adder_512bit/       # Adder testbench
└── sim.tcl             # Universal QuestaSim script

core/                   # Infrastructure (hdlmake)
├── Manifest.py         # Project build manifest
├── regmap/             # Register space
├── axis_forencich/     # AXI4-Stream utilities (submodule)
└── xilinx/             # Xilinx-specific files

sw/                    # Software components
├── streebog-hw-driver/ # Hardware driver
└── stribog-sw/         # Reference software implementation (submodule)
```

## Quick Start

### 1. Clone and Initialize

```bash
git clone https://github.com/Helsing02/streebog-systemverilog
cd streebog-systemverilog
git submodule update --init --recursive
```

### 2. Module Verification (Simulation)

To run tests for any module in QuestaSim:
```bash
cd sim
vsim -do "do sim.tcl hash"              # Test entire core
vsim -do "do sim.tcl g_transform"       # Test compression function
vsim -do "do sim.tcl ls_transform_rom"  # Test optimized LS
```

The sim.tcl script automatically:
* Collects all module dependencies
* Connects software implementation via DPI-C for verification
* Runs tests with result comparison

### 3. Register Map

Main control register:
```yaml
MODE (address 0x00):
    MODE_BIT [0] - operation mode: 1=512-bit, 0=256-bit
```

Test-specific auxiliary registers:
```yaml
TOTAL_NUM_TRANS (address 0x04) - planned number of AXI4-Stream transactions
RECV_NUM_TRANS  (address 0x08) - received transaction counter
```

## Optimizations

### Optimized S Transformation

Parameter `USE_S_RE` enables S transformation optimization via simplified boolean expressions:
* Principle: replacement of tabular S-box with combinational logic
* Note: incompatible with `USE_LS_ROM` (automatically disabled)
* Resources: less than without this optimization

### LS Transformation via ROM Tables

Parameter `USE_PRECALC` in `hash.sv` enables optimization of combined L and S transformations via precalculated ROM tables:
* Principle: tables contain LS(x) results for all possible 8-bit inputs
* Resources: 8 tables of 256x64 bits = 16 Kbits ROM

### DSP Cascades for Adders

Parameter `USE_DSP` enables DSP block usage for 512-bit `N` and `Σ` adders:
* Principle: DSP48 block cascading for modulo 2^512 addition
* Resources: LUT savings at DSP expense
* Compatibility: Works with any LS/S optimization


### Example Parameter Configuration:

```systemverilog
hash #(
    .USE_LS_ROM(1),    // Use ROM for LS (priority)
    .USE_S_RE(0),      // Disabled since USE_LS_ROM=1
    .USE_DSP(1)        // Use DSP for adders
) hash_inst (...);
```

## Requirements

* Simulator: QuestaSim 2020.1 or newer (for DPI-C interface)
* Synthesis: Vivado 2020.1+
* Tools: hdlmake for project build (optional)
* Resources (estimate for Xilinx xczu19eg):
    * Base configuration: ~15K LUT, ~4K FF
    * With optimizations: ~6K LUT, ~4K FF, 128 BRAM, 22 DSP
* Clock frequency: 250 MHz

## DPI-C Verification

Reference software implementation from the stribog-sw submodule is used for verification.
This enables automatic comparison of test vectors between hardware and software implementations.

## Performance

Configuration comparison on Xilinx xczu19eg (250 MHz clock):

|Configuration    |LUT   |FF   |BRAM|DSP|
|:---------------:|:----:|:---:|:--:|:-:|
|Base             |~15.3K|~4.2K|0   |0  |
|Base + DSP       |~13.7K|~4.2K|0   |22 |
|Optimized S      |~14.9K|~4.2K|0   |0  |
|Optimized S + DSP|~13.6K|~4.2K|0   |22 |
|LS BRAM          |~8.3K |~3.7K|128 |0  |
|LS BRAM + DSP    |~6.2K |~3.7K|128 |22 |


Note: *This project was developed for research purposes and verification of GOST 34.11-2012 hardware implementations. Optimizations allow adaptation to specific resource requirements.*
