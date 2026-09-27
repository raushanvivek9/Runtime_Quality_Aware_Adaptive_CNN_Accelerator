#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

conda run -n neural_acc python reference_model.py | tee stage9c_reference.log
conda run -n neural_acc iverilog -g2012 -Wall -o stage9c_sim \
  ../stage8a_rtl/runtime_monitor.sv \
  ../stage8a_rtl/feature_calculator.sv \
  ../stage8a_rtl/quality_estimator.sv \
  ../stage8a_rtl/resource_controller.sv \
  ../stage8a_rtl/runtime_controller_top.sv \
  ../stage9a_conv_rtl/conv_pe.sv \
  ../stage9a_conv_rtl/conv_pe_array.sv \
  ../stage9a_conv_rtl/conv_scheduler.sv \
  ../stage9a_conv_rtl/conv_runtime_top.sv \
  cnn_dataflow_controller.sv \
  pooling2x2.sv \
  conv_layer_wrapper.sv \
  multilayer_cnn_top.sv \
  tb_stage9c_multilayer.sv 2>&1 | tee stage9c_compile.log
conda run -n neural_acc vvp stage9c_sim 2>&1 | tee stage9c_sim.log
conda run -n neural_acc python - <<'PY'
import os
print('Generated files:', sorted(p for p in os.listdir('.') if p.startswith('stage9c_') or p.endswith('.txt')))
PY
