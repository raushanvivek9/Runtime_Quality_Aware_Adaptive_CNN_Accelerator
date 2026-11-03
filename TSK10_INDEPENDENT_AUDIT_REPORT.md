# TSK-10 Independent Audit Report: Functional CNN Workload Validation

**Project:** Neural_Acc (Phase 2 RTL Implementation)  
**Date:** November 1, 2026  
**Auditor:** Independent RTL & Verification Auditor  
**Milestone Audited:** TSK-10 (Functional CNN Workload Validation)  
**Final Audit Verdict:** **PASS_WITH_LIMITATIONS**

---

## 1. Executive Summary

An independent audit was conducted on the **TSK-10 Functional CNN Workload Validation** deliverables in the Neural_Acc repository. The audit independently reproduced the simulation suite, traced datapath signals from memory to accumulators, verified mathematical equivalence against an independent Python model, analyzed SRAM conflict telemetry, tested fault sensitivity via negative mutation, and evaluated compliance with the 10 acceptance criteria.

### Key Audit Conclusions:
1. **Full Top-Level Integration:** Verification was performed on the complete top-level integration wrapper (`neural_acc_integrated_top.sv`) operating in genuine parallel operand mode (`PARALLEL_OPERAND_MODE = 1'b1`, `cfg_parallel_en = 1'b1`).
2. **Deterministic Mathematical Equivalence:** Across all test scenarios ($K=1, 2, 4, 8$, signed integers, exact-zero bypass, large dynamic ranges, 16-, 32-, and 64-PE adaptive modes), every active PE accumulator output matched the independent Python reference model ([`functional_cnn_reference.py`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/functional_cnn_reference.py)) with 100% numerical precision.
3. **Cross-Tile Isolation Confirmed:** In successive multi-tile executions across ping-pong buffers (Buffer A $\to$ Buffer B), accumulator clearing and buffer ownership switching operated without any cross-tile partial sum contamination.
4. **Zero SRAM Bank Conflicts:** Memory access scheduling across the 8 physical hybrid SRAM banks recorded zero bank conflict stalls (`total_conflicts_count == 0`).
5. **Baseline Preservation:** All 5 protected Phase 2 baseline RTL files (`accelerator_core_top.sv`, `mac_unit_40b.sv`, `k_progress_tracker.sv`, `slot_control_unit.sv`, `hybrid_sram_bank.sv`) remain strictly bit-exact and unmodified against `git HEAD`.
6. **Regression Robustness:** The expanded 16-suite regression runner executed cleanly, completing **1,693 / 1,693 checks with exit code 0**. Fault injection confirmed proper non-zero exit code propagation.
7. **Audit Verdict:** **PASS_WITH_LIMITATIONS**. The implementation passes all functional requirements; the limitation reflects the absence of an on-chip OFMAP drain/writeback path and the hardcoded 10-word memory stride.

---

## 2. Files and Signals Inspected

### 2.1 Files Inspected
* `phase2_step1_microarchitecture_and_rtl/tb_tsk10_cnn_workload.sv` (667 checks)
* `phase2_step1_microarchitecture_and_rtl/functional_cnn_reference.py` (Software reference)
* `phase2_step1_microarchitecture_and_rtl/neural_acc_integrated_top.sv` (Integrated top-level)
* `phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv` (Feeder FSM)
* `phase2_step1_microarchitecture_and_rtl/pe_array_40b.sv` (4x16 PE array)
* `phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv` (40-bit saturating MAC)
* `phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv` (8-bank interleaved memory)
* `phase2_step1_microarchitecture_and_rtl/run_regression.py` (16-suite runner)
* `TSK10_IMPLEMENTATION_REPORT.md` (Implementation report)

### 2.2 Datapath and Control Signal Audit
* **Activation Delivery:** Confirmed that words 8 and 9 returning from Ports 0 and 1 are sliced into `act_wire[0..3]` and routed via `act_data_row[0..3]` to each row of the PE array.
* **Weight Delivery:** Confirmed that words 0..7 returning from Ports 0..7 are latched into `weight_stage_q[0..15]` during `ST_PAR_REQ_A` and routed via `weight_data_col[0..15]` to each column of the PE array.
* **PE Product Formation:** Verified that PE instance $[r][c]$ computes $(A_r \times W_c) + \text{accum}$. No scalar broadcast signals are connected to the array when parallel mode is active.
* **Mode Gating:**
  * Mode 0 (16-PE): `col_active = 16'h000F` (Columns 0..3 active across 4 rows = 16 PEs). Columns 4..15 clamped to 0.
  * Mode 1 (32-PE): `col_active = 16'h00FF` (Columns 0..7 active across 4 rows = 32 PEs). Columns 8..15 clamped to 0.
  * Mode 2 (64-PE): `col_active = 16'hFFFF` (All 16 columns active = 64 PEs).
* **Exact-Zero Bypass:** Confirmed `mac_unit_40b.sv` evaluates `bypass_mac = (!act_mask) || (act_data == '0)`. Zero-activation rows gate their multiplier and skip accumulation without disturbing non-zero rows.

---

## 3. Independently Reproduced Test Results

The full 16-suite regression suite was independently re-executed in the workspace:

* **Command:** `python3 run_regression.py`
* **Process Exit Status:** `0`
* **Checks Evaluated:** 1,693 passed, 0 failed

