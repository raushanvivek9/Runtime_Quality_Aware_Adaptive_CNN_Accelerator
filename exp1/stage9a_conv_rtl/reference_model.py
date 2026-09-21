#!/usr/bin/env python3
"""Independent integer reference for the Stage 9A padded convolution."""

from __future__ import annotations

from pathlib import Path

ACC_WIDTH = 48
INPUT_H = 8
INPUT_W = 8
INPUT_C = 3
KERNEL_H = 3
KERNEL_W = 3
OUTPUT_C = 16
OUTPUT_H = 8
OUTPUT_W = 8


def input_value(ic: int, row: int, col: int) -> int:
    return ((ic + row + col) % 5) - 2


def weight_value(oc: int, ic: int, kh: int, kw: int) -> int:
    return ((oc + ic + kh + kw) % 3) - 1


def convolution() -> list[list[list[int]]]:
    output: list[list[list[int]]] = []
    for oc in range(OUTPUT_C):
        channel: list[list[int]] = []
        for oh in range(OUTPUT_H):
            row: list[int] = []
            for ow in range(OUTPUT_W):
                total = 0
                for ic in range(INPUT_C):
                    for kh in range(KERNEL_H):
                        for kw in range(KERNEL_W):
                            ih = oh + kh - 1
                            iw = ow + kw - 1
                            activation = (
                                input_value(ic, ih, iw)
                                if 0 <= ih < INPUT_H and 0 <= iw < INPUT_W
                                else 0
                            )
                            total += activation * weight_value(oc, ic, kh, kw)
                row.append(total)
            channel.append(row)
        output.append(channel)
    return output


def write_mem(output: list[list[list[int]]], destination: Path) -> None:
    mask = (1 << ACC_WIDTH) - 1
    with destination.open("w", encoding="ascii") as handle:
        for oc in range(OUTPUT_C):
            for oh in range(OUTPUT_H):
                for ow in range(OUTPUT_W):
                    handle.write(f"{output[oc][oh][ow] & mask:012x}\n")


def write_text(output: list[list[list[int]]], destination: Path) -> None:
    with destination.open("w", encoding="ascii") as handle:
        for oc, channel in enumerate(output):
            handle.write(f"output channel {oc}\n")
            for row in channel:
                handle.write(" ".join(f"{value:4d}" for value in row) + "\n")
            handle.write("\n")


def main() -> None:
    output = convolution()
    root = Path(__file__).resolve().parent
    write_mem(output, root / "golden_output.mem")
    write_text(output, root / "golden_output.txt")

    print("Stage 9A Python reference PASS")
    print(f"Output elements: {OUTPUT_C * OUTPUT_H * OUTPUT_W}")
    print(f"MACs per output: {INPUT_C * KERNEL_H * KERNEL_W}")
    print(f"Total MAC operations: {OUTPUT_C * OUTPUT_H * OUTPUT_W * INPUT_C * KERNEL_H * KERNEL_W}")
    print(f"O[0][0][0] = {output[0][0][0]}")
    print(f"O[0][0][1] = {output[0][0][1]}")
    print(f"O[1][3][3] = {output[1][3][3]}")
    print(f"O[15][7][7] = {output[15][7][7]}")
    print("Complete output tensor written to golden_output.txt")


if __name__ == "__main__":
    main()
