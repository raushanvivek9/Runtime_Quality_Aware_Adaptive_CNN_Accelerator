#!/usr/bin/env python3

import csv
import json
from math import ceil
from pathlib import Path

base = Path(__file__).resolve().parent
summary = json.loads((base / 'stage12_python_summary.json').read_text(encoding='utf-8'))
rows = []

for case_name in ['A', 'B', 'C']:
    for layer in summary[case_name]:
        sparsity = float(layer['activation_sparsity'])
        if sparsity < 20.0:
            selected_pe = 64
        elif sparsity < 40.0:
            selected_pe = 32
        else:
            selected_pe = 16
        useful = int(layer['useful_macs'])
        skipped = int(layer['skipped_macs'])
        analytical_cycles = ceil(useful / selected_pe)
        rows.append({
            'case': case_name,
            'layer': layer['layer'],
            'sparsity': sparsity,
            'selected_resource': ('64 PE' if selected_pe == 64 else '32 PE' if selected_pe == 32 else '16 PE'),
            'active_pes': selected_pe,
            'useful_macs': useful,
            'skipped_macs': skipped,
            'analytical_cycles': analytical_cycles,
        })

with (base / 'policy_decisions.csv').open('w', newline='', encoding='utf-8') as fh:
    writer = csv.DictWriter(fh, fieldnames=['case', 'layer', 'sparsity', 'selected_resource', 'active_pes', 'useful_macs', 'skipped_macs', 'analytical_cycles'])
    writer.writeheader()
    writer.writerows(rows)

print('Policy decisions written to policy_decisions.csv')
for row in rows:
    print(row)
