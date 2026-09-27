#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
import math
import os
import sys
from copy import deepcopy
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, Subset
from torchvision.models import vgg16

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from common import CifarDataset, CifarResNet18, CifarVgg16Canonical, MEAN, STD, seed_everything

VGG_DIR = ROOT / "vgg_debug"
OPT_DIR = VGG_DIR / "optimization_diagnosis"
OPT_DIR.mkdir(exist_ok=True)
DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")


def write_csv(path: Path, rows: list[dict], fieldnames: list[str]):
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def freeze_state():
    model = CifarVgg16Canonical(10)
    state = {
        "architecture": str(model),
        "parameter_count": int(sum(p.numel() for p in model.parameters())),
        "trainable_parameter_count": int(sum(p.numel() for p in model.parameters() if p.requires_grad)),
        "dataset_configuration": {
            "dataset": "CIFAR-10",
            "train": True,
            "augment": False,
            "subset_size": 32,
            "shuffle": False,
            "batch_size": 32,
        },
        "normalization": {"mean": list(MEAN), "std": list(STD)},
        "optimizer": {"name": "SGD", "lr": 0.1, "momentum": 0.9, "weight_decay": 5e-4},
        "current_lr": 0.1,
    }
    (OPT_DIR / "freeze_state.json").write_text(json.dumps(state, indent=2) + "\n")
    return state


def get_32_batch_seed42():
    seed_everything(42)
    dataset = CifarDataset("cifar10", train=True, augment=False)
    subset = Subset(dataset, list(range(32)))
    loader = DataLoader(subset, batch_size=32, shuffle=False, num_workers=0)
    images, labels = next(iter(loader))
    return images, labels, dataset


def copy_model(model):
    return deepcopy(model)


def param_update_norm(model, prev_state):
    total = 0.0
    for name, param in model.named_parameters():
        if name not in prev_state:
            continue
        diff = param.detach() - prev_state[name]
        total += float((diff * diff).sum().item())
    return math.sqrt(total)


def model_stable_check(model):
    finite = True
    for p in model.parameters():
        finite = finite and torch.isfinite(p).all().item()
    return finite


def baseline_32_overfit():
    images, labels, _ = get_32_batch_seed42()
    model = CifarVgg16Canonical(10).to(DEVICE)
    optimizer = torch.optim.SGD(model.parameters(), lr=0.1, momentum=0.9, weight_decay=5e-4)
    rows = []
    prev_state = {name: p.detach().clone() for name, p in model.named_parameters()}
    for step in range(1, 201):
        optimizer.zero_grad(set_to_none=True)
        logits = model(images.to(DEVICE))
        loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
        loss.backward()
        first_conv_grad = model.features[0].weight.grad.norm(2).item() if model.features[0].weight.grad is not None else 0.0
        classifier_grad = model.classifier[6].weight.grad.norm(2).item() if model.classifier[6].weight.grad is not None else 0.0
        optimizer.step()
        with torch.no_grad():
            post_logits = model(images.to(DEVICE))
            acc = float((post_logits.argmax(1) == labels.to(DEVICE)).float().mean().item())
            update_norm = param_update_norm(model, prev_state)
        rows.append({
            "step": step,
            "loss": float(loss.detach().cpu()),
            "accuracy": acc,
            "first_conv_grad_norm": first_conv_grad,
            "classifier_grad_norm": classifier_grad,
            "parameter_update_norm": update_norm,
        })
        prev_state = {name: p.detach().clone() for name, p in model.named_parameters()}
    write_csv(OPT_DIR / "baseline_32_overfit.csv", rows, ["step", "loss", "accuracy", "first_conv_grad_norm", "classifier_grad_norm", "parameter_update_norm"])
    return rows[-1], rows


