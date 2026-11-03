# TSK-37: Accelerator Limitations and Open Research Questions

**Project:** Neural_Acc — Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Audit Date:** November 4, 2026  
**Audited Baseline:** RTL Phase 2 Step 1 + Autonomous Sequencer (TSK-28 to TSK-36)  

---

## 1. Executive Context

The `Neural_Acc` architecture is a cycle-accurate, parameterizable SystemVerilog hardware accelerator designed for activation-sparse convolutional neural network inference. Extensive empirical evaluation and independent audits (TSK-28 through TSK-37) confirm robust numerical accuracy, hardware interlocks, and dynamic clock gating. However, to maintain absolute scientific integrity and avoid paper rejection or overclaiming during peer review, all architectural boundaries, measurement limits, and trade-offs must be explicitly cataloged.

---

## 2. Workload Scope Limitations

### 2.1 Spatial Sub-Region Evaluation (4x4 Grid)
- **Evaluated Scope:** Each evaluated workload computes a **4x4 spatial output grid (16 tiles)** for **16 output channels** across an input reduction depth of **$K = 576$** ($3 \times 3$ kernel $\times 64$ input channels).
- **Total Arithmetic Operations:** Each run evaluates exactly $16 \text{ tiles} \times 16 \text{ Cout} \times 576 = 147,456$ MAC operations, yielding **256 40-bit output elements** per workload (1,024 elements across WL1–WL4).
- **Limitation:** A complete CIFAR-10 convolution layer for ResNet-18 has spatial dimensions of $32 \times 32$ (1,024 spatial positions) and 64 output channels. Processing an entire layer requires **64 sequential accelerator dispatch passes** managed by a host DMA/scheduler.
- **Publication Requirement:** Publications must **never** describe the tested 4x4 region as a "complete CNN layer" or "end-to-end inference." It must be characterized as a *"representative 4x4 spatial patch of convolutional channels."*

### 2.2 Lack of On-Chip Non-Linearities and Pooling
- The accelerator hardware contains only the dot-product MAC array, spatial accumulation tree, and multi-bank SRAM scratchpad.
- Non-linear activations (ReLU, BatchNorm) and spatial pooling (MaxPool, AvgPool) are modeled offline during host tensor preparation or downstream host CPU processing.

---

## 3. Microarchitectural & Performance Trade-Offs

### 3.1 Constant Latency Under Activation Sparsity (0.00% Speedup)
- **Empirical Measurement:** Across all 12 workload-mode configurations, total execution latency is **identical** between Dense and Sparse execution:
  - 64-PE Mode: Exactly **9,569 cycles** (Dense) vs **9,569 cycles** (Sparse) $\rightarrow$ **0.00% reduction**
  - 32-PE Mode: Exactly **19,121 cycles** (Dense) vs **19,121 cycles** (Sparse) $\rightarrow$ **0.00% reduction**
  - 16-PE Mode: Exactly **38,225 cycles** (Dense) vs **38,225 cycles** (Sparse) $\rightarrow$ **0.00% reduction**
- **Root Cause:** The `k_progress_tracker` and `slot_control_unit` advance synchronously across the 9 channel-chunks. When a zero-valued activation is detected by the sparse feeder, it deasserts the weight SRAM read enable and gates the MAC clock enable; it does **not** compress or skip the pipeline clock cycle.
- **Scientific Impact:** Sparsity serves purely as a **dynamic switching power reduction technique**, not a throughput accelerator. Any claim of "sparsity-driven speedup" in the current microarchitecture is scientifically invalid and refuted by RTL telemetry.

### 3.2 Memory Bandwidth Overhead of Multi-Pass Channel Tiling
- When active PEs are reduced from 64 to 32 or 16, the accelerator tiles the 16 output channels across multiple passes:
  - 64 PEs: 1 pass $\rightarrow$ 9,216 activation reads
  - 32 PEs: 2 passes $\rightarrow$ 18,432 activation reads (**+100.0% overhead**)
  - 16 PEs: 4 passes $\rightarrow$ 36,864 activation reads (**+300.0% overhead**)
