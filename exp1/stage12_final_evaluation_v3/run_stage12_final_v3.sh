#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v conda >/dev/null 2>&1 || { echo "conda is required" >&2; exit 2; }
mkdir -p checkpoints logs results results/plots
printf 'Environment check\n'
conda run -n neural_acc python -c 'import torch, yaml; print("python/torch/yaml: PASS"); print("cuda:", torch.cuda.is_available())'
conda run -n neural_acc python make_reports.py
printf 'Full-data pilot\n'
V3_PILOT=1 conda run -n neural_acc python train_models.py
printf 'Training four model/dataset pairs\n'
V3_SKIP_LONG_TRAINING=1 conda run -n neural_acc python train_models.py
printf 'Evaluation and analytical accelerator measurements\n'
conda run -n neural_acc python evaluate_models.py
conda run -n neural_acc python adaptive_policy.py
conda run -n neural_acc python make_reports.py
printf '\n=============================================\nSTAGE 12 FINAL V3\n=============================================\n'
for item in 'TRAINING: results/training_summary.csv' 'TEST ACCURACY: results/test_accuracy.csv' 'SPARSITY: results/per_layer_sparsity.csv' 'SPARSE INFERENCE: results/dense_vs_sparse.csv' 'ACCURACY PRESERVATION: results/accuracy_preservation.csv' 'MAC REDUCTION: results/paper_main_table.csv' 'FIXED64 ANALYTICAL: results/fixed64_results.csv' 'ADAPTIVE POLICY: results/adaptive_policy.csv' 'FINAL REPORT: FINAL_REPORT.md'; do
  name=${item%%:*}; path=${item#*: }
  [[ -f "$path" ]] && printf '%s: PASS\n' "$name" || printf '%s: NOT RUN\n' "$name"
done
printf 'RTL: NOT RUN\nENERGY: NOT RUN\n'
printf '\nFinal test accuracies:\n'
if [[ -f results/test_accuracy.csv ]]; then tail -n +2 results/test_accuracy.csv; else printf 'NOT RUN\n'; fi
printf '=============================================\n'
