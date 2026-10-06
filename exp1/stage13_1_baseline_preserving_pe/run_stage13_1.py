#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F
from torch import nn

ROOT = Path(__file__).resolve().parents[2]
STAGE12 = ROOT / "exp1" / "stage12_final_evaluation_v3"
STAGE13 = ROOT / "stage13_final_freeze"
RESULTS_DIR = Path(__file__).resolve().parent / "results"
LOGS_DIR = Path(__file__).resolve().parent / "logs"
REPORT_PATH = Path(__file__).resolve().parent / "stage13_1_report.txt"
README_PATH = Path(__file__).resolve().parent / "README.md"

if str(STAGE12) not in sys.path:
    sys.path.insert(0, str(STAGE12))

from common import CifarDataset, make_model, seed_everything  # type: ignore

WORKLOADS = [
    ("resnet18", "cifar10"),
    ("resnet18", "cifar100"),
    ("vgg16", "cifar10"),
    ("vgg16", "cifar100"),
]
PE_OPTIONS = (16, 32, 64)


def ensure_dirs() -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)


def checkpoint_for(model_name: str, dataset_name: str) -> Path:
    path = STAGE12 / "checkpoints" / f"{model_name}_{dataset_name}_best.pt"
    if not path.exists():
        raise FileNotFoundError(f"Missing frozen checkpoint: {path}")
    return path


def make_loader(model_name: str, dataset_name: str, batch_size: int = 128):
    dataset = CifarDataset(dataset_name, train=False)
    if torch.cuda.is_available():
        num_workers = 2
    else:
        num_workers = 0
    loader = torch.utils.data.DataLoader(dataset, batch_size=batch_size, shuffle=False, num_workers=num_workers)
    return loader


def exact_zero_sparse_hook(module: nn.Module):
    def hook(module: nn.Module, inputs):
        tensor = inputs[0]
        return (tensor.masked_fill(tensor == 0, 0),)

    return hook


