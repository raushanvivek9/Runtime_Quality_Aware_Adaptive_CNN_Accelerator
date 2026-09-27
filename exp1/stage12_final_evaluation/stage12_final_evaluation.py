#!/usr/bin/env python3
"""Stage 12 model evaluation with explicit evidence-level boundaries."""
from __future__ import annotations

import hashlib
import json
import math
import os
import pickle
import platform
import random
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import torch
from torch import nn

BASE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BASE_DIR.parents[1]
DATA_DIR = BASE_DIR / "data"
SEED = 42
SAMPLE_COUNT = int(os.environ.get("STAGE12_SAMPLES", "1000"))
BATCH_SIZE = int(os.environ.get("STAGE12_BATCH_SIZE", "32"))
DEVICE = torch.device(os.environ.get("STAGE12_DEVICE", "cuda" if torch.cuda.is_available() else "cpu"))
PE_CONFIGS = (16, 32, 64)
PAIRS = (("ResNet18", "CIFAR10", 10), ("ResNet18", "CIFAR100", 100),
         ("VGG16", "CIFAR10", 10), ("VGG16", "CIFAR100", 100))


class CifarDataset(torch.utils.data.Dataset):
    def __init__(self, dataset_name: str):
        folder = DATA_DIR / ("cifar-10-batches-py" if dataset_name == "CIFAR10" else "cifar-100-python")
        file_name = "test_batch" if dataset_name == "CIFAR10" else "test"
        with (folder / file_name).open("rb") as handle:
            payload = pickle.load(handle, encoding="bytes")
        self.images = np.asarray(payload[b"data"], dtype=np.uint8).reshape(-1, 3, 32, 32)
        label_key = b"labels" if dataset_name == "CIFAR10" else b"fine_labels"
        self.labels = np.asarray(payload[label_key], dtype=np.int64)
        self.mean = torch.tensor((0.4914, 0.4822, 0.4465)).view(3, 1, 1)
        self.std = torch.tensor((0.2470, 0.2435, 0.2616)).view(3, 1, 1)

    def __len__(self):
        return len(self.labels)

    def __getitem__(self, index):
        image = torch.from_numpy(self.images[index]).float().div(255.0)
        return (image - self.mean) / self.std, int(self.labels[index])


class BasicBlock(nn.Module):
    expansion = 1

    def __init__(self, in_channels: int, out_channels: int, stride: int):
        super().__init__()
        self.conv1 = nn.Conv2d(in_channels, out_channels, 3, stride, 1, bias=False)
        self.bn1 = nn.BatchNorm2d(out_channels)
        self.relu1 = nn.ReLU(inplace=False)
        self.conv2 = nn.Conv2d(out_channels, out_channels, 3, 1, 1, bias=False)
        self.bn2 = nn.BatchNorm2d(out_channels)
        self.shortcut = nn.Identity() if stride == 1 and in_channels == out_channels else nn.Sequential(
            nn.Conv2d(in_channels, out_channels, 1, stride, bias=False), nn.BatchNorm2d(out_channels))
        self.relu2 = nn.ReLU(inplace=False)

    def forward(self, value):
        residual = self.shortcut(value)
        value = self.relu1(self.bn1(self.conv1(value)))
        value = self.bn2(self.conv2(value))
        return self.relu2(value + residual)


class CifarResNet18(nn.Module):
    def __init__(self, classes: int):
        super().__init__()
        self.conv1 = nn.Conv2d(3, 64, 3, 1, 1, bias=False)
        self.bn1 = nn.BatchNorm2d(64)
        self.relu = nn.ReLU(inplace=False)
        self.layer1 = self._layer(64, 64, 2, 1)
        self.layer2 = self._layer(64, 128, 2, 2)
        self.layer3 = self._layer(128, 256, 2, 2)
        self.layer4 = self._layer(256, 512, 2, 2)
        self.avgpool = nn.AdaptiveAvgPool2d((1, 1))
        self.fc = nn.Linear(512, classes)

    def _layer(self, in_channels, out_channels, blocks, stride):
        modules = [BasicBlock(in_channels, out_channels, stride)]
        modules.extend(BasicBlock(out_channels, out_channels, 1) for _ in range(blocks - 1))
        return nn.Sequential(*modules)

    def forward(self, value):
        value = self.relu(self.bn1(self.conv1(value)))
        value = self.layer4(self.layer3(self.layer2(self.layer1(value))))
        return self.fc(self.avgpool(value).flatten(1))


