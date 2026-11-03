# TSK-12D-C: Mode-Dependent Operand Fetching and Feeder Gating Final Report

**Project:** Neural_Acc — Phase 2 RTL Microarchitecture and Verification  
**Repository:** `E:\MTech\LanChain\MTP`  
**RTL Directory:** `phase2_step1_microarchitecture_and_rtl`  
**Date:** November 2, 2026  
**Status:** Completed & Fully Verified  
**Audit Verdict:** `PASS_WITH_LIMITATIONS`

---

## 1. Executive Summary

This report documents the microarchitectural analysis, RTL implementation, and experimental verification of **TSK-12D-C: Mode-Dependent Operand Fetching and Feeder Gating** for the Neural_Acc neural accelerator.

Prior to this work, the datapath compute feeder fetched all 8 weight words (16 columns) from the multi-bank SRAM subsystem during every reduction step ($K$-step), regardless of whether the accelerator was operating in 16-PE mode (4 active columns), 32-PE mode (8 active columns), or 64-PE mode (16 active columns). This resulted in substantial unnecessary SRAM read port activations and memory traffic for sub-64-PE configurations.

### Key Results
1. **SRAM Read Transaction Reduction:**
   - **16-PE Mode (4 active columns):** SRAM read requests reduced from **10 to 4 words per $K$-step**, achieving a **60.0% reduction** in read memory accesses.
   - **32-PE Mode (8 active columns):** SRAM read requests reduced from **10 to 6 words per $K$-step**, achieving a **40.0% reduction** in read memory accesses.
   - **64-PE Mode (16 active columns):** SRAM read requests remain exactly **10 words per $K$-step** (0.0% change, maintaining 100% backward compatibility).
2. **Compute Latency Invariance:**
   - Detailed microarchitectural audit proved mathematically and empirically that compute latency cannot be reduced below $3K + 1$ cycles ($T_{\text{comp}} = 4$ for $K=1$, $7$ for $K=2$, $13$ for $K=4$, $25$ for $K=8$) due to a **structural physical SRAM bank conflict** between Weight Word 0 and Activation Word 8.
3. **Cumulative Memory Access Reduction (TSK-12D-B + TSK-12D-C):**
   - Combining mode-dependent OFMAP drain writes (TSK-12D-B) with mode-dependent operand reads (TSK-12D-C) reduces total SRAM accesses for a typical $K=4$ layer from **168 to 48 transactions (-71.43%)** in 16-PE mode, and from **168 to 88 transactions (-47.62%)** in 32-PE mode.
4. **Zero RTL Baseline Regressions:**
   - All five protected baseline RTL files remain bit-exact (0 lines modified).
   - Full 19-suite regression executed with **11,712 / 11,712 checks passing (100% PASS)** with Exit Code 0.

---

## 2. Phase 1 & 2: Architectural Audit and Conflict Proof

Before modifying RTL, an exhaustive audit was performed (documented in `TSK12D_FEEDER_ARCHITECTURE_AUDIT.md`).

### 2.1 Feeder FSM and Memory Mapping
The datapath compute feeder (`datapath_compute_feeder.sv`) fetches operands using a 10-word frame per $K$-step:
- **Words 0..7 (Weights):** 8 words $\times$ 2 weights/word = 16 weights (Columns 0..15).
- **Words 8..9 (Activations):** 2 words $\times$ 2 activations/word = 4 activations (Rows 0..3).

The physical SRAM addresses map across 8 banks via interleaved low-order address bits:
$$\text{Bank ID} = \text{Address}[2:0] = (\text{active\_base} + 10K + \text{offset}) \pmod 8$$
Assuming $\text{active\_base} \equiv 0 \pmod 8$:
- **Word 0 (Weight cols 0..1):** $\text{Bank } (10K + 0) \pmod 8 = (2K) \pmod 8$
- **Word 1 (Weight cols 2..3):** $\text{Bank } (10K + 1) \pmod 8 = (2K + 1) \pmod 8$
- **Word 8 (Activation rows 0..1):** $\text{Bank } (10K + 8) \pmod 8 = (2K + 8) \pmod 8 = (2K) \pmod 8$
- **Word 9 (Activation rows 2..3):** $\text{Bank } (10K + 9) \pmod 8 = (2K + 9) \pmod 8 = (2K + 1) \pmod 8$

