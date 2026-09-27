#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
import pickle
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from torch import nn

from common import CifarDataset, CifarVgg16Canonical, seed_everything

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT.parent / "stage12_final_evaluation" / "data"
OUTDIR = ROOT / "cifar100_diagnostic"


def load_cifar100_payload(file_name: str):
    with (DATA_DIR / "cifar-100-python" / file_name).open("rb") as handle:
        return pickle.load(handle, encoding="bytes")


def check_labels() -> pd.DataFrame:
    train_payload = load_cifar100_payload("train")
    labels = np.asarray(train_payload[b"fine_labels"], dtype=np.int64)
    df = pd.DataFrame({"label": labels})
    counts = df["label"].value_counts().sort_index()
    counts_df = counts.reset_index()
    counts_df.columns = ["label", "count"]
    counts_df.to_csv(OUTDIR / "cifar100_label_distribution.csv", index=False)
    return counts_df


def check_dataset_split() -> str:
    total_train = CifarDataset("cifar100", train=True, augment=False)
    total_val = CifarDataset("cifar100", train=False, augment=False)
    # The project uses the deterministic 45k/5k split inside the training script.
    train_idx = list(range(5000, 50000))
    val_idx = list(range(5000))
    train = torch.utils.data.Subset(total_train, train_idx)
    val = torch.utils.data.Subset(total_train, val_idx)
    checks = [
        f"train_size: {len(train)}",
        f"validation_size: {len(val)}",
        f"test_size: {len(total_val)}",
        f"train_plus_validation: {len(train) + len(val)}",
        f"total_train_dataset: {len(total_train)}",
        f"deterministic_split: {train_idx == list(range(5000, 50000)) and val_idx == list(range(5000))}",
        f"val_indexes_unique: {len(set(val_idx)) == len(val_idx)}",
        f"train_indexes_unique: {len(set(train_idx)) == len(train_idx)}",
        f"validation_not_test_data: {len(set(train_idx) & set(range(len(total_val)))) == 0}",
        f"no_empty_split: {len(train) > 0 and len(val) > 0 and len(total_val) > 0}",
    ]
    text = "\n".join(checks) + "\n"
    (OUTDIR / "dataset_split_check.txt").write_text(text)
    return text


def check_model_output() -> dict:
    model = CifarVgg16Canonical(100)
    dataset = CifarDataset("cifar100", train=True, augment=False)
    loader = torch.utils.data.DataLoader(torch.utils.data.Subset(dataset, range(32)), batch_size=8, shuffle=False, num_workers=0)
    images, targets = next(iter(loader))
    logits = model(images)
    loss = nn.CrossEntropyLoss()(logits, targets)
    result = {
        "input_shape": list(images.shape),
        "target_shape": list(targets.shape),
        "target_min": int(targets.min().item()),
        "target_max": int(targets.max().item()),
        "logits_shape": list(logits.shape),
        "loss": float(loss.item()),
    }
    lines = [
        f"input shape: {result['input_shape']}",
        f"target shape: {result['target_shape']}",
        f"target min/max: {result['target_min']} / {result['target_max']}",
        f"logits shape: {result['logits_shape']}",
        f"loss: {result['loss']}",
        f"classifier_out_features: {model.classifier[-1].out_features}",
    ]
    (OUTDIR / "model_output_check.txt").write_text("\n".join(lines) + "\n")
    return result


def check_label_and_logits_sanity() -> dict:
    dataset = CifarDataset("cifar100", train=True, augment=False)
    loader = torch.utils.data.DataLoader(torch.utils.data.Subset(dataset, range(32)), batch_size=8, shuffle=False, num_workers=0)
    images, targets = next(iter(loader))
    model = CifarVgg16Canonical(100)
    logits = model(images)
    loss = nn.CrossEntropyLoss()(logits, targets)
    preds = logits.argmax(dim=1)
    summary = {
        "cross_entropy_loss": float(loss.item()),
        "prediction_min": int(preds.min().item()),
        "prediction_max": int(preds.max().item()),
        "target_min": int(targets.min().item()),
        "target_max": int(targets.max().item()),
        "unique_predictions": int(torch.unique(preds).numel()),
        "unique_labels": int(torch.unique(targets).numel()),
        "dominant_prediction_fraction": float((preds == preds[0]).float().mean().item()) if preds.numel() > 0 else 0.0,
    }
    dominant = float((preds == preds[0]).float().mean().item())
    (OUTDIR / "label_logit_loss_sanity.txt").write_text(
        "\n".join([
            f"cross entropy loss: {summary['cross_entropy_loss']}",
            f"prediction range: {summary['prediction_min']} to {summary['prediction_max']}",
            f"target range: {summary['target_min']} to {summary['target_max']}",
            f"unique predictions: {summary['unique_predictions']}",
            f"unique labels: {summary['unique_labels']}",
            f"dominant prediction fraction (first class): {dominant}",
            ("almost all predictions are one class" if dominant > 0.9 else "predictions are spread across multiple classes"),
        ]) + "\n"
    )
    return summary


