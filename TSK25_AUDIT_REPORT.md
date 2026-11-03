# TSK-25: Independent Audit of TSK-24 Real CNN Validation

**Project:** Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Audit Milestone:** TSK-25  
**Audited Target:** TSK-24 (Real CNN Numerical Validation & Cross-Mode Equivalence)  
**Date:** November 2026  
**Audit Status:** COMPLETE — ALL CLAIMS INDEPENDENTLY AUDITED  

---

## 1. Executive Summary

This report presents an independent, rigorous hardware and numerical audit of the **TSK-24 Real CNN Validation** milestone for the Neural_Acc accelerator. 

The audit evaluated the complete provenance of input tensors, architectural execution boundaries, numerical precision, cross-mode channel equivalence (16-PE vs 32-PE vs 64-PE), activation sparsity telemetry, memory subsystem handshakes, and test reproducibility.

### Key Audit Findings:
1. **Mathematical Reproducibility (100% Pass):**
   - All 1,204 RTL assertion checks in `tb_tsk24_real_cnn_validation.sv` passed with 0 failures across 16 test regimes.
   - The baseline 20-suite regression passed 100% (12,202 / 12,202 checks passed).
   - The TSK-23 master unified regression passed 100% across all 8 test suites.
   - All SHA-256 hashes of exported INT16 weight, activation, and output tensors match byte-for-byte against independent model extraction.
2. **Execution Scope Classification (Category B):**
   - The TSK-24 verification is strictly classified as **Category B: Kernel / Layer-Fragment Real-Data Validation**.
   - It validates representative $4 \text{ spatial rows} \times 16 \text{ output channels}$ GEMM matrix slices with reduction dimensions $K=64$ and $K=128$ extracted from pretrained ResNet-18.
   - It does **not** constitute an end-to-end model inference evaluation (Category D) nor a full spatial feature map convolution (Category C). Sliding-window im2col unfolding, bias addition, pooling, and multi-tile spatial orchestration remain host/DMA responsibilities.
3. **Cross-Mode Numerical Identity:**
   - 16-PE (4 passes $\times$ 4 channels), 32-PE (2 passes $\times$ 8 channels), and 64-PE (1 pass $\times$ 16 channels) generate bit-exact, mathematically identical accumulators. When de-interleaved from row-major SRAM format, all 128 words match with 0 errors, 0 dropped channels, and 0 memory corruptions.
4. **Feeder Sparsity Telemetry Reconciled:**
   - The hardware feeder FSM skips weight reads and compute cycles if and only if **all 4 spatial rows** at step $k$ are simultaneously zero (quad-row zero).
   - Recomputed cycle reductions match reported numbers exactly: WL1 = 22.26%, WL2 = 22.87%, WL3 = 21.04%, WL4 = 31.15%.
   - Recomputed SRAM read reductions match reported numbers exactly: WL1 = 12.50% (80 words), WL2 = 15.00% (96 words), WL3 = 7.50% (48 words), WL4 = 21.88% (280 words), precisely matching $8 \text{ weight words} \times \text{quad\_zero\_steps}$.
5. **Protected Baseline Preservation:**
   - All 5 protected baseline RTL files are 100% pristine and unmodified (`git diff --exit-code` returned exit code 0). Zero Git commits were created.

---

## 2. Exact Validation Scope Classification

To prevent ambiguity or exaggerated claims in academic publication, the audit classifies the validation scope according to the four formal categories:

| Category | Definition | TSK-24 Audit Verdict | Evidence & Justification |
| :--- | :--- | :---: | :--- |
| **Category A** | **Real-Data Validation Only** | **SUPERSEDED** | TSK-24 goes beyond unorganized synthetic data; operands are real structured tensors from ResNet-18. |
| **Category B** | **Kernel / Layer-Fragment Validation** | **CONFIRMED VERDICT** | Evaluates authentic $4 \times 16$ spatial/channel GEMM inner-product reduction tiles ($K=64, 128$) executed directly on the 64-PE systolic core with multi-pass channel tiling, row-major draining, Round-Half-Up requantization, and zero-skipping telemetry. |
| **Category C** | **Complete Supported-Layer Validation** | **NOT ACHIEVED** | Does not evaluate full $56 \times 56 = 3136$ spatial feature maps. im2col sliding-window unfolding and channel bias addition are performed externally before SRAM loading. |
| **Category D** | **End-to-End Model Validation** | **NOT ACHIEVED** | Does not execute the full 18-layer graph or report Top-1/Top-5 ImageNet classification accuracy. Residual skip addition and pooling are not present in the hardware core. |

