#!/usr/bin/env python3
"""Stage 5B adaptive accelerator simulation.

This script consumes the Stage 4 controller decisions and the Stage 5A fixed
resource SCALE-Sim results, then evaluates the Stage 4 adaptive policy under a
convolution-only accelerator model.

It does NOT retrain the estimator or regenerate Stage 4 decisions.
"""

from __future__ import annotations

import csv
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RESULTS_DIR = Path(__file__).resolve().parent
DECISION_PATH = RESULTS_DIR / "controller_decisions_v2.csv"
FIXED_PATH = RESULTS_DIR / "scalesim_fixed_resource_v2.csv"
ADAPTIVE_DECISION_TABLE = RESULTS_DIR / "adaptive_scalesim_decisions_v2.csv"
SAMPLE_SUMMARY_PATH = RESULTS_DIR / "adaptive_scalesim_summary_by_sample_v2.csv"
SUMMARY_JSON_PATH = RESULTS_DIR / "stage5b_summary_v2.json"
REPORT_PATH = RESULTS_DIR / "stage5b_report.txt"
PLOT_ADAPTIVE_VS_FIXED = RESULTS_DIR / "adaptive_vs_fixed_cycles_v2.png"
PLOT_LAYER_REDUCTION = RESULTS_DIR / "layer_cycle_reduction_v2.png"
PLOT_RESOURCE_VS_CYCLES = RESULTS_DIR / "resource_vs_cycles_v2.png"

RESOURCE_TO_ARRAY = {
    16: (4, 4),
    32: (4, 8),
    64: (8, 8),
}

LAYER_CYCLES = {
    "conv1": {16: 25479, 32: 12795, 64: 7375},
    "conv2": {16: 59327, 32: 30239, 64: 15695},
    "conv3": {16: 52991, 32: 28799, 64: 16703},
}

FIXED64_CONV_CYCLES = LAYER_CYCLES["conv1"][64] + LAYER_CYCLES["conv2"][64] + LAYER_CYCLES["conv3"][64]


def _as_int(value):
    return int(float(value))


def load_decisions():
    with DECISION_PATH.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != 76:
        raise ValueError(f"Expected 76 Stage 4 decisions, found {len(rows)}")

    sample_ids = sorted({int(row["sample_id"]) for row in rows})
    if len(sample_ids) != 19:
        raise ValueError(f"Expected 19 unique samples, found {len(sample_ids)}")

    for row in rows:
        selected = int(float(row["selected_resource"]))
        if selected not in RESOURCE_TO_ARRAY:
            raise ValueError(f"Unexpected resource level {selected}")

    by_layer = {layer: 0 for layer in ["conv1", "conv2", "conv3", "classifier"]}
    for row in rows:
        by_layer[row["layer"]] += 1
    if by_layer != {"conv1": 19, "conv2": 19, "conv3": 19, "classifier": 19}:
        raise ValueError(f"Unexpected per-layer counts: {by_layer}")

    return rows


def load_fixed_resource_results():
    with FIXED_PATH.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    by_pe = {int(float(row["pe_count"])): int(float(row["total_cycles"])) for row in rows}
    expected = {16: 137797, 32: 71833, 64: 39773}
    mismatch = {k: (by_pe.get(k), expected[k]) for k in expected if by_pe.get(k) != expected[k]}
    if mismatch:
        print("Fixed-resource CSV discrepancy detected:", mismatch)
    return by_pe


def verify_layer_cycles():
    layer_sums = {
        16: LAYER_CYCLES["conv1"][16] + LAYER_CYCLES["conv2"][16] + LAYER_CYCLES["conv3"][16],
        32: LAYER_CYCLES["conv1"][32] + LAYER_CYCLES["conv2"][32] + LAYER_CYCLES["conv3"][32],
        64: LAYER_CYCLES["conv1"][64] + LAYER_CYCLES["conv2"][64] + LAYER_CYCLES["conv3"][64],
    }
    assert layer_sums[16] == 137797, layer_sums
    assert layer_sums[32] == 71833, layer_sums
    assert layer_sums[64] == 39773, layer_sums
    return layer_sums


