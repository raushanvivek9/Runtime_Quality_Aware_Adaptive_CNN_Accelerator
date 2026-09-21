#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

source /home/cs25m115/anaconda3/bin/activate neural_acc

python reference_model.py | tee reference_model.log
iverilog -g2012 -Wall -o stage9a_sim \
  ../stage8a_rtl/runtime_monitor.sv \
  ../stage8a_rtl/feature_calculator.sv \
  ../stage8a_rtl/quality_estimator.sv \
  ../stage8a_rtl/resource_controller.sv \
  ../stage8a_rtl/runtime_controller_top.sv \
  conv_pe.sv conv_pe_array.sv conv_scheduler.sv conv_runtime_top.sv \
  tb_stage9a_conv.sv 2>&1 | tee stage9a_compile.log
vvp stage9a_sim 2>&1 | tee stage9a_sim.log
