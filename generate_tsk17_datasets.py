#!/usr/bin/env python3
"""
================================================================================
Project: Neural_Acc (Phase 2 RTL Implementation & Research Evaluation)
Task: TSK-17 CNN Sparsity-Aware Resource Allocation Feasibility Study
Module: generate_tsk17_datasets.py
Description: Generates the authoritative CSV datasets for TSK-17:
             - TSK17_LAYER_WORKLOADS.csv
             - TSK17_RESOURCE_ALLOCATION_ANALYSIS.csv
             using the verified layerwise statistics from Stage 13.1 and Stage 13.
================================================================================
"""

import csv
import math
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parent

STAGE13_1_LAYERWISE = WORKSPACE_ROOT / "exp1" / "stage13_1_baseline_preserving_pe" / "results" / "layerwise_results.csv"
OUT_WORKLOADS_CSV = WORKSPACE_ROOT / "TSK17_LAYER_WORKLOADS.csv"
OUT_ANALYSIS_CSV = WORKSPACE_ROOT / "TSK17_RESOURCE_ALLOCATION_ANALYSIS.csv"

# Representative layers spanning all 4 workloads, network depths, and sparsity regimes
REPRESENTATIVE_LAYERS = [
    # R18-C10
    ("resnet18", "cifar10", 0, "conv1", "Early", "1x3x32x32", "1x64x32x32", "3x3x3", 1, 1),
    ("resnet18", "cifar10", 1, "layer1.0.conv1", "Early-Mid", "1x64x32x32", "1x64x32x32", "3x3x64", 1, 1),
    ("resnet18", "cifar10", 5, "layer2.0.conv1", "Intermediate", "1x64x32x32", "1x128x16x16", "3x3x64", 2, 1),
    ("resnet18", "cifar10", 8, "layer2.1.conv1", "Intermediate", "1x128x16x16", "1x128x16x16", "3x3x128", 1, 1),
    ("resnet18", "cifar10", 14, "layer3.1.conv2", "Intermediate-Late", "1x256x8x8", "1x256x8x8", "3x3x256", 1, 1),
    ("resnet18", "cifar10", 19, "layer4.1.conv2", "Late", "1x512x4x4", "1x512x4x4", "3x3x512", 1, 1),

    # R18-C100
    ("resnet18", "cifar100", 0, "conv1", "Early", "1x3x32x32", "1x64x32x32", "3x3x3", 1, 1),
    ("resnet18", "cifar100", 5, "layer2.0.conv1", "Intermediate", "1x64x32x32", "1x128x16x16", "3x3x64", 2, 1),
    ("resnet18", "cifar100", 8, "layer2.1.conv1", "Intermediate", "1x128x16x16", "1x128x16x16", "3x3x128", 1, 1),
    ("resnet18", "cifar100", 19, "layer4.1.conv2", "Late", "1x512x4x4", "1x512x4x4", "3x3x512", 1, 1),

    # V16-C10
    ("vgg16", "cifar10", 0, "features.0", "Early", "1x3x32x32", "1x64x32x32", "3x3x3", 1, 1),
    ("vgg16", "cifar10", 1, "features.2", "Early-Mid", "1x64x32x32", "1x64x32x32", "3x3x64", 1, 1),
    ("vgg16", "cifar10", 5, "features.12", "Intermediate", "1x256x8x8", "1x256x8x8", "3x3x256", 1, 1),
    ("vgg16", "cifar10", 8, "features.19", "Late", "1x512x4x4", "1x512x4x4", "3x3x512", 1, 1),
    ("vgg16", "cifar10", 11, "features.26", "Late", "1x512x2x2", "1x512x2x2", "3x3x512", 1, 1),

    # V16-C100
    ("vgg16", "cifar100", 0, "features.0", "Early", "1x3x32x32", "1x64x32x32", "3x3x3", 1, 1),
    ("vgg16", "cifar100", 2, "features.7", "Early-Mid", "1x128x16x16", "1x128x16x16", "3x3x128", 1, 1),
    ("vgg16", "cifar100", 3, "features.10", "Intermediate", "1x128x16x16", "1x256x16x16", "3x3x128", 1, 1),
    ("vgg16", "cifar100", 8, "features.27", "Late", "1x512x4x4", "1x512x4x4", "3x3x512", 1, 1),
    ("vgg16", "cifar100", 12, "features.40", "Late", "1x512x2x2", "1x512x2x2", "3x3x512", 1, 1),
]


