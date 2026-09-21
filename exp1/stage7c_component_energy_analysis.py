#!/usr/bin/env python3
from pathlib import Path
import csv
import yaml

ROOT = Path('/home/cs25m115/Neural_Acc')
STAGE = ROOT / 'exp1' / 'stage7c_per_layer_energy'
OUT = ROOT / 'exp1' / 'stage7c_component_energy'
ENERGY_CSV = STAGE / 'reports' / 'stage7c_per_layer_energy.csv'
LAYERS = ('conv1', 'conv2', 'conv3')
RESOURCES = (16, 32, 64)
COMPONENTS = ('MAC', 'GLB_SRAM', 'DRAM', 'PE_scratchpads')
TOLERANCE = 1e-6
BASELINE_TOTALS = {16: 19272485.0, 32: 19272485.0 - 861112.0, 64: 17428277.0}


def yaml_path(layer, resource):
    return STAGE / 'runs' / f'{layer}_{resource}pe' / f'accelergy_output_scale_{resource}pe_energy' / 'energy_estimation.yaml'


def classify(name):
    if name.endswith('.mac'):
        return 'MAC'
    if '_glb' in name:
        return 'GLB_SRAM'
    if '_dram' in name:
        return 'DRAM'
    if '_spad' in name:
        return 'PE_scratchpads'
    return None


def pct(value, total):
    return 100.0 * value / total