- **Total SRAM Access Traffic:** For sparse WL1, total SRAM accesses increase from 12,343 (64-PE) to 21,559 (32-PE, +74.7%) and 39,991 (16-PE, +224.0%).
- **Trade-Off Summary:** Reducing active PEs cuts instantaneous arithmetic footprint, but substantially amplifies on-chip memory access volume.

---

## 4. Power and Energy Measurement Boundaries

### 4.1 Absence of Physical Silicon Measurements
- **Status:** **NOT MEASURED**.
- The repository does not include taped-out silicon power measurements, board-level shunt resistor telemetry, or gate-level VCD-driven power simulations (e.g., Synopsys PrimeTime PX, Cadence Joules) using characterized standard-cell libraries (e.g., TSMC 28nm/16nm).
- All reported power-related benefits are derived strictly from **cycle-accurate architectural switching counters** (MAC clock enable suppression and SRAM read enable suppression).

### 4.2 Inability to Claim Total Energy Reduction
- Net energy $E = \int P(t) dt \approx P_{\text{avg}} \times T_{\text{exec}}$.
- While active datapath power is reduced in 16-PE mode, execution time increases by **$4.0\times$** (38,225 vs 9,569 cycles), static leakage energy accumulates over $4.0\times$ longer duration, and activation SRAM memory reads increase by **$4.0\times$**.
- Therefore, claims that adaptive PE allocation "reduces total energy" are **unsubstantiated** and must be excised from manuscripts until full-chip physical power characterization is completed.

---

## 5. Adaptive Resource Allocation & Supervisor Dependencies

### 5.1 Host-Supervised Operation
- The `tsk33_transparent_policy_controller` requires host-provided inputs: `policy_select`, `latency_budget_cycles`, and `max_active_pe_limit`.
- It does **not** autonomously infer application-level frame deadlines, dynamically measure thermal throttling, or balance battery state of charge.

### 5.2 Decoupling of Historical Degradation Estimator
- As proven in TSK-32, the historical degradation estimator modeled channel pruning (which drops weights and permanently degrades accuracy).
- The actual RTL uses multi-pass tiling, which computes all terms across multiple cycles with **zero numerical loss** (MAE = 0.0). The policy controller operates strictly on latency deadlines and PE caps.

---

## 6. Open Research Questions Prior to Publication

1. **Compressed Sparse Pipelining:**
   - *Question:* Can an asynchronous queue or run-length encoding (RLE) buffer be integrated to collapse zero-activation cycles and achieve genuine wall-clock latency speedup?
   - *Challenge:* Requires non-blocking FIFO buffers, crossbar interconnects, and complex hazard resolution across parallel PEs.

2. **On-Chip Activation Stationarity Buffer:**
   - *Question:* Can a shared activation cache retain input activations across multiple channel passes, eliminating the +100% to +300% SRAM read penalty in 32-PE and 16-PE modes?

3. **ASIC Synthesis & Gate-Level Power Sign-Off:**
   - *Question:* What is the exact energy-per-MAC (pJ/MAC) and area footprint ($mm^2$) under commercial standard-cell libraries (e.g., TSMC 28nm HPC+)?

4. **Multi-Layer End-to-End Orchestration:**
   - *Question:* How does the accelerator interface with a system-level DMA engine and SoC bus (AXI4/Wishbone) to stream full CNN feature maps continuously?

---

## 7. Summary for Authors and Reviewers

| Claim Topic | Validated Status | Mandatory Reviewer Caveat |
| :--- | :--- | :--- |
| **Numerical Equivalence** | VERIFIED | Validated for 4x4 spatial patches with 16 channels, not full CNN models. |
| **Sparsity Switching Benefit** | VERIFIED | Eliminates 48.1% to 84.9% of weight reads and MAC clocks; latency is unchanged. |
| **Sparsity Latency Speedup** | REFUTED | 0.00% speedup; sequencing is synchronous. Do not claim latency improvement. |
| **Policy Determinism** | VERIFIED | 201/201 boundary cases match; safety interlocks positively block $P_{\max} < 16$. |
| **Total Energy Reduction** | NOT MEASURED | Memory amplification and longer runtime counteract gating; energy is unmeasured. |
| **Physical Implementation** | VERIFIED WITH LIMITATIONS | Validated at cycle-accurate RTL and preliminary synthesis; silicon tape-out is future work. |

