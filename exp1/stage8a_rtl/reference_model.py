#!/usr/bin/env python3
"""Numerical reference for the Stage 8A RTL self-checking vectors.

This is a validation aid only.  It uses normal Python integer/float arithmetic,
then applies the same Q16.16 truncation and 32-bit output saturation as the RTL.
"""

from __future__ import annotations

FRAC_BITS = 16
SCALE = 1 << FRAC_BITS
UQ16_MAX = (1 << 32) - 1
SQ16_MIN = -(1 << 31)
SQ16_MAX = (1 << 31) - 1

TEST_VECTORS = {
    "test1_all_nonzero_conv1": [1, 2, 3, 4],
    "test2_all_zero_conv2": [0, 0, 0, 0],
    "test3_signed_conv3": [0, 2, 0, -2],
    "test4_alternating_signed": [1, -1, 1, -1],
    "test5_negative_values": [-4, -3, -2, -1],
    "test6_large_values": [1000, -1000, 1000, -1000],
    "test8_zero_length": [],
}

# These are the constants asserted by tb_runtime_controller.sv.
RTL_EXPECTED = {
    "test1_all_nonzero_conv1": (4, 0, 10, 30, 0, 163840, 81920),
    "test2_all_zero_conv2": (4, 4, 0, 0, 65536, 0, 0),
    "test3_signed_conv3": (4, 2, 0, 8, 32768, 0, 131072),
    "test4_alternating_signed": (4, 0, 0, 4, 0, 0, 65536),
    "test5_negative_values": (4, 0, -10, 30, 0, -163840, 81920),
    "test6_large_values": (4, 0, 0, 4_000_000, 0, 0, UQ16_MAX),
    "test8_zero_length": (0, 0, 0, 0, 0, 0, 0),
}

# Feature vectors injected into the estimator/controller by Tests 9-12.
CONTROLLER_VECTORS = {
    "test9_controller_low": (0, 0, 0, 0, 0),
    "test10_controller_medium": (0, 0, 5 * SCALE, 4_000, 2_000),
    "test11_controller_high": (0, 0, 10 * SCALE, 8_000, 4_000),
    "test12_fixed64": (0, 0, 0, 0, 0),
}

CONTROLLER_EXPECTED = {
    "test9_controller_low": (0, False, 2),
    "test10_controller_medium": (1, False, 2),
    "test11_controller_high": (2, True, 2),
    "test12_fixed64": (0, False, 2),
}


def trunc_toward_zero(numerator: int, denominator: int) -> int:
    """Match signed SystemVerilog integer division for a positive denominator."""
    if numerator >= 0:
        return numerator // denominator
    return -((-numerator) // denominator)


def saturate_signed_q16(value: int) -> int:
    return min(SQ16_MAX, max(SQ16_MIN, value))


def saturate_unsigned_q16(value: int) -> int:
    return min(UQ16_MAX, max(0, value))


def calculate(samples: list[int]) -> tuple[tuple[int, ...], dict[str, float | int]]:
    count = len(samples)
    zero_count = sum(sample == 0 for sample in samples)
    total = sum(samples)
    total_square = sum(sample * sample for sample in samples)
    if count == 0:
        result = (0, 0, 0, 0, 0, 0, 0)
        return result, {"mean": 0.0, "variance": 0.0, "variance_q16_exact": 0}

    sparsity_q16 = saturate_unsigned_q16((zero_count * SCALE) // count)
    mean_q16_wide = trunc_toward_zero(total * SCALE, count)
    mean_q16 = saturate_signed_q16(mean_q16_wide)
    second_moment_q16 = (total_square * SCALE) // count
    mean_square_q16 = (mean_q16_wide * mean_q16_wide) >> FRAC_BITS
    variance_q16_exact = second_moment_q16 - mean_square_q16
    variance_q16 = saturate_unsigned_q16(max(0, variance_q16_exact))

    result = (count, zero_count, total, total_square, sparsity_q16, mean_q16, variance_q16)
    mean_float = total / count
    variance_float = (total_square / count) - mean_float * mean_float
    return result, {
        "mean": mean_float,
        "variance": variance_float,
        "variance_q16_exact": variance_q16_exact,
    }


def estimate_degradation(sparsity: int, mean: int, variance: int, pe: int) -> int:
    """Match the non-negative Q16.16 prototype estimator in quality_estimator."""
    coefficients = {16: (1200, 300, 800), 32: (600, 150, 400)}
    sparse_coeff, mean_coeff, variance_coeff = coefficients[pe]
    return min(
        UQ16_MAX,
        (sparse_coeff * sparsity + mean_coeff * abs(mean) + variance_coeff * variance)
        >> FRAC_BITS,
    )


def adaptive_resource(d16: int, d32: int) -> tuple[int, bool]:
    d_max = 3277
    if d16 <= d_max:
        return 0, False
    if d32 <= d_max:
        return 1, False
    return 2, True


def main() -> None:
    for name, samples in TEST_VECTORS.items():
        calculated, detail = calculate(samples)
        expected = RTL_EXPECTED[name]
        if calculated != expected:
            raise AssertionError(
                f"{name}: Python-derived RTL values {calculated} != testbench {expected}"
            )
        print(
            f"PASS {name}: stats/features={calculated}; "
            f"float_mean={detail['mean']}; float_variance={detail['variance']}; "
            f"exact_variance_q16={detail['variance_q16_exact']}"
        )

    for name, (sparsity, mean, variance, expected_d16, expected_d32) in CONTROLLER_VECTORS.items():
        d16 = estimate_degradation(sparsity, mean, variance, 16)
        d32 = estimate_degradation(sparsity, mean, variance, 32)
        adaptive_cfg, fallback = adaptive_resource(d16, d32)
        expected_cfg, expected_fallback, expected_fixed64_cfg = CONTROLLER_EXPECTED[name]
        if (d16, d32, adaptive_cfg, fallback) != (
            expected_d16,
            expected_d32,
            expected_cfg,
            expected_fallback,
        ):
            raise AssertionError(f"{name}: estimator/controller reference mismatch")
        print(
            f"PASS {name}: d16={d16}; d32={d32}; adaptive_cfg={adaptive_cfg}; "
            f"fallback={fallback}; fixed64_cfg={expected_fixed64_cfg}"
        )

    print(
        "Reference PASS. Intentional quantization: integer division truncates "
        "toward zero for signed mean; variance is clamped to zero then saturated "
        "to 0xffffffff when it exceeds unsigned 32-bit Q16.16 range."
    )


if __name__ == "__main__":
    main()
