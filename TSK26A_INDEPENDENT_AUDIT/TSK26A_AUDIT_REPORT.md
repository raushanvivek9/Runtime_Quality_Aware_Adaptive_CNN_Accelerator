# TSK-26A Independent Verification Audit Report

**Date**: November 3, 2026  
**Auditor**: Independent Audit Subsystem  
**Target Milestone**: TSK-26A (Spatial Feature-Map Validation)  
**Target Model / Layer**: ResNet-18 `layer1.0.conv1`  
**Audit Status**: **AUDIT COMPLETE — CRITICAL LIMITATIONS AND MATHEMATICAL GAPS IDENTIFIED**  
**Classification**: **Category B+ (Spatial Subgrid with Truncated Kernel Fragment)** — *NOT a Complete 3×3 Convolution Feature Map (Category C)*

---

## 1. Executive Summary

An independent microarchitectural and mathematical audit of milestone **TSK-26A** was conducted to verify whether the implementation genuinely computes a complete $3 \times 3$ convolution feature map or a partial kernel-fragment workload.

### Primary Audit Verdict
1. **Mathematical Convolution Correctness (FAIL)**:
   - For a full $3 \times 3$ 2D convolution on ResNet-18 `layer1.0.conv1` with $C_{in}=64$ input channels, the reduction depth per spatial output coordinate is:
     $$K = C_{in} \times K_H \times K_W = 64 \times 3 \times 3 = 576 \text{ MAC operations}$$
   - The TSK-26A implementation executed **only $K=64$ reduction steps** per spatial output point ($64 / 576 = 11.11\%$ of the required reduction).
   - Because the im2col patch of shape $(64, 3, 3)$ was flattened in row-major order and truncated to the first 64 elements:
     - **Only 8 out of 64 input channels (Channels 0..7) contributed to the output**.
     - **Channels 8 through 63 (56 out of 64 channels, or 87.5% of the layer inputs) were completely omitted**.
     - For Channel 7, only a single kernel position `(0, 0)` was evaluated; the other 8 kernel positions were dropped.
     - The hardware and testbench did **not** orchestrate 9 iterative reduction passes to accumulate the 576 terms. Instead, PE accumulators were reset between tiles.

2. **Quantization & Numerical Reference (PASS WITH LIMITATIONS)**:
   - The hardware RTL datapath achieved **1,024 / 1,024 (100.0%) bit-exact integer matches** against the Python software reference (`full_layer_reference.py`). The RTL accurately executed the exact arithmetic modeled by the software script.
   - However, the reported quantization fidelity of **$\text{SQNR} = 86.60\text{ dB}$** was measured solely between a truncated 64-step fixed-point model and a truncated 64-step FP32 model.
   - When compared against the **true PyTorch full 2D convolution** ($K=576$), the actual output signal quality collapses to **$\text{SQNR} = 0.87\text{ dB}$** with $\text{MAE} = 4.6722$ and $\text{Max Absolute Error} = 19.3270$.

3. **Cross-Mode Performance Comparison (FAIL — NON-EQUIVALENT)**:
   - The reported latency and memory read metrics across 64-PE, 32-PE, and 16-PE modes were **non-equivalent**:
     - **64-PE mode** was run with the sparse feeder enabled (`cfg_sparse_feeder_en = 1'b1`), enabling all-zero activation skipping.
     - **32-PE mode** and **16-PE mode** were run with the sparse feeder disabled (`cfg_sparse_feeder_en = 1'b0`), forcing dense execution.
   - This confounded the performance penalty of PE array allocation with the activation sparsity optimization.

4. **Baseline RTL Integrity and Regressions (PASS)**:
   - All five protected baseline RTL files (`accelerator_core_top.sv`, `mac_unit_40b.sv`, `k_progress_tracker.sv`, `slot_control_unit.sv`, `hybrid_sram_bank.sv`) remain strictly untouched (**0 diffs**, verified via `git diff --exit-code`).
   - All 20 baseline regression testbenches passed (**12,202 / 12,202 checks passed, 0 failures**).
   - All 8 master unified regression suites passed (**8 / 8 suites passed, 0 failures**).
   - Zero Git commits were created.

