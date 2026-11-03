# TSK-35B: Adaptive Resource Allocation Policy Benefit Evaluation Report

**Project:** Neural_Acc — Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Repository Location:** `E:\MTech\LanChain\MTP`  
**Milestone:** TSK-35B  
**Evaluation Status:** **COMPLETED (560 Policy Evaluations, 24 Baseline Runs, 100% Verified, Zero Mismatches)**  

---

## 1. Executive Summary

Milestone **TSK-35B** evaluates whether the transparent adaptive resource allocation policies developed in TSK-33 and hardened in TSK-35A provide measurable benefits over fixed 16-, 32-, and 64-PE hardware configurations.

Using cycle-accurate RTL simulation with the actual 40-bit MAC datapath, multi-bank SRAM subsystem, spatial tile sequencer, and four validated real-model CNN workloads (ResNet-18 CIFAR-10, ResNet-18 CIFAR-100, VGG-16 CIFAR-10, and ResNet-18 Deep Conv), this study conducted:
1. **24 Fixed-Mode Baseline Characterizations** across Dense and Sparse regimes ($4\text{ workloads} \times 3\text{ modes} \times 2\text{ regimes}$).
2. **560 Dynamic Policy Evaluations** spanning 10 latency budgets ($L_{\text{budget}} \in [9568, 100000]$) and 7 PE caps ($P_{\text{max}} \in [0, 128]$) for Policy A (Min-Resource) and Policy B (Min-Latency).
3. **100% Numerical Verification** against deterministic software golden references: **0 mismatches** across all 256 output elements for every run.
4. **Safety Gating Verification:** All 240 requests with $P_{\text{max}} < 16$ ($P_{\text{max}} = 0, 8, 15$) were positively blocked with `execution_enable = 0`, `resolved_pe_mode = 2'b11`, and 0 compute cycles.

---

## 2. Experimental Methodology & Metric Definitions

### 2.1 Evaluated Workloads

| Workload ID | Model | Layer | Input Channels ($C_{\text{in}}$) | Output Channels ($C_{\text{out}}$) | Reduction Depth ($K$) | Activation Sparsity | Weight SRAM Reads (Dense) | Weight SRAM Reads (Sparse) | Sparsity Reduction |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL1** | ResNet-18 (CIFAR-10) | `layer1.0.conv1` | 64 | 16 | 576 | **68.89%** | 147,456 | 45,872 | **-68.89%** |
| **WL2** | ResNet-18 (CIFAR-100) | `layer1.0.conv1` | 64 | 16 | 576 | **66.57%** | 147,456 | 49,296 | **-66.57%** |
| **WL3** | VGG-16-BN (CIFAR-10) | `features.3` | 64 | 16 | 576 | **48.11%** | 147,456 | 76,512 | **-48.11%** |
| **WL4** | ResNet-18 (CIFAR-10) | `layer2.1.conv2` | 64 | 16 | 576 | **84.92%** | 147,456 | 22,240 | **-84.92%** |

### 2.2 Mathematical Formulas Used

1. **Active PE Hardware Reduction Percentage:**
   $$\text{PE Savings Pct} = \left( \frac{64 - P_{\text{active}}}{64} \right) \times 100\%$$
2. **Execution Latency Speedup:**
   $$\text{Speedup} = \frac{\text{Total Cycles}_{\text{Baseline}}}{\text{Total Cycles}_{\text{Candidate}}}$$
3. **Weight SRAM Read Reduction Percentage:**
   $$\text{Wt SRAM Reduction Pct} = \left( \frac{\text{Wt Reads}_{\text{Dense}} - \text{Wt Reads}_{\text{Sparse}}}{\text{Wt Reads}_{\text{Dense}}} \right) \times 100\%$$
4. **SRAM Traffic Increase Percentage (Multi-Pass Overhead):**
   $$\text{Traffic Increase Pct} = \left( \frac{\text{SRAM Accesses}_{\text{Mode}} - \text{SRAM Accesses}_{64\text{PE}}}{\text{SRAM Accesses}_{64\text{PE}}} \right) \times 100\%$$
5. **Execution Time ($T_{\text{exec}}$) from Clock Period ($T_{\text{clk}} = 10.0\text{ ns}$):**
   $$T_{\text{exec}} = \text{Total Cycles} \times 10.0\text{ ns}$$

---

## 3. Detailed Answers to Core Evaluation Questions

