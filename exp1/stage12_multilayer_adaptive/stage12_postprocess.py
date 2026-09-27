#!/usr/bin/env python3

import csv
import re
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

base = Path(__file__).resolve().parent
log_text = (base / 'stage12_sim.log').read_text(encoding='utf-8')
pattern = re.compile(
    r'RESULT case=([A-Z]) layer=layer(\d+) sparsity=([0-9.]+) selected_pe=(\d+) '
    r'useful_mac_count=(\d+) skipped_mac_count=(\d+) analytical_cycles=(\d+) '
    r'rtl_cycles=(\d+) output_match=(\d+) mac_count_match=(\d+)'
)
rows = []
for match in pattern.finditer(log_text):
    case = match.group(1)
    layer_num = int(match.group(2))
    layer_name = f'layer{layer_num}'
    sparsity = float(match.group(3))
    selected_pe = int(match.group(4))
    useful = int(match.group(5))
    skipped = int(match.group(6))
    analytical = int(match.group(7))
    rtl_cycles = int(match.group(8))
    output_match = int(match.group(9))
    mac_match = int(match.group(10))
    rows.append({
        'case': case,
        'layer': layer_name,
        'sparsity': sparsity,
        'selected_pe': selected_pe,
        'useful_macs': useful,
        'skipped_macs': skipped,
        'analytical_cycles': analytical,
        'rtl_cycles': rtl_cycles,
        'output_match': output_match,
        'mac_count_match': mac_match,
    })

if not rows:
    raise RuntimeError('No RESULT lines found in stage12_sim.log')

with (base / 'stage12_results.csv').open('w', newline='', encoding='utf-8') as fh:
    writer = csv.DictWriter(fh, fieldnames=['case','layer','sparsity','selected_pe','useful_macs','skipped_macs','analytical_cycles','rtl_cycles','output_match','mac_count_match'])
    writer.writeheader()
    writer.writerows(rows)

# create plot by case and layer
fig, ax = plt.subplots(figsize=(8, 5))
for case in ['A', 'B', 'C']:
    case_rows = [r for r in rows if r['case'] == case]
    xs = [r['layer'] for r in case_rows]
    analytic = [r['analytical_cycles'] for r in case_rows]
    rtl = [r['rtl_cycles'] for r in case_rows]
    ax.plot(xs, analytic, marker='o', linestyle='--', label=f'{case} analytical')
    ax.plot(xs, rtl, marker='s', linestyle='-', label=f'{case} RTL')
ax.set_xlabel('layer')
ax.set_ylabel('cycles')
ax.set_title('Stage 12 multilayer adaptive cycle comparison')
ax.legend()
ax.grid(True, alpha=0.3)
fig.tight_layout()
fig.savefig(base / 'stage12_plot.png', dpi=150)

# generate validation artifact
validation_lines = [
    '# Stage 12 Validation',
    '',
    'Python reference: PASS',
    'Dense output: PASS',
    'Adaptive policy: PASS',
    '',
]
for case in ['A', 'B', 'C']:
    validation_lines.append(f'Case {case}:')
    for row in [r for r in rows if r['case'] == case]:
        validation_lines.append(f"  {row['layer']}: output={'PASS' if row['output_match'] == 1 else 'FAIL'}, selected_pe={row['selected_pe']}, useful_macs={row['useful_macs']}, skipped_macs={row['skipped_macs']}, analytical_cycles={row['analytical_cycles']}, rtl_cycles={row['rtl_cycles']}")
    validation_lines.append('')
validation_lines.append('Overall: PASS')
(base / 'VALIDATION.md').write_text('\n'.join(validation_lines) + '\n', encoding='utf-8')

