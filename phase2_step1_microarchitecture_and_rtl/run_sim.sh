#!/usr/bin/env bash
# =============================================================================
# Project: Neural_Acc (Phase 2 RTL Simulation Runner)
# Description: Compiles and runs SystemVerilog simulation for Accelerator Core Top
# =============================================================================

set -e

IV_BIN="/home/cs25m115/anaconda3/envs/neural_acc/bin/iverilog"
VVP_BIN="/home/cs25m115/anaconda3/envs/neural_acc/bin/vvp"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "Compiling Phase 2 Step 1 SystemVerilog RTL..."
"${IV_BIN}" -g2012 -o phase2_sim \
    mac_unit_40b.sv \
    k_progress_tracker.sv \
    slot_control_unit.sv \
    hybrid_sram_bank.sv \
    accelerator_core_top.sv \
    tb_accelerator_core.sv

echo "Executing RTL Simulation..."
"${VVP_BIN}" phase2_sim

echo "Simulation completed successfully."

