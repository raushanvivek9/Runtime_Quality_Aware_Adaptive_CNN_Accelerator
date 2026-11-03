#!/usr/bin/env python3
"""
TSK-25 Independent Audit: Phase 7 - Test Reproducibility Runner
Executes all documented TSK-24 generation, simulation, analysis, and regression commands.
Records command, working directory, simulator version, duration, exit code, and log location into:
TSK25_TEST_REPRODUCIBILITY.csv
"""

import os
import sys
import time
import csv
import subprocess

AUDIT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(AUDIT_DIR)
TSK24_DIR = os.path.join(REPO_ROOT, "TSK24_REAL_CNN_VALIDATION")
RTL_DIR = os.path.join(REPO_ROOT, "phase2_step1_microarchitecture_and_rtl")

def run_step(step_name, cmd, cwd):
    print(f"\n--- Running: {step_name} ---")
    print(f"  Command: {cmd}")
    print(f"  CWD    : {cwd}")
    start_t = time.time()
    res = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    dur = time.time() - start_t
    print(f"  Duration: {dur:.2f}s | Exit Code: {res.returncode}")

    log_filename = f"log_{step_name.lower().replace(' ', '_').replace('-', '_')}.log"
    log_path = os.path.join(AUDIT_DIR, log_filename)
    with open(log_path, "w", encoding="utf-8") as f:
        f.write(f"COMMAND: {cmd}\nCWD: {cwd}\nEXIT_CODE: {res.returncode}\nDURATION: {dur:.2f}s\n\n")
        f.write("--- STDOUT ---\n")
        f.write(res.stdout)
        if res.stderr:
            f.write("\n--- STDERR ---\n")
            f.write(res.stderr)

    status = "PASS" if res.returncode == 0 else "FAIL"
    print(f"  Status  : {status} (Log: {log_filename})")
    if res.returncode != 0:
        print(f"  ERROR STDOUT:\n{res.stdout[-1000:]}")
        print(f"  ERROR STDERR:\n{res.stderr[-1000:]}")

    return {
        "Step_Name": step_name,
        "Command": cmd,
        "Working_Directory": cwd,
        "Duration_Sec": f"{dur:.2f}",
        "Exit_Code": res.returncode,
        "Log_File": log_filename,
        "Status": status
    }

def main():
    print("=" * 80)
    print("TSK-25 INDEPENDENT AUDIT: FULL REPRODUCIBILITY SUITE")
    print("=" * 80)

    py_bin = sys.executable

    steps = [
        (
            "TSK24 Workload Generation",
            f"{py_bin} generate_rtl_workloads.py",
            TSK24_DIR
        ),
        (
            "TSK24 Real CNN Simulation",
            f"{py_bin} run_tsk24_simulation.py",
            TSK24_DIR
        ),
        (
            "TSK24 Numerical Accuracy Analysis",
            f"{py_bin} analyze_numerical_accuracy.py",
            TSK24_DIR
        ),
        (
            "TSK24 Real CNN Sparsity Analysis",
            f"{py_bin} analyze_real_cnn_sparsity.py",
            TSK24_DIR
        ),
        (
            "Baseline 20-Suite RTL Regression",
            f"{py_bin} run_regression.py",
            RTL_DIR
        ),
        (
            "TSK23 Master Unified Regression (8 Suites)",
            f"{py_bin} run_tsk23_unified_regression.py",
            RTL_DIR
        )
    ]

    repro_results = []
    all_passed = True

    for step_name, cmd, cwd in steps:
        result = run_step(step_name, cmd, cwd)
        repro_results.append(result)
        if result["Exit_Code"] != 0:
            all_passed = False

    # Export TSK25_TEST_REPRODUCIBILITY.csv
    repro_csv = os.path.join(AUDIT_DIR, "TSK25_TEST_REPRODUCIBILITY.csv")
    with open(repro_csv, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(repro_results[0].keys()))
        writer.writeheader()
        writer.writerows(repro_results)
    print(f"\n[OUTPUT] Written: {repro_csv}")

    print("\n" + "=" * 80)
    if all_passed:
        print("[AUDIT RESULT: PASS] 100% of TSK-24 simulations, analyses, and system regressions reproduced cleanly.")
    else:
        print("[AUDIT RESULT: FAIL] One or more reproduction steps failed.")
    print("=" * 80)

    return all_passed

if __name__ == "__main__":
    ok = main()
    sys.exit(0 if ok else 1)

