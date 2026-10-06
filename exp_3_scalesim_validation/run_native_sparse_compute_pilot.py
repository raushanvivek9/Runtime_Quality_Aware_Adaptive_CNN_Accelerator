#!/usr/bin/env python3
"""Run synthetic and one-image Phase-A WS sparse compute validation only."""
from __future__ import annotations

import csv
import json
import math
import sys
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parents[1]
EXP3 = Path(__file__).resolve().parent
STAGE12 = ROOT / "exp1" / "stage12_final_evaluation_v3"
SCALESIM_ROOT = ROOT / "SCALE-Sim-v3-energy"
OUTPUT = EXP3 / "results" / "native_sparse_compute_pilot"
MASK = EXP3 / "masks" / "resnet18_cifar10" / "layer_01.npy"
FINAL_CSV = EXP3 / "results" / "final_experiment" / "final_scalesim_results.csv"
PE_AUDIT_CSV = EXP3 / "results" / "final_experiment" / "stage13_1_single_pass_pe_audit.csv"
TARGET = ("resnet18_cifar10", "layer1.0.conv1")

sys.path.insert(0, str(SCALESIM_ROOT))
sys.path.insert(0, str(STAGE12))
from scalesim.compute.native_sparse_ws import build_sparse_ws_schedule, execute_sparse_ws


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_csv(path: Path, fields: list[str], rows: list[dict[str, Any]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def csv_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def read_one_report_row(path: Path) -> dict[str, str]:
    with path.open(newline="", encoding="utf-8") as handle:
        records = [
            {key.strip(): (value or "").strip() for key, value in row.items() if key and key.strip()}
            for row in csv.DictReader(handle)
        ]
    records = [row for row in records if any(row.values())]
    if len(records) != 1:
        raise RuntimeError(f"expected one native dense report row in {path}, found {len(records)}")
    return records[0]


def run_synthetic_validation() -> dict[str, Any]:
    active_sets = ([0, 2, 5], [1, 4], [0, 3, 7, 8], [2, 6, 9, 11])
    positions, reduction_size, channels = 4, 12, 10
    mask = np.zeros((positions, reduction_size), dtype=np.uint8)
    rng = np.random.default_rng(24)
    activations = np.zeros((positions, reduction_size), dtype=np.float32)
    for position, active_k in enumerate(active_sets):
        mask[position, active_k] = 1
        activations[position, active_k] = rng.normal(size=len(active_k))
    weights = rng.normal(size=(reduction_size, channels)).astype(np.float32)

    schedule = build_sparse_ws_schedule(mask, channels, array_rows=4, array_cols=8)
    events = list(schedule.iter_events())
    dense_output = activations @ weights
    sparse_output = execute_sparse_ws(activations, weights, mask, schedule)

    observed_by_position = {position: set() for position in range(positions)}
    event_coordinates: set[tuple[int, int, int]] = set()
    pe_slots: set[tuple[int, int, int]] = set()
    for event in events:
        if event.original_k not in active_sets[event.output_position]:
            raise RuntimeError("event changed or invented an original K index")
        if event.pe_row != event.original_k % 4 or event.pe_col != event.output_channel % 8:
            raise RuntimeError("event PE mapping does not preserve original K/output-channel mapping")
        if not (0 <= event.pe_row < 4 and 0 <= event.pe_col < 8):
            raise RuntimeError("event PE coordinate is outside the 4x8 array")
        observed_by_position[event.output_position].add(event.original_k)
        event_coordinates.add((event.output_position, event.original_k, event.output_channel))
        slot = (event.issue_cycle, event.pe_row, event.pe_col)
        if slot in pe_slots:
            raise RuntimeError("two MACs were assigned to the same PE in one issue cycle")
        pe_slots.add(slot)

    max_abs_error = float(np.max(np.abs(sparse_output - dense_output)))
    numerical_match = sparse_output.shape == dense_output.shape and bool(
        np.allclose(sparse_output, dense_output, rtol=2e-6, atol=2e-6)
    )
    checks = {
        "output_shape_identical": sparse_output.shape == dense_output.shape,
        "numerical_match": numerical_match,
        "active_k_sets_differ_by_position": len({tuple(values) for values in active_sets}) == len(active_sets),
        "original_k_indices_preserved": all(observed_by_position[i] == set(active_sets[i]) for i in range(positions)),
        "event_count_matches_useful_macs": len(events) == schedule.useful_macs,
        "pe_assignments_valid_and_unique": len(pe_slots) == len(events),
        "output_channels_valid": all(0 <= event.output_channel < channels for event in events),
        "mac_conservation": schedule.useful_macs + schedule.skipped_macs == schedule.dense_macs,
        "not_analytical_cycle_fallback": schedule.cycles != schedule.analytical_lower_bound,
    }
    status = "PASS" if all(checks.values()) else "FAIL"
    payload = {
        "test": "synthetic_irregular_activation_mask",
        "array_rows": 4,
        "array_cols": 8,
        "output_positions": positions,
        "reduction_size": reduction_size,
        "output_channels": channels,
        "active_k_by_position": [list(values) for values in active_sets],
        "active_mask_entries": schedule.active_mask_entries,
        "dense_macs": schedule.dense_macs,
        "useful_macs": schedule.useful_macs,
        "skipped_macs": schedule.skipped_macs,
        "event_count": len(events),
        "sparse_compute_cycles": schedule.cycles,
        "analytical_lower_bound_label": "ANALYTICAL LOWER BOUND",
        "analytical_lower_bound_cycles": schedule.analytical_lower_bound,
        "max_abs_error": max_abs_error,
        "checks": checks,
        "status": status,
    }
    fields = [
        "test", "output_positions", "reduction_size", "output_channels", "array_rows", "array_cols",
        "active_mask_entries", "dense_macs", "useful_macs", "skipped_macs", "event_count",
        "sparse_compute_cycles", "analytical_lower_bound_label", "analytical_lower_bound_cycles",
        "max_abs_error", "original_k_indices_preserved", "pe_assignments_valid_and_unique",
        "output_channels_valid", "numerical_match", "status",
    ]
    write_json(OUTPUT / "synthetic_validation.json", payload)
    write_csv(OUTPUT / "synthetic_validation.csv", fields, [{
        **{field: payload.get(field, "") for field in fields},
        **{name: checks[name] for name in ("original_k_indices_preserved", "pe_assignments_valid_and_unique", "output_channels_valid", "numerical_match")},
    }])
    if status != "PASS":
        raise RuntimeError(f"synthetic validation failed: {checks}")
    return payload


def load_frozen_references() -> tuple[int, dict[str, str]]:
    result_rows = csv_rows(FINAL_CSV)
    result = next((row for row in result_rows if (row["workload"], row["layer"]) == TARGET), None)
    if result is None or result["dense_status"] != "SUCCESS" or result["sparse_status"] != "SUCCESS":
        raise RuntimeError("existing final dense/sparse pilot-layer references are not both successful")
    audit_rows = csv_rows(PE_AUDIT_CSV)
    audit = next((row for row in audit_rows if row["model"] == "resnet18" and row["dataset"] == "cifar10" and row["layer"] == "layer1.0.conv1"), None)
    if audit is None or audit["same_pe"] != "PASS":
        raise RuntimeError("frozen Stage 13.1 PE audit row is missing or invalid")
    selected_pe = int(audit["frozen_selected_pe"])
    if selected_pe != int(result["selected_pe"]) or selected_pe != 32:
        raise RuntimeError("pilot PE differs from frozen Stage 13.1 selected PE=32")
    return selected_pe, result


def load_one_image_and_capture_layer() -> tuple[torch.Tensor, torch.Tensor, torch.nn.Conv2d, int]:
    from common import CifarDataset, make_model

    checkpoint = STAGE12 / "checkpoints" / "resnet18_cifar10_best.pt"
    if not checkpoint.is_file():
        raise FileNotFoundError(checkpoint)
    payload = torch.load(checkpoint, map_location="cpu", weights_only=False)
    model = make_model("resnet18", 10)
    model.load_state_dict(payload["model_state_dict"], strict=True)
    model.eval()
    dataset = CifarDataset("cifar10", train=False)
    image, label = dataset[0]

    target_module = dict(model.named_modules())["layer1.0.conv1"]
    captured: dict[str, torch.Tensor] = {}

    def capture(_module: torch.nn.Module, inputs: tuple[torch.Tensor, ...], output: torch.Tensor) -> None:
        if "input" in captured:
            raise RuntimeError("target convolution executed more than once for one image")
        captured["input"] = inputs[0].detach().cpu()
        captured["output"] = output.detach().cpu()

    handle = target_module.register_forward_hook(capture)
    try:
        with torch.no_grad():
            model(image.unsqueeze(0))
    finally:
        handle.remove()
    if "input" not in captured or "output" not in captured:
        raise RuntimeError("target layer did not execute")
    return captured["input"], captured["output"], target_module, int(label)


def run_real_layer_validation() -> dict[str, Any]:
    selected_pe, result_row = load_frozen_references()
    layer_input, model_output, module, label = load_one_image_and_capture_layer()
    if tuple(layer_input.shape) != (1, 64, 32, 32):
        raise RuntimeError(f"unexpected target input shape: {tuple(layer_input.shape)}")
    if module.out_channels != 64:
        raise RuntimeError(f"unexpected output-channel count: {module.out_channels}")

    mask_file = np.load(MASK, mmap_mode="r")
    if tuple(mask_file.shape) != (10240000, 576):
        raise RuntimeError(f"validated full mask shape changed: {mask_file.shape}")
    one_image_mask = np.asarray(mask_file[:1024])
    if one_image_mask.shape != (1024, 576) or not np.all((one_image_mask == 0) | (one_image_mask == 1)):
        raise RuntimeError("first-image mask slice is malformed or non-binary")

    unfolded_tensor = F.unfold(
        layer_input,
        kernel_size=module.kernel_size,
        dilation=module.dilation,
        padding=module.padding,
        stride=module.stride,
    ).squeeze(0).transpose(0, 1).contiguous()
    unfolded = unfolded_tensor.numpy()
    mask_matches_input = np.array_equal(one_image_mask, unfolded != 0)
    if not mask_matches_input:
        raise RuntimeError("first-image validated mask does not match exact-zero unfolded activations")

    weights = module.weight.detach().cpu().reshape(module.out_channels, -1).transpose(0, 1).contiguous().numpy()
    bias = module.bias.detach().cpu() if module.bias is not None else None
    dense_conv = F.conv2d(
        layer_input,
        module.weight.detach().cpu(),
        bias,
        stride=module.stride,
        padding=module.padding,
        dilation=module.dilation,
        groups=module.groups,
    )
    actual_flat = model_output.squeeze(0).permute(1, 2, 0).reshape(-1, module.out_channels).numpy()
    dense_conv_flat = dense_conv.squeeze(0).permute(1, 2, 0).reshape(-1, module.out_channels).numpy()
    dense_matmul = unfolded @ weights
    if bias is not None:
        dense_matmul += bias.numpy()
    if not np.allclose(dense_matmul, dense_conv_flat, rtol=1e-4, atol=1e-4):
        raise RuntimeError("unfolded dense matrix reference disagrees with PyTorch convolution")

    schedule = build_sparse_ws_schedule(one_image_mask, module.out_channels, array_rows=4, array_cols=8)
    sparse_output = execute_sparse_ws(unfolded, weights, one_image_mask, schedule)
    max_abs_error = float(np.max(np.abs(sparse_output - actual_flat)))
    numerical_match = (
        sparse_output.shape == actual_flat.shape
        and actual_flat.shape == dense_conv_flat.shape
        and bool(np.allclose(sparse_output, actual_flat, rtol=1e-4, atol=1e-4))
        and bool(np.allclose(dense_conv_flat, actual_flat, rtol=1e-5, atol=1e-5))
    )

    report_path = Path(result_row["dense_report_path"])
    dense_report = read_one_report_row(report_path)
    dense_compute_cycles = int(float(dense_report["Total Cycles"]))
    active_entries = int(one_image_mask.sum())
    dense_macs = int(one_image_mask.size * module.out_channels)
    useful_macs = int(active_entries * module.out_channels)
    skipped_macs = dense_macs - useful_macs
    if (useful_macs != schedule.useful_macs or skipped_macs != schedule.skipped_macs
            or useful_macs + skipped_macs != dense_macs):
        raise RuntimeError("real-layer MAC counts do not conserve the dense reference")
    if schedule.cycles == schedule.analytical_lower_bound:
        raise RuntimeError("compute schedule cycle source fell back to analytical MAC/PE bound")

    status = "PASS" if mask_matches_input and numerical_match else "FAIL"
    payload = {
        "workload": TARGET[0],
        "layer": TARGET[1],
        "label": label,
        "selected_pe": selected_pe,
        "array_rows": 4,
        "array_cols": 8,
        "mask_path": str(MASK),
        "mask_shape": list(one_image_mask.shape),
        "active_mask_entries": active_entries,
        "dense_macs": dense_macs,
        "useful_macs": useful_macs,
        "skipped_macs": skipped_macs,
        "sparse_compute_cycles": schedule.cycles,
        "dense_compute_cycles": dense_compute_cycles,
        "analytical_lower_bound_label": "ANALYTICAL LOWER BOUND",
        "analytical_lower_bound_cycles": math.ceil(useful_macs / 32),
        "schedule_cycle_model": "phase_a_ws_compute_only; no native memory service",
        "dense_cycle_report": str(report_path),
        "mask_match": mask_matches_input,
        "output_shape": list(sparse_output.shape),
        "max_abs_error": max_abs_error,
        "numerical_match": numerical_match,
        "status": status,
    }
    write_json(OUTPUT / "real_layer_validation.json", payload)
    fields = [
        "workload", "layer", "selected_pe", "array_rows", "array_cols", "mask_path", "mask_shape",
        "active_mask_entries", "dense_macs", "useful_macs", "skipped_macs", "dense_compute_cycles",
        "sparse_compute_cycles", "analytical_lower_bound_label", "analytical_lower_bound_cycles",
        "schedule_cycle_model", "dense_cycle_report", "mask_match", "output_shape", "max_abs_error",
        "numerical_match", "status",
    ]
    write_csv(OUTPUT / "real_layer_validation.csv", fields, [payload])
    if status != "PASS":
        raise RuntimeError("real-layer validation failed")
    return payload


def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    synthetic = run_synthetic_validation()
    real = run_real_layer_validation()
    print(f"synthetic_status={synthetic['status']}")
    print(f"real_layer_status={real['status']}")
    print(f"sparse_compute_cycles={real['sparse_compute_cycles']}")
    print(f"analytical_lower_bound={real['analytical_lower_bound_cycles']}")
    print(f"max_abs_error={real['max_abs_error']}")
    print("PHASE_A_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())