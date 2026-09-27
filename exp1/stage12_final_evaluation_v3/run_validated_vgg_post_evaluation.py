#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import torch
from torch import nn

from common import CifarDataset, CifarVgg16Canonical, seed_everything
from evaluate_models import evaluate_pair

ROOT = Path(__file__).resolve().parent
CHECKPOINTS = ROOT / "checkpoints"
LOGS = ROOT / "logs"
DEFAULT_OUTPUT_DIR = ROOT / "post_eval_cifar10_final"
SEED = 42

REQUIRED_KEYS = {
    "dense_correct",
    "sparse_correct",
    "dense_accuracy",
    "sparse_accuracy",
    "test_samples",
    "mean_activation_sparsity",
    "dense_MACs",
    "useful_MACs",
    "MAC_reduction_percent",
    "fixed64_dense_cycles",
    "fixed64_sparse_cycles",
    "fixed64_cycle_reduction_percent",
    "adaptive_cycles",
    "average_active_PEs",
}


def validate_result(result: dict) -> None:
    if not isinstance(result, dict):
        raise TypeError(f"Expected evaluation dict, got {type(result).__name__}")
    missing = sorted(key for key in REQUIRED_KEYS if key not in result)
    if missing:
        available = sorted(result.keys())
        raise KeyError(f"Evaluation result missing required field(s): {missing}. Available keys: {available}")
    assert "dense_correct" in result, "Result must include dense_correct"
    assert "sparse_correct" in result, "Result must include sparse_correct"


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        path.write_text("")
        return
    fields = list(rows[0].keys())
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def collect_per_sample_rows(checkpoint_path: Path, dataset_name: str, limit: int | None = None) -> tuple[list[dict], dict]:
    seed_everything(SEED)
    payload = torch.load(checkpoint_path, map_location="cpu")
    model = CifarVgg16Canonical(10 if dataset_name == "cifar10" else 100).to("cuda" if torch.cuda.is_available() else "cpu")
    model.load_state_dict(payload["model_state_dict"], strict=True)
    model.eval()
    dataset = CifarDataset(dataset_name, train=False, augment=False)
    if limit is not None:
        dataset = torch.utils.data.Subset(dataset, list(range(min(limit, len(dataset)))))
    loader = torch.utils.data.DataLoader(dataset, batch_size=128, shuffle=False, num_workers=0)
    rows: list[dict] = []
    dense_correct = 0
    sparse_correct = 0
    total = 0
    mismatches = 0
    with torch.no_grad():
        for images, labels in loader:
            images, labels = images.to(model.device if hasattr(model, "device") else next(model.parameters()).device), labels.to(next(model.parameters()).device)
            dense_logits = model(images)
            convs = [module for _, module in model.named_modules() if isinstance(module, nn.Conv2d)]
            sparse_hooks = []
            for module in convs:
                def _hook(_module, inputs):
                    value = inputs[0]
                    return (value.masked_fill(value == 0, 0),)
                sparse_hooks.append(module.register_forward_pre_hook(_hook))
            sparse_logits = model(images)
            for hook in sparse_hooks:
                hook.remove()
            dense_pred = dense_logits.argmax(1)
            sparse_pred = sparse_logits.argmax(1)
            dense_correct += int((dense_pred == labels).sum())
            sparse_correct += int((sparse_pred == labels).sum())
            mismatches += int((dense_pred != sparse_pred).sum())
            total += labels.numel()
            for index, label in enumerate(labels.tolist()):
                sample_rows = {
                    "sample_index": total - labels.numel() + index,
                    "ground_truth": int(label),
                    "dense_prediction": int(dense_pred[index].item()),
                    "sparse_prediction": int(sparse_pred[index].item()),
                    "dense_correct": bool(int(dense_pred[index].item()) == int(label)),
                    "sparse_correct": bool(int(sparse_pred[index].item()) == int(label)),
                    "prediction_mismatch": bool(int(dense_pred[index].item()) != int(sparse_pred[index].item())),
                }
                rows.append(sample_rows)
    summary = {
        "dense_correct": dense_correct,
        "sparse_correct": sparse_correct,
        "dense_accuracy": dense_correct / max(total, 1),
        "sparse_accuracy": sparse_correct / max(total, 1),
        "test_samples": total,
        "prediction_mismatches": mismatches,
    }
    return rows, summary


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the validated VGG16 post-evaluation and save a robust result manifest.")
    parser.add_argument("--checkpoint", type=Path, default=CHECKPOINTS / "vgg16_cifar10_best.pt")
    parser.add_argument("--dataset", choices=("cifar10", "cifar100"), default="cifar10")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--limit", type=int, default=None, help="Optional sample cap for smoke-test mode.")
    args = parser.parse_args()

    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    _, _, evaluation = evaluate_pair("vgg16", args.dataset, limit=args.limit)
    validate_result(evaluation)

    training_summary_path = LOGS / f"vgg16_{args.dataset}_training_summary.json"
    training_summary = json.loads(training_summary_path.read_text()) if training_summary_path.exists() else {}

    summary = {
        "model": evaluation["model"],
        "dataset": evaluation["dataset"],
        "status": evaluation["status"],
        "checkpoint_path": str(args.checkpoint),
        "checkpoint_epoch": int(training_summary.get("best_epoch", 0)),
        "validation_accuracy_used_for_selection": float(training_summary.get("best_validation_accuracy", 0.0)),
        "test_sample_count": int(evaluation["test_samples"]),
        "dense_accuracy": float(evaluation["dense_accuracy"]),
        "sparse_accuracy": float(evaluation["sparse_accuracy"]),
        "dense_correct": int(evaluation["dense_correct"]),
        "sparse_correct": int(evaluation["sparse_correct"]),
        "dense_vs_sparse_prediction_mismatch_count": int(evaluation["prediction_mismatches"]),
        "mean_activation_sparsity": float(evaluation["mean_activation_sparsity"]),
        "MAC_reduction": float(evaluation["MAC_reduction_percent"]),
        "fixed64_sparse_analytical_cycles": int(evaluation["fixed64_sparse_cycles"]),
        "adaptive_sparse_analytical_cycles": int(evaluation["adaptive_cycles"]),
        "average_active_PE_allocation": float(evaluation["average_active_PEs"]),
    }

    per_sample_rows, _ = collect_per_sample_rows(args.checkpoint, args.dataset, limit=args.limit)
    write_csv(output_dir / "per_sample_results.csv", per_sample_rows)
    (output_dir / "final_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    write_csv(output_dir / "final_summary.csv", [summary])

    manifest_lines = [
        f"checkpoint path: {summary['checkpoint_path']}",
        f"checkpoint epoch: {summary['checkpoint_epoch']}",
        f"validation accuracy used for selection: {summary['validation_accuracy_used_for_selection']}",
        f"test sample count: {summary['test_sample_count']}",
        f"model: {summary['model']}",
        f"dataset: {summary['dataset']}",
        "seed: 42",
        "policy: exact-zero activation masking with dense-vs-sparse comparison",
        "epsilon values: see CONFIG.yaml",
        f"evaluation code version/path: {__file__}",
    ]
    (output_dir / "evaluation_manifest.txt").write_text("\n".join(manifest_lines) + "\n")
    log_lines = [
        f"dataset={summary['dataset']}",
        f"dense_accuracy={summary['dense_accuracy']:.6f}",
        f"sparse_accuracy={summary['sparse_accuracy']:.6f}",
        f"dense_correct={summary['dense_correct']} / {summary['test_sample_count']}",
        f"sparse_correct={summary['sparse_correct']} / {summary['test_sample_count']}",
        f"mean_activation_sparsity={summary['mean_activation_sparsity']:.6f}",
        f"MAC_reduction={summary['MAC_reduction']:.6f}",
        f"fixed64_sparse_analytical_cycles={summary['fixed64_sparse_analytical_cycles']}",
        f"adaptive_sparse_analytical_cycles={summary['adaptive_sparse_analytical_cycles']}",
        f"average_active_PE_allocation={summary['average_active_PE_allocation']:.6f}",
    ]
    (output_dir / "post_eval.log").write_text("\n".join(log_lines) + "\n")

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