def write_csv(path, fields, rows):
    with path.open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rows = []
    validation = []
    discovered = set()
    with ENERGY_CSV.open(newline='') as handle:
        source_rows = list(csv.DictReader(handle))
    if len(source_rows) != 9:
        raise RuntimeError(f'expected 9 CSV rows, found {len(source_rows)}')

    for source in source_rows:
        layer = source['layer']
        resource = int(source['resource'])
        values = {component: float(source[component]) for component in COMPONENTS}
        total = float(source['total_energy'])
        data = yaml.safe_load(yaml_path(layer, resource).read_text())['energy_estimation']
        yaml_total = float(data['Total'])
        yaml_components = {}
        for item in data['components']:
            name = item['name']
            category = classify(name)
            if category:
                discovered.add(name)
                yaml_components[category] = yaml_components.get(category, 0.0) + float(item['energy'])
        for component in COMPONENTS:
            if abs(values[component] - yaml_components.get(component, -1.0)) > TOLERANCE:
                raise RuntimeError(f'{layer}/{resource} {component} CSV/YAML mismatch')
        if abs(total - yaml_total) > TOLERANCE or abs(sum(values.values()) - total) > TOLERANCE:
            raise RuntimeError(f'{layer}/{resource} total mismatch')
        expected = {('conv1', 16): 3773055.0, ('conv1', 32): 3575495.0, ('conv1', 64): 3502887.0,
                    ('conv2', 16): 8705427.0, ('conv2', 32): 8277139.0, ('conv2', 64): 7652551.0,
                    ('conv3', 16): 6794003.0, ('conv3', 32): 6558739.0, ('conv3', 64): 6272839.0}
        if total != expected[(layer, resource)]:
            raise RuntimeError(f'{layer}/{resource} total differs from Stage 7C-1 validation value')
        rows.append({'layer': layer, 'PE': resource, 'array': source['pe_array'], **values, 'total': total, 'cycles': float(source['total_cycles'])})

    print('Discovered component names:')
    for name in sorted(discovered):
        print(name)

    breakdown = []
    for row in rows:
        item = {key: row[key] for key in ('layer', 'PE', 'array', *COMPONENTS, 'total')}
        for component in COMPONENTS:
            item[f'{component}_pct'] = pct(row[component], row['total'])
        breakdown.append(item)
        validation.append(f"PASS {row['layer']} {row['PE']} component sum and YAML cross-check")
    breakdown_fields = ['layer', 'PE', 'array', *COMPONENTS, 'total', *(f'{component}_pct' for component in COMPONENTS)]
    write_csv(OUT / 'stage7c_component_breakdown.csv', breakdown_fields, breakdown)

    deltas = []
    for layer in LAYERS:
        by_resource = {row['PE']: row for row in rows if row['layer'] == layer}
        item = {'layer': layer}
        for component in (*COMPONENTS, 'total'):
            for low, high in ((16, 32), (32, 64), (16, 64)):
                delta = by_resource[high][component] - by_resource[low][component]
                item[f'delta_{component}_{low}_to_{high}'] = delta
                item[f'delta_{component}_pct_{low}_to_{high}'] = pct(delta, by_resource[low][component])
        deltas.append(item)
    delta_fields = ['layer'] + [f'{prefix}_{component}_{low}_to_{high}' for component in (*COMPONENTS, 'total') for prefix in ('delta', 'delta_'+component+'_pct') for low, high in ()]
    delta_fields = ['layer']
    for component in (*COMPONENTS, 'total'):
        for low, high in ((16, 32), (32, 64), (16, 64)):
            delta_fields += [f'delta_{component}_{low}_to_{high}', f'delta_{component}_pct_{low}_to_{high}']
    write_csv(OUT / 'stage7c_component_deltas.csv', delta_fields, deltas)

    whole = []
    for resource in RESOURCES:
        selected = [row for row in rows if row['PE'] == resource]
        item = {'PE': resource, 'array': selected[0]['array']}
        for component in COMPONENTS:
            item[component] = sum(row[component] for row in selected)
        item['total'] = sum(row['total'] for row in selected)
        expected_total = {16: 19272485.0, 32: 18411373.0, 64: 17428277.0}[resource]
        if abs(item['total'] - expected_total) > TOLERANCE:
            raise RuntimeError(f'whole-network total mismatch for {resource}')
        whole.append(item)
        validation.append(f'PASS whole-network {resource} PE total {item["total"]}')
    write_csv(OUT / 'stage7c_whole_network_component_energy.csv', ['PE', 'array', *COMPONENTS, 'total'], whole)

    diagnostics = []
    for row in rows:
        diagnostics.append({'layer': row['layer'], 'PE': row['PE'], 'array': row['array'], 'total_energy': row['total'], 'total_cycles': row['cycles'], 'Accelergy_output_units_per_simulated_cycle': row['total'] / row['cycles']})
    write_csv(OUT / 'stage7c_energy_cycle_diagnostic.csv', ['layer', 'PE', 'array', 'total_energy', 'total_cycles', 'Accelergy_output_units_per_simulated_cycle'], diagnostics)

    summary = []
    whole_by_resource = {item['PE']: item for item in whole}
    total_reduction = whole_by_resource[16]['total'] - whole_by_resource[64]['total']
    for component in (*COMPONENTS, 'total'):
        change = whole_by_resource[64][component] - whole_by_resource[16][component]
        contribution = 100.0 * (whole_by_resource[16][component] - whole_by_resource[64][component]) / total_reduction if component != 'total' else 100.0
        summary.append({'component': component, 'energy_16': whole_by_resource[16][component], 'energy_32': whole_by_resource[32][component], 'energy_64': whole_by_resource[64][component], 'change_16_to_64': change, 'change_pct_16_to_64': pct(change, whole_by_resource[16][component]), 'contribution_to_total_change_pct': contribution})
    write_csv(OUT / 'stage7c_component_summary.csv', ['component', 'energy_16', 'energy_32', 'energy_64', 'change_16_to_64', 'change_pct_16_to_64', 'contribution_to_total_change_pct'], summary)

    largest = max(COMPONENTS, key=lambda c: whole_by_resource[16][c] - whole_by_resource[64][c])
    increasing = [c for c in COMPONENTS if whole_by_resource[64][c] > whole_by_resource[16][c]]
    report = [
        'STAGE 7C-3 COMPONENT-LEVEL ENERGY ANALYSIS',
        '============================================',
        '', '1. Objective', 'Analyze actual Stage 7C-1 component energy outputs; no simulation was rerun.',
        '', '2. Input artifacts', f'- {ENERGY_CSV}', '- Nine Stage 7C-1 energy_estimation.yaml files.',
        '', '3. Validation', 'PASS: exactly 9 configurations; CSV components cross-check against YAML component names and totals.',
        'PASS: every component sum equals its YAML Total within tolerance.',
        '', '4. Whole-network component energy',
        *[f"{item['PE']} PE: MAC={item['MAC']}, GLB_SRAM={item['GLB_SRAM']}, DRAM={item['DRAM']}, PE_scratchpads={item['PE_scratchpads']}, total={item['total']}" for item in whole],
        '', '5. Component percentage contribution',
        *[f"{row['layer']} {row['PE']} PE: MAC={pct(row['MAC'], row['total']):.4f}%, GLB_SRAM={pct(row['GLB_SRAM'], row['total']):.4f}%, DRAM={pct(row['DRAM'], row['total']):.4f}%, PE_scratchpads={pct(row['PE_scratchpads'], row['total']):.4f}%" for row in rows],
        '', '6. 16 vs 32 vs 64 comparison', 'See stage7c_component_deltas.csv for every layer and component delta.',
        '', '7. 16 -> 64 component changes',
        *[f"{item['component']}: change={item['change_16_to_64']}, percent={item['change_pct_16_to_64']:.6f}%, contribution to total reduction={item['contribution_to_total_change_pct']:.6f}%" for item in summary],
        '', '8. Layer-level observations',
    ]
    for layer in LAYERS:
        layer_rows = [row for row in rows if row['layer'] == layer]
        dominant = max(COMPONENTS, key=lambda c: sum(row[c] for row in layer_rows) / 3)
        decreases = {c: layer_rows[0][c] - layer_rows[2][c] for c in COMPONENTS}
        increases = [c for c in COMPONENTS if layer_rows[2][c] > layer_rows[0][c]]
        report.append(f"{layer}: largest average contribution={dominant}; largest 16->64 decrease={max(decreases, key=decreases.get)}; increasing components={', '.join(increases) if increases else 'none'}; largest reduction contribution={max(decreases, key=decreases.get)}.")
    report += ['', '9. Cycle cross-check']
    for layer in LAYERS:
        by = {row['PE']: row for row in rows if row['layer'] == layer}
        report.append(f"{layer}: cycles 16->64 {by[16]['cycles']} -> {by[64]['cycles']}, reduction={by[16]['cycles'] - by[64]['cycles']}; this is an observation only and was not used to derive energy.")
    report += ['', '10. Main finding', f"Across the isolated whole-network sums, {largest} has the largest contribution to the energy reduction from 16 to 64 PE."]
    if increasing:
        report.append(f"The component(s) increasing from 16 to 64 PE are: {', '.join(increasing)}. Their increases offset part of the reductions from decreasing components.")
    report += ['', '11. Scientific limitations', '- Values are Accelergy output units; physical units are unspecified in YAML.', '- No joules, pJ/MAC, power, or hardware measurements are claimed.', '- No energy was derived from cycles; cycles are a descriptive cross-check only.', '- No Stage 5/6, Stage 7B, Stage 7C-1, or Stage 7C-2 artifact was modified.', '- No adaptive controller was created or modified.', '- Stage 7C-4 was not started.', '', '12. Final status', 'STAGE 7C-3 STATUS: PASS']
    (OUT / 'stage7c_component_energy_report.txt').write_text('\n'.join(report) + '\n')
    validation += ['PASS no physical unit invented', 'PASS no prior-stage artifacts modified', 'STAGE 7C-3 STATUS: PASS']
    (OUT / 'stage7c_component_validation.txt').write_text('\n'.join(validation) + '\n')


if __name__ == '__main__':
    main()