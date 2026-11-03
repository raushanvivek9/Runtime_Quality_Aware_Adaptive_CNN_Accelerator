# TSK-09A Implementation Report: Parallel PE Operand Delivery

**Project:** Neural_Acc (Phase 2 RTL Implementation)  
**Date:** November 1, 2026  
**Status:** COMPLETE & PASSED  
**Milestone:** TSK-09A (Independent 4x16 PE Operand Delivery)  
**Verification Coverage:** 15/15 Testbench Suites Passing (1,026 / 1,026 Checks, 0 Failures)

---

## 1. Executive Summary

In milestone TSK-09, an independent architectural audit revealed that the Phase 2 integrated top-level (`neural_acc_integrated_top.sv`) broadcast a single scalar activation and weight operand across all 64 processing elements (PEs), causing all active PEs to compute identical outputs.

Under **TSK-09A**, the datapath was upgraded to deliver genuine independent row activations and column weights to the 4x16 PE array without modifying any protected Phase 2 baseline RTL files. By leveraging the 8 read ports of the `multibank_sram_subsystem`, a conflict-free, 2-cycle interleaved memory access schedule was implemented in `datapath_compute_feeder.sv`. 

All 64 PEs now execute distinct outer-product matrix-multiply accumulations ($Y_{r,c} = \sum_k A_r^{(k)} \times W_c^{(k)}$), achieving up to **$64\times$ higher computational throughput** while strictly maintaining zero bank conflicts and full backward compatibility across all 14 legacy simulation testbenches.

---

## 2. Modules Modified

Strict preservation boundaries were observed: baseline RTL files (`accelerator_core_top.sv`, `mac_unit_40b.sv`, `k_progress_tracker.sv`, `slot_control_unit.sv`, `hybrid_sram_bank.sv`) were left 100% untouched (`git diff` clean). Only two integration-layer modules were updated:

### 2.1 `datapath_compute_feeder.sv`
* **Multi-Port Read Interface:** Expanded from a single read channel (`sram_rd_req_0`) to an 8-port wide bus (`sram_rd_req_bus[7:0]`, `sram_rd_addr_bus[7:0]`, `sram_rd_ready_bus[7:0]`, `sram_rd_rvalid_bus[7:0]`, `sram_rd_dout_bus[7:0]`). Backward-compatible probe aliases were preserved to support existing hierarchical testbench bindings.
* **Vector Output Generation:** Replaced single scalar probe outputs (`act_sample`, `weight_sample`) with dedicated row vectors (`act_data_row[0..3]`, `act_mask_row[0..3]`) and column vectors (`weight_data_col[0..15]`).
* **2-Cycle Conflict-Free Fetch FSM:** Introduced parallel pipeline states (`ST_PAR_REQ_W`, `ST_PAR_REQ_A`, `ST_PAR_COMPUTE`, `ST_PAR_STEP_CHECK`):
  * **Cycle A (`ST_PAR_REQ_W`):** Dispatches simultaneous read requests across Banks 0..7 for 8 weight words (16 column weights).
  * **Cycle B (`ST_PAR_REQ_A`):** Latches returning weights into `weight_stage_q[0..15]`, while requesting 2 activation words (4 row activations) across Banks 0..1.
  * **Cycle C (`ST_PAR_COMPUTE`):** Feeds latched column weights and returning row activations to the PE array, asserting `compute_enable_in` for 1 clock cycle.
* **Zero-Skipping Vector Support:** Monitors `act_mask_row[0..3]`. If all row activations are zero (`act_mask_all_zero == 1'b1`), the feeder asserts `cycle_skipped` and increments `k_skipped` without firing the MAC array, exactly matching architectural specifications.

### 2.2 `neural_acc_integrated_top.sv`
* **Mode Selection & Backward Compatibility:** Added module parameter `PARALLEL_OPERAND_MODE` (default `1'b0`) and top-level configuration input `cfg_parallel_en` (default `1'b0`).
* **SRAM Read Interconnect:** Removed artificial tie-offs (`sram_rd_req[7:1] = '0`), connecting all 8 read ports of `multibank_sram_subsystem` directly to `datapath_compute_feeder`.
* **Operand Multiplexing:**
  * When `cfg_parallel_en == 1'b1` or `PARALLEL_OPERAND_MODE == 1'b1`: routes `feeder_act_data_row[r]` and `feeder_weight_data_col[c]` directly to `pe_array_40b`.
  * When legacy mode (`par_active == 1'b0`): broadcasts scalar sample across all rows and columns (`{4{feeder_act_sample}}`, `{16{feeder_weight_sample}}`).

---

## 3. SRAM Addressing Scheme for 4x16 Operand Delivery

### 3.1 Memory Organization & Interleaving
The `multibank_sram_subsystem` comprises 8 independent physical hybrid SRAM banks with low-order word interleaving:
$$\text{Physical Bank Index} = \text{Address}[2:0]$$
$$\text{Row Offset within Bank} = \text{Address}[10:3]$$
Each word is 32 bits wide, packing two 16-bit signed operands.

