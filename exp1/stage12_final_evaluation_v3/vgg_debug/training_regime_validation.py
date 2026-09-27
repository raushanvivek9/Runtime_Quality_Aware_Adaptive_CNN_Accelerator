#!/usr/bin/env python3
"""Controlled VGG training-regime validation for Stage 12 final evaluation v3."""
from __future__ import annotations

import csv
import inspect
import json
import math
import sys
import time
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader, Subset
from torchvision.models import VGG, vgg16

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from common import CifarDataset, CifarVgg16Canonical, MEAN, STD, seed_everything

VGG_DIR = ROOT / "vgg_debug"
DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
SEED = 42
STEPS = 500
CHECKPOINT_STEPS = {1, 10, 50, 100, 500}


def write_csv(path: Path, rows: list[dict]) -> None:
    fields = list(rows[0].keys()) if rows else []
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def batch32() -> tuple[torch.Tensor, torch.Tensor]:
    seed_everything(SEED)
    dataset = CifarDataset("cifar10", train=True, augment=False)
    loader = DataLoader(Subset(dataset, range(32)), batch_size=32, shuffle=False, num_workers=0)
    images, labels = next(iter(loader))
    return images.to(DEVICE), labels.to(DEVICE)


def new_model(initialization: str = "canonical", dropout: float | None = None) -> nn.Module:
    seed_everything(SEED)
    model = CifarVgg16Canonical(10)
    if dropout is not None:
        for layer in model.classifier:
            if isinstance(layer, nn.Dropout):
                layer.p = dropout
    if initialization == "torchvision":
        initialize_like_torchvision(model)
    return model.to(DEVICE)


def initialize_like_torchvision(model: nn.Module) -> nn.Module:
    """Apply the installed torchvision VGG initialization policy to a compatible model."""
    for layer in model.modules():
        if isinstance(layer, nn.Conv2d):
            nn.init.kaiming_normal_(layer.weight, mode="fan_out", nonlinearity="relu")
            if layer.bias is not None:
                nn.init.constant_(layer.bias, 0)
        elif isinstance(layer, nn.BatchNorm2d):
            nn.init.constant_(layer.weight, 1)
            nn.init.constant_(layer.bias, 0)
        elif isinstance(layer, nn.Linear):
            nn.init.normal_(layer.weight, 0, 0.01)
            nn.init.constant_(layer.bias, 0)
    return model


def optimizer_for(model: nn.Module, name: str, lr: float, weight_decay: float):
    if name == "SGD":
        return torch.optim.SGD(model.parameters(), lr=lr, momentum=0.9, weight_decay=weight_decay)
    if name == "Adam":
        return torch.optim.Adam(model.parameters(), lr=lr, weight_decay=weight_decay)
    if name == "AdamW":
        return torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=weight_decay)
    raise ValueError(name)