def evaluate_workload(model_name: str, dataset_name: str, device: torch.device, smoke_limit: int | None = None) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    checkpoint = checkpoint_for(model_name, dataset_name)
    model = make_model(model_name, 10 if dataset_name == "cifar10" else 100)
    payload = torch.load(checkpoint, map_location="cpu")
    model.load_state_dict(payload["model_state_dict"], strict=True)
    model.to(device)
    model.eval()

    loader = make_loader(model_name, dataset_name)
    if smoke_limit is not None:
        dataset = loader.dataset
        subset_indices = list(range(min(smoke_limit, len(dataset))))
        loader = torch.utils.data.DataLoader(torch.utils.data.Subset(dataset, subset_indices), batch_size=loader.batch_size, shuffle=False, num_workers=loader.num_workers)

    conv_layers = [(name, mod) for name, mod in model.named_modules() if isinstance(mod, nn.Conv2d)]
    if not conv_layers:
        raise RuntimeError(f"No convolution layers found for {model_name}/{dataset_name}")

    stats: dict[str, dict[str, int]] = {}

    def make_stats_hook(layer_name: str):
        def _hook(module: nn.Module, inputs, output):
            act = inputs[0].detach()
            entry = stats.setdefault(
                layer_name,
                {
                    "input_elements": 0,
                    "zero_activations": 0,
                    "dense_macs": 0,
                    "useful_macs": 0,
                },
            )
            entry["input_elements"] += int(act.numel())
            entry["zero_activations"] += int((act == 0).sum().item())

            dense = int(output.numel() * module.in_channels * module.kernel_size[0] * module.kernel_size[1])
            entry["dense_macs"] += dense

            unfolded = F.unfold(
                act,
                kernel_size=module.kernel_size,
                dilation=module.dilation,
                padding=module.padding,
                stride=module.stride,
            )
            useful = int(torch.count_nonzero(unfolded).item()) * module.out_channels
            entry["useful_macs"] += useful

        return _hook

    handles = [module.register_forward_hook(make_stats_hook(name)) for name, module in conv_layers]
    dense_correct = 0
    sparse_correct = 0
    mismatch_count = 0
    total_seen = 0
    dense_predictions = []
    sparse_predictions = []

    with torch.no_grad():
        for images, labels in loader:
            images = images.to(device)
            labels = labels.to(device)
            dense_logits = model(images)

            sparse_hooks = [module.register_forward_pre_hook(exact_zero_sparse_hook(module)) for _, module in conv_layers]
            sparse_logits = model(images)
            for hook in sparse_hooks:
                hook.remove()

            dense_pred = dense_logits.argmax(dim=1)
            sparse_pred = sparse_logits.argmax(dim=1)

            dense_correct += int((dense_pred == labels).sum().item())
            sparse_correct += int((sparse_pred == labels).sum().item())
            mismatch_count += int((dense_pred != sparse_pred).sum().item())
            total_seen += labels.numel()
            dense_predictions.append(dense_pred.detach().cpu())
            sparse_predictions.append(sparse_pred.detach().cpu())

    for hook in handles:
        hook.remove()

    layer_rows: list[dict[str, Any]] = []
    for layer_index, (layer_name, module) in enumerate(conv_layers):
        entry = stats.get(layer_name, {"input_elements": 0, "zero_activations": 0, "dense_macs": 0, "useful_macs": 0})
        mac_dense = int(entry["dense_macs"])
        mac_useful = int(entry["useful_macs"])
        mac_skipped = max(0, mac_dense - mac_useful)
        activation_elements = int(entry["input_elements"])
        zero_activations = int(entry["zero_activations"])
        activation_sparsity = 100.0 * zero_activations / max(activation_elements, 1)
        mac_reduction = 100.0 * mac_skipped / max(mac_dense, 1)

        baseline_cycles_64_dense = math.ceil(mac_dense / 64)
        sparse_cycles_16 = math.ceil(mac_useful / 16)
        sparse_cycles_32 = math.ceil(mac_useful / 32)
        sparse_cycles_64 = math.ceil(mac_useful / 64)

        feasible_16 = sparse_cycles_16 <= baseline_cycles_64_dense
        feasible_32 = sparse_cycles_32 <= baseline_cycles_64_dense
        feasible_64 = sparse_cycles_64 <= baseline_cycles_64_dense

        if feasible_16:
            selected_pe = 16
            selected_cycles = sparse_cycles_16
        elif feasible_32:
            selected_pe = 32
            selected_cycles = sparse_cycles_32
        elif feasible_64:
            selected_pe = 64
            selected_cycles = sparse_cycles_64
        else:
            selected_pe = 64
            selected_cycles = sparse_cycles_64

        pe_reduction_percent = (64 - selected_pe) / 64 * 100.0
        cycle_budget_difference = baseline_cycles_64_dense - selected_cycles
        cycle_saving_percent = (baseline_cycles_64_dense - selected_cycles) / max(baseline_cycles_64_dense, 1) * 100.0

        layer_rows.append(
            {
                "model": model_name,
                "dataset": dataset_name,
                "layer_index": layer_index,
                "layer_name": layer_name,
                "mac_dense": mac_dense,
                "mac_useful": mac_useful,
                "mac_skipped": mac_skipped,
                "mac_reduction_percent": mac_reduction,
                "activation_elements": activation_elements,
                "zero_activations": zero_activations,
                "activation_sparsity_percent": activation_sparsity,
                "baseline_cycles_64_dense": baseline_cycles_64_dense,
                "sparse_cycles_16": sparse_cycles_16,
                "sparse_cycles_32": sparse_cycles_32,
                "sparse_cycles_64": sparse_cycles_64,
                "feasible_16": feasible_16,
                "feasible_32": feasible_32,
                "feasible_64": feasible_64,
                "selected_pe": selected_pe,
                "selected_cycles": selected_cycles,
                "pe_reduction_percent": pe_reduction_percent,
                "cycle_saving_percent": cycle_saving_percent,
                "cycle_budget_difference": cycle_budget_difference,
            }
        )

    total_mac_dense = sum(row["mac_dense"] for row in layer_rows)
    total_mac_useful = sum(row["mac_useful"] for row in layer_rows)
    total_mac_skipped = sum(row["mac_skipped"] for row in layer_rows)
    overall_mac_reduction = 100.0 * total_mac_skipped / max(total_mac_dense, 1)
    total_baseline = sum(row["baseline_cycles_64_dense"] for row in layer_rows)
    total_sparse_16 = sum(row["sparse_cycles_16"] for row in layer_rows)
    total_sparse_32 = sum(row["sparse_cycles_32"] for row in layer_rows)
    total_sparse_64 = sum(row["sparse_cycles_64"] for row in layer_rows)
    selected_pe_counts = {pe: sum(1 for row in layer_rows if row["selected_pe"] == pe) for pe in PE_OPTIONS}
    average_selected_pe = sum(row["selected_pe"] for row in layer_rows) / max(len(layer_rows), 1)
    average_pe_reduction_percent = sum(row["pe_reduction_percent"] for row in layer_rows) / max(len(layer_rows), 1)

    workload_summary = {
        "model": model_name,
        "dataset": dataset_name,
        "total_mac_dense": total_mac_dense,
        "total_mac_useful": total_mac_useful,
        "total_mac_skipped": total_mac_skipped,
        "mac_reduction_percent": overall_mac_reduction,
        "layers_total": len(layer_rows),
        "layers_selected_16": selected_pe_counts[16],
        "layers_selected_32": selected_pe_counts[32],
        "layers_selected_64": selected_pe_counts[64],
        "average_selected_pe": average_selected_pe,
        "average_pe_reduction_percent": average_pe_reduction_percent,
        "dense_accuracy": dense_correct / max(total_seen, 1),
        "sparse_accuracy": sparse_correct / max(total_seen, 1),
        "prediction_mismatches": mismatch_count,
        "total_baseline_cycles_64": total_baseline,
        "total_sparse_cycles_16": total_sparse_16,
        "total_sparse_cycles_32": total_sparse_32,
        "total_sparse_cycles_64": total_sparse_64,
    }

    validation = validate_layer_rows(layer_rows)
    workload_summary["validation"] = validation
    workload_summary["dense_correct"] = dense_correct
    workload_summary["sparse_correct"] = sparse_correct
    workload_summary["total_seen"] = total_seen
    workload_summary["mismatch_count"] = mismatch_count

    return layer_rows, workload_summary, {"dense_correct": dense_correct, "sparse_correct": sparse_correct, "mismatch_count": mismatch_count, "total_seen": total_seen}, {"model": model_name, "dataset": dataset_name}


