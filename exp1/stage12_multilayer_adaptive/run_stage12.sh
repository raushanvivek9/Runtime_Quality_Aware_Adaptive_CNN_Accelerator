#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

conda run -n neural_acc python stage12_python_reference.py
conda run -n neural_acc python adaptive_policy.py
conda run -n neural_acc python stage12_analytical_model.py

conda run -n neural_acc iverilog -g2012 -Wall -o stage12_sim \
  stage12_sparse_conv_pe.sv \
  stage12_sparse_conv_scheduler.sv \
  stage12_layer_wrapper.sv \
  stage12_multilayer_top.sv \
  tb_stage12_multilayer.sv

conda run -n neural_acc vvp stage12_sim 2>&1 | tee stage12_sim.log

conda run -n neural_acc python stage12_postprocess.py

printf '\nStage 12 run completed.\n'
