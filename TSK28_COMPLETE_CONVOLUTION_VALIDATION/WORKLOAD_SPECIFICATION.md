# TSK-28 Workload Specification Report

## 1. Workload Provenance & Identification

| Parameter | Specification Details |
| :--- | :--- |
| **Model Name** | ResNet-18 |
| **Dataset** | CIFAR-10 (Deterministic Test Split) |
| **Source Checkpoint** | `edadaltocg/resnet18_cifar10` (HuggingFace Hub) |
| **Local Checkpoint Path** | `TSK26B_REAL_CNN_VALIDATION/models/resnet18_cifar10.pt` |
| **Checkpoint SHA256** | `6e0828751430f8072186716ca22fb39a7b752df85aa3ef9745d06d44a1da6ef9` |
| **Target Layer** | `layer1.0.conv1` (First convolutional layer in residual block 1) |
| **Input Feature Map Provenance** | Propagated through `conv1 -> bn1 -> relu` using sample 0 of `cifar10_test100.pt` |

---

## 2. Convolution Layer Architectural Parameters

```text
Input Feature Map:   (Batch=1, Cin=64, H=32, W=32)
Weight Filter Bank:  (Cout=64, Cin=64, Kh=3, Kw=3)
Stride:              (s_y=1, s_x=1)
Padding:             (p_y=1, p_x=1) with constant zero padding
Output Feature Map:  (Batch=1, Cout=64, H=32, W=32)
```

### Complete Layer Slicing for Hardware Evaluation
To enable bit-exact hardware RTL execution of a complete, self-contained 2D spatial feature map while maintaining 100% reduction depth:
- **Output Channel Slice**: $C_{out} = 16$ channels (matching the 16 physical columns of the PE array).
- **Spatial Grid**: $W_{tiles} = 4, H_{tiles} = 4$ ($16$ distinct 2D spatial coordinates).
- **Input Channels**: $C_{in} = 64$ (full channel depth, no channel truncation).
- **Kernel Size**: $3 \times 3$ (all 9 spatial kernel elements computed).

---

## 3. Reduction Depth & Multi-Chunk Partitioning

For each output spatial element, the complete mathematical convolution requires:
$$K_{total} = K_H \times K_W \times C_{in} = 3 \times 3 \times 64 = 576 \text{ reduction terms}$$

### 3.1 Chunk Partitioning Breakdown
The 576 terms are partitioned into $N_{chunks} = 9$ chunks of $K_{chunk} = 64$ terms:

| Chunk Index | Kernel Coordinate $(K_y, K_x)$ | Channel Slice | Terms | Accumulator Action | OFMAP Drain Action |
| :---: | :---: | :---: | :---: | :---: | :---: |
| **0** | $(0, 0)$ | $C_{in}[0..63]$ | 64 | **Clear Accumulator** (`accum_clear=1`) | **Suppressed** (`drain_req=0`) |
| **1** | $(0, 1)$ | $C_{in}[0..63]$ | 64 | **Preserve Partial Sum** (`accum_clear=0`) | **Suppressed** (`drain_req=0`) |
| **2** | $(0, 2)$ | $C_{in}[0..63]$ | 64 | **Preserve Partial Sum** (`accum_clear=0`) | **Suppressed** (`drain_req=0`) |
| **3** | $(1, 0)$ | $C_{in}[0..63]$ | 64 | **Preserve Partial Sum** (`accum_clear=0`) | **Suppressed** (`drain_req=0`) |
| **4** | $(1, 1)$ | $C_{in}[0..63]$ | 64 | **Preserve Partial Sum** (`accum_clear=0`) | **Suppressed** (`drain_req=0`) |
| **5** | $(1, 2)$ | $C_{in}[0..63]$ | 64 | **Preserve Partial Sum** (`accum_clear=0`) | **Suppressed** (`drain_req=0`) |
| **6** | $(2, 0)$ | $C_{in}[0..63]$ | 64 | **Preserve Partial Sum** (`accum_clear=0`) | **Suppressed** (`drain_req=0`) |
| **7** | $(2, 1)$ | $C_{in}[0..63]$ | 64 | **Preserve Partial Sum** (`accum_clear=0`) | **Suppressed** (`drain_req=0`) |
| **8** | $(2, 2)$ | $C_{in}[0..63]$ | 64 | **Preserve Final Sum** (`accum_clear=0`) | **Request Drain** (`drain_req=1`) |

**Total Reductions per Output Activation**: $9 \times 64 = 576$ MACs.  
**Total Output Elements Evaluated**: $16 \text{ positions} \times 16 \text{ channels} = 256$ activations.  
**Total Hardware MAC Operations**: $256 \times 576 = 147,456$ MAC operations.

---

## 4. Boundary & Padding Conditions
The evaluated $4 \times 4$ spatial grid covers all topological receptive field conditions:
1. **Corner Positions**:
   - $(0, 0)$: Top-left corner (top and left kernel rows/cols are zero-padded).
   - $(0, 3)$: Top-right corner (top and right kernel rows/cols are zero-padded).
   - $(3, 0)$: Bottom-left corner (bottom and left kernel rows/cols are zero-padded).
   - $(3, 3)$: Bottom-right corner (bottom and right kernel rows/cols are zero-padded).
2. **Edge Positions**:
   - $(0, 1), (0, 2)$: Top edges (top row zero-padded).
   - $(1, 0), (2, 0)$: Left edges (left column zero-padded).
   - $(1, 3), (2, 3)$: Right edges (right column zero-padded).
   - $(3, 1), (3, 2)$: Bottom edges (bottom row zero-padded).
3. **Interior Positions**:
   - $(1, 1), (1, 2), (2, 1), (2, 2)$: Fully internal receptive fields (all $3 \times 3 \times 64$ inputs are active image features).

---

## 5. Fixed-Point Quantization & Datapath Semantics

- **Activation Format**: Signed 16-bit Fixed-Point Q4.12 ($scale = 4096.0$).
- **Weight Format**: Signed 16-bit Fixed-Point Q4.12 ($scale = 4096.0$).
- **Multiplication Product**: Signed 32-bit Q8.24 ($16\text{-bit} \times 16\text{-bit}$).
- **Accumulator Register**: Signed 40-bit fixed-point (`accum_out`).
  - Headroom: 8 guard bits above 32-bit product to prevent overflow during 576-term accumulation.
  - Saturation Bounds: $[-2^{39}, 2^{39}-1] = [-549,755,813,888, +549,755,813,887]$.
- **Requantization**: Division by $4096.0$ ($\gg 12$), rounding to nearest integer, clipping to $[-32768, 32767]$ (INT16), followed by ReLU ($\max(0, x)$).

