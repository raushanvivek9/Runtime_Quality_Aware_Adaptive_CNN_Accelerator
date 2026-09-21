#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

conda run -n neural_acc python reference_model.py | tee reference_model.log
conda run -n neural_acc bash -lc '
  set -o pipefail
  iverilog -g2012 -Wall -o stage8b_sim \
    pe_mac.sv pe_array.sv adaptive_pe_controller.sv \
    adaptive_compute_top.sv tb_adaptive_compute.sv 2>&1 | tee stage8b_compile.log
  vvp stage8b_sim 2>&1 | tee stage8b_sim.log
'
