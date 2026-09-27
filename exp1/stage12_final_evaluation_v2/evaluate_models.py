#!/usr/bin/env python3
from __future__ import annotations
import csv, hashlib, json, math, platform
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import torch
from torch import nn
try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"EVALUATION_NOT_RUN: PyYAML unavailable: {exc}")
from common import CifarDataset, make_model, seed_everything

ROOT = Path(__file__).resolve().parent; RESULTS = ROOT / "results"; PLOTS = RESULTS / "plots"; CHECKPOINTS = ROOT / "checkpoints"
CONFIG = yaml.safe_load((ROOT / "CONFIG.yaml").read_text()); DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

def write_rows(path, rows):
    pd.DataFrame(rows).to_csv(path, index=False)

def checkpoint_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""): digest.update(block)
    return digest.hexdigest()

def load_pair(model_name, dataset_name):
    path = CHECKPOINTS / f"{model_name}_{dataset_name}.pt"
    if not path.exists(): return None, f"NOT RUN: checkpoint missing ({path.name})"
    model = make_model(model_name, CONFIG["classes"][dataset_name])
    payload = torch.load(path, map_location="cpu")
    try: model.load_state_dict(payload["model_state_dict"], strict=True)
    except (KeyError, RuntimeError) as exc: return None, f"NOT RUN: incompatible checkpoint: {exc}"
    return model.to(DEVICE).eval(), str(path)

def stats_hook(stats, name, module, enabled):
    def hook(_module, inputs, output):
        if not enabled[0]: return
        activation, result = inputs[0].detach(), output.detach()
        unfolded = torch.nn.functional.unfold(activation, module.kernel_size, module.dilation, module.padding, module.stride)
        nonzero = int(torch.count_nonzero(unfolded).item())
        entry = stats.setdefault(name, {"batches": 0, "elements": 0, "zeros": 0, "dense_macs": 0, "useful_macs": 0, "input_shape": list(activation.shape), "output_shape": list(result.shape)})
        entry["batches"] += 1; entry["elements"] += activation.numel(); entry["zeros"] += int(torch.count_nonzero(activation == 0)); entry["dense_macs"] += result.numel() * module.in_channels * module.kernel_size[0] * module.kernel_size[1]; entry["useful_macs"] += nonzero * module.out_channels
    return hook

def choose_pe(useful_macs, epsilon):
    baseline = math.ceil(useful_macs / 64)
    allowed = math.ceil(baseline * (1.0 + epsilon))
    for pe in (16, 32, 64):
        if math.ceil(useful_macs / pe) <= allowed: return pe, baseline, math.ceil(useful_macs / pe), allowed
    return 64, baseline, baseline, allowed

