#!/usr/bin/env python3
"""Execute and validate the final per-layer dense and activation-sparse runs."""
from __future__ import annotations

import argparse
import configparser
import csv
import json
import math
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
EXP3 = Path(__file__).resolve().parent
SCALESIM_ROOT = ROOT / "SCALE-Sim-v3-energy"
SCALESIM_CLI = SCALESIM_ROOT / "scalesim" / "scale.py"
PYTHON = Path("/home/cs25m115/anaconda3/envs/neural_acc/bin/python")
FINAL = EXP3 / "results" / "final_experiment"
RUNS = FINAL / "scalesim_runs"
GATE_CSV = FINAL / "final_pre_scalesim_gate.csv"
MASK_MANIFEST = FINAL / "mask_generation_manifest.csv"
PE_AUDIT = FINAL / "stage13_1_single_pass_pe_audit.csv"
RESULTS_CSV = FINAL / "final_scalesim_results.csv"
REPORT_TXT = FINAL / "final_scalesim_report.txt"
VALIDATION_TXT = FINAL / "final_scalesim_validation.txt"
DEFAULT_TIMEOUT = 900

FIELDS = [
    "workload", "layer", "layer_index", "selected_pe", "dense_pe", "sample_count",
    "dense_macs", "sparse_useful_macs", "skipped_macs", "dense_cycles",
    "sparse_cycles", "cycle_reduction_pct", "dense_compute_cycles",
    "sparse_compute_cycles", "dense_stall_cycles", "sparse_stall_cycles",
    "dense_host_seconds", "sparse_host_seconds", "dense_status", "sparse_status",
    "dense_returncode", "sparse_returncode", "activation_mask", "scale_sim_version",
    "dense_report_path", "sparse_report_path", "dense_run_dir", "sparse_run_dir",
    "dense_resumed", "sparse_resumed", "dense_cycles_per_sample",
    "dense_error", "sparse_error",
]

LAYOUT_HEADER = (
    "Layer name, IFMAP Height Intraline Factor, IFMAP Width Intraline Factor, "
    "Filter Height Intraline Factor, Filter Width Intraline Factor, "
    "Channel Intraline Factor, Num Filter Intraline Factor, IFMAP Height Intraline Order, "
    "IFMAP Width Intraline Order, Channel Intraline Order, IFMAP Height Interline Order, "
    "IFMAP Width Interline Order, Channel Interline Order, Num Filter Intraline Order, "
    "Channel Interline Order, Filter Height Interline Order, Filter Width Interline Order, "
    "Num Filter Interline Order, Channel Interline Order, Filter Height Interline Order, "
    "Filter Width Interline Order,\n"
)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, values: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(values)


def numeric(value: Any) -> int:
    number = float(value)
    if not math.isfinite(number) or number < 0 or not number.is_integer():
        raise ValueError(f"expected a non-negative integer, got {value!r}")
    return int(number)