### Question 1: Does Policy A reduce the number of active PEs while satisfying the latency budget?
**Answer: YES, under feasible relaxed budgets.**
- When $L_{\text{budget}} \ge 38,225$ cycles (the 16-PE execution latency), Policy A selects **16-PE mode**, deactivating 48 of the 64 physical PEs (**75.0% active PE hardware reduction**), while strictly meeting the latency budget ($38,225 \le L_{\text{budget}}$).
- When $19,121 \le L_{\text{budget}} \le 38,224$ cycles, Policy A selects **32-PE mode**, deactivating 32 of the 64 physical PEs (**50.0% active PE hardware reduction**), meeting the deadline in 19,121 cycles.
- Only when $9,569 \le L_{\text{budget}} \le 19,120$ cycles does Policy A allocate the full 64 PEs (0% reduction).
- Across all valid requests ($P_{\text{max}} \ge 16$), Policy A achieved:
  - 16-PE selection: **47.50%** of valid evaluations (76 / 160)
  - 32-PE selection: **32.50%** of valid evaluations (52 / 160)
  - 64-PE selection: **20.00%** of valid evaluations (32 / 160)
- **Conclusion:** Policy A dynamically throttles active hardware to the absolute minimum necessary to satisfy the latency constraint.

---

### Question 2: Does Policy B achieve the minimum measured latency within the permitted PE cap?
**Answer: YES, Policy B is latency-optimal with respect to $P_{\text{max}}$.**
- Policy B prioritizes execution speed by greedily selecting the fastest hardware configuration allowed by the active PE limit:
  - When $P_{\text{max}} \ge 64$: Policy B selects **64-PE mode** (9,569 cycles, $95.69\ \mu\text{s}$), achieving a **$3.995\times$ speedup** over 16-PE and **$1.998\times$ speedup** over 32-PE.
  - When $32 \le P_{\text{max}} < 64$: Policy B selects **32-PE mode** (19,121 cycles, $191.21\ \mu\text{s}$), achieving a **$1.999\times$ speedup** over 16-PE.
  - When $16 \le P_{\text{max}} < 32$: Policy B selects **16-PE mode** (38,225 cycles, $382.25\ \mu\text{s}$).
- Across all valid requests ($P_{\text{max}} \ge 16$), Policy B selected:
  - 64-PE mode: **50.00%** (80 / 160)
  - 32-PE mode: **25.00%** (40 / 160)
  - 16-PE mode: **25.00%** (40 / 160)
- **Conclusion:** Policy B always achieves the lowest possible latency permitted by the host's resource ceiling.

---

### Question 3: How often does either policy select the same configuration as a fixed-mode baseline?
**Breakdown across all 560 evaluated scenarios (280 per policy):**

| Selected Configuration | Policy A Count (Pct of Total) | Policy A Pct of Valid ($P_{\text{max}} \ge 16$) | Policy B Count (Pct of Total) | Policy B Pct of Valid ($P_{\text{max}} \ge 16$) |
| :--- | :---: | :---: | :---: | :---: |
| **Fixed 16-PE Mode** | 76 (27.14%) | **47.50%** | 40 (14.29%) | **25.00%** |
| **Fixed 32-PE Mode** | 52 (18.57%) | **32.50%** | 40 (14.29%) | **25.00%** |
| **Fixed 64-PE Mode** | 32 (11.43%) | **20.00%** | 80 (28.57%) | **50.00%** |
| **Blocked / Invalid Mode ($P_{\text{max}} < 16$)** | 120 (42.86%) | N/A | 120 (42.86%) | N/A |
| **Total** | 280 (100.0%) | 160 (100.0%) | 280 (100.0%) | 160 (100.0%) |

- Policy A converges to Fixed 16-PE most frequently (47.50% of valid requests), reflecting its resource-minimization objective.
- Policy B converges to Fixed 64-PE most frequently (50.00% of valid requests), reflecting its performance-maximization objective.

---

### Question 4: How often does a policy violate the latency budget?
**Answer: In exactly 32.50% of valid scenarios for both policies.**
- Across the 160 valid requests ($P_{\text{max}} \ge 16$):
  - **Policy A Budget Violations:** **52 / 160 (32.50%)**; `fallback_asserted` = **52 / 160 (32.50%)**.
  - **Policy B Budget Violations:** **52 / 160 (32.50%)**; `fallback_asserted` = **0 / 160 (0.00%)**.
- **Root Cause of Violations:**
  1. $L_{\text{budget}} = 9,568$ cycles: Infeasible for all modes, because the physical minimum latency of the accelerator on these workloads is 9,569 cycles ($9,216\text{ compute} + 353\text{ overhead}$).
  2. When $P_{\text{max}} = 32$, minimum attainable latency is 19,121 cycles. Any budget below 19,121 (9,568, 9,569, 9,570, 19,120) produces a violation.
  3. When $P_{\text{max}} = 16$, minimum attainable latency is 38,225 cycles. Any budget below 38,225 produces a violation.
- **Controller Behavior Difference:**
  - Under violation, Policy A asserts `fallback_asserted = 1` and selects the fastest permitted mode.
  - Policy B does not assert fallback (because it never falls back from an optimal choice), but accurately flags `budget_violation = 1`.

---

