#!/usr/bin/env python3
"""
Project: Neural_Acc (Phase 2 RTL Implementation)
Task: TSK-23 Final Evidence Audit & Unified Regression Runner
Module: run_tsk23_unified_regression.py
Description: Master verification and audit execution script.
             Runs full baseline regression, cycle reconciliation, memory telemetry,
             multi-pass tiling with tail tiles, bit-exact requantization,
             power switching activity generation, and audit reconciliations.
             Propagates non-zero exit codes on any failure.
"""

import os
import sys
import subprocess
import time

PROTECTED_FILES = [
    "accelerator_core_top.sv",
    "mac_unit_40b.sv",
    "k_progress_tracker.sv",
    "slot_control_unit.sv",
    "hybrid_sram_bank.sv"
]

def run_command(cmd, desc):
    print(f"\n[EXEC] {desc}...")
    start_time = time.time()
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    duration = time.time() - start_time
    print(f"       Duration: {duration:.2f}s | Exit Code: {res.returncode}")
    if res.returncode != 0:
        print(f"[FAIL] {desc} FAILED (Exit Code {res.returncode})")
        if res.stdout:
            print("--- STDOUT ---")
            print(res.stdout[-1500:])
        if res.stderr:
            print("--- STDERR ---")
            print(res.stderr[-1500:])
        return False, res.stdout, res.stderr
    else:
        print(f"[PASS] {desc} PASSED.")
        return True, res.stdout, res.stderr