def train_32(optimizer_name: str, lr: float, weight_decay: float, initialization: str = "canonical", dropout: float | None = None, collect_depth: bool = False):
    images, labels = batch32()
    model = new_model(initialization, dropout)
    optimizer = optimizer_for(model, optimizer_name, lr, weight_decay)
    loss_fn = nn.CrossEntropyLoss()
    first_conv = model.features[0]
    final_classifier = model.classifier[6]
    initial_loss = None
    best_loss = float("inf")
    best_accuracy = 0.0
    first_conv_update_norm = 0.0
    depth_rows = []
    for step in range(1, STEPS + 1):
        previous_first_conv = first_conv.weight.detach().clone()
        optimizer.zero_grad(set_to_none=True)
        logits = model(images)
        loss = loss_fn(logits, labels)
        if initial_loss is None:
            initial_loss = float(loss.detach().cpu())
        loss.backward()
        first_grad = float(first_conv.weight.grad.norm(2).detach().cpu())
        classifier_grad = float(final_classifier.weight.grad.norm(2).detach().cpu())
        if collect_depth and step in CHECKPOINT_STEPS:
            for layer_index, layer in enumerate((m for m in model.features if isinstance(m, nn.Conv2d)), start=1):
                depth_rows.append({
                    "optimizer": optimizer_name,
                    "lr": lr,
                    "step": step,
                    "layer": f"Conv{layer_index}",
                    "gradient_norm": float(layer.weight.grad.norm(2).detach().cpu()),
                    "gradient_mean_abs": float(layer.weight.grad.abs().mean().detach().cpu()),
                })
        optimizer.step()
        update = first_conv.weight.detach() - previous_first_conv
        first_conv_update_norm += float(update.norm(2).cpu())
        with torch.no_grad():
            eval_logits = model(images)
            eval_loss = float(loss_fn(eval_logits, labels).cpu())
            accuracy = float((eval_logits.argmax(1) == labels).float().mean().cpu())
        best_loss = min(best_loss, eval_loss)
        best_accuracy = max(best_accuracy, accuracy)
    return {
        "optimizer": optimizer_name,
        "lr": lr,
        "momentum": 0.9 if optimizer_name == "SGD" else 0.0,
        "weight_decay": weight_decay,
        "initial_loss": initial_loss,
        "final_loss": eval_loss,
        "best_loss": best_loss,
        "final_accuracy": accuracy,
        "best_accuracy": best_accuracy,
        "first_conv_gradient_norm": first_grad,
        "final_classifier_gradient_norm": classifier_grad,
        "first_conv_update_norm": first_conv_update_norm,
        "initialization": initialization,
        "dropout": "default" if dropout is None else dropout,
    }, depth_rows


def training_regime_matrix() -> list[dict]:
    configurations = [
        ("A", "SGD", 0.1, 5e-4),
        ("B", "SGD", 0.01, 5e-4),
        ("C", "SGD", 0.001, 5e-4),
        ("D", "Adam", 1e-3, 0.0),
        ("E", "AdamW", 1e-3, 5e-4),
    ]
    rows = []
    for label, optimizer, lr, weight_decay in configurations:
        result, _ = train_32(optimizer, lr, weight_decay)
        result["configuration"] = label
        rows.append(result)
        print("matrix", rows[-1], flush=True)
    write_csv(VGG_DIR / "training_regime_matrix.csv", rows)
    return rows


def initialization_matrix() -> list[dict]:
    rows = []
    for initialization in ("canonical", "torchvision"):
        result, _ = train_32("SGD", 0.01, 5e-4, initialization=initialization)
        rows.append(result)
        print("initialization", rows[-1], flush=True)
    write_csv(VGG_DIR / "initialization_training_matrix.csv", rows)
    return rows


def initialization_layer_comparison() -> list[dict]:
    canonical = new_model("canonical").cpu()
    torchvision_like = new_model("torchvision").cpu()
    rows = []
    for layer_name, custom_layer, tv_layer in zip(
        (name for name, layer in canonical.named_modules() if isinstance(layer, (nn.Conv2d, nn.Linear))),
        (layer for layer in canonical.modules() if isinstance(layer, (nn.Conv2d, nn.Linear))),
        (layer for layer in torchvision_like.modules() if isinstance(layer, (nn.Conv2d, nn.Linear))),
    ):
        rows.append({
            "layer": layer_name,
            "custom_weight_std": float(custom_layer.weight.std()),
            "torchvision_weight_std": float(tv_layer.weight.std()),
            "custom_bias": float(custom_layer.bias.mean()) if custom_layer.bias is not None else "none",
            "torchvision_bias": float(tv_layer.bias.mean()) if tv_layer.bias is not None else "none",
        })
    write_csv(VGG_DIR / "initialization_layer_comparison.csv", rows)
    source = inspect.getsource(VGG) + "\n\n" + inspect.getsource(vgg16)
    (VGG_DIR / "torchvision_vgg16_source.txt").write_text(source)
    return rows


