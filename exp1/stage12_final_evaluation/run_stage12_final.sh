#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

command -v conda >/dev/null 2>&1 || { echo "conda is required" >&2; exit 2; }
conda run -n neural_acc python stage12_final_evaluation.py

printf '\nStage 12 final evaluation completed.\n'