def load_expected() -> list[dict[str, Any]]:
    gate_rows = read_csv(GATE_CSV)
    mask_rows = read_csv(MASK_MANIFEST)
    audit_rows = read_csv(PE_AUDIT)
    if len(gate_rows) != 66 or len(mask_rows) != 66 or len(audit_rows) != 66:
        raise RuntimeError("preflight requires 66 gate, mask-manifest, and PE-audit rows")

    masks = {(row["workload"], row["layer_name"]): row for row in mask_rows}
    audits = {
        (f"{row['model']}_{row['dataset']}", row["layer"]): row
        for row in audit_rows
    }
    expected: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for gate in gate_rows:
        key = (gate["workload"], gate["layer"])
        if key in seen:
            raise RuntimeError(f"duplicate pre-gate workload/layer row: {key}")
        seen.add(key)
        manifest = masks.get(key)
        audit = audits.get(key)
        if manifest is None or audit is None:
            raise RuntimeError(f"missing frozen metadata for {key}")
        index = int(manifest["layer_index"])
        if gate["overall_pass"] != "PASS" or manifest["validation_status"] != "PASS":
            raise RuntimeError(f"pre-SCALE-Sim gate is not PASS for {key}")
        selected_pe = int(gate["selected_pe"])
        if selected_pe != int(gate["frozen_selected_pe"]) or selected_pe != int(audit["frozen_selected_pe"]):
            raise RuntimeError(f"selected PE differs from frozen Stage 13.1 audit for {key}")
        if audit["same_pe"] != "PASS" or gate["mask_binary"] != "PASS" or gate["mask_shape_valid"] != "PASS":
            raise RuntimeError(f"PE or mask audit failed for {key}")
        if manifest["layer_name"] != gate["layer"]:
            raise RuntimeError(f"mask manifest layer mismatch for {key}")
        mask_path = Path(manifest["mask_path"])
        if not mask_path.is_file():
            raise RuntimeError(f"validated activation mask is missing: {mask_path}")
        expected.append({
            "workload": gate["workload"],
            "layer": gate["layer"],
            "layer_index": index,
            "selected_pe": selected_pe,
            "sample_count": int(manifest["sample_count"]),
            "dense_macs": int(gate["dense_macs"]),
            "useful_macs": int(gate["verified_single_pass_useful_macs"]),
            "skipped_macs": int(gate["skipped_macs"]),
            "activation_mask": str(mask_path),
            "input_shape": json.loads(manifest["input_shape"]),
            "output_shape": json.loads(manifest["output_shape"]),
            "kernel_size": json.loads(manifest["kernel_size"]),
            "stride": json.loads(manifest["stride"]),
            "padding": json.loads(manifest["padding"]),
            "mask_shape": json.loads(manifest["mask_shape"]),
        })
    if len(seen) != 66:
        raise RuntimeError(f"preflight found {len(seen)} unique gate rows, expected 66")
    return expected


def simulator_version() -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(SCALESIM_ROOT), "rev-parse", "--short", "HEAD"],
            check=True, capture_output=True, text=True,
        )
        return f"SCALE-Sim-v3-energy@{result.stdout.strip()}"
    except (OSError, subprocess.CalledProcessError):
        return "SCALE-Sim-v3-energy@unknown"


def load_old_results() -> dict[tuple[str, str], dict[str, str]]:
    if not RESULTS_CSV.is_file():
        return {}
    result: dict[tuple[str, str], dict[str, str]] = {}
    for row in read_csv(RESULTS_CSV):
        key = (row["workload"], row["layer"])
        if key in result:
            raise RuntimeError(f"duplicate row in existing results CSV: {key}")
        result[key] = row
    return result


def parse_config_pe(path: Path) -> int:
    parser = configparser.ConfigParser(delimiters=("=", ":"), inline_comment_prefixes=None)
    parser.optionxform = str
    with path.open(encoding="utf-8") as handle:
        parser.read_file(handle)
    height = int(parser["architecture_presets"]["ArrayHeight"])
    width = int(parser["architecture_presets"]["ArrayWidth"])
    return height * width


def read_single_report_row(path: Path) -> dict[str, str]:
    with path.open(newline="", encoding="utf-8") as handle:
        records = [
            {key.strip(): (value or "").strip() for key, value in row.items() if key and key.strip()}
            for row in csv.DictReader(handle)
        ]
    records = [row for row in records if any(value for value in row.values())]
    if len(records) != 1:
        raise ValueError(f"expected exactly one report record in {path}, found {len(records)}")
    return records[0]


def dense_report(path: Path, sample_count: int) -> dict[str, int]:
    row = read_single_report_row(path)
    result = {"cycles": numeric(row["Total Cycles (incl. prefetch)"]) * sample_count}
    result["cycles_per_sample"] = numeric(row["Total Cycles (incl. prefetch)"])
    for output_key, report_key in (("compute_cycles", "Total Cycles"), ("stall_cycles", "Stall Cycles")):
        if report_key in row and row[report_key] != "":
            result[output_key] = numeric(row[report_key]) * sample_count
    return result


