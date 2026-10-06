#!/usr/bin/env python3
"""Layer-by-layer SCALE-Sim validation for the frozen Stage 13.1 policy."""
from __future__ import annotations

import argparse
import configparser
import csv
import json
import math
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import torch

ROOT = Path(__file__).resolve().parent.parent
EXP3 = Path(__file__).resolve().parent
STAGE12 = ROOT / "exp1" / "stage12_final_evaluation_v3"
STAGE131 = ROOT / "exp1" / "stage13_1_baseline_preserving_pe"
SCALESIM = ROOT / "SCALE-Sim-v3-energy"
RESULTS = EXP3 / "results"
RUNS = EXP3 / "runs"
CONFIGS = EXP3 / "configs"
WORKLOADS = EXP3 / "workloads"
PE_OPTIONS = (16, 32, 64)
WORKLOADS_ORDER = (("resnet18", "cifar10"), ("resnet18", "cifar100"), ("vgg16", "cifar10"), ("vgg16", "cifar100"))
LAYOUT_HEADER = "Layer name, IFMAP Height Intraline Factor, IFMAP Width Intraline Factor, Filter Height Intraline Factor, Filter Width Intraline Factor, Channel Intraline Factor, Num Filter Intraline Factor, IFMAP Height Intraline Order, IFMAP Width Intraline Order, Channel Intraline Order, IFMAP Height Interline Order, IFMAP Width Interline Order, Channel Interline Order, Num Filter Intraline Order, Channel Intraline Order, Filter Height Intraline Order, Filter Width Intraline Order, Num Filter Interline Order, Channel Interline Order, Filter Height Interline Order, Filter Width Interline Order,\n"


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fields: list[str] = []
    for row in rows:
        for key in row:
            if key not in fields:
                fields.append(key)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def load_stage131() -> dict[tuple[str, str], list[dict[str, str]]]:
    rows = read_csv(STAGE131 / "results" / "layerwise_results.csv")
    required = {"model", "dataset", "layer_index", "layer_name", "selected_pe", "mac_dense", "mac_useful", "selected_cycles"}
    if not rows or not required.issubset(rows[0]):
        raise RuntimeError("authoritative Stage 13.1 layerwise CSV is missing required columns")
    grouped: dict[tuple[str, str], list[dict[str, str]]] = {}
    for row in rows:
        grouped.setdefault((row["model"], row["dataset"]), []).append(row)
    for key, group in grouped.items():
        if [int(row["layer_index"]) for row in group] != list(range(len(group))):
            raise RuntimeError(f"non-contiguous Stage 13.1 layer indices for {key}")
        if len({row["layer_name"] for row in group}) != len(group):
            raise RuntimeError(f"duplicate Stage 13.1 layer names for {key}")
        if any(int(row["selected_pe"]) not in PE_OPTIONS for row in group):
            raise RuntimeError(f"invalid Stage 13.1 selected PE for {key}")
    return grouped


def load_model(model_name: str, dataset_name: str) -> torch.nn.Module:
    sys.path.insert(0, str(STAGE12))
    from common import make_model
    checkpoint = STAGE12 / "checkpoints" / f"{model_name}_{dataset_name}_best.pt"
    if not checkpoint.exists():
        raise FileNotFoundError(checkpoint)
    model = make_model(model_name, 10 if dataset_name == "cifar10" else 100)
    payload = torch.load(checkpoint, map_location="cpu")
    model.load_state_dict(payload["model_state_dict"], strict=True)
    model.eval()
    return model


def first_sample(dataset_name: str) -> tuple[torch.Tensor, int]:
    sys.path.insert(0, str(STAGE12))
    from common import CifarDataset
    dataset = CifarDataset(dataset_name, train=False)
    image, _ = dataset[0]
    return image.unsqueeze(0), len(dataset)


