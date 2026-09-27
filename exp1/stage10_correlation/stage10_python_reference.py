#!/usr/bin/env python3

import math
from pathlib import Path

H = 8
W = 8
Cin = 3
Cout = 16
Kh = 3
Kw = 3


def input_value(ic, row, col):
    return ((ic + row + col) % 5) - 2


def weight_value(oc, ic, kh_idx, kw_idx):
    return ((oc + ic + kh_idx + kw_idx) % 3) - 1


def compute_output():
    out = [[[0 for _ in range(W)] for _ in range(H)] for _ in range(Cout)]
    for oc in range(Cout):
        for y in range(H):
            for x in range(W):
                acc = 0
                for ic in range(Cin):
                    for ky in range(Kh):
                        for kx in range(Kw):
                            yy = y + ky - 1
                            xx = x + kx - 1
                            if 0 <= yy < H and 0 <= xx < W:
                                acc += input_value(ic, yy, xx) * weight_value(oc, ic, ky, kx)
                out[oc][y][x] = acc
    return out


def validate(out):
    assert len(out) == Cout, f"Cout mismatch: {len(out)} != {Cout}"
    assert all(len(ch) == H for ch in out), "H mismatch"
    assert all(len(row) == W for ch in out for row in ch), "W mismatch"
    flat = [v for oc in out for row in oc for v in row]
    assert len(flat) == H * W * Cout, f"output count mismatch: {len(flat)} != {H * W * Cout}"
    assert flat[0] == 2, f"checkpoint O[0][0][0] mismatch: {flat[0]}"
    assert flat[1] == 5, f"checkpoint O[0][0][1] mismatch: {flat[1]}"
    assert flat[(1 * H * W) + (3 * W) + 3] == 0, "checkpoint O[1][3][3] mismatch"
    assert flat[(15 * H * W) + (7 * W) + 7] == 14, "checkpoint O[15][7][7] mismatch"
    total_macs = H * W * Cout * Cin * Kh * Kw
    assert total_macs == 27648, f"MAC mismatch: {total_macs}"
    return flat


def main():
    out = compute_output()
    flat = validate(out)
    text_path = Path(__file__).with_name("python_reference.txt")
    text_path.write_text("\n".join(str(v) for v in flat) + "\n", encoding="utf-8")
    print("PYTHON REFERENCE: PASS")
    print(f"output_shape=({Cout},{H},{W})")
    print(f"output_elements={len(flat)}")
    print(f"total_macs={H * W * Cout * Cin * Kh * Kw}")


if __name__ == "__main__":
    main()
