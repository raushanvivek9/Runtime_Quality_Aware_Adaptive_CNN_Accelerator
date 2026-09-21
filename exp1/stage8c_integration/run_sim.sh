#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

# Stage 8C is validated with the project-provided Icarus 13.0 environment.
source /home/cs25m115/anaconda3/bin/activate neural_acc

python reference_model.py | tee reference_model.log
iverilog -g2012 -Wall -o stage8c_sim \
  ../stage8a_rtl/runtime_monitor.sv \
  ../stage8a_rtl/feature_calculator.sv \
  ../stage8a_rtl/quality_estimator.sv \
  ../stage8a_rtl/resource_controller.sv \
  ../stage8a_rtl/runtime_controller_top.sv \
  ../stage8b_pe_array/pe_mac.sv \
  ../stage8b_pe_array/pe_array.sv \
  ../stage8b_pe_array/adaptive_pe_controller.sv \
  ../stage8b_pe_array/adaptive_compute_top.sv \
  integration_top.sv tb_stage8c_integration.sv 2>&1 | tee stage8c_compile.log
vvp stage8c_sim 2>&1 | tee stage8c_sim.log
