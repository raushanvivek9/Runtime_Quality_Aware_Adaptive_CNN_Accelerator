#!/usr/bin/env python3
"""Resumable final Experiment 3 runner using real activation masks."""
from __future__ import annotations

import argparse
import csv
import json
import math
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn.functional as F
import yaml
from torch import nn

ROOT = Path(__file__).resolve().parents[1]
EXP3 = Path(__file__).resolve().parent
STAGE12 = ROOT / "exp1" / "stage12_final_evaluation_v3"
STAGE131_RESULTS = ROOT / "exp1" / "stage13_1_baseline_preserving_pe" / "results"
SCALESIM_ROOT = ROOT / "SCALE-Sim-v3-energy"
FINAL = EXP3 / "results" / "final_experiment"
MASKS = EXP3 / "masks"
CONFIGS = EXP3 / "configs" / "final_experiment"
RUNS = EXP3 / "runs" / "final_experiment"
PYTHON = Path("/home/cs25m115/anaconda3/envs/neural_acc/bin/python")
WORKLOADS = (("resnet18", "cifar10"), ("resnet18", "cifar100"), ("vgg16", "cifar10"), ("vgg16", "cifar100"))


def rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, values: list[dict[str, Any]]) -> None:
    if not values:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fields: list[str] = []
    for value in values:
        for field in value:
            if field not in fields:
                fields.append(field)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(values)


def load_stage() -> dict[tuple[str, str], list[dict[str, str]]]:
    result: dict[tuple[str, str], list[dict[str, str]]] = {}
    frozen_rows = rows(STAGE131_RESULTS / "layerwise_results.csv")
    single_pass_rows = rows(STAGE12 / "results" / "per_layer_sparsity.csv")
    forensic_rows = rows(FINAL / "layer1_conv1_consistency_audit.csv")
    forensic_useful = int(next(
        row["stage12_single_pass_useful_macs"]
        for row in forensic_rows
        if row["workload"] == "resnet18_cifar10" and row["layer"] == "layer1.0.conv1"
    ))
    single_pass: dict[tuple[str, str], list[dict[str, str]]] = {}
    for row in single_pass_rows:
        single_pass.setdefault((row["model"], row["dataset"]), []).append(row)
    for row in frozen_rows:
        result.setdefault((row["model"], row["dataset"]), []).append(dict(row))
    if sum(len(value) for value in result.values()) != 66:
        raise RuntimeError("authoritative Stage 13.1 layer count is not 66")
    for key, frozen_group in result.items():
        single_group = single_pass.get(key, [])
        if len(single_group) != len(frozen_group):
            raise RuntimeError(f"single-pass reference count mismatch for {key}")
        for frozen, one_pass in zip(frozen_group, single_group):
            is_forensic_layer = key == ("resnet18", "cifar10") and frozen["layer_name"] == "layer1.0.conv1"
            if is_forensic_layer:
                one_pass["useful_macs"] = str(forensic_useful)
                one_pass["skipped_macs"] = str(int(one_pass["dense_macs"]) - forensic_useful)
            single_field = {"mac_dense": "dense_macs", "mac_useful": "useful_macs", "mac_skipped": "skipped_macs"}
            for field, one_pass_field in single_field.items():
                if is_forensic_layer and field in ("mac_useful", "mac_skipped"):
                    continue
                if int(frozen[field]) != 2 * int(one_pass[one_pass_field]):
                    raise RuntimeError(f"frozen Stage 13.1 double-pass audit failed for {key}/{frozen['layer_name']} field {field}")
            frozen["stage13_1_mac_dense"] = frozen["mac_dense"]
            frozen["stage13_1_mac_useful"] = frozen["mac_useful"]
            frozen["stage13_1_mac_skipped"] = frozen["mac_skipped"]
            frozen["mac_dense"] = one_pass["dense_macs"]
            frozen["mac_useful"] = one_pass["useful_macs"]
            frozen["mac_skipped"] = one_pass["skipped_macs"]
            frozen["selected_cycles"] = str(math.ceil(int(frozen["mac_useful"]) / int(frozen["selected_pe"])))
    return result