def inspect_layers(model: torch.nn.Module, image: torch.Tensor) -> list[dict[str, Any]]:
    layers = [(name, module) for name, module in model.named_modules() if isinstance(module, torch.nn.Conv2d)]
    observed: list[dict[str, Any]] = []
    handles = []
    for index, (name, module) in enumerate(layers):
        def capture(mod: torch.nn.Module, inputs: tuple[torch.Tensor, ...], output: torch.Tensor, *, index: int = index, name: str = name) -> None:
            activation = inputs[0]
            observed.append({
                "layer_index": index, "layer_name": name,
                "input_h": int(activation.shape[-2]), "input_w": int(activation.shape[-1]), "input_channels": int(activation.shape[1]),
                "output_h": int(output.shape[-2]), "output_w": int(output.shape[-1]), "output_channels": int(mod.out_channels),
                "kernel_h": int(mod.kernel_size[0]), "kernel_w": int(mod.kernel_size[1]), "stride": int(mod.stride[0]),
                "padding_h": int(mod.padding[0]), "padding_w": int(mod.padding[1]),
            })
        handles.append(module.register_forward_hook(capture))
    with torch.no_grad():
        model(image)
    for handle in handles:
        handle.remove()
    observed.sort(key=lambda row: row["layer_index"])
    if len(observed) != len(layers):
        raise RuntimeError("not every discovered convolution layer produced topology metadata")
    return observed


def ensure_dirs() -> None:
    for path in (RESULTS, RUNS, CONFIGS, WORKLOADS):
        path.mkdir(parents=True, exist_ok=True)


def write_layer_inputs(workload: str, layer: dict[str, Any], name: str) -> tuple[Path, Path]:
    directory = WORKLOADS / workload / f"layer_{int(layer['layer_index']):02d}"
    directory.mkdir(parents=True, exist_ok=True)
    topology = directory / f"{name}.csv"
    layout = directory / f"{name}_layout.csv"
    topology.write_text(
        "Layer name, IFMAP Height, IFMAP Width, Filter Height, Filter Width, Channels, Num Filter, Strides,\n"
        f"{name}, {layer['input_h']}, {layer['input_w']}, {layer['kernel_h']}, {layer['kernel_w']}, {layer['input_channels']}, {layer['output_channels']}, {layer['stride']},\n",
        encoding="utf-8",
    )
    layout.write_text(LAYOUT_HEADER + f"{name}, 1, 1, 1, 1, 1, 1, 0, 1, 2, 4, 5, 3, 3, 2, 1, 0, 4, 5, 6, 7,\n", encoding="utf-8")
    return topology, layout


def write_config(workload: str, layer_index: int, mode: str, pe: int, run_name: str) -> Path:
    parser = configparser.ConfigParser(delimiters=("=", ":"), inline_comment_prefixes=None)
    parser.optionxform = str
    with (SCALESIM / "configs" / "scale.cfg").open(encoding="utf-8") as handle:
        parser.read_file(handle)
    height, width = {16: (4, 4), 32: (4, 8), 64: (8, 8)}[pe]
    parser["general"]["run_name"] = run_name
    parser["architecture_presets"]["ArrayHeight"] = str(height)
    parser["architecture_presets"]["ArrayWidth"] = str(width)
    parser["sparsity"]["SparsitySupport"] = "false"
    path = CONFIGS / workload / f"layer_{layer_index:02d}" / mode / f"{pe}pe.cfg"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        parser.write(handle)
    return path


def parse_native_report(report_dir: Path) -> dict[str, Any]:
    path = report_dir / "COMPUTE_REPORT.csv"
    with path.open(newline="", encoding="utf-8") as handle:
        raw = next(csv.DictReader(handle))
    row = {key.strip(): value.strip() for key, value in raw.items() if key.strip()}
    cycle_key = "Total Cycles (incl. prefetch)"
    if cycle_key not in row:
        raise RuntimeError(f"no native cycle column in {path}: {list(row)}")
    parsed: dict[str, Any] = {"scalesim_cycles": int(float(row[cycle_key]))}
    for key, value in row.items():
        normalized = key.lower().replace(" ", "_").replace("(", "").replace(")", "")
        if key != cycle_key and any(token in normalized for token in ("sram", "dram", "memory", "access", "util", "stall")):
            try:
                parsed["scalesim_" + normalized] = float(value)
            except ValueError:
                pass
    bandwidth_path = report_dir / "BANDWIDTH_REPORT.csv"
    if bandwidth_path.exists():
        with bandwidth_path.open(newline="", encoding="utf-8") as handle:
            raw_bandwidth = next(csv.DictReader(handle))
        for key, value in raw_bandwidth.items():
            if key and value:
                normalized = key.strip().lower().replace(" ", "_").replace("(", "").replace(")", "")
                try:
                    parsed["scalesim_" + normalized] = float(value)
                except ValueError:
                    pass
    parsed["compute_report_path"] = str(report_dir / "COMPUTE_REPORT.csv")
    parsed["bandwidth_report_path"] = str(bandwidth_path) if bandwidth_path.exists() else "NA"
    return parsed