### Architectural Boundary Summary:
- **Directly Executed in RTL Core:**
  - $4 \times 16$ inner-product reduction ($16\text{b} \times 16\text{b} \to 40\text{b}$ saturating accumulators).
  - Channel tiling sequencer for 16-PE, 32-PE, and 64-PE modes.
  - Multi-bank SRAM read/write arbitration and row-major OFMAP drain controller.
  - Real-time quad-row zero-detection FSM and cycle/read skip logic.
  - Fine-grained PE operand/clock gating on partial-zero rows.
  - Requantization unit: arithmetic shift ($S \in [0, 31]$), Round-Half-Up, clamping $[-32768, 32767]$, hard ReLU, and two-element 32-bit word packing.
- **Delegated to Host / DMA Software:**
  - im2col sliding-window address generation and padding.
  - Convolutional bias addition.
  - Max-pooling and Average-pooling operations.
  - Inter-tile spatial scheduling across large feature maps.
  - Residual skip connection additions.

---

## 3. Real CNN Tensor Provenance & Checksum Audit

The audit independently verified the provenance, determinism, and extraction pipeline of all workload tensors using `TSK25_INDEPENDENT_AUDIT/recheck_provenance.py`.

```
================================================================================
TSK-25 INDEPENDENT AUDIT: REAL CNN TENSOR PROVENANCE & CHECKSUM VERIFICATION
================================================================================
[INFO] Python Version       : 3.12.3
[INFO] PyTorch Version      : 2.15.0+cpu
[INFO] Torchvision Version  : 0.29.2+cpu
[INFO] NumPy Version        : 2.5.4

--- 1. Pretrained Checkpoint Verification ---
[INFO] ResNet18_Weights.IMAGENET1K_V1 metadata sha256: f37072fd97779f64
[INFO] ResNet-18 Total Parameters: 11,689,512
[PASS] ResNet-18 model structure and weights verified.

--- 2. Deterministic Input & Forward Inference Audit ---
[PASS] Forward pass reproduced successfully. Logits shape: torch.Size([1, 1000])

--- 3. Bit-Exact SHA-256 Checksum Audit Against TSK-24 Manifest ---
  Layer: early_conv (layer1.0.conv1) -> Act, Wt, Out SHA-256 100% MATCH
  Layer: early_relu (layer1.0.relu)  -> Act, Wt, Out SHA-256 100% MATCH
  Layer: mid_conv   (layer2.0.conv1) -> Act, Wt, Out SHA-256 100% MATCH
  Layer: deep_conv  (layer3.0.conv1) -> Act, Wt, Out SHA-256 100% MATCH
================================================================================
[AUDIT RESULT: PASS] All tensor checksums, models, and deterministic extractions verified bit-exact.
================================================================================
```

### Provenance Audit Details:
1. **Model Source:** Official torchvision `resnet18(weights=ResNet18_Weights.IMAGENET1K_V1)` with 11,689,512 parameters and checkpoint hash `f37072fd97779f64`.
2. **Inference Determinism:** `model.eval()`, `torch.manual_seed(20261102)`, `np.random.seed(20261102)`.
3. **Input Image Limitation:** The input passed to the model was a deterministic synthetic Gaussian tensor (`torch.randn(1, 3, 224, 224)`) normalized with ImageNet mean `[0.485, 0.456, 0.406]` and std `[0.229, 0.224, 0.225]`. While it produces authentic dynamic activations in the pretrained model, it is **not** an actual natural image from the ImageNet validation dataset.
4. **Quantization Rules:** Uniform per-tensor symmetric INT16 quantization:
   $$Scale = \frac{32767.0}{\max(|X|)}, \quad X_{\text{int16}} = \text{clip}\left(\text{round}(X \times Scale), -32768, 32767\right)$$
   Activations, weights, and golden outputs are quantized independently with dedicated scales.
