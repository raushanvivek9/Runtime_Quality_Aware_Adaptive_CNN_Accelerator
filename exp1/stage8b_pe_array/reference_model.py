#!/usr/bin/env python3
"""Integer GEMM golden model for the Stage 8B deterministic workload.

This model validates the mathematics only. It does not model hardware timing,
power, area, energy, or neural-network accuracy.
"""

from __future__ import annotations

MATRIX_DIM = 8


def a_value(row: int, col: int) -> int:
    """Must match a_value in tb_adaptive_compute.sv."""
    return row + col + 2


def b_value(row: int, col: int) -> int:
    """Must match b_value in tb_adaptive_compute.sv; row is GEMM k."""
    return col - row + 8


def matmul(a: list[list[int]], b: list[list[int]]) -> list[list[int]]:
    return [
        [sum(a[row][k] * b[k][col] for k in range(MATRIX_DIM))
         for col in range(MATRIX_DIM)]
        for row in range(MATRIX_DIM)
    ]


def main() -> None:
    a = [[a_value(row, col) for col in range(MATRIX_DIM)] for row in range(MATRIX_DIM)]
    b = [[b_value(row, col) for col in range(MATRIX_DIM)] for row in range(MATRIX_DIM)]
    c = matmul(a, b)

    expected_operation_count = MATRIX_DIM * MATRIX_DIM * MATRIX_DIM
    expected_cycles = {16: 32, 32: 16, 64: 8}

    print("A =")
    for row in a:
        print(" ", row)
    print("B =")
    for row in b:
        print(" ", row)
    print("Golden C = A @ B =")
    for row in c:
        print(" ", row)
    print(f"MAC operations: {expected_operation_count}")
    for active_pe_count, cycles in expected_cycles.items():
        print(f"Scheduler reference: active_pe_count={active_pe_count}, MAC cycles={cycles}")

    # Basic deterministic checks protect the intended workload definition.
    assert c[0][0] == 156
    assert c[7][7] == 1108
    assert all(value > 0 for row in c for value in row)
    print("Reference PASS: deterministic integer GEMM golden matrix generated.")


if __name__ == "__main__":
    main()