def sparse_report(path: Path) -> dict[str, int]:
    row = read_single_report_row(path)
    return {
        "dense_macs": numeric(row["Dense MACs"]),
        "useful_macs": numeric(row["Useful MACs"]),
        "skipped_macs": numeric(row["Skipped MACs"]),
        "cycles": numeric(row["Sparse Cycles"]),
        "pe_count": numeric(row["PE Count"]),
        "rows": numeric(row["Rows"]),
        "k": numeric(row["K"]),
    }


def spec_matches(run_dir: Path, expected: dict[str, Any], mode: str, pe: int) -> bool:
    spec_path = run_dir / "run_spec.json"
    config_path = run_dir / "scale.cfg"
    if not spec_path.is_file() or not config_path.is_file():
        return False
    try:
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
        effective_ifmap = [
            expected["input_shape"][-2] + 2 * expected["padding"][0],
            expected["input_shape"][-1] + 2 * expected["padding"][1],
        ]
        if (spec.get("workload") != expected["workload"]
                or spec.get("layer") != expected["layer"]
                or int(spec.get("layer_index", -1)) != expected["layer_index"]
                or int(spec.get("pe", -1)) != pe
                or spec.get("mode") != mode
                or spec.get("activation_mask") != expected["activation_mask"]
                or int(spec.get("sample_count", -1)) != expected["sample_count"]
                or spec.get("topology_ifmap") != effective_ifmap):
            return False
        topology = read_single_report_row(run_dir / "topology.csv")
        if (int(topology["IFMAP Height"]) != effective_ifmap[0]
                or int(topology["IFMAP Width"]) != effective_ifmap[1]):
            return False
        return parse_config_pe(config_path) == pe
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return False


def validate_existing_run(
    row: dict[str, str], expected: dict[str, Any], sparse: bool,
) -> tuple[bool, dict[str, int] | None]:
    prefix = "sparse" if sparse else "dense"
    if row.get(f"{prefix}_status") != "SUCCESS" or row.get(f"{prefix}_returncode") != "0":
        return False, None
    run_dir = Path(row.get(f"{prefix}_run_dir", ""))
    report_path = Path(row.get(f"{prefix}_report_path", ""))
    pe = expected["selected_pe"] if sparse else 64
    mode = "sparse_adaptive_pe" if sparse else "dense_64pe"
    if not spec_matches(run_dir, expected, mode, pe) or not report_path.is_file():
        return False, None
    try:
        if sparse:
            parsed = sparse_report(report_path)
            if (parsed["useful_macs"] != expected["useful_macs"]
                    or parsed["skipped_macs"] != expected["dense_macs"] - expected["useful_macs"]
                    or parsed["dense_macs"] != expected["dense_macs"]
                    or parsed["pe_count"] != expected["selected_pe"]
                    or parsed["rows"] != expected["mask_shape"][0]
                    or parsed["k"] != expected["mask_shape"][1]):
                return False, None
            return True, parsed
        if parse_config_pe(run_dir / "scale.cfg") != 64:
            return False, None
        return True, dense_report(report_path, expected["sample_count"])
    except (OSError, ValueError, KeyError, StopIteration):
        return False, None


def next_attempt(category: Path) -> Path:
    category.mkdir(parents=True, exist_ok=True)
    index = 1
    while (category / f"attempt_{index:03d}").exists():
        index += 1
    return category / f"attempt_{index:03d}"


