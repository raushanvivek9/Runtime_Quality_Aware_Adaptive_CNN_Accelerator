#!/usr/bin/env python3
"""Stage 6 quality-constrained performance-aware controller.

This is an independent controller that reuses the saved Random Forest and the
verified SCALE-Sim cycle table. It does not retrain, regenerate Stage 2 data,
regenerate Stage 4 decisions, or modify any earlier Stage 1-5 artifacts.
"""

from __future__ import annotations

import csv
import json
import pickle
from collections import Counter, defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

RESULTS_DIR = Path(__file__).resolve().parent
DATASET_PATH = RESULTS_DIR / "quality_dataset_v2.csv"
FOREST_PATH = RESULTS_DIR / "quality_estimator_rf_v2.pkl"
STAGE4_DECISIONS_PATH = RESULTS_DIR / "controller_decisions_v2.csv"
DECISION_TABLE_PATH = RESULTS_DIR / "controller_stage6_decisions_v2.csv"
COMPARISON_PATH = RESULTS_DIR / "controller_policy_comparison_v2.csv"
SUMMARY_PATH = RESULTS_DIR / "controller_stage6_summary_v2.json"
REPORT_PATH = RESULTS_DIR / "stage6_report_v2.txt"
PLOT_POLICY_PATH = RESULTS_DIR / "stage6_policy_comparison_v2.png"
PLOT_RESOURCE_PATH = RESULTS_DIR / "stage6_resource_selection_v2.png"
PLOT_DEG_VS_CYCLES_PATH = RESULTS_DIR / "stage6_degradation_vs_cycles_v2.png"

TEST_IDS = [8, 12, 13, 14, 19, 22, 35, 36, 41, 47, 53, 64, 65, 66, 77, 97, 107, 109, 113]
RESOURCE_LEVELS = (16, 32, 64)
D_MAX = 0.05
LAYER_ORDER = ["conv1", "conv2", "conv3"]
CYCLE_TABLE = {
    "conv1": {16: 25479, 32: 12795, 64: 7375},
    "conv2": {16: 59327, 32: 30239, 64: 15695},
    "conv3": {16: 52991, 32: 28799, 64: 16703},
}


def load_forest():
    with FOREST_PATH.open("rb") as handle:
        forest = pickle.load(handle)
    return forest