5. **Hook Semantics:**
   - `early_conv` hook captures input after `conv1 -> bn1 -> relu -> maxpool` (16.19% exact zeros).
   - `early_relu` hook captures input to `layer1.0.relu` (38.75% exact zeros). Evaluated against convolutional weights from `early_conv` to stress-test post-ReLU activation sparsity.
   - `mid_conv` hook captures input to `layer2.0.conv1` (37.63% exact zeros).
   - `deep_conv` hook captures input to `layer3.0.conv1` (59.51% exact zeros).

---

## 4. Test Reproducibility Results

The entire TSK-24 software and hardware toolchain was re-executed from scratch using `TSK25_INDEPENDENT_AUDIT/run_reproducibility.py`. Runtimes, exit codes, and logs were recorded in `TSK25_TEST_REPRODUCIBILITY.csv`.

| Step Name | Working Directory | Command Executed | Duration | Exit Code | Checks / Status |
| :--- | :--- | :--- | :---: | :---: | :---: |
| **TSK24 Workload Generation** | `TSK24_REAL_CNN_VALIDATION/` | `python generate_rtl_workloads.py` | 2.12s | 0 | PASS |
| **TSK24 Real CNN Simulation** | `TSK24_REAL_CNN_VALIDATION/` | `python run_tsk24_simulation.py` | 19.92s | 0 | 1204 / 1204 PASS |
| **TSK24 Numerical Accuracy** | `TSK24_REAL_CNN_VALIDATION/` | `python analyze_numerical_accuracy.py` | 1.25s | 0 | PASS |
| **TSK24 Sparsity Analysis** | `TSK24_REAL_CNN_VALIDATION/` | `python analyze_real_cnn_sparsity.py` | 1.22s | 0 | PASS |
| **Baseline 20-Suite Regression** | `phase2_step1_microarchitecture_and_rtl/` | `python run_regression.py` | 27.27s | 0 | 12202 / 12202 PASS |
| **TSK23 Master Unified Regression** | `phase2_step1_microarchitecture_and_rtl/` | `python run_tsk23_unified_regression.py` | 97.27s | 0 | 8 / 8 Suites PASS |

**Total Regression Runtimes:** 149.05 seconds. 100% of tests passed cleanly with zero compilation warnings and zero assertion failures.

---

## 5. Numerical Correctness Findings

The software and RTL implementations were independently audited using `TSK25_INDEPENDENT_AUDIT/recheck_numerical_and_modes.py`.

```
--- Auditing Workload: WL1_EARLY_CONV (layer1.0.conv1, K=64) ---
  [PASS] Independent 40-bit saturating integer accumulation matched JSON exactly (max diff: 0).
  [PASS] 128 Golden OFMAP words bit-exact match.
  [PASS] 32 Golden Requantized Packed Words bit-exact match.
  FP32 Comparison (on 64 accumulators):
    MAE          : 4.994622e-05
    RMSE         : 6.301161e-05
    Rel L2 Error : 9.408635e-05
    SQNR (dB)    : 80.53 dB
```

### Numerical Audit Summary Table:

| Workload ID | Target Layer | Reduction $K$ | Evaluated Elements | Exact Int Matches | Int MAE | Int RMSE | Requant Matches | FP32 MAE | FP32 SQNR (dB) | Status |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL1_EARLY_CONV** | `layer1.0.conv1` | 64 | 64 ($4 \times 16$) | 64 / 64 | 0.0 | 0.0 | 32 / 32 | $4.99 \times 10^{-5}$ | 80.53 dB | **PASS_WITH_LIMITATIONS** |
| **WL2_SPARSE_RELU** | `layer1.0.relu` | 64 | 64 ($4 \times 16$) | 64 / 64 | 0.0 | 0.0 | 32 / 32 | $3.53 \times 10^{-5}$ | 84.47 dB | **PASS_WITH_LIMITATIONS** |
| **WL3_MID_CONV** | `layer2.0.conv1` | 64 | 64 ($4 \times 16$) | 64 / 64 | 0.0 | 0.0 | 32 / 32 | $2.45 \times 10^{-5}$ | 89.36 dB | **PASS_WITH_LIMITATIONS** |
| **WL4_DEEP_CONV** | `layer3.0.conv1` | 128 | 64 ($4 \times 16$) | 64 / 64 | 0.0 | 0.0 | 32 / 32 | $1.17 \times 10^{-5}$ | 89.31 dB | **PASS_WITH_LIMITATIONS** |

