# TSK-28 Architectural Limitations & Scope Report

## 1. Executive Summary
This document outlines the architectural scope, boundary constraints, and engineering limitations of the **TSK-28 Complete Convolution Layer Validation** milestone.

---

## 2. Microarchitectural Limitations

### 2.1 Receptive Field Line Buffering
- **Current Architecture**: Activations for each spatial coordinate $(y, x)$ are loaded as partitioned chunks from activation RAM.
- **Limitation**: The architecture does not currently include a dedicated 2D line-buffering register array (sliding window buffer) to share overlapping receptive field columns between horizontally adjacent tiles $(y, x)$ and $(y, x+1)$.
- **Impact**: While mathematically and functionally complete, off-chip/SRAM activation read bandwidth is higher than an architecture with hardware line buffering.

### 2.2 Spatial Tiling vs. Full $32 \times 32$ Layer Rasterization
- **Current Status**: TSK-28 validates a complete $4 \times 4$ spatial feature-map grid (16 spatial positions) across 16 output channels, computing all 576 reduction terms ($K = 3 \times 3 \times 64 = 576$) with zero truncation.
- **Limitation**: The complete ResNet-18 `layer1.0.conv1` layer contains $32 \times 32 = 1,024$ spatial coordinates. While the spatial tile sequencer supports arbitrary dimensions up to $1024 \times 1024$, full rasterization of all 1,024 positions was partitioned into $4 \times 4$ feature-map subgrids to keep simulation times bounded and deterministic.

### 2.3 Non-Uniform Channel Depths
- **Current Status**: The controller and compute feeder assume fixed-size chunks of $K_{chunk} = 64$ terms.
- **Limitation**: Layers with odd or non-multiple channel dimensions (such as the initial RGB input layer with $C_{in} = 3$) require host zero-padding to 64 or support for variable $K_{len}$ per chunk.

---

## 3. Scope & Physical Synthesis Disclaimers

### 3.1 Cycle-Accurate Simulation vs. Physical Hardware
- All simulation metrics reported in TSK-28 (e.g., 10,051 clock cycles for 147,456 MAC operations) were measured via cycle-accurate SystemVerilog simulation using Icarus Verilog (`iverilog` / `vvp`).
- No physical ASIC synthesis, place-and-route, or parasitic extraction was performed in this milestone.
- **No claims are made regarding physical clock frequency (MHz/GHz), dynamic power dissipation (mW), or total energy-per-inference (mJ)**.

### 3.2 Baseline RTL Protection Compliance
- Five baseline RTL files remain strictly protected and unmodified:
  - `phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv` (0 diffs)
  - `phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv` (0 diffs)
  - `phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv` (0 diffs)
  - `phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv` (0 diffs)
  - `phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv` (0 diffs)
- Zero Git commits were created.