### 3.2 Conflict-Free Interleaved Framing
To supply 4 row activations and 16 column weights per K-step, 10 words (320 bits) are required:
* **Weights (16 elements $\times$ 16 bits = 8 words):** Stored at offsets `[active_base + k*10 + 0]` through `[active_base + k*10 + 7]`.
* **Activations (4 elements $\times$ 16 bits = 2 words):** Stored at offsets `[active_base + k*10 + 8]` through `[active_base + k*10 + 9]`.

```
========================================================================================
Cycle A: 8-Bank Parallel Weight Fetch (Zero Conflicts)
  Word Offset :  +0    +1    +2    +3    +4    +5    +6    +7
  Physical Bank: Bank0 Bank1 Bank2 Bank3 Bank4 Bank5 Bank6 Bank7
  Contents    : W0..1 W2..3 W4..5 W6..7 W8..9 W10..11 W12..13 W14..15
----------------------------------------------------------------------------------------
Cycle B: 2-Bank Parallel Activation Fetch (Zero Conflicts) + Weight Latch
  Word Offset :  +8    +9
  Physical Bank: Bank0 Bank1  (Banks 2..7 idle)
  Contents    : A0..1 A2..3
----------------------------------------------------------------------------------------
Cycle C: 4x16 Matrix Multiplier Compute Pulse (1 Clock Cycle)
  Row Inputs  : Act[0], Act[1], Act[2], Act[3]
  Col Inputs  : Weight[0] ... Weight[15]
  Active PEs  : 64 PEs compute Y[r, c] += Act[r] * Weight[c] simultaneously
========================================================================================
```

Because low-order address bits increment monotonically from 0 to 7 in Cycle A and 0 to 1 in Cycle B, **every concurrent request targets a distinct physical bank**. The internal crossbar detects zero address collisions (`total_conflicts_count == 0`), eliminating all conflict stalls.

---

## 4. Latency and Throughput Analysis

| Metric | Baseline Scalar Broadcast (TSK-07/08) | Parallel Vector Mode (TSK-09A) |
| :--- | :--- | :--- |
| **SRAM Read Ports Used** | 1 of 8 ports | 8 of 8 ports |
| **Fetch Latency per K-step** | 1 - 2 cycles | 2 cycles |
| **Compute Latency per K-step** | 1 cycle | 1 cycle |
| **Total Cycles per K-step** | 3 cycles | 3 cycles |
| **Distinct MAC Operations per Step** | 1 (all 64 PEs duplicate) | 64 (full outer product) |
| **Bank Conflicts Observed** | 0 | 0 |
| **Throughput (64-PE Mode)** | 0.33 MACs/cycle | **21.33 MACs/cycle** |
| **Throughput (32-PE Mode)** | 0.33 MACs/cycle | **10.67 MACs/cycle** |
| **Throughput (16-PE Mode)** | 0.33 MACs/cycle | **5.33 MACs/cycle** |
| **Effective Functional Speedup** | $1.0\times$ (reference) | **$64.0\times$** |

---

## 5. New Testbench: `tb_parallel_pe_operand_delivery.sv`

A standalone, self-checking SystemVerilog testbench was designed to validate all 12 architectural requirements with 226 explicit runtime assertions:

* **Scenario 1: Full 4x16 Matrix Product Correctness ($K=1$):**
  Fed distinct row activations ($A = [10, -5, 8, -12]$) and column weights ($W_c = (c - 8) \times 3$). Verified that all 64 PEs computed mathematically exact, distinct signed products ($P_{r,c} = A_r \times W_c$).
* **Scenario 2: Zero-Skipping Isolation:**
  Configured sparse row activation masks. Verified that zero-mask rows gated computation without stalling active rows, and all-zero vectors advanced $K$ with `k_skipped` incremented and zero MAC power toggle.
* **Scenario 3: Adaptive PE Allocation Modes:**
  * **16-PE Mode:** Rows 0..1 $\times$ Cols 0..7 active (16 PEs). Verified unallocated rows 2..3 and cols 8..15 remain strictly zero.
  * **32-PE Mode:** Rows 0..3 $\times$ Cols 0..7 active (32 PEs). Verified unallocated cols 8..15 remain zero.
  * **64-PE Mode:** All 64 PEs actively compute.
* **Scenario 4: Multi-K Step Accumulation ($K=8$):**
  Executed an 8-step matrix accumulation. Verified exact cumulative 40-bit dot products across all 64 accumulators against an independent software reference model.
* **Scenario 5: SRAM Conflict-Free Access:**
  Sampled `dut.u_sram.total_conflicts_count` across multi-step parallel reads. Verified conflict count remained strictly zero.
* **Scenario 6: Consumer Backpressure Stall and Un-Stall:**
  Requested an uncommitted ping-pong buffer ID. Confirmed pipeline halted cleanly in `ST_DRAIN_WAIT`, maintained internal state without data loss, and resumed execution immediately when the buffer became available.
* **Scenario 7: Overlapped Ping-Pong Buffer Switching (Buffer A $\to$ Buffer B):**
  Streamed a secondary layer into Buffer B via DMA while Buffer A was actively computing. Switched buffers upon layer boundary, verifying non-identical output accumulation between layers ($Y_A \neq Y_B$).

