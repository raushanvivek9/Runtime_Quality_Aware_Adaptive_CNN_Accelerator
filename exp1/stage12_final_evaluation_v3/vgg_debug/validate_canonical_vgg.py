#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
import math
import os
import sys
import time
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader, Subset
from torchvision.models import vgg16

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from common import CifarDataset, CifarResNet18, CifarVgg16, CifarVgg16Canonical, seed_everything

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
VGG_DIR = ROOT / "vgg_debug"
VGG_DIR.mkdir(exist_ok=True)


def get_grad_l2(model, layer_name: str):
    if layer_name == "first_conv":
        if hasattr(model, "features"):
            layer = model.features[0]
        elif hasattr(model, "conv1"):
            layer = model.conv1
        else:
            return 0.0
        return layer.weight.grad.norm(2).item() if layer.weight.grad is not None else 0.0
    if hasattr(model, "classifier") and isinstance(model.classifier, nn.Sequential):
        linear = model.classifier[0]
    elif hasattr(model, "fc"):
        linear = model.fc
    elif hasattr(model, "classifier"):
        linear = model.classifier
    else:
        return 0.0
    return linear.weight.grad.norm(2).item() if linear.weight.grad is not None else 0.0


def run_gradient_probe(model_name: str, model: nn.Module, images: torch.Tensor, labels: torch.Tensor):
    model = model.to(DEVICE)
    optimizer = torch.optim.SGD(model.parameters(), lr=0.1, momentum=0.9, weight_decay=5e-4)
    rows = []
    for step in range(1, 11):
        optimizer.zero_grad(set_to_none=True)
        logits = model(images.to(DEVICE))
        loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
        loss.backward()
        first_conv = get_grad_l2(model, "first_conv")
        classifier_grad = get_grad_l2(model, "classifier")
        acc = (logits.argmax(1) == labels.to(DEVICE)).float().mean().item()
        rows.append({
            "model": model_name,
            "step": step,
            "loss": float(loss.detach().cpu()),
            "accuracy": float(acc),
            "first_conv_gradient_L2": float(first_conv),
            "classifier_gradient_L2": float(classifier_grad),
        })
        optimizer.step()
    return rows


def write_csv(path: Path, rows: list[dict], fieldnames: list[str]):
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def architecture_comparison():
    reference = vgg16(weights=None)
    canonical = CifarVgg16Canonical(10)
    ref_conv = [m for m in reference.features if isinstance(m, nn.Conv2d)]
    canon_conv = [m for m in canonical.features if isinstance(m, nn.Conv2d)]
    ref_pools = [m for m in reference.features if isinstance(m, nn.MaxPool2d)]
    canon_pools = [m for m in canonical.features if isinstance(m, nn.MaxPool2d)]
    ref_channels = [m.out_channels for m in ref_conv]
    canon_channels = [m.out_channels for m in canon_conv]

    x = torch.randn(1, 3, 32, 32)
    ref_shape = reference.features(x).shape
    canon_shape = canonical.features(x).shape
    lines = [
        "VGG-16 feature-structure comparison",
        "=================================",
        f"Reference torchvision vgg16(weights=None): {len(ref_conv)} Conv2d layers, {len(ref_pools)} MaxPool2d layers",
        f"Canonical CifarVgg16Canonical: {len(canon_conv)} Conv2d layers, {len(canon_pools)} MaxPool2d layers",
        f"Same number of Conv2d layers: {len(ref_conv) == len(canon_conv)}",
        f"Same channel progression: {ref_channels == canon_channels}",
        f"Same number of pooling layers: {len(ref_pools) == len(canon_pools)}",
        f"Reference feature output shape for 32x32 input: {tuple(ref_shape)}",
        f"Canonical feature output shape for 32x32 input: {tuple(canon_shape)}",
        f"Spatial reduction pattern: 32 -> 16 -> 8 -> 4 -> 2 -> 1 is {'yes' if canon_shape[-1] == 1 else 'no'}",
        "",
        "Reference conv channels: " + str(ref_channels),
        "Canonical conv channels: " + str(canon_channels),
        "",
        "Note: this comparison checks structural equivalence of the feature extractor, not numerical equivalence of parameter values.",
    ]
    (VGG_DIR / "architecture_comparison.txt").write_text("\n".join(lines) + "\n")
    return ref_channels == canon_channels and len(ref_conv) == len(canon_conv) and len(ref_pools) == len(canon_pools)