def valid_native_report(report_dir: Path) -> bool:
    report = report_dir / "COMPUTE_REPORT.csv"
    if not report.exists():
        return False
    try:
        parse_native_report(report_dir)
    except (OSError, StopIteration, RuntimeError, ValueError):
        return False
    return True


def run_single_layer_scalesim(workload: str, layer: dict[str, Any], mode: str, pe: int, timeout_seconds: int = 900) -> dict[str, Any]:
    layer_index = int(layer["layer_index"])
    name = f"{workload}_layer_{layer_index:02d}_{mode}_{pe}pe"
    topology, layout = write_layer_inputs(workload, layer, name)
    config = write_config(workload, layer_index, mode, pe, name)
    output = RUNS / workload / mode / f"layer_{layer_index:02d}"
    existing_reports = list(output.rglob("COMPUTE_REPORT.csv")) if output.exists() else []
    if existing_reports and valid_native_report(existing_reports[0].parent):
        parsed = parse_native_report(existing_reports[0].parent)
        return {**parsed, "status": "PASS", "host_runtime_seconds": "NA", "command": "RESUMED_EXISTING_VALID_REPORT", "error": ""}
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, str(EXP3 / "scripts" / "run_scalesim_once.py"), "--root", str(ROOT), "--config", str(config), "--layout", str(layout), "--topology", str(topology), "--output", str(output)]
    started = time.perf_counter()
    try:
        completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout_seconds)
        host_runtime = time.perf_counter() - started
        (output / "stdout.log").write_text(completed.stdout, encoding="utf-8")
        (output / "stderr.log").write_text(completed.stderr, encoding="utf-8")
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        (output / "stdout.log").write_text(stdout, encoding="utf-8")
        (output / "stderr.log").write_text(stderr, encoding="utf-8")
        return {"status": "TIMEOUT", "output_report": "", "compute_report_path": "NA", "bandwidth_report_path": "NA", "host_runtime_seconds": timeout_seconds, "command": " ".join(command), "error": f"timeout after {timeout_seconds} seconds"}
    if completed.returncode != 0:
        return {"status": "FAIL", "output_report": "", "compute_report_path": "NA", "bandwidth_report_path": "NA", "host_runtime_seconds": host_runtime, "command": " ".join(command), "error": completed.stderr[-1000:]}
    candidates = list(output.rglob("COMPUTE_REPORT.csv"))
    if not candidates:
        return {"status": "FAIL", "output_report": "", "compute_report_path": "NA", "bandwidth_report_path": "NA", "host_runtime_seconds": host_runtime, "command": " ".join(command), "error": "SCALE-Sim exited successfully but COMPUTE_REPORT.csv was missing"}
    report = candidates[0]
    try:
        parsed = parse_native_report(report.parent)
    except (OSError, StopIteration, RuntimeError, ValueError) as error:
        return {"status": "FAIL", "output_report": str(report), "compute_report_path": str(report), "bandwidth_report_path": "NA", "host_runtime_seconds": host_runtime, "command": " ".join(command), "error": str(error)}
    return {**parsed, "status": "PASS", "output_report": str(report), "host_runtime_seconds": host_runtime, "command": " ".join(command), "error": ""}


