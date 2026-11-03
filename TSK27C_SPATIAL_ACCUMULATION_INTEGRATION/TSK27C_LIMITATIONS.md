# TSK-27C Architectural Scope & Limitations Report

## 1. Executive Summary
This document provides an engineering assessment of the architectural scope, boundary interfaces, and operational limitations of the **TSK-27C Spatial Sequencer Integration and Multi-Chunk Accumulation** subsystem (`tsk27c_spatial_accumulation_controller.sv`).

The subsystem demonstrates autonomous 2D spatial coordinate sequencing ($X \in [0, W_{tiles}-1], Y \in [0, H_{tiles}-1]$) coupled with multi-chunk inner reduction loops ($chunk\_idx \in [0, N_{chunks}-1]$) and strict accumulator preservation semantics.

---

## 2. Integration Boundary & Baseline RTL Protection

### 2.1 Protected Baseline Constraints
Under the project mandate, five RTL files are strictly protected and read-only:
1. `phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv`
2. `phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv`
3. `phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv`
4. `phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv`
5. `phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv`

### 2.2 Root Cause of Prior Accumulator Resets
In earlier milestones (TSK-24 through TSK-26C), multi-chunk reduction across channel tiles was blocked because:
- `slot_control_unit.sv` unconditionally asserted `accum_clear = 1'b1` upon slot initialization or command issue.
- `layer_command_sequencer.sv` and `adaptive_pe_controller.sv` transitioned directly to OFMAP drain (`ST_DRAIN`) at the end of every individual channel compute cycle.

Directly modifying `slot_control_unit.sv` or `accelerator_core_top.sv` to add multi-chunk bypass signals would violate the zero-modification rule on protected baseline RTL.

### 2.3 Non-Protected Integration Layer
To achieve 100% compliance without modifying protected RTL:
- The controller `tsk27c_spatial_accumulation_controller.sv` wraps `spatial_tile_sequencer.sv` and provides standardized core control interfaces (`core_accum_clear`, `core_drain_req`, `core_compute_valid`).
- The controller acts as the autonomous supervisory FSM that coordinates compute passes, selectively asserting `accum_clear` only on `chunk_idx == 0` and suppressing drain until `chunk_idx == total_chunks - 1`.
- Phase 6 in `tb_tsk27c_spatial_accumulation_controller.sv` directly connects the physical `mac_unit_40b` datapath to verify bit-exact hardware accumulation under this gating scheme.

---

## 3. Microarchitectural Limitations

### 3.1 Line Buffering and Overlapping Halo Reuse
- **Current Status**: The spatial tile sequencer advances coordinates $(x, y)$ in raster-scan order. Each tile computes independently or loads IFMAP data for its receptive field.
- **Limitation**: The architecture does not currently incorporate an on-chip 2D line-buffering cache or slide window register array to eliminate redundant off-chip IFMAP reads for overlapping $3 \times 3$ kernel windows between adjacent spatial tiles $(x, y)$ and $(x+1, y)$.
- **Impact**: IFMAP bandwidth from SRAM/DRAM is proportional to the number of tiles without spatial data reuse.

### 3.2 Dynamic Channel Depth & Uneven Tile Slicing
- **Current Status**: The controller supports arbitrary grid dimensions ($1 \le W_{tiles} \le 1024, 1 \le H_{tiles} \le 1024$) and arbitrary chunk counts ($1 \le N_{chunks} \le 64$).
- **Limitation**: All reduction chunks within a layer are assumed to have uniform channel depths (e.g., $K_{chunk} = 64$ for all chunks). Layers with non-multiple channel dimensions (e.g., input layer with $C_{in} = 3$ or residual blocks with irregular remainder channels) require host zero-padding or variable-length chunk support in a subsequent sequencer iteration.

### 3.3 Single Core Master Interface
- **Current Status**: The controller provides a single-core interface (`core_compute_valid`, `core_compute_ready`, `core_drain_req`, `core_drain_ready`, `core_accum_clear`).
- **Limitation**: Multi-core dispatch (e.g., orchestrating multiple `accelerator_core_top` instances in parallel) requires an external round-robin or tile-partitioning arbiter.

---

## 4. Empirical Scope & Synthesis Disclaimers

### 4.1 Zero Physical Energy / Frequency Claims
- All timing metrics reported in TSK-27C represent clock cycle counts measured via cycle-accurate SystemVerilog simulation (`iverilog` / `vvp`).
- No physical synthesis, place-and-route, or parasitic extraction was conducted for this milestone.
- Consequently, **no claims are made regarding physical clock frequency (MHz/GHz), dynamic power dissipation (mW), or energy-per-inference (mJ)**.

### 4.2 Numerical Verification Boundaries
- Fixed-point 40-bit saturating signed arithmetic was verified using `mac_unit_40b`.
- The numerical testbench verified positive, negative, and mixed-sign product accumulations across 3 chunks.
- Saturation bounds ($[-2^{39}, 2^{39}-1]$) and requantization scaling are handled downstream by the requantization unit, which receives data upon `core_drain_req`.