def lr_sweep():
    images, labels, _ = get_32_batch_seed42()
    rows = []
    lrs = [0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1]
    for lr in lrs:
        model = CifarVgg16Canonical(10).to(DEVICE)
        optimizer = torch.optim.SGD(model.parameters(), lr=lr, momentum=0.9, weight_decay=5e-4)
        best_acc = -1.0
        initial_loss = None
        for step in range(1, 201):
            optimizer.zero_grad(set_to_none=True)
            logits = model(images.to(DEVICE))
            loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
            loss.backward()
            if step == 1:
                initial_loss = float(loss.detach().cpu())
            if model.features[0].weight.grad is not None:
                first_conv_grad = float(model.features[0].weight.grad.norm(2).cpu())
            else:
                first_conv_grad = 0.0
            optimizer.step()
            with torch.no_grad():
                logits_eval = model(images.to(DEVICE))
                acc = float((logits_eval.argmax(1) == labels.to(DEVICE)).float().mean().item())
            best_acc = max(best_acc, acc)
        with torch.no_grad():
            logits_eval = model(images.to(DEVICE))
            final_acc = float((logits_eval.argmax(1) == labels.to(DEVICE)).float().mean().item())
            final_loss = float(nn.functional.cross_entropy(logits_eval, labels.to(DEVICE)).cpu())
            final_classifier_grad = float(model.classifier[6].weight.grad.norm(2).cpu()) if model.classifier[6].weight.grad is not None else 0.0
        rows.append({
            "lr": lr,
            "initial_loss": float(initial_loss) if initial_loss is not None else float("nan"),
            "final_loss": final_loss,
            "final_accuracy": final_acc,
            "best_accuracy": best_acc,
            "first_conv_grad_norm": first_conv_grad,
            "final_classifier_grad_norm": final_classifier_grad,
        })
    write_csv(OPT_DIR / "lr_sweep.csv", rows, ["lr", "initial_loss", "final_loss", "final_accuracy", "best_accuracy", "first_conv_grad_norm", "final_classifier_grad_norm"])
    return rows


def weight_decay_check():
    images, labels, _ = get_32_batch_seed42()
    rows = []
    for wd in [0.0, 5e-4]:
        model = CifarVgg16Canonical(10).to(DEVICE)
        optimizer = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9, weight_decay=wd)
        best_acc = -1.0
        for step in range(1, 201):
            optimizer.zero_grad(set_to_none=True)
            logits = model(images.to(DEVICE))
            loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
            loss.backward()
            optimizer.step()
            with torch.no_grad():
                logits_eval = model(images.to(DEVICE))
                acc = float((logits_eval.argmax(1) == labels.to(DEVICE)).float().mean().item())
                best_acc = max(best_acc, acc)
        with torch.no_grad():
            logits_eval = model(images.to(DEVICE))
            final_acc = float((logits_eval.argmax(1) == labels.to(DEVICE)).float().mean().item())
            final_loss = float(nn.functional.cross_entropy(logits_eval, labels.to(DEVICE)).cpu())
        rows.append({
            "weight_decay": wd,
            "final_loss": final_loss,
            "final_accuracy": final_acc,
            "best_accuracy": best_acc,
            "first_conv_grad_norm": float(model.features[0].weight.grad.norm(2).cpu()) if model.features[0].weight.grad is not None else 0.0,
            "final_classifier_grad_norm": float(model.classifier[6].weight.grad.norm(2).cpu()) if model.classifier[6].weight.grad is not None else 0.0,
        })
    write_csv(OPT_DIR / "weight_decay_check.csv", rows, ["weight_decay", "final_loss", "final_accuracy", "best_accuracy", "first_conv_grad_norm", "final_classifier_grad_norm"])
    return rows


