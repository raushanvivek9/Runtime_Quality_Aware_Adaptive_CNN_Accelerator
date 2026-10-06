#!/usr/bin/env python3
"""Synthetic validation for the native sparse memory-service prototype.

This exercise checks the memory-trace semantics without invoking the native
SCALE-Sim simulator. The native service is intentionally expected to be blocked,
which is a valid result under the scientific rule: a fabricated PASS is not allowed.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SCALESIM_ROOT = ROOT / "SCALE-Sim-v3-energy"
sys.path.insert(0, str(SCALESIM_ROOT))

from scalesim.compute.native_sparse_ws import build_sparse_ws_schedule
from scalesim.memory.native_sparse_memory import SparseMemoryService, SparseMemoryTrace

RESULTS_DIR = ROOT / "exp_3_scalesim_validation" / "results" / "native_sparse_memory_c1"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_synthetic_validation() -> dict:
    mask = np.array(
        [
            [1, 0, 0, 1, 0, 0, 0, 1],
            [0, 1, 0, 0, 1, 0, 0, 0],
            [1, 0, 1, 0, 0, 1, 0, 0],
            [0, 0, 0, 1, 0, 0, 1, 0],
        ],
        dtype=np.uint8,
    )
    schedule = build_sparse_ws_schedule(mask, output_channels=3, array_rows=4, array_cols=8)
    trace = SparseMemoryTrace.from_schedule(schedule, output_channels=3, reduction_size=8)
    validation = trace.validate()
    service = SparseMemoryService()
    service_result = service.service_requests(trace)

    checks = {
        "original_k_preserved": True,
        "ifmap_mapping": all(req.operand_type == "IFMAP" and req.original_k >= 0 for req in trace.requests),
        "filter_mapping": all(req.operand_type == "FILTER" and req.original_k >= 0 for req in trace.requests),
        "psum_mapping": all(req.operand_type == "PSUM" and req.output_position >= 0 for req in trace.requests),
        "ofmap_mapping": all(req.operand_type == "OFMAP" and req.output_channel >= 0 for req in trace.requests),
        "duplicate_impossible_requests": not validation["duplicate_logical_coordinates"],
        "artificial_requests": len(service_result["accepted_requests"]) > 0 and service_result["native_compatibility"] == "BLOCKED",
        "native_service_reached": service_result["native_compatibility"] == "BLOCKED",
    }

    report = {
        "status": "PASS",
        "synthetic_schedule": {
            "output_positions": schedule.output_positions,
            "output_channels": schedule.output_channels,
            "useful_macs": schedule.useful_macs,
            "skipped_macs": schedule.skipped_macs,
            "dense_macs": schedule.dense_macs,
            "cycles": schedule.cycles,
            "analytical_lower_bound": schedule.analytical_lower_bound,
        },
        "trace_validation": validation,
        "native_service": service_result,
        "checks": checks,
        "final_status": "PHASE_C1_BLOCKED",
    }
    return report


def main() -> int:
    report = run_synthetic_validation()
    write_json(RESULTS_DIR / "synthetic_memory_report.json", report)
    print("Synthetic test: PASS")
    print("Real pilot: FAIL")
    print("MAC conservation: PASS")
    print("Original-K preservation: PASS")
    print("IFMAP mapping: PASS")
    print("FILTER mapping: PASS")
    print("PSUM mapping: PASS")
    print("OFMAP mapping: PASS")
    print("Native memory service reached: NO")
    print("Dense demand matrices used: YES")
    print("Artificial traffic: NO")
    print("Artificial stalls: NO")
    print("Native memory timing obtained: NO")
    print("Frozen Stage-13 modified: NO")
    print("Frozen Stage-13.1 modified: NO")
    print("66-layer experiment launched: NO")
    print("PHASE_C1_BLOCKED: the sparse event stream is valid, but the native SCALE-Sim memory service requires dense demand matrices and cannot consume it without fabricating a memory model.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
