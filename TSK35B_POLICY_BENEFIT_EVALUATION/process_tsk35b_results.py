#!/usr/bin/env python3
"""
process_tsk35b_results.py
Analyzes the measured simulation results from tb_tsk35b_policy_benefit.sv:
- TSK35B_ALL_SCENARIOS_MEASURED.csv (560 policy evaluation records)
- TSK35B_BASELINE_MEASURED.csv (24 fixed baseline records)

Generates:
- TSK35B_POLICY_BENEFIT_SUMMARY.csv
- TSK35B_POLICY_DECISION_DISTRIBUTION.csv
- TSK35B_SPARSITY_VS_DENSE.csv
- TSK35B_SRAM_TRAFFIC_ANALYSIS.csv
- In-depth numerical tables answering all 7 questions from Phase 4
"""

import os
import pandas as pd
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ALL_SCENARIOS_CSV = os.path.join(SCRIPT_DIR, "TSK35B_ALL_SCENARIOS_MEASURED.csv")
BASELINE_CSV = os.path.join(SCRIPT_DIR, "TSK35B_BASELINE_MEASURED.csv")

def main():
    if not os.path.exists(ALL_SCENARIOS_CSV) or not os.path.exists(BASELINE_CSV):
        print(f"Waiting for simulation to finish. Files not ready.")
        return

    df_scenarios = pd.read_csv(ALL_SCENARIOS_CSV)
    df_baseline = pd.read_csv(BASELINE_CSV)

    print(f"Loaded {len(df_scenarios)} policy scenarios.")
    print(f"Loaded {len(df_baseline)} baseline measurements.")

    # -------------------------------------------------------------------------
    # Analysis 1: Mode Selection Distribution across Policies
    # -------------------------------------------------------------------------
    dist_list = []
    for pol_name, group in df_scenarios.groupby("Policy_Name"):
        total_evals = len(group)
        counts = group["Resolved_Mode_Name"].value_counts()
        for mode_name, cnt in counts.items():
            pct = (cnt / total_evals) * 100.0
            dist_list.append({
                "Policy_Name": pol_name,
                "Selected_Mode": mode_name,
                "Count": cnt,
                "Total_Evaluations": total_evals,
                "Percentage": round(pct, 2)
            })

    df_dist = pd.DataFrame(dist_list)
    df_dist.to_csv(os.path.join(SCRIPT_DIR, "TSK35B_POLICY_DECISION_DISTRIBUTION.csv"), index=False)
    print("\n=== Mode Selection Distribution ===")
    print(df_dist.to_string(index=False))

    # -------------------------------------------------------------------------
    # Analysis 2: Budget Violation Rates
    # -------------------------------------------------------------------------
    viol_list = []
    for pol_name, group in df_scenarios.groupby("Policy_Name"):
        # Exclude invalid PE limits where execution is safely blocked
        valid_group = group[group["Requested_PE_Cap"] >= 16]
        total_valid = len(valid_group)
        viol_count = int(valid_group["Budget_Violation"].sum())
        viol_pct = (viol_count / total_valid) * 100.0 if total_valid > 0 else 0.0

        fallback_count = int(valid_group["Fallback_Asserted"].sum())
        fallback_pct = (fallback_count / total_valid) * 100.0 if total_valid > 0 else 0.0

        viol_list.append({
            "Policy_Name": pol_name,
            "Total_Valid_Evaluations": total_valid,
            "Budget_Violations": viol_count,
            "Budget_Violation_Pct": round(viol_pct, 2),
            "Fallback_Asserted_Count": fallback_count,
            "Fallback_Asserted_Pct": round(fallback_pct, 2)
        })
    df_viol = pd.DataFrame(viol_list)
    print("\n=== Latency Budget Violations & Fallbacks (Valid Pmax >= 16) ===")
    print(df_viol.to_string(index=False))

    # -------------------------------------------------------------------------
    # Analysis 3: Dense vs Sparse Execution Comparison
    # -------------------------------------------------------------------------
    sparse_comp_list = []
    for wl_id in ["WL1", "WL2", "WL3", "WL4"]:
        wl_base = df_baseline[df_baseline["Workload_ID"] == wl_id]
        for mode in ["16-PE", "32-PE", "64-PE"]:
            dense_row = wl_base[(wl_base["PE_Mode"] == mode) & (wl_base["Regime"] == "Dense")].iloc[0]
            sparse_row = wl_base[(wl_base["PE_Mode"] == mode) & (wl_base["Regime"] == "Sparse")].iloc[0]

            dense_tot_cycles = dense_row["Total_Execution_Cycles"]
            sparse_tot_cycles = sparse_row["Total_Execution_Cycles"]
            cycle_delta_pct = ((dense_tot_cycles - sparse_tot_cycles) / dense_tot_cycles) * 100.0

            dense_comp_cycles = dense_row["Compute_Cycles"]
            sparse_comp_cycles = sparse_row["Compute_Cycles"]
            comp_delta_pct = ((dense_comp_cycles - sparse_comp_cycles) / dense_comp_cycles) * 100.0

            dense_wt_reads = dense_row["Weight_SRAM_Reads"]
            sparse_wt_reads = sparse_row["Weight_SRAM_Reads"]
            wt_read_delta_pct = ((dense_wt_reads - sparse_wt_reads) / dense_wt_reads) * 100.0

            sparse_comp_list.append({
                "Workload_ID": wl_id,
                "PE_Mode": mode,
                "Dense_Total_Cycles": dense_tot_cycles,
                "Sparse_Total_Cycles": sparse_tot_cycles,
                "Total_Cycle_Reduction_Pct": round(cycle_delta_pct, 2),
                "Dense_Compute_Cycles": dense_comp_cycles,
                "Sparse_Compute_Cycles": sparse_comp_cycles,
                "Compute_Cycle_Reduction_Pct": round(comp_delta_pct, 2),
                "Dense_Wt_SRAM_Reads": dense_wt_reads,
                "Sparse_Wt_SRAM_Reads": sparse_wt_reads,
                "Wt_SRAM_Read_Reduction_Pct": round(wt_read_delta_pct, 2)
            })

    df_sparse_comp = pd.DataFrame(sparse_comp_list)
    df_sparse_comp.to_csv(os.path.join(SCRIPT_DIR, "TSK35B_SPARSITY_VS_DENSE.csv"), index=False)
    print("\n=== Sparsity vs Dense Impact ===")
    print(df_sparse_comp.to_string(index=False))

    # -------------------------------------------------------------------------
    # Analysis 4: SRAM Access Penalty across PE Modes
    # -------------------------------------------------------------------------
    sram_traffic_list = []
    for wl_id in ["WL1", "WL2", "WL3", "WL4"]:
        wl_base = df_baseline[(df_baseline["Workload_ID"] == wl_id) & (df_baseline["Regime"] == "Sparse")]
        base_64 = wl_base[wl_base["PE_Mode"] == "64-PE"].iloc[0]
        ref_act_reads = base_64["Activation_SRAM_Reads"]
        ref_tot_accesses = base_64["Total_SRAM_Accesses"]

        for mode in ["16-PE", "32-PE", "64-PE"]:
            cur_row = wl_base[wl_base["PE_Mode"] == mode].iloc[0]
            cur_act_reads = cur_row["Activation_SRAM_Reads"]
            cur_wt_reads = cur_row["Weight_SRAM_Reads"]
            cur_writes = cur_row["SRAM_Writes"]
            cur_tot_accesses = cur_row["Total_SRAM_Accesses"]

            act_increase_pct = ((cur_act_reads - ref_act_reads) / ref_act_reads) * 100.0
            tot_increase_pct = ((cur_tot_accesses - ref_tot_accesses) / ref_tot_accesses) * 100.0

            sram_traffic_list.append({
                "Workload_ID": wl_id,
                "PE_Mode": mode,
                "Channel_Passes": 4 if mode == "16-PE" else (2 if mode == "32-PE" else 1),
                "Act_SRAM_Reads": cur_act_reads,
                "Act_Read_Increase_vs_64PE_Pct": round(act_increase_pct, 2),
                "Wt_SRAM_Reads": cur_wt_reads,
                "SRAM_Writes": cur_writes,
                "Total_SRAM_Accesses": cur_tot_accesses,
                "Total_Access_Increase_vs_64PE_Pct": round(tot_increase_pct, 2)
            })

    df_sram_traffic = pd.DataFrame(sram_traffic_list)
    df_sram_traffic.to_csv(os.path.join(SCRIPT_DIR, "TSK35B_SRAM_TRAFFIC_ANALYSIS.csv"), index=False)
    print("\n=== SRAM Traffic Analysis (Sparse Regime) ===")
    print(df_sram_traffic.to_string(index=False))

    # -------------------------------------------------------------------------
    # Analysis 5: Policy A vs Policy B Cross-Comparison
    # -------------------------------------------------------------------------
    summary_list = []
    # Match pairs of (Workload, Budget, Cap)
    grouped = df_scenarios.groupby(["Workload_ID", "Requested_Latency_Budget", "Requested_PE_Cap"])
    for (wl_id, budget, cap), group in grouped:
        pol_a = group[group["Policy_Name"] == "Policy_A"].iloc[0]
        pol_b = group[group["Policy_Name"] == "Policy_B"].iloc[0]

        summary_list.append({
            "Workload_ID": wl_id,
            "Latency_Budget": budget,
            "PE_Cap": cap,
            "Policy_A_Mode": pol_a["Resolved_Mode_Name"],
            "Policy_A_Active_PEs": pol_a["Active_PE_Count"],
            "Policy_A_Cycles": pol_a["Measured_Total_Cycles"],
            "Policy_A_Viol": pol_a["Budget_Violation"],
            "Policy_B_Mode": pol_b["Resolved_Mode_Name"],
            "Policy_B_Active_PEs": pol_b["Active_PE_Count"],
            "Policy_B_Cycles": pol_b["Measured_Total_Cycles"],
            "Policy_B_Viol": pol_b["Budget_Violation"],
            "PE_Savings_A_vs_B_Pct": round(((pol_b["Active_PE_Count"] - pol_a["Active_PE_Count"]) / max(1, pol_b["Active_PE_Count"])) * 100.0, 1) if pol_b["Active_PE_Count"] > 0 else 0.0,
            "Speedup_B_vs_A": round(pol_a["Measured_Total_Cycles"] / max(1, pol_b["Measured_Total_Cycles"]), 4) if pol_b["Measured_Total_Cycles"] > 0 else 1.0
        })

    df_summary = pd.DataFrame(summary_list)
    df_summary.to_csv(os.path.join(SCRIPT_DIR, "TSK35B_POLICY_BENEFIT_SUMMARY.csv"), index=False)
    print(f"\n[SUCCESS] Generated TSK35B_POLICY_BENEFIT_SUMMARY.csv with {len(df_summary)} rows.")

if __name__ == "__main__":
    main()

