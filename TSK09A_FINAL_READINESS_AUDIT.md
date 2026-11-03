# TSK-09A Final Readiness Audit: Parallel PE Operand Delivery & CNN Readiness

**Project:** Neural_Acc (Phase 2 RTL Implementation)  
**Date:** November 1, 2026  
**Auditor:** Independent RTL & Verification Readiness Auditor  
**Milestone Audited:** TSK-09A (Parallel PE Operand Delivery)  
**Next Milestone Target:** TSK-10 (Functional CNN Workload Validation)  
**Final Audit Verdict:** **PASS_WITH_LIMITATIONS**

---

## 1. Executive Summary

This independent audit assesses whether the **TSK-09A parallel PE operand delivery implementation** is functionally verified, architecturally sound, and ready to support **TSK-10 CNN workload validation**. 

All claims were audited directly against the current repository source code, execution logs, and live simulations in `phase2_step1_microarchitecture_and_rtl`. No prior implementation reports were accepted as proof without reproduction.

### Primary Audit Findings:
1. **Parallel Datapath Fully Validated:** The integrated accelerator core successfully delivers 4 independent row activations ($A_0 \dots A_3$) and 16 independent column weights ($W_0 \dots W_{15}$) across the $4 \times 16$ PE array. Each of the 64 PEs computes its mathematically expected product ($Y_{r,c} += A_r \times W_c$). The legacy single-scalar broadcast defect has been resolved.
2. **Conflict-Free SRAM Access Proven:** The 2-cycle interleaved read schedule over the 8-bank hybrid SRAM subsystem achieves zero bank collisions (`dut.u_sram_subsystem.total_conflicts_count == 0`), proving the cyclic permutation bank-addressing scheme.
3. **Regression & Baseline Preservation:** All 15 regression testbenches pass with **1,026 / 1,026 checks (exit code 0)**. Protected Phase 2 baseline RTL files (`accelerator_core_top.sv`, `mac_unit_40b.sv`, `k_progress_tracker.sv`, `slot_control_unit.sv`, `hybrid_sram_bank.sv`) have **zero modifications** (`git diff HEAD` clean).
4. **CNN Workload Readiness Status:** The datapath is ready to compute multi-$K$ matrix and convolution kernel tiles using pre-packed memory frames. However, **an integrated OFMAP drain/writeback path does not yet exist**—outputs currently reside only on top-level parallel output pins `accum_out[0:3][0:15]`. Furthermore, the feeder enforces a **fixed 10-word stride**, requiring offline tensor pre-formatting.
5. **Final Verdict:** **PASS_WITH_LIMITATIONS**. The implementation is approved to enter TSK-10 under the documented memory layout and output-probing constraints.

---

## 2. Files and Signals Inspected

### 2.1 RTL Source Files Inspected
* `datapath_compute_feeder.sv`: Verified 8-port SRAM read interface (`sram_rd_req_bus`, `sram_rd_addr_bus`, `sram_rd_dout_bus`), 2-cycle fetch FSM (`ST_PAR_REQ_W`, `ST_PAR_REQ_A`, `ST_PAR_COMPUTE`), weight staging registers `weight_stage_q[0..15]`, activation slicing `act_wire[0..3]`, and $K$-step counter `exec_cnt_q`.
* `neural_acc_integrated_top.sv`: Verified parameter `PARALLEL_OPERAND_MODE`, control port `cfg_parallel_en`, interconnect between SRAM subsystem Port B0..B7 and feeder, operand multiplexing (`act_data_row`, `weight_data`), and top-level datapath outputs `accum_out[0:3][0:15]`.
* `pe_array_40b.sv`: Verified 64-PE array instantiation ($4 \times 16$), mode decoding (16-, 32-, 64-PE), column active mask (`col_active`), inactive column clamping to 0, and per-PE `mac_unit_40b` port bindings.
* `mac_unit_40b.sv`: Verified signed $16\text{b} \times 16\text{b} \to 32\text{b}$ multiplication, 40-bit saturating addition ($[-2^{39}, 2^{39}-1]$), sticky saturation latching, and exact-zero bypass (`bypass_mac = (!act_mask) || (act_data == '0)`).
* `multibank_sram_subsystem.sv`: Verified low-order bank interleaving (`bank_sel = addr[2:0]`), 8 physical hybrid SRAM banks, read crossbar arbitration, and conflict detection counter `total_conflicts_count`.
* `adaptive_pe_controller.sv`: Verified degradation threshold comparator (`32'h0000_199A`), dynamic mode downgrade/fallback logic, and handshakes with sequencer and feeder.
* `layer_command_sequencer.sv`: Verified command interface, layer barrier synchronization, ping-pong consumer coordination, and completion pulse generation.

