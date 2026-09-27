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
import yaml
from common import CifarDataset, make_model, seed_everything

ROOT = Path(__file__).resolve().parent; CONFIG = yaml.safe_load((ROOT / "CONFIG.yaml").read_text()); RESULTS = ROOT / "results"; PLOTS = RESULTS / "plots"; CHECKPOINTS = ROOT / "checkpoints"; DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

def save(path, rows): pd.DataFrame(rows).to_csv(path, index=False)
def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""): result.update(block)
    return result.hexdigest()
def choose_pe(useful, epsilon):
    baseline = math.ceil(useful / 64); allowed = math.ceil(baseline * (1 + epsilon))
    for pe in CONFIG["resource_options"]:
        cycles = math.ceil(useful / pe)
        if cycles <= allowed: return pe, baseline, cycles, allowed
    return 64, baseline, baseline, allowed

def evaluate_pair(model_name, dataset_name, limit: int | None = None):
    checkpoint = CHECKPOINTS / f"{model_name}_{dataset_name}_best.pt"; summary_status = {"model": model_name, "dataset": dataset_name}
    if not checkpoint.exists(): return [], [], summary_status | {"status": "NOT RUN", "reason": "best checkpoint missing"}
    model = make_model(model_name, CONFIG["classes"][dataset_name]); payload = torch.load(checkpoint, map_location="cpu")
    try: model.load_state_dict(payload["model_state_dict"], strict=True)
    except (KeyError, RuntimeError) as exc: return [], [], summary_status | {"status": "NOT RUN", "reason": repr(exc)}
    model.to(DEVICE).eval(); dataset = CifarDataset(dataset_name, False); 
    if limit is not None:
        dataset = torch.utils.data.Subset(dataset, list(range(min(limit, len(dataset)))))
    loader = torch.utils.data.DataLoader(dataset, batch_size=CONFIG["batch_size"], shuffle=False, num_workers=0)
    convs = [("layer0" if index == 0 else name, module) for index, (name, module) in enumerate((item for item in model.named_modules() if isinstance(item[1], nn.Conv2d)))]; stats = {}; collect = [True]
    def make_hook(name, module):
        def hook(_module, inputs, output):
            if not collect[0]: return
            activation, result = inputs[0].detach(), output.detach(); unfolded = torch.nn.functional.unfold(activation, module.kernel_size, module.dilation, module.padding, module.stride); entry = stats.setdefault(name, {"batches": 0, "input_elements": 0, "zero_elements": 0, "unfolded_elements": 0, "unfolded_nonzero": 0, "dense_macs": 0, "useful_macs": 0, "input_shape": list(activation.shape), "output_shape": list(result.shape)})
            entry["batches"] += 1; entry["input_elements"] += activation.numel(); entry["zero_elements"] += int(torch.count_nonzero(activation == 0)); entry["unfolded_elements"] += unfolded.numel(); entry["unfolded_nonzero"] += int(torch.count_nonzero(unfolded)); entry["dense_macs"] += result.numel() * module.in_channels * module.kernel_size[0] * module.kernel_size[1]; entry["useful_macs"] += int(torch.count_nonzero(unfolded)) * module.out_channels
        return hook
    handles = [module.register_forward_hook(make_hook(name, module)) for name, module in convs]; dense_correct = sparse_correct = total = mismatches = 0; max_diff = mean_diff = 0.0
    with torch.no_grad():
        for images, labels in loader:
            images, labels = images.to(DEVICE), labels.to(DEVICE); dense_logits = model(images); collect[0] = False; sparse_handles = [module.register_forward_pre_hook(lambda _module, inputs: (inputs[0].masked_fill(inputs[0] == 0, 0),)) for _name, module in convs]; sparse_logits = model(images)
            for handle in sparse_handles: handle.remove()
            collect[0] = True; dense_pred, sparse_pred = dense_logits.argmax(1), sparse_logits.argmax(1); dense_correct += int((dense_pred == labels).sum()); sparse_correct += int((sparse_pred == labels).sum()); total += labels.numel(); mismatches += int((dense_pred != sparse_pred).sum()); difference = (dense_logits - sparse_logits).abs(); max_diff = max(max_diff, float(difference.max())); mean_diff += float(difference.sum())
    for handle in handles: handle.remove()
    mean_diff /= max(total * CONFIG["classes"][dataset_name], 1); layer_rows = []; policy_rows = []
    for index, (name, _module) in enumerate(convs):
        item = stats[name]; dense = int(item["dense_macs"]); useful = int(item["useful_macs"]); activation_sparsity = 100 * item["zero_elements"] / max(item["input_elements"], 1); effective_sparsity = 100 * (1 - item["unfolded_nonzero"] / max(item["unfolded_elements"], 1))
        for epsilon in CONFIG["sensitivity_epsilons"]:
            pe, baseline, adaptive, allowed = choose_pe(useful, epsilon); policy_rows.append({"model": model_name, "dataset": dataset_name, "layer": name, "sparsity": activation_sparsity, "effective_unfolded_sparsity": effective_sparsity, "useful_MACs": useful, "epsilon": epsilon, "selected_PEs": pe, "fixed64_cycles": baseline, "adaptive_cycles": adaptive, "allowed_cycles": allowed, "latency_increase_percent": 100 * (adaptive - baseline) / max(baseline, 1), "active_PE_reduction_percent": 100 * (64 - pe) / 64})
        primary = [row for row in policy_rows if row["layer"] == name and row["epsilon"] == CONFIG["adaptive_latency_epsilon"]][0]; layer_rows.append({"model": model_name, "dataset": dataset_name, "layer": name, "input_shape": str(item["input_shape"]), "output_shape": str(item["output_shape"]), "input_elements": item["input_elements"], "zero_elements": item["zero_elements"], "sparsity": activation_sparsity, "effective_unfolded_sparsity": effective_sparsity, "dense_macs": dense, "useful_macs": useful, "skipped_macs": dense - useful, "mac_reduction_percent": 100 * (dense - useful) / max(dense, 1), "fixed64_dense_cycles": math.ceil(dense / 64), "fixed64_sparse_cycles": math.ceil(useful / 64), "selected_PEs": primary["selected_PEs"], "adaptive_cycles": primary["adaptive_cycles"]})
    dense_macs = sum(row["dense_macs"] for row in layer_rows); useful_macs = sum(row["useful_macs"] for row in layer_rows); dense_cycles = sum(row["fixed64_dense_cycles"] for row in layer_rows); sparse_cycles = sum(row["fixed64_sparse_cycles"] for row in layer_rows); adaptive_cycles = sum(row["adaptive_cycles"] for row in layer_rows); avg_pe = float(np.mean([row["selected_PEs"] for row in layer_rows]))
    summary = {"model": model_name, "dataset": dataset_name, "status": "PASS", "checkpoint": str(checkpoint), "checkpoint_sha256": digest(checkpoint), "test_samples": total, "dense_accuracy": dense_correct / total, "sparse_accuracy": sparse_correct / total, "accuracy_change_percentage_points": 100 * (sparse_correct - dense_correct) / total, "dense_correct": dense_correct, "dense_incorrect": total - dense_correct, "sparse_correct": sparse_correct, "sparse_incorrect": total - sparse_correct, "max_abs_logit_difference": max_diff, "mean_abs_logit_difference": mean_diff, "prediction_mismatches": mismatches, "mean_activation_sparsity": float(np.mean([r["sparsity"] for r in layer_rows])), "mean_effective_unfolded_sparsity": float(np.mean([r["effective_unfolded_sparsity"] for r in layer_rows])), "dense_MACs": dense_macs, "useful_MACs": useful_macs, "skipped_MACs": dense_macs - useful_macs, "MAC_reduction_percent": 100 * (dense_macs - useful_macs) / dense_macs, "fixed64_dense_cycles": dense_cycles, "fixed64_sparse_cycles": sparse_cycles, "fixed64_cycle_reduction_percent": 100 * (dense_cycles - sparse_cycles) / dense_cycles, "adaptive_cycles": adaptive_cycles, "adaptive_latency_change_percent": 100 * (adaptive_cycles - sparse_cycles) / sparse_cycles, "average_active_PEs": avg_pe, "rtl_status": "NOT RUN", "energy_status": "NOT RUN"}
    return layer_rows, policy_rows, summary

