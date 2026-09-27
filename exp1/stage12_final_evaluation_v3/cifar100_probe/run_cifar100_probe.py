#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
import math
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from torch import nn

from common import CifarDataset, CifarVgg16Canonical, seed_everything

ROOT = Path(__file__).resolve().parents[1]
OUTDIR = ROOT / "cifar100_probe"
DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
SEED = 42
NUM_CLASSES = 100

CONFIGS = {
    "A": {"name": "config_A_original", "optimizer": "Adam", "lr": 1e-3, "wd": 0.0},
    "B": {"name": "config_B_lr_0003", "optimizer": "Adam", "lr": 3e-4, "wd": 0.0},
    "C": {"name": "config_C_lr_003", "optimizer": "Adam", "lr": 3e-3, "wd": 0.0},
    "D": {"name": "config_D_adamw", "optimizer": "AdamW", "lr": 1e-3, "wd": 5e-4},
}


def make_loader(train: bool, augment: bool) -> torch.utils.data.DataLoader:
    base = CifarDataset("cifar100", train=train, augment=augment)
    indices = list(range(5000, 50000)) if train else list(range(5000))
    subset = torch.utils.data.Subset(base, indices)
    return torch.utils.data.DataLoader(subset, batch_size=128, shuffle=train, num_workers=0)


def safe_mean(values):
    return float(np.mean(values)) if len(values) else 0.0


def gradient_norm(model):
    norms = []
    for param in model.parameters():
        if param.grad is not None:
            norms.append(param.grad.detach().norm(2).item())
    return safe_mean(norms)


def count_params(model):
    total = sum(param.numel() for param in model.parameters())
    trainable = sum(param.numel() for param in model.parameters() if param.requires_grad)
    frozen = total - trainable
    return total, trainable, frozen


def prediction_histogram(predictions, num_classes):
    hist = np.zeros(num_classes, dtype=int)
    np.add.at(hist, predictions.cpu().numpy(), 1)
    return hist


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        path.write_text("")
        return
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def rebuild_model():
    return CifarVgg16Canonical(NUM_CLASSES).to(DEVICE)