### 2.2 Trace of Critical Signals
```
[multibank_sram_subsystem]
    |-- rd_dout_bus[0..7] (8x 32-bit words)
           |
           v
[datapath_compute_feeder]
    |-- Cycle A: Latch weight_stage_q[0..15] <= {dout[7..0]}
    |-- Cycle B: Combinational act_wire[0..3] <= {dout[1..0]}
    |-- Cycle C: Assert compute_enable_in
           |
           +---> feeder_act_data_row[0..3]
           +---> feeder_weight_data_col[0..15]
           |
           v
[neural_acc_integrated_top]
    |-- act_data_row[0..3]     <= feeder_act_data_row[0..3]
    |-- weight_data[0..3][0..15] <= feeder_weight_data_col[0..15]
           |
           v
[pe_array_40b]
    |-- PE[r][c] receives: act_data_row[r] and weight_data[r][c]
    |-- Gating: inactive columns clamped to 0
           |
           v
[mac_unit_40b (PE[r][c])]
    |-- prod = act_data_row[r] * weight_data_col[c]
    |-- accum_out[r][c] <= sat40(accum_out[r][c] + prod)
           |
           v
[neural_acc_integrated_top Output Pins]
    |-- accum_out[0:3][0:15] (Direct parallel wire pins)
```

---

## 3. Independently Reproduced Test Results

The full regression test runner was executed from the shell in the actual workspace. All results below were independently captured and verified directly from simulator output:

* **Command Executed:**
  ```bash
  cd phase2_step1_microarchitecture_and_rtl && python3 run_regression.py
  ```
* **Process Exit Code:** `0` (Success)
* **Checks Evaluated:** 1,026 total checks (1,026 passed, 0 failed)

### 3.1 Suite-by-Suite Reproduction Matrix
| # | Testbench Suite | Category | Checks | Exit Status | Result | Evidence / Log Output |
| :-: | :--- | :--- | :-: | :-: | :-: | :--- |
| 1 | `tb_accelerator_core` | Baseline | 9 | 0 | PASS | `[SUCCESS] All Phase 2 Step 1 RTL Tests Completed Successfully!` |
| 2 | `tb_mac_saturation` | Baseline | 11 | 0 | PASS | `[SUCCESS] All MAC Saturation & Clear Tests Completed Successfully!` |
| 3 | `tb_k_progress_tracker` | Baseline | 14 | 0 | PASS | `[SUCCESS] All K-Progress Tracker Tests Completed Successfully!` |
| 4 | `tb_hybrid_sram_bank` | Baseline | 13 | 0 | PASS | `[SUCCESS] All SRAM Focused Tests Completed Successfully!` |
| 5 | `tb_drain_backpressure` | Baseline | 15 | 0 | PASS | `[SUCCESS] All Drain & Backpressure Tests Completed Successfully!` |
| 6 | `tb_acceptance_integrated` | Baseline | 29 | 0 | PASS | `[SUCCESS] All Executable RTL Acceptance Tests Passed with Zero Failures!` |
| 7 | `tb_pe_array_40b` | Subsystem | 28 | 0 | PASS | `[SUCCESS] All TSK-01 Multi-PE Array RTL Tests Passed!` |
| 8 | `tb_adaptive_pe_controller` | Subsystem | 53 | 0 | PASS | `[SUCCESS] All TSK-02 Adaptive PE Controller RTL Tests Passed!` |
| 9 | `tb_multibank_sram_subsystem` | Subsystem | 137 | 0 | PASS | `[RESULT] ALL TESTS PASSED SUCCESSFULLY!` |
| 10 | `tb_ping_pong_buffer_controller` | Subsystem | 117 | 0 | PASS | `[SUCCESS] All TSK-04 Ping-Pong Buffer Controller Tests Passed!` |
| 11 | `tb_layer_command_sequencer` | Subsystem | 97 | 0 | PASS | `[SUCCESS] All TSK-05 Layer Command Sequencer Tests Passed!` |
| 12 | `tb_dma_controller` | Subsystem | 87 | 0 | PASS | `[SUCCESS] All TSK-06 DMA Controller Tests Passed!` |
| 13 | `tb_neural_acc_integrated_top` | Integration | 132 | 0 | PASS | `[SUCCESS] All TSK-07 System Integration Tests Passed!` |
| 14 | `tb_workload_validation` | Integration | 58 | 0 | PASS | `[SUCCESS] All TSK-08 Functional Workload Tests Passed!` |
| 15 | `tb_parallel_pe_operand_delivery` | Integration | 226 | 0 | PASS | `[SUCCESS] All TSK-09 Parallel PE Operand Delivery Tests Passed with Zero Failures!` |

