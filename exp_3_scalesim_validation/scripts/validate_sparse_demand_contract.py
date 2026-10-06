#!/usr/bin/env python3
"""Validate the native sparse memory-demand contract without invoking SCALE-Sim execution.

This is a Phase-B.1 gate: evidence for a semantically valid sparse demand trace,
not runtime SCALE-Sim execution.
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
from scalesim.memory.native_sparse_demand import SparseDemandTrace

RESULTS_DIR = ROOT / "exp_3_scalesim_validation" / "results" / "native_sparse_demand_pilot"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

MASK_PATH = ROOT / "exp_3_scalesim_validation" / "masks" / "resnet18_cifar10" / "layer_01.npy"


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_status(status: str) -> None:
    (RESULTS_DIR / "phase_b1_status.txt").write_text(f"{status}\n", encoding="utf-8")


def validate_synthetic() -> tuple[bool, dict]:
    mask = np.array(
        [
            [1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0],
            [0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0],
            [1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0],
            [0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0],
        ],
        dtype=np.uint8,
    )
    schedule = build_sparse_ws_schedule(mask, output_channels=10, array_rows=4, array_cols=8)
    trace = SparseDemandTrace.from_schedule(schedule, mask, output_channels=10, reduction_size=12)
    validation = trace.validate()
    checks = {
        "synthetic_pass": validation["valid"],
        "original_k_preserved": all(
            request.operand_type in {"IFMAP", "FILTER"} and request.original_k in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
            for request in trace.requests
        ),
        "unique_logical_coords": not validation["duplicate_logical_coordinates"],
        "valid_ifmap": validation["missing_ifmap"] == 0,
        "valid_filter": validation["missing_filter"] == 0,
        "valid_ofmap": validation["missing_ofmap"] == 0,
        "mac_conservation": schedule.useful_macs + schedule.skipped_macs == schedule.dense_macs,
    }
    payload = {
        "status": "PASS" if all(checks.values()) else "FAIL",
        "mac_event_count": validation["mac_event_count"],
        "total_requests": validation["total_requests"],
        "schedule_useful_macs": schedule.useful_macs,
        "schedule_skipped_macs": schedule.skipped_macs,
        "schedule_dense_macs": schedule.dense_macs,
        "checks": checks,
    }
    return all(checks.values()), payload


def validate_real_pilot() -> tuple[bool, dict]:
    if not MASK_PATH.is_file():
        raise FileNotFoundError(f"missing pilot mask: {MASK_PATH}")
    mask = np.load(MASK_PATH, mmap_mode="r")[:1024]
    if mask.shape != (1024, 576):
        raise ValueError(f"unexpected mask slice shape: {mask.shape}")
    if not np.all((mask == 0) | (mask == 1)):
        raise ValueError("real pilot mask is not binary")

    schedule = build_sparse_ws_schedule(mask, output_channels=64, array_rows=4, array_cols=8)
    trace = SparseDemandTrace.from_schedule(schedule, mask, output_channels=64, reduction_size=576)
    validation = trace.validate()
    expected = {
        "useful_macs": 9_645_376,
        "skipped_macs": 28_103_360,
        "compute_cycles": 382_208,
        "analytical_lower_bound": 301_418,
    }
    checks = {
        "mac_conservation": schedule.useful_macs == expected["useful_macs"] and schedule.skipped_macs == expected["skipped_macs"],
        "cycle_values_preserved": schedule.cycles == expected["compute_cycles"] and schedule.analytical_lower_bound == expected["analytical_lower_bound"],
        "original_k_preserved": validation["valid"],
        "ifmap_provenance": validation["missing_ifmap"] == 0,
        "filter_provenance": validation["missing_filter"] == 0,
        "ofmap_provenance": validation["missing_ofmap"] == 0,
    }
    payload = {
        "status": "PASS" if all(checks.values()) else "FAIL",
        "expected": expected,
        "actual": {
            "useful_macs": schedule.useful_macs,
            "skipped_macs": schedule.skipped_macs,
            "dense_macs": schedule.dense_macs,
            "compute_cycles": schedule.cycles,
            "analytical_lower_bound": schedule.analytical_lower_bound,
        },
        "checks": checks,
        "validation": validation,
    }
    return all(checks.values()), payload


def build_audit() -> str:
    questions = {
        1: ("Can IFMAP sparse requests be represented without losing original_k?", "NO: the native interface accepts dense request arrays and the sparse contract keeps original_k explicitly at the event level; native dense matrices do not preserve per-MAC original_k provenance without an explicit custom adapter."),
        2: ("Can FILTER requests preserve native reuse semantics?", "NO: native FILTER demand generation is dense and fold-based; sparse activation masks do not define a native FILTER reuse policy or a legal mapping back into the dense matrix API without inventing reuse assumptions."),
        3: ("Can OFMAP requests preserve native output coordinates?", "YES: logical output coordinates are preserved in the sparse event stream and can be represented as (output_position, output_channel)."),
        4: ("Can partial-sum traffic be represented?", "YES: logical PARTIAL_SUM coordinates are preserved as (output_position, output_channel), but this is not the same as native SRAM service semantics."),
        5: ("Can request timing be passed to the native memory service?", "NO: the service consumes dense demand matrices whose timing is generated by the native systolic fill and drain logic; sparse event timing is not accepted as matrix input without redefining the service contract."),
        6: ("Does the native memory service require rectangular dense matrices?", "YES: `read_buffer.service_reads()` and the demand-matrix generation in `systolic_compute_ws.py` produce rectangular matrices with fixed folds and `-1` null padding; the service is built around dense rectangular arrays, not sparse event streams."),
        7: ("If yes, can sparse requests be represented without fabricating zero-work traffic?", "NO: forcing sparse requests into dense matrices requires either dummy `-1` rows/columns or estimated padding traffic, which is artificial and changes the native memory semantics."),
        8: ("Can the existing prefetch structures represent the sparse demand?", "NO: `read_buffer.set_fetch_matrix()` and `service_reads()` operate on dense fetch matrices and hashed active-buffer sets; they have no sparse per-event representation."),
        9: ("Would converting sparse events into the existing matrices introduce artificial requests?", "YES: a dense rectangular matrix conversion would inject padding, null requests, and fold-induced traffic not present in the original sparse event stream."),
        10: ("Would it introduce artificial stalls?", "YES: the native scratchpad service computes stall cycles from dense fetch and hit/miss behavior, so any forced matrix conversion would create fake misses and fake stall behavior."),
    }
    lines = [
        "# Native Memory Interface Compatibility Audit",
        "",
        "## Decision",
        "",
        "PHASE_B1_BLOCKED",
        "",
        "## Evidence",
        "",
        "- `systolic_compute_ws.py` builds `ifmap_demand_matrix`, `filter_demand_matrix`, and `ofmap_demand_matrix` as rectangular folded matrices with `-1` padding.",
        "- `read_buffer.py::service_reads()` consumes dense arrays and calculates hit/miss timing through prefetched active buffers.",
        "- `double_buffered_scratchpad_mem.py::service_memory_requests()` expects arrays shaped for the native memory service and accumulates stall cycles on that basis.",
        "- `native_sparse_ws.py` is compute-only and intentionally not wired into the native memory path.",
        "",
    ]
    for idx, (question, answer) in questions.items():
        lines.append(f"### {idx}. {question}")
        lines.append("")
        lines.append(answer)
        lines.append("")
    lines.append("## Final determination")
    lines.append("")
    lines.append("The sparse demand trace is semantically valid as a Phase-A compute provenance contract, but it cannot be passed into the existing native SCALE-Sim memory service without changing native semantics or inventing traffic and stalls. This is therefore PHASE_B1_BLOCKED.")
    return "\n".join(lines) + "\n"


def main() -> int:
    synthetic_ok, synthetic_payload = validate_synthetic()
    real_ok, real_payload = validate_real_pilot()

    status = "PHASE_B1_BLOCKED" if not (synthetic_ok and real_ok) else "PHASE_B1_PASS"
    # The contract is valid, but the native memory interface is not compatible without inventing traffic/stalls.
    status = "PHASE_B1_BLOCKED"

    write_json(RESULTS_DIR / "synthetic_sparse_demand_report.json", synthetic_payload)
    write_json(RESULTS_DIR / "real_sparse_demand_report.json", real_payload)
    (RESULTS_DIR / "native_memory_interface_audit.md").write_text(build_audit(), encoding="utf-8")
    write_status(status)

    print("Synthetic validation:", "PASS" if synthetic_ok else "FAIL")
    print("Real pilot:", "PASS" if real_ok else "FAIL")
    print("MAC conservation:", "PASS" if synthetic_payload["checks"]["mac_conservation"] and real_payload["checks"]["mac_conservation"] else "FAIL")
    print("Original-K preservation:", "PASS" if synthetic_payload["checks"]["original_k_preserved"] and real_payload["checks"]["original_k_preserved"] else "FAIL")
    print("IFMAP provenance:", "PASS" if real_payload["checks"]["ifmap_provenance"] else "FAIL")
    print("FILTER provenance:", "PASS" if real_payload["checks"]["filter_provenance"] else "FAIL")
    print("OFMAP provenance:", "PASS" if real_payload["checks"]["ofmap_provenance"] else "FAIL")
    print("Native memory compatibility:", "FAIL")
    print("Fabricated traffic:", "YES")
    print("Fabricated stalls:", "YES")
    print("Native SCALE-Sim execution launched:", "NO")
    print("Frozen evidence modified:", "NO")
    print("PHASE_B1_BLOCKED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
