#!/usr/bin/env python3
"""Independent Python reference model for the Stage 9C prototype CNN."""

import math
from pathlib import Path

DATA_W = 16
INPUT_C = 3
INPUT_H = 8
INPUT_W = 8
OUTPUT_C = 16
KERNEL = 3
PAD = 1


def clamp16(value):
    return max(-2**15, min(2**15 - 1, int(value)))


def make_input():
    data = []
    for idx in range(INPUT_C * INPUT_H * INPUT_W):
        data.append(clamp16(((idx % 11) - 5) * 3 + ((idx // 11) % 7) - 3))
    return data


def make_weights():
    weights = []
    for idx in range(OUTPUT_C * INPUT_C * KERNEL * KERNEL):
        weights.append(clamp16(((idx * 7) % 19) - 9))
    return weights


def conv3x3(input_tensor, weight_tensor, out_channels=OUTPUT_C, in_channels=INPUT_C):
    out = []
    for ch in range(out_channels):
        for row in range(INPUT_H):
            for col in range(INPUT_W):
                acc = 0
                for ic in range(in_channels):
                    for kr in range(KERNEL):
                        for kc in range(KERNEL):
                            r = row + kr - PAD
                            c = col + kc - PAD
                            if 0 <= r < INPUT_H and 0 <= c < INPUT_W:
                                idx = (ic * INPUT_H + r) * INPUT_W + c
                                widx = ((ch * in_channels + ic) * KERNEL + kr) * KERNEL + kc
                                acc += input_tensor[idx] * weight_tensor[widx]
                out.append(clamp16(acc))
    return out


def pool2x2(input_tensor, channels=OUTPUT_C):
    out = []
    for ch in range(channels):
        for row in range(INPUT_H // 2):
            for col in range(INPUT_W // 2):
                vals = [
                    input_tensor[(ch * INPUT_H + 2 * row) * INPUT_W + 2 * col],
                    input_tensor[(ch * INPUT_H + 2 * row) * INPUT_W + 2 * col + 1],
                    input_tensor[(ch * INPUT_H + 2 * row + 1) * INPUT_W + 2 * col],
                    input_tensor[(ch * INPUT_H + 2 * row + 1) * INPUT_W + 2 * col + 1],
                ]
                out.append(clamp16(max(vals)))
    return out


def main():
    input_tensor = make_input()
    weights = make_weights()
    conv1 = conv3x3(input_tensor, weights)
    pool1 = pool2x2(conv1)
    conv2 = conv3x3(pool1, weights)
    pool2 = pool2x2(conv2)
    conv3 = conv3x3(pool2, weights)

    print(f"Stage 9C reference model: conv1={len(conv1)}, pool1={len(pool1)}, conv2={len(conv2)}, pool2={len(pool2)}, conv3={len(conv3)}")
    print(f"Total output elements: {len(conv3)}")
    print(f"Conv1 checksum: {sum(abs(v) for v in conv1) % 100000}")
    print(f"Pool1 checksum: {sum(abs(v) for v in pool1) % 100000}")
    print(f"Conv2 checksum: {sum(abs(v) for v in conv2) % 100000}")
    print(f"Pool2 checksum: {sum(abs(v) for v in pool2) % 100000}")
    print(f"Conv3 checksum: {sum(abs(v) for v in conv3) % 100000}")

    out = Path("stage9c_reference.txt")
    with out.open("w", encoding="utf-8") as handle:
        handle.write("conv1\n")
        for v in conv1:
            handle.write(f"{v}\n")
        handle.write("pool1\n")
        for v in pool1:
            handle.write(f"{v}\n")
        handle.write("conv2\n")
        for v in conv2:
            handle.write(f"{v}\n")
        handle.write("pool2\n")
        for v in pool2:
            handle.write(f"{v}\n")
        handle.write("conv3\n")
        for v in conv3:
            handle.write(f"{v}\n")
    print(f"Reference values saved to {out}")


if __name__ == "__main__":
    main()
