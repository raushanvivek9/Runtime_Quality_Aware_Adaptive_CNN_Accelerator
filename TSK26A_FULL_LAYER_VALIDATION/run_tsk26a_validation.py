#!/usr/bin/env python3
"""
Project: Neural_Acc (Phase 2 RTL Implementation)
Task: TSK-26A Complete Spatial Feature-Map Validation
Module: run_tsk26a_validation.py
Description: Compiles and executes tb_tsk26a_full_layer_validation using iverilog/vvp,
             verifies assertion results, and collects output CSV files.
"""

import os
import sys
import shutil
import subprocess
import time
import glob

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(BASE_DIR)
RTL_DIR = os.path.join(REPO_ROOT, "phase2_step1_microarchitecture_and_rtl")

def main():
    print("=" * 80)
    print("TSK-26A FULL SPATIAL LAYER VALIDATION RUNNER")
    print("=" * 80)

    # 1. Verify / generate spatial tiles and hex files
    print("\n--- Step 1: Checking Workload Datasets and Hex Files ---")
    hex_files = glob.glob(os.path.join(BASE_DIR, "*.hex"))
    if len(hex_files) < 12:
        print("[INFO] Hex files missing or incomplete. Generating via generate_spatial_tiles.py...")
        gen_script = os.path.join(BASE_DIR, "generate_spatial_tiles.py")
        res = subprocess.run([sys.executable, gen_script], cwd=BASE_DIR, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"[FAIL] generate_spatial_tiles.py failed with exit code {res.returncode}")
            print("STDOUT:", res.stdout)
            print("STDERR:", res.stderr)
            return False
        hex_files = glob.glob(os.path.join(BASE_DIR, "*.hex"))
    print(f"[PASS] Found {len(hex_files)} hex files ready for simulation.")

    # Copy tb_tsk26a_full_layer_validation.sv and all .hex files into RTL_DIR
    print("\n--- Step 2: Staging Testbench and Hex Files in RTL Directory ---")
    tb_src = os.path.join(BASE_DIR, "tb_tsk26a_full_layer_validation.sv")
    shutil.copy2(tb_src, RTL_DIR)
    
    copied_hex_basenames = []
    for hf in hex_files:
        bn = os.path.basename(hf)
        shutil.copy2(hf, RTL_DIR)
        copied_hex_basenames.append(bn)
    print(f"[PASS] Staged testbench and {len(copied_hex_basenames)} hex files into RTL directory.")

    # 2. Compile with iverilog
    print("\n--- Step 3: Compiling tb_tsk26a_full_layer_validation with iverilog ---")
    iverilog_cmd = (
        "iverilog -g2012 -o sim_tsk26a tb_tsk26a_full_layer_validation.sv neural_acc_integrated_top.sv "
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
    print("\n--- Step 4: Running Simulation Binary (vvp sim_tsk26a) ---")
    print("       Note: Simulating 16 spatial tiles (64-PE, 32-PE 2-pass, 16-PE 4-pass) + 10 boundary tests...")
    start_t = time.time()
    res = subprocess.run("./sim_tsk26a", shell=True, cwd=RTL_DIR, capture_output=True, text=True)
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
        if res.stdout: print("STDOUT:", res.stdout[-3000:])
        if res.stderr: print("STDERR:", res.stderr[-3000:])
        return False

    print("\n--- Simulation Output Tail ---")
    print("\n".join(res.stdout.splitlines()[-40:]))

    # 4. Copy generated CSV deliverables from RTL_DIR to BASE_DIR and REPO_ROOT
    csv_deliverables = [
        "TSK26A_NUMERICAL_RESULTS.csv",
        "TSK26A_CROSS_MODE_RESULTS.csv",
        "TSK26A_PERFORMANCE_RESULTS.csv",
        "TSK26A_TEST_RESULTS.csv"
    ]

    print("\n--- Step 5: Collecting CSV Deliverables ---")
    all_csv_present = True
    for csv_file in csv_deliverables:
        src = os.path.join(RTL_DIR, csv_file)
        if os.path.exists(src):
            shutil.copy2(src, BASE_DIR)
            shutil.copy2(src, REPO_ROOT)
            print(f"[PASS] Successfully collected {csv_file}")
        else:
            print(f"[FAIL] Missing expected deliverable {csv_file} in {RTL_DIR}")
            all_csv_present = False

    # 5. Clean up staged hex files and binary in RTL_DIR to keep git clean
    print("\n--- Step 6: Cleaning up Staged Files in RTL Directory ---")
    for bn in copied_hex_basenames:
        p = os.path.join(RTL_DIR, bn)
        if os.path.exists(p):
            os.remove(p)
    tb_in_rtl = os.path.join(RTL_DIR, "tb_tsk26a_full_layer_validation.sv")
    if os.path.exists(tb_in_rtl):
        os.remove(tb_in_rtl)
    sim_bin = os.path.join(RTL_DIR, "sim_tsk26a")
    if os.path.exists(sim_bin):
        os.remove(sim_bin)
    for csv_file in csv_deliverables:
        p = os.path.join(RTL_DIR, csv_file)
        if os.path.exists(p):
            os.remove(p)
    print("[PASS] Cleaned up staged temporary files.")

    if not all_csv_present:
        return False

    if "ALL TESTS PASSED" in res.stdout:
        print("\n[RESULT: SUCCESS] All TSK-26A Spatial Validation Tests Passed with 0 Failures!")
        return True
    else:
        print("\n[FAIL] 'ALL TESTS PASSED' banner not detected in simulation output.")
        return False

if __name__ == "__main__":
    ok = main()
    sys.exit(0 if ok else 1)

