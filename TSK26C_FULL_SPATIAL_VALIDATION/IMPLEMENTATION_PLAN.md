# TSK-26C: Full Spatial Feature-Map and Multi-Layer Validation Plan

## 1. Overview and Objectives

The objective of **TSK-26C** is to build upon the verified $K=576$ inner product verified in TSK-26B and investigate full spatial feature-map correctness, multi-layer chaining, and hardware autonomy boundaries on real CNN models (ResNet-18 and VGG-16-BN on CIFAR-10 and CIFAR-100).

Specifically, TSK-26C addresses:
1. **Full Spatial Feature-Map Validation:**
   - Moving beyond single-patch evaluation to multi-position spatial grids.
   - Selecting representative **early, middle, and deep** convolution layers.
   - In deep layers (e.g. VGG-16 `features.37` with output spatial size $2 \times 2 = 4$), achieving **100.0% complete spatial feature-map execution** through the 4 rows of the PE array.
   - In middle and early layers, evaluating spatial grids (corners, boundaries, and interior tiles) and characterizing full spatial rasterization limits under RTL simulation.
2. **Sequential Multi-Layer Validation:**
   - Executing two consecutive convolution layers: ResNet-18 CIFAR-10 `layer1.0.conv1` $\to$ Requantization/ReLU $\to$ `layer1.0.conv2`.
   - Ensuring Layer 2 directly consumes the hardware-generated, requantized output of Layer 1 rather than host-computed substitutions.
   - Documenting all operations executed outside the RTL (quantization scaling, rounding, spatial zero-padding, layout reformatting).
3. **PE Mode and Sparsity Scaling:**
   - Evaluating 16-PE, 32-PE, and 64-PE modes across dense and sparse regimes.
   - Strictly matching intra-regime performance comparisons.
4. **Autonomous Sequencing Audit:**
   - Rigorously evaluating whether spatial sequencing, channel tiling, accumulator partial sum preservation, and layer chaining can be executed autonomously by the existing RTL or require testbench/host orchestration.
   - Providing a concrete architectural proposal for future RTL modifications to support autonomous hardware sequencing.
5. **Zero-Regression & Protected Baseline Preservation:**
   - Strictly preserving all 5 core baseline RTL files (0 diffs).
   - Zero Git commits.
   - Executing the complete existing 20-suite regression testbench.

---

## 2. Layer Selection and Spatial Grid Architecture

| Category | Model & Dataset | Layer Name | Input Tensor | Output Tensor | Kernel, Stride, Pad | Reduction Dimension $K$ | Evaluated Spatial Coverage |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Deep Layer** | VGG-16-BN CIFAR-10 | `features.37` | $[512, 2, 2]$ | $[512, 2, 2]$ | $3 \times 3$, $s=1$, $p=1$ | 4,608 (or $C_{in}=64$ slice: 576) | **100.0% Full Spatial Grid (all 4 positions $(0,0), (0,1), (1,0), (1,1)$)** |
| **Middle Layer** | VGG-16-BN CIFAR-10 | `features.14` | $[128, 8, 8]$ | $[256, 8, 8]$ | $3 \times 3$, $s=1$, $p=1$ | 1,152 (or $C_{in}=64$ slice: 576) | Multi-position spatial grid (corners, edges, center) |
| **Early Layer** | ResNet-18 CIFAR-10 | `layer1.0.conv1` | $[64, 32, 32]$ | $[64, 32, 32]$ | $3 \times 3$, $s=1$, $p=1$ | 576 | Multi-position spatial grid across $32 \times 32$ feature map |
| **Chained Seq** | ResNet-18 CIFAR-10 | `conv1` $\to$ `conv2` | $[64, 32, 32]$ | $[64, 32, 32]$ | $3 \times 3$, $s=1$, $p=1$ | 576 per layer | 4 spatial positions chained across two consecutive layers |

---

## 3. Sequential Layer Execution Dataflow

```
[Layer 1 Input Activations] (64, 32, 32)
         │
         ▼
[Host Im2Col & Buffer A Preload]
         │
         ▼
[Neural_Acc RTL Core: Layer 1 (layer1.0.conv1)]
         │
         ▼ (40-bit Accumulator Output)
[Hardware Requantization Unit: Scale >> 12, Round, ReLU, Pack]
         │
         ▼ (INT16 Q4.12 HW Activations)
[Host Buffer Transfer & Spatial Padding for Layer 2]
         │
         ▼
[Neural_Acc RTL Core: Layer 2 (layer1.0.conv2)]
         │
         ▼ (40-bit Accumulator Output)
[Hardware Requantization Unit: Scale >> 12, Round, ReLU, Pack]
         │
         ▼
[Golden PyTorch Chained Verification: 0 Mismatches]
```

---

## 4. Deliverables Checklist

- [ ] `README.md`
- [ ] `SPATIAL_COVERAGE.csv`
- [ ] `MULTI_LAYER_CORRECTNESS.csv`
- [ ] `RTL_REFERENCE_COMPARISON.csv`
- [ ] `PE_MODE_PERFORMANCE.csv`
- [ ] `DENSE_SPARSE_COMPARISON.csv`
- [ ] `HARDWARE_SOFTWARE_PARTITION.md`
- [ ] `AUTONOMOUS_SEQUENCING_AUDIT.md`
- [ ] `LIMITATIONS.md`
- [ ] `FINAL_AUDIT_REPORT.md` (and conversation artifact)

