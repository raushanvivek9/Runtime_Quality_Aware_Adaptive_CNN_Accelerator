# ==============================================================================
# Project: Neural_Acc (Phase 2 RTL Implementation)
# Task: TSK-22 Vivado Non-Project Batch Synthesis & Implementation Script
# Target FPGA: Xilinx Kintex-7 (xc7k325tffg900-2) / Artix-7 (xc7a100tcsg324-1)
# Usage: vivado -mode batch -source synth_vivado.tcl
# ==============================================================================

set TARGET_PART "xc7a100tcsg324-1"
set TOP_MODULE  "neural_acc_integrated_top"

puts "================================================================================"
puts "Starting Vivado Non-Project Synthesis for $TOP_MODULE on Part $TARGET_PART"
puts "================================================================================"

# 1. Read SystemVerilog Source Files
read_verilog -sv mac_unit_40b.sv
read_verilog -sv pe_array_40b.sv
read_verilog -sv adaptive_pe_controller.sv
read_verilog -sv ping_pong_buffer_controller.sv
read_verilog -sv hybrid_sram_bank.sv
read_verilog -sv multibank_sram_subsystem.sv
read_verilog -sv dma_controller.sv
read_verilog -sv layer_command_sequencer.sv
read_verilog -sv dma_to_sram_write_adapter.sv
read_verilog -sv datapath_compute_feeder.sv
read_verilog -sv ofmap_drain_controller.sv
read_verilog -sv memory_telemetry_monitor.sv
read_verilog -sv channel_tile_controller.sv
read_verilog -sv requantization_unit.sv
read_verilog -sv neural_acc_integrated_top.sv

# 2. Read Timing Constraints
read_xdc timing_constraints.xdc

# 3. RTL Synthesis
puts "--- Running synth_design ---"
synth_design -top $TOP_MODULE -part $TARGET_PART -directive PerformanceOptimized

# 4. Post-Synthesis Reports
puts "--- Generating Post-Synthesis Utilization & Timing Reports ---"
report_utilization -file synth_utilization_report.rpt
report_timing_summary -file synth_timing_summary.rpt

# 5. Optional Implementation (Uncomment when running complete bitstream flow)
# opt_design
# place_design
# phys_opt_design
# route_design
# report_utilization -file post_route_utilization.rpt
# report_timing_summary -file post_route_timing.rpt
# report_power -file post_route_power.rpt
# write_checkpoint -force neural_acc_routed.dcp

puts "================================================================================"
puts "Vivado Non-Project Synthesis Completed Successfully!"
puts "================================================================================"

