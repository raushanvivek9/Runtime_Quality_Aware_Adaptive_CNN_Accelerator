# Stage 12 Final Experimental Evaluation

This directory contains the final, isolated evaluation for CIFAR-compatible ResNet-18 and VGG-16 on CIFAR-10 and CIFAR-100. It reports three evidence levels separately:

- **Level A: model evaluation**: forward correctness, measured dense and exact-zero-masked sparse logits, accuracy, activation statistics, and model metadata.
- **Level B: analytical accelerator evaluation**: model-derived convolution MACs, activation zero-skipping, fixed 64 PE baselines, and the documented threshold-based adaptive policy.
- **Level C: RTL validation**: only reported when a complete supported model-to-RTL workload is actually run. This checkout records it as `NOT RUN`; prototype RTL results are not promoted to full-model claims.

## Reproducibility

The default run evaluates the first 1,000 test samples in deterministic order, with seed 42, batch size 32, CPU unless CUDA is available, and CIFAR normalization mean `(0.4914, 0.4822, 0.4465)` and standard deviation `(0.2470, 0.2435, 0.2616)`. Override `STAGE12_SAMPLES`, `STAGE12_BATCH_SIZE`, or `STAGE12_DEVICE` for a documented smoke run or resource-constrained execution.

Matching checkpoints are used if found. No matching ResNet-18/VGG-16 CIFAR checkpoint exists in this workspace, so the recorded accuracy is explicitly untrained-subset accuracy and the overall status is `PARTIAL`.

## Policy and baselines

The fixed policy is defined before result generation:

- sparsity `< 20%`: 64 PE
- sparsity `20%` to `< 40%`: 32 PE
- sparsity `>= 40%`: 16 PE

The baselines are `fixed64_dense`, `fixed64_sparse`, and `adaptive_sparse`. Analytical cycles are `ceil(MACs / active_PEs)`. They are not hardware latency measurements and omit memory, scheduling, and control overhead.

## Run

```bash
cd /home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation
bash ./run_stage12_final.sh
```

The script uses `conda run -n neural_acc` and does not require manual activation. `collect_activation_stats.py` and `final_analytical_model.py` are named compatibility entry points to the same evidence-producing evaluator.

## Outputs

`final_model_summary.csv`, `layer_sparsity.csv`, `final_results.csv`, `final_resource_allocation.csv`, `ablation_results.csv`, `rtl_correlation_results.csv`, `energy_results.csv`, `sparsity_by_layer.png`, `cycle_comparison.png`, `resource_allocation.png`, `mac_reduction.png`, `accuracy_comparison.png`, `experiment_config.json`, `VALIDATION.md`, `stage12_final_report.txt`, and `stage12_final_status.json`.

Energy is `NOT RUN` because no same-workload validated SCALE-Sim/Accelergy invocation was available. The prior Stage 12 prototype and all protected earlier stages remain separate and are not overwritten by this evaluator.
