# TSK-29 Architectural Limitations & Evaluation Scope Report

## 1. Executive Summary
This document delineates the microarchitectural limitations, experimental boundaries, and empirical trade-offs identified during the **TSK-29 Adaptive PE Allocation and Sparse Execution Evaluation** milestone on the `Neural_Acc` accelerator.

---

## 2. Microarchitectural Limitations & Trade-Offs

### 2.1 Sparse Execution: Switching Suppression vs. Cycle Compression
- **Baseline Datapath Mechanism**:
  The sparse execution logic in `tsk29_adaptive_convolution_engine.sv` (integrating the validated compute feeder principles) skips MAC operations when an input activation is exactly zero ($A_{in}[k] = 0$). In sparse mode, weight SRAM reads are suppressed and the MAC enable strobe is held low.
- **Microarchitectural Limitation**:
  The baseline architecture lacks a compressed-sparse-row (CSR/CSC) coordinate indexing unit or elastic FIFO queue to squeeze zero cycles out of the time domain. As a result, the time-step iterator advances linearly through all $K = 576$ terms across all 16 spatial tiles:
  $$\text{Total Cycles (Sparse)} = \text{Total Cycles (Dense)}$$
- **Silicon Impact**:
  Weight SRAM reads are reduced by **68.89%** (from 147,456 reads down to 45,872 reads) and MAC active switching cycles drop by **68.89%** (from 9,216 down to 2,867 cycles in 64-PE mode). In physical silicon, this yields significant dynamic power reduction. However, it does **not** reduce execution wall-clock time or increase throughput without asynchronous compaction queues.

### 2.2 Adaptive PE Allocation: Area/Power Throttle vs. Latency Trade-Off
- **Empirical Reality**:
  The adaptive PE allocation mechanism does **not** accelerate inference compared to the Fixed 64-PE baseline. 
  - Fixed 64-PE completes in **9,569 cycles** ($1.0\times$).
  - Adaptive 32-PE completes in **19,121 cycles** ($2.0\times$ latency penalty).
  - Fixed 16-PE completes in **38,225 cycles** ($4.0\times$ latency penalty).
- **Architectural Role**:
  Adaptive PE allocation acts as an **adaptive hardware throttle**. When accuracy degradation constraints permit ($\hat{D}_{mode} \le D_{max}$), the controller selects 32-PE or 16-PE mode to power-gate 50.0% to 75.0% of the PE columns. This frees thermal headroom or allows multi-tenant core sharing, but directly doubles or quadruples completion latency due to multi-pass channel tiling. Any claim that adaptive mode makes convolution "faster" is unsupported and refuted by the cycle-accurate measurements.

### 2.3 Activation SRAM Re-Streaming in Multi-Pass Channel Tiling
- **Channel Partitioning**:
  In 16-PE mode, 4 channel passes are required to evaluate 16 output channels; in 32-PE mode, 2 channel passes are required.
- **Limitation**:
  Because the architecture lacks a shared on-chip activation cache across passes, the input activations for all 16 spatial coordinates must be re-read from activation SRAM for each channel pass:
  - 64-PE mode: 9,216 activation reads (1 pass)
  - 32-PE mode: 18,432 activation reads (2 passes, $2.0\times$)
  - 16-PE mode: 36,864 activation reads (4 passes, $4.0\times$)
- **Memory Traffic Implication**:
  Total SRAM memory reads scale unfavorably in reduced-PE modes (184,320 reads for 16-PE dense vs. 156,672 reads for 64-PE dense).

### 2.4 Offline Degradation Metric Prediction
- **Current Controller Operation**:
  The Stage 8A `adaptive_pe_controller.sv` evaluates pre-computed degradation metrics ($\hat{D}_{16}, \hat{D}_{32}, \hat{D}_{64}$) supplied via host configuration registers or layer metadata.
- **Limitation**:
  The controller does not evaluate real-time runtime network loss or backpropagation gradients on-chip. If host-supplied degradation estimates are inaccurate or out of calibration, suboptimal allocation decisions may occur.

---

## 3. Experimental Scope & Disclaimers

### 3.1 Cycle-Accurate Simulation vs. Physical Hardware
- All performance, cycle count, and memory read numbers were collected via cycle-accurate simulation using Icarus Verilog (`iverilog` / `vvp`).
- No physical ASIC tapeout, standard-cell synthesis, place-and-route, or FPGA bitstream generation was conducted in this milestone.
- **Strictly No Physical Energy or Timing Claims**:
  No claims are made regarding physical clock frequency (MHz/GHz), dynamic power consumption (mW), or energy-per-inference ($\mu\text{J}$). All comparisons are based strictly on measurable digital quantities: clock cycles, PE column utilization, and SRAM memory access counts.

### 3.2 Protected Baseline RTL File Integrity
- In strict adherence to project constraints, zero modifications were made to the 5 protected baseline RTL files:
  1. `phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv`
  2. `phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv`
  3. `phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv`
  4. `phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv`
  5. `phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv`
- Git diff verification reports exactly 0 diffs across all five files.
- Zero Git commits were executed.