def evaluate(model_name, dataset_name):
    model, checkpoint = load_pair(model_name, dataset_name)
    if model is None: return None, {"model": model_name, "dataset": dataset_name, "status": checkpoint}
    dataset = CifarDataset(dataset_name, train=False); count = min(CONFIG["test_samples"], len(dataset)); loader = torch.utils.data.DataLoader(torch.utils.data.Subset(dataset, range(count)), batch_size=CONFIG["batch_size"], shuffle=False, num_workers=0)
    convs = [(name, module) for name, module in model.named_modules() if isinstance(module, nn.Conv2d)]; stats = {}; enabled = [True]
    handles = [module.register_forward_hook(stats_hook(stats, name, module, enabled)) for name, module in convs]
    dense_correct = sparse_correct = total = prediction_mismatches = 0; max_diff = mean_diff = 0.0
    with torch.no_grad():
        for images, labels in loader:
            images, labels = images.to(DEVICE), labels.to(DEVICE); dense_logits = model(images); enabled[0] = False
            sparse_handles = [module.register_forward_pre_hook(lambda _module, inputs: (inputs[0].masked_fill(inputs[0] == 0, 0),)) for _name, module in convs]
            sparse_logits = model(images)
            for handle in sparse_handles: handle.remove()
            enabled[0] = True
            dense_pred, sparse_pred = dense_logits.argmax(1), sparse_logits.argmax(1); dense_correct += int((dense_pred == labels).sum()); sparse_correct += int((sparse_pred == labels).sum()); total += labels.numel(); prediction_mismatches += int((dense_pred != sparse_pred).sum())
            diff = (dense_logits - sparse_logits).abs(); max_diff = max(max_diff, float(diff.max())); mean_diff += float(diff.sum())
    for handle in handles: handle.remove()
    mean_diff /= max(total * CONFIG["classes"][dataset_name], 1)
    layer_rows = []
    for index, (name, _module) in enumerate(convs):
        item = stats[name]; dense = int(item["dense_macs"]); useful = int(item["useful_macs"]); sparsity = 100.0 * item["zeros"] / max(item["elements"], 1)
        for epsilon in CONFIG["sensitivity_epsilons"]:
            selected, baseline, adaptive, allowed = choose_pe(useful, epsilon)
            layer_rows.append({"model": model_name, "dataset": dataset_name, "layer": name, "layer_index": index, "input_shape": str(item["input_shape"]), "output_shape": str(item["output_shape"]), "sparsity": sparsity, "dense_macs": dense, "useful_macs": useful, "skipped_macs": dense - useful, "mac_reduction_percent": 100.0 * (dense - useful) / max(dense, 1), "epsilon": epsilon, "selected_pes": selected, "fixed64_cycles": baseline, "adaptive_cycles": adaptive, "allowed_cycles": allowed, "latency_increase_percent": 100.0 * (adaptive - baseline) / max(baseline, 1), "active_pe_reduction_percent": 100.0 * (64 - selected) / 64})
    primary = [r for r in layer_rows if r["epsilon"] == CONFIG["adaptive_latency_epsilon"]]; dense_macs = sum(r["dense_macs"] for r in primary); useful_macs = sum(r["useful_macs"] for r in primary); fixed_dense = sum(math.ceil(r["dense_macs"] / 64) for r in primary); fixed_sparse = sum(r["fixed64_cycles"] for r in primary); adaptive = sum(r["adaptive_cycles"] for r in primary)
    summary = {"model": model_name, "dataset": dataset_name, "status": "PASS", "checkpoint": checkpoint, "checkpoint_sha256": checkpoint_digest(Path(checkpoint)), "test_samples": total, "test_accuracy": dense_correct / total, "sparse_accuracy": sparse_correct / total, "dense_correct": dense_correct, "sparse_correct": sparse_correct, "dense_incorrect": total - dense_correct, "sparse_incorrect": total - sparse_correct, "max_abs_logit_difference": max_diff, "mean_abs_logit_difference": mean_diff, "number_of_prediction_mismatches": prediction_mismatches, "mean_sparsity": float(np.mean([r["sparsity"] for r in primary])), "dense_MACs": dense_macs, "useful_MACs": useful_macs, "skipped_MACs": dense_macs - useful_macs, "MAC_reduction_percent": 100.0 * (dense_macs - useful_macs) / max(dense_macs, 1), "fixed64_dense_cycles": fixed_dense, "fixed64_sparse_cycles": fixed_sparse, "fixed64_cycle_reduction_percent": 100.0 * (fixed_dense - fixed_sparse) / max(fixed_dense, 1), "adaptive_cycles": adaptive, "adaptive_latency_change_percent": 100.0 * (adaptive - fixed_sparse) / max(fixed_sparse, 1), "average_active_PEs": float(np.mean([r["selected_pes"] for r in primary])), "active_PE_reduction_percent": 100.0 * (64 - np.mean([r["selected_pes"] for r in primary])) / 64, "rtl_correlation_status": "NOT RUN", "energy_status": "NOT RUN"}
    return summary, layer_rows

