# TSK-24: Limitations and Architectural Scope

## 1. Executive Summary

This document details the architectural boundaries, algorithmic scope, quantization characteristics, and hardware limitations of the **Neural_Acc** accelerator evaluated during milestone **TSK-24 (Real CNN Numerical Validation & Cross-Mode Equivalence)**.

The purpose is to explicitly delineate what the RTL hardware core directly executes, what is delegated to host/DMA memory mapping, and what remains future research.

---

## 2. Architectural Scope & Boundary Definition

Neural_Acc is a specialized **matrix-multiply / inner-product systolic-array engine** optimized for activation-sparse convolutional channel evaluation. It is not an autonomous stand-alone System-on-Chip (SoC) or full CNN graph processor.

### 2.1 Implemented in Accelerator Hardware (RTL)
1. **Inner-Product Reduction Engine**:
   - $4 \times 16$ parallel Processing Elements (64 PEs) computing 16-bit signed integer multiplications into 40-bit saturating accumulators over reduction dimension $K$.
2. **Channel Tiling & Multi-Pass Execution**:
   - Dynamic mode allocation supporting 16-PE (4 channel passes), 32-PE (2 channel passes), and 64-PE (single pass) configurations.
   - Hardware de-interleaving and row-major draining of partial channel tiles into multi-bank SRAM.
3. **Activation-Sparse Feeder FSM**:
   - Real-time exact-zero activation detection across 4 spatial rows.
   - Zero-skipping FSM that bypasses SRAM weight reads and compute latency whenever all 4 spatial activations in a reduction step are zero.
   - Fine-grained PE-level MAC clock/operand gating for partial-zero rows.
4. **Requantization & Word Packing**:
   - Post-accumulation scaling via arithmetic right shift ($S \in [0, 31]$).
   - Unbiased Round-Half-Up tie breaking.
   - Clamping to signed 16-bit boundaries ($[-32768, +32767]$) and optional ReLU ($x = \max(0, x)$).
   - Two-element 16-bit packing into 32-bit words for memory storage.

### 2.2 Delegated to Host / External Memory Mapping
1. **im2col Unfolding**:
   - Convolutional sliding-window addressing, padding insertion, and spatial flattening are performed before SRAM loading or during DMA ingestion. The accelerator operates directly on unrolled GEMM matrix representations.
2. **Convolutional Bias Addition**:
   - The datapath accumulates $A \times W$ inner products. In typical deployment, channel bias is either added via accumulator preload (initializing accumulators with bias rather than 0) or during host post-processing.
3. **Spatial Pooling (MaxPool / AvgPool)**:
   - Max-pooling and average-pooling layers are not supported in the accelerator datapath and must execute in host software or a dedicated hardware pooling unit.
4. **Non-ReLU Activations**:
   - The on-chip requantizer implements ReLU clamping. Complex non-linearities (e.g., GELU, SiLU, Softmax) are not present in hardware.

---

## 3. Workload Coverage Limitations

In TSK-24, four representative layers from torchvision pretrained ResNet-18 were validated:
1. `layer1.0.conv1` ($64 \to 64$, $K=64$ slice, early conv)
2. `layer1.0.relu` ($64 \to 64$, post-ReLU sparsity)
3. `layer2.0.conv1` ($64 \to 128$, middle downsampling conv)
4. `layer3.0.conv1` ($128 \to 256$, deep conv)

### Limitations of Current Workload Coverage:
- **Spatial Slice Size**: Validation evaluated representative 4-row spatial patches $\times$ 16 output channels per pass ($K=64$ and $K=128$). Full feature maps (e.g., $56 \times 56 = 3136$ spatial points) require looping external host DMA transfers across multiple tiles.
- **Whole-Model Graph Chaining**: While inter-layer buffer ping-ponging was validated, end-to-end multi-layer execution across all 18 layers of ResNet-18 with residual skip connections requires a higher-level host graph scheduler.

---

## 4. Quantization Limitations

