# TSK-30 In-Depth Performance & Architectural Analysis

## 1. Overview
This document delivers a rigorous microarchitectural and empirical analysis of the **TSK-30** multi-workload benchmark results across 28 evaluated hardware configurations, specifically addressing the five distinct research questions.

---

## 2. Research Question A: Benefit of Sparse vs. Dense Execution

> **Question**: What is the benefit of sparse execution compared with dense execution at the same PE count?

### Empirical Evidence Across Workloads:

| Workload | Activation Sparsity | Config Mode | Dense Weight Reads | Sparse Weight Reads | Weight SRAM Reduction | Dense Compute Cycles | Sparse Compute Cycles | Switching Reduction | Total Cycles (Both) |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL3 (VGG-16)** | **48.11%** | 64-PE | 147,456 | 76,512 | **48.11%** | 9,216 | 4,782 | **48.11%** | 9,569 |
| **WL2 (R18-C100)** | **66.57%** | 64-PE | 147,456 | 49,296 | **66.57%** | 9,216 | 3,081 | **66.57%** | 9,569 |
| **WL1 (R18-C10)** | **68.89%** | 64-PE | 147,456 | 45,872 | **68.89%** | 9,216 | 2,867 | **68.89%** | 9,569 |
| **WL4 (R18-Deep)** | **84.92%** | 64-PE | 147,456 | 22,240 | **84.92%** | 9,216 | 1,390 | **84.92%** | 9,569 |

### Microarchitectural Analysis:
1. **Linear Memory & Switching Benefits**:
   Across all four workloads, datapath zero-skipping yields an exact **1:1 percentage reduction** in weight SRAM read transactions and active MAC compute toggling that perfectly mirrors the activation sparsity of the layer (from 48.11% up to 84.92%).
2. **Cycle Invariance**:
   Total execution cycles remain identical between dense and sparse modes (e.g., 9,569 cycles in 64-PE across all workloads). Because the baseline architecture does not implement an asynchronous compaction queue or CSR index compaction, clock cycles for zero activations are spent in an idle/suppressed state.
3. **Silicon Implication**:
   Sparse execution provides substantial **dynamic power and energy savings** (by eliminating redundant weight SRAM fetches and suppressing multiplier switching activity), but **zero cycle latency reduction** in the current RTL architecture.

---

## 3. Research Question B: Latency vs. Resource Trade-Off Across Fixed Allocations

> **Question**: What is the latency/resource trade-off between fixed 16-, 32-, and 64-PE configurations?

### Comparative Metrics (Averaged across Workloads):

| Allocation Mode | Active PE Columns | Total Active PEs | Channel Passes ($C_{out}=16$) | Total Cycles | Latency Ratio vs. 64-PE | Relative Throughput | Active PE Reduction | Activation SRAM Reads |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Fixed 64-PE** | 16 | 64 | 1 | 9,569 | **$1.000\times$** | **100.0%** | **0.0%** | 9,216 |
| **Fixed 32-PE** | 8 | 32 | 2 | 19,121 | **$1.998\times$** | **50.04%** | **50.0%** | 18,432 |
| **Fixed 16-PE** | 4 | 16 | 4 | 38,225 | **$3.995\times$** | **25.03%** | **75.0%** | 36,864 |

### Microarchitectural Analysis:
1. **Near-Perfect $2\times$ Latency Scaling**:
   Transitioning from 64-PE to 32-PE halves active hardware (50.0% PE column reduction) while doubling latency ($1.9982\times$). Transitioning to 16-PE quarters active hardware (75.0% PE column reduction) while quadrupling latency ($3.9947\times$).
2. **Activation Re-Reading Overhead**:
   Because the accelerator does not feature an on-chip activation line buffer across passes, input activations must be re-read from activation SRAM for each channel pass:
   - 64-PE (1 pass): 9,216 activation reads
   - 32-PE (2 passes): 18,432 activation reads ($2.0\times$)
   - 16-PE (4 passes): 36,864 activation reads ($4.0\times$)
3. **Conclusion**:
   Reduced PE modes provide significant hardware resource deactivation (enabling power-gating, thermal management, or multi-tenant sharing) at the strict cost of proportional multi-pass execution latency.

---

## 4. Research Question C: Smallest PE Mode Selection by Adaptive Policy

> **Question**: Does adaptive allocation select the smallest PE mode that satisfies the validated degradation constraint?

