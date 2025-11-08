# Центральный симуляционный скрипт

# Получение аргументов
if { $argc < 1 } {
    puts "Usage: do sim.tcl <module_name> ?<run_time>? ?PARAM=<value>?"
    exit 1
}

quietly set module_name $1
quietly set run_time ""
quietly set param_value ""

# Парсинг аргументов
# for {set i 2} {$i <= $argc} {incr i} {
#     set arg $i
#     if {[string match *us* $arg] || [string match *ns* $arg] || [string match *ms* $arg]} {
#         quietly set run_time $arg
#     } elseif {[string match PARAM=* $arg]} {
#         quietly set param_value [string range $arg 5 end]
#         # puts "Parameter value: $param_value"
#     }
# }

# Настройка путей
quietly set RTL_DIR "../rtl"
quietly set TB_DIR "./$module_name"
quietly set WORK_LIB "$TB_DIR/work"

quietly set DPI_SRC_DIR "../sw/src"
quietly set STREEBOG_C "$DPI_SRC_DIR/hash/stribog.c"

# Рекурсивный поиск всех SystemVerilog файлов
proc find_sv_files {dir} {
    set files {}
    if {[file exists $dir]} {
        foreach item [glob -nocomplain -directory $dir *] {
            if {[file isdirectory $item]} {
                set files [concat $files [find_sv_files $item]]
            } elseif {[string match *.sv $item] || [string match *.svh $item]} {
                lappend files $item
            }
        }
    }
    return $files
}

# Очистка предыдущей симуляции
if {[file exists $WORK_LIB]} {
    file delete -force $WORK_LIB
}

# Создаем рабочую библиотеку
vlib $WORK_LIB
vmap work $WORK_LIB

# Поиск и компиляция всех RTL файлов
quietly set rtl_files [find_sv_files $RTL_DIR]
if {[llength $rtl_files] == 0} {
    puts "WARNING: No SystemVerilog files found in $RTL_DIR"
} else {
    puts "Compiling RTL files:"
    foreach file $rtl_files {
        puts "  $file"
        vlog -work $WORK_LIB -sv $file
    }

}

# # Проверка существования файлов
# quietly set rtl_file "$RTL_DIR/${module_name}.sv"
quietly set tb_file "$TB_DIR/tb_${module_name}.sv"

# if {![file exists $rtl_file]} {
#     puts "ERROR: RTL file not found: $rtl_file"
#     exit 1
# }

if {![file exists $tb_file]} {
    puts "ERROR: Testbench file not found: $tb_file"
    exit 1
}

# puts "Compiling RTL: $rtl_file"
# vlog -work $WORK_LIB -sv $rtl_file

puts "Compiling Testbench: $tb_file"
vlog -work $WORK_LIB -sv $tb_file -dpiheader dpi_types.h $STREEBOG_C

# Подготовка команды симуляции
set vsim_cmd "vsim +initreg+0 +initmem+0 -voptargs=+acc -L work work.tb_${module_name} -t 1ns"

if { $param_value != "" } {
    append vsim_cmd " -gPARAM=$param_value"
}

puts "Running simulation: $vsim_cmd"
eval $vsim_cmd

# Добавляем волны по умолчанию
add wave *
add wave -position insertpoint sim:/tb_${module_name}/dut_precalc/*
# add wave -position insertpoint sim:/tb_${module_name}/dut/rom*
# add wave -position insertpoint sim:/tb_${module_name}/dut/g_instance/*
# set signals {"main_nextstate" "main_state" "block_hash_nextstate" "block_hash_state" "g_instance/nextstate" "g_instance/state" "g_instance/s_axis_m_tdata" "g_instance/s_axis_m_tvalid"}
# foreach signal $signals {
#     add wave -position insertpoint sim:/tb_${module_name}/dut/$signal
# }


# Запуск симуляции
puts "Runtime: $run_time"
if { $run_time != "" } {
    puts "Running for $run_time..."
    run $run_time
} else {
    puts "Running until \$finish/stop..."
    run -all
}

puts "Simulation completed."