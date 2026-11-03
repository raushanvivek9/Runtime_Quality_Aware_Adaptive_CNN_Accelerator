# TSK-32: Mathematical Definition and Provenance of Degradation Estimates

**Project**: Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Document**: Degradation Definition, Fixed-Point Specification, and Historical Provenance  
**Date**: November 3, 2026  
**Auditor**: Independent Degradation Estimator Verification Agent  

---

## 1. Executive Summary

This document traces and defines the degradation estimates ($\hat{D}_{16}, \hat{D}_{32}, \hat{D}_{64}$) and the constraint threshold ($D_{\text{MAX}}$) utilized by the Neural_Acc adaptive processing element (PE) allocation controller across TSK-29, TSK-30, and audited in TSK-31 and TSK-32.

### Primary Audit Findings
1. **Zero On-Chip Estimation**: The Neural_Acc hardware datapath contains **no on-chip error estimator, no loss profiling circuit, and no statistical degradation measurement hardware**. All estimates enter the accelerator via external host command descriptor registers (`cmd_degradation_hat_*`).
2. **Fixed-Point Representation**: Degradation metrics are encoded as **unsigned 32-bit Q16.16 fixed-point numbers**, where the integer value divided by $2^{16} = 65,536$ represents the normalized fraction.
3. **Threshold Definition ($D_{\text{MAX}}$)**: The ratified threshold parameter `D_MAX_Q16 = 3277` represents a **$5.0003\%$ relative quality degradation limit** ($3,277 / 65,536 \approx 0.0500$).
4. **Historical Provenance of the Estimates**: The non-zero degradation numbers (e.g. $\hat{D}_{16} = 24.41\%$, $\hat{D}_{32} = 1.53\%$) originated from an early exploratory software simulation (`exp1/controller/generate_quality_dataset.py`) where reducing PE count was simulated as **lossy structured channel pruning** (dropping 50% or 75% of output channels).
5. **Architectural Divergence in Actual RTL**: In the actual RTL microarchitecture (TSK-21 through TSK-31), reduced-PE modes do **not** drop channels; they perform **multi-pass temporal channel tiling** (4 passes for 16-PE, 2 passes for 32-PE). Consequently, the actual RTL datapath produces **0.000000 numerical error** and **0.00% accuracy degradation** across all PE modes!

---

## 2. Signal Ingestion and Hardware Tap Points

The degradation estimates enter the accelerator top-level boundary and propagate combinatorially to the allocation comparator:

```mermaid
flowchart LR
    Host["Host Software / Testbench<br/>(Hardcoded in Descriptors)"] -->|cmd_degradation_hat_16<br/>cmd_degradation_hat_32<br/>cmd_degradation_hat_64| Seq["layer_command_sequencer.sv<br/>(Command Registers)"]
    Seq -->|degradation_hat_16<br/>degradation_hat_32<br/>degradation_hat_64| Ctrl["adaptive_pe_controller.sv<br/>(Priority Comparator)"]
    Ctrl -->|active_cfg_mode<br/>fallback_to_64| Engine["pe_array_40b.sv / Accumulator<br/>(16, 32, or 64 PEs Active)"]
```

### 2.1 RTL Port Signatures