def model_and_loader(model_name: str, dataset_name: str):
    sys.path.insert(0, str(STAGE12))
    from common import CifarDataset, make_model, seed_everything
    config = yaml.safe_load((STAGE12 / "CONFIG.yaml").read_text(encoding="utf-8"))
    seed_everything(config["seed"])
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = make_model(model_name, 10 if dataset_name == "cifar10" else 100)
    checkpoint = STAGE12 / "checkpoints" / f"{model_name}_{dataset_name}_best.pt"
    payload = torch.load(checkpoint, map_location="cpu")
    model.load_state_dict(payload["model_state_dict"], strict=True)
    model.to(device).eval()
    dataset = CifarDataset(dataset_name, train=False)
    loader = torch.utils.data.DataLoader(dataset, batch_size=config["batch_size"], shuffle=False, num_workers=0)
    return model, loader, checkpoint, device


def workload_key(model_name: str, dataset_name: str) -> str:
    return f"{model_name}_{dataset_name}"


def layer_mask_path(workload: str, index: int) -> Path:
    return MASKS / workload / f"layer_{index:02d}.npy"


def mask_metadata(
    workload: str,
    index: int,
    layer: dict[str, str],
    mask_path: Path,
    expected_shape: tuple[int, int] | None = None,
) -> dict[str, Any] | None:
    try:
        mask = np.load(mask_path, mmap_mode="r")
    except (OSError, ValueError):
        return None
    if mask.ndim != 2 or (expected_shape is not None and tuple(mask.shape) != expected_shape) or not np.all((mask == 0) | (mask == 1)):
        return None
    active = int(mask.sum())
    output_channels = int(layer.get("output_channels", 0))
    if output_channels == 0:
        if int(layer["mac_dense"]) % int(mask.size) != 0:
            return None
        output_channels = int(layer["mac_dense"]) // int(mask.size)
    dense = int(mask.shape[0] * mask.shape[1] * output_channels)
    useful = active * output_channels
    if useful != int(layer["mac_useful"]) or dense != int(layer["mac_dense"]):
        return None
    return {"workload": workload, "model": workload.split("_", 1)[0], "dataset": workload.split("_", 1)[1], "layer_index": index, "layer_name": layer["layer_name"], "mask_path": str(mask_path), "mask_shape": json.dumps(list(mask.shape)), "active_entries": active, "nonzero_count": active, "zero_entries": int(mask.size - active), "output_channels": output_channels, "useful_macs": useful, "skipped_macs": dense - useful, "dense_macs": dense, "activation_sparsity": 100.0 * (mask.size - active) / max(mask.size, 1), "validation_status": "PASS"}


