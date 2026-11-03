# TSK-17: Microarchitectural Implementation Gaps & Sparsity Roadmap

**Date:** 2026-11-02  
**Milestone:** TSK-17 Deliverable  
**Status:** Complete  
**Workspace:** `E:\MTech\LanChain\MTP\`  
**Target Systems:** `datapath_compute_feeder.sv`, `neural_acc_integrated_top.sv`, `layer_command_sequencer.sv`, `ofmap_drain_controller.sv`  

---

## 1. Overview and Purpose

This document provides a rigorous microarchitectural gap analysis between the theoretical CNN activation sparsity potential (demonstrated in [`TSK17_SPARSITY_FEASIBILITY_REPORT.md`](file:///E:/MTech/LanChain/MTP/TSK17_SPARSITY_FEASIBILITY_REPORT.md)) and the current physical implementation of the `Neural_Acc` accelerator RTL.

While the current PE leaf cell ([`mac_unit_40b.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv#L30-L55)) correctly zeroes multiplier products and bypasses additions when `act_data == 0` (reducing dynamic switching power), four fundamental microarchitectural gaps prevent the accelerator from translating activation sparsity into **execution cycle reduction, memory bandwidth reduction, or multi-pass channel-preserving PE scaling**.

This document outlines each gap in detail and provides an actionable engineering specification for future RTL implementation.

---

## 2. Microarchitectural Gap Analysis

```
===================================================================================================
GAP ID   SUBSYSTEM                 CURRENT RTL DEFICIENCY                    REQUIRED FUTURE RTL CAPABILITY
===================================================================================================
GAP-01   Feeder Datapath           Feeder unconditionally steps all K cycles Variable-K step engine with
         (datapath_compute_feeder) and fetches weights for zero activations  activation zero-lookahead bypass
---------------------------------------------------------------------------------------------------
GAP-02   Top-Level Integration     cycle_skipped & col_cycle_skipped ports   Memory-mapped 32-bit hardware
         (neural_acc_integrated)   left unconnected () at top level          telemetry performance counters
---------------------------------------------------------------------------------------------------
GAP-03   Tile Sequencer & Drain    Mode-dependent PE gating drops columns    Multi-pass tile accumulation engine
         (sequencer & ofmap_drain) in 1 pass, losing 50-75% output channels  with channel-offset addressing
---------------------------------------------------------------------------------------------------
GAP-04   Post-Processing Datapath  Accumulators produce raw 40-bit integers; On-chip requantization unit
         (output datapath)         no on-chip scale, shift, clamp, or ReLU   (Scale, Shift, Saturate, ReLU)
===================================================================================================
```

---

### Gap 1: Feeder Dynamic Zero-Bypass / Variable-K Step Engine

