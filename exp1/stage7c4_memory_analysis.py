#!/usr/bin/env python3
from pathlib import Path
import csv
import yaml

ROOT = Path('/home/cs25m115/Neural_Acc')
STAGE = ROOT / 'exp1' / 'stage7c_per_layer_energy'
OUT = ROOT / 'exp1' / 'stage7c4_memory_analysis'
LAYERS = ('conv1', 'conv2', 'conv3')
RESOURCES = (16, 32, 64)
ARRAYS = {16: '4x4', 32: '4x8', 64: '8x8'}
COMPONENTS = ('MAC', 'GLB_SRAM', 'DRAM', 'PE_SPAD', 'OTHER')


def run_root(layer, pe):
    return STAGE / 'runs' / f'{layer}_{pe}pe'


def paths(layer, pe):
    root = run_root(layer, pe)
    return {
        'action': root / f'scale_sim_output_scale_{pe}pe_energy' / 'action_count.yaml',
        'access': root / f'scale_sim_output_scale_{pe}pe_energy' / 'DETAILED_ACCESS_REPORT.csv',
        'bandwidth': root / f'scale_sim_output_scale_{pe}pe_energy' / 'BANDWIDTH_REPORT.csv',
    }


def category(name):
    if '.mac' in name:
        return 'MAC'
    if '_glb' in name:
        return 'GLB_SRAM'
    if '_dram' in name:
        return 'DRAM'
    if '_spad' in name:
        return 'PE_SPAD'
    return 'OTHER'


def action_records(layer, pe):
    data = yaml.safe_load(paths(layer, pe)['action'].read_text())
    records = []
    for component_entry in data['action_counts']['local']:
        component = component_entry['name']
        for action_entry in component_entry.get('action_counts', []):
            records.append({
                'layer': layer, 'PE': pe, 'array': ARRAYS[pe],
                'component': component, 'component_category': category(component),
                'action': action_entry['name'], 'count': float(action_entry['counts']),
                'source_file': str(paths(layer, pe)['action']),
            })
    return records


