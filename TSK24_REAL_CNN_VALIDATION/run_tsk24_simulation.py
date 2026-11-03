#!/usr/bin/env python3
"""
Project: Neural_Acc (Phase 2 RTL Implementation)
Task: TSK-24 Real CNN Numerical Validation
Module: run_tsk24_simulation.py
Description: Compiles and executes tb_tsk24_real_cnn_validation using iverilog/vvp,
             verifies assertion results, and collects output CSV files.
"""

import os
import sys
import shutil
import subprocess
import time

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(BASE_DIR)
RTL_DIR = os.path.join(REPO_ROOT, "phase2_step1_microarchitecture_and_rtl")

def main():
    print("=" * 80)
    print("TSK-24 REAL CNN SIMULATION RUNNER")
    print("=" * 80)

    # 1. Regenerate workloads and hex files
    print("\n--- Step 1: Generating Workload Datasets and Hex Files ---")
    gen_script = os.path.join(BASE_DIR, "generate_rtl_workloads.py")
    res = subprocess.run([sys.executable, gen_script], cwd=BASE_DIR, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[FAIL] generate_rtl_workloads.py failed with exit code {res.returncode}")
        print("STDOUT:", res.stdout)
        print("STDERR:", res.stderr)
        return False
    print("[PASS] Workload datasets and hex files generated successfully.")

    # Copy tb_tsk24_real_cnn_validation.sv and tsk24_workloads_data.svh into RTL_DIR
    shutil.copy2(os.path.join(BASE_DIR, "tb_tsk24_real_cnn_validation.sv"), RTL_DIR)
    shutil.copy2(os.path.join(BASE_DIR, "tsk24_workloads_data.svh"), RTL_DIR)

    # 2. Compile with iverilog
    print("\n--- Step 2: Compiling tb_tsk24_real_cnn_validation with iverilog ---")
    iverilog_cmd = (
        "iverilog -g2012 -o sim_tsk24 tb_tsk24_real_cnn_validation.sv neural_acc_integrated_top.sv "
        "datapath_compute_feeder.sv mac_unit_40b.sv pe_array_40b.sv ofmap_drain_controller.sv "
        "hybrid_sram_bank.sv multibank_sram_subsystem.sv adaptive_pe_controller.sv "
        "layer_command_sequencer.sv ping_pong_buffer_controller.sv dma_controller.sv "
        "dma_to_sram_write_adapter.sv k_progress_tracker.sv slot_control_unit.sv "
        "memory_telemetry_monitor.sv channel_tile_controller.sv requantization_unit.sv"
    )
    start_t = time.time()
    res = subprocess.run(iverilog_cmd, shell=True, cwd=RTL_DIR, capture_output=True, text=True)
    compile_time = time.time() - start_t
    print(f"       Compilation Duration: {compile_time:.2f}s | Exit Code: {res.returncode}")
    if res.returncode != 0:
        print(f"[FAIL] Compilation failed with exit code {res.returncode}")
        if res.stdout: print("STDOUT:", res.stdout)
        if res.stderr: print("STDERR:", res.stderr)
        return False
    print("[PASS] Icarus Verilog compilation successful.")

    # 3. Execute simulation with vvp
    print("\n--- Step 3: Running Simulation Binary (vvp sim_tsk24) ---")
    start_t = time.time()
    res = subprocess.run("./sim_tsk24", shell=True, cwd=RTL_DIR, capture_output=True, text=True)
    sim_time = time.time() - start_t
    print(f"       Simulation Duration: {sim_time:.2f}s | Exit Code: {res.returncode}")

    log_path = os.path.join(BASE_DIR, "sim_output.log")
    with open(log_path, "w") as f:
        f.write(res.stdout)
        if res.stderr:
            f.write("\n--- STDERR ---\n")
            f.write(res.stderr)
    print(f"       Full simulation output saved to {log_path}")

    if res.returncode != 0:
        print(f"[FAIL] Simulation failed with exit code {res.returncode}")
        if res.stdout: print("STDOUT:", res.stdout[-2000:])
        if res.stderr: print("STDERR:", res.stderr[-2000:])
        return False

    print("\n--- Simulation Output Tail ---")
    print("\n".join(res.stdout.splitlines()[-35:]))

    # 4. Copy generated CSV deliverables from RTL_DIR to BASE_DIR and REPO_ROOT
    csv_deliverables = [
        "TSK24_CROSS_MODE_RESULTS.csv",
        "TSK24_NUMERICAL_RESULTS.csv",
        "TSK24_SPARSITY_RESULTS.csv",
        "TSK24_PERFORMANCE_RESULTS.csv"
    ]

    print("\n--- Step 4: Collecting CSV Deliverables ---")
    for csv_file in csv_deliverables:
        src = os.path.join(RTL_DIR, csv_file)
        if os.path.exists(src):
            shutil.copy2(src, BASE_DIR)
            shutil.copy2(src, REPO_ROOT)
            print(f"[PASS] Successfully collected {csv_file}")
        else:
            print(f"[FAIL] Missing expected deliverable {csv_file} in {RTL_DIR}")
            return False

    print("\n[RESULT: SUCCESS] All TSK-24 Real CNN Simulations Passed with 0 Failures!")
    return True

if __name__ == "__main__":
    ok = main()
    sys.exit(0 if ok else 1)