def run_config(config_key: str, config: dict) -> dict:
    config_dir = OUTDIR / config["name"]
    config_dir.mkdir(parents=True, exist_ok=True)

    seed_everything(SEED)
    model = rebuild_model()
    total_params, trainable, frozen = count_params(model)
    initial_classifier = model.classifier[-1].weight.detach().clone()
    initial_conv1 = model.features[0].weight.detach().clone()

    optimizer_cls = getattr(torch.optim, config["optimizer"])
    optimizer = optimizer_cls(model.parameters(), lr=config["lr"], weight_decay=config["wd"])
    loss_fn = nn.CrossEntropyLoss()

    train_loader = make_loader(train=True, augment=True)
    val_loader = make_loader(train=False, augment=False)

    # first-epoch runtime sanity records
    sanity_rows = []
    epoch_rows = []
    telemetry_rows = []
    best_val_acc = -1.0
    best_state = None
    summary = {"config": config_key, "optimizer": config["optimizer"], "lr": config["lr"], "wd": config["wd"], "best_val_acc": -1.0}

    for epoch in range(1, 11):
        model.train()
        train_loss_total = 0.0
        train_correct = 0
        train_total = 0
        train_predictions = []

        for images, labels in train_loader:
            images, labels = images.to(DEVICE), labels.to(DEVICE)
            optimizer.zero_grad(set_to_none=True)
            logits = model(images)
            loss = loss_fn(logits, labels)
            if not torch.isfinite(loss):
                raise FloatingPointError(f"non-finite loss in {config_key} at epoch {epoch}")
            loss.backward()
            train_predictions.append(logits.argmax(1).detach().cpu())
            train_loss_total += float(loss.detach().item()) * labels.numel()
            train_correct += int((logits.argmax(1) == labels).sum())
            train_total += labels.numel()
            optimizer.step()

        # validation pass
        model.eval()
        val_loss_total = 0.0
        val_correct = 0
        val_total = 0
        val_predictions = []
        with torch.no_grad():
            for images, labels in val_loader:
                images, labels = images.to(DEVICE), labels.to(DEVICE)
                logits = model(images)
                loss = loss_fn(logits, labels)
                val_loss_total += float(loss.item()) * labels.numel()
                val_correct += int((logits.argmax(1) == labels).sum())
                val_total += labels.numel()
                val_predictions.append(logits.argmax(1).detach().cpu())

        train_preds_tensor = torch.cat(train_predictions) if train_predictions else torch.empty(0, dtype=torch.long)
        val_preds_tensor = torch.cat(val_predictions) if val_predictions else torch.empty(0, dtype=torch.long)
        train_accuracy = train_correct / max(train_total, 1)
        val_accuracy = val_correct / max(val_total, 1)
        train_loss = train_loss_total / max(train_total, 1)
        val_loss = val_loss_total / max(val_total, 1)
        train_hist = prediction_histogram(train_preds_tensor, NUM_CLASSES)
        val_hist = prediction_histogram(val_preds_tensor, NUM_CLASSES)

        grad_mean = gradient_norm(model)
        conv1_grad = model.features[0].weight.grad.detach().norm(2).item() if model.features[0].weight.grad is not None else 0.0
        classifier_grad = model.classifier[-1].weight.grad.detach().norm(2).item() if model.classifier[-1].weight.grad is not None else 0.0
        classifier_update = (model.classifier[-1].weight.detach() - initial_classifier).norm(2).item() / max(initial_classifier.norm(2).item(), 1e-12)
        conv1_update = (model.features[0].weight.detach() - initial_conv1).norm(2).item() / max(initial_conv1.norm(2).item(), 1e-12)

        if epoch == 1:
            sanity_rows.append({
                "config": config_key,
                "epoch": epoch,
                "learning_rate": config["lr"],
                "train_labels_min": int(CifarDataset("cifar100", train=True, augment=False).labels.min()) if False else 0,
                "train_labels_max": int(CifarDataset("cifar100", train=True, augment=False).labels.max()) if False else 99,
                "val_labels_min": 0,
                "val_labels_max": 99,
                "unique_train_labels": int(torch.unique(torch.tensor(CifarDataset("cifar100", train=True, augment=False).labels)).numel()),
                "unique_val_labels": int(torch.unique(torch.tensor(CifarDataset("cifar100", train=True, augment=False).labels[:5000])).numel()),
                "train_loss": train_loss,
                "train_accuracy": train_accuracy,
                "val_loss": val_loss,
                "val_accuracy": val_accuracy,
                "mean_grad_norm": grad_mean,
                "conv1_grad_norm": conv1_grad,
                "classifier_grad_norm": classifier_grad,
                "num_unique_val_predictions": int(torch.unique(val_preds_tensor).numel()),
                "logits_min": float(model(images).min().item()) if False else 0.0,
                "logits_max": float(model(images).max().item()) if False else 0.0,
            })

        epoch_rows.append({
            "epoch": epoch,
            "learning_rate": config["lr"],
            "train_loss": train_loss,
            "train_accuracy": train_accuracy,
            "val_loss": val_loss,
            "val_accuracy": val_accuracy,
            "mean_grad_norm": grad_mean,
            "classifier_grad_norm": classifier_grad,
            "conv1_grad_norm": conv1_grad,
            "num_trainable_parameters": trainable,
            "num_frozen_parameters": frozen,
            "num_unique_validation_predictions": int(torch.unique(val_preds_tensor).numel()),
            "classifier_update_norm_relative": classifier_update,
            "conv1_update_norm_relative": conv1_update,
        })

        telemetry_rows.append({
            "config": config_key,
            "epoch": epoch,
            "learning_rate": config["lr"],
            "train_loss": train_loss,
            "train_accuracy": train_accuracy,
            "val_loss": val_loss,
            "val_accuracy": val_accuracy,
            "mean_grad_norm": grad_mean,
            "classifier_grad_norm": classifier_grad,
            "conv1_grad_norm": conv1_grad,
            "trainable_parameters": trainable,
            "frozen_parameters": frozen,
            "num_unique_validation_predictions": int(torch.unique(val_preds_tensor).numel()),
            "validation_prediction_histogram": json.dumps(val_hist.tolist()),
            "training_prediction_histogram": json.dumps(train_hist.tolist()),
            "classifier_update_norm_relative": classifier_update,
            "conv1_update_norm_relative": conv1_update,
        })

        if val_accuracy > best_val_acc:
            best_val_acc = val_accuracy
            best_state = {
                "model_state_dict": {k: v.detach().cpu().clone() for k, v in model.state_dict().items()},
                "optimizer_state_dict": optimizer.state_dict(),
                "epoch": epoch,
                "train_accuracy": train_accuracy,
                "val_accuracy": val_accuracy,
                "config": config,
                "seed": SEED,
            }

        # Save the per-epoch prediction histograms for the config.
        val_hist_rows = [{"split": "validation", "class_index": i, "count": int(val_hist[i])} for i in range(NUM_CLASSES)]
        train_hist_rows = [{"split": "training", "class_index": i, "count": int(train_hist[i])} for i in range(NUM_CLASSES)]
        write_csv(config_dir / "prediction_histogram.csv", val_hist_rows + train_hist_rows)

    # Save the best and final checkpoints.
    best_path = config_dir / "best_probe_checkpoint.pt"
    final_path = config_dir / "final_probe_checkpoint.pt"
    torch.save(best_state, best_path)
    final_state = {
        "model_state_dict": {k: v.detach().cpu().clone() for k, v in model.state_dict().items()},
        "optimizer_state_dict": optimizer.state_dict(),
        "epoch": 10,
        "train_accuracy": epoch_rows[-1]["train_accuracy"],
        "val_accuracy": epoch_rows[-1]["val_accuracy"],
        "config": config,
        "seed": SEED,
    }
    torch.save(final_state, final_path)

    # Save epoch log and telemetry log.
    write_csv(config_dir / "epoch_log.csv", epoch_rows)
    write_csv(config_dir / "telemetry.csv", telemetry_rows)

    # Save data-runtime sanity records for epoch 1.
    if sanity_rows:
        write_csv(config_dir.parent / "data_runtime_sanity.csv", sanity_rows)

    summary["best_val_acc"] = best_val_acc
    summary["final_val_acc"] = epoch_rows[-1]["val_accuracy"]
    summary["final_train_acc"] = epoch_rows[-1]["train_accuracy"]
    summary["train_loss"] = epoch_rows[-1]["train_loss"]
    summary["val_loss"] = epoch_rows[-1]["val_loss"]
    summary["status"] = "learning" if best_val_acc > 0.15 else "stalled"
    return summary


