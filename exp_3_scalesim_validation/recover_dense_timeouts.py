#!/usr/bin/env python3
"""Retry only the ten final-experiment dense runs that previously timed out."""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path
from typing import Any

import run_actual_final_scalesim as experiment

FINAL = experiment.FINAL
RESULTS_CSV = experiment.RESULTS_CSV
RECOVERY_CSV = FINAL / "dense_timeout_recovery.csv"
RECOVERY_TXT = FINAL / "dense_timeout_recovery.txt"
TIMEOUT = 1800

TARGETS = {
    ("resnet18_cifar10", "layer4.0.conv2"),
    ("resnet18_cifar10", "layer4.1.conv1"),
    ("resnet18_cifar10", "layer4.1.conv2"),
    ("resnet18_cifar100", "layer4.0.conv2"),
    ("resnet18_cifar100", "layer4.1.conv1"),
    ("resnet18_cifar100", "layer4.1.conv2"),
    ("vgg16_cifar10", "features.19"),
    ("vgg16_cifar10", "features.21"),
    ("vgg16_cifar100", "features.27"),
    ("vgg16_cifar100", "features.30"),
}

RECOVERY_FIELDS = [
    "workload", "layer", "dense_pe", "attempt", "status", "returncode",
    "host_seconds", "dense_cycles", "dense_compute_cycles", "dense_stall_cycles",
    "report_path", "error",
]


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_result_table(rows: list[dict[str, Any]]) -> None:
    with RESULTS_CSV.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=experiment.FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def write_recovery_table(rows: list[dict[str, Any]]) -> None:
    with RECOVERY_CSV.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=RECOVERY_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def tail(path: Path, limit: int = 20) -> str:
    try:
        return "\n".join(path.read_text(encoding="utf-8", errors="replace").splitlines()[-limit:])
    except OSError:
        return "(not available)"


def load_and_validate() -> tuple[list[dict[str, Any]], list[dict[str, str]], dict[tuple[str, str], int]]:
    expected_rows = experiment.load_expected()
    expected_by_key = {(row["workload"], row["layer"]): row for row in expected_rows}
    if len(expected_by_key) != 66:
        raise RuntimeError("preflight expected exactly 66 unique frozen workload/layer rows")

    results = read_csv(RESULTS_CSV)
    if len(results) != 66:
        raise RuntimeError(f"results CSV must have 66 rows, found {len(results)}")
    row_index: dict[tuple[str, str], int] = {}
    for index, row in enumerate(results):
        key = (row["workload"], row["layer"])
        if key in row_index:
            raise RuntimeError(f"duplicate results CSV row: {key}")
        row_index[key] = index
    if set(row_index) != set(expected_by_key):
        raise RuntimeError("results CSV workload/layer set differs from the frozen gate")

    not_success = {
        (row["workload"], row["layer"])
        for row in results
        if row["dense_status"] != "SUCCESS"
    }
    if not_success != TARGETS:
        raise RuntimeError(
            "dense non-success rows do not exactly match requested recovery set; "
            f"unexpected={sorted(not_success - TARGETS)}, missing={sorted(TARGETS - not_success)}"
        )

    for key in TARGETS:
        result = results[row_index[key]]
        expected = expected_by_key[key]
        if result["dense_status"] != "TIMEOUT":
            raise RuntimeError(f"target dense row is not TIMEOUT: {key}={result['dense_status']}")
        if result["sparse_status"] != "SUCCESS":
            raise RuntimeError(f"target sparse result is not SUCCESS: {key}")
        sparse_valid, _ = experiment.validate_existing_run(result, expected, sparse=True)
        if not sparse_valid:
            raise RuntimeError(f"target sparse report failed validation; refusing to alter or rerun it: {key}")
        if int(result["dense_pe"]) != 64 or int(result["selected_pe"]) != expected["selected_pe"]:
            raise RuntimeError(f"dense PE or frozen selected-PE metadata mismatch: {key}")
    return expected_rows, results, row_index


def make_recovery_row(result: dict[str, Any], expected: dict[str, Any]) -> dict[str, Any]:
    parsed = result["parsed"] or {}
    run_dir = Path(result["run_dir"])
    try:
        attempt = run_dir.name
    except OSError:
        attempt = ""
    return {
        "workload": expected["workload"], "layer": expected["layer"], "dense_pe": 64,
        "attempt": attempt, "status": result["status"],
        "returncode": result["returncode"], "host_seconds": f"{result['host_seconds']:.6f}",
        "dense_cycles": parsed.get("cycles", ""),
        "dense_compute_cycles": parsed.get("compute_cycles", ""),
        "dense_stall_cycles": parsed.get("stall_cycles", ""),
        "report_path": result["report_path"], "error": result["error"],
    }


