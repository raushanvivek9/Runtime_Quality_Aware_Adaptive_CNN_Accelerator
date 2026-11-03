# TSK-26C: Hardware-Software Functional Partitioning Analysis

## Executive Overview

This document provides a rigorous architectural demarcation between operations natively supported inside the **Neural_Acc RTL hardware** and operations orchestrated by the **Host Software Driver / Verification Harness** during spatial feature-map execution and multi-layer network inference.

---

## 1. Functional Responsibility Matrix

| Subsystem / Operation | Executed in Hardware RTL | Executed in Host / Software Driver | Detailed Architectural Implementation |
| :--- | :---: | :---: | :--- |
| **MAC Array Dot-Product Reduction** | **YES** | NO | 64 physical MAC units ($4 \times 16$), 40-bit saturating adders, sticky flags (`pe_array_40b.sv`, `mac_unit_40b.sv`). |
| **Inner-Product $K$-Dimension Progression** | **YES** | NO | Feeder steps autonomously across `cmd_k_total` (up to $K=576$) (`datapath_compute_feeder.sv`). |
| **Zero-Activation Detection & Cycle Skip** | **YES** | NO | Real-time zero detection on Bank 0/1 operands, bypasses weight fetch and compute cycles (`datapath_compute_feeder.sv`). |
| **Multi-Bank SRAM Read Arbitration** | **YES** | NO | 8 independent banks with low-order interleaving, conflict detection, and telemetry (`multibank_sram_subsystem.sv`). |
| **Dynamic Column Power Gating** | **YES** | NO | Hardware active column masking (16-PE, 32-PE, 64-PE) (`adaptive_pe_controller.sv`). |
| **OFMAP Accumulator Drain** | **YES** | NO | Drains 64 accumulators to Buffer B across active columns (`ofmap_drain_controller.sv`). |
| **Requantization & Saturation** | **YES** | NO | Scale arithmetic shift >> 12, rounding (+2048), ReLU, INT16 saturation, 32-bit packing (`requantization_unit.sv`). |
| **Spatial Coordinate Sequencing ($y, x$)** | NO | **YES** | RTL has no 2D coordinate counters or line buffers; host generates spatial batch offsets. |
| **Spatial Boundary Zero-Padding ($p=1$)** | NO | **YES** | Host zero-pads image boundaries prior to receptive field extraction. |
| **Im2Col Receptive Field Extraction** | NO | **YES** | Host constructs the 576-element vector ($C_{in} \times 3 \times 3$) for each spatial position. |
| **Multi-Pass Channel Tiling ($C_{out}$)** | NO | **YES** | In integrated top, host sequences passes (1 pass for 64-PE, 2 for 32-PE, 4 for 16-PE). |
| **Inter-Pass Partial Sum Accumulation** | NO | **YES** | Hardware clears accumulators per command; multi-pass reduction accumulation requires host management. |
| **Inter-Layer Activation Handover** | NO | **YES** | Host routes drained/requantized Buffer B outputs into Buffer A for Layer 2. |
| **Residual Shortcut Addition (ResNet-18)** | NO | **YES** | Element-wise residual addition ($x + F(x)$) is performed by host. |
| **Spatial Pooling (VGG-16-BN MaxPool)** | NO | **YES** | MaxPool ($2 \times 2$, stride 2) is evaluated by host between feature stages. |

---

## 2. In-Depth Operational Analysis

### 2.1 Receptive Field Generation and Im2Col
The Neural_Acc compute feeder expects input activations in Buffer A to be sequentially formatted such that step $k \in [0, 575]$ contains the corresponding channel and kernel slice for all 4 PE rows:
$$\text{Word 8: } \{\text{Act}[1, k], \text{Act}[0, k]\}, \quad \text{Word 9: } \{\text{Act}[3, k], \text{Act}[2, k]\}$$
The translation from a 3D activation tensor $[C_{in}, H, W]$ with zero-padding ($p=1$) and stride ($s=1$ or $s=2$) into this hardware-aligned sequential format is performed by the host driver. The hardware accelerator does not contain a 2D rasterizer, line buffer, or address stride generator.

### 2.2 Parallel Spatial Batching
The PE array consists of $ROWS = 4$ independent rows. Neural_Acc exploits this structure by assigning **each row to an independent spatial output location**:
- Row 0 $\implies$ Output coordinate $(y_0, x_0)$
- Row 1 $\implies$ Output coordinate $(y_1, x_1)$
- Row 2 $\implies$ Output coordinate $(y_2, x_2)$
- Row 3 $\implies$ Output coordinate $(y_3, x_3)$
Because all 4 rows share the same column weights via broadcast, 4 spatial output positions are evaluated in parallel in a single hardware pass.

### 2.3 Inter-Layer Dataflow and Requantization
Between consecutive convolution layers (e.g. ResNet-18 `layer1.0.conv1` and `layer1.0.conv2`):
1. **Layer 1 Compute:** Executed entirely inside Neural_Acc RTL core.
2. **Layer 1 Drain:** 40-bit accumulators drained to SRAM Buffer B.
3. **Requantization:** Drained accumulators pass through `requantization_unit.sv` (arithmetic shift by 12, rounding, ReLU, and INT16 packing).
4. **Buffer Transfer:** Host driver reads requantized INT16 values, formats the $3 \times 3$ receptive fields with border padding, and preloads Buffer A for Layer 2.
5. **Layer 2 Compute:** Executed entirely inside Neural_Acc RTL core consuming the Layer 1 hardware outputs.

This explicit partition ensures that hardware execution claims are strictly limited to the datapath operations genuinely computed by RTL, while host orchestration is transparently documented.

