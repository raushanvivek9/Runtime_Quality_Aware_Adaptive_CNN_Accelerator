#!/usr/bin/env python3
"""Independent numerical checks for the Stage 8C integration stimuli."""

from __future__ import annotations

FRAC_BITS = 16
SCALE = 1 << FRAC_BITS
D_MAX = 3277
MATRIX_DIM = 8

LAYER_STREAMS = {
    "conv1": [1, 0, 1, 0],
    "conv2": [0, 3, 0, -3],
    "conv3": [0, 4, 0, -4],
}
EXPECTED = {
    "conv1": (4, 2, 2, 2, 32768, 32768, 16384, 950, 475, 16),
    "conv2": (4, 2, 0, 18, 32768, 0, 294912, 4200, 2100, 32),
    "conv3": (4, 2, 0, 32, 32768, 0, 524288, 7000, 3500, 64),
}


def trunc_toward_zero(numerator: int, denominator: int) -> int:
    return numerator // denominator if numerator >= 0 else -((-numerator) // denominator)


def stats_and_decision(samples: list[int]) -> tuple[int, ...]:
    count = len(samples)
    zeros = sum(value == 0 for value in samples)
    total = sum(samples)
    total_square = sum(value * value for value in samples)
    sparsity = (zeros * SCALE) // count
    mean = trunc_toward_zero(total * SCALE, count)
    second_moment = (total_square * SCALE) // count
    variance = max(0, second_moment - ((mean * mean) >> FRAC_BITS))
    d16 = (1200 * sparsity + 300 * abs(mean) + 800 * variance) >> FRAC_BITS
    d32 = (600 * sparsity + 150 * abs(mean) + 400 * variance) >> FRAC_BITS
    resource = 16 if d16 <= D_MAX else 32 if d32 <= D_MAX else 64
    return (count, zeros, total, total_square, sparsity, mean, variance, d16, d32, resource)


def a_value(row: int, col: int) -> int:
    return row + col + 2


def b_value(row: int, col: int) -> int:
    return col - row + 8


def gemm() -> list[list[int]]:
    return [
        [sum(a_value(row, k) * b_value(k, col) for k in range(MATRIX_DIM))
         for col in range(MATRIX_DIM)]
        for row in range(MATRIX_DIM)
    ]


def main() -> None:
    for name, samples in LAYER_STREAMS.items():
        actual = stats_and_decision(samples)
        if actual != EXPECTED[name]:
            raise AssertionError(f"{name}: {actual} != {EXPECTED[name]}")
        print(f"PASS {name}: stats/D16/D32/resource={actual}")

    golden = gemm()
    if golden[0][0] != 156 or golden[7][7] != 1108:
        raise AssertionError("unexpected deterministic GEMM golden result")
    print("PASS GEMM: 8x8 integer golden matrix; C[0][0]=156, C[7][7]=1108")
    print("Reference PASS: activation statistics, Q16.16 estimates, and GEMM are consistent.")


if __name__ == "__main__":
    main()
