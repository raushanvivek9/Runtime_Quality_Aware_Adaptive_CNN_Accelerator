# Stage 12 — Multi-Layer Adaptive Policy

This stage evaluates a three-layer convolution chain in which each layer is measured independently for activation sparsity and then assigned a runtime PE count according to a threshold policy.

## Objective
The goal is to compare a dense fixed-64 baseline, a fixed-64 sparse baseline, and a threshold-driven adaptive sparse policy across three deterministic cases.

## Workload
- 3 convolution layers in sequence
- Reduced 8x8 spatial dimensions
- deterministic activation generation per case
- layer output from one layer becomes the input to the next layer
- no modification to protected Stage 8A/9A/9B/9C/10 files

## Policy
- if activation sparsity < 20% -> select 64 PE
- elif activation sparsity < 40% -> select 32 PE
- else -> select 16 PE

## Honest reporting
The adaptive policy is evaluated without forcing it to outperform the fixed sparse baseline. If it does not reduce cycles, the result is recorded as-is; no energy claim or hardware claim is made.

## Expected outputs
- stage12_results.csv
- stage12_policy_summary.csv
- policy_comparison.csv
- stage12_plot.png
- VALIDATION.md
- stage12_report.txt

## Validation command
```bash
cd /home/cs25m115/Neural_Acc/exp1/stage12_multilayer_adaptive
bash ./run_stage12.sh
```