### Crucial Numerical Clarification on SQNR Scope:
The reported SQNR values ($>80$ dB) represent the quantization fidelity of the **representative $4 \times 16$ tile** comparing dequantized 40-bit accumulators against 64-bit floating-point inner products. They do **not** represent full-layer end-to-end SQNR across the 200,704 elements of the entire layer output tensor. This scope limitation is explicitly tagged in `TSK25_NUMERICAL_RECHECK.csv`.

---

## 6. Cross-Mode Equivalence Findings

The accelerator supports dynamic PE allocation across 16-PE, 32-PE, and 64-PE modes. The audit verified whether multi-pass channel tiling preserves output equivalence without dropping or corrupting channels.

### Channel Tiling Configuration:
- **64-PE Mode:** 1 pass $\times$ 16 columns (Cols 0..15 active).
- **32-PE Mode:** 2 passes $\times$ 8 columns (Pass 0: Cols 0..7; Pass 1: Cols 8..15).
- **16-PE Mode:** 4 passes $\times$ 4 columns (Pass 0: Cols 0..3; Pass 1: Cols 4..7; Pass 2: Cols 8..11; Pass 3: Cols 12..15).

```
================================================================================
TSK-25 INDEPENDENT AUDIT: CROSS-MODE EQUIVALENCE RECHECK
================================================================================
Mode Pair: 16-PE vs 32-PE (4 passes vs 2 passes) -> 128 / 128 Words Match (0 Mismatches) [PASS]
Mode Pair: 32-PE vs 64-PE (2 passes vs 1 pass)   -> 128 / 128 Words Match (0 Mismatches) [PASS]
Mode Pair: 16-PE vs 64-PE (4 passes vs 1 pass)   -> 128 / 128 Words Match (0 Mismatches) [PASS]
================================================================================
```

### Key Verification Highlights:
1. **Channel Preservation:** Across all 4 workloads, exactly 128 SRAM words (64 accumulators $\times$ 2 words) were written and read back. There were **0 dropped channels**, **0 duplicate words**, and **0 overwritten values**.
2. **Row-Major De-interleaving:** In 16-PE and 32-PE modes, partial-channel passes write disjoint addresses within the OFMAP buffer. Hardware row-major address calculation (`ofmap_drain_controller.sv`) correctly interleaves the passes to produce bit-exact identical SRAM layouts.
3. **Activation Reload Overhead:** Multi-pass execution requires activations to be re-read for each channel pass. For $K=64$:
   - 64-PE mode: 640 SRAM reads (1 pass)
   - 32-PE mode: 768 SRAM reads (+20.0% reload overhead)
   - 16-PE mode: 1024 SRAM reads (+60.0% reload overhead)

---

## 7. Recomputed Sparsity and Performance Measurements

The audit independently distinguished element-wise activation sparsity from hardware-skippable sparsity using `TSK25_INDEPENDENT_AUDIT/recheck_sparsity_and_performance.py`.

### Mathematical Feeder Skip Condition:
The feeder FSM skips weight reads and compute cycles if and only if **all 4 spatial rows** in reduction step $k$ are zero:
$$\text{Skip Step } k \iff \forall r \in [0, 3], \quad \text{act\_slice}[r, k] == 0$$

If 1, 2, or 3 rows are zero (partial zeros), the feeder cannot skip the step because the non-zero rows still require weight operands. For partial zeros, the PE array uses fine-grained clock/operand gating to save dynamic power without cycle skipping.

```
--- Sparsity & Telemetry Audit: WL4_DEEP_CONV (layer3.0.conv1) ---
  Global Tensor Act Sparsity   : 59.51% (59,720 / 100,352)
  Global Tensor Wt Sparsity    : 0.02% (55 / 294,912)
  Tile Element-Wise Sparsity   : 56.84% (291 / 512)
  Quad-Row All-Zero Steps (k)  : 35 / 128 (27.34%) -> Feeder Skips
  Partial-Zero Steps (1..3 rows): 69 / 128 (53.91%) -> PE Clock-Gating only
  Fully Dense Steps            : 24 / 128
  Compute Cycles: Dense=128, Sparse=93 (Exact: K - quad_zeros = 128 - 35 = 93)
  SRAM Reads Saved: 280 words (Exact: 8 wt words * 35 quad zeros = 280)
  Cycle Reduction : 31.15% (Dense: 520, Sparse: 358)
  Read Reduction  : 21.88% (Dense: 1280, Sparse: 1000)
  Bank Conflicts  : 0 | Read Stalls: 0
  [PASS] Recomputed reductions match reported CSV values exactly.
```

