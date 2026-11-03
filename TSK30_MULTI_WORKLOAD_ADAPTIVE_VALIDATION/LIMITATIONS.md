# TSK-30 Architectural Limitations & Engineering Scope Report

## 1. Executive Summary
This document outlines the architectural boundaries, microarchitectural limitations, and experimental constraints established during the **TSK-30: Multi-Workload Adaptive PE Allocation Validation** milestone on the `Neural_Acc` accelerator.

---

## 2. Microarchitectural Limitations & Trade-Offs

### 2.1 Sparse Execution: Switching Suppression vs. Time-Domain Compaction
- **Current RTL Architecture**:
  The sparse execution logic in `tsk30_multi_workload_engine.sv` gates the multiplier enable strobe and suppresses weight SRAM read enables when an activation word is exactly zero ($A[k] == 0$).
- **Limitation**:
  The architecture does not implement an asynchronous compaction FIFO queue or compressed-sparse-row (CSR/CSC) coordinate indexing logic. Therefore, the spatial and reduction loop iterators advance linearly through all $K = 576$ steps.
- **Hardware Impact**:
  Weight SRAM reads and active MAC compute toggling are reduced by the exact activation sparsity percentage (48.11% in WL3 up to 84.92% in WL4). However, wall-clock cycle latency remains identical between dense and sparse modes at the same PE count (e.g., 9,569 cycles in 64-PE mode). Cycle compaction would require specialized non-zero address queueing hardware.

### 2.2 Adaptive PE Allocation: Area/Power Throttle vs. Latency Trade-Off
- **Empirical Reality**:
  Adaptive PE allocation does **not** accelerate inference over Fixed 64-PE mode:
  - 64-PE mode: 9,569 cycles ($1.00\times$)
  - 32-PE mode: 19,121 cycles ($1.998\times$ latency penalty)
  - 16-PE mode: 38,225 cycles ($3.995\times$ latency penalty)
- **Architectural Role**:
  Adaptive allocation operates purely as an **adaptive hardware throttle**. When accuracy degradation constraints permit ($\hat{D}_{mode} \le D_{max}$), the controller selects 32-PE or 16-PE mode to power-gate or deactivate 50.0% to 75.0% of the PE columns. This frees thermal headroom or allows multi-tenant core sharing, but directly doubles or quadruples completion latency due to multi-pass channel tiling.

### 2.3 Activation SRAM Re-Reading in Multi-Pass Tiling
- **Channel Partitioning**:
  Because $C_{out} = 16$, 16-PE mode requires 4 channel passes ($4 \times 4$), and 32-PE mode requires 2 channel passes ($2 \times 8$).
- **Limitation**:
  Without an on-chip activation line buffer or reuse cache, input activations must be re-streamed from SRAM for each channel pass:
  - 64-PE: 9,216 activation reads (1 pass)
  - 32-PE: 18,432 activation reads (2 passes, $2.0\times$)
  - 16-PE: 36,864 activation reads (4 passes, $4.0\times$)

### 2.4 Externally Guided Adaptive Allocation
- **Controller Boundary**:
  The Stage 8A controller evaluates degradation estimates ($\hat{D}_{16}, \hat{D}_{32}, \hat{D}_{64}$) provided by host descriptors or offline layer profiling.
- **Limitation**:
  The hardware does not independently calculate task accuracy loss or backpropagation gradients on-chip.

---

## 3. Experimental Scope & Disclaimers

### 3.1 Cycle-Accurate Simulation vs. Physical Hardware
- All performance, cycle count, and memory read metrics reported in TSK-30 were measured via cycle-accurate SystemVerilog simulation using Icarus Verilog (`iverilog` / `vvp`).
- No physical ASIC tapeout, standard-cell synthesis, place-and-route, or FPGA bitstream generation was conducted in this milestone.
- **Strictly No Physical Energy or Timing Claims**:
  No claims are made regarding physical clock frequency (MHz/GHz), dynamic power consumption (mW), or energy-per-inference ($\mu\text{J}$). All comparisons are based strictly on measurable digital quantities: clock cycles, PE column utilization, and SRAM memory access counts.

### 3.2 Baseline RTL Protection Compliance
- Five baseline RTL files remain strictly protected and unmodified:
  1. `phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv` (0 diffs)
  2. `phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv` (0 diffs)
  3. `phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv` (0 diffs)
  4. `phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv` (0 diffs)
  5. `phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv` (0 diffs)
- Git diff verification reports exactly 0 diffs across all five files.
- Zero Git commits were executed.

