#!/usr/bin/env python3
"""Independent integer reference for the Stage 9B 3x3 padded convolution."""

from __future__ import annotations

from pathlib import Path

ACC_WIDTH = 48
INPUT_H = INPUT_W = 8
INPUT_C = 3
OUTPUT_C = 16
KERNEL_H = KERNEL_W = 3


def input_value(ic: int, row: int, col: int) -> int:
    return ((ic + row + col) % 5) - 2


def weight_value(oc: int, ic: int, kh: int, kw: int) -> int:
    return ((oc + ic + kh + kw) % 3) - 1


def convolution() -> list[list[list[int]]]:
    output: list[list[list[int]]] = []
    for oc in range(OUTPUT_C):
        channel: list[list[int]] = []
        for oh in range(INPUT_H):
            row: list[int] = []
            for ow in range(INPUT_W):
                total = 0
                for ic in range(INPUT_C):
                    for kh in range(KERNEL_H):
                        for kw in range(KERNEL_W):
                            ih, iw = oh + kh - 1, ow + kw - 1
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
        for channel in output:
            for row in channel:
                for value in row:
                    handle.write(f"{value & mask:012x}\n")


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
    input_tensor = [input_value(ic, h, w) for ic in range(INPUT_C)
                    for h in range(INPUT_H) for w in range(INPUT_W)]

    assert len(input_tensor) == 192
    assert OUTPUT_C * INPUT_H * INPUT_W == 1024
    assert OUTPUT_C * INPUT_H * INPUT_W * INPUT_C * KERNEL_H * KERNEL_W == 27648
    assert (output[0][0][0], output[0][0][1], output[1][3][3], output[15][7][7]) == (2, 5, 0, 14)

    print("Stage 9B Python reference PASS")
    print("Input elements: 192")
    print("Weight elements: 432")
    print("Output elements: 1024")
    print("Total MAC operations: 27648")
    print(f"Input monitor statistics: count={len(input_tensor)} zeroes={input_tensor.count(0)} "
          f"sum={sum(input_tensor)} sum_square={sum(value * value for value in input_tensor)}")
    print(f"O[0][0][0] = {output[0][0][0]}")
    print(f"O[0][0][1] = {output[0][0][1]}")
    print(f"O[1][3][3] = {output[1][3][3]}")
    print(f"O[15][7][7] = {output[15][7][7]}")
    print("golden_output.mem and golden_output.txt written")


if __name__ == "__main__":
    main()