---

## 2. Audit A: Mathematical Convolution Correctness

### Mathematical Derivation of Full Convolution
For a standard 2D convolution with input activation tensor $X \in \mathbb{R}^{1 \times C_{in} \times H_{in} \times W_{in}}$ and weight tensor $W \in \mathbb{R}^{C_{out} \times C_{in} \times K_H \times K_W}$, the activation at output channel $c_{out}$ and spatial position $(h, w)$ is given by:

$$Y[c_{out}, h, w] = \sum_{c=0}^{C_{in}-1} \sum_{kh=0}^{K_H-1} \sum_{kw=0}^{K_W-1} W[c_{out}, c, kh, kw] \cdot X_{pad}[c, h \cdot S + kh, w \cdot S + kw]$$

For ResNet-18 `layer1.0.conv1`:
- $C_{in} = 64$
- $K_H = 3, K_W = 3$
- $S = 1, P = 1$
- Inner product reduction length per activation:
  $$K_{true} = 64 \times 3 \times 3 = 576 \text{ terms}$$

### Root Cause Analysis in TSK-26A Implementation
In `TSK26A_FULL_LAYER_VALIDATION/full_layer_reference.py`, the im2col matrix was constructed as follows (lines 147–152):

```python
patch_int16 = act_pad_int16[0, :, h : h + K_h, w : w + K_w].reshape(-1)
for k in range(k_steps):  # k_steps was hardcoded to 64!
  im2col_int16[p_idx, k] = patch_int16[k % patch_int16.shape[0]]
```

When `act_pad_int16[0, :, h:h+3, w:w+3]` of shape `(64, 3, 3)` is flattened in NumPy's default C-contiguous order:
1. Slicing indices $0 \le k < 64$ samples:
   - Index `0 .. 8`: Channel 0, all 9 kernel positions `(0,0)` through `(2,2)`
   - Index `9 .. 17`: Channel 1, all 9 kernel positions `(0,0)` through `(2,2)`
   - Index `18 .. 26`: Channel 2, all 9 kernel positions `(0,0)` through `(2,2)`
   - Index `27 .. 35`: Channel 3, all 9 kernel positions `(0,0)` through `(2,2)`
   - Index `36 .. 44`: Channel 4, all 9 kernel positions `(0,0)` through `(2,2)`
   - Index `45 .. 53`: Channel 5, all 9 kernel positions `(0,0)` through `(2,2)`
   - Index `54 .. 62`: Channel 6, all 9 kernel positions `(0,0)` through `(2,2)`
   - Index `63`: Channel 7, **only kernel position `(0,0)`**
2. **Indices $64 \le k < 576$ are completely dropped**:
   - Channels 8 through 63 ($56 / 64 = 87.5\%$ of input channels) never entered the computation.
   - Positions `(0,1)` through `(2,2)` of Channel 7 were never evaluated.

### Hardware Execution Reality
- In `tb_tsk26a_full_layer_validation.sv`, each spatial tile executes a single command:
  `cmd_k_total = K_STEPS` (64).
- The PE array accumulators are cleared at the beginning of each tile (`apply_reset()`).
- There is **no multi-flit partial sum accumulation** across multiple 64-step chunks.
- **Verdict**: The accelerator evaluated 64 spatial coordinates and 16 channels, but each output point was an arbitrary 64-term truncated dot product, **not** a complete $3 \times 3$ convolution.

---

## 3. Audit B: Target-Model Provenance

The tensor provenance was audited against `TSK24_REAL_CNN_VALIDATION/export_cnn_tensors.py` and torchvision's official pretrained checkpoint:

| Property | Original Model / Layer | TSK-26A Workload | Audit Finding |
| :--- | :--- | :--- | :--- |
| **Model** | torchvision ResNet-18 | ResNet-18 (`IMAGENET1K_V1`) | **PASS** (Model verified) |
| **Layer Name** | `layer1.0.conv1` | `layer1.0.conv1` | **PASS** (Exact layer verified) |
| **Input Shape** | $[1, 64, 56, 56]$ | $[1, 64, 8, 8]$ | **PASS_WITH_LIMITATIONS** (Spatial slice: $64 / 3,136$ points, 2.04%) |
| **Weight Shape** | $[64, 64, 3, 3]$ | $[16, 64, 3, 3]$ | **PASS_WITH_LIMITATIONS** (Channel slice: $16 / 64$ output channels, 25.0%) |
| **Reduction Depth** | $K = 576$ ($64 \times 3 \times 3$) | $K = 64$ | **FAIL** (11.11% reduction depth; 87.5% input channels dropped) |
| **Input Generation**| ImageNet photos | Synthetic Gaussian ($\mu=0, \sigma=1$, seed 20261102) | **PASS_WITH_LIMITATIONS** (Deterministic pseudo-random forward pass) |
| **Workload Class** | Category C (Full Layer) | Category B+ (Subgrid Kernel Fragment) | **FAIL** (Cannot claim Category C full-layer completion) |