### Empirical Controller Verification:
- **Workload WL4 (ResNet-18 Deep Layer `layer2.1.conv2`)**:
  - Offline degradation profile: $\hat{D}_{16} = 1200$ (0.0183), $\hat{D}_{32} = 400$ (0.0061), $\hat{D}_{64} = 0$, $D_{max} = 3277$ (0.0500).
  - Condition: $\hat{D}_{16} \le D_{max}$ ($1200 \le 3277$).
  - **Controller Decision**: Resolves to **`MODE_16PE`** (`active_pe_mode = 2'b00`, `fallback_asserted = 0`).
  - Active PE columns: 4 (16 PEs active, **75.0% hardware reduction**).
  - Channel passes: 4 passes.
  - Correctness: 256/256 exact bit-exact matches ($\text{MAE} = 0$, mismatches = 0).
- **Workload WL1 & WL2**:
  - $\hat{D}_{16} > D_{max}$, but $\hat{D}_{32} \le D_{max}$.
  - **Controller Decision**: Resolves to **`MODE_32PE`** (`active_pe_mode = 2'b01`, `fallback_asserted = 0`).
  - Active PE columns: 8 (32 PEs active, **50.0% hardware reduction**).

### Conclusion:
**YES**. The Stage 8A adaptive selection policy strictly prioritizes the smallest hardware allocation (16-PE before 32-PE, and 32-PE before 64-PE) that satisfies the configured degradation budget.

---

## 5. Research Question D: Fallback Behavior Under Unsatisfiable Constraints

> **Question**: Does the adaptive policy behave correctly when no smaller mode satisfies the constraint?

### Empirical Controller Verification:
- **Workload WL3 (VGG-16-BN Early Conv `features.3`)**:
  - Profile: $\hat{D}_{16} = 24500$ (0.3738), $\hat{D}_{32} = 5800$ (0.0885), $\hat{D}_{64} = 0$, $D_{max} = 3277$ (0.0500).
  - Condition Evaluation:
    - $\hat{D}_{16} \le D_{max} \implies 24500 \le 3277$ (**FALSE**)
    - $\hat{D}_{32} \le D_{max} \implies 5800 \le 3277$ (**FALSE**)
  - **Controller Decision**: Asserts **`fallback_asserted = 1'b1`** and resolves to **`MODE_64PE`** (`active_pe_mode = 2'b10`).
  - Hardware Execution: Configures 16 columns (64 PEs active), 1 pass, completing in 9,569 cycles.
  - Output Correctness: 256/256 exact bit-exact matches ($\text{MAE} = 0$, mismatches = 0).

### Conclusion:
**YES**. When task-level constraints cannot be satisfied by 16-PE or 32-PE allocations, the controller safely, deterministically, and conservatively falls back to the full 64-PE baseline, asserting the telemetry fallback flag to notify the host.

---

## 6. Research Question E: Controller Overhead of Adaptive Selection

> **Question**: How much controller overhead does adaptive selection add?

### Empirical Timing & Overhead Measurement:
1. **Combinational Mode Selection Latency**:
   The decision logic in `adaptive_pe_controller.sv` evaluates the priority comparison combinational network ($\hat{D}_{16} \le D_{max} \dots$) within the cycle that `start_req` is asserted. It adds **0 additional clock cycles** to the datapath setup.
2. **Layer Initialization Pipeline**:
   Latching the mode into `cfg_mode_q` and asserting `accum_clear` occurs during `ST_CLEAR` (1 cycle).
3. **Execution Overhead Cycles**:
   - In 64-PE mode: Overhead is **353 cycles** (tile setup and OFMAP drain) out of 9,569 cycles (**3.69%** of total execution).
   - In 32-PE mode: Overhead is **689 cycles** out of 19,121 cycles (**3.60%** of total execution).
   - In 16-PE mode: Overhead is **1,361 cycles** out of 38,225 cycles (**3.56%** of total execution).
4. **Adaptive vs. Fixed Overhead Comparison**:
   The overhead cycles in Adaptive mode are **identical to the corresponding Fixed mode** (e.g., Adaptive 32-PE in WL1 has 689 overhead cycles, exactly matching Fixed 32-PE).

### Conclusion:
Adaptive allocation adds **0 clock cycles of decision overhead** and introduces **zero throughput penalty** relative to a statically programmed layer of the same PE allocation.

