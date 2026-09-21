#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

conda run -n neural_acc python reference_model.py | tee reference_model.log
conda run -n neural_acc iverilog -g2012 -Wall -o stage9b_sim \
  ../stage8a_rtl/runtime_monitor.sv \
  ../stage8a_rtl/feature_calculator.sv \
  ../stage8a_rtl/quality_estimator.sv \
  ../stage8a_rtl/resource_controller.sv \
  ../stage8a_rtl/runtime_controller_top.sv \
  tensor_loader.sv input_buffer.sv weight_buffer.sv output_buffer.sv \
  dataflow_controller.sv conv_pe.sv conv_pe_array.sv conv_buffered_scheduler.sv \
  conv_dataflow_top.sv tb_stage9b_dataflow.sv 2>&1 | tee stage9b_compile.log
conda run -n neural_acc vvp stage9b_sim 2>&1 | tee stage9b_sim.log
