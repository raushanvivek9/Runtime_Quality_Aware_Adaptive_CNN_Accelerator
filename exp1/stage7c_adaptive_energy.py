#!/usr/bin/env python3
from __future__ import annotations

import csv
from collections import defaultdict
from pathlib import Path

ROOT = Path('/home/cs25m115/Neural_Acc')
RESULTS = ROOT / 'exp1' / 'results'
ENERGY = ROOT / 'exp1' / 'stage7c_per_layer_energy' / 'reports' / 'stage7c_per_layer_energy.csv'
OUT = ROOT / 'exp1' / 'stage7c_adaptive_energy'
DECISIONS = RESULTS / 'controller_decisions_v2.csv'
ACTUALS = RESULTS / 'quality_dataset_v2.csv'
D_MAX = 0.05
RESOURCES = (16, 32, 64)
LAYERS = ('conv1', 'conv2', 'conv3')
ENERGY_UNIT = 'Accelergy output units; physical unit not specified in YAML'


def read_energy():
    values = {}
    with ENERGY.open(newline='') as handle:
        for row in csv.DictReader(handle):
            values[(row['layer'], int(row['resource']))] = {
                'energy': float(row['total_energy']),
                'cycles': float(row['total_cycles']),
            }
    expected = {(layer, resource) for layer in LAYERS for resource in RESOURCES}
    missing = expected - values.keys()
    if missing:
        raise RuntimeError(f'missing energy lookups: {sorted(missing)}')
    return values


def read_actuals():
    values = {}
    with ACTUALS.open(newline='') as handle:
        for row in csv.DictReader(handle):
            if row['layer'] in LAYERS:
                values[(int(row['sample_id']), row['layer'], int(row['resource_level']))] = float(row['degradation'])
    return values


def read_decisions(actuals):
    grouped = defaultdict(dict)
    with DECISIONS.open(newline='') as handle:
        for row in csv.DictReader(handle):
            if row['layer'] in LAYERS:
                grouped[int(row['sample_id'])][row['layer']] = row
    if len(grouped) != 19:
        raise RuntimeError(f'expected 19 samples, found {len(grouped)}')
    sample_ids = sorted(grouped)
    expected_layers = set(LAYERS)
    for sample_id in sample_ids:
        if set(grouped[sample_id]) != expected_layers:
            raise RuntimeError(f'sample {sample_id} does not have exactly conv1/conv2/conv3')
        for layer in LAYERS:
            resource = int(grouped[sample_id][layer]['selected_resource'])
            if resource not in RESOURCES:
                raise RuntimeError(f'invalid Stage 4 resource {resource}')
    for sample_id in sample_ids:
        for layer in LAYERS:
            for resource in RESOURCES:
                if (sample_id, layer, resource) not in actuals:
                    raise RuntimeError(f'missing actual degradation for sample {sample_id}, {layer}, {resource}')
    return grouped


def selected_metrics(selections, energy):
    total_energy = sum(energy[(layer, selections[layer])]['energy'] for layer in LAYERS)
    total_cycles = sum(energy[(layer, selections[layer])]['cycles'] for layer in LAYERS)
    return total_energy, total_cycles