### Question 5: Does activation sparsity reduce total execution latency, or only compute activity and memory traffic?
**Answer: In this accelerator microarchitecture, activation sparsity does NOT reduce total execution latency. It exclusively reduces compute switching activity and weight memory traffic.**

#### Empirical Measurement Comparison:
| Workload | Sparsity Pct | PE Mode | Dense Total Cycles | Sparse Total Cycles | **Total Latency Delta** | Dense Compute Cycles | Sparse Compute Cycles | **Compute Cycle Reduction** | Dense Wt Reads | Sparse Wt Reads | **Wt Read Reduction** |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL1** | 68.89% | 64-PE | 9,569 | 9,569 | **0.00%** | 9,216 | 2,867 | **-68.89%** | 147,456 | 45,872 | **-68.89%** |
| **WL1** | 68.89% | 32-PE | 19,121 | 19,121 | **0.00%** | 18,432 | 5,734 | **-68.89%** | 147,456 | 45,872 | **-68.89%** |
| **WL1** | 68.89% | 16-PE | 38,225 | 38,225 | **0.00%** | 36,864 | 11,468 | **-68.89%** | 147,456 | 45,872 | **-68.89%** |
| **WL2** | 66.57% | 64-PE | 9,569 | 9,569 | **0.00%** | 9,216 | 3,081 | **-66.57%** | 147,456 | 49,296 | **-66.57%** |
| **WL3** | 48.11% | 64-PE | 9,569 | 9,569 | **0.00%** | 9,216 | 4,782 | **-48.11%** | 147,456 | 76,512 | **-48.11%** |
| **WL4** | 84.92% | 64-PE | 9,569 | 9,569 | **0.00%** | 9,216 | 1,390 | **-84.92%** | 147,456 | 22,240 | **-84.92%** |

- **Microarchitectural Cause:** The `spatial_tile_sequencer` and memory address generators step through all channel reduction chunks synchronously. When an activation is zero, the feeder suppresses the MAC enable strobe and weight SRAM read strobe, but the sequencer pipeline cycle is preserved.
- **Benefit:** Dynamic switching activity in the MAC multipliers and weight SRAM read energy are reduced by up to **84.92%**, but execution throughput is governed strictly by the PE mode.

---

### Question 6: What additional SRAM traffic results from using 16 or 32 PEs instead of 64?
**Answer: Using 16 or 32 PEs significantly INCREASES total SRAM traffic due to activation re-reading across multi-pass channel tiling.**

#### Empirical SRAM Access Telemetry (Sparse Regime):
| Workload | Mode | Channel Passes | Activation SRAM Reads | Act Read Increase vs 64-PE | Weight SRAM Reads | Output Writes | Total SRAM Accesses | **Total SRAM Access Increase vs 64-PE** |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL1** | 64-PE | 1 | 9,216 | 0.0% | 45,872 | 256 | 55,344 | **0.00% (Baseline)** |
| **WL1** | 32-PE | 2 | 18,432 | **+100.0%** (+9,216) | 45,872 | 256 | 64,560 | **+16.65%** |
| **WL1** | 16-PE | 4 | 36,864 | **+300.0%** (+27,648) | 45,872 | 256 | 82,992 | **+49.96%** |
| **WL2** | 64-PE | 1 | 9,216 | 0.0% | 49,296 | 256 | 58,768 | **0.00% (Baseline)** |
| **WL2** | 32-PE | 2 | 18,432 | **+100.0%** (+9,216) | 49,296 | 256 | 67,984 | **+15.68%** |
| **WL2** | 16-PE | 4 | 36,864 | **+300.0%** (+27,648) | 49,296 | 256 | 86,416 | **+47.05%** |
| **WL3** | 64-PE | 1 | 9,216 | 0.0% | 76,512 | 256 | 85,984 | **0.00% (Baseline)** |
| **WL3** | 32-PE | 2 | 18,432 | **+100.0%** (+9,216) | 76,512 | 256 | 95,200 | **+10.72%** |
| **WL3** | 16-PE | 4 | 36,864 | **+300.0%** (+27,648) | 76,512 | 256 | 113,632 | **+32.15%** |
| **WL4** | 64-PE | 1 | 9,216 | 0.0% | 22,240 | 256 | 31,712 | **0.00% (Baseline)** |
| **WL4** | 32-PE | 2 | 18,432 | **+100.0%** (+9,216) | 22,240 | 256 | 40,928 | **+29.06%** |
| **WL4** | 16-PE | 4 | 36,864 | **+300.0%** (+27,648) | 22,240 | 256 | 59,360 | **+87.18%** |

- **Key Architectural Trade-Off:** While 16-PE mode reduces instantaneous active MAC logic by 75%, it incurs a **+300% increase in activation memory traffic** and up to **+87.18% increase in total SRAM access count**.

---

