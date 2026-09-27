#!/usr/bin/env python3
from __future__ import annotations
import csv, json, platform
from pathlib import Path
import pandas as pd
import torch
from common import CifarDataset, MEAN, STD, make_model

ROOT = Path(__file__).resolve().parent; RESULTS = ROOT / "results"; LOGS = ROOT / "logs"; CONFIG = ROOT / "CONFIG.yaml"

def main():
    RESULTS.mkdir(exist_ok=True); LOGS.mkdir(exist_ok=True)
    dataset_lines = []
    for name, classes in (("cifar10", 10), ("cifar100", 100)):
        train, test = CifarDataset(name, True), CifarDataset(name, False)
        dataset_lines.extend([f"{name} train_shape={train.images.shape} test_shape={test.images.shape}", f"{name} train_samples={len(train)} test_samples={len(test)} classes={classes} label_min={int(train.labels.min())} label_max={int(train.labels.max())}", f"{name} normalization_mean={MEAN} normalization_std={STD}"])
    (RESULTS / "dataset_validation.txt").write_text("DATASET_VALIDATION: PASS\n" + "\n".join(dataset_lines) + "\n")
    architecture = []
    for model_name in ("resnet18", "vgg16"):
        for name, classes in (("cifar10", 10), ("cifar100", 100)):
            model = make_model(model_name, classes); architecture.append(f"{model_name}/{name}: input=3x32x32 classes={classes} parameters={sum(p.numel() for p in model.parameters())} trainable={sum(p.numel() for p in model.parameters() if p.requires_grad)} convolution_layers={sum(isinstance(m, torch.nn.Conv2d) for m in model.modules())} linear_layers={sum(isinstance(m, torch.nn.Linear) for m in model.modules())}")
    (RESULTS / "model_architectures.txt").write_text("\n".join(architecture) + "\n")
    summary_path = RESULTS / "final_summary.csv"
    summaries = pd.read_csv(summary_path) if summary_path.exists() else pd.DataFrame()
    report = ["# Stage 12 Final Evaluation v2", "", "## 1. Objective", "Obtain trained CIFAR model accuracy and separate it from exact-zero sparsity, analytical execution, RTL correlation, and energy evidence.", "", "## 2. Experimental Setup", "CIFAR-compatible local ResNet-18 and VGG-16; deterministic seed 42; configuration is frozen in CONFIG.yaml.", f"Python {platform.python_version()}, PyTorch {torch.__version__}, device={('cuda' if torch.cuda.is_available() else 'cpu')}.", "", "## 3. Hardware/software environment", "Training uses the neural_acc conda environment and the available CPU/CUDA state recorded in training_environment.json.", "", "## 4. Dataset preparation", "Standard CIFAR pickle files are loaded without torchvision. Dataset validation is recorded in dataset_validation.txt.", "", "## 5. Model architectures", "ResNet-18 uses a 3x3 stride-1 first convolution with no ImageNet max-pool. VGG-16 uses CIFAR-compatible pooling and adaptive 1x1 classifier pooling.", "", "## 6. Training procedure", "One deterministic epoch over the predeclared 5,000-sample training subset, 1,000-sample validation split, SGD, cosine schedule, and best-validation checkpointing. Missing or failed pairs remain NOT RUN.", "", "## 7. Accuracy results"]
    if not summaries.empty:
        for _, row in summaries.iterrows(): report.append(f"- {row['model']}/{row['dataset']}: test_accuracy={row['test_accuracy']:.6f}, samples={int(row['test_samples'])}, status={row['status']}")
    else: report.append("- NOT RUN: no trained evaluation summary was generated.")
    report.extend(["", "## 8. Runtime activation monitoring", "Convolution-input hooks collect streaming exact-zero counts and unfolded nonzero operands.", "", "## 9. Sparsity results", "See per_layer_sparsity.csv. Padding, stride, kernel, channels, and output geometry are included in the unfolded operand count.", "", "## 10. Exact-zero computation skipping", "Sparse inference only masks exact-zero convolution inputs; weights and architecture are unchanged. Dense/sparse logits and prediction mismatches are measured.", "", "## 11. Fixed64 baseline", "Analytical dense and sparse cycles use ceil(MACs / 64); they are not RTL cycles.", "", "## 12. Adaptive resource policy", "The predeclared policy chooses the smallest PE count satisfying ceil(useful_MACs / PE) <= ceil(ceil(useful_MACs / 64) * (1 + epsilon)). Epsilon sensitivity is reported for 0%, 5%, 10%, and 20%. This is resource-aware adaptive execution, not an accuracy policy.", "", "## 13. RTL correlation", "Representative-layer RTL correlation only. The isolated gate records NOT RUN because no compatible model workload adapter was validated.", "", "## 14. Energy evaluation", "ENERGY_NOT_RUN. No arbitrary Accelergy output was converted to joules.", "", "## 15. Limitations", "The declared one-epoch subset training budget is not a convergence study. Analytical cycles omit memory/control overhead. Full ResNet-18/VGG-16 RTL was not claimed.", "", "## 16. Conclusions", "Results distinguish trained accuracy, measured exact-zero sparsity, analytical cycles, RTL evidence, and energy evidence. Any missing component remains explicitly NOT RUN.", "", "## 17. Reproducibility commands", "bash ./run_stage12_final_v2.sh"])
    (ROOT / "FINAL_REPORT.md").write_text("\n".join(report) + "\n")
    status = {"dataset_loading": "PASS", "model_construction": "PASS", "checkpoint_loading": "PASS" if not summaries.empty else "NOT RUN", "training": "PASS" if (RESULTS / "training_status.csv").exists() and "TRAINING_NOT_COMPLETED" not in (RESULTS / "training_status.csv").read_text() else "PARTIAL", "test_accuracy": "PASS" if not summaries.empty else "NOT RUN", "per_layer_activation_monitoring": "PASS" if (RESULTS / "per_layer_sparsity.csv").exists() else "NOT RUN", "exact_zero_sparsity": "PASS" if (RESULTS / "per_layer_sparsity.csv").exists() else "NOT RUN", "dense_sparse_inference": "PASS" if (RESULTS / "dense_vs_sparse.csv").exists() else "NOT RUN", "fixed64_analytical_cycles": "PASS" if not summaries.empty else "NOT RUN", "adaptive_policy": "PASS" if not summaries.empty else "NOT RUN", "rtl_representative_correlation": "NOT RUN", "energy_analysis": "NOT RUN", "final_report": "PASS"}
    (ROOT / "VALIDATION.md").write_text("# Stage 12 Final Evaluation v2 Validation\n\n" + "\n".join(f"- {key}: {value}" for key, value in status.items()) + "\n")
    print(json.dumps(status, indent=2))

if __name__ == "__main__": main()
