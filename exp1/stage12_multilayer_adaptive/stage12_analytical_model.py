#!/usr/bin/env python3

import csv
import json
from math import ceil
from pathlib import Path

base = Path(__file__).resolve().parent
summary = json.loads((base / 'stage12_python_summary.json').read_text(encoding='utf-8'))
policy = list(csv.DictReader((base / 'policy_decisions.csv').open('r', encoding='utf-8')))

fixed64_dense_rows = []
fixed64_sparse_rows = []
adaptive_rows = []

for case_name in ['A', 'B', 'C']:
    for layer in summary[case_name]:
        dense_macs = int(layer['dense_macs'])
        useful_macs = int(layer['useful_macs'])
        skipped = int(layer['skipped_macs'])
        dense64 = ceil(dense_macs / 64)
        sparse64 = ceil(useful_macs / 64)
        fixed64_dense_rows.append({
            'case': case_name,
            'layer': layer['layer'],
            'policy': 'fixed64_dense',
            'cycles': dense64,
            'dense_macs': dense_macs,
            'useful_macs': useful_macs,
            'skipped_macs': skipped,
        })
        fixed64_sparse_rows.append({
            'case': case_name,
            'layer': layer['layer'],
            'policy': 'fixed64_sparse',
            'cycles': sparse64,
            'dense_macs': dense_macs,
            'useful_macs': useful_macs,
            'skipped_macs': skipped,
        })

        decision = next(item for item in policy if item['case'] == case_name and item['layer'] == layer['layer'])
        adaptive_cycles = ceil(useful_macs / int(decision['active_pes']))
        adaptive_rows.append({
            'case': case_name,
            'layer': layer['layer'],
            'policy': 'adaptive_sparse',
            'selected_pe': int(decision['active_pes']),
            'cycles': adaptive_cycles,
            'dense_macs': dense_macs,
            'useful_macs': useful_macs,
            'skipped_macs': skipped,
            'sparsity': float(decision['sparsity']),
        })

with (base / 'stage12_policy_summary.csv').open('w', newline='', encoding='utf-8') as fh:
    writer = csv.DictWriter(fh, fieldnames=['case', 'layer', 'policy', 'cycles', 'dense_macs', 'useful_macs', 'skipped_macs', 'selected_pe', 'sparsity'])
    writer.writeheader()
    for row in fixed64_dense_rows:
        row['selected_pe'] = 64
        row['sparsity'] = 0.0
        writer.writerow(row)
    for row in fixed64_sparse_rows:
        row['selected_pe'] = 64
        row['sparsity'] = 0.0
        writer.writerow(row)
    for row in adaptive_rows:
        writer.writerow(row)

policy_compare = []
for case_name in ['A', 'B', 'C']:
    case_rows = [r for r in adaptive_rows if r['case'] == case_name]
    dense_total = sum(r['cycles'] for r in fixed64_dense_rows if r['case'] == case_name)
    sparse_total = sum(r['cycles'] for r in fixed64_sparse_rows if r['case'] == case_name)
    adaptive_total = sum(r['cycles'] for r in case_rows)
    avg_pe = sum(r['selected_pe'] for r in case_rows) / len(case_rows)
    policy_compare.append({
        'case': case_name,
        'policy': 'fixed64_dense',
        'total_cycles': dense_total,
        'average_active_pes': 64.0,
        'total_dense_macs': sum(r['dense_macs'] for r in fixed64_dense_rows if r['case'] == case_name),
        'total_useful_macs': sum(r['useful_macs'] for r in fixed64_dense_rows if r['case'] == case_name),
        'total_skipped_macs': sum(r['skipped_macs'] for r in fixed64_dense_rows if r['case'] == case_name),
        'cycle_reduction_vs_fixed64_dense': 0.0,
    })
    policy_compare.append({
        'case': case_name,
        'policy': 'fixed64_sparse',
        'total_cycles': sparse_total,
        'average_active_pes': 64.0,
        'total_dense_macs': sum(r['dense_macs'] for r in fixed64_sparse_rows if r['case'] == case_name),
        'total_useful_macs': sum(r['useful_macs'] for r in fixed64_sparse_rows if r['case'] == case_name),
        'total_skipped_macs': sum(r['skipped_macs'] for r in fixed64_sparse_rows if r['case'] == case_name),
        'cycle_reduction_vs_fixed64_dense': ((dense_total - sparse_total) / dense_total) * 100.0 if dense_total else 0.0,
    })
    policy_compare.append({
        'case': case_name,
        'policy': 'adaptive_sparse',
        'total_cycles': adaptive_total,
        'average_active_pes': avg_pe,
        'total_dense_macs': sum(r['dense_macs'] for r in case_rows),
        'total_useful_macs': sum(r['useful_macs'] for r in case_rows),
        'total_skipped_macs': sum(r['skipped_macs'] for r in case_rows),
        'cycle_reduction_vs_fixed64_dense': ((dense_total - adaptive_total) / dense_total) * 100.0 if dense_total else 0.0,
    })

with (base / 'policy_comparison.csv').open('w', newline='', encoding='utf-8') as fh:
    writer = csv.DictWriter(fh, fieldnames=['case', 'policy', 'total_cycles', 'average_active_pes', 'total_dense_macs', 'total_useful_macs', 'total_skipped_macs', 'cycle_reduction_vs_fixed64_dense'])
    writer.writeheader()
    writer.writerows(policy_compare)

print('analytical summary written')
for r in policy_compare:
    print(r)