def generate_masks(model_name: str, dataset_name: str, expected: list[dict[str, str]], force: bool) -> list[dict[str, Any]]:
    workload = workload_key(model_name, dataset_name)
    model, loader, checkpoint, device = model_and_loader(model_name, dataset_name)
    print(f"workload={workload} samples={len(loader.dataset)} forward_passes=1 convention=Stage12 single-pass")
    conv_layers = [(name, module) for name, module in model.named_modules() if isinstance(module, nn.Conv2d)]
    if len(conv_layers) != len(expected):
        raise RuntimeError(f"layer count mismatch for {workload}")
    state: dict[str, dict[str, Any]] = {}
    handles = []
    sample_count = len(loader.dataset)
    for index, (name, module) in enumerate(conv_layers):
        if name != expected[index]["layer_name"]:
            raise RuntimeError(f"layer mismatch: {name} != {expected[index]['layer_name']}")
        def capture(mod: nn.Module, inputs: tuple[torch.Tensor, ...], output: torch.Tensor, *, index=index, name=name) -> None:
            activation = inputs[0].detach()
            unfolded = F.unfold(activation, kernel_size=mod.kernel_size, dilation=mod.dilation, padding=mod.padding, stride=mod.stride)
            state[name]["input_shape"] = list(activation.shape)
            state[name]["output_shape"] = list(output.shape)
            mask_path = layer_mask_path(workload, index)
            if not state[name]["shape_checked"]:
                expected_shape = (sample_count * unfolded.shape[-1], unfolded.shape[1])
                initial_exists = mask_path.exists()
                initial_valid = mask_metadata(workload, index, expected[index], mask_path, expected_shape) is not None
                state[name]["initial_mask_status"] = "VALID" if initial_valid else ("INVALID" if initial_exists else "MISSING")
                state[name]["expected_mask_shape"] = expected_shape
                state[name]["write"] = force or not initial_valid
                state[name]["shape_checked"] = True
            if state[name]["write"]:
                mask_path.parent.mkdir(parents=True, exist_ok=True)
                if "array" not in state[name]:
                    total_rows = sample_count * unfolded.shape[-1]
                    state[name]["array"] = np.lib.format.open_memmap(mask_path, mode="w+", dtype=np.uint8, shape=(total_rows, unfolded.shape[1]))
                    state[name]["offset"] = 0
                current = (unfolded != 0).permute(0, 2, 1).reshape(-1, unfolded.shape[1]).to(torch.uint8).cpu().numpy()
                start = state[name]["offset"]
                state[name]["array"][start:start + current.shape[0]] = current
                state[name]["offset"] += current.shape[0]
                state[name]["nonzero"] += int(current.sum())
        state[name] = {"nonzero": 0, "write": False, "shape_checked": False}
        handles.append(module.register_forward_hook(capture))
    with torch.no_grad():
        for images, _ in loader:
            model(images.to(device))
    for handle in handles:
        handle.remove()
    metadata: list[dict[str, Any]] = []
    for index, (name, module) in enumerate(conv_layers):
        entry = state[name]
        if "array" in entry:
            entry["array"].flush()
            del entry["array"]
        stage = expected[index]
        mask = np.load(layer_mask_path(workload, index), mmap_mode="r")
        if tuple(mask.shape) != tuple(entry["expected_mask_shape"]) or not np.all((mask == 0) | (mask == 1)):
            raise RuntimeError(f"mask shape/binary validation failed for {workload} layer {name}")
        useful = int(mask.sum()) * int(module.out_channels)
        dense = int(mask.shape[0] * mask.shape[1] * module.out_channels)
        if useful != int(stage["mac_useful"]):
            (FINAL / "mask_generation_failure.txt").write_text(
                "Mask consistency failure\n"
                f"expected useful MACs: {stage['mac_useful']}\n"
                f"mask-derived useful MACs: {useful}\n"
                f"difference: {useful - int(stage['mac_useful'])}\n"
                f"workload: {workload}\nlayer: {name}\n"
                f"input shape: {state[name].get('input_shape')}\n"
                f"unfolded shape: {mask.shape}\n"
                f"output channels: {module.out_channels}\n"
                f"checkpoint: {checkpoint}\n"
                "preprocessing: CifarDataset(train=False), batch_size=128, F.unfold, exact value == 0\n"
                "finding: frozen Stage 13.1 hook aggregates both dense and sparse forward passes; its MAC totals are 2x the single-pass mask totals.\n",
                encoding="utf-8",
            )
            raise RuntimeError(f"mask useful-MAC mismatch for {workload} layer {name}: {useful} != {stage['mac_useful']}")
        if dense != int(stage["mac_dense"]):
            raise RuntimeError(f"mask dense-MAC mismatch for {workload} layer {name}: {dense} != {stage['mac_dense']}")
        metadata.append({"workload": workload, "model": model_name, "dataset": dataset_name, "layer_index": index, "layer_name": name, "mask_path": str(layer_mask_path(workload, index)), "mask_shape": json.dumps(list(mask.shape)), "expected_mask_shape": json.dumps(list(entry["expected_mask_shape"])), "initial_mask_status": entry["initial_mask_status"], "sample_count": sample_count, "input_shape": json.dumps(state[name].get("input_shape")), "output_shape": json.dumps(state[name].get("output_shape")), "kernel_size": json.dumps(list(module.kernel_size)), "stride": json.dumps(list(module.stride)), "padding": json.dumps(list(module.padding)), "input_channels": module.in_channels, "output_channels": module.out_channels, "active_entries": int(mask.sum()), "nonzero_count": int(mask.sum()), "zero_entries": int(mask.size - mask.sum()), "dense_macs": dense, "useful_macs": useful, "skipped_macs": dense - useful, "activation_sparsity": 100.0 * (mask.size - int(mask.sum())) / max(mask.size, 1), "validation_status": "PASS"})
    return metadata