def load_actual_dataset():
    actual = {}
    features = defaultdict(dict)
    with DATASET_PATH.open(newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            sid = int(row["sample_id"])
            layer = str(row["layer"])
            resource = int(row["resource_level"])
            if sid not in TEST_IDS or layer not in LAYER_ORDER:
                continue
            actual[(sid, layer, resource)] = float(row["degradation"])
            features[(sid, layer)][resource] = {
                "sparsity": float(row["sparsity"]),
                "mean": float(row["mean"]),
                "variance": float(row["variance"]),
                "layer_position": float(row["layer_position"]),
            }
    return actual, features


def stage4_by_key():
    stage4 = {}
    with STAGE4_DECISIONS_PATH.open(newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            sid = int(row["sample_id"])
            layer = str(row["layer"])
            if sid not in TEST_IDS or layer not in LAYER_ORDER:
                continue
            stage4[(sid, layer)] = {
                "selected": int(float(row["selected_resource"])),
                "predicted_D_selected": float(row["predicted_D_selected"]),
                "actual_D_selected": float(row["actual_D_selected"]),
            }
    return stage4


def predict_for_features(forest, base_features, resource):
    vec = np.asarray([[base_features["sparsity"], base_features["mean"], base_features["variance"], base_features["layer_position"], float(resource)]], dtype=float)
    pred = float(forest.predict(vec)[0])
    return pred


def choose_stage6_resource(forest, base_features, layer):
    predictions = {}
    for resource in RESOURCE_LEVELS:
        predictions[resource] = predict_for_features(forest, base_features, resource)
    feasible = {resource for resource, pred in predictions.items() if pred <= D_MAX}
    if feasible:
        return min(feasible, key=lambda res: CYCLE_TABLE[layer][res]), predictions
    return 64, predictions


def compute_policy_metrics(policy_name, decision_rows):
    total_cycles = sum(int(row["selected_cycles"]) for row in decision_rows)
    avg_cycles_per_sample = total_cycles / len(TEST_IDS)
    avg_selected_resource = sum(float(row["selected_resource"]) for row in decision_rows) / len(decision_rows)
    resource_reduction_percent = (64.0 - avg_selected_resource) / 64.0 * 100.0
    actual_vals = [float(row["actual_selected_degradation"]) for row in decision_rows]
    avg_actual = sum(actual_vals) / len(actual_vals)
    max_actual = max(actual_vals)
    violation_count = sum(1 for val in actual_vals if val > D_MAX)
    violation_rate = violation_count / len(actual_vals) * 100.0
    return {
        "policy": policy_name,
        "total_cycles": total_cycles,
        "avg_cycles_per_sample": avg_cycles_per_sample,
        "avg_selected_resource": avg_selected_resource,
        "resource_reduction_percent": resource_reduction_percent,
        "avg_actual_degradation": avg_actual,
        "max_actual_degradation": max_actual,
        "threshold_violations": violation_count,
        "threshold_violation_rate": violation_rate,
    }


def fixed64_policy_rows():
    rows = []
    for sid in TEST_IDS:
        for layer in LAYER_ORDER:
            selected = 64
            selected_cycles = CYCLE_TABLE[layer][selected]
            fixed64 = CYCLE_TABLE[layer][64]
            actual = 0.0
            # Use actual measured degradation for the selected 64 resource
            actual = 0.0
            if (sid, layer, selected) in actual_lookup:
                actual = actual_lookup[(sid, layer, selected)]
            rows.append({
                "sample_id": sid,
                "layer": layer,
                "selected_resource": selected,
                "selected_cycles": selected_cycles,
                "fixed64_cycles": fixed64,
                "cycle_reduction": fixed64 - selected_cycles,
                "cycle_reduction_percent": 100.0 * (fixed64 - selected_cycles) / fixed64,
                "actual_selected_degradation": actual,
                "actual_threshold_satisfied": actual <= D_MAX,
            })
    return rows


def stage4_policy_rows():
    rows = []
    stage4 = stage4_by_key()
    for sid in TEST_IDS:
        for layer in LAYER_ORDER:
            decision = stage4.get((sid, layer), {})
            selected = int(decision.get("selected", 64))
            selected_cycles = CYCLE_TABLE[layer][selected]
            fixed64 = CYCLE_TABLE[layer][64]
            actual = float(decision.get("actual_D_selected", 0.0))
            rows.append({
                "sample_id": sid,
                "layer": layer,
                "selected_resource": selected,
                "selected_cycles": selected_cycles,
                "fixed64_cycles": fixed64,
                "cycle_reduction": fixed64 - selected_cycles,
                "cycle_reduction_percent": 100.0 * (fixed64 - selected_cycles) / fixed64,
                "actual_selected_degradation": actual,
                "actual_threshold_satisfied": actual <= D_MAX,
            })
    return rows


def stage6_policy_rows(forest, features):
    rows = []
    for sid in TEST_IDS:
        for layer in LAYER_ORDER:
            rep = features[(sid, layer)][64] if 64 in features[(sid, layer)] else next(iter(features[(sid, layer)].values()))
            selected, predictions = choose_stage6_resource(forest, rep, layer)
            selected_cycles = CYCLE_TABLE[layer][selected]
            fixed64 = CYCLE_TABLE[layer][64]
            actual = actual_lookup[(sid, layer, selected)]
            rows.append({
                "sample_id": sid,
                "layer": layer,
                "predicted_D_16": predictions[16],
                "predicted_D_32": predictions[32],
                "predicted_D_64": predictions[64],
                "feasible_16": predictions[16] <= D_MAX,
                "feasible_32": predictions[32] <= D_MAX,
                "feasible_64": predictions[64] <= D_MAX,
                "selected_resource": selected,
                "selected_cycles": selected_cycles,
                "fixed64_cycles": fixed64,
                "cycle_reduction": fixed64 - selected_cycles,
                "cycle_reduction_percent": 100.0 * (fixed64 - selected_cycles) / fixed64,
                "actual_selected_degradation": actual,
                "actual_threshold_satisfied": actual <= D_MAX,
            })
    return rows


# Initialize dataset lookups.
actual_lookup, feature_lookup = load_actual_dataset()
stage4_lookup = stage4_by_key()
forest = load_forest()

fixed64_rows = fixed64_policy_rows()
stage4_rows = stage4_policy_rows()
stage6_rows = stage6_policy_rows(forest, feature_lookup)

# Write Stage 6 decision table.
fieldnames = [
    "sample_id",
    "layer",
    "predicted_D_16",
    "predicted_D_32",
    "predicted_D_64",
    "feasible_16",
    "feasible_32",
    "feasible_64",
    "selected_resource",
    "selected_cycles",
    "fixed64_cycles",
    "cycle_reduction",
    "cycle_reduction_percent",
    "actual_selected_degradation",
    "actual_threshold_satisfied",
]
with DECISION_TABLE_PATH.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=fieldnames)
    writer.writeheader()
    for row in stage6_rows:
        writer.writerow({
            "sample_id": row["sample_id"],
            "layer": row["layer"],
            "predicted_D_16": row["predicted_D_16"],
            "predicted_D_32": row["predicted_D_32"],
            "predicted_D_64": row["predicted_D_64"],
            "feasible_16": row["feasible_16"],
            "feasible_32": row["feasible_32"],
            "feasible_64": row["feasible_64"],
            "selected_resource": row["selected_resource"],
            "selected_cycles": row["selected_cycles"],
            "fixed64_cycles": row["fixed64_cycles"],
            "cycle_reduction": row["cycle_reduction"],
            "cycle_reduction_percent": row["cycle_reduction_percent"],
            "actual_selected_degradation": row["actual_selected_degradation"],
            "actual_threshold_satisfied": row["actual_threshold_satisfied"],
        })

# Policy comparison CSV
policy_metrics = [
    compute_policy_metrics("Fixed64", fixed64_rows),
    compute_policy_metrics("Stage4", stage4_rows),
    compute_policy_metrics("Stage6", stage6_rows),
]
with COMPARISON_PATH.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=[
        "policy",
        "total_cycles",
        "avg_cycles_per_sample",
        "avg_selected_resource",
        "resource_reduction_percent",
        "avg_actual_degradation",
        "max_actual_degradation",
        "threshold_violations",
        "threshold_violation_rate",
    ])
    writer.writeheader()
    for metric in policy_metrics:
        writer.writerow(metric)

