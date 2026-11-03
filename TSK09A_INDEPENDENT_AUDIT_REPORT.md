# TSK-09A Independent Audit Report: Parallel PE Operand Delivery

**Project:** Neural_Acc (Phase 2 RTL Implementation)  
**Date:** November 1, 2026  
**Auditor:** Independent RTL & Verification Auditor  
**Milestone Audited:** TSK-09A (Independent 4x16 PE Operand Delivery)  
**Final Audit Verdict:** **PASS_WITH_LIMITATIONS**

---

## 1. Executive Summary

An independent, rigorous audit of the TSK-09A parallel processing element (PE) operand-delivery implementation in the Neural_Acc repository was conducted. The audit inspected the RTL source code, module interfaces, memory scheduling schemes, testbench assertions, regression infrastructure, baseline preservation, and throughput claims.

### Key Audit Conclusions:
1. **Genuine Independent Operands:** The RTL successfully delivers 4 distinct row activations and 16 distinct column weights to the 4x16 PE array. The previous single-scalar broadcast defect identified in TSK-09 has been completely resolved.
2. **Conflict-Free SRAM Schedule:** The 2-cycle interleaved read schedule across the 8-bank hybrid SRAM subsystem operates with zero physical bank conflicts (`total_conflicts_count == 0`), proving the mathematical low-order bank-interleaving scheme.
3. **Mathematical Correctness & Mutation Sensitivity:** Software golden calculations across positive, negative, mixed-sign, exact-zero, and multi-$K$ steps match RTL accumulator outputs across all 64 PEs. Controlled mutation testing confirmed that any permutation or swap of row activation or column weight indices causes immediate assertion failures in the testbench.
4. **Baseline Preservation:** All protected Phase 2 baseline RTL files (`accelerator_core_top.sv`, `mac_unit_40b.sv`, `k_progress_tracker.sv`, `slot_control_unit.sv`, `hybrid_sram_bank.sv`) remain strictly bit-exact and unmodified against `git HEAD`.
5. **Regression Integrity:** The full 15-suite regression executed via `run_regression.py` passes with **1,026 / 1,026 checks (exit code 0)**. Controlled failure injection confirmed that non-zero exit codes are reliably propagated to the OS upon test failure.

---

## 2. Audit 1: Independent Operands & Datapath Tracing

### 2.1 Signal Path Verification
The complete datapath from multi-bank SRAM through `datapath_compute_feeder.sv`, `neural_acc_integrated_top.sv`, and `pe_array_40b.sv` to `mac_unit_40b.sv` was traced:

* **Weights Path:**
  * System memory packs 16 column weights (16-bit signed) into 8 contiguous 32-bit words (`sys_memory[0..7]`).
  * In state `ST_PAR_REQ_W`, `datapath_compute_feeder` requests words `active_base + 10*k + [0..7]` across `sram_rd_req_bus[0..7]`.
  * In state `ST_PAR_REQ_A`, returning data on `sram_rd_dout_bus[0..7]` is captured into `weight_stage_q[0..15]` using 16-bit slicing:
    $$\text{weight\_stage\_d}[2i] = \text{sram\_rd\_dout\_bus}[i][15:0]$$
    $$\text{weight\_stage\_d}[2i+1] = \text{sram\_rd\_dout\_bus}[i][31:16] \quad (i = 0 \dots 7)$$
  * In `neural_acc_integrated_top.sv`, `weight_data[r][c] = feeder_weight_data_col[c]` routes each column weight independently across all rows.

* **Activations Path:**
  * System memory packs 4 row activations (16-bit signed) into 2 contiguous 32-bit words (`sys_memory[8..9]`).
  * In state `ST_PAR_REQ_A`, `datapath_compute_feeder` requests words `active_base + 10*k + 8` on Port 0 and `active_base + 10*k + 9` on Port 1.
  * In state `ST_PAR_COMPUTE`, returning data is sliced combinationally:
    $$\text{act\_wire}[0] = \text{sram\_rd\_dout\_bus}[0][15:0], \quad \text{act\_wire}[1] = \text{sram\_rd\_dout\_bus}[0][31:16]$$
    $$\text{act\_wire}[2] = \text{sram\_rd\_dout\_bus}[1][15:0], \quad \text{act\_wire}[3] = \text{sram\_rd\_dout\_bus}[1][31:16]$$
  * In `neural_acc_integrated_top.sv`, `act_data_row[r] = feeder_act_data_row[r]` routes each row activation independently across all columns.