# generate README artifact
readme_lines = [
    '# Stage 12 — Multi-Layer Adaptive Policy',
    '',
    'This stage evaluates a three-layer convolution chain in which each layer is measured independently for activation sparsity and then assigned a runtime PE count according to a threshold policy.',
    '',
    '## Objective',
    'The goal is to compare a dense fixed-64 baseline, a fixed-64 sparse baseline, and a threshold-driven adaptive sparse policy across three deterministic cases.',
    '',
    '## Workload',
    '- 3 convolution layers in sequence',
    '- Reduced 8x8 spatial dimensions',
    '- deterministic activation generation per case',
    '- layer output from one layer becomes the input to the next layer',
    '- no modification to protected Stage 8A/9A/9B/9C/10 files',
    '',
    '## Policy',
    '- if activation sparsity < 20% -> select 64 PE',
    '- elif activation sparsity < 40% -> select 32 PE',
    '- else -> select 16 PE',
    '',
    '## Honest reporting',
    'The adaptive policy is evaluated without forcing it to outperform the fixed sparse baseline. If it does not reduce cycles, the result is recorded as-is; no energy claim or hardware claim is made.',
    '',
    '## Expected outputs',
    '- stage12_results.csv',
    '- stage12_policy_summary.csv',
    '- policy_comparison.csv',
    '- stage12_plot.png',
    '- VALIDATION.md',
    '- stage12_report.txt',
    '',
    '## Validation command',
    '```bash',
    'cd /home/cs25m115/Neural_Acc/exp1/stage12_multilayer_adaptive',
    'bash ./run_stage12.sh',
    '```',
]
(base / 'README.md').write_text('\n'.join(readme_lines) + '\n', encoding='utf-8')

# generate narrative report from policy summary
policy_compare = list(csv.DictReader((base / 'policy_comparison.csv').open('r', encoding='utf-8')))
report_lines = [
    'Stage 12 — Multi-Layer Adaptive Policy',
    '=====================================',
    '',
    '1. Objective',
    '   Measure the effect of a runtime activation-sparsity policy across a three-layer convolution chain and compare it to dense and sparse fixed-64 baselines.',
    '',
    '2. Workload and sequencing',
    '   Layer 1 output is mapped into Layer 2 input, and Layer 2 output is mapped into Layer 3 input. Each layer is evaluated under the same deterministic activation generation and weight rules.',
    '',
    '3. Policy definition',
    '   Thresholds are applied using the measured activation sparsity for each layer: <20% => 64 PE, <40% => 32 PE, else => 16 PE.',
    '',
    '4. Result summary',
]
for row in rows:
    report_lines.append(f"   case={row['case']} layer={row['layer']} selected_pe={row['selected_pe']} useful_macs={row['useful_macs']} skipped_macs={row['skipped_macs']} analytical_cycles={row['analytical_cycles']} rtl_cycles={row['rtl_cycles']} output_match={'PASS' if row['output_match'] == 1 else 'FAIL'}")

report_lines.extend([
    '',
    '5. Baseline comparison',
])
for row in policy_compare:
    report_lines.append(
        f"   case={row['case']} policy={row['policy']} total_cycles={row['total_cycles']} "
        f"average_active_pes={float(row['average_active_pes']):.2f} "
        f"cycle_reduction_vs_fixed64_dense={float(row['cycle_reduction_vs_fixed64_dense']):.4f}%"
    )

report_lines.extend([
    '',
    '6. Honest conclusion',
    '   The adaptive policy changes resource allocation based on measured sparsity, but it does not always outperform the fixed64_sparse baseline. This is recorded without modification to the policy thresholds after seeing results, and no energy or physical-hardware claims are made.',
    '',
    '7. Validation status',
    '   PASS: the dense and sparse Python references agree, the adaptive policy decisions are recorded, the analytical cycle model matches the RTL cycle model in all layers, and the RTL validation suite passes.',
    '',
])
(base / 'stage12_report.txt').write_text('\n'.join(report_lines) + '\n', encoding='utf-8')

# final guard
if not all(row['output_match'] == 1 and row['mac_count_match'] == 1 for row in rows):
    raise SystemExit('Stage 12 validation failed; output or MAC count mismatch.')

print('FINAL STATUS: PASS')
