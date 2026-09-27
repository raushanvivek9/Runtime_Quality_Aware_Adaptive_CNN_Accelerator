#!/usr/bin/env python3

import csv
from math import ceil
from pathlib import Path

from stage11_python_reference import compute_reference_stats

ACTIVE_PES = [16, 32, 64]

def main():
    stats = compute_reference_stats()
    rows = []
    for active_pe in ACTIVE_PES:
        dense_cycles = ceil(stats['dense_mac_count'] / active_pe)
        sparse_cycles = ceil(stats['useful_mac_count'] / active_pe)
        reduction = ((dense_cycles - sparse_cycles) / dense_cycles) * 100.0 if dense_cycles else 0.0
        rows.append({
            'resource': f'{active_pe}',
            'active_pes': active_pe,
            'dense_macs': stats['dense_mac_count'],
            'useful_macs': stats['useful_mac_count'],
            'skipped_macs': stats['skipped_mac_count'],
            'effective_sparsity': stats['effective_sparsity_percent'],
            'dense_cycles': dense_cycles,
            'sparse_cycles': sparse_cycles,
            'cycle_reduction_percent': reduction,
        })

    csv_path = Path(__file__).with_name('stage11_analytical_results.csv')
    with csv_path.open('w', newline='', encoding='utf-8') as fh:
        writer = csv.DictWriter(fh, fieldnames=['resource','active_pes','dense_macs','useful_macs','skipped_macs','effective_sparsity','dense_cycles','sparse_cycles','cycle_reduction_percent'])
        writer.writeheader()
        writer.writerows(rows)

    for row in rows:
        print(row)

    if not stats['dense_match']:
        raise SystemExit('Dense/sparse equality check failed in analytical model.')


if __name__ == '__main__':
    main()
