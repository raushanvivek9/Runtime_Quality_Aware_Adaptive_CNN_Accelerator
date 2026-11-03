# TSK-31 Evidence Gaps and Limitations Document

**Project**: Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Milestone**: TSK-31 Independent Reproducibility and Adaptive-Policy Audit  
**Date**: November 3, 2026  
**Auditor**: Independent Reproducibility & Verification Agent  

---

## 1. Purpose of this Document

This document transparently delineates the experimental, physical, microarchitectural, and systemic boundaries of the evidence gathered across TSK-28, TSK-29, TSK-30, and replicated in TSK-31.

While the numerical correctness, cycle counts, memory access reductions, and adaptive state machine decisions have been **100% independently reproduced**, scientific rigor requires identifying what is **not** proven or instrumented by the current RTL test infrastructure.

---

## 2. Classification of Claims and Evidence Status

| Claim / Phenomenon | Experimental Status | Limitations & Boundary Conditions |
| :--- | :--- | :--- |
| **Numerical Correctness (Diff = 0 across 7,168 outputs)** | `INDEPENDENTLY_REPRODUCED` | Fully validated against deterministic software floating/fixed-point references. |
| **Weight SRAM Read Reduction (48.11% – 84.92%)** | `INDEPENDENTLY_REPRODUCED` | Perfectly matches activation sparsity. Validated at RTL interface level. |
| **Zero-Gating Dynamic Switching Reduction** | `INDEPENDENTLY_REPRODUCED` | Operand gating verified in RTL. Exact 1:1 match with activation zero-rate. |
| **Adaptive Mode Selection Logic** | `INDEPENDENTLY_REPRODUCED` | FSM correctly selects smallest safe mode or falls back to 64-PE. |
| **Latency Speedup from Sparse Execution** | `NOT_REPRODUCED` / `INAPPLICABLE` | Architecture does **not** compress cycles; sparse and dense modes take identical cycles. |
| **Silicon Area Reduction from Reduced-PE Modes** | `NOT_TESTABLE_WITH_CURRENT_INSTRUMENTATION` | 64 physical PEs remain fabricated. Reduced modes disable PEs, not silicon area. |
| **Physical Energy (mJ) and Power (mW) Savings** | `NOT_TESTABLE_WITH_CURRENT_INSTRUMENTATION` | SRAM reads and switching are proxies; real power requires gate-level SPEF synthesis. |
| **On-Chip Maximum Frequency ($f_{max}$ / Timing Slack)** | `NOT_TESTABLE_WITH_CURRENT_INSTRUMENTATION` | Behavioral and RTL simulations do not include standard-cell wire delays or parasitics. |
| **Autonomous On-The-Fly Degradation Measurement** | `NOT_REPRODUCED` / `MISCLASSIFIED` | Hardware does not compute accuracy drop; it is an **externally guided** controller. |
| **End-to-End Network Latency and Energy** | `NOT_TESTABLE_WITH_CURRENT_INSTRUMENTATION` | Evaluates single representative convolution layers, not complete multi-layer pipelines. |

---

## 3. Detailed Evidence Gaps

### 3.1. Physical Metric Gaps: Area, Power, and Timing

1. **Active PE Count Reduction $\ne$ Silicon Area Reduction**:
   - In 16-PE mode, 75% of the processing elements are gated off (`active_pe_count = 16`).
   - In 32-PE mode, 50% of the processing elements are gated off (`active_pe_count = 32`).
   - **Gap**: The physical chip contains 64 physical MAC units, their pipeline registers, and accumulator structures. Gating 48 PEs (in 16-PE mode) eliminates dynamic switching power in those units, but does **not** reduce fabricated silicon die area or leakage power. Any paper or report must avoid claiming silicon area savings unless reconfigurable or multi-core spatial partitioning is physically synthesized.

2. **SRAM Read Reduction $\ne$ Total Physical Energy Reduction**:
   - Weight SRAM reads are reduced by 48.11% to 84.92% across workloads.
   - **Gap**: Total chip energy includes clock tree distribution, SRAM static leakage, activation SRAM reads, accumulator register energy, control FSM logic, and off-chip DRAM transfers.
   - Crucially, multi-pass channel tiling in reduced-PE modes causes **activation read volume inflation**:
     - 64-PE mode requires **9,216** activation reads (1 pass).
     - 32-PE mode requires **18,432** activation reads (2 passes, $2.0\times$ increase).
     - 16-PE mode requires **36,864** activation reads (4 passes, $4.0\times$ increase).
   - In workloads with high activation read energy, the overhead of re-reading activations multiple times from SRAM can partially or completely offset the energy saved by weight gating!