def plots(summaries, layers):
    PLOTS.mkdir(exist_ok=True); labels = [f"{r['model']}/{r['dataset']}" for r in summaries]; x = np.arange(len(labels)); width = 0.25
    logs = list((ROOT / "logs").glob("*.csv"))
    for metric, filename, ylabel in (("train_accuracy", "training_accuracy.png", "accuracy"), ("train_loss", "training_loss.png", "loss")):
        plt.figure(figsize=(12, 5))
        for path in logs:
            frame = pd.read_csv(path)
            if "epoch" not in frame or metric not in frame:
                continue
            plt.plot(frame["epoch"], frame[metric], label=path.stem)
        for path in logs:
            frame = pd.read_csv(path); val_metric = "val_accuracy" if metric == "train_accuracy" else "val_loss"
            if val_metric not in frame and metric == "train_accuracy":
                val_metric = "validation_accuracy"
            if val_metric not in frame and metric == "train_loss":
                val_metric = "validation_loss"
            if "epoch" not in frame or val_metric not in frame:
                continue
            plt.plot(frame["epoch"], frame[val_metric], linestyle="--", label=path.stem + " validation")
        plt.xlabel("epoch"); plt.ylabel(ylabel); plt.legend(); plt.tight_layout(); plt.savefig(PLOTS / filename, dpi=180); plt.close()
    plt.figure(figsize=(12, 5))
    for label in labels:
        rows = [r for r in layers if f"{r['model']}/{r['dataset']}" == label]; plt.plot(range(len(rows)), [r["sparsity"] for r in rows], marker="o", label=label)
    plt.xlabel("convolution layer index"); plt.ylabel("activation sparsity (%)"); plt.legend(); plt.tight_layout(); plt.savefig(PLOTS / "per_layer_sparsity.png", dpi=180); plt.close()
    for keys, filename, ylabel in [(("dense_MACs", "useful_MACs"), "macs_dense_useful.png", "MACs"), (("fixed64_dense_cycles", "fixed64_sparse_cycles"), "cycles_dense_sparse.png", "analytical cycles"), (("fixed64_sparse_cycles", "adaptive_cycles"), "cycles_sparse_adaptive.png", "analytical cycles")]:
        plt.figure(figsize=(11, 5));
        for index, key in enumerate(keys): plt.bar(x + (index - .5) * width, [r[key] for r in summaries], width=width, label=key)
        plt.xticks(x, labels, rotation=20); plt.ylabel(ylabel); plt.legend(); plt.tight_layout(); plt.savefig(PLOTS / filename, dpi=180); plt.close()
    plt.figure(figsize=(11, 5)); plt.bar(x - .18, [r["dense_accuracy"] for r in summaries], .36, label="dense"); plt.bar(x + .18, [r["sparse_accuracy"] for r in summaries], .36, label="sparse"); plt.xticks(x, labels, rotation=20); plt.ylabel("test accuracy"); plt.legend(); plt.tight_layout(); plt.savefig(PLOTS / "accuracy_dense_sparse.png", dpi=180); plt.close()
    plt.figure(figsize=(12, 5))
    for label in labels:
        rows = [r for r in layers if f"{r['model']}/{r['dataset']}" == label]; plt.plot(range(len(rows)), [r["selected_PEs"] for r in rows], marker="o", label=label)
    plt.xlabel("convolution layer index"); plt.ylabel("active PEs"); plt.legend(); plt.tight_layout(); plt.savefig(PLOTS / "adaptive_pe_by_layer.png", dpi=180); plt.close()

