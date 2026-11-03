# TSK-27A: Implementation Plan
## Autonomous Spatial Sequencing and Accumulator Preservation

**Milestone:** TSK-27A / TSK-27B  
**Project:** Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Status:** In Progress — Architecture & Planning Phase  

---

## 1. Objectives & Scope

1. **Autonomous Spatial Sequencing (TSK-27A):**
   - Eliminate host/testbench per-pixel command dispatch by implementing a dedicated hardware control module: `spatial_tile_sequencer.sv`.
   - Provide configurable grid dimensions ($W_{out}, H_{out}$), stride/step ($step_x, step_y$), coordinate generation $(x, y)$, linear tile indexing, address computation, and deterministic command handshakes.
   - Support small and scalable spatial grids (e.g., $1 \times 1, 2 \times 2, 3 \times 3, 4 \times 4, 8 \times 8$).
   - Enforce robust error handling (zero dimensions, illegal stride, start while busy, unexpected abort).

2. **Accumulator Preservation Investigation & Proposal (TSK-27B):**
   - Audit the exact accumulator clearing, lifetime, and draining mechanisms across:
     - `mac_unit_40b.sv` (protected baseline)
     - `accelerator_core_top.sv` (protected baseline)
     - `slot_control_unit.sv` (protected baseline)
     - `adaptive_pe_controller.sv`
     - `layer_command_sequencer.sv`
     - `pe_array_40b.sv`
   - Determine whether the existing interfaces support multi-pass reductions without losing partial sums.
   - Document whether any modifications to protected files would be required for core-level integration and present a standalone preservation controller architecture.

3. **Verification & Deliverables:**
   - Construct comprehensive testbench `tb_spatial_tile_sequencer.sv` exercising all corner cases.
   - Execute verification under Icarus Verilog, export `SEQUENCING_RESULTS.csv`.
   - Run the full 20-suite baseline regression to ensure 0 regressions.
   - Verify 0 diffs across all five protected baseline RTL files.

---

## 2. Protected RTL Rules & Non-Negotiable Constraints

- The following five baseline RTL files are **STRICTLY READ-ONLY (0 diffs)**:
  1. `phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv`
  2. `phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv`
  3. `phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv`
  4. `phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv`
  5. `phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv`
- **Zero Git Commits:** Do not execute `git commit`.
- **Preserve Historical Evidence:** Do not delete or overwrite prior milestone artifacts.
- **Physical Claims:** Do not report unsupported physical energy or timing claims.

---

## 3. Step-by-Step Execution Plan

- [x] **Step 1: Architectural Audit & Code Inspection:**
  - Trace `accum_clear`, `drain_enable`, and command handshakes in RTL.
  - Author `IMPLEMENTATION_PLAN.md` and `ARCHITECTURE.md`.
- [ ] **Step 2: Design `spatial_tile_sequencer.sv`:**
  - Define parameterizable grid width, height, strides, and memory address offsets.
  - Implement FSM states: `ST_IDLE`, `ST_VALIDATE`, `ST_DISPATCH`, `ST_WAIT_STEP`, `ST_ADVANCE`, `ST_DONE`, `ST_ERROR`.
  - Provide downstream command handshake (`cmd_valid`, `cmd_ready`, `step_done`).
  - Output current coordinates `(current_x, current_y)`, linear `tile_idx`, and memory pointers.
- [ ] **Step 3: Accumulator Preservation Audit (`ACCUMULATOR_PRESERVATION_AUDIT.md`):**
  - Document root causes of accumulator clearing per command in `slot_control_unit` and `adaptive_pe_controller`.
  - Design a non-invasive architectural proposal (`accum_preservation_controller`).
- [ ] **Step 4: Comprehensive Verification (`tb_spatial_tile_sequencer.sv`):**
  - Scenario 1: Asynchronous and synchronous reset behavior.
  - Scenario 2: Single-position execution ($1 \times 1$ grid).
  - Scenario 3: Small spatial grid ($2 \times 2$ grid with 4 tiles).
  - Scenario 4: Asymmetric spatial grid ($3 \times 4$ grid with 12 tiles).
  - Scenario 5: Large spatial grid ($8 \times 8$ grid with 64 tiles).
  - Scenario 6: Boundary coordinate check (first position $(0,0)$, last position $(W-1, H-1)$).
  - Scenario 7: Coordinate rollover between rows ($x = W-1 \to x = 0, y = y + 1$).
  - Scenario 8: Invalid configuration handling ($W = 0$ or $H = 0$).
  - Scenario 9: Start-while-busy lockout and reject flag.
  - Scenario 10: Downstream backpressure handling (`cmd_ready = 0` stalls).
  - Scenario 11: Consecutive back-to-back grid executions.
  - Scenario 12: Deterministic command count and tile index tracking.
- [ ] **Step 5: Run Baseline Regressions & Verify Protected Files:**
  - Execute `run_regression.py` across all 20 testbench suites.
  - Execute `git diff --exit-code` on protected files.
- [ ] **Step 6: Document Integration Status & Final Reports:**
  - Author `INTEGRATION_STATUS.md`, `LIMITATIONS.md`, `README.md`, and `FINAL_AUDIT_REPORT.md`.