---

## 6. Comprehensive Regression Results

All 15 testbench suites in `run_regression.py` were executed. Every suite passed with zero errors, producing an exit code of 0.

```
#   | Testbench Suite                  | Category     | Checks   | Status | Summary Output
--------------------------------------------------------------------------------------------------------------
1   | tb_accelerator_core              | Baseline     | 9        | PASS   | [SUCCESS] All Phase 2 Step 1 RTL Tests Completed Successfully!
2   | tb_mac_saturation                | Baseline     | 11       | PASS   | [SUCCESS] All MAC Saturation & Clear Tests Completed Successfully!
3   | tb_k_progress_tracker            | Baseline     | 14       | PASS   | [SUCCESS] All K-Progress Tracker Tests Completed Successfully!
4   | tb_hybrid_sram_bank              | Baseline     | 13       | PASS   | [SUCCESS] All SRAM Focused Tests Completed Successfully!
5   | tb_drain_backpressure            | Baseline     | 15       | PASS   | [SUCCESS] All Drain & Backpressure Tests Completed Successfully!
6   | tb_acceptance_integrated         | Baseline     | 29       | PASS   | [SUCCESS] All Executable RTL Acceptance Tests Passed with Zero Failures!
7   | tb_pe_array_40b                  | Subsystem    | 28       | PASS   | [SUCCESS] All TSK-01 Multi-PE Array RTL Tests Passed!
8   | tb_adaptive_pe_controller        | Subsystem    | 53       | PASS   | [SUCCESS] All TSK-02 Adaptive PE Controller RTL Tests Passed!
9   | tb_multibank_sram_subsystem      | Subsystem    | 137      | PASS   | [RESULT] ALL TESTS PASSED SUCCESSFULLY!
10  | tb_ping_pong_buffer_controller   | Subsystem    | 117      | PASS   | [SUCCESS] All TSK-04 Ping-Pong Buffer Controller Tests Passed!
11  | tb_layer_command_sequencer       | Subsystem    | 97       | PASS   | [SUCCESS] All TSK-05 Layer Command Sequencer Tests Passed!
12  | tb_dma_controller                | Subsystem    | 87       | PASS   | [SUCCESS] All TSK-06 DMA Controller Tests Passed!
13  | tb_neural_acc_integrated_top     | Integration  | 132      | PASS   | [SUCCESS] All TSK-07 System Integration Tests Passed!
14  | tb_workload_validation           | Integration  | 58       | PASS   | [SUCCESS] All TSK-08 Functional Workload Tests Passed!
15  | tb_parallel_pe_operand_delivery  | Integration  | 226      | PASS   | [SUCCESS] All TSK-09 Parallel PE Operand Delivery Tests Passed with Zero Failures!
--------------------------------------------------------------------------------------------------------------
GRAND TOTAL ACROSS ALL 15 SUITES: 1026 Checks Evaluated | 1026 Passed | 0 Failed | ALL PASS
==============================================================================================================
REGRESSION EXECUTION SUMMARY:
  Total Testbenches : 15
  Passed Testbenches: 15
  Failed Testbenches: 0
  Checks Evaluated  : 1026
  Checks Passed     : 1026
  Checks Failed     : 0

FINAL STATUS: REGRESSION PASSED (Exit Code 0)
==============================================================================================================
```

---

## 7. Known Limitations and Pre-Synthesis Roadmap

Before advancing to physical synthesis (ASIC/FPGA) and physical power sign-off:

1. **Fixed Memory Layout Stride:** The current feeder assumes activations and weights are packed with a fixed stride of 10 words per K-step. Arbitrary tensor layouts will require a programmable address generator stride register.
2. **Read/Write Port Contention:** When DMA writes to Buffer B while the PE array reads from Buffer A, bank contention is structurally impossible because buffers reside in non-overlapping address ranges. However, if unconstrained DMA access to an active buffer occurs, write-port priority must be arbitrated to prevent read corruption.
3. **Synthesis & Timing Constraints (SDC):** SDC files defining clock uncertainties, input/output delays, and multi-cycle paths for the 40-bit saturating adder tree must be ratified.
4. **Physical Power Sign-off:** Measured simulation cycles confirm a $64\times$ throughput enhancement and zero wasted PE activity in 16/32-PE modes. True energy savings (pJ/MAC) must be obtained from gate-level netlists with SAIF/VCD switching activity rather than behavioral toggle counts.

---

## 8. Formal Sign-Off

* **RTL Baseline Integrity:** 100% Preserved. 0 baseline lines modified.
* **Parallel Computation:** Verified across 4 rows $\times$ 16 columns (64 distinct outputs).
* **Memory Subsystem:** Verified 0 bank conflicts across 8 SRAM read channels.
* **Functional Correctness:** 15/15 testbench suites passing (1,026 / 1,026 checks).
* **Regression Runner:** Automated exit-code verification passing.

**Sign-off Status:** **APPROVED & COMPLETE**