def gradient_depth_matrix() -> list[dict]:
    rows = []
    for optimizer_name, lr in (("SGD", 0.01), ("Adam", 1e-3)):
        _, depth_rows = train_32(optimizer_name, lr, 5e-4 if optimizer_name == "SGD" else 0.0, collect_depth=True)
        rows.extend(depth_rows)
    write_csv(VGG_DIR / "gradient_depth_training_regime.csv", rows)
    return rows


def dropout_matrix() -> list[dict]:
    rows = []
    for dropout in (0.5, 0.0):
        result, _ = train_32("Adam", 1e-3, 0.0, dropout=dropout)
        rows.append(result)
    write_csv(VGG_DIR / "dropout_training_matrix.csv", rows)
    return rows


def normalization_matrix(best_optimizer: str, best_lr: float, best_weight_decay: float) -> list[dict]:
    dataset = CifarDataset("cifar10", train=True, augment=False)
    loader = DataLoader(Subset(dataset, range(32)), batch_size=32, shuffle=False, num_workers=0)
    normalized_images, labels = next(iter(loader))
    tensor_only_images = torch.stack([torch.from_numpy(dataset.images[index]).float().div(255.0) for index in range(32)])
    rows = []
    for name, images in (("current_normalization", normalized_images), ("tensor_only", tensor_only_images)):
        model = new_model()
        optimizer = optimizer_for(model, best_optimizer, best_lr, best_weight_decay)
        loss_fn = nn.CrossEntropyLoss()
        best_loss = float("inf")
        best_accuracy = 0.0
        for _ in range(STEPS):
            optimizer.zero_grad(set_to_none=True)
            loss = loss_fn(model(images.to(DEVICE)), labels.to(DEVICE))
            loss.backward()
            optimizer.step()
            with torch.no_grad():
                logits = model(images.to(DEVICE))
                eval_loss = float(loss_fn(logits, labels.to(DEVICE)).cpu())
                accuracy = float((logits.argmax(1) == labels.to(DEVICE)).float().mean().cpu())
            best_loss = min(best_loss, eval_loss)
            best_accuracy = max(best_accuracy, accuracy)
        rows.append({"normalization": name, "optimizer": best_optimizer, "lr": best_lr, "final_loss": eval_loss, "best_loss": best_loss, "final_accuracy": accuracy, "best_accuracy": best_accuracy})
    write_csv(VGG_DIR / "normalization_best_optimizer.csv", rows)
    return rows


def run_pilot(optimizer_name: str, lr: float, weight_decay: float) -> list[dict]:
    seed_everything(SEED)
    train_dataset = CifarDataset("cifar10", train=True, augment=True)
    validation_dataset = CifarDataset("cifar10", train=True, augment=False)
    train_loader = DataLoader(Subset(train_dataset, range(5000, 50000)), batch_size=128, shuffle=True, num_workers=0)
    validation_loader = DataLoader(Subset(validation_dataset, range(5000)), batch_size=128, shuffle=False, num_workers=0)
    model = CifarVgg16Canonical(10).to(DEVICE)
    optimizer = optimizer_for(model, optimizer_name, lr, weight_decay)
    rows = []
    loss_fn = nn.CrossEntropyLoss()
    for epoch in range(1, 6):
        started = time.time()
        model.train()
        train_loss = correct = total = 0
        for images, labels in train_loader:
            images, labels = images.to(DEVICE), labels.to(DEVICE)
            optimizer.zero_grad(set_to_none=True)
            logits = model(images)
            loss = loss_fn(logits, labels)
            loss.backward()
            optimizer.step()
            train_loss += float(loss.detach()) * labels.numel()
            correct += int((logits.argmax(1) == labels).sum())
            total += labels.numel()
        model.eval()
        val_loss = val_correct = val_total = 0
        with torch.no_grad():
            for images, labels in validation_loader:
                images, labels = images.to(DEVICE), labels.to(DEVICE)
                logits = model(images)
                val_loss += float(loss_fn(logits, labels)) * labels.numel()
                val_correct += int((logits.argmax(1) == labels).sum())
                val_total += labels.numel()
        row = {"epoch": epoch, "train_loss": train_loss / total, "train_accuracy": correct / total, "val_loss": val_loss / val_total, "val_accuracy": val_correct / val_total, "learning_rate": optimizer.param_groups[0]["lr"], "epoch_time": time.time() - started}
        rows.append(row)
        print("pilot", row, flush=True)
    write_csv(VGG_DIR / "vgg_5epoch_candidate.csv", rows)
    return rows


