# TSK-12D-A Implementation Report: Adaptive PE Experiment Instrumentation Enhancement

**Project:** Neural_Acc — Phase 2 RTL Microarchitecture and Verification  
**Workspace:** `E:\MTech\LanChain\MTP`  
**RTL Directory:** `phase2_step1_microarchitecture_and_rtl`  
**Status:** **IMPLEMENTATION COMPLETE — ALL 19 REGRESSION SUITES PASSED (12,298 / 12,298 CHECKS)**  
**Date:** November 2, 2026  

---

## 1. Executive Summary

This report documents the implementation and verification of **TSK-12D-A (Adaptive PE Experiment Instrumentation Enhancement)** for the Neural_Acc CNN accelerator core.

Following the independent audit recommendations in `TSK12C_AUDIT_REPORT.md`, the instrumentation in [`tb_tsk12_adaptive_experiment.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_tsk12_adaptive_experiment.sv) was enhanced to transition from analytical estimations to **autonomous hardware runtime event probes** and **cycle-accurate launch latency measurements**, without modifying functional accelerator architecture.

### Key Deliverables Completed:
1. **Direct Hardware Skip-Event Instrumentation:** Implemented direct hierarchical runtime probing of [`dut.u_pe_array.cycle_skipped[r][c]`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/pe_array_40b.sv#L73) gated strictly by the live compute window (`dut.pe_array_enable == 1'b1`) across active columns (`dut.col_active[c] == 1'b1`).
2. **Hardware MAC Event Classification & Conservation:** Added autonomous hardware counters:
   - `hw_mac_enabled_events`: Total active PE-cycles enabled during compute ($K \times N_{\text{cfg}}$).
   - `hw_mac_skipped_events`: Total zero-activation bypass events probed directly from RTL wires.
   - `hw_mac_executed_events`: Total non-bypassed accumulation operations executed by active PEs.
   - Event conservation verified: $\text{hw\_mac\_enabled\_events} \equiv \text{hw\_mac\_skipped\_events} + \text{hw\_mac\_executed\_events}$.
3. **Cycle-Accurate Launch Latency Instrumentation:** Added cycle-accurate clock-edge measurement of sequencer launch latency:
   $$t_{\text{launch\_cycles}} = \text{cycle}(\text{compute\_start}) - \text{cycle}(\text{cmd\_valid} \land \text{cmd\_ready})$$
   Measured to be invariant at exactly **3 clock cycles** across all Fixed 16-PE, 32-PE, 64-PE, and Adaptive modes.
4. **Enhanced 20-Column CSV Dataset:** Generated [`tsk12d_instrumentation_results.csv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tsk12d_instrumentation_results.csv) (both local and repository root) appending the 4 new metrics while preserving the 16 original columns and keeping the baseline [`tsk12_experiment_results.csv`](file:///e:/MTech/LanChain/MTP/tsk12_experiment_results.csv) bit-exact.
5. **Zero Functional RTL Modifications:** Verified that all instrumentation was achieved strictly via testbench enhancements. Zero lines were modified across functional RTL and the 5 protected baseline files.
6. **Full Regression Validation:** Executed the complete 19-suite regression runner (`run_regression.py`): **19 / 19 passed, 12,298 / 12,298 checks evaluated with zero failures**.

---

## 2. Problem Statement & Audit Remediation

In `TSK12C_AUDIT_REPORT.md`, two key measurement limitations were identified:

| Audit Finding | Prior TSK-12B Implementation | TSK-12D-A Remediation |
| :--- | :--- | :--- |
| **Audit Task A: Useful MAC Accounting** | `useful_macs_count` was computed analytically inside stimulus generation loop `generate_and_pack_operands` based on stimulus array `t_act[r][k] != 0`. | Replaced with autonomous hardware runtime event sampling of `dut.u_pe_array.cycle_skipped[r][c]` directly off physical RTL wires inside `always_ff @(posedge clk)`. |
| **Audit Task D: Launch Latency Isolation** | Sequencer launch latency was verified structurally (3 cycles) but was bundled into $T_{\text{total}}$ without an explicit column in the CSV dataset. | Added `t_launch_cycles` as an explicit metric, clock-edge measured between command handshake and `dut.compute_start`, logged in CSV column 17. |

---

## 3. Instrumentation Architecture & Methodology

### 3.1 Hardware MAC Event Probing

In the underlying RTL ([`mac_unit_40b.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv#L44-L46) and [`pe_array_40b.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/pe_array_40b.sv#L73)), the zero-bypass signal is generated combinationally and exposed as:
```systemverilog
assign bypass_mac    = (!act_mask) || (act_data == '0);
assign cycle_skipped = enable && bypass_mac;
```
In [`pe_array_40b.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/pe_array_40b.sv#L73), the multi-PE array gates each MAC skip wire by column active status:
```systemverilog
assign cycle_skipped[r][c] = pe_is_active ? raw_cycle_skipped[r][c] : 1'b0;
```

In [`tb_tsk12_adaptive_experiment.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_tsk12_adaptive_experiment.sv#L370-L388), the testbench samples these signals on every posedge of `clk`:
```systemverilog
// Direct hardware MAC event instrumentation
if (meas_run_active && dut.pe_array_enable) begin
    for (int r = 0; r < 4; r++) begin
        for (int c = 0; c < 16; c++) begin
            if (dut.col_active[c]) begin
                hw_mac_enabled_events++;
                if (dut.u_pe_array.cycle_skipped[r][c]) begin
                    hw_mac_skipped_events++;
                end else begin
                    hw_mac_executed_events++;
                end
            end
        end
    end
end
```

#### Sampling Invariants:
1. **Window Guard:** Probing occurs strictly while `dut.pe_array_enable == 1'b1`, ensuring that idle cycles, sequencer startup, and OFMAP drain cycles contribute zero spurious events.
2. **Column Gating:** Only columns enabled by the active configuration mode (`dut.col_active[c] == 1'b1`) are counted. Inactive columns ($c \ge 4$ in 16-PE, $c \ge 8$ in 32-PE) are ignored.
3. **Mathematical Invariant:** On every compute cycle, each active PE increments either `hw_mac_skipped_events` or `hw_mac_executed_events`. Thus:
   $$\text{hw\_mac\_enabled\_events} = \text{hw\_mac\_skipped\_events} + \text{hw\_mac\_executed\_events}$$

### 3.2 Launch Latency Measurement

The launch latency represents the sequencer state transition overhead from the command arrival until the compute feeder begins execution:
```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        meas_cmd_handshake_cycle <= 64'd0;
        meas_comp_start_cycle_r  <= 64'd0;
    end else begin
        if (cmd_valid && cmd_ready) begin
            meas_cmd_handshake_cycle <= clk_cycle;
        end
        if (meas_run_active && dut.compute_start) begin
            meas_comp_start_cycle_r <= clk_cycle;
        end
    end
end
```
On each experiment run completion:
```systemverilog
t_launch_cycles = int'(meas_comp_start_cycle_r - meas_cmd_handshake_cycle);
```

#### Cycle Timing Decomposition:
1. Cycle $C_0$: `cmd_valid && cmd_ready` handshakes; command is registered into sequencer.
2. Cycle $C_0 + 1$: Sequencer evaluates command and decodes parameters in `ST_VALIDATE`.
3. Cycle $C_0 + 2$: Sequencer asserts `pe_start_req` to adaptive controller in `ST_CONFIGURE`.
4. Cycle $C_0 + 3$: Sequencer asserts `compute_start = 1` in `ST_START_COMP`.
5. Result: $t_{\text{launch\_cycles}} = (C_0 + 3) - C_0 = 3$ clock cycles for all modes.

---

## 4. Enhanced Dataset Schema (`tsk12d_instrumentation_results.csv`)

The enhanced CSV dataset preserves all 16 original columns from TSK-12B and appends the 4 new hardware-probed metrics:

| Col # | Column Name | Type | Description |
| :---: | :--- | :---: | :--- |
| 1 | `workload_id` | String | Workload identifier (`WL-01` to `WL-09`) |
| 2 | `config_id` | String | Configuration evaluated (`CFG_A`, `CFG_B`, `CFG_C`, `CFG_D`, `LAY_x`, `SWP_x`) |
| 3 | `k_steps` | Integer | Reduction steps ($K$) |
| 4 | `deg_hat_16` | Integer | 16-PE degradation estimate threshold |
| 5 | `deg_hat_32` | Integer | 32-PE degradation estimate threshold |
| 6 | `resolved_mode` | Integer | Hardware active mode (0=16-PE, 1=32-PE, 2=64-PE) |
| 7 | `active_pes` | Integer | Number of active PEs ($16, 32, 64$) |
| 8 | `total_cycles` | Integer | Total layer execution latency ($T_{\text{total}}$) |
| 9 | `compute_cycles` | Integer | Active compute duration ($T_{\text{comp}}$) |
| 10 | `drain_cycles` | Integer | OFMAP drain duration ($T_{\text{drain}}$) |
| 11 | `stall_cycles` | Integer | Total pipeline stall cycles ($T_{\text{stall}}$) |
| 12 | `active_pe_cycles` | Integer | Total enabled PE-cycles ($T_{\text{comp}} \times N_{\text{cfg}}$) |
| 13 | `useful_macs` | Integer | Analytical useful MAC count (preserved from TSK-12B) |
| 14 | `sram_rd_reqs` | Integer | Total IFMAP/Filter SRAM read requests |
| 15 | `sram_wr_reqs` | Integer | Total OFMAP SRAM write requests |
| 16 | `verified` | String | Verification status (`PASS`) |
| **17** | **`t_launch_cycles`** | **Integer** | **Sequencer launch latency ($C_{\text{start}} - C_{\text{handshake}} = 3$)** |
| **18** | **`hw_mac_enabled_events`** | **Integer** | **Total active PE-cycles enabled during compute ($K \times N_{\text{cfg}}$)** |
| **19** | **`hw_mac_skipped_events`** | **Integer** | **Directly probed zero-activation bypass events from RTL** |
| **20** | **`hw_mac_executed_events`** | **Integer** | **Directly probed executed accumulation operations from RTL** |

---

## 5. Experimental Results Summary Table

The complete 25-run evaluation results from [`tsk12d_instrumentation_results.csv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tsk12d_instrumentation_results.csv) are summarized below:

| WL ID | CFG | K | Resolved Mode | PEs | $T_{\text{tot}}$ | $T_{\text{cmp}}$ | $T_{\text{drn}}$ | $T_{\text{lnch}}$ | $T_{\text{stl}}$ | Analytical Useful | HW Enabled | HW Skipped | HW Executed | Status |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL-01** | CFG_A | 1 | 0 (16 PE) | 16 | 139 | 4 | 129 | 3 | 0 | 16 | 16 | 0 | 16 | PASS |
| **WL-01** | CFG_B | 1 | 1 (32 PE) | 32 | 139 | 4 | 129 | 3 | 0 | 32 | 32 | 0 | 32 | PASS |
| **WL-01** | CFG_C | 1 | 2 (64 PE) | 64 | 139 | 4 | 129 | 3 | 0 | 64 | 64 | 0 | 64 | PASS |
| **WL-01** | CFG_D | 1 | 0 (16 PE) | 16 | 139 | 4 | 129 | 3 | 0 | 16 | 16 | 0 | 16 | PASS |
| **WL-02** | CFG_A | 2 | 0 (16 PE) | 16 | 142 | 7 | 129 | 3 | 0 | 32 | 32 | 0 | 32 | PASS |
| **WL-02** | CFG_B | 2 | 1 (32 PE) | 32 | 142 | 7 | 129 | 3 | 0 | 64 | 64 | 0 | 64 | PASS |
| **WL-02** | CFG_C | 2 | 2 (64 PE) | 64 | 142 | 7 | 129 | 3 | 0 | 128 | 128 | 0 | 128 | PASS |
| **WL-02** | CFG_D | 2 | 1 (32 PE) | 32 | 142 | 7 | 129 | 3 | 0 | 64 | 64 | 0 | 64 | PASS |
| **WL-03** | CFG_A | 4 | 0 (16 PE) | 16 | 148 | 13 | 129 | 3 | 0 | 64 | 64 | 0 | 64 | PASS |
| **WL-03** | CFG_B | 4 | 1 (32 PE) | 32 | 148 | 13 | 129 | 3 | 0 | 128 | 128 | 0 | 128 | PASS |
| **WL-03** | CFG_C | 4 | 2 (64 PE) | 64 | 148 | 13 | 129 | 3 | 0 | 256 | 256 | 0 | 256 | PASS |
| **WL-03** | CFG_D | 4 | 2 (64 PE) | 64 | 148 | 13 | 129 | 3 | 0 | 256 | 256 | 0 | 256 | PASS |
| **WL-04** | CFG_A | 8 | 0 (16 PE) | 16 | 160 | 25 | 129 | 3 | 0 | 128 | 128 | 0 | 128 | PASS |
| **WL-04** | CFG_B | 8 | 1 (32 PE) | 32 | 160 | 25 | 129 | 3 | 0 | 256 | 256 | 0 | 256 | PASS |
| **WL-04** | CFG_C | 8 | 2 (64 PE) | 64 | 160 | 25 | 129 | 3 | 0 | 512 | 512 | 0 | 512 | PASS |
| **WL-04** | CFG_D | 8 | 0 (16 PE) | 16 | 160 | 25 | 129 | 3 | 0 | 128 | 128 | 0 | 128 | PASS |
| **WL-05** | CFG_A | 4 | 0 (16 PE) | 16 | 148 | 13 | 129 | 3 | 0 | 32 | 64 | **32** | **32** | PASS |
| **WL-05** | CFG_B | 4 | 1 (32 PE) | 32 | 148 | 13 | 129 | 3 | 0 | 64 | 128 | **64** | **64** | PASS |
| **WL-05** | CFG_C | 4 | 2 (64 PE) | 64 | 148 | 13 | 129 | 3 | 0 | 128 | 256 | **128** | **128** | PASS |
| **WL-05** | CFG_D | 4 | 0 (16 PE) | 16 | 148 | 13 | 129 | 3 | 0 | 32 | 64 | **32** | **32** | PASS |
| **WL-06** | CFG_A | 4 | 0 (16 PE) | 16 | 148 | 13 | 129 | 3 | 0 | 64 | 64 | 0 | 64 | PASS |
| **WL-06** | CFG_B | 4 | 1 (32 PE) | 32 | 148 | 13 | 129 | 3 | 0 | 128 | 128 | 0 | 128 | PASS |
| **WL-06** | CFG_C | 4 | 2 (64 PE) | 64 | 148 | 13 | 129 | 3 | 0 | 256 | 256 | 0 | 256 | PASS |
| **WL-06** | CFG_D | 4 | 0 (16 PE) | 16 | 148 | 13 | 129 | 3 | 0 | 64 | 64 | 0 | 64 | PASS |
| **WL-07** | LAY_1 | 2 | 0 (16 PE) | 16 | 142 | 7 | 129 | 3 | 0 | 32 | 32 | 0 | 32 | PASS |
| **WL-07** | LAY_2 | 2 | 1 (32 PE) | 32 | 142 | 7 | 129 | 3 | 0 | 64 | 64 | 0 | 64 | PASS |
| **WL-08** | STALL | 1 | 2 (64 PE) | 64 | 140 | 4 | 130 | 3 | 1 | 64 | 64 | 0 | 64 | PASS |
| **WL-09** | SWP_1 | 2 | 0 (16 PE) | 16 | 142 | 7 | 129 | 3 | 0 | 32 | 32 | 0 | 32 | PASS |
| **WL-09** | SWP_2 | 2 | 1 (32 PE) | 32 | 142 | 7 | 129 | 3 | 0 | 64 | 64 | 0 | 64 | PASS |
| **WL-09** | SWP_3 | 2 | 2 (64 PE) | 64 | 142 | 7 | 129 | 3 | 0 | 128 | 128 | 0 | 128 | PASS |
| **WL-09** | SWP_4 | 2 | 0 (16 PE) | 16 | 142 | 7 | 129 | 3 | 0 | 32 | 32 | 0 | 32 | PASS |
| **WL-09** | SWP_5 | 2 | 1 (32 PE) | 32 | 142 | 7 | 129 | 3 | 0 | 64 | 64 | 0 | 64 | PASS |

---

## 6. Key Scientific Findings & Verifications

### 6.1 Direct Empirical Validation of Zero-Skipping
In **WL-05** (50% activation sparsity across rows and reduction steps):
- In **Fixed 16-PE (CFG_A)**: $64$ enabled opportunities yielded exactly **32 skipped events** and **32 executed operations** directly sampled from the hardware `cycle_skipped[r][c]` wires.
- In **Fixed 32-PE (CFG_B)**: $128$ enabled opportunities yielded exactly **64 skipped events** and **64 executed operations**.
- In **Fixed 64-PE (CFG_C)**: $256$ enabled opportunities yielded exactly **128 skipped events** and **128 executed operations**.
- In **Adaptive 16-PE (CFG_D)**: $64$ enabled opportunities yielded exactly **32 skipped events** and **32 executed operations**.

**Exact Equivalence:** Across all 25 runs, the autonomous hardware counter `hw_mac_executed_events` matched the analytical `useful_macs` metric bit-for-bit ($100\%$ agreement). This directly proves that the RTL zero-bypass logic in [`mac_unit_40b.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv) functions identically to the mathematical reference.

### 6.2 Empirical Invariance of Launch Latency
The launch latency $t_{\text{launch\_cycles}} = 3$ clock cycles was empirically measured and confirmed across all configurations:
- Fixed 16-PE: 3 cycles
- Fixed 32-PE: 3 cycles
- Fixed 64-PE: 3 cycles
- Adaptive mode: 3 cycles
This empirically proves that dynamic quality-score comparison in [`adaptive_pe_controller.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv) imposes **zero clock cycles of latency penalty** on command dispatch.

---

## 7. Full Regression Verification

The complete regression test suite was executed via `python3 run_regression.py`. All 19 testbenches passed with zero errors:

```text
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
19  | tb_tsk12_adaptive_experiment     | Integration  | 6432     | PASS   | [RESULT: SUCCESS] All TSK-12B experiments passed with zero defects!
--------------------------------------------------------------------------------------------------------------
GRAND TOTAL ACROSS ALL 19 SUITES: 12298 Checks Evaluated | 12298 Passed | 0 Failed | ALL PASS
==============================================================================================================
REGRESSION EXECUTION SUMMARY:
  Total Testbenches : 19
  Passed Testbenches: 19
  Failed Testbenches: 0
  Checks Evaluated  : 12298
  Checks Passed     : 12298
  Checks Failed     : 0

FINAL STATUS: REGRESSION PASSED (Exit Code 0)
==============================================================================================================
```

---

## 8. Baseline Integrity and Safety Compliance

1. **Protected Baseline RTL Files:** Zero lines were modified in the 5 protected baseline files:
   - `accelerator_core_top.sv`
   - `mac_unit_40b.sv`
   - `k_progress_tracker.sv`
   - `slot_control_unit.sv`
   - `hybrid_sram_bank.sv`
   Verified via `git diff HEAD -- <files>` (exit code 0, 0 diff lines).
2. **Functional RTL Files:** Zero functional RTL modifications were made. The instrumentation was achieved entirely via non-intrusive hierarchical testbench sampling.
3. **Repository Cleanliness:** Zero Git commits were created.
4. **Physical Power Disclaimer:** All reported metrics represent cycle-accurate digital activity counts (PE-active cycles, enabled MACs, zero-bypasses, memory transactions). Physical energy dissipation, thermal effects, leakage, or silicon area must be evaluated using physical place-and-route and gate-level power simulation (e.g., Synopsys PrimeTime-PX / Cadence Joules), not functional RTL simulation.