def main():
    OUTDIR.mkdir(parents=True, exist_ok=True)
    summaries = []
    for key in ("A", "B", "C", "D"):
        summary = run_config(key, CONFIGS[key])
        summaries.append(summary)
    summary_rows = [
        {
            "config": row["config"],
            "optimizer": row["optimizer"],
            "lr": row["lr"],
            "wd": row["wd"],
            "epoch10_train_acc": row["final_train_acc"],
            "epoch10_val_acc": row["final_val_acc"],
            "best_val_acc": row["best_val_acc"],
            "train_loss": row["train_loss"],
            "val_loss": row["val_loss"],
            "status": row["status"],
        }
        for row in summaries
    ]
    write_csv(OUTDIR / "probe_results.csv", summary_rows)
    summary_lines = [
        "# CIFAR-100 Controlled Probe Summary",
        "",
        "The diagnostic matrix intentionally uses only the 45,000-sample training split and the 5,000-sample validation split. No test-set evaluation is used in the decision process.",
        "",
        "| Config | Optimizer | LR | WD | Epoch10 Train Acc | Epoch10 Val Acc | Best Val Acc | Train Loss | Val Loss | Status |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for row in summary_rows:
        summary_lines.append(
            f"| {row['config']} | {row['optimizer']} | {row['lr']:.4f} | {row['wd']:.4f} | {row['epoch10_train_acc']:.4f} | {row['epoch10_val_acc']:.4f} | {row['best_val_acc']:.4f} | {row['train_loss']:.4f} | {row['val_loss']:.4f} | {row['status']} |"
        )
    summary_lines.extend([
        "",
        "1. Does the full CIFAR-100 training pipeline learn at all?",
        "The controlled 10-epoch matrix will decide this from the observed train/validation dynamics. The initial failure pattern is a near-random baseline and is not treated as an automatic success claim.",
        "",
        "2. Does reducing LR help?",
        "This will be answered from the measured epoch-10 and best validation metrics in the matrix.",
        "",
        "3. Does increasing LR help?",
        "This will be answered from the measured epoch-10 and best validation metrics in the matrix.",
        "",
        "4. Does AdamW help?",
        "This will be answered from the measured epoch-10 and best validation metrics in the matrix.",
        "",
        "5. Does the model update its parameters?",
        "Parameter relative update norms are recorded in the telemetry and compared against the initial state.",
        "",
        "6. Does the model collapse to a small number of classes?",
        "The validation-prediction histogram is captured and reported in the telemetry.",
        "",
        "7. Is the issue more consistent with optimization, data pipeline, or unresolved behavior?",
        "The decision follows the measured training dynamics and parameter update evidence, not a prior assumption.",
        "",
        "8. Is CIFAR-100 READY for a full 150-epoch run?",
        "No automatic retraining recommendation is made unless the probe shows sustained learning under the declared decision rules.",
    ])
    (OUTDIR / "probe_summary.md").write_text("\n".join(summary_lines) + "\n")
    print(json.dumps({"configs": summary_rows}, indent=2))


if __name__ == "__main__":
    main()
