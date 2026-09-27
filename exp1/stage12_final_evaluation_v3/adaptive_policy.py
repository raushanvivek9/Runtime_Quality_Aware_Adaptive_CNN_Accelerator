#!/usr/bin/env python3
import math
import yaml
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONFIG = yaml.safe_load((ROOT / "CONFIG.yaml").read_text())

def choose_pe(useful_macs, epsilon):
    baseline = math.ceil(useful_macs / 64); allowed = math.ceil(baseline * (1 + epsilon))
    for pe in CONFIG["resource_options"]:
        if math.ceil(useful_macs / pe) <= allowed: return pe
    return 64

if __name__ == "__main__":
    print("resource-aware adaptive execution")
    print("epsilon values:", CONFIG["sensitivity_epsilons"])
    print("constraint: smallest PE satisfying the declared latency bound")