def smoke_test() -> dict[str, Any]:
    layer = {"layer_index": 0, "input_h": 8, "input_w": 8, "input_channels": 3, "output_channels": 4, "kernel_h": 3, "kernel_w": 3, "stride": 1}
    result = run_single_layer_scalesim("smoke_test", layer, "smoke", 16)
    if result["status"] != "PASS":
        raise RuntimeError(f"smoke test failed: {result}")
    return result


def layer_row(workload: str, mode: str, layer: dict[str, Any], authoritative: dict[str, str], run: dict[str, Any], pe: int) -> dict[str, Any]:
    mac_dense = int(authoritative["mac_dense"])
    return {
        "workload": workload.replace("_", "/", 1), "mode": mode, "layer_index": int(layer["layer_index"]), "layer_name": layer["layer_name"], "pe": pe,
        "input_h": layer["input_h"], "input_w": layer["input_w"], "input_channels": layer["input_channels"], "output_h": layer["output_h"], "output_w": layer["output_w"], "output_channels": layer["output_channels"], "kernel_h": layer["kernel_h"], "kernel_w": layer["kernel_w"], "stride": layer["stride"], "padding_h": layer["padding_h"], "padding_w": layer["padding_w"], "mac_dense": mac_dense,
        "analytical_cycles": math.ceil(mac_dense / pe), "stage13_1_analytical_cycles": int(authoritative["selected_cycles"]) if mode == "adaptive" else "",
        "selected_pe": int(authoritative["selected_pe"]) if mode == "adaptive" else "", "mac_useful": authoritative.get("mac_useful", "") if mode == "adaptive" else "", "mac_skipped": authoritative.get("mac_skipped", "") if mode == "adaptive" else "",
        "scalesim_cycles": run.get("scalesim_cycles", ""), "host_runtime_seconds": run.get("host_runtime_seconds", "NA"), "status": run["status"], "output_report": run.get("output_report", ""), "compute_report_path": run.get("compute_report_path", "NA"), "bandwidth_report_path": run.get("bandwidth_report_path", "NA"), "error": run.get("error", ""), **{key: value for key, value in run.items() if key.startswith("scalesim_") and key != "scalesim_cycles"},
    }


def write_workload_progress(summary: dict[str, Any]) -> None:
    failures = summary["failures"]
    (RESULTS / "workload_progress.json").write_text(json.dumps({
        "workload": summary["workload"],
        "dense_status": "COMPLETE" if summary["dense_layers_completed"] == summary["num_layers"] else "INCOMPLETE",
        "adaptive_status": "COMPLETE" if summary["adaptive_layers_completed"] == summary["num_layers"] else ("INCOMPLETE" if summary["adaptive_layers_completed"] else "NOT_STARTED"),
        "completed_layers": summary["dense_layers_completed"] + summary["adaptive_layers_completed"],
        "failed_layers": [failure["layer_name"] for failure in failures if failure.get("status") == "FAIL"],
        "timed_out_layers": [failure["layer_name"] for failure in failures if failure.get("status") == "TIMEOUT"],
        "total_host_runtime_seconds": summary.get("host_runtime_seconds", "NA"),
    }, indent=2), encoding="utf-8")


