# TSK-31: Independent Reproducibility and Adaptive-Policy Audit

**Project**: Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Document**: Final Audit & Reproducibility Report  
**Date**: November 3, 2026  
**Auditor**: Independent Reproducibility & Verification Agent  
**Audit Scope**: TSK-28 Complete Convolution, TSK-29 Adaptive PE Evaluation, and TSK-30 Multi-Workload Validation  

---

## 1. Executive Summary & Audit Scorecard

This independent audit rigorously verifies the empirical claims, numerical correctness, memory access telemetry, and control policies reported in TSK-29 and TSK-30 for the **Neural_Acc** accelerator.

The audit was conducted strictly under non-invasive constraints: **zero modifications to protected baseline RTL files**, **zero Git commits**, and **independent regeneration of all stimulus, golden references, and simulation telemetry**.

### Audit Verdict Summary
- **Total Configurations Evaluated**: 28 configurations across 4 real CNN workloads (ResNet-18 CIFAR-10 `layer1.0.conv1`, ResNet-18 CIFAR-100 `layer1.0.conv1`, VGG-16-BN CIFAR-10 `features.3`, and ResNet-18 CIFAR-10 `layer2.1.conv2`).
- **Reproducibility Pass Rate**: **28 / 28 Configurations (100.0%) Verified as `INDEPENDENTLY_REPRODUCED`**.
- **Numerical Correctness**: **7,168 / 7,168 Output Elements Rechecked with Diff = 0** ($\text{MAE} = 0.000000$, $\text{RMSE} = 0.000000$, $\text{Max Absolute Error} = 0$).
- **Sparsity Telemetry Reconciliation**: Exact 1:1 bit-level match between activation zero rate and weight SRAM read suppression across all workloads.
- **Master Regression Status**: **12,202 / 12,202 Checks Passed across 20 suites (100% Pass Rate)**.

### Acceptance Criteria Scorecard

| Milestone Criterion | Required Standard | Audited Result | Compliance Verdict |
| :--- | :--- | :--- | :---: |
| **1. Protected Baseline Integrity** | 0 diffs on 5 baseline files | 0 diffs; SHA-256 hashes cryptographically identical | **VERIFIED** |
| **2. Independent Stimulus Regeneration** | Bit-exact recreation of TSK-30 tensors | 12/12 tensor hex files matched bit-for-bit | **VERIFIED** |
| **3. Full Numerical Recheck** | 100% match against software reference | 7,168 / 7,168 outputs matched with Diff = 0 | **VERIFIED** |
| **4. Sparsity Telemetry Reconciliation** | Zero discrepancy in weight read reduction | 0.00% discrepancy across all 4 workloads | **VERIFIED** |
| **5. Adaptive Policy Classification** | Rigorous architectural classification | Confirmed as "Externally Guided Adaptive Allocation" | **VERIFIED** |
| **6. Performance Metric Recalculation** | Audited latency, reads, and throughput | All 28 configurations recalculated and reconciled | **VERIFIED** |
| **7. Regression Stability** | Zero regressions across repo | 12,202 / 12,202 checks passed (100%) | **VERIFIED** |

---

## 2. Protected Baseline RTL Integrity

The 5 protected baseline RTL files were verified using SHA-256 cryptographic hashes and `git status`/`git diff`:

| Protected Baseline File | Relative Path | Cryptographic SHA-256 Hash | Status |
| :--- | :--- | :--- | :---: |
| `accelerator_core_top.sv` | `phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv` | `067CF7B1630E2D8AE0D9933F17389C9D3915CFFA779750452E042C876042FBDB` | **0 diffs** |
| `mac_unit_40b.sv` | `phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv` | `A6B96ADA3B1E20EB69CC4FC19BD59B58319DE6F8A4C8CBCA9F8DD4ECF446F083` | **0 diffs** |
| `k_progress_tracker.sv` | `phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv` | `991BB938E92B5B4952DBC1C81D2557233D2A032B4D40AB89DBF3199E36D72612` | **0 diffs** |
| `slot_control_unit.sv` | `phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv` | `BFB8C58F432766B8B9B3FF833DA4D74D8AB1A0540CE4723FEC5A5324204959B6` | **0 diffs** |
| `hybrid_sram_bank.sv` | `phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv` | `4606A16A4F54A28A8B7AE718C95882EF205346508754C0E9CA5F1786798B2BBE` | **0 diffs** |

