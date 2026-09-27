#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

conda run -n neural_acc python stage11_python_reference.py
conda run -n neural_acc python sparse_analytical_model.py

conda run -n neural_acc iverilog -g2012 -Wall -o stage11_sim \
  sparse_conv_pe.sv \
  sparse_conv_scheduler.sv \
  tb_stage11_sparse.sv

conda run -n neural_acc vvp stage11_sim 2>&1 | tee stage11_sim.log

conda run -n neural_acc python stage11_postprocess.py

printf '\nStage 11 run completed successfully.\n'
