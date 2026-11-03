# TSK-26C: Technical Scope, Operational Boundaries, and Limitations

## Objective Assessment of Milestone Scope

This document provides a transparent boundary analysis of Milestone **TSK-26C**, detailing what has been proven through cycle-accurate hardware simulation and what remains an in-scope limitation or future architectural goal.

---

## 1. What Has Been Proven

### 1.1 Complete Spatial Feature-Map Validation (Deep Layer)
- In the deep layer (VGG-16-BN `features.37`), the output spatial dimensions are $2 \times 2 = 4$ spatial positions.
- All 4 spatial positions $(0,0), (0,1), (1,0), (1,1)$ were executed simultaneously across the 4 physical rows of the PE array.
- Output accumulators matched the mathematical golden reference with **0 mismatches (100.0% match rate, 100.0% spatial coverage)**.

### 1.2 Multi-Position Spatial Grid Validation (Early & Middle Layers)
- In the middle layer (VGG-16-BN `features.14`, $8 \times 8$ grid) and early layer (ResNet-18 `layer1.0.conv1`, $32 \times 32$ grid), multi-position spatial batches covering corners, edges, and interior coordinates were validated with **0 mismatches**.
- Verified that boundary zero-padding ($p=1$), stride ($s=1$), and 2D spatial receptive fields behave correctly in hardware.

### 1.3 True Sequential Multi-Layer Chaining
- Executed two consecutive convolution layers: ResNet-18 `layer1.0.conv1` followed by `layer1.0.conv2`.
- Layer 2 consumed the actual hardware-generated, requantized outputs from Layer 1 without host numerical substitution.
- Both layers matched their respective golden references with **0 mismatches**.

### 1.4 Cross-Mode Bit-Exact Equivalence
- Outputs are identical whether executed in 64-PE (1 pass), 32-PE (2 passes), or 16-PE (4 passes) mode (0 mismatches).

### 1.5 Real Activation Sparsity Acceleration
- Post-ReLU zero-activation skipping achieved 42.2% to 50.1% cycle reductions and 25.0% to 50.6% memory read reductions across all tested spatial positions.

---

## 2. Technical Limitations and In-Scope Constraints

### 2.1 Software-Orchestrated Spatial Sequencing
- The hardware RTL lacks an autonomous 2D spatial sequencer ($y, x$ loop counters).
- Im2col receptive field extraction, spatial zero-padding, and Buffer A address alignment are performed by the software driver prior to hardware execution.

### 2.2 Simulation Feasibility vs Full Early-Layer Rasterization
- In software-interpreted RTL simulation (Icarus Verilog), executing all $1,024$ spatial positions for an early $32 \times 32$ layer across all channel passes would require $\sim 45$ minutes of simulation time.
- Therefore, spatial validation for early and middle layers was performed over representative multi-position coordinate grids (corners, boundaries, center) rather than full $1,024$-pixel rasterization.

### 2.3 Channel Tiling Top-Level Disconnection
- While a standalone `channel_tile_controller.sv` exists, it is not instantiated in `neural_acc_integrated_top.sv`.
- Multi-pass channel tiling was sequenced by the testbench issuing sequential layer commands.

### 2.4 Lack of Accumulator Partial Sum Preservation
- In the current RTL, every `compute_start` triggers an accumulator clear pulse (`pe_array_accum_clear`).
- Reduction lengths larger than single-pass Buffer A capacity ($K > 576$) cannot accumulate partial sums directly in the PE array accumulators across multiple commands.

### 2.5 Non-Convolutional Layers
- BatchNorm, pooling, and residual additions were evaluated outside the RTL core by the host software.

### 2.6 Energy Claims
- Consistent with project guidelines, all performance metrics are reported in simulated clock cycles and memory transactions. No physical energy numbers are claimed without gate-level power simulation.