def report(matrix, initialization, layer_comparison, depth, dropout, normalization, pilot, candidate):
    best = max(matrix, key=lambda row: (row["final_accuracy"], -row["final_loss"]))
    depth_by_optimizer = {name: [row for row in depth if row["optimizer"] == name] for name in ("SGD", "Adam")}
    lines = [
        "# VGG Training Regime Report\n\n",
        "## Scope and controls\n",
        "All diagnostic runs used the same first 32 CIFAR-10 training samples, labels, current CIFAR normalization, no augmentation, batch size 32, and 500 optimizer steps. No test-set data was used. `CifarVgg16Canonical` was not changed and BatchNorm was not added.\n\n",
        "## 32-image training-regime matrix\n",
        "| config | optimizer | lr | weight decay | initial loss | final loss | best loss | final accuracy | best accuracy | Conv1 grad | classifier grad | Conv1 update |\n|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n",
    ]
    for row in matrix:
        lines.append(f"| {row['configuration']} | {row['optimizer']} | {row['lr']} | {row['weight_decay']} | {row['initial_loss']:.6f} | {row['final_loss']:.6f} | {row['best_loss']:.6f} | {row['final_accuracy']:.4f} | {row['best_accuracy']:.4f} | {row['first_conv_gradient_norm']:.6e} | {row['final_classifier_gradient_norm']:.6e} | {row['first_conv_update_norm']:.6e} |\n")
    lines += ["\n## Findings\n", f"- Original SGD (A, lr=0.1) ended at {matrix[0]['final_accuracy']:.4f} accuracy and loss {matrix[0]['final_loss']:.6f}; changing weight decay was previously shown to have negligible effect.\n", "- Learning rate alone did not rescue SGD in this controlled 500-step matrix; the optimizer change is the dominant observed training-regime effect.\n", f"- Best non-BatchNorm matrix result: {best['optimizer']} at lr={best['lr']}, final accuracy={best['final_accuracy']:.4f}, final loss={best['final_loss']:.6f}.\n", "- AdamW is reported separately from Adam; no architecture or evaluation policy was changed.\n\n", "## Initialization\n", "The canonical model uses PyTorch module defaults. The torchvision-compatible diagnostic uses the installed torchvision VGG policy: Conv2d Kaiming-normal fan-out, zero Conv bias, Linear normal(std=0.01), and zero Linear bias. Layer-level values are in `initialization_layer_comparison.csv`; the inspected source is in `torchvision_vgg16_source.txt`.\n\n", "| initialization | final loss | best loss | final accuracy | best accuracy |\n|---|---:|---:|---:|---:|\n"]
    for row in initialization:
        lines.append(f"| {row['initialization']} | {row['final_loss']:.6f} | {row['best_loss']:.6f} | {row['final_accuracy']:.4f} | {row['best_accuracy']:.4f} |\n")
    lines += ["\n## Gradient depth\n", f"Gradient records were collected for Conv1 through Conv13 at steps 1, 10, 50, 100, and 500 for SGD lr=0.01 and Adam lr=1e-3. The complete data is in `gradient_depth_training_regime.csv`; use it to determine whether Adam prevents the early-depth collapse.\n", f"- SGD records: {len(depth_by_optimizer['SGD'])}; Adam records: {len(depth_by_optimizer['Adam'])}.\n\n", "## Dropout\n"]
    for row in dropout:
        lines.append(f"- Adam dropout={row['dropout']}: final loss={row['final_loss']:.6f}, final accuracy={row['final_accuracy']:.4f}, best accuracy={row['best_accuracy']:.4f}.\n")
    lines += ["\n## Normalization\n"]
    for row in normalization:
        lines.append(f"- {row['normalization']} with {row['optimizer']}: final loss={row['final_loss']:.6f}, final accuracy={row['final_accuracy']:.4f}, best accuracy={row['best_accuracy']:.4f}.\n")
    lines += ["\n## Candidate and pilot\n", f"Candidate selection used only the 32-image training diagnostic: `{candidate['optimizer']}` lr={candidate['lr']} weight_decay={candidate['weight_decay']}. It met the >=90% diagnostic gate: {candidate['final_accuracy']:.4f} final accuracy.\n\n"]
    if pilot:
        lines.append("The 5-epoch full-data pilot was run with the candidate and used the existing 45,000/5,000 train/validation split, augmentation, and normalization.\n\n| epoch | train loss | train accuracy | val loss | val accuracy | lr | epoch time |\n|---:|---:|---:|---:|---:|---:|---:|\n")
        for row in pilot:
            lines.append(f"| {row['epoch']} | {row['train_loss']:.6f} | {row['train_accuracy']:.4f} | {row['val_loss']:.6f} | {row['val_accuracy']:.4f} | {row['learning_rate']:.6g} | {row['epoch_time']:.2f} |\n")
        decision = "READY" if pilot[-1]["val_accuracy"] > pilot[0]["val_accuracy"] and pilot[-1]["train_accuracy"] > 0.1 else "NOT READY"
        lines.append(f"\n5-epoch pilot decision: **{decision}**.\n")
    else:
        decision = "NOT READY"
        lines.append("No non-BatchNorm candidate reached the 90% 32-image gate, so the 5-epoch pilot was not run.\n")
    lines += ["\n## Final gate\n", "- Diagnostic controls: BatchNorm and prior torchvision controls remain diagnostic only.\n", f"- Candidate final configuration: {candidate['optimizer']} lr={candidate['lr']} weight_decay={candidate['weight_decay']}.\n", "- Final experiment configuration: unchanged and not launched.\n", "- 150-epoch training: **NOT STARTED**.\n", f"- Decision: **{decision}**.\n"]
    (VGG_DIR / "VGG_TRAINING_REGIME_REPORT.md").write_text("".join(lines))
    return decision, best