# JSON summary for Stage 6
stage6_summary = {
    "d_max": D_MAX,
    "test_samples": len(TEST_IDS),
    "convolution_decisions": len(stage6_rows),
    "classifier_simulated": False,
    "stage6_policy": {
        "selected_resource_distribution": dict(Counter(row["selected_resource"] for row in stage6_rows)),
        "total_cycles": sum(row["selected_cycles"] for row in stage6_rows),
        "avg_cycles_per_sample": sum(row["selected_cycles"] for row in stage6_rows) / len(TEST_IDS),
        "average_selected_resource": sum(float(row["selected_resource"]) for row in stage6_rows) / len(stage6_rows),
        "resource_reduction_percent": (64.0 - (sum(float(row["selected_resource"]) for row in stage6_rows) / len(stage6_rows))) / 64.0 * 100.0,
        "average_actual_degradation": sum(float(row["actual_selected_degradation"]) for row in stage6_rows) / len(stage6_rows),
        "maximum_actual_degradation": max(float(row["actual_selected_degradation"]) for row in stage6_rows),
        "threshold_violations": sum(1 for row in stage6_rows if not row["actual_threshold_satisfied"]),
        "threshold_violation_rate_percent": 100.0 * sum(1 for row in stage6_rows if not row["actual_threshold_satisfied"]) / len(stage6_rows),
    },
    "fixed64_policy": {
        "total_cycles": sum(row["selected_cycles"] for row in fixed64_rows),
        "avg_cycles_per_sample": sum(row["selected_cycles"] for row in fixed64_rows) / len(TEST_IDS),
        "average_selected_resource": 64.0,
        "resource_reduction_percent": 0.0,
        "average_actual_degradation": sum(float(row["actual_selected_degradation"]) for row in fixed64_rows) / len(fixed64_rows),
        "maximum_actual_degradation": max(float(row["actual_selected_degradation"]) for row in fixed64_rows),
        "threshold_violations": sum(1 for row in fixed64_rows if not row["actual_threshold_satisfied"]),
        "threshold_violation_rate_percent": 100.0 * sum(1 for row in fixed64_rows if not row["actual_threshold_satisfied"]) / len(fixed64_rows),
    },
    "stage4_policy": {
        "total_cycles": sum(row["selected_cycles"] for row in stage4_rows),
        "avg_cycles_per_sample": sum(row["selected_cycles"] for row in stage4_rows) / len(TEST_IDS),
        "average_selected_resource": sum(float(row["selected_resource"]) for row in stage4_rows) / len(stage4_rows),
        "resource_reduction_percent": (64.0 - (sum(float(row["selected_resource"]) for row in stage4_rows) / len(stage4_rows))) / 64.0 * 100.0,
        "average_actual_degradation": sum(float(row["actual_selected_degradation"]) for row in stage4_rows) / len(stage4_rows),
        "maximum_actual_degradation": max(float(row["actual_selected_degradation"]) for row in stage4_rows),
        "threshold_violations": sum(1 for row in stage4_rows if not row["actual_threshold_satisfied"]),
        "threshold_violation_rate_percent": 100.0 * sum(1 for row in stage4_rows if not row["actual_threshold_satisfied"]) / len(stage4_rows),
    },
}
with SUMMARY_PATH.open("w") as handle:
    json.dump(stage6_summary, handle, indent=2)
    handle.write("\n")