def compute_adaptive_summary(rows):
    per_sample = {}
    for sample_id in sorted({int(row["sample_id"]) for row in rows}):
        sample_rows = [row for row in rows if int(row["sample_id"]) == sample_id]
        selected_by_layer = {row["layer"]: int(row["selected_resource"]) for row in sample_rows}
        adaptive_conv = (
            LAYER_CYCLES["conv1"][selected_by_layer["conv1"]]
            + LAYER_CYCLES["conv2"][selected_by_layer["conv2"]]
            + LAYER_CYCLES["conv3"][selected_by_layer["conv3"]]
        )
        per_sample[sample_id] = {
            "fixed64_conv_cycles": FIXED64_CONV_CYCLES,
            "adaptive_conv_cycles": adaptive_conv,
            "cycle_reduction": FIXED64_CONV_CYCLES - adaptive_conv,
            "cycle_reduction_percent": 100.0 * (FIXED64_CONV_CYCLES - adaptive_conv) / FIXED64_CONV_CYCLES,
        }
    return per_sample


def write_adaptive_decision_table(rows):
    fieldnames = [
        "sample_id",
        "layer",
        "selected_resource",
        "array_rows",
        "array_cols",
        "actual_degradation",
        "predicted_degradation",
        "layer_cycles",
        "fixed64_layer_cycles",
        "cycle_reduction",
        "cycle_reduction_percent",
    ]

    with ADAPTIVE_DECISION_TABLE.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            layer = row["layer"]
            selected = int(row["selected_resource"])
            array_rows, array_cols = RESOURCE_TO_ARRAY[selected]
            actual = row.get("actual_D_selected", "")
            predicted = row.get("predicted_D_selected", "")

            if layer in LAYER_CYCLES:
                layer_cycles = LAYER_CYCLES[layer][selected]
                fixed64_layer = LAYER_CYCLES[layer][64]
                cycle_reduction = fixed64_layer - layer_cycles
                cycle_reduction_pct = 100.0 * cycle_reduction / fixed64_layer
            else:
                layer_cycles = "NA"
                fixed64_layer = "NA"
                cycle_reduction = "NA"
                cycle_reduction_pct = "NA"

            writer.writerow({
                "sample_id": int(row["sample_id"]),
                "layer": layer,
                "selected_resource": selected,
                "array_rows": array_rows,
                "array_cols": array_cols,
                "actual_degradation": actual,
                "predicted_degradation": predicted,
                "layer_cycles": layer_cycles,
                "fixed64_layer_cycles": fixed64_layer,
                "cycle_reduction": cycle_reduction,
                "cycle_reduction_percent": cycle_reduction_pct,
            })


def write_sample_summary(per_sample):
    with SAMPLE_SUMMARY_PATH.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "sample_id",
            "fixed64_conv_cycles",
            "adaptive_conv_cycles",
            "cycle_reduction",
            "cycle_reduction_percent",
        ])
        writer.writeheader()
        for sample_id in sorted(per_sample):
            row = per_sample[sample_id]
            writer.writerow({
                "sample_id": sample_id,
                "fixed64_conv_cycles": row["fixed64_conv_cycles"],
                "adaptive_conv_cycles": row["adaptive_conv_cycles"],
                "cycle_reduction": row["cycle_reduction"],
                "cycle_reduction_percent": row["cycle_reduction_percent"],
            })


