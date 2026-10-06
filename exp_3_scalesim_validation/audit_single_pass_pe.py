#!/usr/bin/env python3
"""Audit frozen Stage 13.1 PE choices against verified single-pass MACs."""
from __future__ import annotations

import csv
import math
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXP3 = Path(__file__).resolve().parent
STAGE13_RESULTS = ROOT / "exp1" / "stage13_1_baseline_preserving_pe" / "results"
STAGE12_RESULTS = ROOT / "exp1" / "stage12_final_evaluation_v3" / "results"
OUTPUT = EXP3 / "results" / "final_experiment" / "stage13_1_single_pass_pe_audit.csv"
SUMMARY = EXP3 / "results" / "final_experiment" / "stage13_1_single_pass_pe_audit.txt"


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def main() -> int:
    frozen = read_csv(STAGE13_RESULTS / "layerwise_results.csv")
    single = read_csv(STAGE12_RESULTS / "per_layer_sparsity.csv")
    frozen_groups: dict[tuple[str, str], list[dict[str, str]]] = {}
    single_groups: dict[tuple[str, str], list[dict[str, str]]] = {}
    for row in frozen:
        frozen_groups.setdefault((row["model"], row["dataset"]), []).append(row)
    for row in single:
        single_groups.setdefault((row["model"], row["dataset"]), []).append(row)

    comparisons: list[dict[str, object]] = []
    for key, frozen_rows in frozen_groups.items():
        single_rows = single_groups.get(key, [])
        if len(frozen_rows) != len(single_rows):
            raise RuntimeError(f"layer count mismatch for {key}")
        for frozen_row, single_row in zip(frozen_rows, single_rows):
            dense_macs = int(single_row["dense_macs"])
            useful_macs = int(single_row["useful_macs"])
            baseline_cycles = math.ceil(dense_macs / 64)
            candidate_cycles = {pe: math.ceil(useful_macs / pe) for pe in (16, 32, 64)}
            recomputed = next(pe for pe in (16, 32, 64) if candidate_cycles[pe] <= baseline_cycles)
            frozen_pe = int(frozen_row["selected_pe"])
            comparisons.append({
                "model": key[0], "dataset": key[1], "layer_index": frozen_row["layer_index"],
                "layer": frozen_row["layer_name"], "frozen_selected_pe": frozen_pe,
                "dense_macs_single_pass": dense_macs, "useful_macs_single_pass": useful_macs,
                "frozen_useful_macs": frozen_row["mac_useful"], "baseline_dense64_cycles": baseline_cycles,
                "cycles_16_single_pass": candidate_cycles[16], "cycles_32_single_pass": candidate_cycles[32],
                "cycles_64_single_pass": candidate_cycles[64], "recomputed_selected_pe": recomputed,
                "same_pe": "PASS" if frozen_pe == recomputed else "FAIL",
            })

    if len(comparisons) != 66:
        raise RuntimeError(f"expected 66 comparisons, found {len(comparisons)}")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(comparisons[0]))
        writer.writeheader()
        writer.writerows(comparisons)

    frozen_distribution = Counter(int(row["frozen_selected_pe"]) for row in comparisons)
    corrected_distribution = Counter(int(row["recomputed_selected_pe"]) for row in comparisons)
    changed = [row for row in comparisons if row["same_pe"] == "FAIL"]
    summary = [
        "Stage 13.1 single-pass PE allocation audit",
        "===========================================",
        f"layers audited: {len(comparisons)}",
        f"same PE count: {len(comparisons) - len(changed)}",
        f"changed PE count: {len(changed)}",
        f"frozen PE distribution: 16={frozen_distribution[16]}, 32={frozen_distribution[32]}, 64={frozen_distribution[64]}",
        f"corrected PE distribution: 16={corrected_distribution[16]}, 32={corrected_distribution[32]}, 64={corrected_distribution[64]}",
        f"audit status: {'PASS' if not changed else 'STOP'}",
    ]
    if changed:
        summary.append("changed layers:")
        summary.extend(f"{row['model']}/{row['dataset']} layer {row['layer_index']} {row['layer']}: frozen={row['frozen_selected_pe']}, recomputed={row['recomputed_selected_pe']}" for row in changed)
    SUMMARY.write_text("\n".join(summary) + "\n", encoding="utf-8")
    print("\n".join(summary))
    return 0 if not changed else 2


if __name__ == "__main__":
    raise SystemExit(main())