Detailed provenance records are stored in [`TSK26A_INDEPENDENT_AUDIT/TSK26A_TENSOR_PROVENANCE.csv`](file:///e:/MTech/LanChain/MTP/TSK26A_INDEPENDENT_AUDIT/TSK26A_TENSOR_PROVENANCE.csv).

---

## 4. Audit C: Numerical Reference & Quantization Recheck

### Software Model vs RTL Equivalence
The independent audit confirms that the RTL hardware datapath executed the exact operations prescribed by the software reference model:
- Total elements evaluated: **1,024 elements** (64 spatial points $\times$ 16 channels)
- Exact integer accumulator matches: **1,024 / 1,024 (100.0%)**
- Exact requantized output matches: **1,024 / 1,024 (100.0%)**
- Arithmetic errors: **0**
- $\text{MAE} = 0.0, \text{RMSE} = 0.0$

### True PyTorch Conv2D Recheck
When the 1,024 outputs computed by TSK-26A were independently compared against a true PyTorch `torch.nn.functional.conv2d` evaluation over the same $[1, 64, 8, 8]$ input and $[16, 64, 3, 3]$ weights:

| Numerical Metric | TSK-26A Internal Emulation (64 vs 64 terms) | True Conv2D vs TSK-26A (576 vs 64 terms) | Status / Implication |
| :--- | :---: | :---: | :--- |
| **Mean Absolute Error (MAE)** | $5.34 \times 10^{-5}$ | **4.6722** | Severe mismatch against true convolution |
| **Root Mean Squared Error (RMSE)**| $7.59 \times 10^{-5}$ | **6.1211** | High variance due to omitted channels |
| **Maximum Absolute Error** | $1.92 \times 10^{-4}$ | **19.3270** | Extreme deviation |
| **Signal-to-Quantization-Noise (SQNR)**| **86.60 dB** | **0.87 dB** | Signal completely overwhelmed by error |

> [!CAUTION]
> The reported $\text{SQNR} = 86.60\text{ dB}$ is **not** the SQNR of the convolution against PyTorch. It is exclusively the numerical quantization error between a truncated 64-step FP32 dot product and a truncated 64-step INT16 dot product. Against true 2D convolution, the SQNR is only **0.87 dB**.

Detailed numerical comparison records are stored in [`TSK26A_INDEPENDENT_AUDIT/TSK26A_NUMERICAL_RECHECK.csv`](file:///e:/MTech/LanChain/MTP/TSK26A_INDEPENDENT_AUDIT/TSK26A_NUMERICAL_RECHECK.csv).

---

## 5. Audit D: Cross-Mode Performance Comparison Fairness

The performance metrics reported in TSK-26A were audited for methodological fairness:

| PE Configuration | Feeder Mode Setting in Testbench | Total Execution Cycles | Total Memory Reads | Comparison Classification |
| :---: | :---: | :---: | :---: | :---: |
| **64-PE** | `cfg_sparse_feeder_en = 1'b1` (**SPARSE**) | 3,876 | 7,328 | **NON-EQUIVALENT** |
| **32-PE** | `cfg_sparse_feeder_en = 1'b0` (**DENSE**) | 5,640 (+45.5%) | 9,376 (+27.9%) | **NON-EQUIVALENT** |
| **16-PE** | `cfg_sparse_feeder_en = 1'b0` (**DENSE**) | 9,232 (+138.2%) | 13,472 (+83.8%) | **NON-EQUIVALENT** |

### Audit Findings
1. In `tb_tsk26a_full_layer_validation.sv`:
   - Line 405: 64-PE test explicitly sets `cfg_sparse_feeder_en = 1'b1`.
   - Lines 496 & 519: 32-PE test explicitly sets `cfg_sparse_feeder_en = 1'b0`.
   - Line 594: 16-PE test explicitly sets `cfg_sparse_feeder_en = 1'b0`.
2. Microarchitectural inspection of [`datapath_compute_feeder.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv#L187-L212) proves that **sparse execution is already implemented in RTL for 32-PE and 16-PE modes** via `weight_sparse_comb`.
3. Consequently, comparing 64-PE Sparse cycles directly against 32-PE and 16-PE Dense cycles is methodologically invalid.
4. **Fair Experiments Required**:
   - **Fair Dense Evaluation**: 64-PE Dense vs 32-PE Dense vs 16-PE Dense (all with `cfg_sparse_feeder_en = 0`).
   - **Fair Sparse Evaluation**: 64-PE Sparse vs 32-PE Sparse vs 16-PE Sparse (all with `cfg_sparse_feeder_en = 1`).

Detailed audit rows are recorded in [`TSK26A_INDEPENDENT_AUDIT/TSK26A_PERFORMANCE_COMPARISON_AUDIT.csv`](file:///e:/MTech/LanChain/MTP/TSK26A_INDEPENDENT_AUDIT/TSK26A_PERFORMANCE_COMPARISON_AUDIT.csv).

---

## 6. Audit E: Evidence and Regression Log

All regressions and verification suites were independently rerun with results logged in [`TSK26A_INDEPENDENT_AUDIT/TSK26A_RERUN_LOG.txt`](file:///e:/MTech/LanChain/MTP/TSK26A_INDEPENDENT_AUDIT/TSK26A_RERUN_LOG.txt):

1. **TSK-26A Full Spatial Validation Harness (`run_tsk26a_validation.py`)**:
   - **Exit Code**: `0` (Duration: 34.5s)
   - **Checks**: 31 / 31 passed (100% PASS)
2. **Baseline 20-Suite Regression (`run_regression.py`)**:
   - **Exit Code**: `0` (Duration: 36.2s)
   - **Checks**: 12,202 / 12,202 passed (100% PASS, 0 failures)
3. **TSK-23 Master Unified Regression (`run_tsk23_unified_regression.py`)**:
   - **Exit Code**: `0` (Duration: 44.8s)
   - **Suites**: 8 / 8 passed (100% PASS, 0 failures)
4. **Protected RTL Baseline Verification**:
   - Command: `git diff --exit-code <5 protected files>`
   - Result: **0 diffs** (100% strictly unchanged)
5. **Git Hygiene**:
   - Commits created: **0**

---

## 7. Master Claim Evidence Matrix

The table below summarizes the audited claims as recorded in [`TSK26A_INDEPENDENT_AUDIT/TSK26A_CLAIM_EVIDENCE_MATRIX.csv`](file:///e:/MTech/LanChain/MTP/TSK26A_INDEPENDENT_AUDIT/TSK26A_CLAIM_EVIDENCE_MATRIX.csv):

| Claim ID | Claim Description | Reported Status | Audited Classification | Exact Evidence |
| :---: | :--- | :---: | :---: | :--- |
| **CLM-01** | Computes complete $3 \times 3$ convolution feature map | COMPLETE (Category C) | **FAIL** | $K=64$ evaluated instead of $K=576$. Only 11.11% of reduction computed; 56 of 64 input channels (87.5%) completely omitted. |
| **CLM-02** | Evaluates all 64 spatial output points ($8 \times 8$) and 16 channels | PASS (1,024 elements) | **PASS_WITH_LIMITATIONS** | 64 spatial points tiled across 16 tiles producing 1,024 outputs, but each output point evaluates a truncated inner product. |
| **CLM-03** | Hardware accumulates all 9 kernel positions across channels | PASS | **FAIL** | RTL runs only one 64-step reduction per tile. Accumulators are cleared between tiles; no multi-flit accumulation to reach 576. |
| **CLM-04** | Bit-exact RTL equivalence to software reference model | PASS (1,024/1,024 matches) | **PASS** | RTL bit-exactly matches the 64-step fixed-point software reference (MAE=0.0, RMSE=0.0). Hardware accurately computes the modeled algorithm. |
| **CLM-05** | Quantization fidelity against FP32 ground truth ($\text{SQNR} = 86.60\text{ dB}$) | PASS | **FAIL** | Reported 86.60 dB compared against a truncated 64-step FP32 model. Comparison against true PyTorch Conv2D yields $\text{SQNR} = 0.87\text{ dB}$. |
| **CLM-06** | Cross-mode functional equivalence (16-PE vs 32-PE vs 64-PE) | PASS (1,024/1,024 matches) | **PASS** | Multi-pass channel tiling produces identical accumulators across all three PE configurations. |
| **CLM-07** | Fair cross-mode latency and memory read comparison | REPORTED | **FAIL** | 64-PE mode enabled sparse feeder, whereas 32-PE and 16-PE disabled it. Performance comparisons are non-equivalent. |
| **CLM-08** | Protected RTL baseline integrity (5 modules unchanged) | VERIFIED (0 diffs) | **PASS** | All 5 baseline files confirmed with zero git diffs. |
| **CLM-09** | Zero Git commits created | VERIFIED | **PASS** | Working tree clean of new commits. |
| **CLM-10** | Coverage of all 10 boundary and adversarial scenarios | PASS (10/10) | **PASS** | 10 Phase 8 boundary and adversarial conditions verified in RTL without defects. |

---

## 8. Minimum Next Experiment to Close Correctness Gaps

To advance from **Category B+ (Spatial Subgrid with Truncated Kernel Fragment)** to genuine **Category C (Complete Single-Layer Feature Map)**, the following architectural steps are required:

1. **Full Reduction Depth ($K=576$) Support**:
   - Option A (*Single Execution Pass per Tile*): Expand SRAM buffer allocation and sequencer command length to $K=576$ ($64 \times 3 \times 3$), allowing each spatial tile to evaluate all 576 inner-product terms in one continuous compute run.
   - Option B (*Multi-Flit Inner-Product Accumulation*): Orchestrate 9 sequential $K=64$ passes per spatial tile, preserving PE accumulator values across flits without resetting between passes, and draining only after all 9 passes complete.
2. **Fair Cross-Mode Benchmarking**:
   - Re-run 64-PE, 32-PE, and 16-PE under strictly matched conditions: both in 100% Dense mode and in 100% Sparse mode.
3. **Full Spatial Feature Map ($56 \times 56$) Sequencing**:
   - Implement autonomous hardware spatial sequencing (TSK-26B) to iterate through all 784 spatial tiles covering the full $56 \times 56$ ResNet-18 layer.