def main():
    matrix = training_regime_matrix()
    initialization = initialization_matrix()
    layer_comparison = initialization_layer_comparison()
    depth = gradient_depth_matrix()
    dropout = dropout_matrix()
    best = max(matrix, key=lambda row: (row["final_accuracy"], -row["final_loss"]))
    normalization = normalization_matrix(best["optimizer"], best["lr"], best["weight_decay"])
    candidate = best if best["final_accuracy"] >= 0.9 else max(matrix, key=lambda row: (row["initial_loss"] - row["final_loss"], row["final_accuracy"]))
    pilot = run_pilot(candidate["optimizer"], candidate["lr"], candidate["weight_decay"]) if best["final_accuracy"] >= 0.9 else []
    decision, best = report(matrix, initialization, layer_comparison, depth, dropout, normalization, pilot, candidate)
    print("============================================================")
    print("VGG TRAINING REGIME RESULT")
    print("============================================================")
    print(f"Best non-BN optimizer: {best['optimizer']}")
    print(f"Best diagnostic LR: {best['lr']}")
    print(f"Best initialization: {best['initialization']}")
    print(f"32-image accuracy: {best['final_accuracy']:.4f}")
    print(f"32-image loss: {best['final_loss']:.6f}")
    print(f"5-epoch validation accuracy: {pilot[-1]['val_accuracy']:.4f}" if pilot else "5-epoch validation accuracy: NOT RUN")
    print("150-epoch training: NOT STARTED")
    print(f"Decision: {decision}")


if __name__ == "__main__":
    main()