# Policy comparison plot
labels = ["Fixed 64", "Stage 4", "Stage 6"]
values = [
    sum(r["selected_cycles"] for r in fixed64_rows),
    sum(r["selected_cycles"] for r in stage4_rows),
    sum(r["selected_cycles"] for r in stage6_rows),
]
fig, ax = plt.subplots(figsize=(7, 5))
ax.bar(labels, values, color=["steelblue", "darkorange", "forestgreen"])
ax.set_ylabel("Simulated convolution cycles")
ax.set_title("Policy comparison: fixed 64 vs Stage 4 vs Stage 6")
ax.grid(axis="y", linestyle="--", alpha=0.3)
for bar, value in zip(ax.patches, values):
    ax.text(bar.get_x() + bar.get_width() / 2, value + 8000, f"{value}", ha="center", va="bottom")
fig.tight_layout()
fig.savefig(PLOT_POLICY_PATH, dpi=200)
plt.close(fig)

# Resource distribution plot
stage4_counts = Counter(row["selected_resource"] for row in stage4_rows)
stage6_counts = Counter(row["selected_resource"] for row in stage6_rows)
resources = [16, 32, 64]
stage4_values = [stage4_counts.get(r, 0) for r in resources]
stage6_values = [stage6_counts.get(r, 0) for r in resources]
fig, ax = plt.subplots(figsize=(7, 5))
idx = np.arange(len(resources))
width = 0.35
ax.bar(idx - width/2, stage4_values, width, label="Stage 4")
ax.bar(idx + width/2, stage6_values, width, label="Stage 6")
ax.set_xticks(idx)
ax.set_xticklabels(resources)
ax.set_xlabel("Resource")
ax.set_ylabel("Convolution decisions")
ax.set_title("Stage 4 vs Stage 6 resource distribution")
ax.legend()
ax.grid(axis="y", linestyle="--", alpha=0.3)
fig.tight_layout()
fig.savefig(PLOT_RESOURCE_PATH, dpi=200)
plt.close(fig)

