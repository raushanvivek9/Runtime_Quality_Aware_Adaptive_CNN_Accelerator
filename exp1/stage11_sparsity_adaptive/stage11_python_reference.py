#!/usr/bin/env python3

from pathlib import Path

H = 8
W = 8
CIN = 3
COUT = 16
KH = 3
KW = 3
DENSE_MACS = H * W * COUT * CIN * KH * KW


def input_value(ic, row, col):
    return ((ic + row + col) % 5) - 2


def weight_value(oc, ic, ky, kx):
    return ((oc + ic + ky + kx) % 3) - 1


def dense_convolution():
    out = [[[0 for _ in range(W)] for _ in range(H)] for _ in range(COUT)]
    for oc in range(COUT):
        for y in range(H):
            for x in range(W):
                acc = 0
                for ic in range(CIN):
                    for ky in range(KH):
                        for kx in range(KW):
                            yy = y + ky - 1
                            xx = x + kx - 1
                            if 0 <= yy < H and 0 <= xx < W:
                                acc += input_value(ic, yy, xx) * weight_value(oc, ic, ky, kx)
                out[oc][y][x] = acc
    return out


def sparse_convolution():
    out = [[[0 for _ in range(W)] for _ in range(H)] for _ in range(COUT)]
    for oc in range(COUT):
        for y in range(H):
            for x in range(W):
                acc = 0
                for ic in range(CIN):
                    for ky in range(KH):
                        for kx in range(KW):
                            yy = y + ky - 1
                            xx = x + kx - 1
                            if 0 <= yy < H and 0 <= xx < W:
                                val = input_value(ic, yy, xx)
                                if val != 0:
                                    acc += val * weight_value(oc, ic, ky, kx)
                out[oc][y][x] = acc
    return out


def compute_reference_stats():
    total_input_values = H * W * CIN
    zero_input_values = 0
    for ic in range(CIN):
        for row in range(H):
            for col in range(W):
                if input_value(ic, row, col) == 0:
                    zero_input_values += 1
    input_sparsity = (zero_input_values / total_input_values) * 100.0

    useful_mac_count = 0
    skipped_mac_count = 0
    for oc in range(COUT):
        for y in range(H):
            for x in range(W):
                for ic in range(CIN):
                    for ky in range(KH):
                        for kx in range(KW):
                            yy = y + ky - 1
                            xx = x + kx - 1
                            if 0 <= yy < H and 0 <= xx < W:
                                val = input_value(ic, yy, xx)
                                if val == 0:
                                    skipped_mac_count += 1
                                else:
                                    useful_mac_count += 1
                            else:
                                skipped_mac_count += 1
    dense_output = dense_convolution()
    sparse_output = sparse_convolution()
    dense_match = dense_output == sparse_output
    effective_sparsity = (skipped_mac_count / DENSE_MACS) * 100.0
    return {
        'total_input_values': total_input_values,
        'zero_input_values': zero_input_values,
        'input_sparsity_percent': input_sparsity,
        'dense_mac_count': DENSE_MACS,
        'useful_mac_count': useful_mac_count,
        'skipped_mac_count': skipped_mac_count,
        'effective_sparsity_percent': effective_sparsity,
        'dense_output': dense_output,
        'sparse_output': sparse_output,
        'dense_match': dense_match,
    }


def main():
    stats = compute_reference_stats()
    print(f"INPUT SPARSITY: {stats['input_sparsity_percent']:.4f}%")
    print(f"TOTAL INPUT VALUES: {stats['total_input_values']}")
    print(f"ZERO INPUT VALUES: {stats['zero_input_values']}")
    print(f"DENSE MACS: {stats['dense_mac_count']}")
    print(f"USEFUL MACS: {stats['useful_mac_count']}")
    print(f"SKIPPED MACS: {stats['skipped_mac_count']}")
    print(f"EFFECTIVE SPARSITY: {stats['effective_sparsity_percent']:.4f}%")
    print(f"DENSE OUTPUT: {'PASS' if stats['dense_match'] else 'FAIL'}")
    if not stats['dense_match']:
        raise SystemExit('Dense and sparse outputs differ.')
    print('SPARSE OUTPUT: PASS')
    print(f"ALL OUTPUTS VERIFIED: {H * W * COUT}")
    out_file = Path(__file__).with_name('stage11_python_summary.json')
    out_file.write_text(str(stats).replace("'", '"'), encoding='utf-8')


if __name__ == "__main__":
    main()