### 3.2 Regression Runner Failure Propagation Check
* An isolated mutation test (pointing the first suite to a non-existent file) was executed.
* **Exit Code:** `1` (Non-zero).
* **Output:**
  ```text
  FAILED TESTBENCHES DETAIL:
    [X] tb_accelerator_core: Compilation failed (exit code 1)
  FINAL STATUS: REGRESSION FAILED (Exit Code 1)
  ```
* Confirmed: The test runner does not mask failures or falsely report PASS.

---

## 4. Detailed Audit Findings by Topic

### 4.1 Audit 1: Parallel Datapath Correctness
* **Row Activations:** Confirmed that Row 0..3 activations are sliced from SRAM words 8 and 9. Each row receives an independent signed 16-bit value.
* **Column Weights:** Confirmed that Column 0..15 weights are sliced from SRAM words 0..7. Each column receives an independent signed 16-bit value.
* **PE Product Mapping:** Verified that PE instance $[r][c]$ computes $A_r \times W_c$. All 64 PEs execute distinct multiplications simultaneously.
* **Isolation from Broadcast:** In `neural_acc_integrated_top.sv`, `is_parallel_active = PARALLEL_OPERAND_MODE | cfg_parallel_en | cmd_layer_id[15]`. When active, scalar probe samples (`feeder_act_sample`, `feeder_weight_sample`) are multiplexed out; only vector rows and columns drive the PE array.
* **Signed Arithmetic:** All inputs, weights, and multipliers are declared as `signed`.
* **Exact-Zero Skipping:** `mac_unit_40b.sv` evaluates `bypass_mac = (!act_mask) || (act_data == '0)`. If a row activation is 0, the MAC multiplier is gated, `cycle_skipped` is asserted, and the accumulator register retains its prior sum without updating. Inactive rows skip without disrupting active rows.
* **Inactive PE Clamping:** Inactive columns are gated (`pe_mac_enable = 1'b0`) and clamped to 0 at inputs and outputs.

### 4.2 Audit 2: SRAM Scheduling
* **Read Port Interconnect:** All 8 read channels (`sram_rd_req_bus[7:0]`, `sram_rd_addr_bus[7:0]`, `sram_rd_ready_bus[7:0]`, `sram_rd_rvalid_bus[7:0]`, `sram_rd_dout_bus[7:0]`) are connected between the SRAM subsystem and feeder without tie-offs.
* **Conflict-Free Weight Fetch (Cycle A):** In `ST_PAR_REQ_W`, addresses requested are $10k + [0..7]$. The low 3 address bits increment from 0 to 7 modulo 8, mapping to Banks 0..7. All 8 banks are accessed concurrently with **zero bank conflicts**.
* **Conflict-Free Activation Fetch (Cycle B):** In `ST_PAR_REQ_A`, addresses requested are $10k + 8$ (Port 0) and $10k + 9$ (Port 1). Address low bits are $2k \pmod 8$ (even) and $(2k+1) \pmod 8$ (odd). They never collide with each other, and Ports 2..7 are idle.
* **Latency Alignment:** Synchronous SRAM read latency is 1 cycle. Weight data requested at $T_0$ is latched at $T_1$. Activation data requested at $T_1$ arrives combinationally at $T_2$. `compute_enable_in` pulses at $T_2$ when both sets of operands are aligned.
* **Backpressure Integrity:** When the sequencer or buffer controller is not ready, the feeder holds in `ST_IDLE` or `ST_DRAIN_WAIT`. No requests are issued, and state counters do not advance.

### 4.3 Audit 3: Multi-K Computation
* **Step Progression:** `exec_cnt_q` and `req_cnt_q` increment strictly once per cycle in `ST_PAR_COMPUTE` when `sram_rd_rvalid_bus[0] && sram_rd_rvalid_bus[1]` is asserted.
* **Operand Alignment:** For every step $k \in [0, K-1]$, weights and activations are indexed by $10k$, guaranteeing identical $K$-index alignment across all 64 PEs.
* **Accumulator Preservation:** Partial sums persist in the 40-bit accumulator registers across all $K$ steps. `accum_clear` is asserted only at layer start (`pe_start_req`).
* **Completion Handshake:** `compute_done` is asserted only when `exec_cnt_q + 1 == k_total_q`. The sequencer waits for `pe_layer_quiescent` before asserting `layer_done_pulse`. Completion cannot fire prematurely.

