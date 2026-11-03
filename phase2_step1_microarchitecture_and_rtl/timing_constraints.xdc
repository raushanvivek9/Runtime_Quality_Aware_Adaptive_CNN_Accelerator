# ==============================================================================
# Project: Neural_Acc (Phase 2 RTL Implementation)
# Task: TSK-22 Xilinx Design Constraints (XDC)
# Target Clock: 100.0 MHz (10.0 ns Period)
# Target Architecture: Xilinx 7-Series (Artix-7 / Kintex-7)
# ==============================================================================

# 1. Primary Clock Definition
create_clock -period 10.000 -name clk -waveform {0.000 5.000} [get_ports clk]

# 2. Clock Uncertainty
set_clock_uncertainty -setup 0.200 [get_clocks clk]
set_clock_uncertainty -hold 0.100 [get_clocks clk]

# 3. Input Delays (Assuming 2.0 ns external board / PHY delay)
set_input_delay -clock [get_clocks clk] -max 2.000 [get_ports -filter {NAME !~ "clk" && DIRECTION == "IN"}]
set_input_delay -clock [get_clocks clk] -min 0.500 [get_ports -filter {NAME !~ "clk" && DIRECTION == "IN"}]

# 4. Output Delays (Assuming 2.0 ns external board / PHY delay)
set_output_delay -clock [get_clocks clk] -max 2.000 [get_ports -filter {DIRECTION == "OUT"}]
set_output_delay -clock [get_clocks clk] -min 0.500 [get_ports -filter {DIRECTION == "OUT"}]

# 5. False Paths
set_false_path -from [get_ports rst_n]

# 6. Configuration / Static Signal Timing Relaxations
set_false_path -through [get_ports cfg_parallel_en]
set_false_path -through [get_ports cfg_sparse_feeder_en]
set_false_path -through [get_ports cfg_ofmap_drain_en]
set_false_path -through [get_ports cfg_ofmap_base_addr*]

