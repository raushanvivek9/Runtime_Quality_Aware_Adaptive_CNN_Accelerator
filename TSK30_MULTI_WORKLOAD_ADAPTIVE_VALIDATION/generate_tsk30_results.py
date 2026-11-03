#!/usr/bin/env python3
"""
generate_tsk30_results.py
Consolidates raw RTL simulation metrics from RAW_METRICS.csv, computes
cross-mode comparisons, SRAM traffic reduction percentages, and PE utilization,
and writes TSK30_RESULTS.csv.
"""

import os
import pandas as pd
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_METRICS_PATH = os.path.join(SCRIPT_DIR, "RAW_METRICS.csv")
RESULTS_PATH = os.path.join(SCRIPT_DIR, "TSK30_RESULTS.csv")

def main():
    if not os.path.exists(RAW_METRICS_PATH):
        print(f"Error: {RAW_METRICS_PATH} does not exist.")
        return

    df = pd.read_csv(RAW_METRICS_PATH)
    print(f"Loaded {len(df)} configurations from RAW_METRICS.csv")

    results = []

    # Process each workload group
    for wl_id, wl_group in df.groupby("Workload_ID"):
        # Find 64PE dense baseline for this workload
        base_64_dense = wl_group[wl_group["Config_Name"].str.contains("Fixed_64PE_Dense")]
        base_32_dense = wl_group[wl_group["Config_Name"].str.contains("Fixed_32PE_Dense")]

        if len(base_64_dense) == 0:
            print(f"Warning: No 64PE dense baseline found for {wl_id}")
            continue

        base_cycles_64 = float(base_64_dense["Total_Cycles"].values[0])
        base_wt_reads = float(base_64_dense["Wt_SRAM_Reads"].values[0])

        for _, row in wl_group.iterrows():
            total_cycles = float(row["Total_Cycles"])
            compute_cycles = float(row["Compute_Cycles"])
            overhead_cycles = float(row["Overhead_Cycles"])
            act_reads = float(row["Act_SRAM_Reads"])
            wt_reads = float(row["Wt_SRAM_Reads"])
            total_sram_reads = act_reads + wt_reads
            active_pes = int(row["Active_PEs"])
            mismatches = int(row["Mismatches"])

            latency_ratio_vs_64pe = round(total_cycles / base_cycles_64, 4)
            throughput_rel_to_64pe = round(base_cycles_64 / total_cycles, 4)

            wt_sram_reduction_pct = round(((base_wt_reads - wt_reads) / base_wt_reads) * 100.0, 2)
            active_pe_reduction_pct = round(((64 - active_pes) / 64) * 100.0, 1)

            results.append({
                "Config_ID": int(row["Config_ID"]),
                "Workload_ID": wl_id,
                "Config_Name": row["Config_Name"],
                "PE_Allocation": f"{active_pes}-PE" if row["Adaptive_En"] == 0 else f"Adaptive ({active_pes}-PE)",
                "Active_PEs": active_pes,
                "Passes": int(row["Passes"]),
                "Sparse_Enabled": int(row["Sparse_En"]),
                "Adaptive_Enabled": int(row["Adaptive_En"]),
                "Total_Execution_Cycles": int(total_cycles),
                "Compute_Cycles": int(compute_cycles),
                "Overhead_Cycles": int(overhead_cycles),
                "Latency_Ratio_vs_64PE_Dense": latency_ratio_vs_64pe,
                "Throughput_Relative_to_64PE": throughput_rel_to_64pe,
                "Total_SRAM_Reads": int(total_sram_reads),
                "Weight_SRAM_Reads": int(wt_reads),
                "SRAM_Weight_Read_Reduction_Pct": wt_sram_reduction_pct,
                "Active_PE_Hardware_Reduction_Pct": active_pe_reduction_pct,
                "PE_Utilization_Pct": round(float(row["PE_Utilization_Pct"]), 2),
                "Numerical_Mismatches": mismatches,
                "Correctness_Status": "PASS" if mismatches == 0 else "FAIL"
            })

    df_out = pd.DataFrame(results)
    df_out.sort_values(by="Config_ID", inplace=True)
    df_out.to_csv(RESULTS_PATH, index=False)
    print(f"[SUCCESS] TSK30_RESULTS.csv written with {len(df_out)} rows.")

if __name__ == "__main__":
    main()