def run_overfit32():
    seed_everything(42)
    dataset = CifarDataset("cifar10", True, augment=False)
    subset = Subset(dataset, list(range(32)))
    loader = DataLoader(subset, batch_size=32, shuffle=False)
    images, labels = next(iter(loader))
    model = CifarVgg16Canonical(10).to(DEVICE)
    optimizer = torch.optim.SGD(model.parameters(), lr=0.1, momentum=0.9, weight_decay=5e-4)
    rows = []
    for step in range(1, 501):
        optimizer.zero_grad(set_to_none=True)
        logits = model(images.to(DEVICE))
        loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
        loss.backward()
        optimizer.step()
        if step % 25 == 0:
            acc = (logits.argmax(1) == labels.to(DEVICE)).float().mean().item()
            rows.append({"step": step, "loss": float(loss.detach().cpu()), "accuracy": float(acc)})
    write_csv(VGG_DIR / "canonical_overfit32.csv", rows, ["step", "loss", "accuracy"])
    return rows


def run_pilot5epoch():
    seed_everything(42)
    train_dataset = CifarDataset("cifar10", True, augment=True)
    val_dataset = CifarDataset("cifar10", True, augment=False)
    train_indices = list(range(5000, 50000))
    val_indices = list(range(5000))
    train_loader = DataLoader(Subset(train_dataset, train_indices), batch_size=128, shuffle=True)
    val_loader = DataLoader(Subset(val_dataset, val_indices), batch_size=128, shuffle=False)
    model = CifarVgg16Canonical(10).to(DEVICE)
    optimizer = torch.optim.SGD(model.parameters(), lr=0.1, momentum=0.9, weight_decay=5e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=5)
    rows = []
    for epoch in range(1, 6):
        model.train()
        running_loss = 0.0
        correct = 0
        total = 0
        start = time.time()
        for batch_images, batch_labels in train_loader:
            batch_images = batch_images.to(DEVICE)
            batch_labels = batch_labels.to(DEVICE)
            optimizer.zero_grad(set_to_none=True)
            logits = model(batch_images)
            loss = nn.functional.cross_entropy(logits, batch_labels)
            loss.backward()
            optimizer.step()
            running_loss += loss.item() * batch_labels.numel()
            correct += int((logits.argmax(1) == batch_labels).sum())
            total += batch_labels.numel()
        scheduler.step()
        model.eval()
        val_loss = 0.0
        val_correct = 0
        val_total = 0
        with torch.no_grad():
            for batch_images, batch_labels in val_loader:
                logits = model(batch_images.to(DEVICE))
                val_loss += nn.functional.cross_entropy(logits, batch_labels.to(DEVICE), reduction="sum").item()
                val_correct += int((logits.argmax(1) == batch_labels.to(DEVICE)).sum())
                val_total += batch_labels.numel()
        epoch_time = time.time() - start
        rows.append({
            "epoch": epoch,
            "train_loss": running_loss / max(total, 1),
            "train_accuracy": correct / max(total, 1),
            "validation_loss": val_loss / max(val_total, 1),
            "validation_accuracy": val_correct / max(val_total, 1),
            "learning_rate": optimizer.param_groups[0]["lr"],
            "epoch_time": epoch_time,
        })
    write_csv(VGG_DIR / "canonical_5epoch_pilot.csv", rows, ["epoch", "train_loss", "train_accuracy", "validation_loss", "validation_accuracy", "learning_rate", "epoch_time"])
    return rows


