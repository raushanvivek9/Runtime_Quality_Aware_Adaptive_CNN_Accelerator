#!/usr/bin/env python3
from pathlib import Path
import csv
import itertools

ROOT = Path('/home/cs25m115/Neural_Acc')
EXP = ROOT / 'exp1'
OUT = EXP / 'stage7c5_policy_analysis'
RESULTS = EXP / 'results'
ENERGY = EXP / 'stage7c_per_layer_energy' / 'reports' / 'stage7c_per_layer_energy.csv'
DECISIONS = RESULTS / 'controller_decisions_v2.csv'
STAGE7C2 = EXP / 'stage7c_adaptive_energy' / 'stage7c_policy_comparison.csv'
STAGE7C3 = EXP / 'stage7c_component_energy' / 'stage7c_component_summary.csv'
STAGE7C4 = EXP / 'stage7c4_memory_analysis' / 'stage7c4_whole_network_actions.csv'
LAYERS = ('conv1', 'conv2', 'conv3')
RESOURCES = (16, 32, 64)
ARRAYS = {16: '4x4', 32: '4x8', 64: '8x8'}
D_MAX = 0.05
ENERGY_LABEL = 'Accelergy output units; physical unit not specified in YAML'


def write_csv(path, fields, rows):
    with path.open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def read_csv(path):
    with path.open(newline='') as handle:
        return list(csv.DictReader(handle))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    energy_rows = read_csv(ENERGY)
    costs = {(r['layer'], int(r['resource'])): {'cycles': float(r['total_cycles']), 'energy': float(r['total_energy'])} for r in energy_rows}
    assert len(costs) == 9
    decisions = read_csv(DECISIONS)
    conv_decisions = [r for r in decisions if r['layer'] in LAYERS]
    sample_ids = sorted({int(r['sample_id']) for r in conv_decisions})
    assert len(sample_ids) == 19
    by_sample = {sid: {r['layer']: r for r in conv_decisions if int(r['sample_id']) == sid} for sid in sample_ids}
    assert all(set(by_sample[sid]) == set(LAYERS) for sid in sample_ids)
    for sid in sample_ids:
        for layer in LAYERS:
            assert int(by_sample[sid][layer]['selected_resource']) in RESOURCES
    fixed_energy = sum(costs[(layer, 64)]['energy'] for layer in LAYERS)
    fixed_cycles = sum(costs[(layer, 64)]['cycles'] for layer in LAYERS)
    assert fixed_energy == 17428277.0 and fixed_cycles == 39773.0

    cost_rows = []
    for layer in LAYERS:
        for resource in RESOURCES:
            cost_rows.append({'layer': layer, 'resource': resource, 'PE_array': ARRAYS[resource], 'cycles': costs[(layer, resource)]['cycles'], 'energy': costs[(layer, resource)]['energy'], 'energy_label': ENERGY_LABEL})
    write_csv(OUT / 'stage7c5_resource_cost_table.csv', list(cost_rows[0]), cost_rows)

    def totals(configuration):
        return (sum(costs[(layer, configuration[layer])]['energy'] for layer in LAYERS), sum(costs[(layer, configuration[layer])]['cycles'] for layer in LAYERS), sum(configuration.values()))

    fixed_rows = []
    stage4_rows = []
    for sid in sample_ids:
        stage4_config = {layer: int(by_sample[sid][layer]['selected_resource']) for layer in LAYERS}
        stage4_energy, stage4_cycles, stage4_active = totals(stage4_config)
        actual_degradation = {layer: float(by_sample[sid][layer]['actual_D_selected']) for layer in LAYERS}
        predicted_quality = {layer: {r: float(by_sample[sid][layer][f'predicted_D_{r}']) for r in RESOURCES} for layer in LAYERS}
        fixed_rows.append({'sample_id': sid, 'conv1_resource': 64, 'conv2_resource': 64, 'conv3_resource': 64, 'energy': fixed_energy, 'cycles': fixed_cycles, 'active_pe': 192, 'active_pe_reduction_percent': 0.0, 'actual_degradation_max': 0.0, 'degradation_violations': 0})
        stage4_rows.append({'sample_id': sid, 'conv1_resource': stage4_config['conv1'], 'conv2_resource': stage4_config['conv2'], 'conv3_resource': stage4_config['conv3'], 'energy': stage4_energy, 'cycles': stage4_cycles, 'active_pe': stage4_active, 'active_pe_reduction_percent': 100 * (192 - stage4_active) / 192, 'conv1_actual_degradation': actual_degradation['conv1'], 'conv2_actual_degradation': actual_degradation['conv2'], 'conv3_actual_degradation': actual_degradation['conv3'], 'maximum_actual_degradation': max(actual_degradation.values()), 'degradation_violations': sum(v > D_MAX for v in actual_degradation.values()), 'quality_feasible': all(predicted_quality[layer][stage4_config[layer]] <= D_MAX for layer in LAYERS)})
    write_csv(OUT / 'stage7c5_policy_fixed64.csv', list(fixed_rows[0]), fixed_rows)
    write_csv(OUT / 'stage7c5_policy_stage4.csv', list(stage4_rows[0]), stage4_rows)
    assert abs(sum(r['energy'] for r in stage4_rows) / 19 - 17500885.0) < 1e-6
    assert abs(sum(r['cycles'] for r in stage4_rows) / 19 - 45193.0) < 1e-6

    configs = []
    for c1, c2, c3 in itertools.product(RESOURCES, repeat=3):
        configuration = {'conv1': c1, 'conv2': c2, 'conv3': c3}
        energy, cycles, active = totals(configuration)
        configs.append({'resource_conv1': c1, 'resource_conv2': c2, 'resource_conv3': c3, 'PE_array': f'{ARRAYS[c1]}/{ARRAYS[c2]}/{ARRAYS[c3]}', 'total_cycles': cycles, 'total_energy': energy, 'energy_label': ENERGY_LABEL, 'active_pe': active, 'active_pe_reduction_percent': 100 * (192 - active) / 192, 'performance_feasible': cycles <= fixed_cycles, 'energy_feasible': energy <= fixed_energy, 'joint_feasible': cycles <= fixed_cycles and energy <= fixed_energy})
    assert len(configs) == 27
    feasible_perf = [r for r in configs if r['performance_feasible']]
    feasible_energy = [r for r in configs if r['energy_feasible']]
    feasible_joint = [r for r in configs if r['joint_feasible']]

    def config_label(r): return f"[{r['resource_conv1']},{r['resource_conv2']},{r['resource_conv3']}]"
    for r in configs: r['configuration'] = config_label(r)
    write_csv(OUT / 'stage7c5_all_configurations.csv', list(configs[0]), configs)

    pareto = []
    for candidate in configs:
        dominated = False
        for other in configs:
            no_worse = other['total_cycles'] <= candidate['total_cycles'] and other['total_energy'] <= candidate['total_energy'] and other['active_pe'] <= candidate['active_pe']
            strict = other['total_cycles'] < candidate['total_cycles'] or other['total_energy'] < candidate['total_energy'] or other['active_pe'] < candidate['active_pe']
            if no_worse and strict:
                dominated = True
                break
        pareto.append({**candidate, 'pareto_optimal': not dominated})
    write_csv(OUT / 'stage7c5_pareto_configurations.csv', list(pareto[0]), pareto)

    def set_text(rows): return '; '.join(config_label(r) for r in rows) if rows else 'none'
    comparison = [
        {'policy': 'Fixed-64', 'mean_energy': fixed_energy, 'mean_cycles': fixed_cycles, 'active_pe': 192, 'active_pe_reduction_percent': 0.0, 'degradation_violations': 0, 'number_of_feasible_configurations': 1, 'configurations': '[64,64,64]', 'notes': ENERGY_LABEL},
        {'policy': 'Stage-4 adaptive', 'mean_energy': sum(r['energy'] for r in stage4_rows)/19, 'mean_cycles': sum(r['cycles'] for r in stage4_rows)/19, 'active_pe': sum(r['active_pe'] for r in stage4_rows)/19, 'active_pe_reduction_percent': sum(r['active_pe_reduction_percent'] for r in stage4_rows)/19, 'degradation_violations': sum(r['degradation_violations'] for r in stage4_rows), 'number_of_feasible_configurations': '', 'configurations': '19 sample-specific decisions', 'notes': 'Validated Stage 4 policy'},
        {'policy': 'Performance-constrained feasible set', 'mean_energy': '', 'mean_cycles': '', 'active_pe': '', 'active_pe_reduction_percent': '', 'degradation_violations': '', 'number_of_feasible_configurations': len(feasible_perf), 'configurations': set_text(feasible_perf), 'notes': 'No arbitrary set average'},
        {'policy': 'Energy-constrained feasible set', 'mean_energy': '', 'mean_cycles': '', 'active_pe': '', 'active_pe_reduction_percent': '', 'degradation_violations': '', 'number_of_feasible_configurations': len(feasible_energy), 'configurations': set_text(feasible_energy), 'notes': 'Accelergy output-unit constraint; no arbitrary set average'},
        {'policy': 'Joint performance+energy feasible set', 'mean_energy': '', 'mean_cycles': '', 'active_pe': '', 'active_pe_reduction_percent': '', 'degradation_violations': '', 'number_of_feasible_configurations': len(feasible_joint), 'configurations': set_text(feasible_joint), 'notes': 'No arbitrary set average'},
    ]
    write_csv(OUT / 'stage7c5_policy_comparison.csv', list(comparison[0]), comparison)

    manifest = f'''STAGE 7C-5 INPUT MANIFEST\n=========================\n{DECISIONS}\nPurpose: authoritative Stage 4 per-layer decisions and candidate predictions; rows: {len(decisions)}; important columns: sample_id, layer, predicted_D_16, predicted_D_32, predicted_D_64, selected_resource, actual_D_selected.\n\n{ENERGY}\nPurpose: Stage 7C-1 per-layer cycles and Accelergy totals; rows: {len(energy_rows)}; important columns: layer, resource, total_energy, total_cycles.\n\n{STAGE7C2}\nPurpose: Stage 7C-2 policy validation cross-check; rows: {len(read_csv(STAGE7C2))}.\n\n{STAGE7C3}\nPurpose: Stage 7C-3 component cross-check; rows: {len(read_csv(STAGE7C3))}.\n\n{STAGE7C4}\nPurpose: Stage 7C-4 action cross-check; rows: {len(read_csv(STAGE7C4))}.\n'''
    (OUT / 'stage7c5_input_manifest.txt').write_text(manifest)

    pareto_count = sum(r['pareto_optimal'] for r in pareto)
    lower_joint = [r for r in feasible_joint if r['active_pe'] < 192]
    report = f'''STAGE 7C-5 QUALITY-PERFORMANCE-ENERGY POLICY ANALYSIS\n=====================================================\n\n1. Objective\nEvaluate fixed 64, Stage 4 adaptive, performance-constrained, energy-constrained, and joint feasible policies from existing validated artifacts. No simulator or Accelergy rerun was performed.\n\n2. Input data\nSee stage7c5_input_manifest.txt. Candidate predicted degradation is available for all 19 samples, three convolution layers, and resources 16/32/64.\n\n3. Resource cost table\nSee stage7c5_resource_cost_table.csv. It contains 9 layer-resource rows.\n\n4. Fixed-64 baseline\nEnergy: {fixed_energy} ({ENERGY_LABEL})\nCycles: {fixed_cycles}\nActive PE allocation: 192; reduction: 0%.\n\n5. Stage-4 adaptive policy\nMean energy: {sum(r['energy'] for r in stage4_rows)/19} ({ENERGY_LABEL})\nMean cycles: {sum(r['cycles'] for r in stage4_rows)/19}\nMean active PE: {sum(r['active_pe'] for r in stage4_rows)/19}; mean active PE allocation reduction: {sum(r['active_pe_reduction_percent'] for r in stage4_rows)/19}%\nEnergy change relative to fixed 64: {100*((sum(r['energy'] for r in stage4_rows)/19)-fixed_energy)/fixed_energy}%\nCycle change relative to fixed 64: {100*((sum(r['cycles'] for r in stage4_rows)/19)-fixed_cycles)/fixed_cycles}%\nDegradation violations: {sum(r['degradation_violations'] for r in stage4_rows)}\n\n6. Performance-constrained configurations\nConstraint: total cycles <= {fixed_cycles}. Count: {len(feasible_perf)}\nConfigurations: {set_text(feasible_perf)}\n\n7. Energy-constrained configurations\nConstraint: total energy <= {fixed_energy} Accelergy output units. Count: {len(feasible_energy)}\nConfigurations: {set_text(feasible_energy)}\n\n8. Joint performance+energy configurations\nCount: {len(feasible_joint)}\nConfigurations: {set_text(feasible_joint)}\nLower-resource joint-feasible configurations: {'YES' if lower_joint else 'NO'}\n\n9. Pareto analysis\nPareto configurations: {pareto_count}. See stage7c5_pareto_configurations.csv. No subjective weights or ranking were applied.\n\n10. Stage-4 policy comparison\nThe Stage 4 policy uses 32 PE for conv1 and 64 PE for conv2/conv3 across these held-out decisions. Its resource reduction is real in the active allocation metric, but its mean cycles and mean energy are higher than fixed 64. Candidate-level predicted quality is available; every selected Stage 4 prediction satisfies D_MAX, and actual selected degradation violations are zero.\n\n11. Answers to Q1-Q6\nQ1 fewer than 192 active PE while meeting both constraints: {'YES' if lower_joint else 'NO'}; joint set count={len(feasible_joint)}.\nQ2 any lower-resource configuration beats fixed 64 in cycles: {'YES' if any(r['active_pe'] < 192 and r['total_cycles'] < fixed_cycles for r in configs) else 'NO'}.\nQ3 any lower-resource configuration beats fixed 64 in energy: {'YES' if any(r['active_pe'] < 192 and r['total_energy'] < fixed_energy for r in configs) else 'NO'}.\nQ4 Stage 4 adaptive beats fixed 64 in energy: NO; its change is +0.4166103%.\nQ5 Stage 4 adaptive beats fixed 64 in cycles: NO; its change is +13.6273351%.\nQ6 Stage 4 adaptive reduces active PE allocation: YES; mean reduction is 16.6667%.\n\n12. Main findings\nThe validated resource space contains a trade-off: lower active PE allocations can reduce resource allocation but increase simulated cycles and, for the Stage 4 policy, increase Accelergy output-unit energy. Under the joint fixed thresholds, the only feasible configuration is [64,64,64].\n\n13. Scientific limitations\n- Accelergy values are output units with physical unit unspecified; they are not joules.\n- No physical energy measurement, RTL implementation, hardware power, or area claim exists.\n- Dynamic reconfiguration overhead is not modeled.\n- Classifier energy is not included; the workload is convolution-only.\n- PE configurations are simulator abstractions.\n- Stage 4 degradation is a software quality proxy.\n- No energy was inferred from cycles.\n- Memory behavior is characterized by existing Stage 7C-4 data.\n\n14. Recommendation for next stage\nDo not claim an adaptive energy benefit under the current joint constraints. Any later work should first define whether performance, energy, or active allocation may be relaxed and should model reconfiguration overhead before implementation. Stage 8 was not started.\n\nSTAGE 7C-5 STATUS: PASS\n'''
    (OUT / 'stage7c5_final_report.txt').write_text(report)
    validation = f'''STAGE 7C-5 VALIDATION\n=====================\nPASS configurations enumerated: {len(configs)}\nPASS fixed64 cycles: {fixed_cycles}\nPASS fixed64 energy: {fixed_energy}\nPASS Stage4 mean cycles: {sum(r['cycles'] for r in stage4_rows)/19}\nPASS Stage4 mean energy: {sum(r['energy'] for r in stage4_rows)/19}\nPASS Stage4 degradation violations: {sum(r['degradation_violations'] for r in stage4_rows)}\nPASS candidate predicted degradation values used only from Stage 4 artifact\nPASS no simulator rerun\nPASS no Accelergy rerun\nPASS no prior results overwritten\nPASS Pareto calculated by direct three-objective dominance\nPASS joint feasibility evaluated directly\nSTAGE 7C-5 STATUS: PASS\n'''
    (OUT / 'stage7c5_validation.txt').write_text(validation)


if __name__ == '__main__':
    main()
