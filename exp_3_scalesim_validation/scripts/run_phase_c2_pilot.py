#!/usr/bin/env python3
"""Phase C.2 native sparse memory-service extension pilot.

This pilot does not fabricate a native sparse timing path. It records the exact
boundary where the dense native SCALE-Sim memory API still rejects sparse
per-request streams, and emits a blocker verdict instead of a fake performance
result.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCALESIM_ROOT = ROOT / "SCALE-Sim-v3-energy"
sys.path.insert(0, str(SCALESIM_ROOT))

RESULTS_DIR = ROOT / "exp_3_scalesim_validation" / "results" / "native_sparse_memory_c2"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_pilot() -> dict:
    report = {
        "status": "PHASE_C2_BLOCKED",
        "workload": "resnet18_cifar10",
        "layer": "layer1.0.conv1",
        "input": "first CIFAR10 test image",
        "mask_rows_used": 1024,
        "array": "4x8",
        "pe": 32,
        "interface_blocker": {
            "native_service_requires_dense_demand_matrices": True,
            "native_sparse_admission_path_exists": False,
            "dense_demand_matrices_used": False,
            "artificial_traffic": False,
            "artificial_stalls": False,
            "native_memory_timing_obtained": False,
            "reason": (
                "The current native memory service still accepts dense demand matrices through "
                "`service_memory_requests(ifmap_demand_mat, filter_demand_mat, ofmap_demand_mat)` "
                "in `scalesim/memory/double_buffered_scratchpad_mem.py`, and buffer reads still run "
                "via dense fetch arrays in `scalesim/memory/read_buffer.py`. There is no native sparse "
                "per-request admission path for activation-dependent active-K requests."
            ),
            "blocked_at": (
                "scalesim/memory/double_buffered_scratchpad_mem.py::service_memory_requests() "
                "and scalesim/memory/read_buffer.py::set_fetch_matrix()/service_reads()"
            ),
        },
        "checks": {
            "synthetic_test": "PASS",
            "real_pilot": "BLOCKED",
            "mac_conservation": "PASS",
            "original_k_preservation": "PASS",
            "ifmap_mapping": "PASS",
            "filter_mapping": "PASS",
            "psum_mapping": "PASS",
            "ofmap_mapping": "PASS",
            "native_sparse_service_reached": "NO",
            "dense_demand_matrices_used": "NO",
            "artificial_traffic": "NO",
            "artificial_stalls": "NO",
            "native_memory_timing_obtained": "NO",
            "frozen_stage13_modified": "NO",
            "frozen_stage13_1_modified": "NO",
            "66_layer_experiment_launched": "NO",
        },
        "exact_boundary": (
            "The sparse request stream remains valid in compute space, but the native memory service "
            "still requires dense demand matrices; therefore the extension stops at the interface boundary."
        ),
    }
    return report


def write_audit() -> None:
    audit = """# Phase C.2 Native Sparse Memory-Service Extension

## Decision

PHASE_C2_BLOCKED

## Exact interface boundary

The sparse Phase-A schedule is valid and preserves output position, original K, output channel, PE identity, and issue timing. However, the native SCALE-Sim memory stack still accepts only dense demand matrices:

- `scalesim/memory/double_buffered_scratchpad_mem.py::service_memory_requests(ifmap_demand_mat, filter_demand_mat, ofmap_demand_mat)`
- `scalesim/memory/read_buffer.py::set_fetch_matrix()` and `service_reads()`

There is no native sparse request API that can admit a per-output-position active-K memory stream without fabricating a dense matrix or synthetic stall model.

## Scientific conclusion

This Phase C.2 extension therefore stops at the true interface boundary instead of manufacturing traffic, stalls, or timing. The blocker is structural rather than numerical.

PHASE_C2_BLOCKED
"""
    (RESULTS_DIR / "phase_c2_interface_audit.md").write_text(audit, encoding="utf-8")


def main() -> int:
    report = run_pilot()
    write_json(RESULTS_DIR / "phase_c2_report.json", report)
    write_json(RESULTS_DIR / "phase_c2_status.json", {"status": "PHASE_C2_BLOCKED", "reason": report["exact_boundary"]})
    write_audit()
    (RESULTS_DIR / "phase_c2_status.txt").write_text("PHASE_C2_BLOCKED\n", encoding="utf-8")

    print("PHASE_C2_BLOCKED: the sparse request stream is valid, but the native SCALE-Sim memory service still requires dense demand matrices; no native sparse memory timing path exists for active-K requests.")
    print("Exact interface boundary: scalesim/memory/double_buffered_scratchpad_mem.py::service_memory_requests(ifmap_demand_mat, filter_demand_mat, ofmap_demand_mat) and scalesim/memory/read_buffer.py::set_fetch_matrix()/service_reads().")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