def write_run_inputs(
    run_dir: Path, expected: dict[str, Any], mode: str, pe: int, version: str,
) -> tuple[Path, Path, Path, str]:
    run_dir.mkdir(parents=True, exist_ok=False)
    mode_name = "sparse" if mode == "sparse_adaptive_pe" else "dense"
    run_name = f"{expected['workload']}_layer_{expected['layer_index']:02d}_{mode_name}_{pe}pe"
    config = configparser.ConfigParser(delimiters=("=", ":"), inline_comment_prefixes=None)
    config.optionxform = str
    with (SCALESIM_ROOT / "configs" / "scale.cfg").open(encoding="utf-8") as handle:
        config.read_file(handle)
    height, width = {16: (4, 4), 32: (4, 8), 64: (8, 8)}[pe]
    config["general"]["run_name"] = run_name
    config["architecture_presets"]["ArrayHeight"] = str(height)
    config["architecture_presets"]["ArrayWidth"] = str(width)
    config["sparsity"]["SparsitySupport"] = "false"
    config_path = run_dir / "scale.cfg"
    with config_path.open("w", encoding="utf-8") as handle:
        config.write(handle)

    topology_path = run_dir / "topology.csv"
    layout_path = run_dir / "layout.csv"
    input_shape = expected["input_shape"]
    output_shape = expected["output_shape"]
    kernel = expected["kernel_size"]
    stride = expected["stride"]
    padding = expected["padding"]
    effective_ifmap = [
        input_shape[-2] + 2 * padding[0],
        input_shape[-1] + 2 * padding[1],
    ]
    topology_path.write_text(
        "Layer name, IFMAP Height, IFMAP Width, Filter Height, Filter Width, Channels, Num Filter, Strides,\n"
        f"{run_name}, {effective_ifmap[0]}, {effective_ifmap[1]}, {kernel[0]}, {kernel[1]}, "
        f"{input_shape[1]}, {output_shape[1]}, {stride[0]},\n",
        encoding="utf-8",
    )
    layout_path.write_text(
        LAYOUT_HEADER + f"{run_name}, 1, 1, 1, 1, 1, 1, 0, 1, 2, 4, 5, 3, 3, 2, 1, 0, 4, 5, 6, 7,\n",
        encoding="utf-8",
    )
    spec = {
        "workload": expected["workload"], "layer": expected["layer"],
        "layer_index": expected["layer_index"], "mode": mode, "pe": pe,
        "array_geometry": [height, width], "sample_count": expected["sample_count"],
        "dense_macs": expected["dense_macs"], "useful_macs": expected["useful_macs"],
        "skipped_macs": expected["skipped_macs"], "activation_mask": expected["activation_mask"],
        "mask_shape": expected["mask_shape"], "topology_ifmap": effective_ifmap,
        "scale_sim_version": version,
    }
    (run_dir / "run_spec.json").write_text(json.dumps(spec, indent=2) + "\n", encoding="utf-8")
    return config_path, topology_path, layout_path, run_name


def execute_run(
    expected: dict[str, Any], sparse: bool, timeout: int, version: str,
) -> dict[str, Any]:
    mode = "sparse_adaptive_pe" if sparse else "dense_64pe"
    pe = expected["selected_pe"] if sparse else 64
    workload_dir = RUNS / expected["workload"] / expected["layer"]
    run_dir = next_attempt(workload_dir / mode)
    config, topology, layout, run_name = write_run_inputs(run_dir, expected, mode, pe, version)
    output_dir = run_dir / "simulator_output"
    report_path = output_dir / run_name / (
        "ACTIVATION_SPARSE_REPORT.csv" if sparse else "COMPUTE_REPORT.csv"
    )
    command = [
        str(PYTHON), str(SCALESIM_CLI), "-c", str(config), "-t", str(topology),
        "-l", str(layout), "-p", str(output_dir), "-i", "conv", "-s", "N",
    ]
    if sparse:
        command.extend(["-a", expected["activation_mask"]])
    (run_dir / "command.json").write_text(json.dumps(command, indent=2) + "\n", encoding="utf-8")
    started = time.perf_counter()
    try:
        completed = subprocess.run(
            command, cwd=SCALESIM_ROOT, capture_output=True, text=True, timeout=timeout,
        )
        elapsed = time.perf_counter() - started
        stdout, stderr = completed.stdout or "", completed.stderr or ""
        returncode: int | str = completed.returncode
        if completed.returncode != 0:
            status = "FAILED"
            parsed = None
            error = (stderr or stdout)[-2000:]
        else:
            try:
                if sparse:
                    parsed = sparse_report(report_path)
                    if (parsed["dense_macs"] != expected["dense_macs"]
                            or parsed["useful_macs"] != expected["useful_macs"]
                            or parsed["skipped_macs"] != expected["dense_macs"] - expected["useful_macs"]
                            or parsed["pe_count"] != expected["selected_pe"]
                            or parsed["rows"] != expected["mask_shape"][0]
                            or parsed["k"] != expected["mask_shape"][1]):
                        raise ValueError("activation-sparse report does not match validated mask/PE references")
                    status = "SUCCESS"
                else:
                    if parse_config_pe(config) != 64:
                        raise ValueError("dense config is not a 64-PE array")
                    parsed = dense_report(report_path, expected["sample_count"])
                    status = "SUCCESS"
                error = ""
            except (OSError, ValueError, KeyError, StopIteration) as exc:
                status = "FAILED"
                parsed = None
                error = f"report validation failed: {exc}; stderr/stdout tail: {(stderr or stdout)[-1500:]}"
    except subprocess.TimeoutExpired as exc:
        elapsed = time.perf_counter() - started
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        returncode = ""
        status = "TIMEOUT"
        parsed = None
        error = f"host timeout after {elapsed:.3f}s; stdout tail: {stdout[-1000:]}; stderr tail: {stderr[-1000:]}"
    except OSError as exc:
        elapsed = time.perf_counter() - started
        stdout, stderr = "", str(exc)
        returncode = ""
        status = "FAILED"
        parsed = None
        error = str(exc)

    (run_dir / "stdout.log").write_text(stdout, encoding="utf-8")
    (run_dir / "stderr.log").write_text(stderr, encoding="utf-8")
    return {
        "status": status, "returncode": returncode, "host_seconds": elapsed,
        "report_path": str(report_path), "run_dir": str(run_dir),
        "parsed": parsed, "error": error,
    }