### Sparsity & Performance Reconciliation Table:

| Workload ID | $K$ Steps | Element Sparsity | Quad-Zero Steps (Feeder Skips) | Partial-Zero Steps (Clock Gating) | Dense Cycles | Sparse Cycles | Recomputed Cycle Reduction | Dense Reads | Sparse Reads | Recomputed Read Reduction | Reads Saved | Bank Conflicts |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL1_EARLY_CONV** | 64 | 21.88% | 10 (15.62%) | 11 (17.19%) | 328 | 255 | **22.26%** | 640 | 560 | **12.50%** | 80 | 0 |
| **WL2_SPARSE_RELU** | 64 | 37.50% | 12 (18.75%) | 23 (35.94%) | 328 | 253 | **22.87%** | 640 | 544 | **15.00%** | 96 | 0 |
| **WL3_MID_CONV** | 64 | 32.03% | 6 (9.38%) | 30 (46.88%) | 328 | 259 | **21.04%** | 640 | 592 | **7.50%** | 48 | 0 |
| **WL4_DEEP_CONV** | 128 | 56.84% | 35 (27.34%) | 69 (53.91%) | 520 | 358 | **31.15%** | 1280 | 1000 | **21.88%** | 280 | 0 |

### Verification of Underlying Formulas:
$$\text{Cycle Reduction (\%)} = \frac{\text{Dense Cycles} - \text{Sparse Cycles}}{\text{Dense Cycles}} \times 100$$
$$\text{Read Reduction (\%)} = \frac{\text{Dense Reads} - \text{Sparse Reads}}{\text{Dense Reads}} \times 100$$
$$\text{Reads Saved} = 8 \text{ weight words} \times \text{Quad-Zero Steps}$$

All recomputed values match the reported CSV files bit-for-bit.

---

## 8. Protected Baseline RTL Audit

The audit verified that the five core protected baseline RTL files have remained completely untouched:

```powershell
PS> git diff --exit-code phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv `
                         phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv `
                         phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv `
                         phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv `
                         phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv
# Exit code: 0 (No differences detected)
```

- `accelerator_core_top.sv`: **0 diffs (UNTOUCHED)**
- `mac_unit_40b.sv`: **0 diffs (UNTOUCHED)**
- `k_progress_tracker.sv`: **0 diffs (UNTOUCHED)**
- `slot_control_unit.sv`: **0 diffs (UNTOUCHED)**
- `hybrid_sram_bank.sv`: **0 diffs (UNTOUCHED)**

Zero Git commits were made during this audit.

---

## 9. Comprehensive Claim-Evidence Matrix

The table below summarizes the independent audit of all claims in `TSK25_INDEPENDENT_AUDIT/TSK25_CLAIM_EVIDENCE_MATRIX.csv`:

| # | Evaluated Claim | Original Reported Value | Evidence Location | Independent Verification Method | Reproduced Value | Audit Status | Limitations & Boundary Scope |
| :-: | :--- | :--- | :--- | :--- | :--- | :---: | :--- |
| **1** | Pretrained Model Origin | ResNet-18 ImageNet1K_V1, 11,689,512 params | `export_cnn_tensors.py:51-57` | Loaded torchvision model, verified parameter count and metadata sha256 | 11,689,512 params, sha256 prefix verified | **PASS** | Forward inference used synthetic deterministic Gaussian input with ImageNet mean/std, not raw ImageNet JPEG image |
| **2** | Deterministic Checksums | Bit-exact SHA-256 hashes across 12 tensors | `TSK24_LAYER_MANIFEST.csv:2-5` | Standalone re-extraction with seed 20261102; SHA-256 computed on raw bytes | 100% bit-exact SHA-256 match | **PASS** | Pre-ReLU input activations used for early_relu; conv weights from early_conv reused |
| **3** | RTL Computation Scope | Real CNN layers validated on accelerator core | `TSK24_REAL_CNN_VALIDATION_REPORT.md` | Codebase and datapath audit of feeder, PE array, and tile controller | Validated 4x16 spatial/channel GEMM tiles ($K=64, 128$) | **PASS_WITH_LIMITATIONS** | Category B (Kernel Fragment). Host handles im2col unfolding, bias, multi-tile orchestration, and pooling |
| **4** | Integer Accumulator Correctness | 64/64 exact integer matches (0 mismatches, MAE=0) | `TSK24_NUMERICAL_RESULTS.csv:2,5,8,11` | Independent software simulation of 40-bit saturating integer accumulation | 64/64 exact matches for all 4 workloads | **PASS** | Applies to evaluated 4x16 tile slice over $K=64$ and $K=128$ |
| **5** | Cross-Mode Equivalence | 128/128 exact SRAM words match across all modes | `TSK24_CROSS_MODE_RESULTS.csv:2-17` | Recomputed row-major de-interleaving and checked SRAM words across all 3 modes | 128/128 exact word matches for all 4 workloads | **PASS** | Channel tiling re-reads activations for each pass, adding reload overhead in 16-PE (+60%) and 32-PE (+20%) modes |
| **6** | Requantization & Packing | 32/32 packed words exact match (64 activations) | `TSK24_NUMERICAL_RESULTS.csv:col 10` | Independent bit-exact emulation of Round-Half-Up, clamping, ReLU, and word packing | 32/32 packed words bit-exact match across all 4 workloads | **PASS** | `cfg_scale_shift` applies uniformly across all 16 columns; per-channel scaling not supported without per-column shift registers |
| **7** | Quantization Noise & SQNR | WL1: 80.53 dB, WL2: 84.47 dB, WL3: 89.36 dB, WL4: 89.31 dB | `analyze_numerical_accuracy.py:118-124` | Recomputed FP32 accumulation and dequantized INT16 error against ground truth | WL1: 80.53 dB, WL2: 84.47 dB, WL3: 89.36 dB, WL4: 89.31 dB | **PASS_WITH_LIMITATIONS** | SQNR was computed on the representative 64-accumulator tile ($4 \times 16$), not across the entire layer output tensor |
| **8** | Feeder Sparsity Cycle Reduction | WL1: 22.26%, WL2: 22.87%, WL3: 21.04%, WL4: 31.15% | `TSK24_SPARSITY_RESULTS.csv:2-5` | Recomputed from raw simulation cycles: $(C_{\text{dense}} - C_{\text{sparse}}) / C_{\text{dense}} \times 100$ | WL1: 22.26%, WL2: 22.87%, WL3: 21.04%, WL4: 31.15% | **PASS** | Requires all 4 spatial rows to be simultaneously zero (quad-row zeros); partial-zero steps trigger clock gating only |
| **9** | SRAM Read Reduction | WL1: 12.50%, WL2: 15.00%, WL3: 7.50%, WL4: 21.88% | `TSK24_SPARSITY_RESULTS.csv:cols 10-12` | Recomputed from raw memory reads: $(R_{\text{dense}} - R_{\text{sparse}}) / R_{\text{dense}} \times 100$ | Exact $8 \times \text{quad\_zeros}$ avoided for all workloads | **PASS** | Static weight sparsity is not exploited for skipping by the current feeder architecture |
| **10** | Memory Arbitration & Stalls | 0 bank conflicts, 0 read stalls across all 16 runs | `TSK24_CROSS_MODE_RESULTS.csv:cols 15-16` | Recomputed telemetry counter verification from simulation event logs | 0 bank conflicts, 0 read stalls | **PASS_WITH_LIMITATIONS** | Verified under isolated simulation conditions where OFMAP drain and DMA write adapter do not contend simultaneously |
| **11** | Protected Baseline Preservation | 5 protected baseline RTL files are 100% clean | `phase2_step1_microarchitecture_and_rtl/` | Executed `git diff --exit-code` on all 5 protected files | 0 diffs (exit code 0) | **PASS** | None. All 5 baseline files remain strictly untouched |
| **12** | Physical Power / Timing Claims | No physical silicon power or FPGA timing asserted | `TSK24_LIMITATIONS.md` | Scrutinized reports and testbench logs for unsupported physical claims | Reports strictly cite RTL toggle counts and cycle/read counts | **PASS** | Physical power estimation requires standard cell libraries or Vivado post-implementation power report |