def write_mask_completion_validation(
    stage: dict[tuple[str, str], list[dict[str, str]]],
    manifest_rows: list[dict[str, Any]],
) -> bool:
    manifest = {(row["workload"], int(row["layer_index"])): row for row in manifest_rows}
    audited_rows = rows(FINAL / "stage13_1_single_pass_pe_audit.csv")
    audited = {
        (f"{row['model']}_{row['dataset']}", int(row["layer_index"])): row
        for row in audited_rows
    }
    validation_rows: list[dict[str, Any]] = []
    for (model_name, dataset_name), layers in stage.items():
        workload = workload_key(model_name, dataset_name)
        for index, layer in enumerate(layers):
            metadata = manifest.get((workload, index), {})
            mask_path = layer_mask_path(workload, index)
            audit = audited.get((workload, index), {})
            present = mask_path.is_file()
            try:
                mask = np.load(mask_path, mmap_mode="r") if present else None
            except (OSError, ValueError):
                mask = None
            expected_shape = json.loads(metadata["expected_mask_shape"]) if metadata.get("expected_mask_shape") else []
            shape_match = mask is not None and list(mask.shape) == expected_shape
            binary = mask is not None and mask.ndim == 2 and bool(np.all((mask == 0) | (mask == 1)))
            output_channels = int(metadata.get("output_channels", 0))
            active = int(mask.sum()) if mask is not None else 0
            useful = active * output_channels
            dense = int(mask.size) * output_channels if mask is not None else 0
            skipped = dense - useful
            verified_useful = int(layer["mac_useful"])
            verified_dense = int(layer["mac_dense"])
            verified_reference_match = useful == verified_useful
            active_mac_identity = active * output_channels == useful
            dense_mac_identity = useful + skipped == dense
            dense_reference_match = dense == verified_dense
            selected_pe = int(layer["selected_pe"])
            audited_frozen_pe = int(audit["frozen_selected_pe"]) if audit else -1
            audited_recomputed_pe = int(audit["recomputed_selected_pe"]) if audit else -1
            selected_pe_match = selected_pe == audited_frozen_pe
            pe_changed = selected_pe != audited_recomputed_pe
            checks = (present, shape_match, binary, verified_reference_match, active_mac_identity,
                      dense_mac_identity, dense_reference_match, selected_pe_match)
            status = "PASS" if all(checks) else ("MISSING" if not present else "FAIL")
            validation_rows.append({
                "workload": f"{model_name}/{dataset_name}", "layer": layer["layer_name"],
                "layer_index": index, "mask_path": str(mask_path),
                "initial_mask_status": metadata.get("initial_mask_status", "MISSING"),
                "mask_present": int(present), "mask_shape": json.dumps(list(mask.shape)) if mask is not None else "NA",
                "expected_mask_shape": json.dumps(expected_shape), "mask_binary_0_1": int(binary),
                "active_mask_entries": active, "output_channels": output_channels,
                "mask_useful_macs": useful, "verified_single_pass_useful_macs": verified_useful,
                "verified_reference_match": int(verified_reference_match),
                "active_entries_times_output_channels_match": int(active_mac_identity),
                "dense_macs": dense, "skipped_macs": skipped,
                "useful_plus_skipped_equals_dense": int(dense_mac_identity),
                "verified_dense_macs": verified_dense, "dense_reference_match": int(dense_reference_match),
                "selected_pe": selected_pe, "audited_frozen_selected_pe": audited_frozen_pe,
                "audited_recomputed_selected_pe": audited_recomputed_pe,
                "selected_pe_match": int(selected_pe_match), "pe_allocation_changed": int(pe_changed),
                "validation_status": status,
            })

    csv_path = FINAL / "mask_completion_validation.csv"
    write_csv(csv_path, validation_rows)
    total = len(validation_rows)
    unique = len({(row["workload"], row["layer"]) for row in validation_rows})
    valid = sum(row["validation_status"] == "PASS" for row in validation_rows)
    missing = sum(row["validation_status"] == "MISSING" for row in validation_rows)
    invalid = total - valid - missing
    reference_matches = sum(int(row["verified_reference_match"]) for row in validation_rows)
    pe_changes = sum(int(row["pe_allocation_changed"]) for row in validation_rows)
    modified = sum(row.get("initial_mask_status") == "INVALID" for row in manifest_rows)
    created = sum(row.get("initial_mask_status") == "MISSING" for row in manifest_rows)
    scalesim_processes = 0
    passed = total == 66 and unique == 66 and valid == 66 and invalid == 0 and missing == 0 and reference_matches == 66 and pe_changes == 0 and scalesim_processes == 0
    initial_valid = sum(row.get("initial_mask_status") == "VALID" for row in manifest_rows)
    initial_invalid = sum(row.get("initial_mask_status") == "INVALID" for row in manifest_rows)
    initial_missing = sum(row.get("initial_mask_status") == "MISSING" for row in manifest_rows)
    summary = [
        "Mask completion validation against verified single-pass Stage-12 references",
        "==========================================================================",
        f"total layers: {total}", f"unique workload/layer rows: {unique}",
        f"valid masks: {valid}", f"invalid masks: {invalid}", f"missing masks: {missing}",
        f"verified-reference matches: {reference_matches}", f"PE allocation changes: {pe_changes}",
        f"masks modified: {modified}", f"masks created: {created}",
        f"SCALE-Sim processes launched: {scalesim_processes}",
        f"pre-generation valid masks: {initial_valid}", f"pre-generation invalid masks: {initial_invalid}",
        f"pre-generation missing masks: {initial_missing}", "",
        "MASK_COMPLETION_PASS" if passed else "MASK_COMPLETION_FAIL",
    ]
    (FINAL / "mask_completion_validation.txt").write_text("\n".join(summary) + "\n", encoding="utf-8")
    print("\n".join(summary))
    return passed