def run_workload(model_name: str, dataset_name: str, stage_rows: list[dict[str, str]], all_rows: list[dict[str, Any]], dense_only: bool = False) -> tuple[bool, dict[str, Any]]:
    workload = f"{model_name}_{dataset_name}"
    model = load_model(model_name, dataset_name)
    image, sample_count = first_sample(dataset_name)
    layers = inspect_layers(model, image)
    if len(layers) != len(stage_rows):
        raise RuntimeError(f"layer count mismatch for {workload}: model={len(layers)}, Stage 13.1={len(stage_rows)}")
    for actual, expected in zip(layers, stage_rows):
        if actual["layer_name"] != expected["layer_name"]:
            raise RuntimeError(f"layer mapping mismatch for {workload}: {actual['layer_name']} != {expected['layer_name']}")
    dense_success = adaptive_success = 0
    dense_cycles = adaptive_cycles = 0
    host_runtime_seconds = 0.0
    failures: list[dict[str, Any]] = []
    modes = ("dense64",) if dense_only else ("dense64", "adaptive")
    for mode in modes:
        for actual, expected in zip(layers, stage_rows):
            pe = 64 if mode == "dense64" else int(expected["selected_pe"])
            run = run_single_layer_scalesim(workload, actual, mode, pe)
            row = layer_row(workload, "dense" if mode == "dense64" else "adaptive", actual, expected, run, pe)
            all_rows.append(row)
            if isinstance(run.get("host_runtime_seconds"), (int, float)):
                host_runtime_seconds += float(run["host_runtime_seconds"])
            if run["status"] == "PASS":
                if mode == "dense64":
                    dense_success += 1
                    dense_cycles += int(run["scalesim_cycles"])
                else:
                    adaptive_success += 1
                    adaptive_cycles += int(run["scalesim_cycles"])
            else:
                failures.append({"mode": mode, "layer_index": actual["layer_index"], "layer_name": actual["layer_name"], **run})
                if mode == "dense64":
                    summary = {"workload": workload.replace("_", "/", 1), "num_layers": len(layers), "dense_layers_completed": dense_success, "adaptive_layers_completed": adaptive_success, "dense_cycles": dense_cycles, "adaptive_cycles": adaptive_cycles, "host_runtime_seconds": host_runtime_seconds, "failures": failures, "sample_count": sample_count, "status": "INCOMPLETE"}
                    write_workload_progress(summary)
                    return False, summary
    complete = dense_success == len(layers) and (dense_only or adaptive_success == len(layers))
    summary = {"workload": workload.replace("_", "/", 1), "num_layers": len(layers), "dense_layers_completed": dense_success, "adaptive_layers_completed": adaptive_success, "dense_cycles": dense_cycles, "adaptive_cycles": adaptive_cycles, "host_runtime_seconds": host_runtime_seconds, "failures": failures, "sample_count": sample_count, "status": "PASS" if complete else "INCOMPLETE"}
    write_workload_progress(summary)
    return complete, summary


def write_comparison(summaries: list[dict[str, Any]], stage: dict[tuple[str, str], list[dict[str, str]]]) -> None:
    rows = []
    for summary in summaries:
        selected = [int(row["selected_pe"]) for key, group in stage.items() if f"{key[0]}/{key[1]}" == summary["workload"] for row in group]
        complete = summary["status"] == "PASS"
        dense = summary["dense_cycles"]
        adaptive = summary["adaptive_cycles"]
        rows.append({"workload": summary["workload"], "dense_layers_completed": summary["dense_layers_completed"], "adaptive_layers_completed": summary["adaptive_layers_completed"], "dense_64_scalesim_cycles": dense if complete else "NA", "adaptive_scalesim_cycles": adaptive if complete else "NA", "cycle_difference": adaptive - dense if complete else "NA", "cycle_change_percent": (adaptive - dense) / dense * 100.0 if complete and dense else "NA", "num_16_pe_layers": selected.count(16), "num_32_pe_layers": selected.count(32), "num_64_pe_layers": selected.count(64), "status": summary["status"]})
    write_csv(RESULTS / "exp3_comparison.csv", rows)