### 4.4 Audit 4: Adaptive PE Allocation
* **Mode Definitions:**
  * Mode 0 (16-PE): Columns 0..3 active across all 4 rows ($4 \times 4 = 16\text{ PEs}$). Columns 4..15 clamped to 0.
  * Mode 1 (32-PE): Columns 0..7 active across all 4 rows ($8 \times 4 = 32\text{ PEs}$). Columns 8..15 clamped to 0.
  * Mode 2 (64-PE): Columns 0..15 active across all 4 rows ($16 \times 4 = 64\text{ PEs}$).
* **Controller Routing:** Sequencer forwards `cmd_pe_mode` and `cmd_adaptive_en` to `adaptive_pe_controller`, which outputs `cfg_mode` directly to `pe_array_40b`.
* **Degradation Estimates Clarification:** The degradation inputs `cmd_degradation_hat_16/32/64` are externally provided by software/host driver. There is **no on-chip neural quality estimator** in RTL; the controller acts strictly as a hardware actuator for software-directed degradation policies.

### 4.5 Audit 5: Regression Integrity
* Fully reproduced with 15/15 suites passing, 1,026/1,026 checks.
* Zero compilation or simulation errors.
* No test was counted as passing based solely on printed strings; exit codes and error outputs were verified.

### 4.6 Audit 6: Throughput Claims
* **Recalculation from RTL:**
  * Weight Fetch: 1 cycle (`ST_PAR_REQ_W`)
  * Activation Fetch + Weight Latch: 1 cycle (`ST_PAR_REQ_A`)
  * Compute Pulse: 1 cycle (`ST_PAR_COMPUTE`)
  * **Total per $K$-step:** Exactly 3 clock cycles.
* **Kernel Compute Throughput:**
  $$\text{Throughput}_{\text{64-PE}} = \frac{64\text{ MACs}}{3\text{ cycles}} = 21.33\text{ MACs/cycle}$$
* **Evaluation of the $64\times$ Speedup Claim:**
  * The baseline broadcast mode also required ~3 cycles per step, but computed only 1 unique outer-product element ($0.33\text{ MACs/cycle}$), redundantly duplicating it across 64 PEs.
  * The $64\times$ speedup ($21.33 / 0.33$) is valid **only as a functional matrix throughput comparison** (unique outer-product elements computed per cycle).
  * It does **not** reflect end-to-end wall-clock speedup (which includes DMA ingestion and barrier latency), nor does it imply a $64\times$ hardware multiplier capacity increase.

---

## 5. Audit 7: CNN Workload Readiness Assessment

This audit evaluated whether the existing integrated implementation can execute realistic convolution workloads (e.g. Conv2D layers with multiple input channels, output channels, and spatial tiles):

### 5.1 Mapping a CNN Layer to the Neural_Acc Architecture
In a standard Conv2D layer with input feature map $X \in \mathbb{R}^{C \times H \times W}$ and filters $W \in \mathbb{R}^{M \times C \times R \times S}$:
* **Spatial Tiling (Rows):** 4 rows compute 4 distinct output spatial points (pixels $(h, w)_0 \dots (h, w)_3$).
* **Channel Tiling (Columns):** 16 columns compute 16 distinct output channels (filters $m_0 \dots m_{15}$).
* **Reduction Dimension ($K$):** $K = C \times R \times S$ (reduction over input channels and filter window).
* **Per Step $k$:** 4 activations ($A_0 \dots A_3$) and 16 weights ($W_0 \dots W_{15}$) are multiplied and accumulated across the 64 PEs.

### 5.2 Architectural Readiness and Specific Gaps

| Architectural Feature | Current RTL Status | Assessment for TSK-10 CNN Validation |
| :--- | :--- | :--- |
| **Multi-$K$ Dot-Product Accumulation** | Fully verified ($K=1, 2, 3, 8$) | **READY:** 40-bit accumulators accumulate correctly over arbitrary $K$. |
| **Parallel $4 \times 16$ Outer Product** | Fully verified (64 distinct outputs) | **READY:** Computes 4 spatial points $\times$ 16 output channels in parallel. |
| **Memory Framing & Tensor Layout** | Hardcoded 10-word stride in feeder | **LIMITATION:** Requires offline tensor pre-packing into interleaved 10-word frames (`[W0..15, A0..3]`). Arbitrary layout strides are not supported in RTL. |
| **Output Feature Map (OFMAP) Storage** | Parallel top-level pins `accum_out[0:3][0:15]` | **MAJOR GAP:** No internal drain/writeback datapath to SRAM or DMA. In an actual chip, reading outputs requires on-chip writeback. For TSK-10 simulation, outputs must be validated at the top-level pins. |
| **Multi-Tile Outer-Loop Sequencing** | Sequencer runs 1 layer command per trigger | **LIMITATION:** Iterating over multiple tiles (e.g. 49 spatial tiles $\times$ 4 channel tiles) requires host/testbench orchestration to dispatch successive layer commands. |
| **Quantization & Activation Function** | Not present (raw 40-bit signed accumulators) | **OBSERVATION:** No on-chip ReLU or requantization to INT8/INT16; raw 40-bit accumulator outputs are exposed directly. |

