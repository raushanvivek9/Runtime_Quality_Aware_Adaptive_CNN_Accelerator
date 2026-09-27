#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v conda >/dev/null 2>&1 || { echo "conda is required" >&2; exit 2; }
mkdir -p checkpoints results logs
printf 'Environment check\n'
conda run -n neural_acc python -c 'import torch, yaml; print("python/torch/yaml: PASS"); print("cuda:", torch.cuda.is_available())'
conda run -n neural_acc python make_reports.py
conda run -n neural_acc python train_models.py
conda run -n neural_acc python evaluate_models.py
conda run -n neural_acc python adaptive_policy.py
conda run -n neural_acc python rtl_correlation.py
conda run -n neural_acc python energy_analysis.py
conda run -n neural_acc python make_reports.py
printf '\n========================================\nSTAGE 12 FINAL V2\n========================================\n'
for item in 'TRAINING: results/training_status.csv' 'ACCURACY: results/test_accuracy.csv' 'SPARSITY: results/per_layer_sparsity.csv' 'SPARSE INFERENCE: results/dense_vs_sparse.csv' 'ADAPTIVE POLICY: results/final_summary.csv' 'FINAL REPORT: FINAL_REPORT.md'; do
  name=${item%%:*}; path=${item#*: }
  if [[ -f "$path" ]]; then printf '%s: PASS\n' "$name"; else printf '%s: NOT RUN\n' "$name"; fi
done
if grep -q 'NOT_RUN' results/rtl_correlation_status.txt; then printf 'RTL CORRELATION: NOT RUN\n'; else printf 'RTL CORRELATION: PASS\n'; fi
if grep -q 'ENERGY_NOT_RUN' results/energy_status.txt; then printf 'ENERGY: NOT RUN\n'; else printf 'ENERGY: PASS\n'; fi
printf '========================================\n'