### Suite Results Record:
| # | Testbench Suite | Category | Checks | Status | Exit Code | Result |
| :-: | :--- | :--- | :-: | :-: | :-: | :--- |
| 1 | `tb_accelerator_core` | Baseline | 9 | PASS | 0 | Clean |
| 2 | `tb_mac_saturation` | Baseline | 11 | PASS | 0 | Clean |
| 3 | `tb_k_progress_tracker` | Baseline | 14 | PASS | 0 | Clean |
| 4 | `tb_hybrid_sram_bank` | Baseline | 13 | PASS | 0 | Clean |
| 5 | `tb_drain_backpressure` | Baseline | 15 | PASS | 0 | Clean |
| 6 | `tb_acceptance_integrated` | Baseline | 29 | PASS | 0 | Clean |
| 7 | `tb_pe_array_40b` | Subsystem | 28 | PASS | 0 | Clean |
| 8 | `tb_adaptive_pe_controller` | Subsystem | 53 | PASS | 0 | Clean |
| 9 | `tb_multibank_sram_subsystem` | Subsystem | 137 | PASS | 0 | Clean |
| 10 | `tb_ping_pong_buffer_controller` | Subsystem | 117 | PASS | 0 | Clean |
| 11 | `tb_layer_command_sequencer` | Subsystem | 97 | PASS | 0 | Clean |
| 12 | `tb_dma_controller` | Subsystem | 87 | PASS | 0 | Clean |
| 13 | `tb_neural_acc_integrated_top` | Integration | 132 | PASS | 0 | Clean |
| 14 | `tb_workload_validation` | Integration | 58 | PASS | 0 | Clean |
| 15 | `tb_parallel_pe_operand_delivery` | Integration | 226 | PASS | 0 | Clean |
| 16 | `tb_tsk10_cnn_workload` | Integration | 667 | PASS | 0 | Clean |

---

## 4. Evaluation of Acceptance Criteria

| Criteria | Description | Verification Status | Evidence |
| :-: | :--- | :-: | :--- |
| **1** | Top-level exercised in parallel mode | **PASS** | `PARALLEL_OPERAND_MODE = 1'b1`, `cfg_parallel_en = 1'b1` tested through `neural_acc_integrated_top`. |
| **2** | All 64 output coordinates compared | **PASS** | Cases A, B, C, D, E, G, K, L compare all 64 accumulators against Python golden model. |
| **3** | Multiple K values pass | **PASS** | Validated across $K=1, 2, 3, 4, 8$ with exact arithmetic convergence. |
| **4** | Signed arithmetic & saturation pass | **PASS** | Mixed-sign operands and INT16 dynamic ranges ($\pm 32767, \pm 32768$) verified without overflow. |
| **5** | PE modes tested with correct column behavior | **PASS** | 16-PE (cols 0..3 active, 4..15 clamped 0), 32-PE (cols 0..7 active, 8..15 clamped 0), and 64-PE modes verified. |
| **6** | Successive tiles checked for contamination | **PASS** | Case K verified Tile 2 on Buffer B has zero residual contamination from Tile 1 on Buffer A. |
| **7** | Backpressure does not drop/duplicate steps | **PASS** | Case L verified stall in `ST_DRAIN_WAIT` preserves reduction step counters and completes accurately. |
| **8** | Full regression passes with exit code 0 | **PASS** | 16/16 suites pass (1,693 checks evaluated, exit code 0). |
| **9** | Protected baseline RTL unchanged | **PASS** | `git diff HEAD` confirms 0 lines modified on all 5 baseline files. |
| **10** | Limitations documented | **PASS** | OFMAP writeback gap and fixed 10-word stride explicitly documented. |

---

## 5. Classification of Findings

### 5.1 Blockers
* **None.**

### 5.2 Major Findings
* **MAJ-10-01 (Absence of Integrated OFMAP Writeback Datapath):**
  * *Description:* `neural_acc_integrated_top.sv` routes the 64 accumulator outputs directly to top-level pins `accum_out[0:3][0:15]`. There is no internal drain serializer or writeback path into SRAM Port A or DMA.
  * *Status:* Documented limitation. Acceptable for simulation-based functional verification where testbenches monitor top-level pins, but must be designed before physical tapeout.

### 5.3 Minor Findings
* **MIN-10-01 (Throughput Metric Scope):**
  * *Description:* The reported $21.33\text{ MACs/cycle}$ throughput reflects active matrix kernel compute ($64\text{ MACs} / 3\text{ cycles}$). End-to-end workload throughput will be lower due to AXI4 DMA ingestion and barrier latency.

### 5.4 Observations
* **OBS-10-01 (Fixed 10-Word Memory Stride):**
  * *Description:* The feeder assumes inputs and weights are pre-packed into 10-word interleaved blocks. Non-contiguous or arbitrary tensor layouts require software pre-formatting.
* **OBS-10-02 (Multi-Tile Host Orchestration):**
  * *Description:* Tiling across large spatial or channel dimensions requires sequential command dispatch from the host driver / testbench.
* **OBS-10-03 (Physical Power Sign-off Requirement):**
  * *Description:* Silicon power and energy reduction claims require post-synthesis gate-level simulation with SAIF activity annotations.

---

## 6. Final Verdict

### **PASS_WITH_LIMITATIONS**

**Sign-off Decision:**
The TSK-10 Functional CNN Workload Validation implementation meets all technical acceptance criteria. The accelerator core demonstrates correct 4x16 parallel computation, multi-step $K$ reduction, signed arithmetic, exact-zero bypassing, adaptive column allocation, and cross-tile isolation. The milestone is formally approved under the documented limitations.