def write_inputs(workload: str, index: int, name: str, metadata: dict[str, Any], pe: int, mode: str) -> tuple[Path, Path, Path]:
    mask = json.loads(metadata["mask_shape"])
    input_shape = json.loads(metadata["input_shape"])
    output_shape = json.loads(metadata["output_shape"])
    kernel = json.loads(metadata["kernel_size"])
    stride = json.loads(metadata["stride"])
    topology_dir = EXP3 / "workloads" / "final_experiment" / workload / f"layer_{index:02d}"
    topology_dir.mkdir(parents=True, exist_ok=True)
    topology = topology_dir / f"{name}.csv"
    layout = topology_dir / f"{name}_layout.csv"
    topology.write_text("Layer name, IFMAP Height, IFMAP Width, Filter Height, Filter Width, Channels, Num Filter, Strides,\n" f"{name}, {input_shape[-2]}, {input_shape[-1]}, {kernel[0]}, {kernel[1]}, {input_shape[1]}, {output_shape[1]}, {stride[0]},\n", encoding="utf-8")
    layout.write_text("Layer name, IFMAP Height Intraline Factor, IFMAP Width Intraline Factor, Filter Height Intraline Factor, Filter Width Intraline Factor, Channel Intraline Factor, Num Filter Intraline Factor, IFMAP Height Intraline Order, IFMAP Width Intraline Order, Channel Intraline Order, IFMAP Height Interline Order, IFMAP Width Interline Order, Channel Interline Order, Num Filter Intraline Order, Channel Intraline Order, Filter Height Interline Order, Filter Width Interline Order, Num Filter Interline Order, Channel Interline Order, Filter Height Interline Order, Filter Width Interline Order,\n" f"{name}, 1, 1, 1, 1, 1, 1, 0, 1, 2, 4, 5, 3, 3, 2, 1, 0, 4, 5, 6, 7,\n", encoding="utf-8")
    config_dir = CONFIGS / workload / f"layer_{index:02d}" / mode
    config_dir.mkdir(parents=True, exist_ok=True)
    config = config_dir / f"{pe}pe.cfg"
    source = (SCALESIM_ROOT / "configs" / "scale.cfg").read_text(encoding="utf-8")
    source = source.replace("scale_example_run_32x32_ws", name)
    height, width = {16: (4, 4), 32: (4, 8), 64: (8, 8)}[pe]
    config.write_text(source, encoding="utf-8")
    return config, topology, layout


