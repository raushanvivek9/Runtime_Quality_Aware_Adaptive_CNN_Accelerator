#!/usr/bin/env python3
"""
run_tsk26c_validation.py
Hardware execution harness for TSK-26C:
1. Stages tb_tsk26c_spatial_validation.sv and 45 workload hex files into RTL directory
2. Compiles with Icarus Verilog (iverilog -g2012)
3. Executes simulation binary with vvp
4. Verifies 100% bit-exact golden match and cross-mode parity
5. Collects CSV deliverables and cleans up staged files
6. Verifies zero modifications to protected baseline files
"""

import os
import sys
import glob
import shutil
import subprocess
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
RTL_DIR = os.path.join(REPO_ROOT, "phase2_step1_microarchitecture_and_rtl")
WORKLOADS_DIR = os.path.join(SCRIPT_DIR, "workloads")

def main():
    print("=" * 80)
    print(" TSK-26C FULL SPATIAL & MULTI-LAYER HARDWARE VALIDATION RUNNER")
    print("=" * 80)

    # 1. Verify hex files
    hex_files = glob.glob(os.path.join(WORKLOADS_DIR, "*.hex"))
    print(f"\n[Step 1] Found {len(hex_files)} hex files in workloads directory.")
    if len(hex_files) < 45:
        print(f"[FAIL] Expected at least 45 hex files, found {len(hex_files)}.")
        return 1

    # 2. Stage testbench and hex files in RTL_DIR
    print("\n[Step 2] Staging testbench and hex files in RTL directory...")
    tb_src = os.path.join(SCRIPT_DIR, "tb_tsk26c_spatial_validation.sv")
    shutil.copy2(tb_src, RTL_DIR)

    staged_hex = []
    for hf in hex_files:
        bn = os.path.basename(hf)
        dest = os.path.join(RTL_DIR, bn)
        shutil.copy2(hf, dest)
        staged_hex.append(dest)
    print(f"[PASS] Staged testbench and {len(staged_hex)} hex files into {RTL_DIR}")

    # 3. Compile with iverilog
    print("\n[Step 3] Compiling tb_tsk26c_spatial_validation with iverilog...")
    iverilog_cmd = (
        "iverilog -g2012 -o sim_tsk26c tb_tsk26c_spatial_validation.sv neural_acc_integrated_top.sv "
        "datapath_compute_feeder.sv mac_unit_40b.sv pe_array_40b.sv ofmap_drain_controller.sv "
        "hybrid_sram_bank.sv multibank_sram_subsystem.sv adaptive_pe_controller.sv "
        "layer_command_sequencer.sv ping_pong_buffer_controller.sv dma_controller.sv "
        "dma_to_sram_write_adapter.sv k_progress_tracker.sv slot_control_unit.sv "
        "memory_telemetry_monitor.sv channel_tile_controller.sv requantization_unit.sv"
    )
    t0 = time.time()
    res_compile = subprocess.run(iverilog_cmd, shell=True, cwd=RTL_DIR, capture_output=True, text=True)
    compile_time = time.time() - t0
    print(f"       Compilation Duration: {compile_time:.2f}s | Exit Code: {res_compile.returncode}")
    if res_compile.returncode != 0:
        print("[FAIL] Compilation failed!")
        print("STDOUT:", res_compile.stdout)
        print("STDERR:", res_compile.stderr)
        cleanup(staged_hex, tb_src)
        return 1
    print("[PASS] Icarus Verilog compilation successful.")

    # 4. Execute simulation binary with vvp
    print("\n[Step 4] Running simulation binary (vvp sim_tsk26c)...")
    t0 = time.time()
    res_sim = subprocess.run("vvp ./sim_tsk26c", shell=True, cwd=RTL_DIR, capture_output=True, text=True)
    sim_time = time.time() - t0
    print(f"       Simulation Duration: {sim_time:.2f}s | Exit Code: {res_sim.returncode}")

    # Save log
    log_path = os.path.join(SCRIPT_DIR, "sim_output.log")
    with open(log_path, "w") as f:
        f.write(res_sim.stdout)
        if res_sim.stderr:
            f.write("\nSTDERR:\n" + res_sim.stderr)

    print(res_sim.stdout)
    if res_sim.stderr:
        print("STDERR:", res_sim.stderr)

    # 5. Collect CSV deliverables
    print("\n[Step 5] Collecting CSV deliverables...")
    csv_names = [
        "PE_MODE_PERFORMANCE.csv",
        "DENSE_SPARSE_COMPARISON.csv",
        "RTL_REFERENCE_COMPARISON.csv"
    ]
    all_collected = True
    for c in csv_names:
        src = os.path.join(RTL_DIR, c)
        dst = os.path.join(SCRIPT_DIR, c)
        if os.path.exists(src):
            shutil.copy2(src, dst)
            print(f"  [COLLECTED] {c}")
        else:
            print(f"  [MISSING] {c} in {RTL_DIR}")
            all_collected = False

    # 6. Cleanup staged files in RTL_DIR
    cleanup(staged_hex, tb_src, csv_names)

    # 7. Check Protected Baseline Files
    print("\n[Step 7] Checking protected baseline files git status...")
    res_git = subprocess.run("git diff --exit-code phase2_step1_microarchitecture_and_rtl",
                             shell=True, cwd=REPO_ROOT, capture_output=True, text=True)
    if res_git.returncode == 0:
        print("[PASS] All protected baseline files are 100% UNCHANGED (0 diffs).")
    else:
        print("[FAIL] Git diff detected in baseline RTL files!")
        print(res_git.stdout)

    if res_sim.returncode == 0 and "ALL SPATIAL FEATURE-MAP & MULTI-LAYER WORKLOADS VALIDATED" in res_sim.stdout and all_collected:
        print("\n" + "=" * 80)
        print(" TSK-26C HARDWARE SIMULATION VALIDATION: SUCCESS!")
        print("=" * 80)
        return 0
    else:
        print("\n[FAIL] Simulation encountered errors or missed assertions.")
        return 1

def cleanup(staged_hex, tb_src, csv_names=None):
    print("\n[Cleanup] Removing temporary staged files from RTL directory...")
    for f in staged_hex:
        if os.path.exists(f):
            os.remove(f)
    tb_in_rtl = os.path.join(RTL_DIR, "tb_tsk26c_spatial_validation.sv")
    if os.path.exists(tb_in_rtl):
        os.remove(tb_in_rtl)
    sim_bin = os.path.join(RTL_DIR, "sim_tsk26c")
    if os.path.exists(sim_bin):
        os.remove(sim_bin)
    if csv_names:
        for c in csv_names:
            p = os.path.join(RTL_DIR, c)
            if os.path.exists(p):
                os.remove(p)
    print("[PASS] Cleanup complete.")

if __name__ == "__main__":
    sys.exit(main())