def write_report(recovery_rows: list[dict[str, Any]], result_rows: list[dict[str, Any]]) -> bool:
    counts = {status: sum(row["status"] == status for row in recovery_rows) for status in ("SUCCESS", "TIMEOUT", "FAILED")}
    dense_counts = {status: sum(row["dense_status"] == status for row in result_rows) for status in ("SUCCESS", "TIMEOUT", "FAILED")}
    sparse_counts = {status: sum(row["sparse_status"] == status for row in result_rows) for status in ("SUCCESS", "TIMEOUT", "FAILED")}
    complete = (
        len(recovery_rows) == 10 and counts["SUCCESS"] == 10
        and dense_counts == {"SUCCESS": 66, "TIMEOUT": 0, "FAILED": 0}
        and sparse_counts == {"SUCCESS": 66, "TIMEOUT": 0, "FAILED": 0}
    )
    lines = [
        "Dense timeout recovery",
        "======================",
        "target dense reruns: 10", f"attempted recovery rows: {len(recovery_rows)}",
        f"recovery successes: {counts['SUCCESS']}", f"recovery timeouts: {counts['TIMEOUT']}",
        f"recovery failures: {counts['FAILED']}",
        f"final successful dense: {dense_counts['SUCCESS']}/66",
        f"final dense timeouts: {dense_counts['TIMEOUT']}/66",
        f"final dense failures: {dense_counts['FAILED']}/66",
        f"final successful sparse: {sparse_counts['SUCCESS']}/66",
        f"final sparse timeouts: {sparse_counts['TIMEOUT']}/66",
        f"final sparse failures: {sparse_counts['FAILED']}/66",
        "all dense reruns use native SCALE-Sim, 64 PE, sparsity disabled, and no activation mask",
        "successful sparse rows were validated before execution and were not modified or rerun",
        "host wall time is separate from simulated cycles",
        "",
    ]
    for recovery in recovery_rows:
        lines.extend([
            f"{recovery['workload']}/{recovery['layer']}: status={recovery['status']}, "
            f"attempt={recovery['attempt']}, returncode={recovery['returncode']}, "
            f"host_seconds={recovery['host_seconds']}, dense_cycles={recovery['dense_cycles'] or 'NA'}",
            f"report: {recovery['report_path']}",
            f"error: {recovery['error'] or 'none'}",
        ])
        run_dir = FINAL / "scalesim_runs" / recovery["workload"] / recovery["layer"] / "dense_64pe" / recovery["attempt"]
        lines.extend(["stdout tail:", tail(run_dir / "stdout.log"), "stderr tail:", tail(run_dir / "stderr.log"), ""])
    RECOVERY_TXT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return complete


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preflight-only", action="store_true")
    args = parser.parse_args()
    FINAL.mkdir(parents=True, exist_ok=True)
    try:
        expected_rows, result_rows, row_index = load_and_validate()
        expected_by_key = {(row["workload"], row["layer"]): row for row in expected_rows}
        ordered_targets = [
            (row["workload"], row["layer"])
            for row in result_rows
            if (row["workload"], row["layer"]) in TARGETS
        ]
        if args.preflight_only:
            for key in ordered_targets:
                old = result_rows[row_index[key]]
                next_attempt = experiment.next_attempt(
                    experiment.RUNS / key[0] / key[1] / "dense_64pe"
                )
                print(f"READY {key[0]}/{key[1]} dense_pe=64 next_attempt={next_attempt.name} sparse=VALIDATED_NOT_RERUN")
            print("PREFLIGHT_PASS")
            return 0

        version = experiment.simulator_version()
        recovery_rows: list[dict[str, Any]] = []
        for key in ordered_targets:
            expected = expected_by_key[key]
            row = result_rows[row_index[key]]
            print(f"DENSE_RECOVERY {key[0]}/{key[1]} PE=64 timeout={TIMEOUT}s", flush=True)
            run = experiment.execute_run(expected, sparse=False, timeout=TIMEOUT, version=version)
            recovery = make_recovery_row(run, expected)
            recovery_rows.append(recovery)

            row["dense_status"] = run["status"]
            row["dense_returncode"] = run["returncode"]
            row["dense_host_seconds"] = recovery["host_seconds"]
            row["dense_report_path"] = run["report_path"]
            row["dense_run_dir"] = run["run_dir"]
            row["dense_resumed"] = 0
            row["dense_error"] = run["error"]
            if run["parsed"] is not None:
                row["dense_cycles"] = run["parsed"]["cycles"]
                row["dense_cycles_per_sample"] = run["parsed"]["cycles_per_sample"]
                row["dense_compute_cycles"] = run["parsed"].get("compute_cycles", "")
                row["dense_stall_cycles"] = run["parsed"].get("stall_cycles", "")
                sparse_cycles = experiment.numeric(row["sparse_cycles"])
                dense_cycles = experiment.numeric(row["dense_cycles"])
                row["cycle_reduction_pct"] = (
                    f"{100.0 * (dense_cycles - sparse_cycles) / dense_cycles:.8f}"
                    if dense_cycles else ""
                )
            else:
                row["dense_cycles"] = ""
                row["dense_cycles_per_sample"] = ""
                row["dense_compute_cycles"] = ""
                row["dense_stall_cycles"] = ""
                row["cycle_reduction_pct"] = ""

            write_result_table(result_rows)
            write_recovery_table(recovery_rows)
            write_report(recovery_rows, result_rows)
            print(
                f"{run['status']} {key[0]}/{key[1]} attempt={recovery['attempt']} "
                f"host_seconds={recovery['host_seconds']} returncode={recovery['returncode']}",
                flush=True,
            )

        complete = write_report(recovery_rows, result_rows)
        recovery_counts = {status: sum(row["status"] == status for row in recovery_rows) for status in ("SUCCESS", "TIMEOUT", "FAILED")}
        print(f"recovery_rows={len(recovery_rows)} recovery_counts={recovery_counts}")
        print("DENSE_TIMEOUT_RECOVERY_COMPLETE" if complete else "DENSE_TIMEOUT_RECOVERY_PARTIAL")
        return 0 if complete else 1
    except Exception as exc:
        print(f"DENSE_TIMEOUT_RECOVERY_BLOCKED: {exc}", file=sys.stderr)
        print("DENSE_TIMEOUT_RECOVERY_PARTIAL")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())