def main():
    print("=" * 80)
    print("TSK-23 MASTER UNIFIED REGRESSION & AUDIT RUNNER")
    print("=" * 80)

    # 1. Check Protected RTL Baseline Files
    print("\n--- Step 1: Checking Protected RTL Baseline Files ---")
    violated = []
    for f in PROTECTED_FILES:
        res = subprocess.run(f"git diff --exit-code {f}", shell=True, capture_output=True, text=True)
        if res.returncode != 0:
            violated.append(f)
    if violated:
        print(f"[FAIL] Protected baseline files have been modified: {violated}")
        sys.exit(1)
    else:
        print("[PASS] All 5 protected baseline RTL files are 100% UNTOUCHED.")

    all_passed = True
    test_results = []

    # 2. Run Baseline 20-Suite Regression Runner
    ok, stdout, stderr = run_command("python3 run_regression.py", "Baseline 20-Suite Regression Runner")
    test_results.append(("Baseline_20_Suites", "PASS" if ok else "FAIL"))
    if not ok: all_passed = False

    # 3. Compile and Run tb_tsk18b_reconciliation
    iverilog_cmd_18b = (
        "iverilog -g2012 -o sim_tsk18b tb_tsk18b_reconciliation.sv datapath_compute_feeder.sv "
        "mac_unit_40b.sv pe_array_40b.sv ofmap_drain_controller.sv hybrid_sram_bank.sv "
        "multibank_sram_subsystem.sv neural_acc_integrated_top.sv adaptive_pe_controller.sv "
        "layer_command_sequencer.sv ping_pong_buffer_controller.sv dma_controller.sv "
        "dma_to_sram_write_adapter.sv k_progress_tracker.sv slot_control_unit.sv "
        "memory_telemetry_monitor.sv channel_tile_controller.sv requantization_unit.sv && ./sim_tsk18b"
    )
    ok, stdout, stderr = run_command(iverilog_cmd_18b, "TSK-18B Sparse Feeder Cycle Reconciliation")
    test_results.append(("TSK18B_Cycle_Reconciliation", "PASS" if ok else "FAIL"))
    if not ok: all_passed = False

    # 4. Compile and Run tb_tsk20_memory_telemetry
    iverilog_cmd_20_telem = (
        "iverilog -g2012 -o sim_tsk20_telem tb_tsk20_memory_telemetry.sv memory_telemetry_monitor.sv "
        "multibank_sram_subsystem.sv hybrid_sram_bank.sv && ./sim_tsk20_telem"
    )
    ok, stdout, stderr = run_command(iverilog_cmd_20_telem, "TSK-20 Memory Telemetry Monitor Microbenchmarks")
    test_results.append(("TSK20_Memory_Telemetry", "PASS" if ok else "FAIL"))
    if not ok: all_passed = False

    # 5. Compile and Run tb_tsk20_memory_replay
    iverilog_cmd_20_replay = (
        "iverilog -g2012 -o sim_tsk20_replay tb_tsk20_memory_replay.sv neural_acc_integrated_top.sv "
        "datapath_compute_feeder.sv mac_unit_40b.sv pe_array_40b.sv ofmap_drain_controller.sv "
        "hybrid_sram_bank.sv multibank_sram_subsystem.sv adaptive_pe_controller.sv "
        "layer_command_sequencer.sv ping_pong_buffer_controller.sv dma_controller.sv "
        "dma_to_sram_write_adapter.sv k_progress_tracker.sv slot_control_unit.sv "
        "memory_telemetry_monitor.sv channel_tile_controller.sv requantization_unit.sv && ./sim_tsk20_replay"
    )
    ok, stdout, stderr = run_command(iverilog_cmd_20_replay, "TSK-20 Memory Replay & Bandwidth Simulation")
    test_results.append(("TSK20_Memory_Replay", "PASS" if ok else "FAIL"))
    if not ok: all_passed = False

    # 6. Run TSK-20 Memory Telemetry Audit Script
    ok, stdout, stderr = run_command("python3 audit_tsk20_telemetry.py", "TSK-20 Independent Telemetry Audit")
    test_results.append(("TSK20_Trace_Reconciliation_Audit", "PASS" if ok else "FAIL"))
    if not ok: all_passed = False

    # 7. Run TSK-21 Requantization Semantics & Tie-Breaking Audit Script
    ok, stdout, stderr = run_command("python3 audit_tsk21_requantization.py", "TSK-21 Requantization & Tie-Breaking Audit")
    test_results.append(("TSK21_Requantization_Semantics_Audit", "PASS" if ok else "FAIL"))
    if not ok: all_passed = False

    # 8. Compile and Run tb_tsk21_multipass_tiling
    iverilog_cmd_21 = (
        "iverilog -g2012 -o sim_tsk21 tb_tsk21_multipass_tiling.sv neural_acc_integrated_top.sv "
        "datapath_compute_feeder.sv mac_unit_40b.sv pe_array_40b.sv ofmap_drain_controller.sv "
        "hybrid_sram_bank.sv multibank_sram_subsystem.sv adaptive_pe_controller.sv "
        "layer_command_sequencer.sv ping_pong_buffer_controller.sv dma_controller.sv "
        "dma_to_sram_write_adapter.sv k_progress_tracker.sv slot_control_unit.sv "
        "memory_telemetry_monitor.sv channel_tile_controller.sv requantization_unit.sv && ./sim_tsk21"
    )
    ok, stdout, stderr = run_command(iverilog_cmd_21, "TSK-21 Multi-Pass Channel Tiling & Tail Tile Verification")
    test_results.append(("TSK21_MultiPass_Tiling_And_Tails", "PASS" if ok else "FAIL"))
    if not ok: all_passed = False

    # 9. Compile and Run tb_power_switching_activity
    iverilog_cmd_power = (
        "iverilog -g2012 -o sim_power tb_power_switching_activity.sv neural_acc_integrated_top.sv "
        "datapath_compute_feeder.sv mac_unit_40b.sv pe_array_40b.sv ofmap_drain_controller.sv "
        "hybrid_sram_bank.sv multibank_sram_subsystem.sv adaptive_pe_controller.sv "
        "layer_command_sequencer.sv ping_pong_buffer_controller.sv dma_controller.sv "
        "dma_to_sram_write_adapter.sv k_progress_tracker.sv slot_control_unit.sv "
        "memory_telemetry_monitor.sv channel_tile_controller.sv requantization_unit.sv && ./sim_power"
    )
    ok, stdout, stderr = run_command(iverilog_cmd_power, "TSK-22 Switching Activity VCD Generation")
    test_results.append(("TSK22_Switching_Activity_VCD", "PASS" if ok else "FAIL"))
    if not ok: all_passed = False

    # Summary
    print("\n" + "=" * 80)
    print("TSK-23 MASTER UNIFIED REGRESSION SUMMARY")
    print("=" * 80)
    for name, status in test_results:
        print(f"  {name:<40} : [{status}]")
    print("-" * 80)
    print(f"OVERALL STATUS: {'ALL SUITES PASSED' if all_passed else 'SOME SUITES FAILED'}")
    print("=" * 80)

    if not all_passed:
        sys.exit(1)
    else:
        sys.exit(0)

if __name__ == "__main__":
    main()