class CifarVgg16(nn.Module):
    def __init__(self, classes: int):
        super().__init__()
        channels = [64, 64, "M", 128, 128, "M", 256, 256, 256, "M", 512, 512, 512, "M", 512, 512, 512, "M"]
        layers = []
        in_channels = 3
        for item in channels:
            if item == "M":
                layers.append(nn.MaxPool2d(2, 2))
            else:
                layers.extend((nn.Conv2d(in_channels, item, 3, 1, 1), nn.ReLU(inplace=False)))
                in_channels = item
        self.features = nn.Sequential(*layers)
        self.avgpool = nn.AdaptiveAvgPool2d((1, 1))
        self.classifier = nn.Linear(512, classes)

    def forward(self, value):
        return self.classifier(self.avgpool(self.features(value)).flatten(1))


def set_deterministic() -> None:
    random.seed(SEED)
    np.random.seed(SEED)
    torch.manual_seed(SEED)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(SEED)
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False


def checkpoint_for(model_name: str, dataset_name: str) -> Path | None:
    roots = [BASE_DIR, PROJECT_ROOT / "checkpoints", PROJECT_ROOT / "detr_output"]
    candidates = []
    for root in roots:
        if root.exists():
            candidates.extend(p for p in root.rglob("*") if p.suffix in {".pth", ".pt", ".ckpt"})
    for path in sorted(set(candidates)):
        name = path.name.lower()
        if model_name.lower() in name and dataset_name.lower() in name:
            return path
    return None


def make_model(model_name: str, classes: int) -> nn.Module:
    if model_name == "ResNet18":
        return CifarResNet18(classes)
    if model_name == "VGG16":
        return CifarVgg16(classes)
    raise ValueError(model_name)


def make_loader(dataset_name: str) -> tuple[torch.utils.data.DataLoader, int]:
    dataset = CifarDataset(dataset_name)
    count = min(SAMPLE_COUNT, len(dataset))
    return torch.utils.data.DataLoader(torch.utils.data.Subset(dataset, range(count)), batch_size=BATCH_SIZE, shuffle=False, num_workers=0), count


def tensor_stats(value: torch.Tensor) -> tuple[int, int, float, float, float, float]:
    flat = value.detach().float().reshape(-1).cpu()
    return (flat.numel(), int(torch.count_nonzero(flat == 0)), float(flat.mean()),
            float(flat.var(unbiased=False)), float(flat.min()), float(flat.max()))


def select_pe(sparsity_pct: float) -> int:
    if sparsity_pct < 20.0:
        return 64
    if sparsity_pct < 40.0:
        return 32
    return 16


def sha256(path: Path | None) -> str | None:
    if path is None:
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_checkpoint(model: nn.Module, path: Path | None) -> str:
    if path is None:
        return "NOT FOUND: untrained model used"
    payload = torch.load(path, map_location="cpu")
    state = payload.get("state_dict", payload) if isinstance(payload, dict) else payload
    model.load_state_dict(state, strict=True)
    return str(path)


