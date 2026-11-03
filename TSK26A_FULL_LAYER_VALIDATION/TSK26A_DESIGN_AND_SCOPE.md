# TSK-26A: Complete Spatial Feature-Map Validation Design and Architectural Scope

**Project:** Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Milestone:** TSK-26A  
**Objective:** Extend Category-B kernel-fragment validation into complete spatial feature-map validation for one supported convolutional layer.  
**Hardware Baseline:** Unmodified Neural_Acc RTL (`accelerator_core_top.sv`, `mac_unit_40b.sv`, `k_progress_tracker.sv`, `slot_control_unit.sv`, `hybrid_sram_bank.sv`).  

---

## 1. Architectural Scope & Boundary Definition

Neural_Acc is a systolic matrix-multiply inner-product engine optimized for activation-sparse convolutional channel evaluation.

### 1.1 Directly Executed in RTL Hardware
1. **$4 \times 16$ Processing Element Datapath (`pe_array_40b.sv`):**
   - 4 parallel rows evaluating 4 spatial output positions simultaneously.
   - 16 parallel columns evaluating up to 16 output channels simultaneously.
   - 16-bit signed integer operands $\to$ 40-bit saturating accumulators ($[-2^{39}, 2^{39}-1]$).
2. **Channel Tiling Controller (`channel_tile_controller.sv`):**
   - 64-PE Mode: 1 pass $\times$ 16 channels (all 16 columns active).
   - 32-PE Mode: 2 passes $\times$ 8 channels (Pass 0: Cols 0..7; Pass 1: Cols 8..15).
   - 16-PE Mode: 4 passes $\times$ 4 channels (Pass 0: Cols 0..3; Pass 1: Cols 4..7; Pass 2: Cols 8..11; Pass 3: Cols 12..15).
3. **Activation-Sparse Feeder FSM (`datapath_compute_feeder.sv`):**
   - Autonomous quad-row all-zero detection across Rows 0..3.
   - Skips SRAM weight reads and compute cycles when all 4 spatial activations are zero.
   - Fine-grained PE operand/clock gating for partial-zero rows.
4. **OFMAP Drain Controller (`ofmap_drain_controller.sv`):**
   - Row-major de-interleaving and draining of 64 accumulators into multi-bank SRAM (128 words).
5. **Requantization Unit (`requantization_unit.sv`):**
   - Post-accumulation scaling with configurable arithmetic shift $S \in [0, 31]$.
   - Unbiased Round-Half-Up tie breaking ($+2^{S-1}$).
   - Clamping to signed 16-bit range $[-32768, 32767]$ and hard ReLU.
   - Two-element 16-bit packing into 32-bit words.

### 1.2 Orchestrated by Testbench / Software Driver (In Scope for TSK-26A)
- **Spatial Tiling Sequencer:** Loops across all spatial coordinates of the 2D feature map, streaming tiles of 4 spatial points into the accelerator.
- **im2col Unfolding:** Sliding-window extraction with zero-padding insertion performed prior to SRAM ingestion.
- **Buffer Preload / Readback:** SRAM memory preload of 10-word reduction blocks ($k$ steps) and readback of 128 OFMAP words (or 32 packed words) per pass.

---

## 2. Selected Layer Mathematical Specification

The layer selected for complete spatial feature-map validation is derived from **torchvision pretrained ResNet-18 `layer1.0.conv1` (Early Convolution)**:

* **Layer Identifier:** `layer1.0.conv1`
* **Input Tensor Shape:** $[N=1, C_{\text{in}}=64, H_{\text{in}}=8, W_{\text{in}}=8]$ (extracted from pretrained ResNet-18 forward pass)
* **Weight Tensor Shape:** $[C_{\text{out}}=16, C_{\text{in}}=64, K_h=3, K_w=3]$ (official `IMAGENET1K_V1` weights)
* **Stride:** $S_h = 1, S_w = 1$
* **Padding:** $P_h = 1, P_w = 1$ (zero padding)
* **Convolutional Bias:** `False` (standard ResNet Conv2d layers do not use bias; BatchNorm follows)
* **Activation Function:** ReLU ($\max(0, x)$ applied at requantization)
* **Reduction Dimension:** $K = 64$ inner-product reduction steps per tile

### 2.1 Independent Output Dimension Derivation
The standard 2D convolution spatial dimension formulas:
$$H_{\text{out}} = \left\lfloor \frac{H_{\text{in}} + 2P_h - K_h}{S_h} \right\rfloor + 1 = \left\lfloor \frac{8 + 2(1) - 3}{1} \right\rfloor + 1 = 8$$
$$W_{\text{out}} = \left\lfloor \frac{W_{\text{in}} + 2P_w - K_w}{S_w} \right\rfloor + 1 = \left\lfloor \frac{8 + 2(1) - 3}{1} \right\rfloor + 1 = 8$$