def load_layerwise_dict():
    lookup = {}
    if STAGE13_1_LAYERWISE.exists():
        with open(STAGE13_1_LAYERWISE, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for r in reader:
                key = (r["model"], r["dataset"], int(r["layer_index"]))
                lookup[key] = r
    return lookup


def generate_datasets():
    lookup = load_layerwise_dict()
    if not lookup:
        print("[ERROR] layerwise_results.csv not found.")
        return

    workload_rows = []
    analysis_rows = []

    for item in REPRESENTATIVE_LAYERS:
        model, dataset, layer_idx, layer_name, stage, in_dim, out_dim, kernel, stride, pad = item
        key = (model, dataset, layer_idx)
        if key not in lookup:
            print(f"[WARN] Layer {key} not found in layerwise lookup.")
            continue

        raw = lookup[key]
        wid = "R18-C10" if model == "resnet18" and dataset == "cifar10" else \
              "R18-C100" if model == "resnet18" and dataset == "cifar100" else \
              "V16-C10" if model == "vgg16" and dataset == "cifar10" else \
              "V16-C100"

        mac_dense = int(raw["mac_dense"])
        mac_useful = int(raw["mac_useful"])
        mac_skipped = int(raw["mac_skipped"])
        mac_red_pct = float(raw["mac_reduction_percent"])
        act_elems = int(raw["activation_elements"])
        zero_acts = int(raw["zero_activations"])
        act_sparsity = float(raw["activation_sparsity_percent"])

        dense_c64 = int(raw["baseline_cycles_64_dense"])
        sparse_c16 = int(raw["sparse_cycles_16"])
        sparse_c32 = int(raw["sparse_cycles_32"])
        sparse_c64 = int(raw["sparse_cycles_64"])

        feas_16 = (sparse_c16 <= dense_c64)
        feas_32 = (sparse_c32 <= dense_c64)
        feas_64 = (sparse_c64 <= dense_c64)

        selected_pe = int(raw["selected_pe"])
        selected_cycles = int(raw["selected_cycles"])
        pe_red_pct = float(raw["pe_reduction_percent"])
        cycle_saving_pct = float(raw["cycle_saving_percent"])

        # Table 1: TSK17_LAYER_WORKLOADS.csv
        workload_rows.append({
            "workload_id": wid,
            "layer_index": layer_idx,
            "layer_name": layer_name,
            "network_stage": stage,
            "input_dimensions": in_dim,
            "output_dimensions": out_dim,
            "kernel_geometry": kernel,
            "stride": stride,
            "padding": pad,
            "dense_mac_count": mac_dense,
            "exact_zero_activation_count": zero_acts,
            "total_activation_elements": act_elems,
            "activation_sparsity_percent": f"{act_sparsity:.2f}",
            "useful_mac_count": mac_useful,
            "skipped_mac_count": mac_skipped,
            "mac_reduction_percent": f"{mac_red_pct:.2f}",
            "data_source": "Stage 13.1 Authoritative Activation Trace",
            "checkpoint_dependency_status": "PROVENANCE_RECORDED_LOCAL_PT_MISSING"
        })

        # Table 2: TSK17_RESOURCE_ALLOCATION_ANALYSIS.csv
        analysis_rows.append({
            "workload_id": wid,
            "layer_index": layer_idx,
            "layer_name": layer_name,
            "activation_sparsity_percent": f"{act_sparsity:.2f}",
            "baseline_cycles_fixed64_dense": dense_c64,
            "sparse_cycles_fixed64": sparse_c64,
            "sparse_cycles_fixed32": sparse_c32,
            "sparse_cycles_fixed16": sparse_c16,
            "feasible_16pe": "YES" if feas_16 else "NO",
            "feasible_32pe": "YES" if feas_32 else "NO",
            "feasible_64pe": "YES" if feas_64 else "NO",
            "selected_pe_adaptive": f"{selected_pe}-PE",
            "selected_cycles": selected_cycles,
            "pe_count_reduction_percent": f"{pe_red_pct:.2f}",
            "cycle_saving_vs_dense64_percent": f"{cycle_saving_pct:.2f}",
            "preserves_full_output_tensor": "YES",
            "rtl_zero_skipping_cycle_benefit": "NONE (RTL Feeder steps all K-cycles sequentially)",
            "rtl_dynamic_power_benefit": "YES (AMD-02 Multiplier zero-gated)",
            "channel_pruning_accuracy_impact": "UNVIABLE (Causes >40-80% accuracy collapse if columns dropped)"
        })

    # Write CSVs
    def write_csv(path, rows):
        if not rows:
            return
        with open(path, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        print(f"[OK] Wrote {len(rows)} records to {path.name}")

    write_csv(OUT_WORKLOADS_CSV, workload_rows)
    write_csv(OUT_ANALYSIS_CSV, analysis_rows)


if __name__ == "__main__":
    generate_datasets()

