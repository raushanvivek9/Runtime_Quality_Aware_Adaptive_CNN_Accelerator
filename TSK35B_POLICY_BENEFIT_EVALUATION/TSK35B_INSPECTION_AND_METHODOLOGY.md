# TSK-35B: Phase 1 Inspection & Experimental Methodology

## 1. Executive Summary

The objective of milestone **TSK-35B** is to evaluate whether the transparent adaptive resource allocation policies developed in TSK-33 and corrected in TSK-35A provide measurable operational benefits over fixed 16-, 32-, and 64-PE hardware configurations.

This milestone is an **empirical evaluation and validation task**, not a redesign task. It strictly maintains:
1. Zero modifications to the five protected baseline RTL files.
2. Complete numerical fidelity and bit-exact reproducibility across all evaluated CNN workloads.
3. Strict separation of dense and sparse execution regimes to prevent attributing sparsity savings to PE allocation adaptation.
4. Objective measurement of hardware cycles, SRAM read/write transactions, compute switching activity, and latency constraint satisfaction.

---

## 2. Phase 1: Repository & Workload Audit

### 2.1 Audit of Existing Infrastructure
The following components were audited prior to benchmarking:
- **Policy Controller:** [`TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv`](file:///e:/MTech/LanChain/MTP/TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv)
  - Latency parameters: `LATENCY_16PE_CYCLES = 38225`, `LATENCY_32PE_CYCLES = 19121`, `LATENCY_64PE_CYCLES = 9569`.
  - Safety correction (TSK-35A): For $P_{\text{max}} < 16$, asserts `invalid_pe_limit = 1`, deasserts `execution_enable = 0`, sets `resolved_pe_mode = 2'b11` and `active_pe_count = 0`.
  - Policy A (`policy_select = 0`): Selects minimum active PE configuration meeting $L \le L_{\text{budget}}$ and $P \le P_{\text{max}}$.
  - Policy B (`policy_select = 1`): Selects maximum throughput configuration permitted by $P \le P_{\text{max}}$.
- **Hardware Execution Engine:** [`TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tsk30_multi_workload_engine.sv`](file:///e:/MTech/LanChain/MTP/TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tsk30_multi_workload_engine.sv)
  - Cycle-accurate RTL integration of 16 physical MAC units (40-bit accumulators), spatial tile sequencer, and accumulation controller.
  - Telemetry instrumentation for total cycles, compute cycles, overhead cycles, SRAM activation reads, SRAM weight reads, and output writes.
- **Tensors & Workload Provenance:** [`TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/`](file:///e:/MTech/LanChain/MTP/TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/)
  - Quantized INT16 tensors extracted from validated PyTorch model checkpoints.

### 2.2 Workload Audit Matrix

| Workload ID | Model | Layer | Input Channels ($C_{\text{in}}$) | Output Channels ($C_{\text{out}}$) | Spatial Tiles | Reduction Depth ($K$) | Total MACs | Activation Sparsity | Input Act Hex | Weight Hex | Golden Reference Hex |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL1** | ResNet-18 (CIFAR-10) | `layer1.0.conv1` | 64 | 16 | 4x4 (16 tiles) | 576 | 147,456 | **68.89%** (6,349 / 9,216 zeros) | `WL1_act.hex` | `WL1_wt.hex` | `WL1_golden.hex` |
| **WL2** | ResNet-18 (CIFAR-100) | `layer1.0.conv1` | 64 | 16 | 4x4 (16 tiles) | 576 | 147,456 | **66.57%** (6,135 / 9,216 zeros) | `WL2_act.hex` | `WL2_wt.hex` | `WL2_golden.hex` |
| **WL3** | VGG-16-BN (CIFAR-10) | `features.3` | 64 | 16 | 4x4 (16 tiles) | 576 | 147,456 | **48.11%** (4,434 / 9,216 zeros) | `WL3_act.hex` | `WL3_wt.hex` | `WL3_golden.hex` |
| **WL4** | ResNet-18 (CIFAR-10) | `layer2.1.conv2` | 64 | 16 | 4x4 (16 tiles) | 576 | 147,456 | **84.92%** (7,826 / 9,216 zeros) | `WL4_act.hex` | `WL4_wt.hex` | `WL4_golden.hex` |

All four workloads maintain identical convolution geometry ($4 \times 4$ spatial grid, 16 output channels, 576 reduction depth), allowing completely fair, unskewed comparisons.

---

## 3. Phase 2: Experimental Design & Comparison Protocol

To ensure fair comparisons:
1. **Identical Datapath & Arithmetic:**
   - All configurations execute through the identical 40-bit MAC units, identical accumulator registers, and identical saturating arithmetic logic.
   - Numerical correctness requires **zero output mismatches** ($\Delta = 0$) across all 256 output elements ($16\text{ positions} \times 16\text{ channels}$) against the golden reference.
2. **Dense vs. Sparse Disaggregation:**
   - Fixed modes and policy-directed runs are evaluated in both **Dense** and **Sparse** regimes.
   - Sparse execution enables dynamic zero-activation skipping. Dense execution processes every operand regardless of value.
   - Sparsity benefits (e.g. weight memory read savings) are attributed solely to activation zero-skipping, never to PE allocation policies.
3. **Configurations Evaluated per Workload:**
   - **Baseline 1:** Fixed 16-PE Dense & Sparse (4 passes, 38,225 cycles).
   - **Baseline 2:** Fixed 32-PE Dense & Sparse (2 passes, 19,121 cycles).
   - **Baseline 3:** Fixed 64-PE Dense & Sparse (1 pass, 9,569 cycles).
   - **Policy A (Min-Resource):** Dynamically allocates the smallest PE mode that satisfies both $L \le L_{\text{budget}}$ and $P \le P_{\text{max}}$.
   - **Policy B (Min-Latency):** Dynamically allocates the fastest PE mode permitted by $P \le P_{\text{max}}$.

---

## 4. Phase 3: Constraint Space Specification

The evaluation sweeps 140 constraint scenarios per workload:

### 4.1 Latency Budgets ($L_{\text{budget}}$)
Ten discrete points targeting exact hardware execution thresholds:
- **Around 64-PE Latency (9,569 cycles):**
  1. $L_{\text{budget}} = 9,568$ (Infeasible for all modes)
  2. $L_{\text{budget}} = 9,569$ (Exact 64-PE threshold)
  3. $L_{\text{budget}} = 9,570$ (Feasible for 64-PE only)
- **Around 32-PE Latency (19,121 cycles):**
  4. $L_{\text{budget}} = 19,120$ (Infeasible for 32-PE; feasible for 64-PE)
  5. $L_{\text{budget}} = 19,121$ (Exact 32-PE threshold)
  6. $L_{\text{budget}} = 19,122$ (Feasible for 32-PE and 64-PE)
- **Around 16-PE Latency (38,225 cycles):**
  7. $L_{\text{budget}} = 38,224$ (Infeasible for 16-PE; feasible for 32-PE and 64-PE)
  8. $L_{\text{budget}} = 38,225$ (Exact 16-PE threshold)
  9. $L_{\text{budget}} = 38,226$ (Feasible for all valid modes)
- **Relaxed Latency Budget:**
  10. $L_{\text{budget}} = 100,000$ (Generous budget; permits maximum resource conservation)

### 4.2 Active PE Caps ($P_{\text{max}}$)
Seven discrete points covering invalid, valid, and unconstrained allocations:
- **Invalid Safety Caps (TSK-35A verification):**
  1. $P_{\text{max}} = 0$
  2. $P_{\text{max}} = 8$
  3. $P_{\text{max}} = 15$
- **Valid Operational Caps:**
  4. $P_{\text{max}} = 16$ (Allows only 16-PE)
  5. $P_{\text{max}} = 32$ (Allows 16-PE or 32-PE)
  6. $P_{\text{max}} = 64$ (Allows 16-PE, 32-PE, or 64-PE)
  7. $P_{\text{max}} = 128$ (Unconstrained; allows up to full 64-PE array)

### 4.3 Total Parameter Combinations
$$\text{Scenarios per Workload} = 10\text{ (Budgets)} \times 7\text{ (PE Caps)} \times 2\text{ (Policies)} = 140\text{ scenarios}$$
Across all 4 workloads, a total of **560 policy evaluations** plus **24 fixed baseline runs** (6 per workload) are executed and tracked.