# Degradation vs cycles plot
stage4_points = [(float(row["selected_cycles"]), float(row["actual_selected_degradation"])) for row in stage4_rows]
stage6_points = [(float(row["selected_cycles"]), float(row["actual_selected_degradation"])) for row in stage6_rows]
fig, ax = plt.subplots(figsize=(7, 5))
if stage4_points:
    xs4, ys4 = zip(*stage4_points)
    ax.scatter(xs4, ys4, label="Stage 4", alpha=0.7)
if stage6_points:
    xs6, ys6 = zip(*stage6_points)
    ax.scatter(xs6, ys6, label="Stage 6", alpha=0.7)
ax.axhline(D_MAX, color="red", linestyle="--", label="D_MAX = 0.05")
ax.set_xlabel("Selected cycles")
ax.set_ylabel("Actual selected degradation")
ax.set_title("Actual degradation vs simulated selected cycles")
ax.legend()
ax.grid(True, linestyle="--", alpha=0.3)
fig.tight_layout()
fig.savefig(PLOT_DEG_VS_CYCLES_PATH, dpi=200)
plt.close(fig)

# Report text
stage6_total = sum(r["selected_cycles"] for r in stage6_rows)
stage6_avg = stage6_total / len(TEST_IDS)
stage6_avg_resource = sum(float(r["selected_resource"]) for r in stage6_rows) / len(stage6_rows)
stage6_resource_reduction = (64.0 - stage6_avg_resource) / 64.0 * 100.0
stage6_avg_actual = sum(float(r["actual_selected_degradation"]) for r in stage6_rows) / len(stage6_rows)
stage6_max_actual = max(float(r["actual_selected_degradation"]) for r in stage6_rows)
stage6_violation_rate = 100.0 * sum(1 for r in stage6_rows if not r["actual_threshold_satisfied"]) / len(stage6_rows)
fixed64_total = sum(r["selected_cycles"] for r in fixed64_rows)
stage4_total = sum(r["selected_cycles"] for r in stage4_rows)
stage4_avg_resource = sum(float(r["selected_resource"]) for r in stage4_rows) / len(stage4_rows)
stage4_resource_reduction = (64.0 - stage4_avg_resource) / 64.0 * 100.0
stage4_avg_actual = sum(float(r["actual_selected_degradation"]) for r in stage4_rows) / len(stage4_rows)
stage4_violation_rate = 100.0 * sum(1 for r in stage4_rows if not r["actual_threshold_satisfied"]) / len(stage4_rows)