* **PE Array Mapping:**
  * In `pe_array_40b.sv`, physical PE instance `[r][c]` receives:
    $$\text{pe\_act\_in} = \text{act\_data\_row}[r], \quad \text{pe\_weight\_in} = \text{weight\_data}[r][c] = \text{weight\_data\_col}[c]$$
  * Every physical PE computes $Y_{r,c} += A_r \times W_c$, forming a complete, genuine outer product across the $4 \times 16$ grid.

### 2.2 Slicing, Ordering, and Duplication Checks
* **Signed Interpretation:** Verified. Ports and intermediate nets are explicitly declared as `logic signed [15:0]`. Multiplication in `mac_unit_40b.sv` evaluates signed $16\text{b} \times 16\text{b} \to 32\text{b}$ signed products.
* **$K$-Step Ordering:** Verified. `req_cnt_q` and `exec_cnt_q` increment synchronously in `ST_PAR_COMPUTE`. Stride of 10 words advances address boundaries without dropping or overlapping words.
* **Scalar Broadcast Elimination:** When `cfg_parallel_en` or `PARALLEL_OPERAND_MODE` is asserted, scalar broadcast wires are completely isolated from the PE array.

---

## 3. Audit 2: SRAM Scheduling & Latency Analysis

### 3.1 Bank Interleaving & Address Decoding
The `multibank_sram_subsystem` uses low-order interleaving:
$$\text{Bank Index} = \text{Address}[2:0], \quad \text{Row Offset} = \text{Address}[13:3]$$

* **Cycle A (Weights Fetch):**
  * Requests target `active_base + 10*k + [0..7]`.
  * For any integer $k$, the sequence $\{10k, 10k+1, \dots, 10k+7\} \pmod 8$ is a cyclic permutation of $\{0, 1, 2, 3, 4, 5, 6, 7\}$.
  * Each of the 8 read ports requests a unique physical bank simultaneously. Conflict count: 0.
* **Cycle B (Activations Fetch):**
  * Requests target `active_base + 10*k + 8` (Port 0) and `active_base + 10*k + 9` (Port 1).
  * Low bits: $(10k+8) \pmod 8 = 2k \pmod 8$ (always even); $(10k+9) \pmod 8 = (2k+1) \pmod 8$ (always odd).
  * Ports 0 and 1 never address the same bank, and Ports 2..7 are idle. Conflict count: 0.

### 3.2 Read-Response Latency Alignment
* **SRAM Latency:** 1 clock cycle from read request assertion to valid data output.
* **Pipeline Synchronization:**
  * At $T_0$ (`ST_PAR_REQ_W`): 8 weight read requests asserted.
  * At $T_1$ (`ST_PAR_REQ_A`): 8 weight words arrive; latched into `weight_stage_q`; 2 activation read requests asserted.
  * At $T_2$ (`ST_PAR_COMPUTE`): 2 activation words arrive combinationally on `act_wire`; `compute_enable_in` asserted for exactly 1 cycle.
  * At $T_3$: MAC registers capture the accumulated product. FSM loops to $T_0$ for next step $k+1$.
* **Throughput:** Exactly 3 clock cycles per $K$-step. Zero wasted stall cycles.

### 3.3 Backpressure & Ping-Pong Switching
* **Backpressure Stalls:** Verified in Scenario 6. When consumer requests an empty or uncommitted buffer, FSM stalls in `ST_DRAIN_WAIT`, preserving registers without spurious transitions. Upon DMA buffer commitment, computation resumes seamlessly.
* **Overlapped Ping-Pong Switching:** Verified in Scenario 7. Layer 701 executes on Buffer A while Buffer B is loaded via DMA. Layer 702 executes on Buffer B immediately upon Layer 701 completion, confirming zero buffer cross-talk.

---

## 4. Audit 3: Computational Correctness & Mutation Testing