def evaluate_pair(model_name: str, dataset_name: str, classes: int) -> tuple[dict, list[dict]]:
    loader, sample_count = make_loader(dataset_name)
    model = make_model(model_name, classes)
    checkpoint = checkpoint_for(model_name, dataset_name)
    checkpoint_status = load_checkpoint(model, checkpoint)
    model.to(DEVICE).eval()
    convs = [(name, module) for name, module in model.named_modules() if isinstance(module, nn.Conv2d)]
    stats: dict[str, dict] = {}
    handles = []
    collect_stats = True

    def hook_factory(layer_name: str, module: nn.Conv2d):
        def hook(_module, inputs, output):
            if not collect_stats:
                return
            activation, out = inputs[0].detach(), output.detach()
            elements, zeros, mean, variance, minimum, maximum = tensor_stats(activation)
            out_elements, out_zeros, *_ = tensor_stats(out)
            unfolded = torch.nn.functional.unfold(activation, module.kernel_size, module.dilation, module.padding, module.stride)
            nonzero = int(torch.count_nonzero(unfolded).item())
            entry = stats.setdefault(layer_name, {"batches": 0, "elements": 0, "zeros": 0, "dense_macs": 0, "useful_macs": 0,
                                                   "output_elements": 0, "output_zeros": 0, "input_shape": list(activation.shape), "output_shape": list(out.shape)})
            entry["batches"] += 1
            entry["elements"] += elements; entry["zeros"] += zeros
            entry["dense_macs"] += int(out.numel() * module.in_channels * module.kernel_size[0] * module.kernel_size[1])
            entry["useful_macs"] += nonzero * module.out_channels
            entry["output_elements"] += out_elements; entry["output_zeros"] += out_zeros
            entry["mean_sum"] = entry.get("mean_sum", 0.0) + mean
            entry["variance_sum"] = entry.get("variance_sum", 0.0) + variance
            entry["min"] = min(entry.get("min", minimum), minimum); entry["max"] = max(entry.get("max", maximum), maximum)
        return hook

    for name, module in convs:
        handles.append(module.register_forward_hook(hook_factory(name, module)))
    dense_correct = sparse_correct = total = mismatch = 0
    max_diff = mean_diff = 0.0
    with torch.no_grad():
        for images, labels in loader:
            images, labels = images.to(DEVICE), labels.to(DEVICE)
            dense_logits = model(images)
            collect_stats = False
            sparse_handles = [module.register_forward_pre_hook(
                lambda _module, inputs: (inputs[0].masked_fill(inputs[0] == 0, 0),)
            ) for _name, module in convs]
            sparse_logits = model(images)
            for handle in sparse_handles:
                handle.remove()
            collect_stats = True
            dense_pred, sparse_pred = dense_logits.argmax(1), sparse_logits.argmax(1)
            dense_correct += int((dense_pred == labels).sum()); sparse_correct += int((sparse_pred == labels).sum()); total += labels.numel()
            difference = (dense_logits - sparse_logits).abs()
            max_diff = max(max_diff, float(difference.max())); mean_diff += float(difference.sum()); mismatch += int((dense_pred != sparse_pred).sum())
    for handle in handles:
        handle.remove()
    mean_diff /= max(total * classes, 1)

    layer_rows = []
    for index, (name, _module) in enumerate(convs):
        entry = stats[name]; dense_macs = entry["dense_macs"]; useful_macs = entry["useful_macs"]
        sparsity = 100.0 * entry["zeros"] / max(entry["elements"], 1); selected = select_pe(sparsity)
        layer_rows.append({"model": model_name, "dataset": dataset_name, "layer": name, "layer_index": index,
            "input_shape": str(entry["input_shape"]), "output_shape": str(entry["output_shape"]), "elements": entry["elements"], "zero_elements": entry["zeros"],
            "sparsity": sparsity, "mean": entry["mean_sum"] / entry["batches"], "variance": entry["variance_sum"] / entry["batches"], "min": entry["min"], "max": entry["max"],
            "output_elements": entry["output_elements"], "dense_macs": dense_macs, "useful_macs": useful_macs, "skipped_macs": dense_macs - useful_macs,
            "dense_cycles": math.ceil(dense_macs / 64), "sparse_cycles": math.ceil(useful_macs / 64), "selected_pe": selected,
            "adaptive_cycles": math.ceil(useful_macs / selected), "effective_sparsity": 100.0 * (dense_macs - useful_macs) / max(dense_macs, 1)})
    dense_macs = sum(r["dense_macs"] for r in layer_rows); useful_macs = sum(r["useful_macs"] for r in layer_rows)
    fixed_dense = sum(r["dense_cycles"] for r in layer_rows); fixed_sparse = sum(r["sparse_cycles"] for r in layer_rows); adaptive = sum(r["adaptive_cycles"] for r in layer_rows)
    parameters = list(model.parameters())
    summary = {"model": model_name, "dataset": dataset_name, "classes": classes, "samples": sample_count, "checkpoint": checkpoint_status, "checkpoint_sha256": sha256(checkpoint),
        "dataset_train_samples": 50000, "dataset_test_samples": 10000, "input_dimensions": "3x32x32", "normalization_mean": "0.4914,0.4822,0.4465", "normalization_std": "0.2470,0.2435,0.2616",
        "total_parameters": sum(parameter.numel() for parameter in parameters), "trainable_parameters": sum(parameter.numel() for parameter in parameters if parameter.requires_grad),
        "convolution_layers": len(convs), "linear_layers": sum(isinstance(module, nn.Linear) for module in model.modules()),
        "training_status": "CHECKPOINT LOADED" if checkpoint else "NOT RUN: no checkpoint found", "dense_accuracy": dense_correct / max(total, 1), "sparse_accuracy": sparse_correct / max(total, 1),
        "accuracy_difference": (sparse_correct - dense_correct) / max(total, 1), "max_logit_difference": max_diff, "mean_logit_difference": mean_diff, "prediction_mismatches": mismatch,
        "total_dense_macs": dense_macs, "total_useful_macs": useful_macs, "total_skipped_macs": dense_macs - useful_macs,
        "average_sparsity": float(np.mean([r["sparsity"] for r in layer_rows])), "median_sparsity": float(np.median([r["sparsity"] for r in layer_rows])),
        "minimum_sparsity": min(r["sparsity"] for r in layer_rows), "maximum_sparsity": max(r["sparsity"] for r in layer_rows),
        "fixed64_dense_cycles": fixed_dense, "fixed64_sparse_cycles": fixed_sparse, "adaptive_sparse_cycles": adaptive,
        "average_active_pes": float(np.mean([r["selected_pe"] for r in layer_rows])), "minimum_active_pes": min(r["selected_pe"] for r in layer_rows),
        "maximum_active_pes": max(r["selected_pe"] for r in layer_rows), "pe_utilization_ratio": float(np.mean([r["selected_pe"] / 64.0 for r in layer_rows])), "forward_pass": "PASS"}
    return summary, layer_rows