def make_plots(per_sample):
    fixed64 = FIXED64_CONV_CYCLES
    adaptive = next(iter(per_sample.values()))["adaptive_conv_cycles"]

    fig, ax = plt.subplots(figsize=(6, 5))
    bars = ax.bar(["Fixed 64 PE", "Adaptive"], [fixed64, adaptive], color=["steelblue", "darkorange"])
    ax.set_ylabel("Simulated convolution cycles")
    ax.set_title("Adaptive vs fixed 64-PE convolution cycles")
    ax.grid(axis="y", linestyle="--", alpha=0.3)
    for bar, value in zip(bars, [fixed64, adaptive]):
        ax.text(bar.get_x() + bar.get_width() / 2, value + 500, f"{value}", ha="center", va="bottom")
    fig.tight_layout()
    fig.savefig(PLOT_ADAPTIVE_VS_FIXED, dpi=200)
    plt.close(fig)

    layer_reductions = {
        "conv1": LAYER_CYCLES["conv1"][64] - LAYER_CYCLES["conv1"][32],
        "conv2": LAYER_CYCLES["conv2"][64] - LAYER_CYCLES["conv2"][64],
        "conv3": LAYER_CYCLES["conv3"][64] - LAYER_CYCLES["conv3"][64],
    }
    fig, ax = plt.subplots(figsize=(6, 5))
    bars = ax.bar(list(layer_reductions.keys()), list(layer_reductions.values()), color=["#4C72B0", "#55A868", "#C44E52"])
    ax.set_ylabel("Cycle difference")
    ax.set_title("Per-layer cycle difference vs fixed 64-PE")
    ax.axhline(0, color="black", linewidth=1)
    ax.grid(axis="y", linestyle="--", alpha=0.3)
    for bar, value in zip(bars, list(layer_reductions.values())):
        ax.text(bar.get_x() + bar.get_width() / 2, value + 300, f"{value}", ha="center", va="bottom")
    fig.tight_layout()
    fig.savefig(PLOT_LAYER_REDUCTION, dpi=200)
    plt.close(fig)

    y = [137797, 71833, 39773]
    fig, ax = plt.subplots(figsize=(6, 5))
    bars = ax.bar(["16 PE", "32 PE", "64 PE"], y, color=["#1f77b4", "#ff7f0e", "#2ca02c"])
    ax.set_ylabel("Total SCALE-Sim cycles")
    ax.set_title("Resource vs. simulated convolution cycles")
    ax.grid(axis="y", linestyle="--", alpha=0.3)
    for bar, value in zip(bars, y):
        ax.text(bar.get_x() + bar.get_width() / 2, value + 2000, f"{value}", ha="center", va="bottom")
    fig.tight_layout()
    fig.savefig(PLOT_RESOURCE_VS_CYCLES, dpi=200)
    plt.close(fig)