3. **Absence of Standard Cell Synthesis and Parasitics**:
   - Current verifications are conducted in Icarus Verilog RTL simulation.
   - Operating frequency ($f_{max}$), setup/hold timing margin, wire congestion, and dynamic power in milliwatts ($P_{dyn} = \alpha C V^2 f$) cannot be reported until physical synthesis (e.g. Synopsys Design Compiler or OpenROAD with TSMC 28nm/SkyWater 130nm PDK) is conducted.

---

### 3.2. Microarchitectural Gaps: Latency vs. Throughput Trade-Off

1. **Absence of Zero-Skipping Cycle Compaction**:
   - In Neural_Acc, when an activation is zero, the sparse feeder suppresses the weight SRAM read and gates the MAC multiplier operand.
   - However, the spatial accumulation controller advances by exactly one cycle per reduction step.
   - **Consequence**: Dense and sparse modes execute in **identical total cycles**:
     - 16-PE Dense: 38,225 cycles | 16-PE Sparse: 38,225 cycles (Speedup = $1.0000\times$)
     - 32-PE Dense: 19,121 cycles | 32-PE Sparse: 19,121 cycles (Speedup = $1.0000\times$)
     - 64-PE Dense: 9,569 cycles  | 64-PE Sparse: 9,569 cycles  (Speedup = $1.0000\times$)
   - Sparsity yields **energy efficiency and power reduction**, but **zero execution time speedup**. To achieve speedup, the architecture would require an asynchronous compaction buffer or index-matching FIFO crossbar.

2. **Adaptive PE Allocation is an Area/Power Throttle, NOT a Speedup Mechanism**:
   - Compared to the baseline 64-PE configuration:
     - 32-PE mode takes $19,121$ cycles ($1.9982\times$ longer).
     - 16-PE mode takes $38,225$ cycles ($3.9947\times$ longer).
   - The adaptive engine chooses smaller PE modes when accuracy allows it, deliberately accepting a $2\times$ or $4\times$ latency penalty in exchange for reducing instantaneous active computing units (50% or 75% fewer active PEs).
   - Adaptive mode must be documented as an **energy-delay or resource trade-off mechanism**, never as a latency optimization.

---

### 3.3. Algorithmic and System Classification Gaps

1. **Externally Guided vs. Autonomous Adaptive Allocation**:
   - The term "adaptive PE allocation" could be misinterpreted as an autonomous on-chip hardware mechanism that monitors activation distributions or gradient error during execution.
   - **Reality**: The hardware accelerator implements an **externally guided adaptive controller**.
   - Offline profiling evaluates the network on a validation set and calculates the relative accuracy drop $\hat{D}_{mode}$ for each PE configuration, encoded in Q16.16 format.
   - The host driver passes these precomputed descriptors to the accelerator.
   - The hardware controller performs the final deterministic threshold check:
     $$\text{mode} = \begin{cases} 
     \text{16-PE}, & \text{if } \hat{D}_{16} \le D_{max} \\
     \text{32-PE}, & \text{else if } \hat{D}_{32} \le D_{max} \\
     \text{64-PE}, & \text{otherwise (fallback)}
     \end{cases}$$
   - This architectural classification is accurate, robust, and reproducible, but must be explicitly documented to prevent misconceptions about hardware autonomy.

---

### 3.4. Workload and Network Scope Gaps

1. **Single-Layer Workloads vs. Whole Networks**:
   - The evaluation tests 4 convolution layer instances across ResNet-18 and VGG-16-BN.
   - Network layers not evaluated on the RTL datapath include:
     - Pointwise $1\times 1$ convolutions (e.g. shortcut downsampling projections).
     - Residual skip additions ($y = \mathcal{F}(x) + x$).
     - Batch normalization folding variations.
     - Spatial Pooling (Max-Pooling, Global Average Pooling).
     - Dense classification head (Fully Connected linear layer).
   - Complete network inference latency and accuracy cannot be directly asserted from these single-layer RTL runs.

---

## 4. Summary of Recommendations for Future Milestones

1. **Implement Physical Synthesis Flow**: Synthesize `tsk30_multi_workload_engine.sv` with standard cell libraries to extract true silicon area ($\mu\text{m}^2$) and standard-cell power (mW).
2. **Explore Cycle-Compacting Sparsity**: If latency reduction is desired from sparsity, incorporate a leading-zero detection FIFO to skip inactive cycles.
3. **Add On-Chip Activation Buffer**: Implement a dedicated line buffer or caching SRAM to eliminate the $2\times$ to $4\times$ activation re-reading penalty in multi-pass channel tiling.
4. **Maintain Terminology Integrity**: Consistently describe the adaptive engine as "externally guided adaptive allocation" in all publications and project reports.