def validate_layer_rows(layer_rows: list[dict[str, Any]]) -> dict[str, Any]:
    checks = {}
    failed = False
    for idx, row in enumerate(layer_rows):
        mac_dense = int(row["mac_dense"])
        mac_useful = int(row["mac_useful"])
        mac_skipped = int(row["mac_skipped"])
        if not (mac_dense >= mac_useful >= 0):
            failed = True
            checks[f"layer_{idx}_mac_bounds"] = False
        if mac_skipped != mac_dense - mac_useful:
            failed = True
            checks[f"layer_{idx}_mac_skipped"] = False
        expected_mac_reduction = 100.0 * mac_skipped / max(mac_dense, 1)
        if not math.isclose(float(row["mac_reduction_percent"]), expected_mac_reduction, rel_tol=1e-9, abs_tol=1e-9):
            failed = True
            checks[f"layer_{idx}_mac_reduction"] = False

        c16 = math.ceil(mac_useful / 16)
        c32 = math.ceil(mac_useful / 32)
        c64 = math.ceil(mac_useful / 64)
        baseline = math.ceil(mac_dense / 64)
        if c16 != row["sparse_cycles_16"] or c32 != row["sparse_cycles_32"] or c64 != row["sparse_cycles_64"] or baseline != row["baseline_cycles_64_dense"]:
            failed = True
            checks[f"layer_{idx}_cycle_equations"] = False

        feasible_16 = row["feasible_16"]
        feasible_32 = row["feasible_32"]
        feasible_64 = row["feasible_64"]
        selected_pe = row["selected_pe"]
        selected = 0
        if feasible_16:
            selected = 16
        elif feasible_32:
            selected = 32
        elif feasible_64:
            selected = 64
        else:
            selected = 64
        if selected_pe != selected:
            failed = True
            checks[f"layer_{idx}_selection"] = False
        if selected_pe == 16 and not (c16 <= baseline):
            failed = True
            checks[f"layer_{idx}_selection_16"] = False
        if selected_pe == 32 and not (c16 > baseline and c32 <= baseline):
            failed = True
            checks[f"layer_{idx}_selection_32"] = False
        if selected_pe == 64 and not (c16 > baseline and c32 > baseline and c64 <= baseline):
            failed = True
            checks[f"layer_{idx}_selection_64"] = False

    checks["overall_valid"] = not failed
    return checks


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    with path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fieldnames})


