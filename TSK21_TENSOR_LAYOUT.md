# TSK-21 Tensor Layout & Memory Mapping Specification

**Project:** Neural_Acc Accelerator  
**Task:** TSK-21 Multi-Pass Channel Tiling & Inter-Layer Handoff  
**Date:** November 2026  

---

## 1. Architectural Motivation & Analysis of Prior Limitation

### 1.1 The Single-Pass Channel Truncation Problem
In the Phase 2 baseline design:
- The physical PE array consists of 4 rows and 16 columns (64 PEs total).
- Each PE column computes one output feature channel ($C_{out}$).
- 4 rows process 4 spatial or batch activations ($N \times H \times W$) concurrently.
- In **64-PE Mode (`2'b10`)**, all 16 physical columns (4 rows $\times$ 16 cols = 64 MACs) are active, computing 16 output channels across 4 spatial locations. The OFMAP drain writes 128 32-bit words (64 40-bit accumulators $\times$ 2 words/accumulator) into SRAM starting at `DEFAULT_OFMAP_BASE` (`14'h2000`).
- In **32-PE Mode (`2'b01`)**, columns 8..15 are clock-gated. Only 8 columns are active. The drain controller was hardcoded to drain only $8 \times 4 \times 2 = 64$ words (32 accumulators = 8 channels).
- In **16-PE Mode (`2'b00`)**, columns 4..15 are clock-gated. Only 4 columns are active. The drain controller drained only $4 \times 4 \times 2 = 32$ words (16 accumulators = 4 channels).

**Impact on CNN Inference Quality:**
In a standard CNN (e.g. ResNet-18 or VGG-16), a convolutional layer expects 64 output channels. If execution stops after a single pass in 16-PE or 32-PE mode, 75% or 50% of the output channels are completely omitted (truncated to zero). This caused the severe quality collapse observed in early TSK-15 audits (top-1 accuracy dropping to ~10%).

### 1.2 Multi-Pass Channel Tiling Solution
To preserve **100% of required output channels** under constrained PE configurations:
- The total output channel set $C_{out}$ is divided into tiles matching the active column count $C_{tile}$:
  - **64-PE Mode:** $C_{tile} = 16$ channels/pass $\to 1$ pass preserves 16 channels $\times$ 4 rows = 64 accumulators.
  - **32-PE Mode:** $C_{tile} = 8$ channels/pass $\to 2$ passes preserve $2 \times 8 = 16$ channels $\times$ 4 rows = 64 accumulators.
  - **16-PE Mode:** $C_{tile} = 4$ channels/pass $\to 4$ passes preserve $4 \times 4 = 16$ channels $\times$ 4 rows = 64 accumulators.
- The **Channel Tile Controller** coordinates multi-pass scheduling:
  - Maintains the current tile pass index $p \in [0 .. N_{passes}-1]$.
  - Calculates the destination SRAM address offset:  
    $$\text{tile\_ofmap\_base} = \text{base\_addr} + (p \times \text{words\_per\_tile})$$
  - Points the feeder to the corresponding weight slice for channel tile $p$.
  - Coordinates accumulator clearing between passes.
  - Triggers the OFMAP drain after each pass.
  - Pulses `layer_all_tiles_done` when all passes have finished, ensuring all 128 words (64 accumulators) are completely written to SRAM.

---

## 2. Memory Organization & Buffer Mapping

The 41,472-Byte Multi-Bank SRAM is partitioned into logical regions:

| Buffer Name | Base Address (Word) | Base Address (Byte) | Size (Words) | Size (Bytes) | Description |
|---|---|---|---|---|---|
| **Ping-Pong Buffer A** | `14'h0000` | `0x0000` | 1024 | 4096 | Ingestion Buffer A: Input activations (16-bit packed) |
| **Ping-Pong Buffer B** | `14'h1000` | `0x4000` | 1024 | 4096 | Ingestion Buffer B: Input activations (16-bit packed) |
| **OFMAP Partial Sums** | `14'h2000` | `0x8000` | 1024 | 4096 | Output Partial Sums: 40-bit unquantized accumulators (2 words/val) |
| **Requantized Activations** | `14'h2400` | `0x9000` | 512 | 2048 | Post-Requantization Output: 16-bit packed activations |
| **Scratchpad Weights** | `14'h0800` | `0x2000` | 2048 | 8192 | Filter weights partitioned by tile |

### 2.1 Accumulator Packing (40-bit Unquantized)
Each 40-bit signed accumulator $A[39:0]$ from PE$(r, c)$ is serialized into two consecutive 32-bit SRAM words:
- **Even Word ($2i$):** $A[31:0]$ (lower 32 bits)
- **Odd Word ($2i+1$):** $\{\{24\{A[39]\}\}, A[39:32]\}$ (sign-extended upper 8 bits)

### 2.2 Requantized Activation Packing (16-bit Quantized)
Each requantized 16-bit signed activation $Q[15:0]$ is packed in pairs:
- **Word $j$:** $\{Q_{2j+1}[15:0], Q_{2j}[15:0]\}$
- Word contains two activations corresponding to consecutive spatial or channel indices.

---

## 3. Requantization Specification

To enable inter-layer chaining, the 40-bit accumulator must be scaled and packed back into 16-bit format:
$$Y = \text{clamp}\left(\left\lfloor \frac{A + \text{round\_offset}}{2^S} \right\rfloor, -32768, 32767\right)$$
If $\text{relu\_en} = 1$:
$$Y_{relu} = \max(0, Y)$$

Where:
- $S \in [0..31]$ is the programmable bit right-shift (`cfg_scale_shift`).
- $\text{round\_offset} = 2^{S-1}$ if $S > 0$ and rounding is enabled, else 0.
- Signed saturation prevents overflow wrapping.