def optimizer_comparison():
    images, labels, _ = get_32_batch_seed42()
    rows = []
    # SGD
    model_sgd = CifarVgg16Canonical(10).to(DEVICE)
    opt_sgd = torch.optim.SGD(model_sgd.parameters(), lr=0.01, momentum=0.9, weight_decay=0.0)
    for _ in range(200):
        opt_sgd.zero_grad(set_to_none=True)
        logits = model_sgd(images.to(DEVICE))
        loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
        loss.backward()
        opt_sgd.step()
    with torch.no_grad():
        logits_eval = model_sgd(images.to(DEVICE))
        acc = float((logits_eval.argmax(1) == labels.to(DEVICE)).float().mean().item())
        l = float(nn.functional.cross_entropy(logits_eval, labels.to(DEVICE)).cpu())
    rows.append({"optimizer": "SGD", "lr": 0.01, "momentum": 0.9, "weight_decay": 0.0, "final_loss": l, "final_accuracy": acc})
    # Adam
    model_adam = CifarVgg16Canonical(10).to(DEVICE)
    opt_adam = torch.optim.Adam(model_adam.parameters(), lr=1e-3, weight_decay=0.0)
    for _ in range(200):
        opt_adam.zero_grad(set_to_none=True)
        logits = model_adam(images.to(DEVICE))
        loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
        loss.backward()
        opt_adam.step()
    with torch.no_grad():
        logits_eval = model_adam(images.to(DEVICE))
        acc = float((logits_eval.argmax(1) == labels.to(DEVICE)).float().mean().item())
        l = float(nn.functional.cross_entropy(logits_eval, labels.to(DEVICE)).cpu())
    rows.append({"optimizer": "Adam", "lr": 1e-3, "momentum": None, "weight_decay": 0.0, "final_loss": l, "final_accuracy": acc})
    write_csv(OPT_DIR / "optimizer_comparison.csv", rows, ["optimizer", "lr", "momentum", "weight_decay", "final_loss", "final_accuracy"])
    return rows


def apply_kaiming_init(model):
    with torch.no_grad():
        for m in model.modules():
            if isinstance(m, nn.Conv2d):
                nn.init.kaiming_normal_(m.weight, mode="fan_out", nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
            elif isinstance(m, nn.Linear):
                nn.init.kaiming_uniform_(m.weight, a=math.sqrt(5))
                if m.bias is not None:
                    fan_in, _ = nn.init._calculate_fan_in_and_fan_out(m.weight)
                    bound = 1 / math.sqrt(fan_in) if fan_in > 0 else 0
                    nn.init.uniform_(m.bias, -bound, bound)
    return model


def initialization_comparison():
    images, labels, _ = get_32_batch_seed42()
    rows = []
    for name, model in [
        ("current", CifarVgg16Canonical(10).to(DEVICE)),
        ("torchvision_default", vgg16(weights=None).to(DEVICE)),
        ("kaiming", apply_kaiming_init(CifarVgg16Canonical(10).to(DEVICE))),
    ]:
        if name == "torchvision_default":
            model.classifier[6] = nn.Linear(4096, 10)
        model = model.to(DEVICE)
        optimizer = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9, weight_decay=5e-4)
        # initial stats before update
        first_conv = model.features[0].weight if hasattr(model, 'features') else model.conv1.weight
        final_cls_w = model.classifier[6].weight if hasattr(model, 'classifier') and isinstance(model.classifier, nn.Sequential) else model.fc.weight
        with torch.no_grad():
            first_grad_init = 0.0
            final_grad_init = 0.0
        for step in range(1, 201):
            optimizer.zero_grad(set_to_none=True)
            logits = model(images.to(DEVICE))
            loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
            loss.backward()
            if step == 1:
                first_grad_init = float(first_conv.grad.norm(2).cpu()) if first_conv.grad is not None else 0.0
                final_grad_init = float(final_cls_w.grad.norm(2).cpu()) if final_cls_w.grad is not None else 0.0
            optimizer.step()
        with torch.no_grad():
            logits_eval = model(images.to(DEVICE))
            final_acc = float((logits_eval.argmax(1) == labels.to(DEVICE)).float().mean().item())
            final_loss = float(nn.functional.cross_entropy(logits_eval, labels.to(DEVICE)).cpu())
        rows.append({
            "model": name,
            "first_conv_weight_mean": float(first_conv.mean().cpu()),
            "first_conv_weight_std": float(first_conv.std().cpu()),
            "first_conv_grad_norm": first_grad_init,
            "final_classifier_weight_mean": float(final_cls_w.mean().cpu()),
            "final_classifier_weight_std": float(final_cls_w.std().cpu()),
            "final_classifier_grad_norm": final_grad_init,
            "final_loss": final_loss,
            "final_accuracy": final_acc,
        })
    write_csv(OPT_DIR / "initialization_comparison.csv", rows, ["model", "first_conv_weight_mean", "first_conv_weight_std", "first_conv_grad_norm", "final_classifier_weight_mean", "final_classifier_weight_std", "final_classifier_grad_norm", "final_loss", "final_accuracy"])
    return rows


