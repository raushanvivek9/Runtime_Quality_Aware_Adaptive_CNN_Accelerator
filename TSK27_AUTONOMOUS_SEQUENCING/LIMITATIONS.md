# TSK-27A: Technical Limitations and Constraints Analysis

**Milestone Identifier:** TSK-27A / TSK-27B  
**Project:** Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Status:** Documented  

---

## 1. Architectural & Scope Limitations

### 1.1 Standalone Verification vs. Top-Level Integration
- `spatial_tile_sequencer.sv` is fully verified as a standalone synthesizable module (12 test scenarios, 30 passed assertions, zero failures).
- It is **not yet wired into `neural_acc_integrated_top.sv`**. This decision was made intentionally to preserve the 20 existing regression suites and prevent pinout/interface changes to the validated top-level module without a dedicated integration milestone.

### 1.2 Accumulator Preservation in Protected Baseline RTL
- As established in [`ACCUMULATOR_PRESERVATION_AUDIT.md`](file:///e:/MTech/LanChain/MTP/TSK27_AUTONOMOUS_SEQUENCING/ACCUMULATOR_PRESERVATION_AUDIT.md), `slot_control_unit.sv` unconditionally clears accumulators in state `ST_ALLOCATED`.
- Because `slot_control_unit.sv` and `accelerator_core_top.sv` are protected baseline files, adding an `accum_preserve` port requires explicit architectural approval. Per task instructions, no modifications were made to protected RTL.

### 1.3 Memory Subsystem & 2D Line Buffering
- `spatial_tile_sequencer.sv` autonomously computes 2D coordinates $(x, y)$ and SRAM address pointers.
- However, it does not implement an internal 2D line-buffer array to cache overlapping receptive-field pixels. The memory subsystem currently assumes that activations for each spatial tile are positioned in SRAM or flattened via im2col.

### 1.4 No Unsupported Physical Claims
- In accordance with research standards, no claims are made regarding physical ASIC core area, clock frequency, or dynamic energy dissipation for the sequencer until post-synthesis netlist static timing and gate-level power simulation are executed.