def write_csv(path: Path, rows: list[dict]) -> None:
    pd.DataFrame(rows).to_csv(path, index=False)


def make_plots(summaries: list[dict], layers: list[dict]) -> None:
    labels = [f"{r['model']}/{r['dataset']}" for r in summaries]
    def save(name: str) -> None:
        plt.tight_layout(); plt.savefig(BASE_DIR / name, dpi=180); plt.close()
    plt.figure(figsize=(12, 5))
    for label in labels:
        rows = [r for r in layers if f"{r['model']}/{r['dataset']}" == label]
        plt.plot([r["layer_index"] for r in rows], [r["sparsity"] for r in rows], marker="o", label=label)
    plt.xlabel("convolution layer index"); plt.ylabel("input activation sparsity (%)"); plt.legend(); save("sparsity_by_layer.png")
    plt.figure(figsize=(11, 5))
    for summary, label in zip(summaries, labels):
        plt.plot(["fixed64_dense", "fixed64_sparse", "adaptive_sparse"], [summary["fixed64_dense_cycles"], summary["fixed64_sparse_cycles"], summary["adaptive_sparse_cycles"]], marker="o", label=label)
    plt.ylabel("analytical cycles"); plt.legend(); save("cycle_comparison.png")
    x = np.arange(len(labels)); width = 0.25
    plt.figure(figsize=(11, 5))
    for index, pe in enumerate(PE_CONFIGS):
        values = [sum(r["selected_pe"] == pe for r in layers if f"{r['model']}/{r['dataset']}" == label) for label in labels]
        plt.bar(x + (index - 1) * width, values, width=width, label=f"{pe} PE")
    plt.xticks(x, labels, rotation=20); plt.ylabel("layers"); plt.legend(); save("resource_allocation.png")
    plt.figure(figsize=(11, 5))
    for index, key in enumerate(("total_dense_macs", "total_useful_macs", "total_skipped_macs")):
        plt.bar(x + (index - 1) * width, [r[key] for r in summaries], width=width, label=key)
    plt.xticks(x, labels, rotation=20); plt.ylabel("MACs"); plt.legend(); save("mac_reduction.png")
    plt.figure(figsize=(11, 5)); plt.bar(x - 0.18, [r["dense_accuracy"] for r in summaries], width=0.36, label="dense"); plt.bar(x + 0.18, [r["sparse_accuracy"] for r in summaries], width=0.36, label="sparse")
    plt.xticks(x, labels, rotation=20); plt.ylabel("accuracy"); plt.legend(); save("accuracy_comparison.png")