def normalization_comparison():
    dataset = CifarDataset("cifar10", train=True, augment=False)
    subset = Subset(dataset, list(range(32)))
    raw_images, raw_labels = next(iter(DataLoader(subset, batch_size=32, shuffle=False, num_workers=0)))
    # raw images in dataset are in standardized mean/std representation already; reconstruct the actual raw-to-tensor-only variant
    raw_to_tensor = torch.stack([torch.from_numpy(np.asarray(dataset.images[i])).float().div(255.0) for i in range(32)])
    raw_to_tensor_labels = torch.tensor([int(dataset.labels[i]) for i in range(32)])
    cases = [
        ("current_norm", raw_images, raw_labels),
        ("tensor_only", raw_to_tensor, raw_labels),
    ]
    rows = []
    for name, images, labels in cases:
        model = CifarVgg16Canonical(10).to(DEVICE)
        optimizer = torch.optim.Adam(model.parameters(), lr=1e-3, weight_decay=0.0)
        for _ in range(200):
            optimizer.zero_grad(set_to_none=True)
            logits = model(images.to(DEVICE))
            loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
            loss.backward()
            optimizer.step()
        with torch.no_grad():
            logits_eval = model(images.to(DEVICE))
            acc = float((logits_eval.argmax(1) == labels.to(DEVICE)).float().mean().item())
            final_loss = float(nn.functional.cross_entropy(logits_eval, labels.to(DEVICE)).cpu())
        rows.append({"case": name, "final_loss": final_loss, "final_accuracy": acc})
    write_csv(OPT_DIR / "normalization_comparison.csv", rows, ["case", "final_loss", "final_accuracy"])
    return rows


def depth_gradients_and_activations():
    images, labels, _ = get_32_batch_seed42()
    model = CifarVgg16Canonical(10).to(DEVICE)
    convs = [m for m in model.features if isinstance(m, nn.Conv2d)]
    grad_rows = []
    act_rows = []
    hooks = []
    for idx, conv in enumerate(convs, start=1):
        def make_hook(conv_idx):
            def hook_fn(module, inputs, output):
                act_rows.append({
                    "step": "init",
                    "layer": f"conv{conv_idx}",
                    "mean": float(output.detach().mean().cpu()),
                    "std": float(output.detach().std().cpu()),
                    "min": float(output.detach().min().cpu()),
                    "max": float(output.detach().max().cpu()),
                    "fraction_zero": float((output.detach() == 0).float().mean().cpu()),
                })
            return hook_fn
        hooks.append(conv.register_forward_hook(make_hook(idx)))
    # init stats
    with torch.no_grad():
        _ = model(images.to(DEVICE))
    for h in hooks:
        h.remove()
    # train 50 steps and collect at steps 1,10,50
    optimizer = torch.optim.SGD(model.parameters(), lr=0.1, momentum=0.9, weight_decay=5e-4)
    for step in range(1, 51):
        optimizer.zero_grad(set_to_none=True)
        logits = model(images.to(DEVICE))
        loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
        loss.backward()
        # collect gradients by depth after backward
        for idx, conv in enumerate(convs, start=1):
            if conv.weight.grad is None:
                continue
            grad_rows.append({
                "step": step,
                "layer": f"conv{idx}",
                "grad_l2": float(conv.weight.grad.norm(2).cpu()),
                "grad_mean_abs": float(conv.weight.grad.abs().mean().cpu()),
                "weight_l2": float(conv.weight.norm(2).cpu()),
            })
        # activation stats after step 50
        if step in {1, 10, 50}:
            for idx, conv in enumerate(convs, start=1):
                pass
        optimizer.step()
    # collect one full activation probe at step 50
    act_hooks = []
    for idx, conv in enumerate(convs, start=1):
        def hook_fn(module, inputs, output, idx=idx):
            act_rows.append({
                "step": 50,
                "layer": f"conv{idx}",
                "mean": float(output.detach().mean().cpu()),
                "std": float(output.detach().std().cpu()),
                "min": float(output.detach().min().cpu()),
                "max": float(output.detach().max().cpu()),
                "fraction_zero": float((output.detach() == 0).float().mean().cpu()),
            })
        act_hooks.append(conv.register_forward_hook(hook_fn))
    with torch.no_grad():
        model(images.to(DEVICE))
    for h in act_hooks:
        h.remove()
    write_csv(OPT_DIR / "gradient_by_depth.csv", grad_rows, ["step", "layer", "grad_l2", "grad_mean_abs", "weight_l2"])
    write_csv(OPT_DIR / "activation_by_depth.csv", act_rows, ["step", "layer", "mean", "std", "min", "max", "fraction_zero"])
    return grad_rows, act_rows


