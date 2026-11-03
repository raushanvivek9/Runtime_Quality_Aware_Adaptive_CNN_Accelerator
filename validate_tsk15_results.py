#!/usr/bin/env python3
"""
================================================================================
Project: Neural_Acc (Phase 2 RTL Implementation & Research Evaluation)
Task: TSK-15 Real CNN Quality-Constrained Adaptive PE Selection
Module: validate_tsk15_results.py
Description: Validates CSV schemas, types, ranges, constraints, and generates
             statistical summaries for:
             - TSK15_QUALITY_RESULTS.csv
             - TSK15_ADAPTIVE_SELECTION_RESULTS.csv
             - TSK15_RESOURCE_METRICS.csv
================================================================================
"""

import sys
import csv
from pathlib import Path
from typing import Dict, List, Any, Tuple

WORKSPACE_ROOT = Path(__file__).resolve().parent

QUALITY_CSV = WORKSPACE_ROOT / "TSK15_QUALITY_RESULTS.csv"
ADAPTIVE_CSV = WORKSPACE_ROOT / "TSK15_ADAPTIVE_SELECTION_RESULTS.csv"
RESOURCE_CSV = WORKSPACE_ROOT / "TSK15_RESOURCE_METRICS.csv"


def validate_quality_csv() -> Tuple[bool, str, Dict[str, Any]]:
    if not QUALITY_CSV.exists():
        return False, f"File not found: {QUALITY_CSV.name}", {}
    
    expected_fields = [
        "workload_id", "architecture", "dataset", "evaluation_regime",
        "pe_mode", "evaluated_samples", "top1_accuracy_percent",
        "accuracy_loss_pp", "relative_accuracy_change_percent",
        "prediction_mismatches", "quality_constraint_satisfied",
        "execution_method", "provenance_note"
    ]
    
    stats = {"total_rows": 0, "workloads": set(), "modes": set(), "regimes": set()}
    with open(QUALITY_CSV, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != expected_fields:
            return False, f"Field mismatch in {QUALITY_CSV.name}. Got: {reader.fieldnames}", {}
        for idx, row in enumerate(reader):
            stats["total_rows"] += 1
            stats["workloads"].add(row["workload_id"])
            stats["modes"].add(row["pe_mode"])
            stats["regimes"].add(row["evaluation_regime"])
            
            # Numeric validation
            try:
                acc = float(row["top1_accuracy_percent"])
                loss = float(row["accuracy_loss_pp"])
                samples = int(row["evaluated_samples"])
                mismatches = int(row["prediction_mismatches"])
                if not (0.0 <= acc <= 100.0):
                    return False, f"Row {idx+1}: Invalid accuracy {acc}", {}
                if loss < 0.0 or loss > 100.0:
                    return False, f"Row {idx+1}: Invalid loss {loss}", {}
                if samples <= 0:
                    return False, f"Row {idx+1}: Invalid samples {samples}", {}
            except ValueError as e:
                return False, f"Row {idx+1}: Numeric parse error: {e}", {}

    return True, f"Quality CSV validated successfully ({stats['total_rows']} rows).", stats


def validate_adaptive_csv() -> Tuple[bool, str, Dict[str, Any]]:
    if not ADAPTIVE_CSV.exists():
        return False, f"File not found: {ADAPTIVE_CSV.name}", {}
    
    expected_fields = [
        "workload_id", "layer_index", "layer_name", "activation_sparsity_percent",
        "selected_pe_mode", "predicted_degradation", "measured_degradation",
        "prediction_error", "threshold_D_MAX_Q16", "threshold_normalized",
        "predicted_constraint_satisfied", "measured_constraint_satisfied",
        "is_false_safe", "is_false_alarm", "selection_reason", "fallback_asserted"
    ]
    
    stats = {"total_rows": 0, "pe_counts": {"16-PE": 0, "32-PE": 0, "64-PE": 0}, "false_safes": 0, "false_alarms": 0}
    with open(ADAPTIVE_CSV, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != expected_fields:
            return False, f"Field mismatch in {ADAPTIVE_CSV.name}. Got: {reader.fieldnames}", {}
        for idx, row in enumerate(reader):
            stats["total_rows"] += 1
            pe = row["selected_pe_mode"]
            if pe in stats["pe_counts"]:
                stats["pe_counts"][pe] += 1
            if row["is_false_safe"] == "YES":
                stats["false_safes"] += 1
            if row["is_false_alarm"] == "YES":
                stats["false_alarms"] += 1
            
            # Numeric checks
            try:
                sparsity = float(row["activation_sparsity_percent"])
                p_deg = float(row["predicted_degradation"])
                m_deg = float(row["measured_degradation"])
                thresh = float(row["threshold_normalized"])
                if not (0.0 <= sparsity <= 100.0):
                    return False, f"Row {idx+1}: Invalid sparsity {sparsity}", {}
                if int(row["threshold_D_MAX_Q16"]) != 3277:
                    return False, f"Row {idx+1}: Invalid D_MAX_Q16 {row['threshold_D_MAX_Q16']}", {}
            except ValueError as e:
                return False, f"Row {idx+1}: Numeric parse error: {e}", {}

    return True, f"Adaptive CSV validated successfully ({stats['total_rows']} layers).", stats


def validate_resource_csv() -> Tuple[bool, str, Dict[str, Any]]:
    if not RESOURCE_CSV.exists():
        return False, f"File not found: {RESOURCE_CSV.name}", {}
    
    expected_fields = [
        "workload_id", "policy", "simulated_cycles", "average_active_pes",
        "dense_mac_events", "useful_mac_events", "skipped_mac_events",
        "mac_reduction_percent", "accepted_sram_read_transactions",
        "accepted_sram_write_transactions", "feeder_mode_gated",
        "drain_mode_reduced", "fallback_status", "bit_exact_verified"
    ]
    
    stats = {"total_rows": 0, "policies": set(), "workloads": set()}
    with open(RESOURCE_CSV, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != expected_fields:
            return False, f"Field mismatch in {RESOURCE_CSV.name}. Got: {reader.fieldnames}", {}
        for idx, row in enumerate(reader):
            stats["total_rows"] += 1
            stats["policies"].add(row["policy"])
            stats["workloads"].add(row["workload_id"])
            
            try:
                cycles = int(row["simulated_cycles"])
                pes = float(row["average_active_pes"])
                mac_d = int(row["dense_mac_events"])
                mac_u = int(row["useful_mac_events"])
                mac_s = int(row["skipped_mac_events"])
                if cycles <= 0 or pes <= 0 or mac_d <= 0:
                    return False, f"Row {idx+1}: Non-positive metrics", {}
                if mac_u + mac_s != mac_d:
                    return False, f"Row {idx+1}: Useful ({mac_u}) + Skipped ({mac_s}) != Dense ({mac_d})", {}
            except ValueError as e:
                return False, f"Row {idx+1}: Numeric parse error: {e}", {}

    return True, f"Resource CSV validated successfully ({stats['total_rows']} rows).", stats


def main():
    print("=" * 80)
    print("TSK-15: Validation & Schema Verification of Experimental Results")
    print("=" * 80)

    all_passed = True

    # 1. Quality CSV
    passed, msg, q_stats = validate_quality_csv()
    status_str = "[PASS]" if passed else "[FAIL]"
    print(f"{status_str} {msg}")
    if passed:
        print(f"       Workloads: {sorted(list(q_stats['workloads']))}")
        print(f"       Regimes: {sorted(list(q_stats['regimes']))}")
    else:
        all_passed = False

    # 2. Adaptive CSV
    passed, msg, a_stats = validate_adaptive_csv()
    status_str = "[PASS]" if passed else "[FAIL]"
    print(f"{status_str} {msg}")
    if passed:
        print(f"       Selected PEs Distribution: {a_stats['pe_counts']}")
        print(f"       False-Safe Decisions: {a_stats['false_safes']} | False-Alarm Decisions: {a_stats['false_alarms']}")
    else:
        all_passed = False

    # 3. Resource CSV
    passed, msg, r_stats = validate_resource_csv()
    status_str = "[PASS]" if passed else "[FAIL]"
    print(f"{status_str} {msg}")
    if passed:
        print(f"       Policies Evaluated: {sorted(list(r_stats['policies']))}")
    else:
        all_passed = False

    print("=" * 80)
    if all_passed:
        print("ALL TSK-15 RESULT SCHEMAS AND CONSTRAINTS STRICTLY VALIDATED.")
        sys.exit(0)
    else:
        print("VALIDATION FAILED ON ONE OR MORE FILES.")
        sys.exit(1)


if __name__ == "__main__":
    from typing import Tuple
    main()