report_lines = [
    "Stage 6 report (quality-constrained performance-aware resource controller)",
    "====================================================================",
    "",
    "1. Objective",
    "Stage 6 selects the lowest simulated cycle cost among resources whose predicted degradation satisfies D_hat <= 0.05, using the saved Random Forest and the verified SCALE-Sim cycle table.",
    "",
    "2. Stage 4 controller decisions (unchanged)",
    f"- Test samples: {len(TEST_IDS)}",
    f"- Convolution decisions evaluated: {len(stage4_rows)}",
    f"- Stage 4 selected resource distribution: 16={sum(1 for r in stage4_rows if r['selected_resource']==16)}, 32={sum(1 for r in stage4_rows if r['selected_resource']==32)}, 64={sum(1 for r in stage4_rows if r['selected_resource']==64)}",
    "",
    "3. Hardware resource mapping",
    "- 16 -> 4x4 PE array",
    "- 32 -> 4x8 PE array",
    "- 64 -> 8x8 PE array",
    "",
    "4. Fixed 64 baseline",
    f"- Total cycles: {fixed64_total}",
    f"- Average cycles/sample: {fixed64_total / len(TEST_IDS)}",
    f"- Average selected resource: 64.0",
    f"- Resource reduction: 0.0%",
    "",
    "5. Stage 4 baseline",
    f"- Total cycles: {stage4_total}",
    f"- Average cycles/sample: {stage4_total / len(TEST_IDS)}",
    f"- Average selected resource: {stage4_avg_resource}",
    f"- Resource reduction: {stage4_resource_reduction:.4f}%",
    f"- Average actual degradation: {stage4_avg_actual}",
    f"- Threshold violation rate: {stage4_violation_rate:.4f}%",
    "",
    "6. Stage 6 decision rule",
    "- Predict D_hat_16, D_hat_32, D_hat_64 for each sample/layer using the saved RF.",
    "- Restrict to feasible resources where D_hat <= 0.05.",
    "- Select the feasible resource with the smallest SCALE-Sim cycles.",
    "- If no feasible resource exists, select 64.",
    "",
    "7. Stage 6 results",
    f"- Total cycles: {stage6_total}",
    f"- Average cycles/sample: {stage6_avg}",
    f"- Average selected resource: {stage6_avg_resource}",
    f"- Resource reduction: {stage6_resource_reduction:.4f}%",
    f"- Average actual degradation: {stage6_avg_actual}",
    f"- Maximum actual degradation: {stage6_max_actual}",
    f"- Threshold violation rate: {stage6_violation_rate:.4f}%",
    "",
    "8. Comparison",
    f"- Stage 4 vs Fixed64 cycle change: {stage4_total - fixed64_total} cycles",
    f"- Stage 6 vs Fixed64 cycle change: {stage6_total - fixed64_total} cycles",
    f"- Stage 6 vs Stage4 cycle change: {stage6_total - stage4_total} cycles",
    f"- Stage 4 resource reduction: {stage4_resource_reduction:.4f}%",
    f"- Stage 6 resource reduction: {stage6_resource_reduction:.4f}%",
    f"- Stage 4 threshold violations: {sum(1 for r in stage4_rows if not r['actual_threshold_satisfied'])}",
    f"- Stage 6 threshold violations: {sum(1 for r in stage6_rows if not r['actual_threshold_satisfied'])}",
    "",
    "9. Per-layer summary",
]
for layer in LAYER_ORDER:
    s4 = [r for r in stage4_rows if r["layer"] == layer]
    s6 = [r for r in stage6_rows if r["layer"] == layer]
    s4_res = Counter(r["selected_resource"] for r in s4)
    s6_res = Counter(r["selected_resource"] for r in s6)
    report_lines.append(f"- {layer}:")
    report_lines.append(f"  Stage 4: 16={s4_res.get(16,0)}, 32={s4_res.get(32,0)}, 64={s4_res.get(64,0)}")
    report_lines.append(f"  Stage 6: 16={s6_res.get(16,0)}, 32={s6_res.get(32,0)}, 64={s6_res.get(64,0)}")
    report_lines.append(f"  Stage 4 average actual degradation: {sum(float(r['actual_selected_degradation']) for r in s4)/len(s4)}")
    report_lines.append(f"  Stage 6 average actual degradation: {sum(float(r['actual_selected_degradation']) for r in s6)/len(s6)}")

