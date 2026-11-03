#!/usr/bin/env python3
"""
================================================================================
Project: Neural_Acc (Phase 2 RTL Implementation & Research Evaluation)
Task: TSK-17 CNN Sparsity-Aware Resource Allocation Feasibility Study
Module: validate_tsk17_results.py
Description: Validates schemas, numeric constraints, and ranges for:
             - TSK17_LAYER_WORKLOADS.csv
             - TSK17_RESOURCE_ALLOCATION_ANALYSIS.csv
================================================================================
"""

import sys
import csv
from pathlib import Path
from typing import Dict, List, Any, Tuple

WORKSPACE_ROOT = Path(__file__).resolve().parent

WORKLOADS_CSV = WORKSPACE_ROOT / "TSK17_LAYER_WORKLOADS.csv"
ANALYSIS_CSV = WORKSPACE_ROOT / "TSK17_RESOURCE_ALLOCATION_ANALYSIS.csv"


def validate_workloads_csv() -> Tuple[bool, str, Dict[str, Any]]:
    if not WORKLOADS_CSV.exists():
        return False, f"File not found: {WORKLOADS_CSV.name}", {}

    expected_fields = [
        "workload_id", "layer_index", "layer_name", "network_stage",
        "input_dimensions", "output_dimensions", "kernel_geometry",
        "stride", "padding", "dense_mac_count", "exact_zero_activation_count",
        "total_activation_elements", "activation_sparsity_percent",
        "useful_mac_count", "skipped_mac_count", "mac_reduction_percent",
        "data_source", "checkpoint_dependency_status"
    ]

    stats = {"total_rows": 0, "workloads": set(), "stages": set(), "max_sparsity": 0.0, "min_sparsity": 100.0}

    with open(WORKLOADS_CSV, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != expected_fields:
            return False, f"Field mismatch in {WORKLOADS_CSV.name}. Got: {reader.fieldnames}", {}

        for idx, row in enumerate(reader):
            stats["total_rows"] += 1
            stats["workloads"].add(row["workload_id"])
            stats["stages"].add(row["network_stage"])

            try:
                dense = int(row["dense_mac_count"])
                useful = int(row["useful_mac_count"])
                skipped = int(row["skipped_mac_count"])
                sparsity = float(row["activation_sparsity_percent"])
                reduction = float(row["mac_reduction_percent"])

                if dense <= 0 or useful < 0 or skipped < 0:
                    return False, f"Row {idx+1}: Invalid non-positive MAC counts", {}
                if useful + skipped != dense:
                    return False, f"Row {idx+1}: useful ({useful}) + skipped ({skipped}) != dense ({dense})", {}
                if not (0.0 <= sparsity <= 100.0):
                    return False, f"Row {idx+1}: Sparsity out of range: {sparsity}", {}
                if not (0.0 <= reduction <= 100.0):
                    return False, f"Row {idx+1}: Reduction out of range: {reduction}", {}

                stats["max_sparsity"] = max(stats["max_sparsity"], sparsity)
                stats["min_sparsity"] = min(stats["min_sparsity"], sparsity)
            except ValueError as e:
                return False, f"Row {idx+1}: Numeric parse error: {e}", {}

    return True, f"Workloads CSV validated successfully ({stats['total_rows']} rows).", stats


def validate_analysis_csv() -> Tuple[bool, str, Dict[str, Any]]:
    if not ANALYSIS_CSV.exists():
        return False, f"File not found: {ANALYSIS_CSV.name}", {}

    expected_fields = [
        "workload_id", "layer_index", "layer_name", "activation_sparsity_percent",
        "baseline_cycles_fixed64_dense", "sparse_cycles_fixed64",
        "sparse_cycles_fixed32", "sparse_cycles_fixed16", "feasible_16pe",
        "feasible_32pe", "feasible_64pe", "selected_pe_adaptive",
        "selected_cycles", "pe_count_reduction_percent",
        "cycle_saving_vs_dense64_percent", "preserves_full_output_tensor",
        "rtl_zero_skipping_cycle_benefit", "rtl_dynamic_power_benefit",
        "channel_pruning_accuracy_impact"
    ]

    stats = {"total_rows": 0, "selected_pes": {"16-PE": 0, "32-PE": 0, "64-PE": 0}}

    with open(ANALYSIS_CSV, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != expected_fields:
            return False, f"Field mismatch in {ANALYSIS_CSV.name}. Got: {reader.fieldnames}", {}

        for idx, row in enumerate(reader):
            stats["total_rows"] += 1
            pe = row["selected_pe_adaptive"]
            if pe in stats["selected_pes"]:
                stats["selected_pes"][pe] += 1

            try:
                c_dense = int(row["baseline_cycles_fixed64_dense"])
                c_sel = int(row["selected_cycles"])
                c_16 = int(row["sparse_cycles_fixed16"])
                c_32 = int(row["sparse_cycles_fixed32"])
                c_64 = int(row["sparse_cycles_fixed64"])

                if c_dense <= 0 or c_sel <= 0:
                    return False, f"Row {idx+1}: Non-positive cycle counts", {}
                if c_64 > c_dense:
                    return False, f"Row {idx+1}: Sparse 64 cycles ({c_64}) > Dense 64 cycles ({c_dense})", {}
                if row["feasible_16pe"] == "YES" and c_16 > c_dense:
                    return False, f"Row {idx+1}: Feasible 16 asserted but c_16 ({c_16}) > c_dense ({c_dense})", {}
            except ValueError as e:
                return False, f"Row {idx+1}: Numeric parse error: {e}", {}

    return True, f"Analysis CSV validated successfully ({stats['total_rows']} rows).", stats


def main():
    print("=" * 80)
    print("TSK-17: Validation of Sparsity-Aware Allocation Datasets")
    print("=" * 80)

    all_passed = True

    p1, m1, s1 = validate_workloads_csv()
    status1 = "[PASS]" if p1 else "[FAIL]"
    print(f"{status1} {m1}")
    if p1:
        print(f"       Workloads: {sorted(list(s1['workloads']))}")
        print(f"       Sparsity Range: {s1['min_sparsity']:.2f}% to {s1['max_sparsity']:.2f}%")
        print(f"       Network Stages: {sorted(list(s1['stages']))}")
    else:
        all_passed = False

    p2, m2, s2 = validate_analysis_csv()
    status2 = "[PASS]" if p2 else "[FAIL]"
    print(f"{status2} {m2}")
    if p2:
        print(f"       Adaptive PE Distribution: {s2['selected_pes']}")
    else:
        all_passed = False

    print("=" * 80)
    if all_passed:
        print("ALL TSK-17 DATASETS STRICTLY VALIDATED.")
        sys.exit(0)
    else:
        print("VALIDATION FAILED ON ONE OR MORE DATASETS.")
        sys.exit(1)


if __name__ == "__main__":
    main()