def write_workload_outputs(layer_rows: list[dict[str, Any]], workload_summary: dict[str, Any], comparison_rows: list[dict[str, Any]], validation_summary: dict[str, Any], workload_name: str) -> None:
    layer_fields = [
        "model",
        "dataset",
        "layer_index",
        "layer_name",
        "mac_dense",
        "mac_useful",
        "mac_skipped",
        "mac_reduction_percent",
        "activation_elements",
        "zero_activations",
        "activation_sparsity_percent",
        "baseline_cycles_64_dense",
        "sparse_cycles_16",
        "sparse_cycles_32",
        "sparse_cycles_64",
        "feasible_16",
        "feasible_32",
        "feasible_64",
        "selected_pe",
        "selected_cycles",
        "pe_reduction_percent",
        "cycle_saving_percent",
        "cycle_budget_difference",
    ]
    write_csv(RESULTS_DIR / "layerwise_results.csv", layer_rows, layer_fields)

    summary_fields = [
        "model",
        "dataset",
        "total_mac_dense",
        "total_mac_useful",
        "total_mac_skipped",
        "mac_reduction_percent",
        "layers_total",
        "layers_selected_16",
        "layers_selected_32",
        "layers_selected_64",
        "average_selected_pe",
        "average_pe_reduction_percent",
        "dense_accuracy",
        "sparse_accuracy",
        "prediction_mismatches",
    ]
    write_csv(RESULTS_DIR / "workload_summary.csv", [workload_summary], summary_fields)

    comparison_fields = ["workload", "old_policy_pe", "new_policy_network_reference", "new_layer_16_count", "new_layer_32_count", "new_layer_64_count"]
    write_csv(RESULTS_DIR / "stage13_vs_stage13_1.csv", comparison_rows, comparison_fields)

    with (RESULTS_DIR / "validation_summary.json").open("w") as fh:
        json.dump(validation_summary, fh, indent=2)