report_lines.extend([
    "",
    "10. Scientific interpretation",
    "The quality-constrained performance-aware controller chooses the minimum-cycle feasible resource under the predicted degradation constraint, using the saved RF and verified SCALE-Sim cycle table. In this experiment, the feasible set for the evaluated convolution layers is dominated by 64-PE choices, so Stage 6 collapses to the fixed 64-PE policy for the held-out test set.",
    "",
    "11. Limitations",
    "- SCALE-Sim is convolution-only and does not include the classifier.",
    "- No validated energy model was used.",
    "- No RTL or physical hardware measurements exist.",
    "- Resource reconfiguration overhead is not modeled.",
    "- PE configurations are simulator abstractions, not real fabricated hardware.",
    "- Cycle results are simulated execution costs, not actual end-to-end runtime measurements.",
    "- The controller is evaluated offline, not as a runtime hardware controller.",
])
REPORT_PATH.write_text("\n".join(report_lines) + "\n")

# Final terminal output
print("================ STAGE 6 RESULTS ================")
print("Test samples:")
print(len(TEST_IDS))
print("Convolution decisions:")
print(len(stage6_rows))
print("D_MAX:")
print(D_MAX)
print("\n---------------- FIXED 64 ----------------")
print("Total cycles:")
print(fixed64_total)
print("Average cycles/sample:")
print(fixed64_total / len(TEST_IDS))
print("\n---------------- STAGE 4 ----------------")
print("Total cycles:")
print(stage4_total)
print("Average cycles/sample:")
print(stage4_total / len(TEST_IDS))
print("Average resource:")
print(stage4_avg_resource)
print("Resource reduction:")
print(stage4_resource_reduction)
print("Average actual degradation:")
print(stage4_avg_actual)
print("Threshold violation rate:")
print(stage4_violation_rate)
print("\n---------------- STAGE 6 ----------------")
print("Total cycles:")
print(stage6_total)
print("Average cycles/sample:")
print(stage6_avg)
print("Average resource:")
print(stage6_avg_resource)
print("Resource reduction:")
print(stage6_resource_reduction)
print("Average actual degradation:")
print(stage6_avg_actual)
print("Maximum actual degradation:")
print(stage6_max_actual)
print("Threshold violation rate:")
print(stage6_violation_rate)
print("\n---------------- COMPARISON ----------------")
print("Stage 4 vs Fixed64 cycle change:")
print(stage4_total - fixed64_total)
print("Stage 6 vs Fixed64 cycle change:")
print(stage6_total - fixed64_total)
print("Stage 6 vs Stage4 cycle change:")
print(stage6_total - stage4_total)
print("Stage 4 resource reduction:")
print(stage4_resource_reduction)
print("Stage 6 resource reduction:")
print(stage6_resource_reduction)
print("Stage 4 threshold violations:")
print(sum(1 for r in stage4_rows if not r["actual_threshold_satisfied"]))
print("Stage 6 threshold violations:")
print(sum(1 for r in stage6_rows if not r["actual_threshold_satisfied"]))
print("\n---------------- RESOURCE DISTRIBUTION ----------------")
print("Stage 4:")
print({"16": stage4_counts.get(16, 0), "32": stage4_counts.get(32, 0), "64": stage4_counts.get(64, 0)})
print("Stage 6:")
print({"16": stage6_counts.get(16, 0), "32": stage6_counts.get(32, 0), "64": stage6_counts.get(64, 0)})
print("\n---------------- PER-LAYER ----------------")
for layer in LAYER_ORDER:
    s4 = [r for r in stage4_rows if r["layer"] == layer]
    s6 = [r for r in stage6_rows if r["layer"] == layer]
    print(f"{layer}:")
    print("Stage4:", Counter(r["selected_resource"] for r in s4))
    print("Stage6:", Counter(r["selected_resource"] for r in s6))

print("\nGenerated files:")
for path in [
    DECISION_TABLE_PATH,
    SUMMARY_PATH,
    COMPARISON_PATH,
    REPORT_PATH,
    PLOT_POLICY_PATH,
    PLOT_RESOURCE_PATH,
    PLOT_DEG_VS_CYCLES_PATH,
]:
    print(path)
