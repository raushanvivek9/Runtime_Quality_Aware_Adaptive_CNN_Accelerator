#!/usr/bin/env python3
"""
================================================================================
Project: Neural_Acc (Phase 2 RTL Implementation)
Task: TSK-10 Functional CNN Workload Validation
Module: functional_cnn_reference.py
Description: Independent Python Reference Model for 4x16 Output Tile CNN Workloads.
             Simulates multi-K reduction steps, signed 16-bit multiplication,
             40-bit saturating accumulation, exact-zero bypass, adaptive column
             gating (16-, 32-, and 64-PE modes), and generates memory-packed frames.
================================================================================
"""

import sys
from typing import List, Tuple, Dict, Optional

# 40-bit Saturation Bounds: [-2^39, 2^39 - 1]
SAT_MAX_POS = (1 << 39) - 1   #  549755813887 (0x7F_FFFF_FFFF)
SAT_MAX_NEG = -(1 << 39)      # -549755813888 (-0x80_0000_0000)

ROWS = 4
COLS = 16


def to_signed16(val: int) -> int:
    """Clamp/wrap value to 16-bit signed range [-32768, 32767]."""
    val = val & 0xFFFF
    if val >= 0x8000:
        val -= 0x10000
    return val


def to_unsigned32(val: int) -> int:
    """Format integer as 32-bit unsigned word."""
    return val & 0xFFFFFFFF


def sat40(val: int) -> Tuple[int, bool]:
    """
    Apply 40-bit saturation semantics.
    Returns (saturated_value, saturation_flag).
    """
    if val > SAT_MAX_POS:
        return SAT_MAX_POS, True
    elif val < SAT_MAX_NEG:
        return SAT_MAX_NEG, True
    return val, False


def compute_tile(
    act: List[List[int]],
    weights: List[List[int]],
    k_total: int,
    pe_mode: int = 2,
    initial_accum: Optional[List[List[int]]] = None
) -> Dict:
    """
    Compute 4x16 output tile using Neural_Acc microarchitectural rules:
      - act: 4 rows x k_total list of signed 16-bit integers
      - weights: 16 cols x k_total list of signed 16-bit integers
      - k_total: reduction steps (> 0)
      - pe_mode: 0 (16-PE), 1 (32-PE), 2 (64-PE)
      - initial_accum: optional prior accumulator state (default all 0)

    Returns dictionary with:
      - accum_out: 4x16 grid of 40-bit integers
      - sticky_sat: bool indicating if any active PE saturated
      - cycle_skipped_steps: count of zero-skipped operations
      - active_pe_count: 16, 32, or 64
    """
    if initial_accum is None:
        accum = [[0 for _ in range(COLS)] for _ in range(ROWS)]
    else:
        accum = [[initial_accum[r][c] for c in range(COLS)] for r in range(ROWS)]

    # Determine active columns based on PE mode
    if pe_mode == 0:     # 16-PE mode: Cols 0..3 active (4 rows x 4 cols = 16 PEs)
        active_cols = 4
        active_pe_count = 16
    elif pe_mode == 1:   # 32-PE mode: Cols 0..7 active (4 rows x 8 cols = 32 PEs)
        active_cols = 8
        active_pe_count = 32
    else:                # 64-PE mode: All 16 cols active (4 rows x 16 cols = 64 PEs)
        active_cols = 16
        active_pe_count = 64

    any_sat = False
    zero_skipped_macs = 0

    for k in range(k_total):
        # Extract row activations for step k
        a_step = [to_signed16(act[r][k]) for r in range(ROWS)]
        # Extract column weights for step k
        w_step = [to_signed16(weights[c][k]) for c in range(COLS)]

        for r in range(ROWS):
            a_val = a_step[r]
            # Exact-zero bypass check (AMD-02): if activation is exact zero, skip MAC
            is_zero_skip = (a_val == 0)

            for c in range(active_cols):
                w_val = w_step[c]
                if is_zero_skip:
                    zero_skipped_macs += 1
                    # Accumulator remains untouched on exact zero
                    continue

                prod = a_val * w_val
                new_sum = accum[r][c] + prod
                sat_sum, sat_flag = sat40(new_sum)
                accum[r][c] = sat_sum
                if sat_flag:
                    any_sat = True

    # Inactive columns are strictly clamped to 0 in RTL output
    for r in range(ROWS):
        for c in range(active_cols, COLS):
            accum[r][c] = 0

    return {
        "accum_out": accum,
        "sticky_saturation": any_sat,
        "zero_skipped_macs": zero_skipped_macs,
        "active_pe_count": active_pe_count,
        "active_cols": active_cols
    }