---

## 6. Classification of Findings

### 6.1 Blockers
* **None.** There are no architectural defects preventing simulation-based CNN workload validation.

### 6.2 Major Findings
* **MAJ-09A-01 (Absence of Integrated OFMAP Writeback Datapath):**
  * *Description:* `neural_acc_integrated_top.sv` exports accumulator outputs purely as 64 parallel 40-bit wires (`accum_out[0:3][0:15]`). SRAM Port A write ports 1..7 are tied off, and Write Port 0 is connected exclusively to the DMA ingestion adapter. There is no internal drain controller, serializer, or writeback adapter to store completed OFMAP tiles into SRAM or stream them to external memory via AXI master write.
  * *Impact:* For physical tapeout, an on-chip writeback path is mandatory. For TSK-10 simulation verification, the testbench must sample outputs directly from top-level pins.

### 6.3 Minor Findings
* **MIN-09A-01 (Throughput Metric Qualification):**
  * *Description:* The $64\times$ throughput speedup cited in `TSK09A_IMPLEMENTATION_REPORT.md` represents the ratio of unique functional MAC operations per cycle during active kernel compute ($21.33\text{ vs }0.33\text{ MACs/cycle}$). It must not be cited as end-to-end workload acceleration, which is lower due to DMA ingestion and layer barrier overhead.

### 6.4 Observations
* **OBS-09A-01 (Fixed 10-Word Interleaved Tensor Layout):**
  * *Description:* `datapath_compute_feeder.sv` hardcodes a stride of 10 words per $K$-step (8 weight words + 2 activation words). CNN inputs and weights must be pre-formatted by software/driver into this exact interleaved structure prior to DMA transfer.
* **OBS-09A-02 (Multi-Tile Host Orchestration Required):**
  * *Description:* The hardware does not contain an autonomous multi-tile loop generator (e.g., nested loops for $H, W, M$). Multi-tile workloads in TSK-10 must be sequenced by dispatching a sequence of layer commands from the testbench.
* **OBS-09A-03 (Synthesis SDC & Physical Energy Verification):**
  * *Description:* Active power and energy reductions from adaptive PE gating are currently verified via behavioral enable gating and input clamping. Silicon power and energy claims require Gate-Level Netlist (GLN) simulation with SAIF/VCD switching activity against a target standard cell library.

---

## 7. Readiness Assessment for TSK-10 CNN Workload Validation

### Is the implementation ready for TSK-10?
**YES, WITH DOCUMENTED LIMITATIONS.**

The parallel datapath, multi-bank memory scheduling, signed 40-bit accumulation, adaptive column gating, and baseline preservation are thoroughly verified and stable.

To execute TSK-10 successfully without altering the frozen RTL:
1. **Software Pre-Formatting:** The TSK-10 test environment must include a software utility (or Python reference) that maps CNN filter weights and input feature maps into the conflict-free 10-word interleaved memory layout (`pack_k_step`).
2. **Top-Level Pin Observation:** The TSK-10 testbench must sample completed tile outputs directly from `accum_out[0:3][0:15]` upon `layer_done_pulse`.
3. **Sequencer-Driven Tiling:** Multi-tile CNN convolution must be orchestrated by issuing sequential layer commands across successive ping-pong buffers.

---

## 8. Final Verdict

### **PASS_WITH_LIMITATIONS**

**Sign-Off Summary:**
* **Parallel Datapath Correctness:** PASS (4 independent rows, 16 independent columns, 64 distinct outputs).
* **SRAM Scheduling & Conflicts:** PASS (0 bank conflicts observed).
* **Regression Suite:** PASS (15/15 suites passing, 1,026/1,026 checks).
* **Baseline Preservation:** PASS (100% bit-exact against HEAD, 0 lines modified).
* **CNN Validation Readiness:** APPROVED under pre-formatted memory framing and top-level pin validation constraints.

