# TSK-26B: Technical Scope and Limitations

## Objective Assessment of Milestone Scope

This document provides a rigorous, transparent boundary analysis of the verification performed in Milestone **TSK-26B**, clarifying what has been proven with hardware RTL evidence and what remains outside the current milestone's scope.

---

## 1. What Has Been Proven

### 1.1 Complete Mathematical Reduction ($K=576$)
- Prior milestones (TSK-24, TSK-26A) either truncated the reduction dimension to $K=64$ or evaluated isolated center-tap fragments. TSK-26B verified the **entire 576-step inner product** ($64\text{ channels} \times 3 \times 3\text{ kernel} = 576$) encompassing all 9 spatial filter positions.
- The hardware sequencer and compute feeder natively processed `cmd_k_total = 576` cycles without hardware modification or intermediate buffer truncation.

### 1.2 Bit-Exact Fixed-Point Numerical Integrity
- Across all 4 models and datasets, the hardware RTL datapath (mac units, column accumulators, saturating adder logic) matched the bit-exact software integer model with **0 mismatches across all 64 output channel elements (100.0% accuracy)**.
- Fixed-point INT16 Q4.12 dynamic range was verified: maximum accumulator magnitude reached 39,687,983 (out of a 40-bit saturating capacity of $\pm 549,755,813,887$), confirming that no accumulator overflow or clipping occurred.

### 1.3 Strict Cross-Mode Equivalence
- The output accumulator tensor is bit-exact identical whether executed on:
  - **64-PE Mode** (1 pass, 16 active columns)
  - **32-PE Mode** (2 channel passes, 8 active columns)
  - **16-PE Mode** (4 channel passes, 4 active columns)
- Cross-mode comparisons produced **0 mismatches across all 64 elements**.

### 1.4 Hardware Acceleration from Real Activation Sparsity
- Real post-ReLU activation sparsity (37.5% to 63.2%) was delivered through the sparse feeder and verified to reduce compute cycles by **42.2% to 50.1%** and SRAM buffer read transactions by **41.4% to 50.6%** with zero numerical degradation.

### 1.5 Bit-Exact Requantization
- 32 packed 32-bit words (64 INT16 values) were requantized (arithmetic right shift by 12, rounding, ReLU zero-clamping, and INT16 saturation) and matched the software reference with **100% bit-exact equivalence**.

---

## 2. Technical Limitations and In-Scope Constraints

### 2.1 Multi-Pass Tiling Orchestration
- While single-pass execution of $K=576$ is handled natively by the hardware layer sequencer, multi-pass channel tiling (2 passes for 32-PE, 4 passes for 16-PE) was orchestrated by the testbench driver issuing sequential layer commands.
- An autonomous multi-pass hardware sequencer that iterates through channel passes, updates buffer offsets, and manages inter-pass accumulator accumulation automatically in RTL without host/driver intervention remains a future architectural milestone.

### 2.2 Spatial Receptive Field Patch vs Full Feature-Map Rasterization
- TSK-26B validated a representative spatial receptive field patch ($3 \times 3 \times 64$) producing 64 output channel values.
- Validating the full $32 \times 32$ spatial output grid (1,024 spatial locations $\times$ 576 cycles $\approx 600,000$ hardware cycles per pass) in software-interpreted Icarus Verilog would require ~40 hours of continuous simulation time. Full feature-map rasterization is therefore deferred to hardware-accelerated FPGA emulation or Verilator C++ cycle-accurate simulation.

### 2.3 Off-Chip Memory and DMA Interface
- The SRAM memory system was verified using the multi-bank SRAM subsystem model (`multibank_sram_subsystem.sv`) with cycle-accurate telemetry monitors.
- Validation did not model physical DDR4/LPDDR4 DRAM controllers, PHY latencies, or AXI bus contention with external masters.

### 2.4 Energy Claims
- Consistent with audit rules established in TSK-23, cycle reductions and SRAM transaction reductions are measured directly from hardware handshakes and monitor registers. No unverified physical energy numbers are claimed in this report without post-layout gate-level power simulation.