#### Current Implementation Failure
In [`datapath_compute_feeder.sv:140-220`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv#L140-L220), the feeder executes an inflexible, synchronous 3-state loop for every single step $k \in [0, K-1]$:
```
   +-------------------+      1 cycle       +-------------------+
   |   ST_PAR_REQ_W    | -----------------> |   ST_PAR_REQ_A    |
   | (Fetch Weights)   |                    | (Fetch Activation)|
   +-------------------+                    +-------------------+
             ^                                        |
             | 1 cycle                      1 cycle   v
             |                              +-------------------+
             +----------------------------- |  ST_PAR_COMPUTE   |
                                            | (Execute Array)   |
                                            +-------------------+
```
1. **Unconditional Weight Fetching:** Weight read requests (`ST_PAR_REQ_W`) are issued across active SRAM banks *before* inspecting whether the corresponding activation elements are zero. Even if all 4 row activations are zero, up to 8 packed weight words are read from SRAM.
2. **Fixed Execution Time:** Exactly $3 \times K$ cycles are elapsed regardless of whether activation sparsity is 0% or 99.5%.
3. **No Time Compression:** The multiplier zeroing in `mac_unit_40b` reduces dynamic power during `ST_PAR_COMPUTE`, but the accelerator clock cycles are never skipped.

#### Required Microarchitectural Specification
To achieve true cycle and memory bandwidth reduction from activation sparsity:
1. **Activation-First Scheduling:** Invert the fetch order or buffer activation vectors ahead of time (`ST_PREFETCH_A`).
2. **Row-Zero Lookahead Comparator:**
   ```systemverilog
   wire row_all_zero = (act_row0 == 16'd0) && (act_row1 == 16'd0) &&
                       (act_row2 == 16'd0) && (act_row3 == 16'd0);
   ```
3. **Dynamic Zero-Bypass State Transition:**
   - If `row_all_zero == 1'b1`:
     - Suppress SRAM weight read requests (`w_req = 1'b0`).
     - Advance the $K$-counter immediately: `k_step <= k_step + 1`.
     - Skip the compute cycle entirely.
   - Result: Execution time for zero steps collapses from 3 cycles to 0 or 1 cycle, reducing execution time proportionally to layer activation sparsity.

---

### Gap 2: Top-Level Telemetry and Performance Counter Disconnection

#### Current Implementation Failure
In [`neural_acc_integrated_top.sv:630-640`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/neural_acc_integrated_top.sv#L630-L640):
```systemverilog
    pe_array_40b u_pe_array (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (pe_array_en),
        .mode             (pe_mode),
        .weight_data      (feeder_weight_data),
        .act_data         (feeder_act_data),
        .accum_out        (pe_accum_out),
        .col_cycle_skipped(), // Disconnected
        .cycle_skipped    ()  // Disconnected
    );
```
1. **Floating Telemetry Signals:** `col_cycle_skipped` (indicating columns where all 4 rows encountered zero activations) and `cycle_skipped` (global array zero) are completely unconnected.
2. **No Hardware Observability:** Software drivers and testbenches cannot query how many operations or cycles were bypassed by the hardware.
3. **Verification Deficit:** Claims of zero-skipping can only be verified by probing internal signals with simulator waveforms, rather than reading documented hardware performance registers.

#### Required Microarchitectural Specification
1. **Memory-Mapped Telemetry Counters:**
   Add two 32-bit hardware performance registers to `neural_acc_integrated_top.sv`:
   - `CSR_CYCLES_SKIPPED` (Address `0x0040`): Increments whenever `cycle_skipped == 1'b1` during compute.
   - `CSR_USEFUL_MACS_COMPUTED` (Address `0x0044`): Increments by the number of active non-zero MAC operations.
2. **Integration with Command Sequencer:**
   Expose these counters to the host register bus so that testbenches and firmware can read exact hardware execution statistics at layer completion.

---

### Gap 3: Multi-Pass Tile Accumulation and Channel Offset Support

#### Current Implementation Failure
In the current implementation of [`adaptive_pe_controller.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv), [`neural_acc_integrated_top.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/neural_acc_integrated_top.sv), and [`ofmap_drain_controller.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/ofmap_drain_controller.sv):
1. **Column Physical Gating = Channel Truncation:**
   - In 16-PE mode, columns 4..15 are disabled. Only columns 0..3 (16 channels) write to SRAM.
   - The sequencer runs the tile in a single pass and marks layer completion.
   - For a layer with 64 output channels, running in 16-PE mode permanently discards channels 16..63 (75% of the tensor).
   - This causes fatal accuracy collapse (e.g., dropping from 92.48% to 10.00% on CIFAR-10).
2. **Lack of Multi-Pass Loop in Sequencer:**
   - The sequencer has no inner loop to iterate over channel chunks:
     $$\text{Passes} = \left\lceil \frac{C_{out}}{P} \right\rceil$$
   - A 16-PE array requires 4 passes ($4 \times 16 = 64$) to compute all 64 output channels.
3. **Lack of Base Address Offsetting in OFMAP Drain:**
   - `ofmap_drain_controller.sv` always writes output channels starting at `base_addr`.
   - In a multi-pass architecture, Pass $p$ must write to `base_addr + (p * 16 * words_per_pe)`.

#### Required Microarchitectural Specification
1. **Sequencer Multi-Pass FSM:**
   ```systemverilog
   logic [3:0] current_pass;
   logic [3:0] total_passes; // e.g., 4 passes for 16-PE mode on 64-channel tile

   always_ff @(posedge clk or negedge rst_n) begin
       if (!rst_n) begin
           current_pass <= 4'd0;
       end else if (drain_done) begin
           if (current_pass < total_passes - 1) begin
               current_pass <= current_pass + 1;
               start_feeder <= 1'b1; // Trigger next channel chunk
           end else begin
               layer_complete <= 1'b1;
           end
       end
   end
   ```
2. **OFMAP Drain Channel-Offset Addressing:**
   Modify `ofmap_drain_controller.sv` to accept `pass_index` and add `pass_index * CHANNELS_PER_PASS` to the destination SRAM bank and row addresses.
3. **Benefit:** Enables running layers on 16 or 32 PEs to conserve physical array power while computing **100% of output channels**, achieving zero accuracy loss.

---

### Gap 4: Hardware Requantization & Activation Unit (Scale, Shift, Clamp, ReLU)

#### Current Implementation Failure
1. **Accumulator Bit-Growth:**
   - Each PE in `pe_array_40b` outputs a 40-bit signed saturated integer.
   - However, the SRAM operand banks and feeder accept 16-bit packed activations (two 8-bit or one 16-bit word).
2. **Offline Software Workaround:**
   - In all existing testbenches and Python reference models, 40-bit output tensors are copied to host memory, where scaling, division, clamping, and ReLU are performed in software.
3. **No Closed-Loop Layer Pipelining:**
   - The hardware cannot feed the output of Layer $L$ directly into Layer $L+1$ on-chip without an on-chip activation unit.

#### Required Microarchitectural Specification
Implement an on-chip Post-Processing Unit (PPU) integrated between `pe_accum_out` and `ofmap_drain_controller`:
```systemverilog
module requantization_relu_unit (
    input  logic [39:0] accum_in,
    input  logic [15:0] scale_factor,
    input  logic [4:0]  shift_right,
    input  logic [15:0] bias_val,
    input  logic        enable_relu,
    output logic [15:0] requant_out
);
    logic signed [55:0] scaled_val;
    logic signed [39:0] shifted_val;
    logic signed [15:0] clamped_val;

    // Fixed-point scaling and bias addition
    assign scaled_val  = (accum_in * $signed(scale_factor)) + ($signed(bias_val) <<< shift_right);
    assign shifted_val = scaled_val >>> shift_right;

    // Saturation clamp to 16-bit signed range [-32768, 32767]
    always_comb begin
        if (shifted_val > 39'sd32767)
            clamped_val = 16'sh7FFF;
        else if (shifted_val < -39'sd32768)
            clamped_val = 16'sh8000;
        else
            clamped_val = shifted_val[15:0];
    end

    // ReLU activation: max(0, x)
    assign requant_out = (enable_relu && clamped_val[15]) ? 16'sd0 : clamped_val;
endmodule
```

---

## 3. Pre-Implementation Checklist & Safety Protocols

When implementing the above enhancements in subsequent tasks, the following constraints must be strictly preserved:

1. **Protected Baseline RTL Files:**
   The following files must **never** be edited or overwritten without explicit authorization:
   - `accelerator_core_top.sv`
   - `mac_unit_40b.sv`
   - `k_progress_tracker.sv`
   - `slot_control_unit.sv`
   - `hybrid_sram_bank.sv`
   *(All PE-level changes must be isolated to wrapper modules or top-level extensions).*

2. **Backward Compatibility:**
   - Any modifications to `datapath_compute_feeder.sv` or `neural_acc_integrated_top.sv` must preserve existing dense 64-PE, 32-PE, and 16-PE regression pass rates.
   - The default behavior with zero-skipping disabled must match existing TSK-12D testbench signatures bit-for-bit.

3. **Incremental Verification Gates:**
   - **Gate 1:** Standalone testbench for `requantization_relu_unit` verifying numerical correctness against `numpy` fixed-point arithmetic across $10^6$ pseudo-random inputs.
   - **Gate 2:** Verification of `datapath_compute_feeder` dynamic bypass on synthetic sparse patterns (0%, 50%, 75%, 90% zero activations) proving cycle reductions.
   - **Gate 3:** End-to-end multi-pass execution of a 64-channel layer on 16 PEs verifying bit-exact equivalence with the 64-PE dense run.