### 2.2 Mathematical Proof of Compute Latency Invariance
A proposed optimization was to coalesce Weight Fetch (Phase A) and Activation Fetch (Phase B) into a single cycle for 16-PE mode (since only 4 total words are needed). 

However:
$$\text{Bank}(\text{Word 0}) = (2K) \pmod 8 = \text{Bank}(\text{Word 8})$$
$$\text{Bank}(\text{Word 1}) = (2K + 1) \pmod 8 = \text{Bank}(\text{Word 9})$$

Both Weight Word 0 and Activation Word 8 reside in the **exact same physical SRAM bank**, and Weight Word 1 and Activation Word 9 reside in the exact same physical SRAM bank. Because each hybrid SRAM bank contains only **one read port**, attempting to read weights and activations in the same cycle triggers a **structural read-read bank conflict stall**.

Consequently:
- Phase A (`ST_PAR_REQ_W`) and Phase B (`ST_PAR_REQ_A`) **must remain strictly sequential**.
- Compute cycle latency ($T_{\text{comp}}$) is **fundamentally invariant**:
  $$T_{\text{comp}}(K) = 3K + 1 \text{ cycles}$$
  $$\begin{cases} K=1 \implies 4 \text{ cycles} \\ K=2 \implies 7 \text{ cycles} \\ K=4 \implies 13 \text{ cycles} \\ K=8 \implies 25 \text{ cycles} \end{cases}$$

---

## 3. RTL Implementation Details

### 3.1 Modified Files
1. `phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv`
   - Added configuration input port: `input logic [1:0] cfg_mode` with safe fallback logic.
   - Added registered mode latch: `cfg_mode_q` sampled at `compute_start`.
   - Continuous wire generation (`gen_wt_slice`) for lower and upper 16-bit weight slices (`sram_wt_lo`, `sram_wt_hi`) outside `always_comb` to circumvent simulator part-select synthesis limitations.
   - Mode-gated `sram_rd_req_bus` during `ST_PAR_REQ_W`:
     - **16-PE (`2'b00`):** `sram_rd_req_bus = 8'b0000_0011;` (Ports 2..7 gated off). Waits on `ready_16`.
     - **32-PE (`2'b01`):** `sram_rd_req_bus = 8'b0000_1111;` (Ports 4..7 gated off). Waits on `ready_32`.
     - **64-PE (`2'b10`):** `sram_rd_req_bus = 8'b1111_1111;` (All 8 ports requested). Waits on `ready_64`.
   - Mode-gated weight latching during `ST_PAR_REQ_A`:
     - **16-PE:** Latches Columns 0..3 from Ports 0..1 on `rvalid_16`; clamps Columns 4..15 strictly to zero.
     - **32-PE:** Latches Columns 0..7 from Ports 0..3 on `rvalid_32`; clamps Columns 8..15 strictly to zero.
     - **64-PE:** Latches Columns 0..15 from Ports 0..7 on `rvalid_64`.
2. `phase2_step1_microarchitecture_and_rtl/neural_acc_integrated_top.sv`
   - Connected `cfg_mode` of `u_feeder` to top-level `pe_array_cfg_mode`.

### 3.2 Baseline RTL Integrity
The five protected baseline RTL files were verified with `git diff`:
- `accelerator_core_top.sv`: 0 lines modified.
- `mac_unit_40b.sv`: 0 lines modified.
- `k_progress_tracker.sv`: 0 lines modified.
- `slot_control_unit.sv`: 0 lines modified.
- `hybrid_sram_bank.sv`: 0 lines modified.

Zero Git commits were created.

---

## 4. Experimental Evaluation & Verification

### 4.1 SRAM Read Requests & Transactions
Comparison of SRAM read requests before and after TSK-12D-C optimization:

| Mode | Active PEs | $K$-Steps | Baseline Reads | Optimized Reads | Read Reduction |
| :---: | :---: | :---: | :---: | :---: | :---: |
| **16-PE** | 16 | $K=1$ | 10 | **4** | **-60.0%** |
| **16-PE** | 16 | $K=2$ | 20 | **8** | **-60.0%** |
| **16-PE** | 16 | $K=4$ | 40 | **16** | **-60.0%** |
| **16-PE** | 16 | $K=8$ | 80 | **32** | **-60.0%** |
| **32-PE** | 32 | $K=1$ | 10 | **6** | **-40.0%** |
| **32-PE** | 32 | $K=2$ | 20 | **12** | **-40.0%** |
| **32-PE** | 32 | $K=4$ | 40 | **24** | **-40.0%** |
| **32-PE** | 32 | $K=8$ | 80 | **48** | **-40.0%** |
| **64-PE** | 64 | $K=1$ | 10 | **10** | **0.0%** |
| **64-PE** | 64 | $K=2$ | 20 | **20** | **0.0%** |
| **64-PE** | 64 | $K=4$ | 40 | **40** | **0.0%** |
| **64-PE** | 64 | $K=8$ | 80 | **80** | **0.0%** |

### 4.2 Latency and Execution Cycle Breakdown
Comparison of cycle counts verifying compute latency invariance:

| Workload & Config | Mode | $K$ | Launch Latency ($T_{\text{lnch}}$) | Compute Cycles ($T_{\text{cmp}}$) | Drain Cycles ($T_{\text{drn}}$) | Total Cycles ($T_{\text{tot}}$) | Status |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL-01 CFG_A** | 16-PE | 1 | 3 | **4** | 33 | 43 | PASS |
| **WL-01 CFG_B** | 32-PE | 1 | 3 | **4** | 65 | 75 | PASS |
| **WL-01 CFG_C** | 64-PE | 1 | 3 | **4** | 129 | 139 | PASS |
| **WL-02 CFG_A** | 16-PE | 2 | 3 | **7** | 33 | 46 | PASS |
| **WL-02 CFG_B** | 32-PE | 2 | 3 | **7** | 65 | 78 | PASS |
| **WL-02 CFG_C** | 64-PE | 2 | 3 | **7** | 129 | 142 | PASS |
| **WL-03 CFG_A** | 16-PE | 4 | 3 | **13** | 33 | 52 | PASS |
| **WL-03 CFG_B** | 32-PE | 4 | 3 | **13** | 65 | 84 | PASS |
| **WL-03 CFG_C** | 64-PE | 4 | 3 | **13** | 129 | 148 | PASS |
| **WL-04 CFG_A** | 16-PE | 8 | 3 | **25** | 33 | 64 | PASS |
| **WL-04 CFG_B** | 32-PE | 8 | 3 | **25** | 65 | 96 | PASS |
| **WL-04 CFG_C** | 64-PE | 8 | 3 | **25** | 129 | 160 | PASS |

### 4.3 Combined Memory Access Reduction (TSK-12D-B + TSK-12D-C)
Total SRAM transactions (Feeder Reads + OFMAP Drain Writes) for a representative $K=4$ reduction:

| Optimization Level | 16-PE Mode (Reads + Writes = Total) | 32-PE Mode (Reads + Writes = Total) | 64-PE Mode (Reads + Writes = Total) |
| :--- | :---: | :---: | :---: |
| **Pre-12D Baseline** | $40 + 128 = 168$ | $40 + 128 = 168$ | $40 + 128 = 168$ |
| **TSK-12D-B Only (Drain)** | $40 + 32 = 72$ (-57.1%) | $40 + 64 = 104$ (-38.1%) | $40 + 128 = 168$ (0.0%) |
| **TSK-12D-B + C (Combined)** | **$16 + 32 = 48$ (-71.43%)** | **$24 + 64 = 88$ (-47.62%)** | **$40 + 128 = 168$ (0.0%)** |