### Question 7: Which policy is preferable under each constraint scenario?

| Operating Scenario | Constraints ($L_{\text{budget}}, P_{\text{max}}$) | Preferred Policy | Justification |
| :--- | :--- | :---: | :--- |
| **Real-Time / Low Latency** | $L_{\text{budget}} \le 9,570$, $P_{\text{max}} \ge 64$ | **Policy B** | Policy B selects 64-PE mode, completing the convolution in 9,569 cycles ($95.69\ \mu\text{s}$). |
| **Balanced / Edge Compute** | $19,121 \le L_{\text{budget}} < 38,225$, $P_{\text{max}} \ge 32$ | **Policy A** | Policy A selects 32-PE mode, conserving 50% PE logic while strictly meeting the deadline in 19,121 cycles. |
| **Ultra-Low Peak Power / Wearable** | $L_{\text{budget}} \ge 38,225$, $P_{\text{max}} \ge 16$ | **Policy A** | Policy A selects 16-PE mode, deactivating 75% of PE columns to minimize peak inrush current. |
| **Resource-Capped Infeasible** | $L_{\text{budget}} < 19,121$, $P_{\text{max}} = 32$ | **Policy B** | Policy B achieves the lowest attainable latency (19,121 cycles) and reports deadline miss transparently. |
| **Invalid / Unsafe Request** | $P_{\text{max}} < 16$ ($P_{\text{max}} = 0, 8, 15$) | **Both (TSK-35A)** | Both policies assert `invalid_pe_limit = 1`, deassert `execution_enable = 0`, and block execution safely. |

---

## 4. Phase 5: Resource & Energy Disclosures

In compliance with project specifications:
- **Implemented Physical PE Count:** **64 PEs** ($16\text{ columns} \times 4\text{ PEs per column}$).
- **Active PE Count:** Dynamically allocated as **0** (blocked), **16**, **32**, or **64**.
- **Clock Period ($T_{\text{clk}}$):** **10.0 ns** (100.0 MHz).
- **Physical Silicon Energy:** **NOT MEASURED (MODEL-BASED ESTIMATE NOT AVAILABLE)**.
  > [!WARNING]
  > As proven in Section 3 (Question 6), lower active PE counts do **not** imply lower total energy. While active PE logic is gated, the execution duration is $2\times$ or $4\times$ longer, and SRAM activation reads increase by $+100\%$ or $+300\%$. Physical energy savings can only be verified through post-layout gate-level power simulation with characterized standard cell libraries.

---

## 5. Phase 6: Numerical Correctness & Safety Verification

1. **Software Golden Reference Scoreboarding:**
   - 24 baseline runs $\times 256\text{ outputs} = 6,144\text{ verified elements}$.
   - Number of mismatches across all workloads and modes: **strictly 0 mismatches**.
   - Maximum absolute error: **0**.
2. **TSK-35A Safety Enforcement:**
   - Evaluated across 240 invalid requests ($P_{\text{max}} \in \{0, 8, 15\}$).
   - In 100% of cases:
     - `invalid_pe_limit = 1'b1`
     - `execution_enable = 1'b0`
     - `resolved_pe_mode = 2'b11`
     - `active_pe_count = 8'd0`
     - Downstream compute start strobe was blocked: **0 cycles executed**.
3. **Single-Cycle Dynamic Recovery:**
   - When immediately followed by a valid request ($P_{\text{max}} \ge 16$), the controller restored `invalid_pe_limit = 0` and `execution_enable = 1` in exactly 1 clock cycle without latch-up.

---

## 6. Generated Evidence & Artifact Inventory

- [`TSK35B_ALL_SCENARIOS_MEASURED.csv`](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_ALL_SCENARIOS_MEASURED.csv): Complete log of 560 policy evaluations.
- [`TSK35B_BASELINE_MEASURED.csv`](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_BASELINE_MEASURED.csv): Full hardware telemetry for all 24 baseline runs.
- [`TSK35B_POLICY_BENEFIT_SUMMARY.csv`](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_POLICY_BENEFIT_SUMMARY.csv): Paired comparative analysis of Policy A vs Policy B.
- [`TSK35B_SPARSITY_VS_DENSE.csv`](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_SPARSITY_VS_DENSE.csv): Disaggregated dense vs sparse execution breakdown.
- [`TSK35B_SRAM_TRAFFIC_ANALYSIS.csv`](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_SRAM_TRAFFIC_ANALYSIS.csv): Multi-pass activation memory read penalty analysis.
- [`TSK35B_POLICY_DECISION_DISTRIBUTION.csv`](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_POLICY_DECISION_DISTRIBUTION.csv): Statistical mode distribution table.
- [`tb_tsk35b_policy_benefit.sv`](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/tb_tsk35b_policy_benefit.sv): Verified cycle-accurate SystemVerilog testbench.