def pack_k_step_memory(act_step: List[int], weight_step: List[int]) -> List[int]:
    """
    Pack one K-step of 16 weights and 4 activations into 10x 32-bit words:
      - Words 0..7: 16 column weights (2 weights per 32-bit word, low-order first)
      - Words 8..9: 4 row activations (2 activations per 32-bit word, low-order first)
    """
    assert len(act_step) == 4, "Must provide exactly 4 row activations"
    assert len(weight_step) == 16, "Must provide exactly 16 column weights"

    words = []
    # Pack 16 weights into 8 words
    for i in range(8):
        w_low = weight_step[2 * i] & 0xFFFF
        w_high = weight_step[2 * i + 1] & 0xFFFF
        words.append((w_high << 16) | w_low)

    # Pack 4 activations into 2 words
    a0 = act_step[0] & 0xFFFF
    a1 = act_step[1] & 0xFFFF
    words.append((a1 << 16) | a0)

    a2 = act_step[2] & 0xFFFF
    a3 = act_step[3] & 0xFFFF
    words.append((a3 << 16) | a2)

    return words


def pack_workload(act: List[List[int]], weights: List[List[int]], k_total: int) -> List[int]:
    """
    Pack an entire multi-K workload into a contiguous list of 32-bit words
    with the 10-words-per-K layout. Total length = k_total * 10 words.
    """
    packed = []
    for k in range(k_total):
        a_step = [act[r][k] for r in range(ROWS)]
        w_step = [weights[c][k] for c in range(COLS)]
        packed.extend(pack_k_step_memory(a_step, w_step))
    return packed


# ==============================================================================
# Self-Test & Workload Case Generation
# ==============================================================================
def run_self_tests():
    print("=" * 70)
    print("TSK-10 Independent CNN Workload Reference Model - Self Test")
    print("=" * 70)

    # Case A: K=1 with distinct signed operands
    A_a = [[10], [-5], [20], [-12]]
    W_a = [[c + 1] for c in range(16)]
    res_a = compute_tile(A_a, W_a, k_total=1, pe_mode=2)
    assert res_a["accum_out"][0][0] == 10 * 1
    assert res_a["accum_out"][1][0] == -5 * 1
    assert res_a["accum_out"][0][15] == 10 * 16
    assert res_a["accum_out"][3][15] == -12 * 16
    print("[PASS] Case A: K=1 distinct signed operands verified.")

    # Case B: K=2 with positive and negative operands
    A_b = [[10, -8], [-5, 14], [20, -6], [-12, 25]]
    W_b = [[c + 1, -(c + 2)] for c in range(16)]
    res_b = compute_tile(A_b, W_b, k_total=2, pe_mode=2)
    exp_b_0_0 = (10 * 1) + (-8 * -2)  # 10 + 16 = 26
    assert res_b["accum_out"][0][0] == exp_b_0_0
    print("[PASS] Case B: K=2 mixed-sign multi-step verified.")

    # Case E: Zero-activation bypass
    A_e = [[0, 25], [30, 0], [0, -40], [-15, 0]]
    W_e = [[c + 1, 2 * (c + 1)] for c in range(16)]
    res_e = compute_tile(A_e, W_e, k_total=2, pe_mode=2)
    assert res_e["accum_out"][0][0] == 0 + 25 * 2
    assert res_e["accum_out"][1][0] == 30 * 1 + 0
    print("[PASS] Case E: Exact-zero bypass verified.")

    # Case G: Saturation boundary
    # 500,000 steps of 32767 * 32767 would exceed 2^39 - 1
    val_over = SAT_MAX_POS + 1000
    sat_val, sat_f = sat40(val_over)
    assert sat_val == SAT_MAX_POS and sat_f is True
    val_under = SAT_MAX_NEG - 1000
    sat_val_u, sat_f_u = sat40(val_under)
    assert sat_val_u == SAT_MAX_NEG and sat_f_u is True
    print("[PASS] Case G: 40-bit saturation boundaries verified.")

    # Case H: 16-PE Mode
    res_h = compute_tile(A_a, W_a, k_total=1, pe_mode=0)
    assert res_h["active_pe_count"] == 16
    for r in range(ROWS):
        for c in range(4):
            assert res_h["accum_out"][r][c] == A_a[r][0] * W_a[c][0]
        for c in range(4, COLS):
            assert res_h["accum_out"][r][c] == 0
    print("[PASS] Case H: 16-PE mode active/inactive columns verified.")

    # Case I: 32-PE Mode
    res_i = compute_tile(A_a, W_a, k_total=1, pe_mode=1)
    assert res_i["active_pe_count"] == 32
    for r in range(ROWS):
        for c in range(8):
            assert res_i["accum_out"][r][c] == A_a[r][0] * W_a[c][0]
        for c in range(8, COLS):
            assert res_i["accum_out"][r][c] == 0
    print("[PASS] Case I: 32-PE mode active/inactive columns verified.")

    # Memory packing check
    mem = pack_workload(A_b, W_b, k_total=2)
    assert len(mem) == 20, "2 steps x 10 words = 20 words"
    # Word 0: W[0][0] (1) and W[1][0] (2) -> 0x0002_0001
    assert mem[0] == 0x00020001
    # Word 8: A[0][0] (10 = 0x000A) and A[1][0] (-5 = 0xFFFB) -> 0xFFFB_000A
    assert mem[8] == 0xFFFB000A
    print("[PASS] Memory packing: 10-words-per-K layout verified.")
    print("=" * 70)
    print("ALL PYTHON REFERENCE MODEL SELF-TESTS PASSED!")
    print("=" * 70)


if __name__ == "__main__":
    run_self_tests()