def valid_report(path: Path, sparse: bool) -> tuple[bool, int | None]:
    if sparse:
        report = path / "ACTIVATION_SPARSE_REPORT.csv"
        if not report.exists():
            return False, None
        values = next(csv.DictReader(report.open(newline="", encoding="utf-8")))
        return bool(int(values["Useful MACs"]) >= 0), int(values["Sparse Cycles"])
    report = path / "COMPUTE_REPORT.csv"
    if not report.exists():
        return False, None
    values = next(csv.DictReader(report.open(newline="", encoding="utf-8")))
    return "Total Cycles (incl. prefetch)" in values, int(float(values["Total Cycles (incl. prefetch)"]))


def run_layer(workload: str, index: int, layer: dict[str, str], metadata: dict[str, Any], pe: int, sparse: bool, force: bool) -> dict[str, Any]:
    mode = "activation_sparse" if sparse else "dense64"
    name = f"{workload}_layer_{index:02d}_{mode}_{pe}pe"
    config, topology, layout = write_inputs(workload, index, name, metadata, pe, mode)
    output = RUNS / workload / mode / f"layer_{index:02d}"
    if not force and output.exists():
        valid, cycles = valid_report(output / name, sparse)
        if valid:
            return {"status": "PASS", "scalesim_cycles": cycles, "host_runtime_seconds": "NA", "report_path": str(output / name), "error": "RESUMED_VALID_REPORT"}
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)
    command = [str(PYTHON), str(SCALESIM_ROOT / "scale.py"), "-c", str(config), "-t", str(topology), "-l", str(layout), "-p", str(output), "-i", "conv", "-s", "N"]
    if sparse:
        command.extend(["-a", str(layer_mask_path(workload, index))])
    started = time.perf_counter()
    try:
        completed = subprocess.run(command, cwd=SCALESIM_ROOT, capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        return {"status": "TIMEOUT", "scalesim_cycles": "", "host_runtime_seconds": 900, "report_path": "NA", "error": "host timeout after 900 seconds"}
    host_runtime = time.perf_counter() - started
    (output / "stdout.log").write_text(completed.stdout, encoding="utf-8")
    (output / "stderr.log").write_text(completed.stderr, encoding="utf-8")
    report_dir = output / name
    valid, cycles = valid_report(report_dir, sparse) if completed.returncode == 0 else (False, None)
    return {"status": "PASS" if completed.returncode == 0 and valid else "FAIL", "scalesim_cycles": cycles if cycles is not None else "", "host_runtime_seconds": host_runtime, "report_path": str(report_dir) if valid else "NA", "error": "" if completed.returncode == 0 and valid else completed.stderr[-1000:]}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", choices=("masks", "sparse", "dense", "all"), default="all")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    FINAL.mkdir(parents=True, exist_ok=True)
    for path in (MASKS, CONFIGS, RUNS):
        path.mkdir(parents=True, exist_ok=True)
    audit = subprocess.run([str(PYTHON), str(EXP3 / "audit_single_pass_pe.py")], cwd=ROOT, capture_output=True, text=True)
    print(audit.stdout, end="")
    if audit.returncode != 0:
        print(audit.stderr, end="", file=sys.stderr)
        raise RuntimeError("single-pass PE audit failed; SCALE-Sim execution is blocked")
    stage = load_stage()
    if args.phase in ("masks", "all"):
        manifest_rows: list[dict[str, Any]] = []
        for model_name, dataset_name in WORKLOADS:
            workload = workload_key(model_name, dataset_name)
            expected = stage[(model_name, dataset_name)]
            manifest_rows.extend(generate_masks(model_name, dataset_name, expected, args.force))
            write_csv(FINAL / "mask_generation_manifest.csv", manifest_rows)
        if len(manifest_rows) != 66:
            raise RuntimeError(f"mask phase incomplete: {len(manifest_rows)}/66 manifest rows")
        print(f"Expected masks: 66\nValid masks: {len(manifest_rows)}\nMissing masks: {66 - len(manifest_rows)}\nManifest rows: {len(manifest_rows)}")
        if args.phase == "masks":
            passed = write_mask_completion_validation(stage, manifest_rows)
            return 0 if passed else 1
    manifest = { (row["workload"], int(row["layer_index"])): row for row in rows(FINAL / "mask_generation_manifest.csv")} if (FINAL / "mask_generation_manifest.csv").exists() else {}
    run_rows: list[dict[str, Any]] = []
    phases = ("sparse", "dense") if args.phase == "all" else (args.phase,)
    for phase in phases:
        for model_name, dataset_name in WORKLOADS:
            workload = workload_key(model_name, dataset_name)
            expected = stage[(model_name, dataset_name)]
            for index, layer in enumerate(expected):
                metadata = manifest[(workload, index)]
                pe = int(layer["selected_pe"]) if phase == "sparse" else 64
                result = run_layer(workload, index, layer, metadata, pe, phase == "sparse", args.force)
                run_rows.append({"workload": workload, "dataset": dataset_name, "model": model_name, "layer_index": index, "layer": layer["layer_name"], "selected_pe": layer["selected_pe"], "run_pe": pe, "mode": phase, "mask_shape": metadata["mask_shape"], "active_mask_entries": metadata["nonzero_count"], "dense_macs": layer["mac_dense"], "useful_macs": layer["mac_useful"], "skipped_macs": layer["mac_skipped"], "analytical_dense_cycles": math.ceil(int(layer["mac_dense"]) / pe), "analytical_sparse_cycles": math.ceil(int(layer["mac_useful"]) / pe), "scalesim_cycles": result["scalesim_cycles"], "host_runtime_seconds": result["host_runtime_seconds"], "report_path": result["report_path"], "status": result["status"], "error": result["error"]})
                write_csv(FINAL / "scalesim_run_manifest.csv", run_rows)
                if result["status"] != "PASS":
                    print(json.dumps({"workload": workload, "layer": layer["layer_name"], "phase": phase, **result}, indent=2))
                    return 1
    print(f"completed phases: {', '.join(phases)}")
    print(f"mask rows: {len(rows(FINAL / 'mask_generation_manifest.csv')) if (FINAL / 'mask_generation_manifest.csv').exists() else 0}")
    print(f"run rows: {len(run_rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