---

## 3. Workload Description & Stimulus Regeneration Audit

The 4 audited workloads were independently extracted from real pre-trained PyTorch checkpoints:
- **WL1**: ResNet-18 on CIFAR-10, `layer1.0.conv1` ($64 \times 64 \times 3 \times 3$, batch size 1).
- **WL2**: ResNet-18 on CIFAR-100, `layer1.0.conv1` ($64 \times 64 \times 3 \times 3$, batch size 1).
- **WL3**: VGG-16-BN on CIFAR-10, `features.3` ($64 \times 64 \times 3 \times 3$, batch size 1).
- **WL4**: ResNet-18 on CIFAR-10, `layer2.1.conv2` ($128 \times 128 \times 3 \times 3$, representative $64 \times 64$ channel slice).

### Tensor Cryptographic Hash Verification

All 12 regenerated tensor files in `TSK31_INDEPENDENT_REPRODUCIBILITY_AUDIT/tensors/` were hashed and compared against the upstream TSK-30 tensor files:

| Workload ID | Tensor Type | File Name | SHA-256 Match Status |
| :---: | :---: | :--- | :---: |
| WL1 | Activation | `wl1_act.hex` | **VERIFIED_BIT_EXACT** |
| WL1 | Weights | `wl1_wt.hex` | **VERIFIED_BIT_EXACT** |
| WL1 | Golden OFMAP | `wl1_golden.hex` | **VERIFIED_BIT_EXACT** |
| WL2 | Activation | `wl2_act.hex` | **VERIFIED_BIT_EXACT** |
| WL2 | Weights | `wl2_wt.hex` | **VERIFIED_BIT_EXACT** |
| WL2 | Golden OFMAP | `wl2_golden.hex` | **VERIFIED_BIT_EXACT** |
| WL3 | Activation | `wl3_act.hex` | **VERIFIED_BIT_EXACT** |
| WL3 | Weights | `wl3_wt.hex` | **VERIFIED_BIT_EXACT** |
| WL3 | Golden OFMAP | `wl3_golden.hex` | **VERIFIED_BIT_EXACT** |
| WL4 | Activation | `wl4_act.hex` | **VERIFIED_BIT_EXACT** |
| WL4 | Weights | `wl4_wt.hex` | **VERIFIED_BIT_EXACT** |
| WL4 | Golden OFMAP | `wl4_golden.hex` | **VERIFIED_BIT_EXACT** |

---

## 4. Activation Sparsity & Memory Telemetry Reconciliation

The audit analyzed all activation tensors to determine exact zero counts and compared them against the weight SRAM read telemetry captured by the hardware testbench.

### Reconciliation Table

| Workload ID | Workload Description | Total Act Elements | Exact Zero Count | Calculated Sparsity (%) | Dense Weight Reads | Sparse Weight Reads | Weight Read Reduction (%) | Telemetry Discrepancy |
| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL1** | ResNet-18 C10 L1Conv1 | 9,216 | 6,349 | **68.89%** | 147,456 | 45,872 | **68.89%** | **0.00%** |
| **WL2** | ResNet-18 C100 L1Conv1 | 9,216 | 6,135 | **66.57%** | 147,456 | 49,296 | **66.57%** | **0.00%** |
| **WL3** | VGG-16 C10 Features3 | 9,216 | 4,434 | **48.11%** | 147,456 | 76,512 | **48.11%** | **0.00%** |
| **WL4** | ResNet-18 C10 L2Conv2 | 9,216 | 7,826 | **84.92%** | 147,456 | 22,240 | **84.92%** | **0.00%** |

**Finding**: The sparsity reduction at the weight SRAM interface matches the mathematical zero rate of the input activations with **zero discrepancy (0.00%)**. Every zero activation completely suppresses its corresponding 16-, 32-, or 64-weight block read from SRAM.

---

## 5. Numerical Correctness Verification

All 28 configurations were simulated under Icarus Verilog (`iverilog -g2012`), and every output element was logged and compared against the 40-bit unquantized golden reference:
- Total Output Elements Evaluated: **7,168** (256 outputs per run $\times$ 28 configurations).
- **Exact Bit Matches**: **7,168 / 7,168 (100.0%)**.
- **Mismatches**: **0**.
- **Mean Absolute Error (MAE)**: **0.000000**.
- **Root Mean Squared Error (RMSE)**: **0.000000**.
- **Max Absolute Error**: **0**.