def empty_result(expected: dict[str, Any], version: str) -> dict[str, Any]:
    return {
        "workload": expected["workload"], "layer": expected["layer"],
        "layer_index": expected["layer_index"], "selected_pe": expected["selected_pe"],
        "dense_pe": 64, "sample_count": expected["sample_count"],
        "dense_macs": expected["dense_macs"], "sparse_useful_macs": expected["useful_macs"],
        "skipped_macs": expected["skipped_macs"], "dense_cycles": "", "sparse_cycles": "",
        "cycle_reduction_pct": "", "dense_compute_cycles": "", "sparse_compute_cycles": "",
        "dense_stall_cycles": "", "sparse_stall_cycles": "", "dense_host_seconds": "",
        "sparse_host_seconds": "", "dense_status": "PENDING", "sparse_status": "PENDING",
        "dense_returncode": "", "sparse_returncode": "",
        "activation_mask": expected["activation_mask"], "scale_sim_version": version,
        "dense_report_path": "", "sparse_report_path": "", "dense_run_dir": "",
        "sparse_run_dir": "", "dense_resumed": 0, "sparse_resumed": 0,
        "dense_cycles_per_sample": "", "dense_error": "", "sparse_error": "",
    }


def normalized_old_row(expected: dict[str, Any], old: dict[str, str] | None, version: str) -> dict[str, Any]:
    result = empty_result(expected, version)
    if old:
        for field in FIELDS:
            if field in old and old[field] != "":
                result[field] = old[field]
    result.update({
        "workload": expected["workload"], "layer": expected["layer"],
        "layer_index": expected["layer_index"], "selected_pe": expected["selected_pe"],
        "dense_pe": 64, "sample_count": expected["sample_count"],
        "dense_macs": expected["dense_macs"], "sparse_useful_macs": expected["useful_macs"],
        "skipped_macs": expected["skipped_macs"], "activation_mask": expected["activation_mask"],
        "scale_sim_version": version,
    })
    return result


