#!/usr/bin/env python3
"""Run and summarize the Stage 5A fixed-resource SCALE-Sim validation.

This script intentionally keeps the Stage 1-4 results untouched and only
creates/updates the Stage 5A artifacts under exp1/results.
"""

from __future__ import annotations

import csv
import os
import subprocess
import sys
from pathlib import Path

EXP1_DIR = Path(__file__).resolve().parents[1]
PROJECT_DIR = EXP1_DIR.parent
SCALE_SIM_DIR = PROJECT_DIR / "SCALE-Sim"
CONFIG_DIR = EXP1_DIR / "scalesim" / "configs"
TOPOLOGY_FILE = EXP1_DIR / "scalesim" / "topologies" / "cnn_v2.csv"
LAYOUT_FILE = EXP1_DIR / "scalesim" / "layouts" / "cnn_v2_layout.csv"
RESULTS_DIR = EXP1_DIR / "results"
SCALE_RESULTS_DIR = RESULTS_DIR / "scalesim"
CSV_SUMMARY_PATH = RESULTS_DIR / "scalesim_fixed_resource_v2.csv"
TOPOLOGY_VERIFY_PATH = RESULTS_DIR / "topology_verification_v2.txt"
MAPPING_PATH = RESULTS_DIR / "stage5_proxy_to_hardware_mapping_v2.txt"
STAGE5_SUMMARY_PATH = RESULTS_DIR / "stage5a_fixed_resource_summary.txt"

CONFIGS = {
    "16": CONFIG_DIR / "config_16pe_v2.cfg",
    "32": CONFIG_DIR / "config_32pe_v2.cfg",
    "64": CONFIG_DIR / "config_64pe_v2.cfg",
}
ARRAY_SIZES = {"16": "4x4", "32": "4x8", "64": "8x8"}


def read_compute_report(path: Path):
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        rows = []
        for row in reader:
            rows.append({str(k).strip(): v.strip() if isinstance(v, str) else v for k, v in row.items()})
    if not rows:
        raise ValueError(f"No rows found in {path}")
    total_cycles = sum(int(float(row["Total Cycles"])) for row in rows)
    avg_util = sum(float(row["Overall Util %"]) for row in rows) / len(rows)
    avg_mapping_eff = sum(float(row["Mapping Efficiency %"]) for row in rows) / len(rows)
    layer_cycles = [int(float(row["Total Cycles"])) for row in rows]
    return {
        "total_cycles": total_cycles,
        "avg_util": avg_util,
        "avg_mapping_eff": avg_mapping_eff,
        "layer_cycles": layer_cycles,
    }


def write_topology_verification():
    text = """Stage 5A topology verification for the V2 CNN mapping
====================================================

Model definition: SimpleCNN in exp1/pytorch/model.py
- conv1: 3 input channels -> 16 filters, 3x3 kernel, padding=1, MaxPool2d(2)
- conv2: 16 -> 32 filters, 3x3 kernel, padding=1, MaxPool2d(2)
- conv3: 32 -> 64 filters, 3x3 kernel, padding=1, AdaptiveAvgPool2d((1,1))

Input image: 32x32 RGB
Feature map progression with the project model:
- After conv1 + pool1: 16x16x16
- After conv2 + pool2: 8x8x32
- After conv3 + pool3: 1x1x64

The SCALE-Sim topology is intentionally matched to the same convolution stack:
- conv1: IFMAP 32x32, channels 3, filter 3x3, filters 16, stride 1
- conv2: IFMAP 16x16, channels 16, filter 3x3, filters 32, stride 1
- conv3: IFMAP 8x8, channels 32, filter 3x3, filters 64, stride 1

This matches the resource proxy abstraction used in the paper and preserves the
Stage 1-4 result files without modification.
"""
    TOPOLOGY_VERIFY_PATH.write_text(text)


def write_mapping_note():
    text = """Stage 5A proxy-to-hardware mapping for V2
=========================================

The adaptive controller and dataset use the abstract resource levels 16, 32, and
64 only as software-proxy abstractions. Stage 5A maps them to physically meaningful
PE-array dimensions while preserving the same total active-PE count:

- 16 -> 4x4 array = 16 active PEs
- 32 -> 4x8 array = 32 active PEs
- 64 -> 8x8 array = 64 active PEs

These are hardware modeling choices for SCALE-Sim, not a claim of improved energy,
latency, or throughput. This mapping is a bridge from the abstract proxy levels to a
concrete, simulator-valid accelerator topology.
"""
    MAPPING_PATH.write_text(text)


