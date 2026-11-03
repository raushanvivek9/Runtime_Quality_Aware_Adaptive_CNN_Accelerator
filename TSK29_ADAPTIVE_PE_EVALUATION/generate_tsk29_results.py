#!/usr/bin/env python3
import pandas as pd
import numpy as np
import os

script_dir = os.path.dirname(os.path.abspath(__file__))
raw_csv = os.path.join(script_dir, "TSK29_RAW_METRICS.csv")
out_csv = os.path.join(script_dir, "TSK29_RESULTS.csv")

df = pd.read_csv(raw_csv)

# Baseline references:
# Baseline 1: Fixed 64-PE Dense (Config 5)
base_64_cycles = df.loc[df['Config_Name'] == 'Fixed_64PE_Dense', 'Total_Cycles'].values[0]
base_64_compute = df.loc[df['Config_Name'] == 'Fixed_64PE_Dense', 'Compute_Cycles'].values[0]
base_64_wt_reads = df.loc[df['Config_Name'] == 'Fixed_64PE_Dense', 'SRAM_Wt_Reads'].values[0]

# Baseline 2: Fixed 32-PE Dense (Config 3)
base_32_cycles = df.loc[df['Config_Name'] == 'Fixed_32PE_Dense', 'Total_Cycles'].values[0]

results = []
for idx, row in df.iterrows():
    tot_cycles = row['Total_Cycles']
    comp_cycles = row['Compute_Cycles']
    wt_reads = row['SRAM_Wt_Reads']
    act_reads = row['SRAM_Act_Reads']
    total_sram_reads = act_reads + wt_reads

    # Relative to 64-PE Dense
    cycle_ratio_vs_64 = tot_cycles / base_64_cycles
    speedup_vs_64 = base_64_cycles / tot_cycles

    # Relative to 32-PE Dense
    cycle_ratio_vs_32 = tot_cycles / base_32_cycles

    # Sparsity savings within mode (Dense vs Sparse)
    if 'Dense' in row['Config_Name']:
        sparse_savings_pct = 0.0
    else:
        sparse_savings_pct = ((147456 - wt_reads) / 147456.0) * 100.0

    # PE Hardware reduction relative to 64 PEs
    pe_saving_pct = ((64 - row['Active_PEs']) / 64.0) * 100.0

    results.append({
        "Config_ID": row['Config_ID'],
        "Config_Name": row['Config_Name'],
        "PE_Allocation": f"{row['Active_PEs']}-PE",
        "Sparse_Enabled": row['Sparse_En'],
        "Adaptive_Enabled": row['Adaptive_En'],
        "Total_Execution_Cycles": tot_cycles,
        "Compute_Cycles": comp_cycles,
        "Overhead_Cycles": row['Overhead_Cycles'],
        "Latency_Ratio_vs_64PE_Dense": round(cycle_ratio_vs_64, 4),
        "Throughput_Relative_to_64PE": round(speedup_vs_64, 4),
        "Latency_Ratio_vs_32PE_Dense": round(cycle_ratio_vs_32, 4),
        "Total_SRAM_Reads": total_sram_reads,
        "Weight_SRAM_Reads": wt_reads,
        "SRAM_Weight_Read_Reduction_Pct": round(sparse_savings_pct, 2),
        "Active_PE_Hardware_Reduction_Pct": round(pe_saving_pct, 2),
        "Numerical_Mismatches": row['Mismatches'],
        "Correctness_Status": row['Status']
    })

res_df = pd.DataFrame(results)
res_df.to_csv(out_csv, index=False)
print(f"[PASS] Successfully generated {out_csv}")
print(res_df.to_string(index=False))