def use_or_execute(
    result_row: dict[str, Any], expected: dict[str, Any], old: dict[str, str] | None,
    sparse: bool, timeout: int, version: str,
) -> dict[str, Any]:
    prefix = "sparse" if sparse else "dense"
    if old:
        valid, parsed = validate_existing_run(old, expected, sparse)
        if valid and parsed is not None:
            result_row[f"{prefix}_status"] = "SUCCESS"
            result_row[f"{prefix}_returncode"] = 0
            result_row[f"{prefix}_report_path"] = old[f"{prefix}_report_path"]
            result_row[f"{prefix}_run_dir"] = old[f"{prefix}_run_dir"]
            result_row[f"{prefix}_host_seconds"] = old.get(f"{prefix}_host_seconds", "")
            result_row[f"{prefix}_resumed"] = 1
            if sparse:
                result_row["sparse_cycles"] = parsed["cycles"]
            else:
                result_row["dense_cycles"] = parsed["cycles"]
                result_row["dense_cycles_per_sample"] = parsed["cycles_per_sample"]
                result_row["dense_compute_cycles"] = parsed.get("compute_cycles", "")
                result_row["dense_stall_cycles"] = parsed.get("stall_cycles", "")
            print(f"RESUME {expected['workload']}/{expected['layer']} {prefix}")
            return {"status": "SUCCESS", "parsed": parsed}

    run = execute_run(expected, sparse, timeout, version)
    result_row[f"{prefix}_status"] = run["status"]
    result_row[f"{prefix}_returncode"] = run["returncode"]
    result_row[f"{prefix}_host_seconds"] = f"{run['host_seconds']:.6f}"
    result_row[f"{prefix}_report_path"] = run["report_path"]
    result_row[f"{prefix}_run_dir"] = run["run_dir"]
    result_row[f"{prefix}_error"] = run["error"]
    result_row[f"{prefix}_resumed"] = 0
    parsed = run["parsed"]
    if parsed is not None:
        if sparse:
            result_row["sparse_cycles"] = parsed["cycles"]
        else:
            result_row["dense_cycles"] = parsed["cycles"]
            result_row["dense_cycles_per_sample"] = parsed["cycles_per_sample"]
            result_row["dense_compute_cycles"] = parsed.get("compute_cycles", "")
            result_row["dense_stall_cycles"] = parsed.get("stall_cycles", "")
    print(
        f"{run['status']} {expected['workload']}/{expected['layer']} {prefix} "
        f"host_seconds={run['host_seconds']:.3f} returncode={run['returncode']}"
    )
    return run


def valid_row_run(row: dict[str, Any], expected: dict[str, Any], sparse: bool) -> tuple[bool, dict[str, int] | None]:
    return validate_existing_run({key: str(value) for key, value in row.items()}, expected, sparse)