* **Total Spatial Output Points:** $P = H_{\text{out}} \times W_{\text{out}} = 8 \times 8 = 64$ points.
* **Output Tensor Shape:** $[1, 16, 8, 8]$
* **Total Output Elements:** $16 \text{ channels} \times 8 \times 8 = 1,024$ activations.

---

## 3. Complete Spatial Feature-Map Tiling Layout

Because the PE array has 4 rows, the 64 spatial output points are partitioned into **16 spatial tiles** ($64 / 4 = 16$):

| Tile Index | Row 0 Spatial Pos $(h, w)$ | Row 1 Spatial Pos $(h, w)$ | Row 2 Spatial Pos $(h, w)$ | Row 3 Spatial Pos $(h, w)$ | Boundary Feature Evaluated |
| :---: | :---: | :---: | :---: | :---: | :--- |
| **Tile 0** | $(0, 0)$ | $(0, 1)$ | $(0, 2)$ | $(0, 3)$ | Top-left corner (dual pad), top edge |
| **Tile 1** | $(0, 4)$ | $(0, 5)$ | $(0, 6)$ | $(0, 7)$ | Top edge, top-right corner (dual pad) |
| **Tile 2** | $(1, 0)$ | $(1, 1)$ | $(1, 2)$ | $(1, 3)$ | Left edge, interior points |
| **Tile 3** | $(1, 4)$ | $(1, 5)$ | $(1, 6)$ | $(1, 7)$ | Interior points, right edge |
| **Tile 4** | $(2, 0)$ | $(2, 1)$ | $(2, 2)$ | $(2, 3)$ | Left edge, interior points |
| **Tile 5** | $(2, 4)$ | $(2, 5)$ | $(2, 6)$ | $(2, 7)$ | Interior points, right edge |
| **Tile 6** | $(3, 0)$ | $(3, 1)$ | $(3, 2)$ | $(3, 3)$ | Left edge, interior points |
| **Tile 7** | $(3, 4)$ | $(3, 5)$ | $(3, 6)$ | $(3, 7)$ | Interior points, right edge |
| **Tile 8** | $(4, 0)$ | $(4, 1)$ | $(4, 2)$ | $(4, 3)$ | Left edge, interior points |
| **Tile 9** | $(4, 4)$ | $(4, 5)$ | $(4, 6)$ | $(4, 7)$ | Interior points, right edge |
| **Tile 10** | $(5, 0)$ | $(5, 1)$ | $(5, 2)$ | $(5, 3)$ | Left edge, interior points |
| **Tile 11** | $(5, 4)$ | $(5, 5)$ | $(5, 6)$ | $(5, 7)$ | Interior points, right edge |
| **Tile 12** | $(6, 0)$ | $(6, 1)$ | $(6, 2)$ | $(6, 3)$ | Left edge, interior points |
| **Tile 13** | $(6, 4)$ | $(6, 5)$ | $(6, 6)$ | $(6, 7)$ | Interior points, right edge |
| **Tile 14** | $(7, 0)$ | $(7, 1)$ | $(7, 2)$ | $(7, 3)$ | Bottom-left corner (dual pad), bottom edge |
| **Tile 15** | $(7, 4)$ | $(7, 5)$ | $(7, 6)$ | $(7, 7)$ | Bottom edge, bottom-right corner (dual pad) |

Every spatial point $(h, w)$ for $h \in [0, 7], w \in [0, 7]$ is computed exactly once in the reconstructed output tensor.

---

## 4. Multi-Pass Execution Plan & Overhead

To compute all 16 output channels for each spatial tile:
* **64-PE Mode (1 pass):**
  - Pass 0: Channels 0..15 (16 columns active).
  - Passes per tile: 1. Total passes = $16 \times 1 = 16$ passes.
  - SRAM reads: 640 words/pass. Total reads = $16 \times 640 = 10,240$ words.
* **32-PE Mode (2 passes):**
  - Pass 0: Channels 0..7 (Cols 0..7 active).
  - Pass 1: Channels 8..15 (Cols 8..15 active).
  - Passes per tile: 2. Total passes = $16 \times 2 = 32$ passes.
  - SRAM reads: 768 words/tile (+20.0% reload overhead).
* **16-PE Mode (4 passes):**
  - Pass 0: Channels 0..3 (Cols 0..3 active).
  - Pass 1: Channels 4..7 (Cols 4..7 active).
  - Pass 2: Channels 8..11 (Cols 8..11 active).
  - Pass 3: Channels 12..15 (Cols 12..15 active).
  - Passes per tile: 4. Total passes = $16 \times 4 = 64$ passes.
  - SRAM reads: 1024 words/tile (+60.0% reload overhead).

Total passes across all 3 modes = $16 + 32 + 64 = 112$ passes.
Expected runtime: $\approx 72$ seconds.
Total output elements validated per mode = $1,024$.
Total output elements validated across all modes = $3,072$.

