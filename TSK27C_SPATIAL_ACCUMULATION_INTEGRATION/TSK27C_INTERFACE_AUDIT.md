# TSK-27C: Interface and Repository Audit Report
## Analysis of Spatial Sequencing, Accumulator Clearing, and Multi-Chunk Reduction Datapath

**Milestone Identifier:** TSK-27C  
**Project:** Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Status:** COMPLETE (Pre-Implementation Audit)  
**Target:** Non-Protected Integration Layer for Autonomous Spatial Tile Sequencing and Multi-Chunk Accumulation  

---

## 1. Executive Summary

Milestone **TSK-27C** integrates the standalone spatial sequencer ([`spatial_tile_sequencer.sv`](file:///e:/MTech/LanChain/MTP/TSK27_AUTONOMOUS_SEQUENCING/spatial_tile_sequencer.sv)) with the accumulator-preservation requirements identified in TSK-27B. The objective is to establish an autonomous spatial advancement and multi-chunk reduction controller that preserves partial sums in hardware accumulators across sequential reduction chunks without modifying protected baseline RTL.

This audit evaluates:
1. The exact control signals and command handshakes between spatial scheduling, chunk iteration, accumulator clearing, and OFMAP draining.
2. The accessibility and persistence of MAC accumulator values between consecutive commands.
3. The boundary between protected baseline files and the new non-protected integration module.

---

## 2. Comprehensive RTL Interface Audit

### 2.1 Spatial Sequencer: `spatial_tile_sequencer.sv`
- **Inputs:** `clk`, `rst_n`, `start_req`, `abort_req`, `error_clear`, `cfg_grid_w`, `cfg_grid_h`, `cfg_step_x`, `cfg_step_y`, `cmd_ready`, `step_done`.
- **Outputs:** `busy`, `done_pulse`, `error_flag`, `error_code`, `busy_reject`, `current_x`, `current_y`, `current_tile_idx`, `total_tiles_count`, `cmd_valid`, `cmd_spatial_x`, `cmd_spatial_y`, `cmd_tile_idx`, `cmd_last_tile`, `cmd_ifmap_addr`, `cmd_ofmap_addr`.
- **Handshake Behavior:**
  - Asserts `cmd_valid = 1` for tile $(x, y)$.
  - Waits for `cmd_ready = 1`.
  - Transitions to `ST_WAIT_STEP` awaiting `step_done`.
  - Upon receiving `step_done`, advances coordinates $(x, y)$ or pulses `done_pulse` if `tile_idx == total_tiles - 1`.
- **Audit Finding:** The sequencer successfully controls 2D spatial navigation. However, it operates on single-pass commands per tile; it has no native concept of multi-chunk reduction ($K$-partitioning).

---

### 2.2 Arithmetic Accumulator: `mac_unit_40b.sv` (Protected Baseline)
- **Inputs:** `clk`, `rst_n`, `enable`, `accum_clear`, `sat_clear`, `act_data`, `act_mask`, `weight_data`.
- **Outputs:** `accum_out`, `sticky_saturation`, `cycle_skipped`.
- **Internal Behavior:**
  ```verilog
  if (accum_clear) begin
      accum_out <= '0;
  end else if (enable && !bypass_mac) begin
      accum_out <= sum_41[ACCUM_WIDTH-1:0];
  end
  ```
- **Audit Finding:**
  - The accumulator register `accum_out` **strictly preserves** its accumulated 40-bit value as long as `accum_clear == 1'b0`.
  - Successive compute passes add directly onto `accum_out`.
  - The physical MAC unit natively supports multi-chunk accumulation without software workarounds.

---

### 2.3 Single-Core Baseline: `slot_control_unit.sv` & `accelerator_core_top.sv` (Protected Baseline)
- **Control Path:**
  `slot_alloc_req` $\to$ `slot_control_unit.sv` (State `ST_FREE` $\to$ `ST_ALLOCATED`).
- **Clearing Behavior:**
  In `ST_ALLOCATED`, `accum_clear = 1'b1` is unconditionally asserted for 1 cycle.
- **Audit Finding:**
  - `slot_control_unit.sv` lacks an `accum_preserve` port.
  - In `accelerator_core_top.sv`, slot allocation unconditionally wipes the accumulator.
  - **Protected Boundary Rule:** Because both files are protected baseline RTL, modifying them directly is prohibited. Integration must either interface directly with the PE datapath (`pe_array_40b` / `mac_unit_40b`) or wrap the core non-invasively.

---

### 2.4 Integrated System: `adaptive_pe_controller.sv` & `layer_command_sequencer.sv`
- **Control Path:**
  `cmd_valid` $\to$ `layer_command_sequencer` $\to$ `pe_start_req` $\to$ `adaptive_pe_controller` (State `ST_CLEAR`).
- **Clearing Behavior:**
  In `ST_CLEAR`, `adaptive_pe_controller` unconditionally asserts `accum_clear = 1'b1`.
- **Draining Behavior:**
  When `compute_done` arrives, `layer_command_sequencer` unconditionally transitions to `ST_DRAIN`.
- **Audit Finding:**
  - Issuing an individual layer command for each $K$-chunk through `layer_command_sequencer` causes two defects:
    1. Accumulators are cleared at the start of Chunk 1, Chunk 2, etc.
    2. Partial sums are drained prematurely to Buffer B at the end of Chunk 0, Chunk 1, etc.
  - Therefore, multi-chunk reduction cannot be achieved simply by issuing back-to-back commands to `layer_command_sequencer` without an intermediate preservation controller.

---

## 3. Interface Gap and Resolution Strategy

```
+-----------------------------------------------------------------------------------------------------------------------------+
| Subsystem              | Existing Interface Behavior                 | Required Multi-Chunk Behavior | Resolution Strategy  |
+------------------------+---------------------------------------------+-------------------------------+----------------------+
| spatial_tile_sequencer | Dispatches 1 command per spatial tile       | Iterates N chunks per tile    | Hierarchical wrapper |
| mac_unit_40b           | Preserves accum_out when accum_clear=0      | Accumulate across chunks      | Native datapath reuse|
| slot_control_unit      | Unconditionally clears on ST_ALLOCATED      | Gate clear on chunks > 0      | Audit / Non-invasive |
| adaptive_pe_controller | Unconditionally clears on ST_CLEAR          | Gate clear on chunks > 0      | Control gating layer |
| layer_command_sequencer| Unconditionally drains on compute_done      | Drain only on final chunk     | Control gating layer |
+-----------------------------------------------------------------------------------------------------------------------------+
```

### Resolution via Dedicated Integration Layer:
We will implement `tsk27c_spatial_accumulation_controller.sv`:
1. It encapsulates or coordinates `spatial_tile_sequencer.sv`.
2. For each spatial tile $(x, y)$, it sequences $N_{chunks}$ reduction passes:
   - **Chunk 0 (First Chunk):** Asserts `accum_clear = 1'b1`, enables compute, suppresses drain upon completion.
   - **Chunk 1..N-2 (Intermediate Chunks):** Holds `accum_clear = 1'b0`, enables compute, suppresses drain upon completion.
   - **Chunk N-1 (Final Chunk):** Holds `accum_clear = 1'b0`, enables compute, triggers OFMAP drain upon completion.
3. Upon drain completion of the final chunk, it acknowledges the spatial sequencer via `step_done`, advancing to the next $(x, y)$ coordinate.
4. When all spatial coordinates and reduction chunks are complete, it asserts `done_pulse` to the host.

