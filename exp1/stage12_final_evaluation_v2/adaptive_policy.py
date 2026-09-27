#!/usr/bin/env python3
"""Predeclared bounded-latency resource policy used by evaluation."""
import math

RESOURCE_OPTIONS = (16, 32, 64)
EPSILONS = (0.00, 0.05, 0.10, 0.20)

def choose_resource(useful_macs: int, epsilon: float) -> tuple[int, int, int, int]:
    baseline_cycles = math.ceil(useful_macs / 64)
    allowed_cycles = math.ceil(baseline_cycles * (1.0 + epsilon))
    for active_pes in RESOURCE_OPTIONS:
        cycles = math.ceil(useful_macs / active_pes)
        if cycles <= allowed_cycles:
            return active_pes, baseline_cycles, cycles, allowed_cycles
    return 64, baseline_cycles, baseline_cycles, allowed_cycles

if __name__ == "__main__":
    print("Predeclared policy: smallest PE count satisfying ceil(useful_MACs / PE) <= ceil(ceil(useful_MACs / 64) * (1 + epsilon)).")
    print("epsilon values:", ", ".join(str(value) for value in EPSILONS))