### 4.1 Independent Mathematical Verification
An independent software model (`independent_matrix_audit.py`) was evaluated against the RTL execution across a diverse computational workload:
* Positive operands ($A > 0, W > 0$)
* Negative operands ($A < 0, W < 0$)
* Mixed-sign operands ($A \gtrless 0, W \lessgtr 0$)
* Exact-zero activations (zero-skipping validation)
* Saturation boundary conditions (40-bit saturating signed adder clamping)
* Multi-$K$ step accumulation ($K=1, 2, 3, 8$)
* Across all 64 accumulators, the RTL outputs matched the mathematical reference with 100% numerical precision.

### 4.2 Mutation Testing (Fault Sensitivity)
To confirm that the test suite does not produce false passes, controlled fault injection was performed on temporary, isolated testbench copies without altering the actual RTL:
1. **Mutation 1 (Row Activation Transposition):**
   * Deliberately swapped Row 0 and Row 1 activations in testbench packing: `a_s0[0*16 +: 16] = a_val0[1]`.
   * Result: **16 explicit assertion failures** across all 16 PEs of Row 0 (`[FAIL] S1.3: PE[0][0..15] actual=16..136, expected=26..296`). Testbench reported failure.
2. **Mutation 2 (Column Weight Transposition):**
   * Deliberately swapped Column 0 and Column 1 weights in testbench packing: `w_s0[0] <-> w_s0[1]`.
   * Result: **13 explicit assertion failures** across multiple rows and columns (`[FAIL] S1.3: PE[0..3][0..1]`). Testbench reported failure.
* **Conclusion:** The testbench assertions possess high fault coverage and cannot be spoofed by accidental operand broadcasting or transposed indices.

---

## 5. Audit 4: Throughput and Speedup Claims

### 5.1 Analysis of the $64\times$ Speedup Claim
`TSK09A_IMPLEMENTATION_REPORT.md` claims an "Effective Functional Speedup of 64x". The audit inspected this claim:

1. **Definition of One MAC:**
   One 16-bit $\times$ 16-bit signed multiplication followed by 40-bit signed accumulation: $(A_r \times W_c) + \text{accum}$.
2. **Per-Cycle MAC Execution:**
   During the 1 compute cycle (`ST_PAR_COMPUTE`), all 64 physical PEs execute concurrently, performing 64 MACs.
3. **Cycle Breakdown per $K$-Step:**
   * Fetch Weights: 1 cycle (`ST_PAR_REQ_W`)
   * Fetch Activations + Latch Weights: 1 cycle (`ST_PAR_REQ_A`)
   * Compute Pulse: 1 cycle (`ST_PAR_COMPUTE`)
   * **Total per step:** 3 clock cycles.
4. **Kernel-Level Compute Throughput:**
   * 64-PE Mode: $64\text{ MACs} / 3\text{ cycles} = 21.33\text{ MACs/cycle}$.
   * 32-PE Mode: $32\text{ MACs} / 3\text{ cycles} = 10.67\text{ MACs/cycle}$.
   * 16-PE Mode: $16\text{ MACs} / 3\text{ cycles} = 5.33\text{ MACs/cycle}$.
5. **Comparison Against Baseline:**
   * In baseline broadcast mode (TSK-07/08), the feeder fetched 1 scalar activation and 1 scalar weight per step (~3 cycles), and broadcast it to all 64 PEs. Only **1 distinct outer-product MAC** was computed per step ($1 / 3 = 0.33\text{ MACs/cycle}$), while 63 PEs redundantly computed identical duplicate values.
   * Ratio of distinct mathematical MACs completed:
     $$\frac{21.33\text{ MACs/cycle}}{0.33\text{ MACs/cycle}} = 64\times$$

### 5.2 Throughput Claim Classification & Caveats
* **Peak Theoretical Array Throughput:** 64 MACs/cycle (achievable only if memory bandwidth was infinite/zero-latency).
* **Simulation-Measured Kernel Throughput:** 21.33 MACs/cycle (memory-bound by 8-bank SRAM 2-cycle fetch schedule).
* **End-to-End Workload Throughput:** Lower than 21.33 MACs/cycle when factoring in DMA memory ingestion (AXI burst transfers) and sequencer setup/barrier latency.
* **Silicon Activity vs Functional Speedup:** The $64\times$ speedup represents **useful mathematical work completed per unit time**, not a $64\times$ increase in raw multiplier toggling (the baseline array was already toggling 64 multipliers, but doing redundant work). The implementation report correctly described this as "Effective Functional Speedup", but it must be clearly distinguished from end-to-end wall-clock speedup on arbitrary workloads.

