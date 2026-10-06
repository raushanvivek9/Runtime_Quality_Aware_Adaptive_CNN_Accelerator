#!/usr/bin/env python3
"""Validate row-wise sparse scheduling against frozen Stage 13.1 counts."""
from __future__ import annotations

import csv
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXP3 = ROOT / "exp_3_scalesim_validation"
STAGE131 = ROOT / "exp1" / "stage13_1_baseline_preserving_pe" / "results" / "layerwise_results.csv"
sys.path.insert(0, str(EXP3))

from sparse_scheduler import schedule_row_work


def main() -> None:
    checked = 0
    with STAGE131.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            dense_macs = int(row["mac_dense"])
            useful_macs = int(row["mac_useful"])
            pe_count = int(row["selected_pe"])
            result = schedule_row_work((useful_macs,), dense_macs, pe_count)
            expected_dense_cycles = math.ceil(dense_macs / pe_count)
            expected_sparse_cycles = math.ceil(useful_macs / pe_count)
            assert result.useful_macs == useful_macs
            assert result.skipped_macs == int(row["mac_skipped"])
            assert result.dense_cycles == expected_dense_cycles
            assert result.sparse_cycles == expected_sparse_cycles
            assert result.sparse_cycles == int(row["selected_cycles"])
            checked += 1
    print(f"validated {checked} Stage 13.1 layer rows")


if __name__ == "__main__":
    main()