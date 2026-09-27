import csv
import hashlib
import math
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

from adaptive_policy import EPSILONS, choose_pe
from dataset import make_loaders
from model import AlexNetMNIST, convolution_layers


ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / "results"
BATCH_SIZE = 128


def write_csv(path, rows):
    if not rows:
        return
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main():
    RESULTS.mkdir(exist_ok=True)
    checkpoint_path = ROOT / "alexnet_mnist_5epoch_pilot.pt"
    if not checkpoint_path.exists():
        raise FileNotFoundError(f"missing checkpoint: {checkpoint_path}")
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    _, _, test_loader = make_loaders(BATCH_SIZE)
    model = AlexNetMNIST().to(device)
    payload = torch.load(checkpoint_path, map_location=device)
    model.load_state_dict(payload["model_state_dict"], strict=True)
    model.eval()
    convs = convolution_layers(model)
    layer_stats = {name: {"input_elements": 0, "zero_elements": 0, "dense_macs": 0, "useful_macs": 0} for name, _ in convs}
    per_sample = {name: [] for name, _ in convs}
    dense_correct = sparse_correct = total = mismatches = 0
    max_diff = 0.0
    mean_diff_total = 0.0
    collect = [True]

    def make_hook(name, layer):
        def hook(_module, inputs, output):
            if not collect[0]:
                return
            activation = inputs[0].detach()
            unfolded = F.unfold(activation, layer.kernel_size, layer.dilation, layer.padding, layer.stride)
            useful = (torch.count_nonzero(unfolded, dim=1) * layer.out_channels).cpu().tolist()
            dense = output.shape[1] * output.shape[2] * output.shape[3] * layer.in_channels * layer.kernel_size[0] * layer.kernel_size[1]
            stats = layer_stats[name]
            stats["input_elements"] += activation.numel()
            stats["zero_elements"] += int(torch.count_nonzero(activation == 0))
            stats["dense_macs"] += activation.shape[0] * dense
            stats["useful_macs"] += int(sum(useful))
            per_sample[name].extend({"dense_macs": dense, "useful_macs": int(value)} for value in useful)
        return hook

    handles = [layer.register_forward_hook(make_hook(name, layer)) for name, layer in convs]
    with torch.no_grad():
        for images, labels in test_loader:
            images, labels = images.to(device), labels.to(device)
            dense_logits = model(images)
            collect[0] = False
            sparse_handles = [
                layer.register_forward_pre_hook(
                    lambda _module, inputs: (inputs[0].masked_fill(inputs[0] == 0, 0),)
                )
                for _name, layer in convs
            ]
            sparse_logits = model(images)
            for handle in sparse_handles:
                handle.remove()
            collect[0] = True
            dense_predictions = dense_logits.argmax(1)
            sparse_predictions = sparse_logits.argmax(1)
            dense_correct += int((dense_predictions == labels).sum())
            sparse_correct += int((sparse_predictions == labels).sum())
            total += labels.numel()
            mismatches += int((dense_predictions != sparse_predictions).sum())
            difference = (dense_logits - sparse_logits).abs()
            max_diff = max(max_diff, float(difference.max()))
            mean_diff_total += float(difference.sum())
    for handle in handles:
        handle.remove()

    layer_rows = []
    policy_rows = []
    for name, _layer in convs:
        stats = layer_stats[name]
        dense = int(stats["dense_macs"])
        useful = int(stats["useful_macs"])
        layer_rows.append({
            "layer": name,
            "input_elements": stats["input_elements"],
            "zero_elements": stats["zero_elements"],
            "exact_zero_sparsity": stats["zero_elements"] / max(stats["input_elements"], 1),
            "dense_MACs": dense,
            "useful_MACs": useful,
            "skipped_MACs": dense - useful,
            "MAC_reduction": (dense - useful) / max(dense, 1),
            "fixed64_dense_cycles": math.ceil(dense / 64),
            "fixed64_sparse_cycles": math.ceil(useful / 64),
        })
        for epsilon in EPSILONS:
            choices = [choose_pe(row["useful_macs"], epsilon) for row in per_sample[name]]
            policy_rows.append({
                "layer": name,
                "epsilon": epsilon,
                "average_active_PE_allocation": float(np.mean([choice[0] for choice in choices])),
                "fixed64_sparse_cycles": sum(choice[1] for choice in choices),
                "adaptive_sparse_cycles": sum(choice[2] for choice in choices),
                "cycle_change": sum(choice[2] for choice in choices) - sum(choice[1] for choice in choices),
                "PE_reduction": 1 - float(np.mean([choice[0] for choice in choices])) / 64,
            })
    summary = [{
        "checkpoint": str(checkpoint_path),
        "checkpoint_sha256": hashlib.sha256(checkpoint_path.read_bytes()).hexdigest(),
        "test_samples": total,
        "dense_accuracy": dense_correct / total,
        "sparse_accuracy": sparse_correct / total,
        "prediction_mismatch_count": mismatches,
        "prediction_mismatch_rate": mismatches / total,
        "max_abs_logit_difference": max_diff,
        "mean_abs_logit_difference": mean_diff_total / max(total * 10, 1),
        "fixed64_dense_cycles": sum(row["fixed64_dense_cycles"] for row in layer_rows),
        "fixed64_sparse_cycles": sum(row["fixed64_sparse_cycles"] for row in layer_rows),
        "rtl_status": "NOT RUN",
        "energy_status": "NOT RUN",
    }]
    write_csv(RESULTS / "per_layer_sparsity.csv", layer_rows)
    write_csv(RESULTS / "adaptive_policy.csv", policy_rows)
    write_csv(RESULTS / "summary.csv", summary)


if __name__ == "__main__":
    main()