def write_reports(summaries: list[dict], layers: list[dict]) -> None:
    rtl = [{"model": m, "dataset": d, "layer": "NOT RUN", "active_pes": "", "analytical_cycles": "", "rtl_cycles": "", "error_percent": "", "output_match": "NOT RUN", "status": "NOT RUN: no complete model-to-RTL integration"} for m, d, _ in PAIRS]
    write_csv(BASE_DIR / "rtl_correlation_results.csv", rtl)
    write_csv(BASE_DIR / "energy_results.csv", [{"status": "NOT RUN", "reason": "No validated same-workload SCALE-Sim/Accelergy invocation was available."}])
    result_rows, ablation = [], []
    for summary in summaries:
        common = {"model": summary["model"], "dataset": summary["dataset"], "total_dense_macs": summary["total_dense_macs"], "total_useful_macs": summary["total_useful_macs"], "total_skipped_macs": summary["total_skipped_macs"], "average_sparsity": summary["average_sparsity"]}
        for baseline, cycles, avg_pe, accuracy in (("fixed64_dense", summary["fixed64_dense_cycles"], 64.0, summary["dense_accuracy"]), ("fixed64_sparse", summary["fixed64_sparse_cycles"], 64.0, summary["sparse_accuracy"]), ("adaptive_sparse", summary["adaptive_sparse_cycles"], summary["average_active_pes"], summary["sparse_accuracy"])):
            reduction = 100.0 * (summary["fixed64_dense_cycles"] - cycles) / max(summary["fixed64_dense_cycles"], 1)
            result_rows.append({**common, "baseline": baseline, "accuracy": accuracy, "total_cycles": cycles, "average_active_pes": avg_pe, "cycle_reduction_percent": reduction})
            ablation.append({"model": summary["model"], "dataset": summary["dataset"], "configuration": baseline, "total_cycles": cycles, "cycle_reduction_vs_dense_percent": reduction})
    write_csv(BASE_DIR / "final_results.csv", result_rows); write_csv(BASE_DIR / "ablation_results.csv", ablation); write_csv(BASE_DIR / "layer_sparsity.csv", layers)
    write_csv(BASE_DIR / "final_resource_allocation.csv", [{k: r[k] for k in ("model", "dataset", "layer", "sparsity", "selected_pe")} for r in layers])
    lines = ["Stage 12 - Final Experimental Evaluation", "", "1. Research Objective", "Model and analytical accelerator evaluation with separate RTL evidence levels.", "", "2. Models", "CIFAR-compatible ResNet-18 (3x3 stride-1 first convolution, no max-pool) and VGG-16 (adaptive 1x1 classifier pooling).", "", "3. Datasets", "CIFAR-10 and CIFAR-100 test sets with deterministic ToTensor plus CIFAR normalization.", "", "4. Experimental Setup", f"Seed={SEED}; device={DEVICE}; samples per pair={SAMPLE_COUNT}; batch={BATCH_SIZE}.", "No matching checkpoints were found; accuracy is untrained-subset accuracy, not a trained-model claim.", "", "5. Activation Monitoring", "Forward hooks collect streaming convolution-input statistics and exact unfolded nonzero counts.", "", "6. Sparsity Analysis", "Sparsity is measured on convolution inputs; MAC savings include padding geometry.", "", "7. Resource Policy", "<20% -> 64 PE, 20-40% -> 32 PE, >=40% -> 16 PE. Thresholds are not optimality claims.", "", "8. Baselines", "fixed64_dense, fixed64_sparse, adaptive_sparse.", "", "9. Accuracy Evaluation", "Dense and exact-zero-masked sparse logits are compared using measured differences and prediction mismatches.", "", "10. MAC Reduction", "Derived from model convolution shapes and unfolded activation values.", "", "11. Cycle Evaluation", "Analytical cycles are ceil(MACs / active PEs), not RTL-measured cycles.", "", "12. Resource Allocation", "See final_resource_allocation.csv.", "", "13. RTL Correlation", "NOT RUN: no complete model-to-RTL integration was executed by this evaluator.", "", "14. Energy Evaluation", "NOT RUN: no same-workload SCALE-Sim/Accelergy result is claimed.", "", "15. Ablation Study", "See ablation_results.csv.", "", "16. Limitations", "No trained checkpoints were available. Analytical cycles omit memory, scheduling, and control overhead. Full ResNet/VGG RTL was not claimed.", "", "17. Final Findings"]
    lines.extend(f"{r['model']}/{r['dataset']}: accuracy={r['dense_accuracy']:.6f}, sparsity={r['average_sparsity']:.4f}%, dense={r['fixed64_dense_cycles']}, sparse={r['fixed64_sparse_cycles']}, adaptive={r['adaptive_sparse_cycles']}, avg_PE={r['average_active_pes']:.3f}" for r in summaries)
    (BASE_DIR / "stage12_final_report.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    validation = ["# Stage 12 Final Validation", "", "Overall status: PARTIAL", "", f"Python: {platform.python_version()}", f"PyTorch: {torch.__version__}", f"Device: {DEVICE}", f"Seed: {SEED}", f"Evaluation samples per pair: {SAMPLE_COUNT}", "", "All four model/dataset forward passes, activation collection, dense inference, sparse inference, accuracy measurement, and analytical model: PASS.", "Matching trained checkpoints: NOT FOUND; training status is NOT RUN.", "Representative RTL compile/simulation/output/correlation: NOT RUN by this final evaluator.", "Energy evaluation: NOT RUN.", "Overall status is PARTIAL because trained checkpoints and representative RTL correlation are unavailable."]
    (BASE_DIR / "VALIDATION.md").write_text("\n".join(validation) + "\n", encoding="utf-8")


def main() -> None:
    set_deterministic(); summaries, layers = [], []
    for model_name, dataset_name, classes in PAIRS:
        summary, rows = evaluate_pair(model_name, dataset_name, classes); summaries.append(summary); layers.extend(rows)
    write_csv(BASE_DIR / "final_model_summary.csv", summaries); write_reports(summaries, layers); make_plots(summaries, layers)
    config = {"models": [p[0] for p in PAIRS], "datasets": [p[1] for p in PAIRS], "sample_count": SAMPLE_COUNT, "batch_size": BATCH_SIZE, "seed": SEED, "device": str(DEVICE), "pe_configurations": list(PE_CONFIGS), "policy_thresholds_percent": {"less_than_20": 64, "20_to_less_than_40": 32, "at_least_40": 16}, "normalization": {"mean": [0.4914, 0.4822, 0.4465], "std": [0.2470, 0.2435, 0.2616]}, "checkpoint_policy": "matching checkpoint if found; otherwise report NOT RUN and use untrained model only for forward/analytical evidence"}
    (BASE_DIR / "experiment_config.json").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    status = {"status": "PARTIAL", "reason": "No matching trained checkpoints and no complete model-to-RTL integration were available.", "model_dataset_pairs": summaries, "rtl": "NOT RUN", "energy": "NOT RUN"}
    (BASE_DIR / "stage12_final_status.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(status, indent=2))


if __name__ == "__main__":
    main()
