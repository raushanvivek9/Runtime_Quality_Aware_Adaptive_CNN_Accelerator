# TSK-32: Experimental Limitations and Methodological Boundaries

**Project**: Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Document**: Limitations, Evidence Gaps, and Threats to Validity  
**Date**: November 3, 2026  
**Auditor**: Independent Degradation Estimator Verification Agent  

---

## 1. Overview of Identified Limitations

This document transparently outlines the limitations, experimental assumptions, and architectural boundaries uncovered during the **TSK-32 Adaptive Degradation Estimator Validation**.

Scientific rigor demands clearly distinguishing what has been proven from what is not modeled, not instrumented, or fundamentally decoupled in the current accelerator implementation.

---

## 2. Primary Methodological & Architectural Limitations

### 2.1 Decoupling of Estimator Assumptions from RTL Microarchitecture

| Dimension | Historical Estimator Assumption | Physical RTL Implementation Reality |
| :--- | :--- | :--- |
| **Operational Meaning of "16-PE"** | Pruned to 16 channels (75% channels dropped) | Multi-pass tiling: 4 passes of 16 channels (100% computed) |
| **Operational Meaning of "32-PE"** | Pruned to 32 channels (50% channels dropped) | Multi-pass tiling: 2 passes of 32 channels (100% computed) |
| **Predicted Degradation ($\hat{D}_{mode}$)** | Non-zero (1.5% to 37.4% accuracy drop) | Non-zero values passed into command descriptors |
| **Actual Measured Degradation ($D_{\text{actual}}$)**| High accuracy drop under channel pruning | **Strictly 0.000000% error across all modes** |

#### The Consequence: Overly Conservative Allocation Rate (75%)
Because the estimates passed to the controller are derived from lossy channel pruning:
- In **WL1** and **WL2**, the controller rejected 16-PE mode because $\hat{D}_{16} > 0.05$. In reality, 16-PE mode in the RTL produces the exact same numerical result with **0.00% degradation**!
- In **WL3**, the controller asserted fallback to 64-PE because $\hat{D}_{32} = 0.0885 > 0.05$. In reality, 16-PE and 32-PE modes in the RTL both have **0.00% degradation**!
- Across the 4 workloads, **3 of 4 decisions (75.0%) were overly conservative**, causing the accelerator to consume more instantaneous active PEs than necessary.

---

### 2.2 Absence of On-Chip Hardware Degradation Estimator

> [!CAUTION]
> **Zero On-Chip Measurement Capability:**
> The `Neural_Acc` accelerator core top-level, PE array, and controllers contain **no on-chip loss monitors, no output feature error checkers, and no statistical profiling circuitry**.
> 
> The system is strictly classified as **Externally Guided Adaptive Allocation**. Any claims in project documentation or academic publications that the hardware "autonomously senses network degradation and adapts" are scientifically unfounded. All degradation values must be computed offline by a host profiler or compiler.

---

### 2.3 Single-Layer Evaluation vs. Whole-Network Pipeline

1. **Evaluated Scope**:
   - The verified hardware datapath executes single representative $3 \times 3$ convolution layers (`layer1.0.conv1`, `features.3`, `layer2.1.conv2`).
2. **Missing Subsystems for Autonomous Full-Model Inference**:
   - The accelerator core does not include hardware activation functions (e.g. ReLU, SiLU).
   - The accelerator core does not include spatial pooling hardware (e.g. MaxPool, Global Average Pooling).
   - The accelerator core does not include residual shortcut adder hardware ($y = \mathcal{F}(x) + x$).
   - The accelerator core does not include fully connected classification head logic.
   - Whole-network classification accuracy was evaluated using a software wrapper feeding into the PyTorch network pipeline.

---

### 2.4 Evaluation Dataset Sample Size

1. **Current Scope**:
   - Model classification evaluations were performed using a deterministic 100-sample test set extracted from torchvision CIFAR-10 and CIFAR-100 (`cifar10_test100.pt`, `cifar100_test100.pt`).
2. **Threat to Statistical Generalization**:
   - While 100 samples provide a bit-exact, deterministic, and fast reproducibility check, formal academic evaluation on the full 10,000-image test sets is required to report statistical confidence intervals ($p < 0.05$).
   - Historical Stage 13 evaluations on the full 10,000-image test set confirm identical conclusions (baseline-preserving layerwise tiling achieves 0.00% accuracy drop across all 66 layers).

---

### 2.5 Dynamic Power and Timing Boundaries

1. **Switching Activity vs. Physical Power (mW)**:
   - Zero-skipping suppresses weight SRAM reads and gates multiplier inputs, reducing dynamic switching.
   - However, physical power (in mW) and total energy (in Joules) cannot be extracted from functional RTL simulations without gate-level netlists, standard cell PDKs, and parasitics (SPEF).
2. **Latency vs. Area Trade-off**:
   - Multi-pass execution in 16-PE and 32-PE modes eliminates numerical degradation, but **multiplies latency by $4\times$ or $2\times$**, and **multiplies activation SRAM read volume by $4\times$ or $2\times$**.
   - Adaptive mode must be understood as an **instantaneous power/resource throttle**, not as a latency accelerator.

---

## 3. Recommendations for Next Milestones

1. **Re-align Degradation Estimators**: Update host descriptors so degradation metrics accurately reflect the true multi-pass architecture rather than legacy channel-pruning assumptions.
2. **Define Multi-Objective Cost Function**: Formulate $D_{\text{MAX}}$ as a multi-variable constraint incorporating both latency tolerance and instantaneous power budgets:
   $$\min P \quad \text{s.t.} \quad T_{\text{layer}}(P) \le T_{\text{target}} \quad \text{and} \quad \Delta \text{Acc} \le D_{\text{MAX}}$$
3. **Silicon Synthesis**: Synthesize the core in TSMC 28nm or SkyWater 130nm to measure real silicon area ($\mu\text{m}^2$) and dynamic power consumption.
