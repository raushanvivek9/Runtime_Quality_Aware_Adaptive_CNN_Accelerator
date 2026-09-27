#!/usr/bin/env bash
set -euo pipefail
cd /home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3
source /home/cs25m115/anaconda3/etc/profile.d/conda.sh
conda activate neural_acc
python validate_training.py
python evaluate_models.py
python adaptive_policy.py
python make_reports.py