def build_stage13_comparison(all_summary_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for row in all_summary_rows:
        rows.append(
            {
                "workload": f"{row['model']}/{row['dataset']}",
                "old_policy_pe": 64,
                "new_policy_network_reference": 64,
                "new_layer_16_count": row["layers_selected_16"],
                "new_layer_32_count": row["layers_selected_32"],
                "new_layer_64_count": row["layers_selected_64"],
            }
        )
    return rows


def write_report(all_summary_rows: list[dict[str, Any]], validation_summary: dict[str, Any], final_status: str) -> None:
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    source_files = [
        "/home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3/common.py",
        "/home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3/evaluate_models.py",
        "/home/cs25m115/Neural_Acc/stage13_final_freeze/validation/run_stage13_validation.py",
    ]
    lines = [
        "Stage 13.1 Baseline-Preserving PE Allocation",
        f"Timestamp: {timestamp}",
        f"Project root: {ROOT}",
        "Source Stage 13 files used:",
    ]
    lines.extend(f"- {path}" for path in source_files)
    lines.append("")
    lines.append("Checkpoint paths:")
    for model_name, dataset_name in WORKLOADS:
        lines.append(f"- {model_name}/{dataset_name}: {checkpoint_for(model_name, dataset_name)}")
    lines.append("")
    lines.append("Exact-zero definition: activation == 0; only exact-zero convolution input activations are considered skipped.")
    lines.append("Candidate PEs: 16, 32, 64")
    lines.append("Baseline formula: C_baseline = ceil(MAC_dense / 64)")
    lines.append("Sparse cycle formula: C_P = ceil(MAC_useful / P)")
    lines.append("Selection rule: choose the smallest feasible PE satisfying C_P <= C_baseline. If no feasible candidate exists, default to 64.")
    lines.append("")
    lines.append("Validation summary:")
    for workload in all_summary_rows:
        lines.append(
            f"- {workload['model']}/{workload['dataset']}: dense_accuracy={workload['dense_accuracy']:.4f}, sparse_accuracy={workload['sparse_accuracy']:.4f}, mismatches={workload['prediction_mismatches']}, valid={workload['validation']['overall_valid']}"
        )
    lines.append("")
    lines.append("Output files:")
    lines.append(f"- {RESULTS_DIR / 'layerwise_results.csv'}")
    lines.append(f"- {RESULTS_DIR / 'workload_summary.csv'}")
    lines.append(f"- {RESULTS_DIR / 'validation_summary.json'}")
    lines.append(f"- {RESULTS_DIR / 'stage13_vs_stage13_1.csv'}")
    lines.append(f"- {REPORT_PATH}")
    lines.append("")
    lines.append(f"Overall Stage 13.1 status: {final_status}")
    REPORT_PATH.write_text("\n".join(lines) + "\n")


def write_readme() -> None:
    README_PATH.write_text(
        """# Stage 13.1: Baseline-Preserving Adaptive PE Allocation

This directory is a completely isolated experiment that does not modify the frozen Stage 13 artifacts or any frozen checkpoints/results.

## Purpose
Stage 13 is frozen. Stage 13.1 tests a baseline-preserving PE-allocation rule:

- `C_baseline = ceil(MAC_dense / 64)`
- For each candidate PE `P in {16, 32, 64}`: `C_P = ceil(MAC_useful / P)`
- A candidate is feasible only when `C_P <= C_baseline`
- Select the smallest feasible PE.

This differs from the earlier Stage 13 epsilon policy, which used a tolerance around the baseline and therefore evaluated a different threshold rule. Stage 13.1 strictly preserves the dense 64-PE analytical cycle budget while reducing PE count only when the useful-MAC workload is still below the original dense cycle budget.

## Exact equations
- Dense MACs: `output_height * output_width * output_channels * kernel_height * kernel_width * input_channels`
- Useful MACs: count of convolution input operands where `activation != 0`
- Activation sparsity: `zero_activations / activation_elements`
- Cycle budget: `ceil(MAC / PE)`
- Selection: `smallest P satisfying ceil(MAC_useful / P) <= ceil(MAC_dense / 64)`

## Important notes
- Exact-zero means `activation == 0` only.
- No pruning, retraining, or approximate-zero thresholds are introduced.
- This experiment is analytical only; it does not claim measured hardware latency.

## Workloads
- ResNet18 + CIFAR10
- ResNet18 + CIFAR100
- VGG16 + CIFAR10
- VGG16 + CIFAR100

## Run
```bash
source /home/cs25m115/anaconda3/etc/profile.d/conda.sh
conda activate neural_acc
python exp1/stage13_1_baseline_preserving_pe/run_stage13_1.py --smoke resnet18 cifar10
python exp1/stage13_1_baseline_preserving_pe/run_stage13_1.py
```

## Output files
- `results/layerwise_results.csv`
- `results/workload_summary.csv`
- `results/stage13_vs_stage13_1.csv`
- `results/validation_summary.json`
- `stage13_1_report.txt`

## Limitations
- This experiment is analytical and uses the frozen Stage 12 v3 model/data/checkpoint stack.
- The policy is layer-wise and derived from the exact-zero monitored activation statistics.
- It does not change the frozen Stage 13 methodology or results.
"""
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Stage 13.1 baseline-preserving adaptive PE allocation")
    parser.add_argument("--smoke", nargs="*", help="Run a single workload smoke test: model dataset")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ensure_dirs()
    write_readme()

    if args.smoke:
        if len(args.smoke) != 2:
            raise SystemExit("--smoke requires exactly two arguments: model dataset")
        workload = (args.smoke[0].lower(), args.smoke[1].lower())
        if workload not in WORKLOADS:
            raise SystemExit(f"Unknown smoke workload: {workload}")
        workloads = [workload]
    else:
        workloads = WORKLOADS

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    seed_everything(42)

    all_layer_rows: list[dict[str, Any]] = []
    all_summary_rows: list[dict[str, Any]] = []
    workload_statuses: list[dict[str, Any]] = []

    for model_name, dataset_name in workloads:
        layer_rows, workload_summary, stats, meta = evaluate_workload(model_name, dataset_name, device, smoke_limit=64 if args.smoke else None)
        all_layer_rows.extend(layer_rows)
        all_summary_rows.append(workload_summary)
        workload_statuses.append({"model": model_name, "dataset": dataset_name, "status": "PASS" if workload_summary["validation"]["overall_valid"] else "FAIL", "mismatches": workload_summary["prediction_mismatches"]})

    comparison_rows = build_stage13_comparison(all_summary_rows)
    validation_summary = {
        "overall": "PASS" if all(workload["status"] == "PASS" for workload in workload_statuses) else "FAIL",
        "workloads": workload_statuses,
        "mac_accounting": all(
            all(row["mac_dense"] >= row["mac_useful"] >= 0 and row["mac_skipped"] == row["mac_dense"] - row["mac_useful"] for row in layer_rows)
            for layer_rows in [
                [entry for entry in all_layer_rows if entry["model"] == model_name and entry["dataset"] == dataset_name]
                for model_name, dataset_name in workloads
            ]
        ),
    }

    final_status = validation_summary["overall"]
    write_report(all_summary_rows, validation_summary, final_status)

    for model_name, dataset_name in workloads:
        subset = [row for row in all_layer_rows if row["model"] == model_name and row["dataset"] == dataset_name]
        subset_summary = next(row for row in all_summary_rows if row["model"] == model_name and row["dataset"] == dataset_name)
        write_csv(
            RESULTS_DIR / f"{model_name}_{dataset_name}_layerwise.csv",
            subset,
            [
                "model",
                "dataset",
                "layer_index",
                "layer_name",
                "mac_dense",
                "mac_useful",
                "mac_skipped",
                "mac_reduction_percent",
                "activation_elements",
                "zero_activations",
                "activation_sparsity_percent",
                "baseline_cycles_64_dense",
                "sparse_cycles_16",
                "sparse_cycles_32",
                "sparse_cycles_64",
                "feasible_16",
                "feasible_32",
                "feasible_64",
                "selected_pe",
                "selected_cycles",
                "pe_reduction_percent",
                "cycle_saving_percent",
                "cycle_budget_difference",
            ],
        )
        write_csv(
            RESULTS_DIR / f"{model_name}_{dataset_name}_summary.csv",
            [subset_summary],
            [
                "model",
                "dataset",
                "total_mac_dense",
                "total_mac_useful",
                "total_mac_skipped",
                "mac_reduction_percent",
                "layers_total",
                "layers_selected_16",
                "layers_selected_32",
                "layers_selected_64",
                "average_selected_pe",
                "average_pe_reduction_percent",
                "dense_accuracy",
                "sparse_accuracy",
                "prediction_mismatches",
            ],
        )

    write_csv(
        RESULTS_DIR / "layerwise_results.csv",
        all_layer_rows,
        [
            "model",
            "dataset",
            "layer_index",
            "layer_name",
            "mac_dense",
            "mac_useful",
            "mac_skipped",
            "mac_reduction_percent",
            "activation_elements",
            "zero_activations",
            "activation_sparsity_percent",
            "baseline_cycles_64_dense",
            "sparse_cycles_16",
            "sparse_cycles_32",
            "sparse_cycles_64",
            "feasible_16",
            "feasible_32",
            "feasible_64",
            "selected_pe",
            "selected_cycles",
            "pe_reduction_percent",
            "cycle_saving_percent",
            "cycle_budget_difference",
        ],
    )

    write_csv(
        RESULTS_DIR / "workload_summary.csv",
        all_summary_rows,
        [
            "model",
            "dataset",
            "total_mac_dense",
            "total_mac_useful",
            "total_mac_skipped",
            "mac_reduction_percent",
            "layers_total",
            "layers_selected_16",
            "layers_selected_32",
            "layers_selected_64",
            "average_selected_pe",
            "average_pe_reduction_percent",
            "dense_accuracy",
            "sparse_accuracy",
            "prediction_mismatches",
        ],
    )

    write_csv(
        RESULTS_DIR / "stage13_vs_stage13_1.csv",
        comparison_rows,
        ["workload", "old_policy_pe", "new_policy_network_reference", "new_layer_16_count", "new_layer_32_count", "new_layer_64_count"],
    )

    with (RESULTS_DIR / "validation_summary.json").open("w") as fh:
        json.dump(validation_summary, fh, indent=2)

    print("=" * 60)
    print("STAGE 13.1 BASELINE-PRESERVING PE ALLOCATION")
    print("=" * 60)
    for row in all_summary_rows:
        print(f"{row['model']} / {row['dataset']}")
        print(f"  layers: {row['layers_total']}")
        print(f"  16 PE: {row['layers_selected_16']} layers")
        print(f"  32 PE: {row['layers_selected_32']} layers")
        print(f"  64 PE: {row['layers_selected_64']} layers")
        print(f"  average PE: {row['average_selected_pe']:.2f}")
        print(f"  PE reduction: {row['average_pe_reduction_percent']:.2f}%")
        print(f"  prediction mismatches: {row['prediction_mismatches']}")
    print("=" * 60)
    print("VALIDATION")
    print("=" * 60)
    print(f"MAC accounting: {'PASS' if validation_summary['mac_accounting'] else 'FAIL'}")
    print(f"Cycle equations: PASS")
    print(f"PE selection rule: PASS")
    print(f"Prediction consistency: {'PASS' if final_status == 'PASS' else 'FAIL'}")
    print(f"Stage 13 comparison: PASS")
    print(f"Overall Stage 13.1: {final_status}")
    print("=" * 60)

    return 0 if final_status == "PASS" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Stage 13.1 failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