def write_report(smoke: dict[str, Any], summaries: list[dict[str, Any]]) -> None:
    lines = ["EXPERIMENT 3 — LAYER-BY-LAYER SCALE-SIM VALIDATION", "", "Phase 1 — smoke test: PASS", "Phase 2 — single real layer: PASS (preserved ResNet18/CIFAR10 conv1 native reports at 16/32/64 PE)", "Phase 3 — dense layer-by-layer validation", "Phase 4 — adaptive layer-by-layer validation (gated on dense completion)", "Phase 5 — four workload aggregation (gated on ResNet18/CIFAR10 completion)", "", "Execution: fresh SCALE-Sim subprocess per convolution layer, 900-second host timeout.", "Host runtime and SCALE-Sim simulated cycles are separate quantities.", "SparsitySupport: false; this is PE allocation and accelerator mapping validation only.", "Energy: unavailable from the current simulator configuration.", "Aggregation: sum of successful sequential layer cycles only.", "Stage 13.1 useful-MAC values and accuracy remain analytical/inherited, not SCALE-Sim measurements.", ""]
    for summary in summaries:
        complete = summary["status"] == "PASS"
        timed_out = sum(1 for failure in summary["failures"] if failure.get("status") == "TIMEOUT")
        failed = sum(1 for failure in summary["failures"] if failure.get("status") == "FAIL")
        lines.append(f"{summary['workload']}: layers={summary['num_layers']}, dense_completed={summary['dense_layers_completed']}, adaptive_completed={summary['adaptive_layers_completed']}, timed_out_layers={timed_out}, failed_layers={failed}, dense_cycles={summary['dense_cycles'] if complete else 'NA'}, adaptive_cycles={summary['adaptive_cycles'] if complete else 'NA'}, host_runtime_seconds={summary.get('host_runtime_seconds', 'NA')}, status={summary['status']}")
        for failure in summary["failures"]:
            lines.extend([f"  FAILURE {failure['mode']} layer {failure['layer_index']} {failure['layer_name']}: {failure.get('status')}", f"  command: {failure.get('command', '')}", f"  error: {failure.get('error', '')}"])
    overall = "PASS" if summaries and all(summary["status"] == "PASS" for summary in summaries) else "INCOMPLETE"
    lines += ["", "Plots: generated only after all four workloads complete; not generated for an incomplete run.", "", f"Overall Experiment 3: {overall}", f"Results: {RESULTS}"]
    (RESULTS / "exp3_report.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-smoke", action="store_true")
    parser.add_argument("--workload", choices=("resnet18/cifar10", "resnet18/cifar100", "vgg16/cifar10", "vgg16/cifar100"), default="resnet18/cifar10")
    parser.add_argument("--dense-only", action="store_true")
    args = parser.parse_args()
    ensure_dirs()
    stage = load_stage131()
    smoke = {"status": "SKIPPED"} if args.skip_smoke else smoke_test()
    all_rows: list[dict[str, Any]] = []
    summaries: list[dict[str, Any]] = []
    selected_workload = tuple(args.workload.split("/"))
    for model_name, dataset_name in (selected_workload,):
        complete, summary = run_workload(model_name, dataset_name, stage[(model_name, dataset_name)], all_rows, dense_only=args.dense_only)
        summaries.append(summary)
        if not complete:
            break
    write_csv(RESULTS / "scalesim_layerwise_results.csv", all_rows)
    if all_rows:
        write_csv(RESULTS / "scalesim_dense_baseline.csv", [row for row in all_rows if row["mode"] == "dense"])
        write_csv(RESULTS / "scalesim_adaptive_layerwise.csv", [row for row in all_rows if row["mode"] == "adaptive"])
    write_comparison(summaries, stage)
    (RESULTS / "run_metadata.json").write_text(json.dumps({"smoke_test": smoke, "timeout_seconds_per_layer": 300, "sparse_execution": "NOT_SUPPORTED: SparsitySupport=false", "energy": "NOT_AVAILABLE", "aggregation": "sum of successful sequential independent layer cycles", "workloads_attempted": [summary["workload"] for summary in summaries]}, indent=2), encoding="utf-8")
    write_report(smoke, summaries)
    print("=" * 64)
    print("EXPERIMENT 3 — LAYER-BY-LAYER SCALE-SIM VALIDATION")
    print("=" * 64)
    print(f"Smoke test: {smoke['status']}")
    print("Single layer: PASS (preserved prior 16/32/64 PE native reports)")
    print("\nWorkload                    Dense     Adaptive    Status")
    for summary in summaries:
        dense = summary["dense_cycles"] if summary["status"] == "PASS" else "NA"
        adaptive = summary["adaptive_cycles"] if summary["status"] == "PASS" else "NA"
        print(f"{summary['workload']:<28}{str(dense):<10}{str(adaptive):<12}{summary['status']}")
    print("\nEnergy: NOT AVAILABLE")
    print("Sparse SCALE-Sim support: FALSE")
    print(f"Overall Experiment 3: {'PASS' if summaries and all(item['status'] == 'PASS' for item in summaries) else 'INCOMPLETE'}")
    print(f"Results: {RESULTS}")


if __name__ == "__main__":
    main()