def main():
    seed_everything(CONFIG["seed"]); RESULTS.mkdir(exist_ok=True); summaries = []; layers = []; policies = []
    for model_name in CONFIG["models"]:
        for dataset_name in CONFIG["datasets"]:
            pair_layers, pair_policy, summary = evaluate_pair(model_name, dataset_name)
            summaries.append(summary); layers.extend(pair_layers); policies.extend(pair_policy)
    valid_summaries = [row for row in summaries if row.get("status") == "PASS"]; save(RESULTS / "test_accuracy.csv", [{k: row[k] for k in ("model", "dataset", "test_samples", "dense_correct", "dense_incorrect", "dense_accuracy")} for row in valid_summaries]); save(RESULTS / "per_layer_sparsity.csv", layers); save(RESULTS / "fixed64_results.csv", [{k: row[k] for k in ("model", "dataset", "dense_MACs", "useful_MACs", "skipped_MACs", "fixed64_dense_cycles", "fixed64_sparse_cycles", "fixed64_cycle_reduction_percent")} for row in valid_summaries]); save(RESULTS / "adaptive_policy.csv", policies); save(RESULTS / "dense_vs_sparse.csv", [{k: row[k] for k in ("model", "dataset", "dense_accuracy", "sparse_accuracy", "accuracy_change_percentage_points", "max_abs_logit_difference", "mean_abs_logit_difference", "prediction_mismatches")} for row in valid_summaries]); save(RESULTS / "accuracy_preservation.csv", [{"model": row["model"], "dataset": row["dataset"], "dense_accuracy": row["dense_accuracy"], "sparse_accuracy": row["sparse_accuracy"], "accuracy_drop_percentage_points": -row["accuracy_change_percentage_points"], "prediction_mismatches": row["prediction_mismatches"]} for row in valid_summaries]); save(RESULTS / "paper_main_table.csv", [{"Model": row["model"], "Dataset": row["dataset"], "Dense Accuracy": row["dense_accuracy"], "Sparse Accuracy": row["sparse_accuracy"], "Accuracy Change": row["accuracy_change_percentage_points"], "Mean Activation Sparsity": row["mean_activation_sparsity"], "Dense MACs": row["dense_MACs"], "Useful MACs": row["useful_MACs"], "MAC Reduction": row["MAC_reduction_percent"], "Fixed64 Dense Cycles": row["fixed64_dense_cycles"], "Fixed64 Sparse Cycles": row["fixed64_sparse_cycles"], "Cycle Reduction": row["fixed64_cycle_reduction_percent"], "Average Active PEs": row["average_active_PEs"]} for row in valid_summaries]); plots(valid_summaries, layers); (RESULTS / "evaluation_environment.json").write_text(json.dumps({"python": platform.python_version(), "torch": torch.__version__, "device": str(DEVICE), "seed": CONFIG["seed"]}, indent=2) + "\n"); print(json.dumps(summaries, indent=2))

if __name__ == "__main__": main()
