#!/usr/bin/env python3

import json
from math import ceil
from pathlib import Path

H = 8
W = 8
K = 3

LAYER_SPECS = [
    {"name": "layer1", "in_c": 3, "out_c": 16},
    {"name": "layer2", "in_c": 16, "out_c": 32},
    {"name": "layer3", "in_c": 32, "out_c": 16},
]

CASES = {
    "A": {"seed": 1, "zero_mode": "low"},
    "B": {"seed": 3, "zero_mode": "medium"},
    "C": {"seed": 7, "zero_mode": "high"},
}


def value_rule(ic, y, x, layer_idx, case_name):
    seed = CASES[case_name]["seed"]
    v = ((ic + 3 * y + 5 * x + seed + 7 * (layer_idx + 1)) % 13) - 6
    if CASES[case_name]["zero_mode"] == "low":
        if ((ic + 2 * y + 3 * x + layer_idx + seed) % 19 == 0):
            v = 0
    elif CASES[case_name]["zero_mode"] == "medium":
        if ((ic + 3 * y + 5 * x + layer_idx + seed) % 7 == 0):
            v = 0
    else:
        if ((ic + 2 * y + 4 * x + layer_idx + seed) % 3 == 0):
            v = 0
    return v


def weight_rule(oc, ic, ky, kx, layer_idx):
    return ((oc + ic + ky + kx + layer_idx + 1) % 7) - 3


def dense_conv(input_tensor, in_c, out_c):
    output = [[[0 for _ in range(W)] for _ in range(H)] for _ in range(out_c)]
    for oc in range(out_c):
        for y in range(H):
            for x in range(W):
                acc = 0
                for ic in range(in_c):
                    for ky in range(K):
                        for kx in range(K):
                            yy = y + ky - 1
                            xx = x + kx - 1
                            if 0 <= yy < H and 0 <= xx < W:
                                val = input_tensor[ic][yy][xx]
                                w = weight_rule(oc, ic, ky, kx, 0)
                                acc += val * w
                output[oc][y][x] = acc
    return output


def dense_conv_layer(input_tensor, in_c, out_c, layer_idx):
    output = [[[0 for _ in range(W)] for _ in range(H)] for _ in range(out_c)]
    for oc in range(out_c):
        for y in range(H):
            for x in range(W):
                acc = 0
                for ic in range(in_c):
                    for ky in range(K):
                        for kx in range(K):
                            yy = y + ky - 1
                            xx = x + kx - 1
                            if 0 <= yy < H and 0 <= xx < W:
                                val = input_tensor[ic][yy][xx]
                                w = weight_rule(oc, ic, ky, kx, layer_idx)
                                acc += val * w
                output[oc][y][x] = acc
    return output


def sparse_conv_layer(input_tensor, in_c, out_c, layer_idx):
    output = [[[0 for _ in range(W)] for _ in range(H)] for _ in range(out_c)]
    for oc in range(out_c):
        for y in range(H):
            for x in range(W):
                acc = 0
                for ic in range(in_c):
                    for ky in range(K):
                        for kx in range(K):
                            yy = y + ky - 1
                            xx = x + kx - 1
                            if 0 <= yy < H and 0 <= xx < W:
                                val = input_tensor[ic][yy][xx]
                                if val != 0:
                                    w = weight_rule(oc, ic, ky, kx, layer_idx)
                                    acc += val * w
                output[oc][y][x] = acc
    return output


def flatten_tensor(tensor):
    flat = []
    for oc in range(len(tensor)):
        for y in range(H):
            for x in range(W):
                flat.append(tensor[oc][y][x])
    return flat


def make_input_tensor(case_name, layer_idx, in_c):
    tensor = [[[0 for _ in range(W)] for _ in range(H)] for _ in range(in_c)]
    for ic in range(in_c):
        for y in range(H):
            for x in range(W):
                tensor[ic][y][x] = value_rule(ic, y, x, layer_idx, case_name)
    return tensor


def layer_stats(case_name, layer_name, in_c, out_c, layer_idx, activations):
    dense_out = dense_conv_layer(activations, in_c, out_c, layer_idx)
    sparse_out = sparse_conv_layer(activations, in_c, out_c, layer_idx)
    dense_flat = flatten_tensor(dense_out)
    sparse_flat = flatten_tensor(sparse_out)
    if dense_flat != sparse_flat:
        raise SystemExit(f"Dense/sparse mismatch in {case_name}/{layer_name}")

    total_elements = in_c * H * W
    zero_elements = sum(1 for val in flatten_tensor([[[activations[ic][y][x] for x in range(W)] for y in range(H)] for ic in range(in_c)]) if val == 0)
    activation_sparsity = (zero_elements / total_elements) * 100.0
    dense_macs = H * W * out_c * in_c * K * K
    useful_macs = 0
    skipped_macs = 0
    for oc in range(out_c):
        for y in range(H):
            for x in range(W):
                for ic in range(in_c):
                    for ky in range(K):
                        for kx in range(K):
                            yy = y + ky - 1
                            xx = x + kx - 1
                            if 0 <= yy < H and 0 <= xx < W:
                                if activations[ic][yy][xx] == 0:
                                    skipped_macs += 1
                                else:
                                    useful_macs += 1
                            else:
                                skipped_macs += 1
    effective_sparsity = (skipped_macs / dense_macs) * 100.0
    return {
        "case": case_name,
        "layer": layer_name,
        "layer_index": layer_idx,
        "in_c": in_c,
        "out_c": out_c,
        "total_elements": total_elements,
        "zero_elements": zero_elements,
        "activation_sparsity": activation_sparsity,
        "dense_macs": dense_macs,
        "useful_macs": useful_macs,
        "skipped_macs": skipped_macs,
        "effective_sparsity": effective_sparsity,
        "dense_output": dense_out,
        "sparse_output": sparse_out,
        "dense_match": dense_flat == sparse_flat,
    }


def main():
    all_results = {}
    current_tensor = None
    for case_name in ["A", "B", "C"]:
        all_results[case_name] = []
        current_tensor = None
        for layer_idx, layer in enumerate(LAYER_SPECS):
            in_c = layer["in_c"]
            out_c = layer["out_c"]
            if current_tensor is None:
                current_tensor = make_input_tensor(case_name, layer_idx, in_c)
            stats = layer_stats(case_name, layer["name"], in_c, out_c, layer_idx, current_tensor)
            all_results[case_name].append(stats)
            current_tensor = dense_conv_layer(current_tensor, in_c, out_c, layer_idx)

    output_path = Path(__file__).resolve().with_name('stage12_python_summary.json')
    output_path.write_text(json.dumps(all_results, indent=2), encoding='utf-8')

    for case_name in ["A", "B", "C"]:
        print(f"CASE {case_name}")
        for stats in all_results[case_name]:
            print(
                f"  {stats['layer']}: activation_sparsity={stats['activation_sparsity']:.4f}% "
                f"dense_macs={stats['dense_macs']} useful_macs={stats['useful_macs']} "
                f"skipped_macs={stats['skipped_macs']} effective_sparsity={stats['effective_sparsity']:.4f}% "
                f"dense_match={stats['dense_match']}"
            )

    if any(not s['dense_match'] for case in all_results.values() for s in case):
        raise SystemExit('Dense/sparse output mismatch detected.')

    print('STAGE 12 PYTHON REFERENCE: PASS')


if __name__ == '__main__':
    main()