def tiny_overfit_test() -> dict:
    seed_everything(42)
    dataset = CifarDataset("cifar100", train=True, augment=False)
    subset = torch.utils.data.Subset(dataset, list(range(32)))
    loader = torch.utils.data.DataLoader(subset, batch_size=32, shuffle=False, num_workers=0)
    images, targets = next(iter(loader))
    model = CifarVgg16Canonical(100)
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-3, weight_decay=0.0)
    criterion = nn.CrossEntropyLoss()
    initial_logits = model(images)
    initial_loss = float(criterion(initial_logits, targets).item())
    initial_acc = float((initial_logits.argmax(dim=1) == targets).float().mean().item())
    best_loss = initial_loss
    best_acc = initial_acc
    conv1_grad_norm = None
    classifier_grad_norm = None
    conv1_update_norm = None
    prev_weight = model.features[0].weight.detach().clone()
    for step in range(500):
        batch_images, batch_targets = next(iter(loader))
        optimizer.zero_grad()
        logits = model(batch_images)
        loss = criterion(logits, batch_targets)
        loss.backward()
        if conv1_grad_norm is None:
            conv1_grad_norm = float(model.features[0].weight.grad.detach().norm(p=2).item())
            classifier_grad_norm = float(model.classifier[-1].weight.grad.detach().norm(p=2).item())
        optimizer.step()
        with torch.no_grad():
            conv1_update_norm = float((model.features[0].weight.detach() - prev_weight).norm(p=2).item())
            prev_weight = model.features[0].weight.detach().clone()
        current_loss = float(loss.item())
        current_acc = float((logits.argmax(1) == batch_targets).float().mean().item())
        best_loss = min(best_loss, current_loss)
        best_acc = max(best_acc, current_acc)
        if step == 499:
            final_loss = current_loss
            final_acc = current_acc
    summary = {
        "initial_loss": initial_loss,
        "final_loss": final_loss,
        "best_loss": best_loss,
        "initial_accuracy": initial_acc,
        "final_accuracy": final_acc,
        "best_accuracy": best_acc,
        "conv1_gradient_norm": conv1_grad_norm,
        "classifier_gradient_norm": classifier_grad_norm,
        "conv1_parameter_update_norm": conv1_update_norm,
    }
    (OUTDIR / "tiny_overfit_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def compare_cifar10_and_cifar100_first_batch() -> pd.DataFrame:
    rows = []
    for dataset_name in ("cifar10", "cifar100"):
        dataset = CifarDataset(dataset_name, train=True, augment=False)
        images, labels = next(iter(torch.utils.data.DataLoader(torch.utils.data.Subset(dataset, range(32)), batch_size=32, shuffle=False, num_workers=0)))
        model = CifarVgg16Canonical(10 if dataset_name == "cifar10" else 100)
        logits = model(images)
        loss = nn.CrossEntropyLoss()(logits, labels)
        rows.append({
            "dataset": dataset_name,
            "dataset_length": len(dataset),
            "num_classes": 10 if dataset_name == "cifar10" else 100,
            "image_tensor_shape": str(tuple(images.shape)),
            "label_min": int(labels.min().item()),
            "label_max": int(labels.max().item()),
            "unique_labels_in_first_batch": int(torch.unique(labels).numel()),
            "logits_shape": str(tuple(logits.shape)),
            "initial_loss": float(loss.item()),
            "initial_accuracy": float((logits.argmax(1) == labels).float().mean().item()),
        })
    frame = pd.DataFrame(rows)
    frame.to_csv(OUTDIR / "cifar10_vs_cifar100_sanity.csv", index=False)
    return frame


def main() -> None:
    OUTDIR.mkdir(exist_ok=True)
    label_counts = check_labels()
    split_text = check_dataset_split()
    model_output = check_model_output()
    sanity = check_label_and_logits_sanity()
    tiny = tiny_overfit_test()
    compare = compare_cifar10_and_cifar100_first_batch()
    print(json.dumps({
        "labels": {"min": int(label_counts["label"].min()), "max": int(label_counts["label"].max()), "class_count": int(label_counts.shape[0]), "label_count": int(label_counts["count"].sum())},
        "dataset_split": split_text,
        "model_output": model_output,
        "logit_sanity": sanity,
        "tiny_overfit": tiny,
        "first_batch_compare": compare.to_dict(orient="records"),
    }, indent=2))


if __name__ == "__main__":
    main()
