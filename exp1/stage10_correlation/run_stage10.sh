#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

conda run -n neural_acc python stage10_python_reference.py
conda run -n neural_acc python analytical_model.py

conda run -n neural_acc iverilog -g2012 -Wall -o stage10_sim \
  ../stage9a_conv_rtl/conv_pe.sv \
  ../stage9a_conv_rtl/conv_pe_array.sv \
  ../stage9a_conv_rtl/conv_scheduler.sv \
  ../stage9a_conv_rtl/conv_runtime_top.sv \
  ../stage8a_rtl/runtime_monitor.sv \
  ../stage8a_rtl/feature_calculator.sv \
  ../stage8a_rtl/quality_estimator.sv \
  ../stage8a_rtl/resource_controller.sv \
  ../stage8a_rtl/runtime_controller_top.sv \
  stage10_tb.sv

conda run -n neural_acc vvp stage10_sim 2>&1 | tee stage10_sim.log

conda run -n neural_acc python stage10_postprocess.py

printf '\nStage 10 run completed successfully.\n'