def write_summaries(expected_rows: list[dict[str, Any]], results: list[dict[str, Any]], version: str) -> tuple[dict[str, int], bool]:
    by_key = {(row["workload"], row["layer"]): row for row in results}
    success = {"dense": 0, "sparse": 0}
    failed = {"dense": 0, "sparse": 0}
    timed_out = {"dense": 0, "sparse": 0}
    missing = 0
    invalid = 0
    valid_metrics: dict[tuple[str, str, str], dict[str, int]] = {}
    for expected in expected_rows:
        row = by_key[(expected["workload"], expected["layer"])]
        for sparse, prefix in ((False, "dense"), (True, "sparse")):
            status = row[f"{prefix}_status"]
            if status == "SUCCESS":
                valid, parsed = valid_row_run(row, expected, sparse)
                if valid and parsed is not None:
                    success[prefix] += 1
                    valid_metrics[(expected["workload"], expected["layer"], prefix)] = parsed
                else:
                    invalid += 1
            elif status == "FAILED":
                failed[prefix] += 1
            elif status == "TIMEOUT":
                timed_out[prefix] += 1
            else:
                missing += 1

    dense_sum = sum(values["cycles"] for (workload, layer, mode), values in valid_metrics.items() if mode == "dense")
    sparse_sum = sum(values["cycles"] for (workload, layer, mode), values in valid_metrics.items() if mode == "sparse")
    paired = [
        expected for expected in expected_rows
        if (expected["workload"], expected["layer"], "dense") in valid_metrics
        and (expected["workload"], expected["layer"], "sparse") in valid_metrics
    ]
    paired_dense = sum(valid_metrics[(item["workload"], item["layer"], "dense")]["cycles"] for item in paired)
    paired_sparse = sum(valid_metrics[(item["workload"], item["layer"], "sparse")]["cycles"] for item in paired)
    paired_reduction = 100.0 * (paired_dense - paired_sparse) / paired_dense if paired_dense else None

    lines = [
        "Final SCALE-Sim experiment raw execution report",
        "===============================================",
        "layers expected: 66", "runs expected: 132",
        f"successful dense runs: {success['dense']}",
        f"successful sparse runs: {success['sparse']}",
        f"failed dense runs: {failed['dense']}", f"failed sparse runs: {failed['sparse']}",
        f"timed-out dense runs: {timed_out['dense']}", f"timed-out sparse runs: {timed_out['sparse']}",
        f"missing results: {missing}", f"invalid results: {invalid}",
        f"aggregate dense cycles (all successful dense runs): {dense_sum}",
        f"aggregate sparse cycles (all successful sparse runs): {sparse_sum}",
        f"aggregate paired dense cycles: {paired_dense}",
        f"aggregate paired sparse cycles: {paired_sparse}",
        f"aggregate paired cycle reduction (%): {paired_reduction if paired_reduction is not None else 'NA'}",
        f"SCALE-Sim version: {version}",
        "energy: unavailable (no validated SCALE-Sim energy value emitted)",
        "dense native topology simulates one image; native cycle counters are multiplied by sample_count",
        "sparse cycles are read from the activation-mask scheduler report over the complete validated mask",
        "host runtimes are separate process wall-clock times, not accelerator latency",
        "",
        "Per workload",
        "------------",
    ]
    workloads = sorted({item["workload"] for item in expected_rows})
    for workload in workloads:
        group = [item for item in expected_rows if item["workload"] == workload]
        dense_count = sum((item["workload"], item["layer"], "dense") in valid_metrics for item in group)
        sparse_count = sum((item["workload"], item["layer"], "sparse") in valid_metrics for item in group)
        dense_cycles = sum(valid_metrics[(item["workload"], item["layer"], "dense")]["cycles"] for item in group if (item["workload"], item["layer"], "dense") in valid_metrics)
        sparse_cycles = sum(valid_metrics[(item["workload"], item["layer"], "sparse")]["cycles"] for item in group if (item["workload"], item["layer"], "sparse") in valid_metrics)
        paired_group = [item for item in group if (item["workload"], item["layer"], "dense") in valid_metrics and (item["workload"], item["layer"], "sparse") in valid_metrics]
        group_dense = sum(valid_metrics[(item["workload"], item["layer"], "dense")]["cycles"] for item in paired_group)
        group_sparse = sum(valid_metrics[(item["workload"], item["layer"], "sparse")]["cycles"] for item in paired_group)
        reduction = 100.0 * (group_dense - group_sparse) / group_dense if group_dense else None
        lines.append(
            f"{workload}: dense_success={dense_count}, sparse_success={sparse_count}, "
            f"dense_cycles={dense_cycles}, sparse_cycles={sparse_cycles}, "
            f"paired_cycle_reduction_pct={reduction if reduction is not None else 'NA'}"
        )

    lines.extend(["", "Per selected PE", "----------------"])
    for pe in (16, 32, 64):
        group = [item for item in expected_rows if item["selected_pe"] == pe]
        sparse_count = sum((item["workload"], item["layer"], "sparse") in valid_metrics for item in group)
        paired_group = [item for item in group if (item["workload"], item["layer"], "dense") in valid_metrics and (item["workload"], item["layer"], "sparse") in valid_metrics]
        group_dense = sum(valid_metrics[(item["workload"], item["layer"], "dense")]["cycles"] for item in paired_group)
        group_sparse = sum(valid_metrics[(item["workload"], item["layer"], "sparse")]["cycles"] for item in paired_group)
        reduction = 100.0 * (group_dense - group_sparse) / group_dense if group_dense else None
        lines.append(
            f"PE {pe}: layers={len(group)}, sparse_success={sparse_count}, "
            f"paired_dense_cycles={group_dense}, paired_sparse_cycles={group_sparse}, "
            f"paired_cycle_reduction_pct={reduction if reduction is not None else 'NA'}"
        )
    REPORT_TXT.write_text("\n".join(lines) + "\n", encoding="utf-8")

    validation_lines = [
        "Final SCALE-Sim execution validation",
        "=====================================",
        "expected runs: 132", "dense expected: 66", "sparse expected: 66",
        f"successful dense: {success['dense']}", f"successful sparse: {success['sparse']}",
        f"failed dense: {failed['dense']}", f"failed sparse: {failed['sparse']}",
        f"timed-out dense: {timed_out['dense']}", f"timed-out sparse: {timed_out['sparse']}",
        f"missing results: {missing}", f"invalid results: {invalid}",
    ]
    all_success = success["dense"] == 66 and success["sparse"] == 66 and not any(failed.values()) and not any(timed_out.values()) and missing == 0 and invalid == 0
    VALIDATION_TXT.write_text("\n".join(validation_lines) + "\n", encoding="utf-8")
    counts = {
        "dense_success": success["dense"], "sparse_success": success["sparse"],
        "dense_failed": failed["dense"], "sparse_failed": failed["sparse"],
        "dense_timeout": timed_out["dense"], "sparse_timeout": timed_out["sparse"],
        "missing": missing, "invalid": invalid,
    }
    return counts, all_success


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    parser.add_argument("--workload", help="limit execution to one workload key")
    parser.add_argument("--layer-index", type=int, help="limit execution to one layer index")
    parser.add_argument("--limit", type=int, help="execute at most this many selected rows")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    try:
        if not PYTHON.is_file() or not SCALESIM_CLI.is_file():
            raise RuntimeError("the configured Python interpreter or SCALE-Sim CLI is unavailable")
        expected_rows = load_expected()
        version = simulator_version()
        old_results = load_old_results()
        results = [
            normalized_old_row(item, old_results.get((item["workload"], item["layer"])), version)
            for item in expected_rows
        ]
        by_key = {(row["workload"], row["layer"]): index for index, row in enumerate(results)}
        targets = [
            item for item in expected_rows
            if (args.workload is None or item["workload"] == args.workload)
            and (args.layer_index is None or item["layer_index"] == args.layer_index)
        ]
        if args.workload is not None and not any(item["workload"] == args.workload for item in expected_rows):
            raise RuntimeError(f"unknown workload: {args.workload}")
        if args.layer_index is not None and not any(item["layer_index"] == args.layer_index for item in expected_rows):
            raise RuntimeError(f"unknown layer index: {args.layer_index}")
        if args.limit is not None:
            if args.limit <= 0:
                parser.error("--limit must be positive")
            targets = targets[:args.limit]
        if not targets:
            raise RuntimeError("no experiment rows selected")

        write_csv(RESULTS_CSV, results)
        for expected in targets:
            old = old_results.get((expected["workload"], expected["layer"]))
            row = results[by_key[(expected["workload"], expected["layer"])]]
            print(f"LAYER {expected['workload']}/{expected['layer']} PE={expected['selected_pe']}")
            use_or_execute(row, expected, old, sparse=False, timeout=args.timeout, version=version)
            use_or_execute(row, expected, old, sparse=True, timeout=args.timeout, version=version)
            dense_cycles = row["dense_cycles"]
            sparse_cycles = row["sparse_cycles"]
            if dense_cycles not in ("", None) and sparse_cycles not in ("", None):
                dense_value, sparse_value = numeric(dense_cycles), numeric(sparse_cycles)
                row["cycle_reduction_pct"] = f"{100.0 * (dense_value - sparse_value) / dense_value:.8f}" if dense_value else ""
            else:
                row["cycle_reduction_pct"] = ""
            write_csv(RESULTS_CSV, results)
            write_summaries(expected_rows, results, version)
        counts, complete = write_summaries(expected_rows, results, version)
        print(json.dumps(counts, sort_keys=True))
        print("FINAL_SCALESIM_EXECUTION_COMPLETE" if complete else "FINAL_SCALESIM_EXECUTION_PARTIAL")
        return 0 if complete else 1
    except Exception as exc:
        print(f"FINAL SCALE-Sim execution could not proceed: {exc}", file=sys.stderr)
        print("FINAL_SCALESIM_EXECUTION_FAILED")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())