Every single accumulation across all 576 reduction steps per spatial pixel is identical between RTL and the software reference.

---

## 6. Adaptive Allocation Policy Audit

### Mathematical Definition of Degradation Estimates

In TSK-29 and TSK-30, degradation metrics are represented in standard **Q16.16 fixed-point format**, where the raw integer value divided by $2^{16} = 65,536$ represents the normalized accuracy degradation ($\hat{D}_{mode} = \text{Raw} / 65536.0$).
- Target Threshold $D_{max} = 3,277 \approx 0.0500$ ($5.0\%$ relative validation accuracy drop limit).
- The priority order is to select the smallest PE mode whose estimated degradation satisfies the threshold:
  1. If $\hat{D}_{16} \le D_{max}$, select **16-PE Mode** (Mode 0).
  2. Else if $\hat{D}_{32} \le D_{max}$, select **32-PE Mode** (Mode 1).
  3. Otherwise, select **64-PE Mode** (Mode 2) and assert `fallback_asserted = 1'b1`.

### Audited Decision Table

| Workload ID | $\hat{D}_{16}$ (Raw / Norm) | $\hat{D}_{32}$ (Raw / Norm) | $D_{max}$ (Raw / Norm) | Expected Mode | RTL Selected Mode | Fallback Asserted | Constraint Met? | Architectural Decision Rationale |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **WL1** | 16,000 (0.2441) | 1,000 (0.0153) | 3,277 (0.050) | 32-PE | **32-PE** | `1'b0` | **YES** | 16-PE exceeds $D_{max}$ (0.244 > 0.05); 32-PE passes (0.015 $\le$ 0.05). |
| **WL2** | 18,500 (0.2823) | 2,200 (0.0336) | 3,277 (0.050) | 32-PE | **32-PE** | `1'b0` | **YES** | 16-PE exceeds $D_{max}$ (0.282 > 0.05); 32-PE passes (0.034 $\le$ 0.05). |
| **WL3** | 24,500 (0.3738) | 5,800 (0.0885) | 3,277 (0.050) | 64-PE | **64-PE** | `1'b1` | **YES** | Both 16-PE and 32-PE violate $D_{max}$; controller safely triggers fallback. |
| **WL4** | 1,200 (0.0183) | 400 (0.0061) | 3,277 (0.050) | 16-PE | **16-PE** | `1'b0` | **YES** | 16-PE passes threshold (0.018 $\le$ 0.05); smallest safe mode selected. |

### Architectural Classification
The adaptive controller is classified as **Externally Guided Adaptive Allocation**:
- **Mechanism**: The hardware FSM does **not** dynamically profile loss or compute cosine distance on-chip. Instead, the host driver calculates $\hat{D}_{mode}$ during offline validation profiling and embeds the values in the workload descriptor packet.
- **Hardware Role**: The on-chip controller provides low-latency, deterministic mode resolution, channel-tiling reconfiguration, and defensive fallback handling.

---

## 7. Comprehensive 28-Configuration Audit Table

All 28 configurations were independently verified and matched bit-for-bit with original results:

| Config ID | WL | Configuration Name | Active PEs | Passes | Execution Cycles | Weight SRAM Reads | Act SRAM Reads | Mismatches | Status | Audit Classification |
| :---: | :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **1** | WL1 | Fixed_16PE_Dense | 16 | 4 | 38,225 | 147,456 | 36,864 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **2** | WL1 | Fixed_16PE_Sparse | 16 | 4 | 38,225 | 45,872 | 36,864 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **3** | WL1 | Fixed_32PE_Dense | 32 | 2 | 19,121 | 147,456 | 18,432 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **4** | WL1 | Fixed_32PE_Sparse | 32 | 2 | 19,121 | 45,872 | 18,432 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **5** | WL1 | Fixed_64PE_Dense | 64 | 1 | 9,569 | 147,456 | 9,216 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **6** | WL1 | Fixed_64PE_Sparse | 64 | 1 | 9,569 | 45,872 | 9,216 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **7** | WL1 | Adaptive_Sparse (32-PE) | 32 | 2 | 19,121 | 45,872 | 18,432 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **8** | WL2 | Fixed_16PE_Dense | 16 | 4 | 38,225 | 147,456 | 36,864 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **9** | WL2 | Fixed_16PE_Sparse | 16 | 4 | 38,225 | 49,296 | 36,864 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **10** | WL2 | Fixed_32PE_Dense | 32 | 2 | 19,121 | 147,456 | 18,432 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **11** | WL2 | Fixed_32PE_Sparse | 32 | 2 | 19,121 | 49,296 | 18,432 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **12** | WL2 | Fixed_64PE_Dense | 64 | 1 | 9,569 | 147,456 | 9,216 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **13** | WL2 | Fixed_64PE_Sparse | 64 | 1 | 9,569 | 49,296 | 9,216 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **14** | WL2 | Adaptive_Sparse (32-PE) | 32 | 2 | 19,121 | 49,296 | 18,432 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **15** | WL3 | Fixed_16PE_Dense | 16 | 4 | 38,225 | 147,456 | 36,864 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **16** | WL3 | Fixed_16PE_Sparse | 16 | 4 | 38,225 | 76,512 | 36,864 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **17** | WL3 | Fixed_32PE_Dense | 32 | 2 | 19,121 | 147,456 | 18,432 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **18** | WL3 | Fixed_32PE_Sparse | 32 | 2 | 19,121 | 76,512 | 18,432 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **19** | WL3 | Fixed_64PE_Dense | 64 | 1 | 9,569 | 147,456 | 9,216 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **20** | WL3 | Fixed_64PE_Sparse | 64 | 1 | 9,569 | 76,512 | 9,216 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **21** | WL3 | Adaptive_Sparse (64-PE) | 64 | 1 | 9,569 | 76,512 | 9,216 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **22** | WL4 | Fixed_16PE_Dense | 16 | 4 | 38,225 | 147,456 | 36,864 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **23** | WL4 | Fixed_16PE_Sparse | 16 | 4 | 38,225 | 22,240 | 36,864 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **24** | WL4 | Fixed_32PE_Dense | 32 | 2 | 19,121 | 147,456 | 18,432 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **25** | WL4 | Fixed_32PE_Sparse | 32 | 2 | 19,121 | 22,240 | 18,432 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **26** | WL4 | Fixed_64PE_Dense | 64 | 1 | 9,569 | 147,456 | 9,216 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **27** | WL4 | Fixed_64PE_Sparse | 64 | 1 | 9,569 | 22,240 | 9,216 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |
| **28** | WL4 | Adaptive_Sparse (16-PE) | 16 | 4 | 38,225 | 22,240 | 36,864 | 0 | PASS | `INDEPENDENTLY_REPRODUCED` |

---

## 8. Latency vs. Resource Trade-Off Recalculation

A key finding of this audit is that **adaptive PE allocation does not accelerate execution latency**:
1. **Clock Cycle Parity**: Sparse and dense modes take the identical number of clock cycles (e.g. 9,569 cycles in 64-PE mode). Sparsity saves dynamic switching power through zero-operand gating, but does not compress execution time because there is no asynchronous FIFO crossbar.
2. **Latency Penalty in Reduced Modes**:
   - 32-PE mode requires **19,121 cycles** ($1.9982\times$ latency compared to 64-PE).
   - 16-PE mode requires **38,225 cycles** ($3.9947\times$ latency compared to 64-PE).
3. **Activation Memory Read Overhead**:
   - Multi-pass tiling in 32-PE mode doubles activation reads ($2.0\times$, 18,432 reads).
   - Multi-pass tiling in 16-PE mode quadruples activation reads ($4.0\times$, 36,864 reads).
4. **Conclusion**: Adaptive allocation functions as an **instantaneous power/resource throttle**, trading inference throughput for a 50% or 75% reduction in active computing units.

---

## 9. Final Audit Verdict

The reproducibility audit concludes with a verdict of **APPROVED - INDEPENDENTLY REPRODUCED**:
- All 28 configurations execute cleanly with zero defects.
- All 7,168 output pixels replicate the software mathematical model bit-for-bit.
- All memory access telemetry matches activation sparsity exactly.
- The 5 protected baseline RTL files remain unaltered (0 diffs).
- Full 20-suite regression passed 100% (12,202 / 12,202 checks).