def checkpoint_test():
    seed_everything(42)
    model = CifarVgg16Canonical(10).to(DEVICE)
    x = torch.randn(2, 3, 32, 32, device=DEVICE)
    ckpt = VGG_DIR / "canonical_temp_checkpoint.pt"
    torch.save({"state_dict": model.state_dict()}, ckpt)
    loaded = CifarVgg16Canonical(10).to(DEVICE)
    payload = torch.load(ckpt, map_location=DEVICE)
    loaded.load_state_dict(payload["state_dict"])
    y = loaded(x)
    assert y.shape == (2, 10)
    assert torch.isfinite(y).all()
    return {"checkpoint": str(ckpt), "output_shape": tuple(y.shape), "finite": bool(torch.isfinite(y).all())}


def main():
    seed_everything(42)
    structure_ok = architecture_comparison()

    dataset = CifarDataset("cifar10", True, augment=False)
    subset = Subset(dataset, list(range(128)))
    images, labels = next(iter(DataLoader(subset, batch_size=128, shuffle=False)))
    rows = []
    rows.extend(run_gradient_probe("canonical_vgg16", CifarVgg16Canonical(10), images, labels))
    rows.extend(run_gradient_probe("custom_vgg16", CifarVgg16(10), images, labels))
    rows.extend(run_gradient_probe("resnet18", CifarResNet18(10), images, labels))
    write_csv(VGG_DIR / "canonical_gradient_probe.csv", rows, ["model", "step", "loss", "accuracy", "first_conv_gradient_L2", "classifier_gradient_L2"])

    overfit_rows = run_overfit32()
    overfit_pass = (overfit_rows[-1]["loss"] < 1.0 and overfit_rows[-1]["accuracy"] > 0.9)

    pilot_rows = run_pilot5epoch()
    pilot_pass = len(pilot_rows) == 5 and pilot_rows[-1]["validation_accuracy"] > 0.1 and pilot_rows[-1]["train_accuracy"] > 0.2

    checkpoint = checkpoint_test()

    status_lines = [
        "architecture validation: PASS" if structure_ok else "architecture validation: FAIL",
        f"gradient probe: {'PASS' if all(row['first_conv_gradient_L2'] > 0 and math.isfinite(row['first_conv_gradient_L2']) for row in rows if row['model'] == 'canonical_vgg16') else 'FAIL'}",
        f"32-image overfit: {'PASS' if overfit_pass else 'FAIL'}",
        f"5-epoch pilot: {'PASS' if pilot_pass else 'FAIL'}",
        "",
        "summary:",
        f"- final canonical loss after overfit: {overfit_rows[-1]['loss']:.4f}",
        f"- final canonical training accuracy after overfit: {overfit_rows[-1]['accuracy']:.4f}",
        f"- final 5-epoch validation accuracy: {pilot_rows[-1]['validation_accuracy']:.4f}",
        f"- checkpoint validation: {checkpoint['output_shape']} finite={checkpoint['finite']}",
    ]
    (VGG_DIR / "READY_FOR_RETRAINING.txt").write_text("\n".join(status_lines) + "\n")

    print("==================================================")
    print("VGG ARCHITECTURE FIX SUMMARY")
    print("==================================================")
    print(f"Canonical architecture: {'PASS' if structure_ok else 'FAIL'}")
    print(f"Output shape: {'PASS' if checkpoint['finite'] and checkpoint['output_shape'] == (2, 10) else 'FAIL'}")
    print(f"Gradient flow: {'PASS' if all(row['first_conv_gradient_L2'] > 0 and math.isfinite(row['first_conv_gradient_L2']) for row in rows if row['model'] == 'canonical_vgg16') else 'FAIL'}")
    print(f"32-image overfit: {'PASS' if overfit_pass else 'FAIL'}")
    print(f"5-epoch CIFAR-10 pilot: {'PASS' if pilot_pass else 'FAIL'}")
    print("")
    print("150-epoch retraining:")
    print("    NOT STARTED")
    print("Decision:")
    print("    READY FOR 150-EPOCH RETRAINING" if structure_ok and all(row['first_conv_gradient_L2'] > 0 and math.isfinite(row['first_conv_gradient_L2']) for row in rows if row['model'] == 'canonical_vgg16') and overfit_pass and pilot_pass else "    NOT READY — CONTINUE DEBUGGING")


if __name__ == "__main__":
    main()