---

## 10. Discrepancies, Gaps, and Limitations

The independent audit identified four technical limitations that must be clearly noted in project documentation:

1. **Synthetic Deterministic Input Tensor:**
   - The input to ResNet-18 was generated using `torch.randn(1, 3, 224, 224)` under fixed seed `20261102` with ImageNet normalization. While this propagates through the pretrained model to create authentic convolutional feature maps and realistic sparsity, it does not evaluate classification accuracy on real ImageNet images.
2. **Tile Slice vs Full Feature Map:**
   - The accelerator validates a $4 \times 16$ tile slice over $K=64$ or $K=128$. Full layers contain up to 3,136 spatial points ($56 \times 56$) and up to 256 channels with $K=576$ or $1,152$. Evaluating full layers requires an automated external DMA double-buffering driver to orchestrate thousands of spatial tiles.
3. **Coarse Feeder Skip Granularity:**
   - Feeder skipping requires all 4 spatial rows to be simultaneously zero. While element-wise activation sparsity ranges from 21.9% to 56.8%, quad-row zero steps range from 9.4% to 27.3%. Partial-zero steps (17.2% to 53.9%) achieve clock gating but do not reduce memory traffic or cycle latency.
4. **Uniform Requantization Shift:**
   - Requantization shift $S$ is applied uniformly across all 16 columns in a single pass. Per-channel scaling (where individual output filters have independent shift factors) is not supported in the unified shifter.

---

## 11. Recommended Next Research Milestone (TSK-26)

To advance the accelerator from **Category B (Kernel / Layer-Fragment Validation)** to **Category C (Complete Supported-Layer Validation)** and ultimately **Category D (End-to-End Model Inference)**, the following research milestone is recommended:

### Milestone TSK-26: Autonomous Hardware im2col Streaming, Full Feature-Map Tiling, and Residual Graph Chaining
1. **Autonomous Spatial Tiling Sequencer:**
   - Implement hardware address generation to loop across all spatial tiles ($4 \times 16$ grid covering $56 \times 56$ feature maps) using on-chip ping-pong buffer handshakes.
2. **On-Chip im2col Sliding Window Unit:**
   - Implement an autonomous sliding-window line buffer that ingests 2D feature maps directly from external memory/DMA, eliminating host CPU im2col matrix unfolding.
3. **Channel Bias Preload Datapath:**
   - Route channel bias values directly into accumulator clear/preload registers, eliminating host bias addition.
4. **Residual Bypass Accumulator:**
   - Implement an on-chip adder to accumulate skip connection activations with the current layer's requantized output, enabling autonomous ResNet residual block evaluation.
5. **Real ImageNet Dataset Validation:**
   - Run end-to-end inference on a 1,000-image ImageNet sample set to report full Top-1 and Top-5 accuracy validation.

---

## 12. Artifact Directory File Index

The following deliverables have been created and placed in `TSK25_INDEPENDENT_AUDIT/`:
- `TSK25_AUDIT_REPORT.md` (This document)
- `TSK25_TEST_REPRODUCIBILITY.csv` (Complete command logs, exit codes, and durations)
- `TSK25_NUMERICAL_RECHECK.csv` (Independent integer matches, MAE, RMSE, and SQNR)
- `TSK25_CROSS_MODE_RECHECK.csv` (16-PE vs 32-PE vs 64-PE word-level comparisons)
- `TSK25_PERFORMANCE_RECHECK.csv` (Independent cycle reductions, read savings, and sparsity metrics)
- `TSK25_CLAIM_EVIDENCE_MATRIX.csv` (Formal claim audit with PASS / PASS_WITH_LIMITATIONS verdicts)
- `recheck_provenance.py` (Independent model verification & SHA-256 checksum tool)
- `recheck_numerical_and_modes.py` (Independent numerical & cross-mode verification tool)
- `recheck_sparsity_and_performance.py` (Independent sparsity & performance reconciliation tool)
- `run_reproducibility.py` (Full automated reproduction harness)

