# Stage 12 Final Evaluation v3

This isolated experiment replaces the v2 one-epoch/5,000-sample training with full CIFAR train/validation data: 45,000 training images and 5,000 validation images per dataset. It trains CIFAR-compatible ResNet-18 and VGG-16, evaluates the best checkpoint on all 10,000 test images, and repeats exact-zero convolution-input sparsity and analytical accelerator measurements.

The login host is CPU-only, but the validated q15d compute allocation provides Tesla P100 GPUs. A full-data GPU pilot measured 222.37 seconds for one ResNet-18/CIFAR-10 epoch, so 150 epochs is the declared target in CONFIG.yaml. Any pair completing fewer than the declared target is marked TRAINING_INCOMPLETE and is not presented as final accuracy.

Training uses deterministic seed 42, RandomCrop(32, padding=4), RandomHorizontalFlip, CIFAR normalization, SGD, momentum 0.9, weight decay 5e-4, batch size 128, and cosine annealing. Test images are never augmented.

The adaptive policy is unchanged from v2: for epsilon values 0%, 5%, 10%, and 20%, choose the smallest PE count among 16, 32, and 64 satisfying the declared latency bound relative to fixed64 sparse cycles. It is resource-aware adaptive execution, not an accuracy policy.

## Run

```bash
cd /home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3
bash ./run_stage12_final_v3.sh
```

The run uses `conda run -n neural_acc`. It first performs a full-data pilot, then trains all four pairs, evaluates complete test sets, generates CSVs and plots, and writes FINAL_REPORT.md and VALIDATION.md. RTL and energy remain separate evidence gates and are reported NOT RUN unless faithfully validated.

Important outputs include `results/training_summary.csv`, `results/test_accuracy.csv`, `results/per_layer_sparsity.csv`, `results/dense_vs_sparse.csv`, `results/fixed64_results.csv`, `results/adaptive_policy.csv`, `results/accuracy_preservation.csv`, `results/paper_main_table.csv`, `results/plots/`, [FINAL_REPORT.md](FINAL_REPORT.md), and [VALIDATION.md](VALIDATION.md).