---

## 6. Audit 5: Regression Suite Verification

The complete regression runner was executed in the actual repository environment:
* **Command:** `python3 run_regression.py`
* **Exit Status:** `0`
* **Total Suites:** 15
* **Total Checks:** 1,026 Evaluated | 1,026 Passed | 0 Failed

### Per-Suite Regression Record:
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

### Regression Failure Propagation:
A controlled fault was injected into an isolated copy of `run_regression.py` (pointing to a non-existent testbench file).
* Output: `[X] tb_accelerator_core : Compilation failed (exit code 1)`
* Runner Exit Status: `1` (Non-zero).
* Confirmation: Failure reporting to the operating system is robust.

---

## 7. Audit 6: Baseline Preservation

The baseline files protected under Phase 2 rules were checked using `git diff HEAD`:
* `accelerator_core_top.sv` : 0 diff lines (100% bit-exact)
* `mac_unit_40b.sv` : 0 diff lines (100% bit-exact)
* `k_progress_tracker.sv` : 0 diff lines (100% bit-exact)
* `slot_control_unit.sv` : 0 diff lines (100% bit-exact)
* `hybrid_sram_bank.sv` : 0 diff lines (100% bit-exact)

No baseline RTL was modified, and no git commits were created.

---

## 8. Audit Findings Classification

### BLOCKER Findings:
* **None.**

### MAJOR Findings:
* **None.**

### MINOR Findings:
1. **FND-09A-01 (Throughput Scope Qualification):**
   * *Description:* `TSK09A_IMPLEMENTATION_REPORT.md` cites a $64\times$ speedup and $21.33\text{ MACs/cycle}$ throughput. While mathematically accurate for the inner-loop matrix kernel, this metric does not represent end-to-end workload throughput. In full system execution, DMA burst ingestion latency and sequencer layer barriers reduce sustained workload throughput.
   * *Impact:* Risk of overstating end-to-end acceleration if cited without qualification.

### OBSERVATIONS:
1. **OBS-09A-01 (Report Typo in 16-PE Mode Description):**
   * *Description:* Section 5 of `TSK09A_IMPLEMENTATION_REPORT.md` stated that 16-PE mode activates "Rows 0..1 $\times$ Cols 0..7", whereas the actual RTL in `pe_array_40b.sv` line 72 and testbench `tb_parallel_pe_operand_delivery.sv` line 565 activate **Columns 0..3 across all 4 Rows** (`col_active = 16'h000F`, $4 \times 4 = 16\text{ PEs}$). The RTL and testbench agree, but the report text contains a minor geometric typo.
2. **OBS-09A-02 (Fixed 10-Word Memory Stride):**
   * *Description:* `datapath_compute_feeder.sv` hardcodes a stride of 10 words per $K$-step (8 weight words + 2 activation words). Supporting arbitrary tensor geometries or transposed layouts will require a programmable stride generator in future milestones.
3. **OBS-09A-03 (Synthesis SDC & Power Measurement Prerequisites):**
   * *Description:* All activity reduction metrics (e.g., inactive PE clamping) are currently verified at the behavioral simulation level. True silicon power savings and timing closure require Gate-Level Netlist (GLN) simulation with SAIF switching activity on a target standard cell library.

---

## 9. Final Verdict

### **PASS_WITH_LIMITATIONS**

**Justification:**  
The TSK-09A parallel PE operand delivery implementation successfully solves the scalar broadcast defect, delivering distinct row activations and column weights across the entire 4x16 PE array. The 8-bank SRAM access schedule is mathematically sound and conflict-free. All 15 regression suites (1,026 checks) pass with zero errors, baseline files are strictly preserved, and mutation tests confirm high verification sensitivity. 

The verdict is designated as **PASS_WITH_LIMITATIONS** due to the minor qualification required on end-to-end throughput claims and the hardcoded 10-word memory layout stride, which must be addressed before physical synthesis.

