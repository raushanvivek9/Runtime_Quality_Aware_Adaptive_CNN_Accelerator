#!/usr/bin/env python3
"""
Project: Neural_Acc (Phase 2 RTL Implementation)
Task: TSK-22 Power Switching Activity Generator & Toggle Rate Profiler
Module: generate_power_activity.py
Description: Runs simulation of tb_power_switching_activity.sv, produces
             neural_acc_switching_activity.vcd, profiles toggle rates, and
             prepares switching data for Vivado/Synopsys power analysis.
"""

import subprocess
import os
import sys

def main():
    print("=" * 80)
    print("TSK-22 Dynamic Switching Activity & Power Estimation Generator")
    print("=" * 80)

    # 1. Compile simulation with VCD dumping enabled
    compile_cmd = (
        "iverilog -g2012 -o /tmp/sim_pwr "
        "mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv ping_pong_buffer_controller.sv "
        "hybrid_sram_bank.sv multibank_sram_subsystem.sv dma_controller.sv layer_command_sequencer.sv "
        "dma_to_sram_write_adapter.sv datapath_compute_feeder.sv ofmap_drain_controller.sv "
        "memory_telemetry_monitor.sv channel_tile_controller.sv requantization_unit.sv "
        "neural_acc_integrated_top.sv tb_power_switching_activity.sv"
    )

    print("[STEP 1] Compiling testbench with switching activity instrumentation...")
    p_comp = subprocess.run(compile_cmd, shell=True, capture_output=True, text=True)
    if p_comp.returncode != 0:
        print(f"[FAIL] Compilation failed:\n{p_comp.stderr}")
        return False
    print("[PASS] Compilation successful.")

    # 2. Run simulation
    print("[STEP 2] Executing simulation and generating VCD activity file...")
    p_sim = subprocess.run("vvp /tmp/sim_pwr", shell=True, capture_output=True, text=True)
    subprocess.run("rm -f /tmp/sim_pwr", shell=True)

    if p_sim.returncode != 0:
        print(f"[FAIL] Simulation failed:\n{p_sim.stderr}")
        return False
    print(f"[PASS] Simulation completed:\n{p_sim.stdout.strip()}")

    # 3. Verify VCD creation
    vcd_path = "neural_acc_switching_activity.vcd"
    if not os.path.exists(vcd_path):
        print(f"[FAIL] VCD file {vcd_path} was not created.")
        return False

    vcd_size = os.path.getsize(vcd_path)
    print(f"[STEP 3] VCD generated: {vcd_path} ({vcd_size:,} bytes)")

    # 4. Profile toggle statistics from VCD
    print("[STEP 4] Profiling signal toggle statistics...")
    total_value_changes = 0
    signals_seen = set()

    with open(vcd_path, "r", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("$var"):
                parts = line.split()
                if len(parts) >= 5:
                    signals_seen.add(parts[4])
            elif line[0] in "01xXzZbBrR":
                total_value_changes += 1

    print(f"  Total Signals Instrumented : {len(signals_seen):,}")
    print(f"  Total Value Transitions    : {total_value_changes:,}")
    print(f"  Average Transitions / Signal: {total_value_changes / max(len(signals_seen), 1):.2f}")

    print("\n[SUCCESS] Power estimation activity generation completed.")
    return True

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)