1. **Per-Tensor Symmetric Quantization**:
   - Neural_Acc currently uses uniform per-tensor signed INT16 scaling.
   - Per-channel weight quantization (where each output filter has an individual scale factor) is not supported in the unified hardware shifter without per-column shift registers.
2. **Operand Precision**:
   - Operands are strictly signed INT16 $\times$ INT16 $\to$ 40-bit accumulator. INT8 or INT4 low-precision arithmetic is not supported in this RTL baseline.
3. **Requantization Shift Uniformity**:
   - The shift value `cfg_scale_shift` applies uniformly across all 16 columns within a single layer pass.

---

## 5. Memory System & Capacity Constraints

1. **On-Chip SRAM Capacity**:
   - Total SRAM macro capacity is 8 banks $\times$ 1024 words = 8192 words (32 KB) per ping-pong buffer (Buffer A: `0x0000..0x0FFF`, Buffer B: `0x1000..0x1FFF`).
   - At 10 words per $k$ step (8 weight words + 2 activation words), a single ping buffer can hold up to $K \approx 400$ reduction steps. Reduction dimensions exceeding $K=400$ require inter-pass partial sum accumulation in SRAM or external DRAM buffering.
2. **Channel Tiling Reload Overhead**:
   - In 32-PE mode (2 passes) and 16-PE mode (4 passes), activations must be re-read for each channel pass. For $K=64$, 32-PE mode reads 768 words (+20.0%) and 16-PE mode reads 1024 words (+60.0%) compared to 64-PE single-pass mode (640 words).

---

## 6. Controller & Sparsity Exploitation Limitations

1. **Static vs Dynamic Mode Selection**:
   - In TSK-24, 16-PE, 32-PE, and 64-PE modes were evaluated under static software control (`cmd_pe_mode`) to rigorously prove cross-mode numerical equivalence.
   - Hardware degradation prediction (`adaptive_pe_controller.sv`) evaluates degradation thresholds against pre-programmed `degradation_hat` values, but dynamic switching within a single layer tile is constrained by accumulator tiling boundaries.
2. **Coarse-Grained Feeder Skipping**:
   - The feeder skips SRAM weight reads and saves cycles only when **all 4 spatial rows** are zero simultaneously.
   - When 1, 2, or 3 rows are zero (partial zero steps), the feeder still fetches weights from SRAM, though individual PE accumulators are gated to prevent dynamic toggle power.
   - Real CNN activation sparsity showed 9.4% to 27.3% quad-row all-zero steps, compared to 21.9% to 56.8% element-wise sparsity. Fully exploiting element-wise sparsity would require asynchronous PE FIFOs or compressed sparse column (CSC) storage, which significantly increases hardware complexity.
3. **Activation Sparsity Only**:
   - Neural_Acc exploits dynamic activation sparsity (post-ReLU zeros). Static weight sparsity (pruning) is not exploited for skipping by the current feeder.

---

## 7. Summary Matrix of Limitations

| Dimension | Neural_Acc RTL Capability | Host / External Responsibility | Future Research Scope |
| :--- | :--- | :--- | :--- |
| **Arithmetic** | 16b $\times$ 16b MAC, 40b accum, saturating add | Im2col unfolding, channel bias, pooling | INT8/INT4 precision, per-channel scaling |
| **Activation Functions** | Hard ReLU, clamping $[-32768, 32767]$ | Non-linear activations (GELU, Softmax) | Piecewise linear approximation engine |
| **Tiling** | 16/32/64-PE multi-pass channel tiling | Multi-tile spatial tiling & DRAM orchestration | Autonomous spatial tiling DMA sequencer |
| **Sparsity** | Quad-row feeder skip, individual PE clock-gating | Reordering/clustering rows to maximize quad zeros | Asynchronous decoupled sparse buffers |
| **Layer Chaining** | Ping-pong buffer handoff (A $\to$ B $\to$ A) | Residual addition (ResNet skip connections) | On-chip residual bypass accumulator |

