# TSK-26C: Autonomous Sequencing Audit and Architectural Proposal

## Executive Summary

This audit assesses the extent of **hardware autonomy** in the current Neural_Acc RTL core regarding:
1. Spatial coordinate sequencing ($y, x$ loops)
2. Channel tiling passes ($C_{out}$ and $C_{in}$ tiling)
3. Partial-sum accumulator preservation across multi-pass execution
4. Output draining and requantization chaining
5. Multi-layer inference orchestration

---

## 1. Audit Findings: Hardware Autonomy vs Testbench Orchestration

### 1.1 Spatial Coordinate Sequencing
- **Current RTL Status: NOT AUTONOMOUS.**
  - `layer_command_sequencer.sv` receives only a scalar reduction length `cmd_k_total` and an integer `cmd_layer_id`. It has zero internal counters for spatial coordinates $(y, x)$, image dimensions ($H, W$), stride ($s$), or padding ($p$).
  - **Testbench Action:** The software testbench iterates over spatial coordinates in batches of 4, extracts the corresponding receptive fields via im2col, zero-pads the boundaries, and loads the aligned 5,760 words into Buffer A prior to pulsing `cmd_valid`.

### 1.2 Channel Tiling
- **Current RTL Status: PARTIALLY IMPLEMENTED / DISCONNECTED.**
  - A standalone hardware module `channel_tile_controller.sv` was developed in TSK-21 to sequence multi-pass channel tiling (2 passes for 32-PE, 4 passes for 16-PE).
  - **Audit Finding:** `channel_tile_controller.sv` is **NOT instantiated in the system top-level module** `neural_acc_integrated_top.sv`.
  - **Testbench Action:** In `tb_tsk26c_spatial_validation.sv` (and earlier in TSK-26B), multi-pass channel tiling is driven by the testbench issuing sequential layer commands (`cmd_valid` with incremented `cmd_layer_id`), preloading corresponding channel weight slices, and manually calculating Buffer B drain offsets.

### 1.3 Partial Sum Accumulator Preservation
- **Current RTL Status: NOT SUPPORTED ACROSS COMMANDS.**
  - In `adaptive_pe_controller.sv`, whenever `compute_start` is triggered by a new command, `pe_array_accum_clear` is asserted during the state transition, resetting all 64 accumulators to 0.
  - There is currently no `cmd_accum_preserve` or `cmd_accum_accumulate` control signal in `layer_command_sequencer.sv` to retain partial sums across multiple sequential commands.
  - **Implication:** The hardware cannot split a large input channel dimension (e.g. $K > 576$) across multiple Buffer A preloads while accumulating partial sums directly in the PE array accumulators.

### 1.4 Output Draining and Requantization
- **Current RTL Status: AUTONOMOUS DRAIN, DISCONNECTED REQUANTIZATION.**
  - Once computation finishes, `ofmap_drain_controller.sv` autonomously drains the active PE accumulators to SRAM Buffer B via Port A1 without host intervention.
  - However, `requantization_unit.sv` is a separate module not directly connected to Buffer B in `neural_acc_integrated_top.sv`.
  - **Testbench Action:** The testbench reads drained accumulators from Buffer B and streams them into the requantization unit.

### 1.5 Multi-Layer Chaining
- **Current RTL Status: NOT AUTONOMOUS.**
  - The accelerator lacks a hardware feedback datapath or internal loopback DMA to transfer requantized activations from Buffer B to Buffer A.
  - **Testbench Action:** The host reads requantized outputs from Layer 1, applies spatial padding, formats the im2col layout, and writes the input tensor for Layer 2 into Buffer A.

---

## 2. Architectural Proposal for Autonomous Hardware Sequencing

To achieve fully autonomous spatial, channel, and multi-layer sequencing without software intervention, the following architectural extensions are proposed for a future major RTL revision:

### Proposal A: 2D Spatial & Channel Tile Sequencer (`spatial_tile_sequencer.sv`)
- **Microarchitecture:**
  - Introduce hardware nested loop counters:
    - Inner loop: Channel tile pass ($p_{cout} \in [0, N_{cout}-1]$)
    - Middle loop: Spatial row ($y \in [0, H_{out}-1]$)
    - Outer loop: Spatial col ($x \in [0, W_{out}-1]$)
  - Hardware registers: `REG_IMAGE_H`, `REG_IMAGE_W`, `REG_STRIDE`, `REG_PAD`, `REG_CHANNELS_IN`, `REG_CHANNELS_OUT`.
- **Operation:**
  - Upon receiving a single `layer_start` command, the sequencer iterates through all spatial and channel tiles autonomously, signaling `datapath_compute_feeder` and `ofmap_drain_controller` beat-by-beat until the entire layer feature map is complete.

### Proposal B: Accumulator Accumulate Mode (`ACCUM_PRESERVE`)
- **Microarchitecture:**
  - Add a 1-bit control input `cmd_accum_mode` (0: CLEAR, 1: ACCUMULATE) to `layer_command_sequencer` and `adaptive_pe_controller`.
  - When `cmd_accum_mode == 1`, suppress the `pe_array_accum_clear` pulse at compute start.
- **Benefit:**
  - Allows reduction dimensions larger than SRAM buffer capacity ($K > 576$, e.g. $K=1152, 2304, 4608$) to be evaluated across multiple passes while accumulating partial sums directly in the 40-bit PE registers.

### Proposal C: Integrated Buffer B-to-A DMA Loopback & Line Buffer
- **Microarchitecture:**
  - Wire the output stream of `requantization_unit.sv` directly into an internal line-buffer FIFO.
  - Implement a hardware sliding-window address generator that translates raster-scan feature maps into 9-tap $3 \times 3$ receptive fields on-the-fly.
  - Connect a loopback AXI streaming channel from the requantizer output back into SRAM Write Port A0.
- **Benefit:**
  - Completely eliminates host intervention between consecutive convolution layers, enabling end-to-end hardware inference pipelines.

