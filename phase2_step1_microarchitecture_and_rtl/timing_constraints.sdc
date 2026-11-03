# ==============================================================================
# Project: Neural_Acc (Phase 2 RTL Implementation)
# Task: TSK-22 Static Timing Analysis Constraints (SDC)
# Target Clock: 100.0 MHz (10.0 ns Clock Period)
# ==============================================================================

# 1. Primary Clock Definition
create_clock -name clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

# 2. Clock Uncertainty & Jitter
set_clock_uncertainty -setup 0.200 [get_clocks clk]
set_clock_uncertainty -hold  0.100 [get_clocks clk]
set_clock_transition 0.150 [get_clocks clk]

# 3. Input Constraints (20% of cycle period = 2.0 ns setup budget)
set_input_delay -clock clk -max 2.000 [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay -clock clk -min 0.500 [remove_from_collection [all_inputs] [get_ports clk]]

# 4. Output Constraints (20% of cycle period = 2.0 ns setup budget)
set_output_delay -clock clk -max 2.000 [all_outputs]
set_output_delay -clock clk -min 0.500 [all_outputs]

# 5. Asynchronous Reset Constraints
set_false_path -from [get_ports rst_n]

# 6. Drive & Load Assumptions
set_driving_cell -lib_cell INVX1 [remove_from_collection [all_inputs] [get_ports clk]]
set_load -pin_load 0.050 [all_outputs]