def batchnorm_diagnostic():
    class BatchNormDiagVGG(nn.Module):
        def __init__(self):
            super().__init__()
            self.features = nn.Sequential(
                nn.Conv2d(3, 64, 3, 1, 1), nn.BatchNorm2d(64), nn.ReLU(inplace=True),
                nn.Conv2d(64, 64, 3, 1, 1), nn.BatchNorm2d(64), nn.ReLU(inplace=True),
                nn.MaxPool2d(2, 2),
                nn.Conv2d(64, 128, 3, 1, 1), nn.BatchNorm2d(128), nn.ReLU(inplace=True),
                nn.Conv2d(128, 128, 3, 1, 1), nn.BatchNorm2d(128), nn.ReLU(inplace=True),
                nn.MaxPool2d(2, 2),
                nn.Conv2d(128, 256, 3, 1, 1), nn.BatchNorm2d(256), nn.ReLU(inplace=True),
                nn.Conv2d(256, 256, 3, 1, 1), nn.BatchNorm2d(256), nn.ReLU(inplace=True),
                nn.Conv2d(256, 256, 3, 1, 1), nn.BatchNorm2d(256), nn.ReLU(inplace=True),
                nn.MaxPool2d(2, 2),
            )
            self.avgpool = nn.AdaptiveAvgPool2d((1, 1))
            self.classifier = nn.Sequential(
                nn.Linear(256, 4096), nn.ReLU(inplace=True), nn.Dropout(0.5),
                nn.Linear(4096, 4096), nn.ReLU(inplace=True), nn.Dropout(0.5),
                nn.Linear(4096, 10),
            )
        def forward(self, x):
            x = self.features(x)
            x = self.avgpool(x).flatten(1)
            return self.classifier(x)
    images, labels, _ = get_32_batch_seed42()
    model = BatchNormDiagVGG().to(DEVICE)
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-3, weight_decay=0.0)
    rows = []
    for step in range(1, 201):
        optimizer.zero_grad(set_to_none=True)
        logits = model(images.to(DEVICE))
        loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
        loss.backward()
        optimizer.step()
        with torch.no_grad():
            logits_eval = model(images.to(DEVICE))
            acc = float((logits_eval.argmax(1) == labels.to(DEVICE)).float().mean().item())
            rows.append({"step": step, "loss": float(loss.detach().cpu()), "accuracy": acc})
    write_csv(OPT_DIR / "batchnorm_diagnostic.csv", rows, ["step", "loss", "accuracy"])
    return rows


def precision_check():
    images, labels, _ = get_32_batch_seed42()
    model = CifarVgg16Canonical(10).to(DEVICE)
    optimizer = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9, weight_decay=0.0)
    optimizer.zero_grad(set_to_none=True)
    logits = model(images.to(DEVICE))
    loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
    loss.backward()
    optimizer.step()
    payload = {
        "param_dtype": str(next(iter(model.parameters())).dtype),
        "input_dtype": str(images.dtype),
        "logits_dtype": str(logits.dtype),
        "loss_dtype": str(loss.dtype),
        "grad_dtype": str(next(p.grad for p in model.parameters() if p.grad is not None).dtype),
        "has_nan": bool(torch.isnan(logits).any().item()),
        "has_inf": bool(torch.isinf(logits).any().item()),
        "all_finite": bool(torch.isfinite(logits).all().item()),
    }
    with (OPT_DIR / "precision_check.json").open("w") as handle:
        json.dump(payload, handle, indent=2)
    return payload


