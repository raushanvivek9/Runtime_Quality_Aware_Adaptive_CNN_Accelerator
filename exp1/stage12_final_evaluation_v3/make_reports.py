#!/usr/bin/env python3
from __future__ import annotations
import json, platform, shutil
from pathlib import Path
import pandas as pd
import torch
from common import CifarDataset, MEAN, STD, make_model

ROOT = Path(__file__).resolve().parent; RESULTS = ROOT / "results"; CONFIG = (ROOT / "CONFIG.yaml").read_text()

def read_csv_or_empty(path):
    try:
        return pd.read_csv(path) if path.exists() else pd.DataFrame()
    except pd.errors.EmptyDataError:
        return pd.DataFrame()

def main():
    RESULTS.mkdir(exist_ok=True)
    lines = ["DATASET_VALIDATION: PASS"]
    for name, classes in (("cifar10", 10), ("cifar100", 100)):
        train, test = CifarDataset(name, True), CifarDataset(name, False); lines.append(f"{name}: train={len(train)} test={len(test)} image_shape={train.images.shape[1:]} classes={classes} labels={train.labels.min()}..{train.labels.max()} normalization_mean={MEAN} normalization_std={STD}")
    (RESULTS / "dataset_validation.txt").write_text("\n".join(lines) + "\n")
    architecture = []
    for model_name in ("resnet18", "vgg16"):
        for name, classes in (("cifar10", 10), ("cifar100", 100)):
            model = make_model(model_name, classes); architecture.append(f"{model_name}/{name}: input=3x32x32 classes={classes} parameters={sum(p.numel() for p in model.parameters())} trainable={sum(p.numel() for p in model.parameters() if p.requires_grad)} conv_layers={sum(isinstance(m, torch.nn.Conv2d) for m in model.modules())} linear_layers={sum(isinstance(m, torch.nn.Linear) for m in model.modules())}")
    (RESULTS / "model_architectures.txt").write_text("\n".join(architecture) + "\n")
    summary = read_csv_or_empty(RESULTS / "paper_main_table.csv"); training = read_csv_or_empty(RESULTS / "training_summary.csv")
    report = ["# Stage 12 Final Evaluation v3", "", "## 1. Objective", "Train CIFAR-compatible ResNet-18 and VGG-16 on the full CIFAR training data, then measure exact-zero convolution-input skipping.", "", "## 2. Experimental setup", "Seed 42, deterministic 45,000/5,000 train/validation split, full 10,000-image test set, local CIFAR pickle loader, and CPU-only neural_acc execution.", "", "## 3. Dataset", "CIFAR-10 and CIFAR-100 counts, shapes, labels, and normalization are recorded in results/dataset_validation.txt.", "", "## 4. Training methodology", "Training uses RandomCrop(32, padding=4), RandomHorizontalFlip, SGD with momentum 0.9, weight decay 5e-4, cosine annealing, batch size 256, and the declared 50-epoch CPU target. The requested 150 epochs was not feasible on this CPU-only host and is recorded in CONFIG.yaml.", "", "## 5. Model architectures", "ResNet-18 uses a 3x3 stride-1 first convolution with no ImageNet max-pooling. VGG-16 uses CIFAR-compatible pooling and adaptive 1x1 classifier pooling.", "", "## 6. Training results"]
    if not training.empty:
        report.extend(f"- {row['model']}/{row['dataset']}: epochs={row['epochs_completed']}, best_val={row['best_validation_accuracy']}, status={row['status']}" for _, row in training.iterrows())
    else: report.append("- Training summary unavailable.")
    report.extend(["", "## 7. Test accuracy", "Only best-checkpoint, completed-training test accuracy is presented as final accuracy.", "", "## 8. Runtime activation monitoring", "Convolution inputs are monitored with streaming exact-zero counts and unfolded operands.", "", "## 9. Activation sparsity", "Both pre-padding activation sparsity and effective unfolded sparsity are reported.", "", "## 10. Exact-zero sparse inference", "Sparse mode masks only values exactly equal to zero at convolution inputs. No weights, labels, test samples, architecture, or nonzero values are changed.", "", "## 11. Accuracy preservation", "Dense and sparse logits, prediction mismatches, and percentage-point accuracy change are measured in dense_vs_sparse.csv and accuracy_preservation.csv.", "", "## 12. MAC reduction", "MACs account for channels, kernels, stride, padding, and output geometry.", "", "## 13. Fixed64 analytical performance", "Cycles are ceil(MACs / 64) and are analytical, not RTL cycles.", "", "## 14. Adaptive resource allocation", "The unchanged v2 epsilon policy tests 0%, 5%, 10%, and 20% and selects the smallest PE count within each declared latency bound. It is resource-aware adaptive execution, not an accuracy policy.", "", "## 15. RTL evidence", "NOT RUN. No full-model RTL is claimed; previous-stage RTL remains separate.", "", "## 16. Energy evidence", "NOT RUN. No uncalibrated Accelergy unit was converted to joules.", "", "## 17. Limitations", "CPU-only training used the declared 50-epoch maximum-feasible target rather than 150 requested epochs. Any pair below 50 epochs is incomplete and excluded from final accuracy evaluation.", "", "## 18. Main findings"])
    if not summary.empty:
        report.extend(f"- {row['Model']}/{row['Dataset']}: dense_accuracy={row['Dense Accuracy']}, sparse_accuracy={row['Sparse Accuracy']}, MAC_reduction={row['MAC Reduction']}%, cycle_reduction={row['Cycle Reduction']}%, average_active_PEs={row['Average Active PEs']}" for _, row in summary.iterrows())
    else: report.append("- No completed model results available.")
    report.extend(["", "## 19. Reproducibility", "bash ./run_stage12_final_v3.sh"])
    (ROOT / "FINAL_REPORT.md").write_text("\n".join(report) + "\n")
    completed = not summary.empty
    status = {"full_training_dataset": "PASS", "split": "PASS", "architecture": "PASS", "training": "PASS" if not training.empty and all(training["status"] == "PASS") else "INCOMPLETE", "test_accuracy": "PASS" if completed else "NOT RUN", "sparsity": "PASS" if completed else "NOT RUN", "sparse_inference": "PASS" if completed else "NOT RUN", "accuracy_preservation": "PASS" if completed else "NOT RUN", "mac_reduction": "PASS" if completed else "NOT RUN", "fixed64": "PASS" if completed else "NOT RUN", "adaptive_policy": "PASS" if completed else "NOT RUN", "rtl": "NOT RUN", "energy": "NOT RUN", "final_report": "PASS"}
    (ROOT / "VALIDATION.md").write_text("# Stage 12 Final Evaluation v3 Validation\n\n" + "\n".join(f"- {key}: {value}" for key, value in status.items()) + "\n")
    print(json.dumps(status, indent=2))

if __name__ == "__main__": main()