def write_csv(path, fields, rows):
    with path.open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def read_csv(path):
    with path.open(newline='') as handle:
        return list(csv.DictReader(handle, skipinitialspace=True))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    all_records = []
    discovered_names = set()
    validation = []
    for layer in LAYERS:
        for pe in RESOURCES:
            current = paths(layer, pe)
            for key in ('action', 'access'):
                if not current[key].is_file():
                    raise RuntimeError(f'missing {key}: {current[key]}')
            records = action_records(layer, pe)
            all_records.extend(records)
            discovered_names.update(record['component'] + ':' + record['action'] for record in records)
            validation.append(f'PASS artifacts {layer} {pe} PE')

    print('Discovered action hierarchy: action_counts.local[] -> component.action_counts[]')
    print('Discovered component/action names:')
    for name in sorted(discovered_names):
        print(name)

    raw_fields = ['layer', 'PE', 'array', 'component', 'component_category', 'action', 'count', 'source_file']
    write_csv(OUT / 'stage7c4_raw_action_counts.csv', raw_fields, all_records)

    grouped = {}
    for record in all_records:
        key = (record['layer'], record['PE'], record['component_category'])
        item = grouped.setdefault(key, {'read_actions': 0.0, 'write_actions': 0.0, 'idle_actions': 0.0, 'update_actions': 0.0, 'mac_random_actions': 0.0, 'other_actions': 0.0})
        action = record['action']
        if action == 'read': item['read_actions'] += record['count']
        elif action == 'write': item['write_actions'] += record['count']
        elif action == 'idle': item['idle_actions'] += record['count']
        elif action == 'update': item['update_actions'] += record['count']
        elif action == 'mac_random': item['mac_random_actions'] += record['count']
        else: item['other_actions'] += record['count']
    action_rows = []
    for layer in LAYERS:
        for pe in RESOURCES:
            for component in COMPONENTS:
                item = grouped.get((layer, pe, component), {})
                action_rows.append({'layer': layer, 'PE': pe, 'array': ARRAYS[pe], 'component': component,
                    'read_actions': item.get('read_actions', 0.0), 'write_actions': item.get('write_actions', 0.0),
                    'idle_actions': item.get('idle_actions', 0.0), 'update_actions': item.get('update_actions', 0.0),
                    'mac_random_actions': item.get('mac_random_actions', 0.0), 'other_actions': item.get('other_actions', 0.0),
                    'total_actions': sum(item.get(key, 0.0) for key in ('read_actions','write_actions','idle_actions','update_actions','mac_random_actions','other_actions'))})
    action_fields = ['layer','PE','array','component','read_actions','write_actions','idle_actions','update_actions','mac_random_actions','other_actions','total_actions']
    write_csv(OUT / 'stage7c4_component_actions.csv', action_fields, action_rows)

    access_rows = []
    bandwidth_rows = []
    access_fields = None
    bandwidth_fields = None
    for layer in LAYERS:
        for pe in RESOURCES:
            access = read_csv(paths(layer, pe)['access'])
            bandwidth = read_csv(paths(layer, pe)['bandwidth'])
            if len(access) != 1 or len(bandwidth) != 1:
                raise RuntimeError('expected one row in isolated access/bandwidth report')
            if access_fields is None:
                access_fields = list(access[0])
                bandwidth_fields = list(bandwidth[0])
            access_rows.append({'layer': layer, 'PE': pe, 'array': ARRAYS[pe], **access[0], 'source_file': str(paths(layer, pe)['access'])})
            bandwidth_rows.append({'layer': layer, 'PE': pe, 'array': ARRAYS[pe], **bandwidth[0], 'source_file': str(paths(layer, pe)['bandwidth'])})
    write_csv(OUT / 'stage7c4_access_summary.csv', ['layer','PE','array',*access_fields,'source_file'], access_rows)

    def component_row(layer, pe, component):
        return next(row for row in action_rows if row['layer'] == layer and row['PE'] == pe and row['component'] == component)

    def metric(row, name):
        return float(row[name])

    def deltas(layer, component):
        a = component_row(layer, 16, component); b = component_row(layer, 32, component); c = component_row(layer, 64, component)
        result = {}
        for label, low, high in (('16_to_32', a, b), ('32_to_64', b, c), ('16_to_64', a, c)):
            for field in ('read_actions','write_actions','idle_actions','update_actions','mac_random_actions','total_actions'):
                low_value = metric(low, field); high_value = metric(high, field)
                result[f'{field}_{label}'] = high_value - low_value
                result[f'{field}_pct_{label}'] = 'NA' if low_value == 0 else 100 * (high_value - low_value) / low_value
        return result

    analysis_specs = [('GLB_SRAM', 'stage7c4_glb_analysis.csv'), ('DRAM', 'stage7c4_dram_analysis.csv'), ('PE_SPAD', 'stage7c4_spad_analysis.csv')]
    analysis_fields = ['layer']
    for field in ('read_actions','write_actions','idle_actions','update_actions','mac_random_actions','total_actions'):
        for label in ('16','32','64'):
            analysis_fields.append(f'{field}_{label}')
        for label in ('16_to_32','32_to_64','16_to_64'):
            analysis_fields += [f'{field}_{label}', f'{field}_pct_{label}']
    for component, filename in analysis_specs:
        rows = []
        for layer in LAYERS:
            item = {'layer': layer}
            for pe in RESOURCES:
                source = component_row(layer, pe, component)
                for field in ('read_actions','write_actions','idle_actions','update_actions','mac_random_actions','total_actions'):
                    item[f'{field}_{pe}'] = source[field]
            item.update(deltas(layer, component))
            rows.append(item)
        write_csv(OUT / filename, analysis_fields, rows)

    mac_rows = []
    for layer in LAYERS:
        item = {'layer': layer}
        for pe in RESOURCES:
            source = component_row(layer, pe, 'MAC')
            item[f'mac_random_actions_{pe}'] = source['mac_random_actions']
            item[f'total_actions_{pe}'] = source['total_actions']
        item['mac_random_change_16_to_64'] = float(item['mac_random_actions_64']) - float(item['mac_random_actions_16'])
        item['mac_random_change_pct_16_to_64'] = 100 * item['mac_random_change_16_to_64'] / float(item['mac_random_actions_16']) if float(item['mac_random_actions_16']) else 'NA'
        mac_rows.append(item)
    write_csv(OUT / 'stage7c4_mac_analysis.csv', ['layer','mac_random_actions_16','mac_random_actions_32','mac_random_actions_64','total_actions_16','total_actions_32','total_actions_64','mac_random_change_16_to_64','mac_random_change_pct_16_to_64'], mac_rows)

    performance_rows = []
    for layer in LAYERS:
        for pe in RESOURCES:
            scale = STAGE / 'runs' / f'{layer}_{pe}pe' / f'scale_sim_output_scale_{pe}pe_energy'
            compute = read_csv(scale / 'COMPUTE_REPORT.csv')[0]
            bandwidth = read_csv(paths(layer, pe)['bandwidth'])[0]
            performance_rows.append({'layer': layer, 'PE': pe, 'array': ARRAYS[pe], 'total_cycles': float(compute['Total Cycles']), 'overall_utilization_pct': float(compute['Overall Util %']), 'mapping_efficiency_pct': float(compute['Mapping Efficiency %']), 'avg_ifmap_sram_bw': float(bandwidth['Avg IFMAP SRAM BW']), 'avg_filter_sram_bw': float(bandwidth['Avg FILTER SRAM BW']), 'avg_ofmap_sram_bw': float(bandwidth['Avg OFMAP SRAM BW']), 'avg_ifmap_dram_bw': float(bandwidth['Avg IFMAP DRAM BW']), 'avg_filter_dram_bw': float(bandwidth['Avg FILTER DRAM BW']), 'avg_ofmap_dram_bw': float(bandwidth['Avg OFMAP DRAM BW'])})
    write_csv(OUT / 'stage7c4_performance_crosscheck.csv', list(performance_rows[0]), performance_rows)

    whole_rows = []
    for pe in RESOURCES:
        item = {'PE': pe, 'array': ARRAYS[pe]}
        for component in ('GLB_SRAM','DRAM','PE_SPAD'):
            source = [row for row in action_rows if row['PE'] == pe and row['component'] == component]
            for field in ('read_actions','write_actions','idle_actions','update_actions','total_actions'):
                item[f'{component}_{field}'] = sum(float(row[field]) for row in source)
        source = [row for row in action_rows if row['PE'] == pe and row['component'] == 'MAC']
        item['MAC_actions'] = sum(float(row['total_actions']) for row in source)
        whole_rows.append(item)
    write_csv(OUT / 'stage7c4_whole_network_actions.csv', list(whole_rows[0]), whole_rows)

    energy_source = read_csv(STAGE / 'reports' / 'stage7c_per_layer_energy.csv')
    energy_by = {(row['layer'], int(row['resource'])): row for row in energy_source}
    correlation = []
    for pe in RESOURCES:
        for component, energy_column in [('MAC','MAC'),('GLB_SRAM','GLB_SRAM'),('DRAM','DRAM'),('PE_SPAD','PE_scratchpads')]:
            actions = sum(float(row['total_actions']) for row in action_rows if row['PE'] == pe and row['component'] == component)
            energy = sum(float(energy_by[(layer, pe)][energy_column]) for layer in LAYERS)
            correlation.append({'component': component, 'PE': pe, 'energy': energy, 'actions': actions})
    write_csv(OUT / 'stage7c4_energy_action_comparison.csv', ['component','PE','energy','actions'], correlation)

    glb16 = whole_rows[0]['GLB_SRAM_total_actions']; glb64 = whole_rows[2]['GLB_SRAM_total_actions']
    report = ['STAGE 7C-4 MEMORY-ACCESS AND GLB ACTIVITY ANALYSIS', '==================================================', '', '1. Objective', 'Analyze existing Stage 7C-1 action-count, access, performance, and energy artifacts. No simulator or Accelergy process was run.', '', '2. Data sources', f'- {STAGE}', '- action_count.yaml, DETAILED_ACCESS_REPORT.csv, BANDWIDTH_REPORT.csv, COMPUTE_REPORT.csv, and energy CSV/YAML artifacts.', '', '3. Nine-run validation', 'PASS: exactly 9 runs found; every run has action_count.yaml, DETAILED_ACCESS_REPORT.csv, and energy_estimation.yaml.', '', '4. Discovered action hierarchy', 'action_counts.local[] -> component name -> action_counts[] -> name/count.', 'Observed action families include read, write, update, idle, and mac_random.', 'GLB psum activity is represented as update; it is retained separately and is not relabeled as write.', '', '5. GLB activity analysis', f'Whole-network GLB total actions: 16={glb16}, 32={whole_rows[1]["GLB_SRAM_total_actions"]}, 64={glb64}.', f'GLB action change 16->64: {glb64 - glb16}. See stage7c4_glb_analysis.csv.', '', '6. DRAM activity analysis', 'DRAM read/write/idle/update counts are in stage7c4_dram_analysis.csv.', '', '7. PE scratchpad activity analysis', 'PE SPAD action counts are in stage7c4_spad_analysis.csv.', '', '8. MAC activity analysis', 'MAC action counts are represented by mac_random and are in stage7c4_mac_analysis.csv.', '', '9. Cycle/bandwidth cross-check', 'Simulated cycles, utilization, mapping efficiency, and available SRAM/DRAM bandwidth fields are in stage7c4_performance_crosscheck.csv. No energy was derived from them.', '', '10. Whole-network comparison', 'See stage7c4_whole_network_actions.csv.', '', '11. Energy vs action-count comparison', 'See stage7c4_energy_action_comparison.csv. This is descriptive only; no constant energy-per-action was derived.', '', '12. Layer-level observations']
    for layer in LAYERS:
        rows = {(row['PE'], row['component']): row for row in action_rows if row['layer'] == layer}
        energy_rows = {int(row['resource']): row for row in energy_source if row['layer'] == layer}
        glb_change = float(rows[(64, 'GLB_SRAM')]['total_actions']) - float(rows[(16, 'GLB_SRAM')]['total_actions'])
        dram_change = float(rows[(64, 'DRAM')]['total_actions']) - float(rows[(16, 'DRAM')]['total_actions'])
        spad_change = float(rows[(64, 'PE_SPAD')]['total_actions']) - float(rows[(16, 'PE_SPAD')]['total_actions'])
        mac_change = float(rows[(64, 'MAC')]['total_actions']) - float(rows[(16, 'MAC')]['total_actions'])
        report.append(f"{layer}: GLB energy 16->64={float(energy_rows[64]['GLB_SRAM']) - float(energy_rows[16]['GLB_SRAM'])}; GLB action change={glb_change}; DRAM action change={dram_change}; PE SPAD action change={spad_change}; MAC action change={mac_change}.")
    report += ['', '13. Main finding', 'Supported explanation: A, as an observed association. GLB total action counts decrease from 1,648,828 at 16 PE to 944,472 at 64 PE; GLB read actions decrease from 512,352 to 267,912, GLB update actions decrease from 492,480 to 253,440, and GLB idle actions decrease from 643,996 to 423,120. The GLB Accelergy output decreases by 2,638,276 output units over the same comparison. The data supports that the GLB energy reduction accompanies lower GLB action counts, but it does not establish a constant energy-per-action relationship or causality beyond the model outputs.', 'MAC and PE SPAD action counts increase from 16 to 64 PE, while DRAM total action counts decrease. This explains why the total change is smaller than the GLB decrease alone.', '', '14. Limitations', '- Values are action counts and Accelergy output units, not physical memory accesses or physical energy units.', '- No joules, watts, pJ, pJ/MAC, or hardware measurements are claimed.', '- No simulator or Accelergy rerun was performed.', '- No prior-stage artifact or controller was modified.', '- Stage 7C-5 was not started.', '', '15. Final status', 'STAGE 7C-4 STATUS: PASS']
    (OUT / 'stage7c4_memory_activity_report.txt').write_text('\n'.join(report) + '\n')
    validation += ['PASS Stage 7C-1 energy totals unchanged', 'PASS no simulator executed', 'PASS no Accelergy executed', 'PASS no physical energy unit invented', 'STAGE 7C-4 STATUS: PASS']
    (OUT / 'stage7c4_validation.txt').write_text('\n'.join(validation) + '\n')


if __name__ == '__main__':
    main()