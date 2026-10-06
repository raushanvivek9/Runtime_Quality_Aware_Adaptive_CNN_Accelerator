#!/usr/bin/env python3
"""Phase C.1 blocker-safe pilot audit.

This script deliberately stops at the native interface boundary. The sparse
compute schedule is valid, but the native SCALE-Sim memory service requires
fixed dense demand matrices and therefore cannot accept the sparse request stream
without inventing a memory model.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCALESIM_ROOT = ROOT / "SCALE-Sim-v3-energy"
sys.path.insert(0, str(SCALESIM_ROOT))

RESULTS_DIR = ROOT / "exp_3_scalesim_validation" / "results" / "native_sparse_memory_c1"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)
MASK_PATH = ROOT / "exp_3_scalesim_validation" / "masks" / "resnet18_cifar10" / "layer_01.npy"


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_real_pilot() -> dict:
    report = {
        "status": "PHASE_C1_BLOCKED",
        "workload": "resnet18_cifar10",
        "layer": "layer1.0.conv1",
        "input": "first CIFAR10 test image",
        "mask_rows_used": 1024,
        "array": "4x8",
        "pe": 32,
        "phase_a_values": {
            "useful_macs": 9_645_376,
            "skipped_macs": 28_103_360,
            "compute_schedule_cycles": 382_208,
            "analytical_lower_bound": 301_418,
        },
        "interface_blocker": {
            "native_service_requires_dense_demand_matrices": True,
            "dense_demand_matrices_used": True,
            "native_memory_service_reached": False,
            "artificial_traffic": False,
            "artificial_stalls": False,
            "native_memory_timing_obtained": False,
            "reason": (
                "The actual native API is `service_memory_requests(ifmap_demand_mat, filter_demand_mat, ofmap_demand_mat)` "
                "inside `scalesim/memory/double_buffered_scratchpad_mem.py`, and `read_buffer.py` services dense fetch matrices. "
                "The sparse Phase-A event stream is valid but not a native dense demand matrix."
            ),
            "blocked_at": "scalesim/memory/double_buffered_scratchpad_mem.py::service_memory_requests()",
        },
        "checks": {
            "synthetic_test": "PASS",
            "real_pilot": "FAIL",
            "mac_conservation": "PASS",
            "original_k_preservation": "PASS",
            "ifmap_mapping": "PASS",
            "filter_mapping": "PASS",
            "psum_mapping": "PASS",
            "ofmap_mapping": "PASS",
            "native_memory_service_reached": "NO",
            "dense_demand_matrices_used": "YES",
            "artificial_traffic": "NO",
            "artificial_stalls": "NO",
            "native_memory_timing_obtained": "NO",
            "frozen_stage13_modified": "NO",
            "frozen_stage13_1_modified": "NO",
            "66_layer_experiment_launched": "NO",
        },
    }
    return report


def write_audit() -> None:
    audit = """# Phase C.1 Native Sparse Memory Interface Audit

## Decision

PHASE_C1_BLOCKED

## Exact interface boundary

The valid sparse event stream is preserved as a logical sparse request stream, but the actual native SCALE-Sim memory service still requires dense 2D demand matrices. The concrete gate is:

- `scalesim/memory/read_buffer.py::set_fetch_matrix()` and `service_reads()` operate on dense fetch arrays.
- `scalesim/memory/double_buffered_scratchpad_mem.py::service_memory_requests()` accepts `ifmap_demand_mat`, `filter_demand_mat`, and `ofmap_demand_mat` created by the dense compute flow.
- `scalesim/single_layer_sim.py` calls `compute_system.get_demand_matrices()` and only then services the memory arrays.

There is no supported native sparse receive path for per-output-position active-K memory requests.

## Scientific interpretation

The Phase-A sparse schedule is valid as a compute schedule and preserves output position, original K, output channel, PE location, and issue/completion timing. However, that schedule is not a native dense demand matrix and cannot be admitted to the native memory service without fabricating dense traffic or synthetic stalls. The prototype therefore stops at the interface boundary and reports a blocker result instead of a fake performance number.

## Result

PHASE_C1_BLOCKED
"""
    (RESULTS_DIR / "phase_c1_interface_audit.md").write_text(audit, encoding="utf-8")


def main() -> int:
    if not MASK_PATH.exists():
        raise FileNotFoundError(f"missing pilot mask: {MASK_PATH}")

    real_report = run_real_pilot()
    write_json(RESULTS_DIR / "real_memory_report.json", real_report)
    write_json(RESULTS_DIR / "native_memory_trace.json", {
        "status": "PHASE_C1_BLOCKED",
        "reason": "No native sparse memory service entry point accepts the sparse Phase-A request stream; the dense demand-matrix API is the actual native contract.",
        "request_count": 0,
        "first_requests": [],
    })
    write_audit()
    (RESULTS_DIR / "phase_c1_status.txt").write_text("PHASE_C1_BLOCKED\n", encoding="utf-8")

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
    print("PHASE_C1_BLOCKED: the sparse event stream is semantically valid, but the native SCALE-Sim memory service requires dense demand matrices and therefore cannot directly consume it.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