def make_plots(summaries, layers):
    PLOTS.mkdir(exist_ok=True); labels = [f"{r['model']}/{r['dataset']}" for r in summaries];
    def save(name): plt.tight_layout(); plt.savefig(PLOTS / name, dpi=180); plt.close()
    plt.figure(figsize=(12, 5))
    for label in labels:
        rows = [r for r in layers if f"{r['model']}/{r['dataset']}" == label and r["epsilon"] == CONFIG["adaptive_latency_epsilon"]]; plt.plot(range(len(rows)), [r["sparsity"] for r in rows], marker="o", label=label)
    plt.xlabel("convolution layer index"); plt.ylabel("exact-zero sparsity (%)"); plt.legend(); save("per_layer_sparsity.png")
    x = np.arange(len(labels)); width = 0.25
    for keys, name, ylabel in [(("dense_MACs", "useful_MACs"), "macs_dense_useful.png", "MACs"), (("fixed64_dense_cycles", "fixed64_sparse_cycles"), "cycles_fixed64.png", "analytical cycles"), (("fixed64_sparse_cycles", "adaptive_cycles"), "cycles_fixed64_vs_adaptive.png", "analytical cycles")]:
        plt.figure(figsize=(11, 5));
        for index, key in enumerate(keys): plt.bar(x + (index - (len(keys)-1)/2) * width, [r[key] for r in summaries], width=width, label=key)
        plt.xticks(x, labels, rotation=20); plt.ylabel(ylabel); plt.legend(); save(name)
    plt.figure(figsize=(11, 5));
    for label in labels:
        rows = [r for r in layers if f"{r['model']}/{r['dataset']}" == label and r["epsilon"] == CONFIG["adaptive_latency_epsilon"]]; plt.plot(range(len(rows)), [r["selected_pes"] for r in rows], marker="o", label=label)
    plt.xlabel("convolution layer index"); plt.ylabel("active PEs"); plt.legend(); save("active_pe_allocation.png")
    plt.figure(figsize=(11, 5)); plt.bar(x - 0.18, [r["test_accuracy"] for r in summaries], width=0.36, label="dense"); plt.bar(x + 0.18, [r["sparse_accuracy"] for r in summaries], width=0.36, label="exact-zero sparse"); plt.xticks(x, labels, rotation=20); plt.ylabel("top-1 accuracy"); plt.legend(); save("accuracy_dense_sparse.png")

def main():
    seed_everything(CONFIG["seed"]); RESULTS.mkdir(exist_ok=True); summaries, layers, accuracy_rows = [], [], []
    for model_name in CONFIG["models"]:
        for dataset_name in CONFIG["datasets"]:
            summary, rows = evaluate(model_name, dataset_name)
            summaries.append(summary); layers.extend(rows)
            if summary: accuracy_rows.append({k: summary[k] for k in ("model", "dataset", "test_samples", "test_accuracy", "dense_correct", "dense_incorrect")})
    write_rows(RESULTS / "test_accuracy.csv", accuracy_rows); write_rows(RESULTS / "per_layer_sparsity.csv", layers); write_rows(RESULTS / "dense_vs_sparse.csv", [{k: r[k] for k in ("model", "dataset", "test_samples", "test_accuracy", "sparse_accuracy", "max_abs_logit_difference", "mean_abs_logit_difference", "number_of_prediction_mismatches")} for r in summaries if r])
    write_rows(RESULTS / "final_summary.csv", summaries); write_rows(RESULTS / "per_layer_summary.csv", [r for r in layers if r["epsilon"] == CONFIG["adaptive_latency_epsilon"]]); make_plots([r for r in summaries if r], layers)
    (RESULTS / "evaluation_environment.json").write_text(json.dumps({"python": platform.python_version(), "torch": torch.__version__, "device": str(DEVICE), "seed": CONFIG["seed"]}, indent=2) + "\n")
    print(json.dumps(summaries, indent=2))

if __name__ == "__main__": main()
