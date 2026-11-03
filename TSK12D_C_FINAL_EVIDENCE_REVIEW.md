# TSK-12D-C: Final Evidence Review and Technical Audit
## Mode-Dependent Operand Fetching and Feeder Gating

**Project:** Neural_Acc — Phase 2 RTL Microarchitecture and Verification  
**Repository:** `E:\MTech\LanChain\MTP`  
**RTL Directory:** `phase2_step1_microarchitecture_and_rtl`  
**Date:** November 2, 2026  
**Auditor:** Antigravity Verification Agent  
**Review Type:** Final Evidence Review & Microarchitectural Verification  
**Audit Verdict:** **`PASS_WITH_LIMITATIONS`**  
*(Limitations: Compute cycle latency is structurally invariant due to single-port physical SRAM bank collisions; fixed 10-word frame memory layout contract is preserved; system-level WL-06 represents high-magnitude arithmetic rather than a true saturation-boundary test).*

---

## 1. Executive Summary & Audit Verdict

This review performs a strict, independent evidence review of **TSK-12D-C (Mode-Dependent Operand Fetching and Feeder Gating)** without modifying functional RTL, testbenches, historical CSV datasets, reference models, or protected baseline files.

### Key Audit Findings:
1. **Saturation Evidence (Task 1):**
   - In [`tb_mac_saturation.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_mac_saturation.sv) (Suite 2) and [`tb_workload_validation.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_workload_validation.sv) (Suite 15), **true 40-bit positive and negative saturation boundaries ($+549,755,813,887$ and $-549,755,813,888$) are genuinely reached and verified** via multi-hundred-cycle accumulation loops ($K=515$ and $K=16,777$).
   - In [`tb_tsk12_adaptive_experiment.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_tsk12_adaptive_experiment.sv) (Suite 19), **WORKLOAD 6 ($K=4$) reaches accumulator values of $\pm 3,600,000,000$, which is only $0.65\%$ of the 40-bit threshold**. WL-06 is therefore accurately classified as a **high-magnitude signed arithmetic test**, not a saturation-boundary test.
2. **SRAM Transaction Accounting (Task 2):**
   - The hardware event instrumentation rigorously discriminates between request cycles, accepted transactions (`req && ready`), consumed responses, and contention stalls.
   - During contention workloads (WL-08, WL-10), stalled requests held their signals stable and did **not** increment accepted transaction counters.
3. **Reported Savings Verification (Task 3):**
   - The reported $K=4$ transaction counts match the simulation event counters and CSV rows bit-for-bit:
     - **16-PE Mode:** 16 operand reads + 32 OFMAP writes = **48 total accesses (-71.43%)**.
     - **32-PE Mode:** 24 operand reads + 64 OFMAP writes = **88 total accesses (-47.62%)**.
     - **64-PE Mode:** 40 operand reads + 128 OFMAP writes = **168 total accesses (0.0% change, baseline invariant)**.
4. **Baseline & Regression Integrity (Task 4):**
   - All 5 protected baseline RTL files remain bit-exact (0 lines modified).
   - Full 19-suite regression executed with **11,712 / 11,712 checks passing (100% PASS)** with Exit Code 0. Zero Git commits created.

---

## 2. Task 1: Saturation Evidence Review

The repository contains three primary testbenches evaluating signed 40-bit accumulation and saturation behavior. Each case was independently audited against mathematical ground truth.

### 2.1 40-Bit Saturation Arithmetic Bounds
In the 40-bit saturating datapath ([`mac_unit_40b.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv#L17-L18)):
$$\text{SAT\_MAX\_POS} = +2^{39} - 1 = +549,755,813,887 \quad (\text{40'sh7F\_FFFF\_FFFF})$$
$$\text{SAT\_MAX\_NEG} = -2^{39} = -549,755,813,888 \quad (-\text{40'sh80\_0000\_0000})$$
A single product of two signed 16-bit integers has maximum magnitude:
$$\text{Max Pos Prod} = (+32,767) \times (+32,767) = +1,073,676,289$$
$$\text{Max Neg Prod} = (-32,768) \times (+32,767) = -1,073,709,056$$
The minimum number of accumulation steps ($K_{\text{min}}$) required to mathematically reach 40-bit saturation from zero is:
$$K_{\text{min}} = \left\lceil \frac{549,755,813,888}{1,073,709,056} \right\rceil = \mathbf{513 \text{ steps}}$$

### 2.2 Comprehensive Saturation Audit Table

| Testbench & Test Case | Operands ($A, W$) | Steps ($K$) | Mathematical Unsaturated Accumulator Result | Signed 40-bit Bounds [Min, Max] | Expected Saturated Result | Actual Simulated Result | Boundary Reached? | Classification |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **Suite 2: `tb_mac_saturation.sv`**<br>`MAC-SAT-03`<br>(Exact Pos Boundary) | $A_1 = +32,767, W_1 = +1,000$<br>$A_2 = +23,854, W_2 = +1,000$<br>$A_3 = +887, W_3 = +1$ | $16,777$<br>$1$<br>$1$ | $16,777 \times 32,767,000 + 23,854,000 + 887$<br>$= \mathbf{+549,755,813,887}$ | $[-2^{39}, +2^{39}-1]$ | $+549,755,813,887$<br>(`sticky_sat = 0`) | $+549,755,813,887$<br>(`sticky_sat = 0`) | **YES**<br>(Exact boundary) | **True Saturation Boundary Test** |
| **Suite 2: `tb_mac_saturation.sv`**<br>`MAC-SAT-04`<br>(Positive Overflow) | Prior accum = $+549,755,813,887$<br>$A = +1, W = +1$ | $+1$ | $+549,755,813,888$<br>($+1$ overflow) | $[-2^{39}, +2^{39}-1]$ | $+549,755,813,887$<br>(`sticky_sat = 1`) | $+549,755,813,887$<br>(`sticky_sat = 1`) | **YES**<br>(Clamped overflow) | **True Saturation Boundary Test** |
| **Suite 2: `tb_mac_saturation.sv`**<br>`MAC-SAT-08`<br>(Exact Neg Boundary) | $A_1 = -32,767, W_1 = +1,000$<br>$A_2 = -23,854, W_2 = +1,000$<br>$A_3 = -888, W_3 = +1$ | $16,777$<br>$1$<br>$1$ | $16,777 \times (-32,767,000) - 23,854,000 - 888$<br>$= \mathbf{-549,755,813,888}$ | $[-2^{39}, +2^{39}-1]$ | $-549,755,813,888$<br>(`sticky_sat = 0`) | $-549,755,813,888$<br>(`sticky_sat = 0`) | **YES**<br>(Exact boundary) | **True Saturation Boundary Test** |
| **Suite 2: `tb_mac_saturation.sv`**<br>`MAC-SAT-09`<br>(Negative Overflow) | Prior accum = $-549,755,813,888$<br>$A = -1, W = +1$ | $+1$ | $-549,755,813,889$<br>($-1$ underflow) | $[-2^{39}, +2^{39}-1]$ | $-549,755,813,888$<br>(`sticky_sat = 1`) | $-549,755,813,888$<br>(`sticky_sat = 1`) | **YES**<br>(Clamped underflow) | **True Saturation Boundary Test** |
| **Suite 15: `tb_workload_validation.sv`**<br>`CAT6.1 / CAT6.2`<br>(Array Pos Overflow) | $A = +32,767, W = +32,767$<br>(Across all 64 PEs) | $515$ | $515 \times (+1,073,676,289)$<br>$= \mathbf{+552,943,288,835}$ | $[-2^{39}, +2^{39}-1]$ | $+549,755,813,887$<br>(`sticky_sat = 1`) | $+549,755,813,887$<br>(`sticky_sat = 1`) | **YES**<br>(Clamped overflow) | **True Saturation Boundary Test** |
| **Suite 15: `tb_workload_validation.sv`**<br>`CAT6.5 / CAT6.6`<br>(Array Neg Overflow) | $A = -32,768, W = +32,767$<br>(Across all 64 PEs) | $515$ | $515 \times (-1,073,709,056)$<br>$= \mathbf{-552,960,163,840}$ | $[-2^{39}, +2^{39}-1]$ | $-549,755,813,888$<br>(`sticky_sat = 1`) | $-549,755,813,888$<br>(`sticky_sat = 1`) | **YES**<br>(Clamped underflow) | **True Saturation Boundary Test** |
| **Suite 19: `tb_tsk12_adaptive_experiment.sv`**<br>`WL-06: CFG_A (16-PE)`<br>Rows 0, 1 | $A = +30,000, W = +30,000$ | $4$ | $4 \times (+900,000,000)$<br>$= \mathbf{+3,600,000,000}$ | $[-2^{39}, +2^{39}-1]$ | $+3,600,000,000$<br>(`sticky_sat = 0`) | $+3,600,000,000$<br>(`sticky_sat = 0`) | **NO**<br>($0.65\%$ of threshold) | **High-Magnitude Arithmetic Test** |
| **Suite 19: `tb_tsk12_adaptive_experiment.sv`**<br>`WL-06: CFG_A (16-PE)`<br>Rows 2, 3 | $A = -30,000, W = +30,000$ | $4$ | $4 \times (-900,000,000)$<br>$= \mathbf{-3,600,000,000}$ | $[-2^{39}, +2^{39}-1]$ | $-3,600,000,000$<br>(`sticky_sat = 0`) | $-3,600,000,000$<br>(`sticky_sat = 0`) | **NO**<br>($0.65\%$ of threshold) | **High-Magnitude Arithmetic Test** |
| **Suite 19: `tb_tsk12_adaptive_experiment.sv`**<br>`WL-06: CFG_B (32-PE)`<br>Rows 0, 1 / Rows 2, 3 | $A = \pm 30,000, W = +30,000$ | $4$ | $\mathbf{\pm 3,600,000,000}$ | $[-2^{39}, +2^{39}-1]$ | $\pm 3,600,000,000$<br>(`sticky_sat = 0`) | $\pm 3,600,000,000$<br>(`sticky_sat = 0`) | **NO**<br>($0.65\%$ of threshold) | **High-Magnitude Arithmetic Test** |
| **Suite 19: `tb_tsk12_adaptive_experiment.sv`**<br>`WL-06: CFG_C (64-PE)`<br>Rows 0, 1 / Rows 2, 3 | $A = \pm 30,000, W = +30,000$ | $4$ | $\mathbf{\pm 3,600,000,000}$ | $[-2^{39}, +2^{39}-1]$ | $\pm 3,600,000,000$<br>(`sticky_sat = 0`) | $\pm 3,600,000,000$<br>(`sticky_sat = 0`) | **NO**<br>($0.65\%$ of threshold) | **High-Magnitude Arithmetic Test** |

### 2.3 Transparent Audit Conclusion on Saturation
- **Genuine Saturation Verification:** The hardware 40-bit saturating accumulation logic in [`mac_unit_40b.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv) and [`pe_array_40b.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/pe_array_40b.sv) is thoroughly, genuinely proven to saturate and clamp at both exact positive ($+549,755,813,887$) and exact negative ($-549,755,813,888$) limits in Suite 2 (`tb_mac_saturation.sv`) and Suite 15 (`tb_workload_validation.sv`).
- **Classification of WL-06:** In the experimental benchmark suite (`tb_tsk12_adaptive_experiment.sv`), WL-06 is described as "Saturation Stress (Extreme Pos/Neg Boundaries)", but its reduction length of $K=4$ mathematically restricts the accumulator to $\pm 3.6 \times 10^9$. Because $3.6 \times 10^9 \ll 5.49 \times 10^{11}$, the saturation boundaries are **not** reached during WL-06. WL-06 is strictly a **high-magnitude signed arithmetic test**, not a saturation-boundary test.

---

## 3. Task 2: SRAM Transaction Accounting

### 3.1 Hardware Event Counter Definitions
The testbench event counters in [`tb_tsk12_adaptive_experiment.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_tsk12_adaptive_experiment.sv#L340-L401) sample actual interface handshakes synchronously at every positive clock edge during the active measurement window (`meas_run_active == 1`):

1. **Read Request Cycles:**
   Cycles where the feeder asserts at least one read port:
   $$\text{Read Request Cycles} = \sum_{\text{cycles}} (\text{feeder\_busy} \ \& \ (|\text{sram\_rd\_req\_bus} \ne 0))$$
   For every $K$-step, this equals exactly 2 cycles (Cycle 1 in `ST_PAR_REQ_W`, Cycle 2 in `ST_PAR_REQ_A`).
2. **Accepted Read Transactions (`sram_rd_accepted_count`):**
   Sampled via lines 384-386:
   $$\text{rd\_accepted\_step} = \sum_{b=0}^{7} (\text{dut.sram\_rd\_req\_bus}[b] \ \& \ \text{dut.sram\_rd\_ready\_bus}[b])$$
   Strictly counts words that are acknowledged by the SRAM read arbiter in that clock cycle.
3. **Read Responses Consumed:**
   In Phase B (`ST_PAR_REQ_A`), weight words returning on `rvalid` are latched into `weight_stage_q`.
   In Phase C (`ST_PAR_COMPUTE`), activation words returning on `act_rvalid` are consumed by `act_data_row`.
   Responses consumed equal accepted transactions.
4. **Write Request Cycles (`sram_wr_reqs_count`):**
   Sampled via lines 394-396:
   $$\text{sram\_wr\_reqs\_count} = \sum_{\text{cycles}} (\text{dut.sram\_wr\_req\_bus}[1] == 1)$$
   Port 1 is the dedicated OFMAP drain write port to the multibank SRAM subsystem.
5. **Accepted Write Transactions (`sram_wr_accepted_count`):**
   Sampled via lines 399-401:
   $$\text{sram\_wr\_accepted\_count} = \sum_{\text{cycles}} (\text{dut.sram\_wr\_req\_bus}[1] \ \& \ \text{dut.sram\_wr\_ready\_bus}[1])$$
   Counts words successfully written into SRAM Buffer A.
6. **Stalled Transactions (`t_drain_stall_cycles`):**
   Sampled via lines 346-348:
   $$\text{t\_drain\_stall\_cycles} = \sum_{\text{cycles}} (\text{dut.sram\_wr\_req\_bus}[1] \ \& \ !\text{dut.sram\_wr\_ready\_bus}[1])$$
   $$\text{sram\_wr\_reqs\_count} = \text{sram\_wr\_accepted\_count} + \text{t\_drain\_stall\_cycles}$$

### 3.2 Contention Trace Analysis (WL-08, WL-10)
In workloads with contention, the testbench launches a concurrent DMA write to Bank 0 (`wr_addr = 0`, Port 0) during OFMAP drain write execution (Port 1).

#### Cycle-by-Cycle Waveform Trace:
```
Cycle  Event / State           wr_req[0] wr_req[1] Bank 0 Arbiter Granted Port wr_ready[0] wr_ready[1] wr_accepted[1] word_idx_q
-------------------------------------------------------------------------------------------------------------------------------
T0     OFMAP Drain Word 0          0         1     Idle -> Port 1     Port 1        -          1              1         0 -> 1
T1     OFMAP Drain Word 1          0         1     Idle -> Port 1     Port 1        -          1              1         1 -> 2
...    ...
T8     Concurrent DMA launched     1         1     Conflict!          Port 0        1          0              0           8
       (Port 0 & 1 target Bank 0)                  (Port 0 wins)                                              (Stalled) (Held)
T9     DMA completes Port 0        0         1     Port 1 Granted     Port 1        -          1              1         8 -> 9
T10    OFMAP Drain Word 9          0         1     Port 1 Granted     Port 1        -          1              1         9 -> 10
```

#### Verification of Contention Handling:
- At cycle `T8`, `multibank_sram_subsystem.sv:146` grants Port 0 because $0 < 1$.
- `wr_ready[1]` is deasserted to `0`; `wr_conflict_stall[1]` is asserted to `1`.
- In `ofmap_drain_controller.sv:180-184`, `word_idx_q` and `words_cnt_q` hold stable because `sram_wr_ready == 0`.
- In `tb_tsk12_adaptive_experiment.sv`, `sram_wr_reqs_count` increments by 1, but `sram_wr_accepted_count` **does not increment**.
- `bank_conflict_flags[0]` asserts, incrementing `bank_conflict_cycles`.
- When Port 0 releases at `T9`, Port 1 is accepted without data corruption, omission, or duplication.
- **Empirical CSV Values:**
  - WL-08 (STALL, 64-PE): `sram_wr_reqs = 129`, `sram_wr_accepted = 128`, `stall_cycles = 1`, `bank_conflict_cycles = 1`.
  - WL-10 (ST_16, 16-PE): `sram_wr_reqs = 33`, `sram_wr_accepted = 32`, `stall_cycles = 1`, `bank_conflict_cycles = 1`.
  - WL-10 (ST_32, 32-PE): `sram_wr_reqs = 65`, `sram_wr_accepted = 64`, `stall_cycles = 1`, `bank_conflict_cycles = 1`.

---

## 4. Task 3: Verification of Reported Savings

### 4.1 Theoretical Recalculation ($K=4$)

$$\text{Operand Reads}(K=4) = 4 \times \text{reads\_per\_K}$$
$$\text{OFMAP Drain Writes} = \text{active\_PEs} \times 2$$
$$\text{Total SRAM Accesses} = \text{Operand Reads} + \text{OFMAP Drain Writes}$$

| Architectural Configuration | Operand Reads ($K=4$) | OFMAP Writes ($K=4$) | Total SRAM Accesses | Read Savings vs Baseline | Total Access Savings vs Baseline |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Baseline Architecture** | $4 \times 10 = 40$ | $64 \times 2 = 128$ | **168** | 0.0% (Ref) | 0.0% (Ref) |
| **TSK-12D-B Only (Drain)** | $4 \times 10 = 40$ | $16 \times 2 = 32$ | **72** | 0.0% | -57.14% |
| **TSK-12D-B + C (16-PE Mode)** | $4 \times 4 = \mathbf{16}$ | $16 \times 2 = \mathbf{32}$ | **48** | **-60.00%** | **-71.43%** |
| **TSK-12D-B + C (32-PE Mode)** | $4 \times 6 = \mathbf{24}$ | $32 \times 2 = \mathbf{64}$ | **88** | **-40.00%** | **-47.62%** |
| **TSK-12D-B + C (64-PE Mode)** | $4 \times 10 = \mathbf{40}$ | $64 \times 2 = \mathbf{128}$ | **168** | **0.00%** | **0.00%** |

### 4.2 Cross-Check with Experimental Datasets
From [`tsk12d_feeder_optimization_results.csv`](file:///E:/MTech/LanChain/MTP/tsk12d_feeder_optimization_results.csv):
- **Row 10 (WL-03, CFG_A, $K=4$, 16-PE):**
  `sram_rd_reqs = 16`, `sram_rd_accepted = 16`, `sram_wr_reqs = 32`, `sram_wr_accepted = 32`.
  Total accesses: $16 + 32 = \mathbf{48}$.
- **Row 11 (WL-03, CFG_B, $K=4$, 32-PE):**
  `sram_rd_reqs = 24`, `sram_rd_accepted = 24`, `sram_wr_reqs = 64`, `sram_wr_accepted = 64`.
  Total accesses: $24 + 64 = \mathbf{88}$.
- **Row 12 (WL-03, CFG_C, $K=4$, 64-PE):**
  `sram_rd_reqs = 40`, `sram_rd_accepted = 40`, `sram_wr_reqs = 128`, `sram_wr_accepted = 128`.
  Total accesses: $40 + 128 = \mathbf{168}$.
- **Row 18 (WL-05, CFG_A, $K=4$, 16-PE Sparse):**
  `sram_rd_accepted = 16`, `sram_wr_accepted = 32` $\implies \mathbf{48}$ total accesses.
- **Row 22 (WL-06, CFG_A, $K=4$, 16-PE High-Mag):**
  `sram_rd_accepted = 16`, `sram_wr_accepted = 32` $\implies \mathbf{48}$ total accesses.

The numbers in `TSK12D_FEEDER_OPTIMIZATION_REPORT.md` are completely identical to the CSV and hardware event counters.

---

## 5. Task 4: Implementation Preservation & Audit Evidence

### 5.1 Baseline RTL File Integrity
The five protected baseline RTL files were verified with `git diff`:
1. `accelerator_core_top.sv`: 0 lines modified.
2. `mac_unit_40b.sv`: 0 lines modified.
3. `k_progress_tracker.sv`: 0 lines modified.
4. `slot_control_unit.sv`: 0 lines modified.
5. `hybrid_sram_bank.sv`: 0 lines modified.

Zero Git commits were created.

### 5.2 Historical CSV Dataset Preservation
The three historical CSV files remain bit-exact and unaltered:
- `tsk12_experiment_results.csv`: SHA / contents preserved.
- `tsk12d_instrumentation_results.csv`: SHA / contents preserved.
- `tsk12d_drain_optimization_results.csv`: SHA / contents preserved.

### 5.3 Full 19-Suite Regression Results
The regression runner (`phase2_step1_microarchitecture_and_rtl/run_regression.py`) executed all 19 testbenches in WSL with zero failures:

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
FINAL STATUS: REGRESSION PASSED (Exit Code 0)
```

---

## 6. Remaining Limitations & Structural Constraints

1. **Physical Bank Structural Conflict (Compute Latency Invariance):**
   - *Line Reference:* `datapath_compute_feeder.sv:255, 291` and `multibank_sram_subsystem.sv:73-75`.
   - *Limitation:* Weight Word 0 and Activation Word 8 both map to Bank $(2K) \pmod 8$. Because each hybrid SRAM bank contains only one physical read port, reading weights and activations concurrently in 1 cycle is impossible without a structural bank collision.
   - *Impact:* Compute latency ($T_{\text{comp}}$) cannot be reduced below $3K + 1$ cycles ($4, 7, 13, 25$ cycles for $K=1, 2, 4, 8$).
2. **Fixed 10-Word SRAM Frame Stride:**
   - *Line Reference:* `datapath_compute_feeder.sv:255, 266, 276, 291` (`active_base + req_cnt_q * 10`).
   - *Limitation:* Unaccessed weight words in 16-PE (offsets 2..7) and 32-PE (offsets 4..7) remain empty in SRAM address space. Packing frames without stride would break the DMA transfer contract (`dma_transfer_len = k_len * 10 * 4`) and ping-pong buffer controller addressing.
3. **WL-06 Dynamic Range Boundary:**
   - *Line Reference:* `tb_tsk12_adaptive_experiment.sv:1155-1164`.
   - *Limitation:* With $K=4$, maximum accumulator values reach only $\pm 3.6 \times 10^9$ ($0.65\%$ of $5.49 \times 10^{11}$). Saturation boundaries are verified in Suites 2 and 15, but not in WL-06.

---

## 7. Strict Physical Metrics Disclaimer

> [!IMPORTANT]
> **Functional Simulation Boundary Disclaimer:**
> The transaction reductions reported in this evidence review (-60% read requests, -71.43% total SRAM accesses) are cycle-accurate microarchitectural figures derived from functional simulation. They directly demonstrate that wordline charging, bitline swing, and sense-amplifier toggling are eliminated on unrequested banks.
>
> However, these functional reductions **must not be described as physical power, energy, or area savings, nor as end-to-end CNN inference speedup**. Physical power and energy metrics require standard cell synthesis, place-and-route, parasitic extraction (SPEF), and gate-level power simulation driven by switching activity vector files (VCD or SAIF) across characterized PVT operating corners.

---

## 8. File and Line References Supporting Audit Findings

| Audit Topic | Source File | Exact Line Range | Technical Finding |
| :--- | :--- | :--- | :--- |
| **Weight Bank Gating** | `datapath_compute_feeder.sv` | Lines 251–282 | Mode-dependent `sram_rd_req_bus` (8'b0000_0011, 8'b0000_1111, 8'b1111_1111) |
| **Weight Latching** | `datapath_compute_feeder.sv` | Lines 295–341 | Mode-dependent latching from Ports 0..1, 0..3, or 0..7 with zero-clamping |
| **Activation Fetch** | `datapath_compute_feeder.sv` | Lines 289–293 | Phase B requests Ports 0..1 for Words 8..9 across all modes |
| **Bank Interleaving** | `multibank_sram_subsystem.sv` | Lines 73–75 | $\text{Bank ID} = \text{rd\_addr}[2:0]$ mapping |
| **Bank Arbiter Priority** | `multibank_sram_subsystem.sv` | Lines 145–152 | Lowest port index granted; Port 0 (DMA) has priority over Port 1 (OFMAP) |
| **Bank Conflict Flag** | `multibank_sram_subsystem.sv` | Lines 241–246 | Composite conflict flags asserted on contention |
| **OFMAP Mode Slicing** | `ofmap_drain_controller.sv` | Lines 97–100 | Mode-dependent write counts: 32 words (16-PE), 64 words (32-PE), 128 words (64-PE) |
| **PE Output Gating** | `pe_array_40b.sv` | Lines 141–143 | Inactive columns strictly drive zero accumulators |
| **True MAC Saturation** | `tb_mac_saturation.sv` | Lines 111–136, 166–189 | 16,777-cycle loops genuinely reaching $+549,755,813,887$ and $-549,755,813,888$ |
| **Array Saturation** | `tb_workload_validation.sv` | Lines 673–705 | 515-cycle loops genuinely causing positive and negative overflow clamping |
| **WL-06 Operands** | `tb_tsk12_adaptive_experiment.sv` | Lines 1155–1164 | $K=4, A=\pm 30,000, W=30,000$ reaching $\pm 3.6 \times 10^9$ (high-magnitude test) |
| **Contention Generation** | `tb_tsk12_adaptive_experiment.sv` | Lines 909–913 | Concurrent DMA launched targeting Bank 0 during OFMAP drain busy |
| **Event Accounting** | `tb_tsk12_adaptive_experiment.sv` | Lines 375–401 | Direct synchronous sampling of read/write requests, ready, and accepted handshakes |
| **Untouched SRAM Check** | `tb_tsk12_adaptive_experiment.sv` | Lines 804–811 | Verifies unwritten words $32..127$ or $64..127$ remain strictly zero |

---

## 9. Final Sign-Off

| Verification Item | Requirement | Actual Status | Verdict |
| :--- | :--- | :--- | :---: |
| **Task 1: Saturation Evidence** | Audit saturation bounds and classify WL-06 | True saturation in Suites 2 & 15; WL-06 classified as high-mag | **PASS** |
| **Task 2: Transaction Accounting** | Trace actual handshake events & contention | Exact handshake event tracing verified without theoretical assumptions | **PASS** |
| **Task 3: Reported Savings** | Recalculate K=4 counts & reconcile CSV | $16+32=48$ (-71.43%) and $24+64=88$ (-47.62%) confirmed exact | **PASS** |
| **Task 4: Preservation** | Zero RTL modifications, zero commit creation | 5 protected files untouched; historical CSVs bit-exact | **PASS** |
| **Full Regression** | 100% pass across all 19 suites | 11,712 / 11,712 checks passed (100% PASS) | **PASS** |

**FINAL EVIDENCE REVIEW VERDICT: `PASS_WITH_LIMITATIONS`**