### 4.4 Contention and Error Handling
- **WL-08 & WL-10 (Memory Backpressure & Contention):** Concurrent DMA write requests to Bank 0/1 correctly introduced a 1-cycle stall (`Stl=1`), with SRAM write and read addresses holding stable without operand corruption or missing pulses.
- **WL-11 (Invalid OFMAP Base Address & Reset-Free Recovery):** An illegal base address ($10,350$) immediately triggered `ofmap_error_flag` and `sequencer_error_flag` with error code `ERR_OFMAP_DRAIN` (4'd5); `layer_done_pulse` remained strictly suppressed, zero writes were accepted, and pulsing `sequencer_error_clear` successfully restored `cmd_ready` allowing a subsequent valid layer command to execute to completion without hardware reset.

---

## 5. Full 19-Suite Regression Results

The regression runner (`phase2_step1_microarchitecture_and_rtl/run_regression.py`) was executed across all 19 testbenches.

```
#   | Testbench Suite                  | Category     | Checks   | Status | Summary Output
--------------------------------------------------------------------------------------------------------------
1   | tb_accelerator_core              | Baseline     | 4        | PASS   | [SUCCESS] All Phase 2 Step 1 RTL Tests Completed Successfully!
2   | tb_mac_saturation                | Baseline     | 11       | PASS   | [SUCCESS] All MAC Saturation & Clear Tests Completed Successfully!
3   | tb_k_progress_tracker            | Baseline     | 4        | PASS   | [SUCCESS] All K-Progress Tracker Tests Completed Successfully!
4   | tb_hybrid_sram_bank              | Baseline     | 13       | PASS   | [SUCCESS] All SRAM Focused Tests Completed Successfully!
5   | tb_drain_backpressure            | Baseline     | 15       | PASS   | [SUCCESS] All Drain & Backpressure Tests Completed Successfully!
6   | tb_acceptance_integrated         | Baseline     | 29       | PASS   | [SUCCESS] All Executable RTL Acceptance Tests Passed with Zero Failures!
7   | tb_pe_array_40b                  | Subsystem    | 28       | PASS   | [SUCCESS] All TSK-01 Multi-PE Array RTL Tests Passed!
8   | tb_adaptive_pe_controller        | Subsystem    | 53       | PASS   | [SUCCESS] All TSK-02 Adaptive PE Controller RTL Tests Passed!
9   | tb_multibank_sram_subsystem      | Subsystem    | 137      | PASS   | [RESULT] ALL TESTS PASSED SUCCESSFULLY!
10  | tb_ping_pong_buffer_controller   | Subsystem    | 117      | PASS   | [SUCCESS] All TSK-04 Ping-Pong Buffer Controller Tests Passed!
11  | tb_layer_command_sequencer       | Subsystem    | 110      | PASS   | [SUCCESS] All TSK-05 Layer Command Sequencer Tests Passed!
12  | tb_dma_controller                | Subsystem    | 87       | PASS   | [SUCCESS] All TSK-06 DMA Controller Tests Passed!
13  | tb_ofmap_drain_controller        | Subsystem    | 732      | PASS   | [SUCCESS] All TSK-11 Phase 2A OFMAP Drain Controller Tests Passed with Zero Failures!
14  | tb_neural_acc_integrated_top     | Integration  | 132      | PASS   | [SUCCESS] All TSK-07 System Integration Tests Passed!
15  | tb_workload_validation           | Integration  | 58       | PASS   | [SUCCESS] All TSK-08 Functional Workload Tests Passed!
16  | tb_parallel_pe_operand_delivery  | Integration  | 226      | PASS   | [SUCCESS] All TSK-09 Parallel PE Operand Delivery Tests Passed with Zero Failures!
17  | tb_tsk10_cnn_workload            | Integration  | 667      | PASS   | [SUCCESS] All TSK-10 Functional CNN Workload Tests Passed with Zero Failures!
18  | tb_tsk11_ofmap_integration       | Integration  | 3443     | PASS   | [SUCCESS] All TSK-11 OFMAP Integration Tests Passed with Zero Failures!
19  | tb_tsk12_adaptive_experiment     | Integration  | 5846     | PASS   | [RESULT: SUCCESS] All TSK-12D-C experiments passed with zero defects!
--------------------------------------------------------------------------------------------------------------
GRAND TOTAL ACROSS ALL 19 SUITES: 11712 Checks Evaluated | 11712 Passed | 0 Failed | ALL PASS
==============================================================================================================
REGRESSION EXECUTION SUMMARY:
  Total Testbenches : 19
  Passed Testbenches: 19
  Failed Testbenches: 0
  Checks Evaluated  : 11712
  Checks Passed     : 11712
  Checks Failed     : 0

FINAL STATUS: REGRESSION PASSED (Exit Code 0)
==============================================================================================================
```

---

## 6. Limitations & Architectural Constraints

1. **Fixed 10-Word SRAM Frame Stride:**
   Although inactive weight reads are gated off, each $K$-step frame still spans 10 words in SRAM address space (`active_base + K * 10`). This spacing is required by DMA ingestion layout and ping-pong buffering contracts. Packing weights contiguously without stride would require complex runtime dynamic address generation in both the DMA engine and feeder.
2. **Compute Latency Invariance:**
   Feeder gating achieves memory transaction reduction, but does **not** reduce compute cycle latency ($T_{\text{comp}}$ remains $3K + 1$) due to the physical single-read-port limitation of each SRAM bank.
3. **Asymmetric Bandwidth:**
   The feeder can read up to 8 words per cycle during parallel vector fetch, while the OFMAP drain writes at 1 word per cycle. The accelerator remains drain-bandwidth bound for small $K$ reductions.

---

## 7. Physical Power & Energy Disclaimer

> [!IMPORTANT]
> **Functional Simulation Boundary Disclaimer:**
> The transaction reductions reported in this study (e.g. -60% SRAM read requests, -71.43% total SRAM accesses) are derived from cycle-accurate RTL functional simulation. Functional simulation directly confirms the elimination of read request strobes and port activations, which in CMOS SRAM macros eliminates wordline charging, bitline precharge/discharge, and sense amplifier activation on inactive banks.
>
> However, functional simulation **does not measure physical power, energy, or area**. Exact power and energy savings can only be quantified through standard cell synthesis, physical place-and-route (P&R), parasitic extraction (SPEF), and gate-level power simulation driven by switching activity vector files (VCD or SAIF) under characterized PVT operating conditions.

---

## 8. Artifact and Dataset Preservation

The new 24-column dataset has been generated and validated:
- `phase2_step1_microarchitecture_and_rtl/tsk12d_feeder_optimization_results.csv`
- `tsk12d_feeder_optimization_results.csv` (repository root)

All 3 historical datasets remain untouched and bit-exact:
- `tsk12_experiment_results.csv`
- `tsk12d_instrumentation_results.csv`
- `tsk12d_drain_optimization_results.csv`

---

## 9. Final Sign-Off & Verdict

| Verification Item | Requirement | Actual Status | Verdict |
| :--- | :--- | :--- | :---: |
| **16-PE Mode Reads** | Fetch only 4 words per $K$-step | Exactly 4 words verified across all runs | PASS |
| **32-PE Mode Reads** | Fetch only 6 words per $K$-step | Exactly 6 words verified across all runs | PASS |
| **64-PE Mode Reads** | Fetch all 10 words per $K$-step | Exactly 10 words verified across all runs | PASS |
| **Compute Latency** | Verify structural bank conflict proof | Invariance ($3K+1$) verified bit-exact | PASS |
| **Data Integrity** | Bit-exact 40-bit accumulation | Zero arithmetic mismatches | PASS |
| **Backpressure Safety** | Handle concurrent port contention | Stable address/data, 0 loss | PASS |
| **Error Recovery** | Recovery without hardware reset | Verified on invalid base address | PASS |
| **Baseline Preservation** | Zero modifications to 5 protected files | 0 lines modified | PASS |
| **Regression Suite** | 100% pass across all 19 suites | 11,712 / 11,712 checks passed | PASS |

**FINAL AUDIT VERDICT: `PASS_WITH_LIMITATIONS`**  
*(Limitations: Compute latency invariance due to single-port SRAM structural conflicts; fixed 10-word frame memory layout contract).*