In [`phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv#L15-L35):
```systemverilog
parameter int D_MAX_Q16 = 16'd3277; // Ratified Q16.16 threshold (0.0500 = 5.0%)

input  logic [31:0] degradation_hat_16, // Estimated degradation for 16-PE mode
input  logic [31:0] degradation_hat_32, // Estimated degradation for 32-PE mode
input  logic [31:0] degradation_hat_64, // Estimated degradation for 64-PE mode
```

In [`TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tsk30_multi_workload_engine.sv`](file:///e:/MTech/LanChain/MTP/TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tsk30_multi_workload_engine.sv#L44-L47):
```systemverilog
input  logic [31:0] degradation_hat_16,
input  logic [31:0] degradation_hat_32,
input  logic [31:0] degradation_hat_64,
input  logic [31:0] threshold_d_max,
```

---

## 3. Fixed-Point Format and Mathematical Normalization

All degradation values in the command descriptor are formatted in unsigned **Q16.16** fixed-point arithmetic:
- **Format**: 32-bit unsigned integer ($16$ integer bits, $16$ fractional bits).
- **Scale Factor**: $2^{16} = 65,536$.
- **Conversion Equation**:
  $$D_{\text{norm}} = \frac{\text{Raw Integer Value}}{65,536.0}$$
  $$\text{Raw Integer Value} = \text{round}(D_{\text{norm}} \times 65,536.0)$$

### Table 1: Raw Fixed-Point Values across Workloads

| Workload ID | Workload Name | $\hat{D}_{16}$ (Raw) | $\hat{D}_{16}$ (Norm) | $\hat{D}_{32}$ (Raw) | $\hat{D}_{32}$ (Norm) | $\hat{D}_{64}$ (Raw) | $\hat{D}_{64}$ (Norm) | $D_{\text{MAX}}$ (Raw) | $D_{\text{MAX}}$ (Norm) |
| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL1** | ResNet-18 C10 L1Conv1 | 16,000 | **0.2441** (24.41%) | 1,000 | **0.0153** (1.53%) | 0 | **0.0000** (0.00%) | 3,277 | **0.0500** (5.00%) |
| **WL2** | ResNet-18 C100 L1Conv1 | 18,500 | **0.2823** (28.23%) | 2,200 | **0.0336** (3.36%) | 0 | **0.0000** (0.00%) | 3,277 | **0.0500** (5.00%) |
| **WL3** | VGG-16 C10 Features3 | 24,500 | **0.3738** (37.38%) | 5,800 | **0.0885** (8.85%) | 0 | **0.0000** (0.00%) | 3,277 | **0.0500** (5.00%) |
| **WL4** | ResNet-18 C10 L2Conv2 | 1,200 | **0.0183** (1.83%) | 400 | **0.0061** (0.61%) | 0 | **0.0000** (0.00%) | 3,277 | **0.0500** (5.00%) |

---

## 4. Origin and Provenance of the Degradation Estimates

A forensic analysis of the codebase reveals how these estimates originated:

1. **Stage 1 Exploratory Software Proxy (`exp1/controller/generate_quality_dataset.py`)**:
   - Before Phase 2 hardware was designed, an early software prototype modeled hardware resource reduction using `ReducedConv2d` and `ReducedLinear`.
   - In that prototype, running at "16-PE" was simulated by **discarding 75% of the output channels** (`mask[:16] = 1.0; mask[16:] = 0.0`).
   - In that prototype, running at "32-PE" was simulated by **discarding 50% of the output channels** (`mask[:32] = 1.0; mask[32:] = 0.0`).
   - Discarding channels severely degraded model representation, producing high cross-entropy loss and measurable top-1 accuracy degradation (e.g. 15% to 85% drop).
2. **Migration into RTL Testbench Descriptors**:
   - When TSK-29 and TSK-30 were developed, the authors sought representative workloads to exercise all three branches of the adaptive controller:
     - Branch 1: Select 16-PE ($\hat{D}_{16} \le D_{\text{MAX}}$) $\rightarrow$ tested with WL4 (1,200 $\le$ 3,277).
     - Branch 2: Select 32-PE ($\hat{D}_{16} > D_{\text{MAX}}$ and $\hat{D}_{32} \le D_{\text{MAX}}$) $\rightarrow$ tested with WL1 and WL2.
     - Branch 3: Fallback to 64-PE ($\hat{D}_{32} > D_{\text{MAX}}$) $\rightarrow$ tested with WL3 (5,800 > 3,277).
   - The authors manually assigned these Q16.16 values in `prepare_tsk30_workloads.py` to reflect the intuitive concept that early layers and VGG layers are more sensitive than deep ResNet layers.

---

## 5. The Critical Architectural Divergence: Multi-Pass vs. Channel Pruning

The central scientific discovery of TSK-32 is the fundamental divergence between what the estimates assumed and what the hardware actually does:

| Feature / Property | Historical Software Proxy (`exp1`) | Actual Hardware Datapath (Phase 2 RTL) |
| :--- | :--- | :--- |
| **Execution Mechanism** | Dropped 48 of 64 channels (16-PE) or 32 channels (32-PE) | **Multi-Pass Tiling**: 4 passes $\times$ 16 PEs or 2 passes $\times$ 32 PEs |
| **Accumulator Depth** | Single pass, partial channels | **Multi-chunk accumulator preserves full sum across passes** |
| **Output Channel Count** | Truncated to 16 or 32 channels | **Computes all 64 output channels identically** |
| **Numerical Output Error** | High (missing channels zeroed) | **0.000000 (Bit-exact match to 40-bit unquantized golden)** |
| **Model Classification Degradation** | 10% to 85% accuracy drop | **0.00% accuracy drop (Identical inference predictions)** |

### Conclusion on Degradation Definition

In the physical RTL accelerator, **the degradation of 16-PE, 32-PE, and 64-PE modes is strictly zero ($0.000000$)**. 

The hardware adaptive allocation mechanism is formally classified as **Externally Guided Adaptive Allocation**. It does not measure degradation dynamically, and the non-zero degradation numbers supplied by the host reflect an obsolete channel-pruning assumption rather than any true numerical or model-accuracy loss in the multi-pass accelerator datapath.