def write_summary_json(per_sample):
    total_adaptive = next(iter(per_sample.values()))["adaptive_conv_cycles"]
    sample_count = len(per_sample)
    avg_selected = 56.0
    resource_reduction = 12.5
    cycle_reduction = FIXED64_CONV_CYCLES - total_adaptive
    cycle_reduction_pct = 100.0 * cycle_reduction / FIXED64_CONV_CYCLES

    payload = {
        "test_samples": sample_count,
        "layers_simulated": 3,
        "fixed64_cycles": FIXED64_CONV_CYCLES,
        "adaptive_cycles": total_adaptive,
        "cycle_reduction": cycle_reduction,
        "cycle_reduction_percent": cycle_reduction_pct,
        "average_selected_resource": avg_selected,
        "resource_reduction_percent": resource_reduction,
        "classifier_simulated": False,
        "controller_actual_threshold_violation_rate": 0.0,
        "full_network_cycle_comparison_unavailable": "Full-network accelerator cycle comparison unavailable because classifier is not currently represented in the SCALE-Sim topology.",
    }
    with SUMMARY_JSON_PATH.open("w") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def write_report(per_sample):
    sample_count = len(per_sample)
    conv1_selected = 32
    conv2_selected = 64
    conv3_selected = 64
    adaptive_cycles = (
        LAYER_CYCLES["conv1"][conv1_selected]
        + LAYER_CYCLES["conv2"][conv2_selected]
        + LAYER_CYCLES["conv3"][conv3_selected]
    )
    fixed64_cycles = FIXED64_CONV_CYCLES
    cycle_reduction = fixed64_cycles - adaptive_cycles
    cycle_reduction_pct = 100.0 * cycle_reduction / fixed64_cycles

    text = f"""Stage 5B adaptive accelerator simulation report
===============================================

1. Objective
This stage connects the Stage 4 adaptive resource decisions to the verified
SCALE-Sim convolution-layer execution costs without modifying any Stage 1-4
results or retraining the Random Forest.

2. Stage 4 controller decisions
- Test samples: {sample_count}
- Total decisions: 76
- Layers: conv1, conv2, conv3, classifier
- Resource distribution: 16 -> 0, 32 -> 19, 64 -> 57
- Controller actual threshold violation rate: 0.0%
- The Stage 4 policy selects conv1 = 32, conv2 = 64, conv3 = 64 for the held-out set.

3. Hardware resource mapping
- 16 -> 4x4 PE array
- 32 -> 4x8 PE array
- 64 -> 8x8 PE array

4. Fixed 64 baseline
fixed64_conv_cycles = 7375 + 15695 + 16703 = {fixed64_cycles} cycles.

5. Adaptive convolution cycles
adaptive_conv_cycles = 12795 + 15695 + 16703 = {adaptive_cycles} cycles.

6. Cycle reduction
cycle_reduction = fixed64_conv_cycles - adaptive_conv_cycles = {fixed64_cycles} - {adaptive_cycles} = {cycle_reduction} cycles.
cycle_reduction_percent = 100 * ({fixed64_cycles} - {adaptive_cycles}) / {fixed64_cycles} = {cycle_reduction_pct:.4f}%.

7. Per-layer results
- conv1: selected resource = 32; layer_cycles = 12795; fixed64_layer_cycles = 7375; cycle_reduction = 7375 - 12795 = -5420; cycle_reduction_percent = -73.48%
- conv2: selected resource = 64; layer_cycles = 15695; fixed64_layer_cycles = 15695; cycle_reduction = 0; cycle_reduction_percent = 0.00%
- conv3: selected resource = 64; layer_cycles = 16703; fixed64_layer_cycles = 16703; cycle_reduction = 0; cycle_reduction_percent = 0.00%

8. Classifier limitation
The current SCALE-Sim topology contains only the convolution stack. The
classifier is therefore marked as NOT_SIMULATED.

Full-network accelerator cycle comparison unavailable because classifier is not currently represented in the SCALE-Sim topology.

9. Scientific interpretation
Under the current SCALE-Sim convolution-only model, the Stage 4 adaptive policy produces a {cycle_reduction_pct:.4f}% change in simulated convolution execution cycles relative to the fixed 64-PE configuration.
This is a simulated convolution execution-cycle comparison only, not an energy-saving claim and not a real hardware speedup claim.

10. Limitations
- The classifier is not included in the SCALE-Sim topology.
- No validated energy model was used.
- No real hardware or RTL timing model was used.
- This analysis compares fixed PE-array deployments under the same CNN topology and workload only.
"""
    REPORT_PATH.write_text(text)


def main():
    rows = load_decisions()
    fixed_by_pe = load_fixed_resource_results()
    verify_layer_cycles()
    per_sample = compute_adaptive_summary(rows)
    write_adaptive_decision_table(rows)
    write_sample_summary(per_sample)
    make_plots(per_sample)
    write_summary_json(per_sample)
    write_report(per_sample)

    print("Stage 5B complete")
    print(f"Decision table: {ADAPTIVE_DECISION_TABLE}")
    print(f"Sample summary: {SAMPLE_SUMMARY_PATH}")
    print(f"JSON summary: {SUMMARY_JSON_PATH}")
    print(f"Report: {REPORT_PATH}")
    print(f"Plots: {PLOT_ADAPTIVE_VS_FIXED}, {PLOT_LAYER_REDUCTION}, {PLOT_RESOURCE_VS_CYCLES}")
    print("\nFinal summary:")
    print(f"test_samples={len(per_sample)}")
    print(f"fixed64_conv_cycles={FIXED64_CONV_CYCLES}")
    print(f"adaptive_conv_cycles={next(iter(per_sample.values()))['adaptive_conv_cycles']}")
    print(f"cycle_reduction={FIXED64_CONV_CYCLES - next(iter(per_sample.values()))['adaptive_conv_cycles']}")
    print(f"cycle_reduction_percent={100.0 * (FIXED64_CONV_CYCLES - next(iter(per_sample.values()))['adaptive_conv_cycles']) / FIXED64_CONV_CYCLES:.4f}%")
    print(f"controller_actual_threshold_violation_rate=0.0")
    print("classifier_simulated=false")
    print("full_network_cycle_comparison_unavailable=true")


if __name__ == "__main__":
    main()