def write_csv(path, rows, fields):
    with path.open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    energy = read_energy()
    actuals = read_actuals()
    decisions = read_decisions(actuals)
    fixed_energy = sum(energy[(layer, 64)]['energy'] for layer in LAYERS)
    fixed_cycles = sum(energy[(layer, 64)]['cycles'] for layer in LAYERS)
    if fixed_energy != 17428277.0 or fixed_cycles != 39773.0:
        raise RuntimeError('fixed-64 baseline does not match required Stage 7C-1 values')

    per_sample = []
    policy_rows = []
    for sample_id in sorted(decisions):
        stage4 = {layer: int(decisions[sample_id][layer]['selected_resource']) for layer in LAYERS}
        predicted = {
            layer: {resource: float(decisions[sample_id][layer][f'predicted_D_{resource}']) for resource in RESOURCES}
            for layer in LAYERS
        }
        actual = {layer: float(decisions[sample_id][layer]['actual_D_selected']) for layer in LAYERS}
        energy_policy = {}
        fallback = {}
        for layer in LAYERS:
            feasible = [resource for resource in RESOURCES if predicted[layer][resource] <= D_MAX]
            if feasible:
                energy_policy[layer] = min(feasible, key=lambda resource: energy[(layer, resource)]['energy'])
                fallback[layer] = False
            else:
                energy_policy[layer] = 64
                fallback[layer] = True
        stage4_energy, stage4_cycles = selected_metrics(stage4, energy)
        policy_energy, policy_cycles = selected_metrics(energy_policy, energy)
        stage4_violations = sum(actual[layer] > D_MAX for layer in LAYERS)
        policy_actual = {layer: actuals[(sample_id, layer, energy_policy[layer])] for layer in LAYERS}
        policy_violations = sum(value > D_MAX for value in policy_actual.values())
        row = {
            'sample_id': sample_id,
            'conv1_resource_stage4': stage4['conv1'],
            'conv2_resource_stage4': stage4['conv2'],
            'conv3_resource_stage4': stage4['conv3'],
            'conv1_predicted_D16': predicted['conv1'][16], 'conv1_predicted_D32': predicted['conv1'][32], 'conv1_predicted_D64': predicted['conv1'][64],
            'conv2_predicted_D16': predicted['conv2'][16], 'conv2_predicted_D32': predicted['conv2'][32], 'conv2_predicted_D64': predicted['conv2'][64],
            'conv3_predicted_D16': predicted['conv3'][16], 'conv3_predicted_D32': predicted['conv3'][32], 'conv3_predicted_D64': predicted['conv3'][64],
            'conv1_actual_D_selected': actual['conv1'], 'conv2_actual_D_selected': actual['conv2'], 'conv3_actual_D_selected': actual['conv3'],
            'adaptive_energy_stage4': stage4_energy,
            'fixed64_energy': fixed_energy,
            'energy_saving_stage4': fixed_energy - stage4_energy,
            'energy_saving_percent_stage4': 100 * (fixed_energy - stage4_energy) / fixed_energy,
            'adaptive_cycles_stage4': stage4_cycles,
            'fixed64_cycles': fixed_cycles,
            'cycle_saving_stage4': fixed_cycles - stage4_cycles,
            'cycle_saving_percent_stage4': 100 * (fixed_cycles - stage4_cycles) / fixed_cycles,
            'conv1_resource_energy_policy': energy_policy['conv1'],
            'conv2_resource_energy_policy': energy_policy['conv2'],
            'conv3_resource_energy_policy': energy_policy['conv3'],
            'energy_energy_policy': policy_energy,
            'energy_saving_energy_policy': fixed_energy - policy_energy,
            'energy_saving_percent_energy_policy': 100 * (fixed_energy - policy_energy) / fixed_energy,
            'cycles_energy_policy': policy_cycles,
            'cycle_saving_energy_policy': fixed_cycles - policy_cycles,
            'cycle_saving_percent_energy_policy': 100 * (fixed_cycles - policy_cycles) / fixed_cycles,
            'energy_policy_degradation_violations': policy_violations,
            'conv1_actual_D_energy_policy': policy_actual['conv1'],
            'conv2_actual_D_energy_policy': policy_actual['conv2'],
            'conv3_actual_D_energy_policy': policy_actual['conv3'],
            'energy_policy_fallback_to_64': any(fallback.values()),
        }
        per_sample.append(row)

    per_fields = list(per_sample[0])
    write_csv(OUT / 'stage7c_adaptive_energy_per_sample.csv', per_sample, per_fields)

    configs = {
        'Fixed64': lambda row: {'conv1': 64, 'conv2': 64, 'conv3': 64},
        'Stage4 adaptive': lambda row: {layer: int(row[f'{layer}_resource_stage4']) for layer in LAYERS},
        'Energy-aware feasible': lambda row: {layer: int(row[f'{layer}_resource_energy_policy']) for layer in LAYERS},
    }
    for name, selector in configs.items():
        selected = [selector(row) for row in per_sample]
        energies = [selected_metrics(selection, energy)[0] for selection in selected]
        cycles = [selected_metrics(selection, energy)[1] for selection in selected]
        resources = [sum(selection.values()) for selection in selected]
        actual_violations = [
            sum(actuals[(row['sample_id'], layer, selection[layer])] > D_MAX for layer in LAYERS)
            for row, selection in zip(per_sample, selected)
        ]
        policy_rows.append({
            'policy': name,
            'samples': len(per_sample),
            'mean_energy': sum(energies) / len(energies),
            'total_energy': sum(energies),
            'energy_unit': ENERGY_UNIT,
            'mean_cycles': sum(cycles) / len(cycles),
            'total_cycles': sum(cycles),
            'mean_resource_count': sum(resources) / len(resources),
            'mean_pe_reduction_relative_to_64': 100 * (192 - sum(resources) / len(resources)) / 192,
            'energy_reduction_relative_to_fixed64_percent': 100 * (fixed_energy - sum(energies) / len(energies)) / fixed_energy,
            'cycle_reduction_relative_to_fixed64_percent': 100 * (fixed_cycles - sum(cycles) / len(cycles)) / fixed_cycles,
            'degradation_violations': sum(actual_violations),
            'maximum_actual_degradation': max(
                actuals[(row['sample_id'], layer, selection[layer])]
                for row, selection in zip(per_sample, selected)
                for layer in LAYERS
            ),
            'energy_policy_fallbacks_to_64': sum(bool(row['energy_policy_fallback_to_64']) for row in per_sample) if name == 'Energy-aware feasible' else '',
        })
    write_csv(OUT / 'stage7c_policy_comparison.csv', policy_rows, list(policy_rows[0]))

    stage4 = policy_rows[1]
    energy_policy = policy_rows[2]
    (OUT / 'stage7c_policy_summary.txt').write_text(
        'STAGE 7C-2 POLICY SUMMARY\n'
        '=========================\n\n'
        f"Samples: 19\nD_MAX: {D_MAX}\n\n"
        f"Fixed64 mean energy: {policy_rows[0]['mean_energy']}\n"
        f"Stage4 adaptive mean energy: {stage4['mean_energy']}\n"
        f"Energy-aware feasible mean energy: {energy_policy['mean_energy']}\n"
        f"Stage4 energy reduction: {stage4['energy_reduction_relative_to_fixed64_percent']}%\n"
        f"Energy-policy energy reduction: {energy_policy['energy_reduction_relative_to_fixed64_percent']}%\n"
        f"Stage4 mean cycles: {stage4['mean_cycles']}\n"
        f"Energy-policy mean cycles: {energy_policy['mean_cycles']}\n"
        f"Stage4 degradation violations: {stage4['degradation_violations']}\n"
        f"Energy-policy degradation violations: {energy_policy['degradation_violations']}\n"
        f"Energy-policy fallbacks to 64: {energy_policy['energy_policy_fallbacks_to_64']}\n\n"
        'Energy values are Accelergy output units; physical unit not specified in YAML.\n'
    )

    (OUT / 'stage7c_adaptive_energy_report.txt').write_text(
        'STAGE 7C-2 ENERGY-AWARE ADAPTIVE RESOURCE EVALUATION\n'
        '===================================================\n\n'
        'Final status: STAGE 7C-2 STATUS: PASS\n\n'
        'Objective\n---------\n'
        'Evaluate Stage 4 adaptive convolution-layer resource decisions using the\n'
        'authoritative Stage 7C-1 per-layer Accelergy characterization.\n\n'
        'Inputs\n------\n'
        f'- Stage 4 authoritative decisions: {DECISIONS}\n'
        f'- Stage 7C-1 energy table: {ENERGY}\n'
        '- 19 held-out samples; conv1/conv2/conv3 only. Classifier rows were excluded.\n'
        '- D_MAX=0.05; resource order=[16,32,64]; fixed baseline=64.\n\n'
        'Fixed-64 baseline\n------------------\n'
        f'- Energy: {fixed_energy} ({ENERGY_UNIT})\n'
        f'- Cycles: {fixed_cycles}\n\n'
        'Stage 4 and energy-aware policy\n---------------------------------\n'
        f"- Stage 4 mean energy: {stage4['mean_energy']}; total: {stage4['total_energy']}\n"
        f"- Stage 4 energy reduction: {stage4['energy_reduction_relative_to_fixed64_percent']}%\n"
        f"- Stage 4 mean cycles: {stage4['mean_cycles']}; total: {stage4['total_cycles']}\n"
        f"- Stage 4 cycle reduction: {stage4['cycle_reduction_relative_to_fixed64_percent']}%\n"
        f"- Energy-aware mean energy: {energy_policy['mean_energy']}; total: {energy_policy['total_energy']}\n"
        f"- Energy-aware energy reduction: {energy_policy['energy_reduction_relative_to_fixed64_percent']}%\n"
        f"- Energy-aware mean cycles: {energy_policy['mean_cycles']}; total: {energy_policy['total_cycles']}\n"
        f"- Energy-aware cycle reduction: {energy_policy['cycle_reduction_relative_to_fixed64_percent']}%\n"
        f"- Energy-aware policy degradation violations: {energy_policy['degradation_violations']}\n\n"
        'Candidate policy validity\n--------------------------\n'
        'Candidate predicted degradations exist for all three convolution layers and\n'
        'all three resources in the Stage 4 decision file. The energy-aware policy\n'
        'therefore used only those predictions and selected the minimum-energy feasible\n'
        'resource per layer. No degradation values were invented.\n\n'
        'Limitations\n-----------\n'
        '- Energy values are Accelergy estimates, not physical hardware measurements.\n'
        '- Physical units are not specified in the Stage 7C-1 YAML; values are not joules.\n'
        '- No energy was inferred from cycle count.\n'
        '- Dynamic reconfiguration overhead is not included.\n'
        '- Classifier energy is not included.\n'
        '- Runtime hardware implementation was not validated.\n'
        '- Stage 7C-1 reconstruction differences remain documented in its report.\n'
        '- Stage 7C-3 was not started.\n'
    )


if __name__ == '__main__':
    main()
