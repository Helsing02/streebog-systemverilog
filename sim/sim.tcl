# ------------------------------------------------------------------------------
# Main Simulation Script for RTL Verification
#
# This script automates compilation and simulation of SystemVerilog testbenches.
# Usage: do sim.tcl <module_name>
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# ARGUMENT PARSING
# ------------------------------------------------------------------------------
# Check command line arguments
if { $argc < 1 } {
    puts "Usage: do sim.tcl <module_name>"
    puts "Example: do sim.tcl adder_512bit"
    exit 1
}

# Get the module name to test
quietly set module_name $1

# ------------------------------------------------------------------------------
# DIRECTORY SETUP
# ------------------------------------------------------------------------------
# Define all relevant paths for the project
# RTL source directory
quietly set RTL_DIR "../rtl"
# Testbench directory for this module
quietly set TB_DIR "./$module_name"
# Simulation library location
quietly set WORK_LIB "$TB_DIR/work"
# External IP directory
quietly set AXIS_LIB "../core/axis_forencich/rtl"
# SW streebog .c file
quietly set STREEBOG_C_SRC "../sw/src/hash/stribog.c"

# ------------------------------------------------------------------------------
# HELPER PROCEDURE: FIND SYSTEMVERILOG FILES
# ------------------------------------------------------------------------------
# Recursively searches for all .sv files in a directory
proc find_sv_files {dir} {
    set files {}
    if {[file exists $dir]} {
        foreach item [glob -nocomplain -directory $dir *] {
            if {[file isdirectory $item]} {
                # Recursive call for subdirectories
                set files [concat $files [find_sv_files $item]]
            } elseif {[string match *.sv $item]} {
                # Add SystemVerilog files to the list
                lappend files $item
            }
        }
    }
    return $files
}

# ------------------------------------------------------------------------------
# CLEANUP PREVIOUS SIMULATION
# ------------------------------------------------------------------------------
# Remove existing library to ensure clean simulation run
if {[file exists $WORK_LIB]} {
    puts "Cleaning previous simulation library..."
    file delete -force $WORK_LIB
}

# ------------------------------------------------------------------------------
# CREATE NEW SIMULATION LIBRARY
# ------------------------------------------------------------------------------
# Create and map the working library
vlib $WORK_LIB
vmap work $WORK_LIB
puts "Created simulation library: $WORK_LIB"

# ------------------------------------------------------------------------------
# COMPILE RTL SOURCES
# ------------------------------------------------------------------------------
# Find and compile all SystemVerilog files in the RTL directory
quietly set rtl_files [find_sv_files $RTL_DIR]

if {[llength $rtl_files] == 0} {
    puts "WARNING: No SystemVerilog files found in $RTL_DIR"
} else {
    puts "Compiling RTL files..."
    foreach file $rtl_files {
        puts "  [file tail $file]"
        vlog -work $WORK_LIB -sv $file
    }
    puts "RTL compilation complete.\n"
}

# ------------------------------------------------------------------------------
# COMPILE EXTERNAL COMPONENTS
# ------------------------------------------------------------------------------
# Compile required external IP blocks and utilities
puts "Compiling external components..."
# AXI-Stream register
vlog -work $WORK_LIB -sv "$AXIS_LIB/axis_register.v"
# Global simulation model for Xilinx
vlog -work $WORK_LIB -sv "../core/xilinx/glbl.v"

# ------------------------------------------------------------------------------
# COMPILE TESTBENCH
# ------------------------------------------------------------------------------
# Verify testbench exists and compile it
quietly set tb_file "$TB_DIR/tb_${module_name}.sv"

if {![file exists $tb_file]} {
    puts "ERROR: Testbench file not found: $tb_file"
    puts "Expected testbench at: $TB_DIR/"
    exit 1
}

puts "Compiling testbench: [file tail $tb_file]"
vlog -work $WORK_LIB -sv $tb_file
vlog -work $WORK_LIB -sv $tb_file -dpiheader dpi_types.h $STREEBOG_C_SRC
puts "Testbench compilation complete.\n"

# ------------------------------------------------------------------------------
# LAUNCH SIMULATION
# ------------------------------------------------------------------------------
# Configure and start the simulation
set vsim_cmd "vsim -voptargs=+acc -L work work.glbl work.tb_${module_name} -L unisims_ver -t 1ns"
puts "Starting simulation with command:"
puts "  $vsim_cmd\n"

eval $vsim_cmd

# ------------------------------------------------------------------------------
# RUN SIMULATION
# ------------------------------------------------------------------------------
# Execute the simulation until $finish is called
puts "Running simulation until \$finish..."
run -all

puts "\nSimulation completed successfully."