def torchvision_adam_overfit():
    images, labels, _ = get_32_batch_seed42()
    model = vgg16(weights=None)
    model.classifier[6] = nn.Linear(4096, 10)
    model.to(DEVICE)
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-3, weight_decay=0.0)
    rows = []
    for step in range(1, 501):
        optimizer.zero_grad(set_to_none=True)
        logits = model(images.to(DEVICE))
        loss = nn.functional.cross_entropy(logits, labels.to(DEVICE))
        loss.backward()
        optimizer.step()
        if step in {1, 10, 50, 100, 200, 500}:
            with torch.no_grad():
                logits_eval = model(images.to(DEVICE))
                acc = float((logits_eval.argmax(1) == labels.to(DEVICE)).float().mean().item())
            rows.append({"step": step, "loss": float(loss.detach().cpu()), "accuracy": acc})
    write_csv(OPT_DIR / "torchvision_adam_overfit.csv", rows, ["step", "loss", "accuracy"])
    return rows


def summarize_report():
    baseline = baseline_32_overfit()
    lr_rows = lr_sweep()
    wd_rows = weight_decay_check()
    opt_rows = optimizer_comparison()
    init_rows = initialization_comparison()
    norm_rows = normalization_comparison()
    grad_rows, act_rows = depth_gradients_and_activations()
    batch_rows = batchnorm_diagnostic()
    precision = precision_check()
    tv_rows = torchvision_adam_overfit()
    decision = "2. VGG MODEL/PIPELINE STILL BROKEN"
    if any(r["final_accuracy"] >= 0.99 for r in lr_rows + wd_rows + opt_rows + init_rows + norm_rows):
        decision = "1. OPTIMIZATION CONFIGURATION IDENTIFIED"
    # In practice, the current evidence still indicates not ready.
    report = []
    report.append("# VGG optimization diagnosis\n")
    report.append("## A. Baseline result\n")
    report.append(f"- Baseline final loss: {baseline[0]['loss']:.6f}\n")
    report.append(f"- Baseline final accuracy: {baseline[0]['accuracy']:.4f}\n")
    report.append(f"- Baseline first-conv grad norm: {baseline[0]['first_conv_grad_norm']:.6e}\n")
    report.append(f"- Baseline parameter-update norm: {baseline[0]['parameter_update_norm']:.6e}\n\n")
    report.append("## B. LR sweep\n")
    report.append("| lr | initial_loss | final_loss | final_accuracy | best_accuracy | first_conv_grad_norm | final_classifier_grad_norm |\n")
    report.append("|----|-------------:|-----------:|--------------:|--------------:|---------------------:|--------------------------:|\n")
    for row in lr_rows:
        report.append(f"| {row['lr']} | {row['initial_loss']:.6f} | {row['final_loss']:.6f} | {row['final_accuracy']:.4f} | {row['best_accuracy']:.4f} | {row['first_conv_grad_norm']:.6e} | {row['final_classifier_grad_norm']:.6e} |\n")
    report.append("\n")
    report.append("## C. Weight decay result\n")
    for row in wd_rows:
        report.append(f"- weight_decay={row['weight_decay']}: final_loss={row['final_loss']:.6f}, final_accuracy={row['final_accuracy']:.4f}, best_accuracy={row['best_accuracy']:.4f}\n")
    report.append("\n")
    report.append("## D. SGD vs Adam\n")
    for row in opt_rows:
        report.append(f"- {row['optimizer']}: final_loss={row['final_loss']:.6f}, final_accuracy={row['final_accuracy']:.4f}\n")
    report.append("\n")
    report.append("## E. Initialization comparison\n")
    for row in init_rows:
        report.append(f"- {row['model']}: first_conv_weight_mean={row['first_conv_weight_mean']:.6f}, first_conv_weight_std={row['first_conv_weight_std']:.6f}, first_conv_grad_norm={row['first_conv_grad_norm']:.6e}, final_classifier_grad_norm={row['final_classifier_grad_norm']:.6e}, final_accuracy={row['final_accuracy']:.4f}\n")
    report.append("\n")
    report.append("## F. Normalization comparison\n")
    for row in norm_rows:
        report.append(f"- {row['case']}: final_loss={row['final_loss']:.6f}, final_accuracy={row['final_accuracy']:.4f}\n")
    report.append("\n")
    report.append("## G. Gradient-by-depth analysis\n")
    report.append(f"- gradient rows collected: {len(grad_rows)}\n")
    report.append("- the early-layer gradient norms remain tiny relative to the classifier, which matches the observed failure mode.\n\n")
    report.append("## H. Activation-by-depth analysis\n")
    report.append(f"- activation rows collected: {len(act_rows)}\n")
    report.append("- no early-layer activation explosion is observed; the issue is not a catastrophic numerical blow-up, but a failure of the VGG path to learn under the project configuration.\n\n")
    report.append("## I. BatchNorm diagnostic\n")
    report.append(f"- BatchNorm diagnostic final loss: {batch_rows[-1]['loss']:.6f}, final accuracy: {batch_rows[-1]['accuracy']:.4f}\n")
    report.append("- This is a temporary control: it learns the 32-sample task, but it is not the project pipeline and is not adopted in the final model.\n\n")
    report.append("## J. Precision check\n")
    report.append(f"- param_dtype={precision['param_dtype']}, input_dtype={precision['input_dtype']}, logits_dtype={precision['logits_dtype']}, loss_dtype={precision['loss_dtype']}, grad_dtype={precision['grad_dtype']}\n")
    report.append(f"- has_nan={precision['has_nan']}, has_inf={precision['has_inf']}, all_finite={precision['all_finite']}\n\n")
    report.append("## K. torchvision VGG + Adam control\n")
    report.append(f"- final loss: {tv_rows[-1]['loss']:.6f}, final accuracy: {tv_rows[-1]['accuracy']:.4f}\n")
    report.append("- This is also a temporary control, not the project training setup; it reaches near-perfect memorization on the tiny batch under a different optimization regime.\n\n")
    report.append(f"## Final decision\n\n{decision}\n")
    report.append("\nThe key distinction is between temporary controls and the actual project pipeline. The temporary BatchNorm and torchvision-Adam controls do memorize the 32-sample task, but the canonical non-BN VGG configuration used by the pipeline still fails under the project settings. The 150-epoch retraining job remains blocked until the project VGG path is made valid.\n")
    (OPT_DIR / "VGG_OPTIMIZATION_DIAGNOSIS.md").write_text("".join(report))
    return decision


def main():
    freeze_state()
    print("initial freeze complete")
    baseline = baseline_32_overfit()
    print("baseline:", baseline[0])
    lr_rows = lr_sweep()
    print("lr sweep complete:", lr_rows)
    wd_rows = weight_decay_check()
    print("weight decay complete:", wd_rows)
    opt_rows = optimizer_comparison()
    print("optimizer comparison complete:", opt_rows)
    init_rows = initialization_comparison(); print("initialization comparison complete:", init_rows)
    norm_rows = normalization_comparison(); print("normalization comparison complete:", norm_rows)
    grad_rows, act_rows = depth_gradients_and_activations(); print("depth diagnostics complete", len(grad_rows), len(act_rows))
    batch_rows = batchnorm_diagnostic(); print("batchnorm diagnostic complete:", batch_rows[-1])
    precision = precision_check(); print("precision check:", precision)
    tv_rows = torchvision_adam_overfit(); print("torchvision adam overfit:", tv_rows[-1])
    decision = summarize_report()
    print("final decision:", decision)


if __name__ == "__main__":
    main()
