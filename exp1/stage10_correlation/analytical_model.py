#!/usr/bin/env python3

import csv
import math
from pathlib import Path

H = 8
W = 8
Cin = 3
Cout = 16
Kh = 3
Kw = 3
active_pes = [16, 32, 64]


def analytical_cycles(active_pe):
    total_macs = H * W * Cout * Cin * Kh * Kw
    return math.ceil(total_macs / active_pe)


def main():
    total_outputs = H * W * Cout
    macs_per_output = Cin * Kh * Kw
    total_macs = total_outputs * macs_per_output
    rows = []
    for active_pe in active_pes:
        rows.append({
            "resource": str(active_pe),
            "active_pes": active_pe,
            "total_outputs": total_outputs,
            "macs_per_output": macs_per_output,
            "total_macs": total_macs,
            "analytical_compute_cycles": analytical_cycles(active_pe),
        })

    expected = {16: 1728, 32: 864, 64: 432}
    for row in rows:
        if row["analytical_compute_cycles"] != expected[row["active_pes"]]:
            raise ValueError(f"analytical mismatch for {row['active_pes']} PE: got {row['analytical_compute_cycles']}, expected {expected[row['active_pes']]}")

    with Path(__file__).with_name("analytical_results.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "resource",
            "active_pes",
            "total_outputs",
            "macs_per_output",
            "total_macs",
            "analytical_compute_cycles",
        ])
        writer.writeheader()
        writer.writerows(rows)

    print("ANALYTICAL MODEL: PASS")
    for row in rows:
        print(row)


if __name__ == "__main__":
    main()