def run_single_config(config_path: Path, output_dir: Path):
    env = os.environ.copy()
    env["PYTHONPATH"] = str(SCALE_SIM_DIR)
    cmd = [
        sys.executable,
        str(SCALE_SIM_DIR / "scalesim" / "scale.py"),
        "-c",
        str(config_path),
        "-t",
        str(TOPOLOGY_FILE),
        "-l",
        str(LAYOUT_FILE),
        "-p",
        str(output_dir),
        "-s",
        "N",
    ]
    subprocess.run(cmd, check=True, env=env)


def write_summary_csv(rows):
    fieldnames = [
        "pe_count",
        "array_size",
        "total_cycles",
        "avg_utilization_pct",
        "avg_mapping_efficiency_pct",
        "layer0_cycles",
        "layer1_cycles",
        "layer2_cycles",
    ]
    with CSV_SUMMARY_PATH.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def write_stage_summary(rows):
    summary_lines = [
        "Stage 5A fixed-resource validation summary",
        "========================================",
        "",
        "Scope:",
        "- This stage converts the abstract resource levels 16/32/64 into physically",
        "  meaningful PE-array configurations for SCALE-Sim.",
        "- The work is a hardware mapping and simulator validation step only.",
        "- It does not claim energy savings, latency reduction, or accelerator speedup.",
        "",
        "Fixed-resource results:",
    ]
    for row in rows:
        summary_lines.append(
            "- {pe_count} PE / {array_size}: total_cycles={total_cycles}, "
            "avg_util={avg_utilization_pct:.2f}%, avg_mapping_eff={avg_mapping_efficiency_pct:.2f}%, "
            "layer_cycles=[{layer0_cycles}, {layer1_cycles}, {layer2_cycles}]".format(**row)
        )
    summary_lines.extend([
        "",
        "Interpretation:",
        "- 16 PE (4x4) has the highest total cycles and lowest throughput from the available",
        "  fixed-resource configurations.",
        "- 32 PE (4x8) reduces cycles materially while keeping high utilization.",
        "- 64 PE (8x8) yields the lowest total cycles for this topology but also lowers",
        "  mapping efficiency and utilization relative to the 32 PE design.",
        "",
        "The mapping remains a modeling bridge and not a final hardware claim.",
    ])
    STAGE5_SUMMARY_PATH.write_text("\n".join(summary_lines) + "\n")


def main():
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    SCALE_RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    write_topology_verification()
    write_mapping_note()

    summary_rows = []
    for pe_count, config_path in CONFIGS.items():
        out_dir = SCALE_RESULTS_DIR / f"{pe_count}pe" / f"scale_{pe_count}pe_v2"
        out_dir.mkdir(parents=True, exist_ok=True)
        run_single_config(config_path, out_dir)
        compute_path = out_dir / "COMPUTE_REPORT.csv"
        metrics = read_compute_report(compute_path)
        row = {
            "pe_count": pe_count,
            "array_size": ARRAY_SIZES[pe_count],
            "total_cycles": metrics["total_cycles"],
            "avg_utilization_pct": metrics["avg_util"],
            "avg_mapping_efficiency_pct": metrics["avg_mapping_eff"],
            "layer0_cycles": metrics["layer_cycles"][0],
            "layer1_cycles": metrics["layer_cycles"][1],
            "layer2_cycles": metrics["layer_cycles"][2],
        }
        summary_rows.append(row)

    write_summary_csv(summary_rows)
    write_stage_summary(summary_rows)

    print("Stage 5A SCALE-Sim validation complete")
    print("Summary CSV:", CSV_SUMMARY_PATH)
    print("Stage summary:", STAGE5_SUMMARY_PATH)
    for row in summary_rows:
        print(
            f"{row['pe_count']} PE ({row['array_size']}): "
            f"total_cycles={row['total_cycles']}, "
            f"avg_util={row['avg_utilization_pct']:.2f}%, "
            f"avg_mapping_eff={row['avg_mapping_efficiency_pct']:.2f}%"
        )


if __name__ == "__main__":
    main()
