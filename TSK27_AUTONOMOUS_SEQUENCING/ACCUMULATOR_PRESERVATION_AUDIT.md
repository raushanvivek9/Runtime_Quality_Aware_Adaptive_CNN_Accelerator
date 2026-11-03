# TSK-27B: Accumulator Preservation Engineering Audit
## Investigation into Accumulator Clearing, Drain Lifetime, and Multi-Pass Reduction Feasibility

**Milestone Identifier:** TSK-27B  
**Project:** Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Status:** COMPLETE (Root Causes Audited & Standalone Controller Architecture Ratified)  
**Baseline RTL Status:** 100% Preserved (0 Diffs to Protected RTL Files)  

---

## 1. Executive Summary & Objective

In convolution neural networks, when the reduction dimension $K = C_{in} \times K_h \times K_w$ exceeds the maximum single-pass hardware buffer or tile limit $K_{max\_tile}$ (e.g., $K > 576$), execution must be partitioned into multiple sequential $K$-chunks:
$$Y = \sum_{k=0}^{K-1} X_k \cdot W_k = \sum_{chunk=0}^{N_{chunks}-1} \left( \sum_{i=0}^{K_{chunk}-1} X_{chunk, i} \cdot W_{chunk, i} \right)$$
For correct hardware execution:
1. **Chunk 0:** Accumulators must be cleared to 0, and the first partial product chunk accumulated.
2. **Intermediate Chunks ($0 < chunk < N_{chunks}-1$):** Accumulators must **NOT** be cleared; they must retain the running partial sum. Furthermore, OFMAP draining must be **suppressed** so incomplete sums are not prematurely committed to memory.
3. **Final Chunk ($chunk = N_{chunks}-1$):** Accumulators add the final chunk products, sticky saturation is finalized, and the complete 40-bit accumulated feature map is drained to Buffer B / requantization unit.

**Audit Goal:** Investigate every level of the existing Neural_Acc RTL hierarchy to determine whether the current hardware interfaces support multi-pass reductions without losing partial sums.

---

## 2. Component-by-Component RTL Lifetime Audit

### 2.1 Arithmetic Datapath: `mac_unit_40b.sv` (Protected Baseline)

Inspection of lines 63–90 in [`mac_unit_40b.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv):
```verilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        accum_out         <= '0;
        sticky_saturation <= 1'b0;
    end else begin
        if (sat_clear) begin
            sticky_saturation <= 1'b0;
        end

        // Accumulator clearing
        if (accum_clear) begin
            accum_out <= '0;
        end else if (enable && !bypass_mac) begin
            // Saturating addition onto existing accum_out
            if (sum_41 > 41'sh07F_FFFF_FFFF) begin
                accum_out         <= SAT_MAX_POS;
                sticky_saturation <= 1'b1;
            end else if (sum_41 < -41'sh080_0000_0000) begin
                accum_out         <= SAT_MAX_NEG;
                sticky_saturation <= 1'b1;
            end else begin
                accum_out         <= sum_41[ACCUM_WIDTH-1:0];
            end
        end
    end
end
```
- **Audit Verdict:** **CAPABLE OF ACCUMULATION.**
- The signed 40-bit saturating MAC unit natively retains its previous accumulator value (`accum_out`) whenever `accum_clear == 1'b0`. When enabled, it calculates `sum_41 = accum_out + product_32`.
- Therefore, the physical MAC arithmetic datapath has **zero architectural barrier** to multi-pass accumulator preservation.

---

### 2.2 PE Array Subsystem: `pe_array_40b.sv` (Non-Protected RTL)

Inspection of lines 122–144 in [`pe_array_40b.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/pe_array_40b.sv):
- The 4-row $\times$ 16-column PE array exposes a global `accum_clear` input port which is routed directly to all 64 instantiated `mac_unit_40b` instances.
- If `accum_clear` is held at `1'b0`, all 64 accumulators preserve their partial sums across consecutive cycles.

---

### 2.3 Single-Core Baseline: `accelerator_core_top.sv` & `slot_control_unit.sv` (Protected Baseline)

Inspection of lines 84–95 in [`slot_control_unit.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv):
```verilog
ST_FREE: begin
    if (alloc_req) begin
        state_d = ST_ALLOCATED;
    end
end

ST_ALLOCATED: begin
    // Initialize slot accumulator on first allocation
    accum_clear = 1'b1; // <--- UNCONDITIONAL CLEAR
    state_d     = ST_COMPUTING;
end
```
- **Audit Verdict:** **DEFECT / CLEAR-ON-ALLOCATE LIMITATION.**
- In `slot_control_unit.sv`, entering `ST_ALLOCATED` on every `alloc_req` unconditionally pulses `accum_clear = 1'b1`.
- The module has **no input port** (e.g., `cmd_accum_preserve` or `chunk_idx`) to suppress this pulse.
- **Protected File Impact:** Because `accelerator_core_top.sv` and `slot_control_unit.sv` are protected baseline files, integrating accumulator preservation directly into `accelerator_core_top` would require modifying protected RTL. Per task guidelines, **no modifications were made to protected files**, and the required changes are formally documented below.

---

### 2.4 Integrated System: `adaptive_pe_controller.sv` & `layer_command_sequencer.sv`

Inspection of lines 138–156 in [`adaptive_pe_controller.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv):
```verilog
ST_IDLE: begin
    if (start_req) begin
        ...
        state_d = ST_CLEAR;
    end
end

ST_CLEAR: begin
    // Exactly 1 cycle pulse to clear accumulators and reset saturation
    accum_clear = 1'b1; // <--- UNCONDITIONAL CLEAR
    sat_clear   = 1'b1;
    enable      = 1'b0;
    state_d     = ST_COMPUTE;
end
```
- **Audit Verdict:** **DEFECT / CLEAR-ON-START LIMITATION.**
- `adaptive_pe_controller.sv` unconditionally enters `ST_CLEAR` upon every `start_req` from `layer_command_sequencer`.
- In `layer_command_sequencer.sv`, every layer command issued via `cmd_valid / cmd_ready` asserts `pe_start_req`, which enters `ST_CLEAR`.
- Furthermore, lines 277–292 in `layer_command_sequencer.sv`:
```verilog
ST_WAIT_COMP: begin
    if (compute_done) begin
        state_d = ST_DRAIN; // <--- UNCONDITIONAL DRAIN
    end
end
```
Every completed compute command transitions unconditionally to `ST_DRAIN`. If an intermediate $K$-chunk is executing, it prematurely drains incomplete partial sums to Buffer B and the requantization unit.

---

## 3. Accumulator Preservation Controller Proposal

To achieve full multi-pass $K$-reduction capability without modifying any protected baseline RTL files, we propose the following synthesizable wrapper architecture:

```
                          ┌──────────────────────────────────────┐
                          │    accum_preservation_controller     │
   cmd_valid              │                                      │
  ───────────────────────►│                                      │
   cmd_chunk_idx [3:0]    │                                      │
  ───────────────────────►│                                      │ core_cmd_valid
   cmd_total_chunks [3:0] │                                      ├─────────────────► (To Top Level)
  ───────────────────────►│                                      │
                          │                                      │
   pe_accum_clear_in      │                                      │ pe_accum_clear_gated
  ───────────────────────►│                                      ├─────────────────► (To PE Array)
                          │                                      │
   pe_drain_start_in      │                                      │ pe_drain_start_gated
  ───────────────────────►│                                      ├─────────────────► (To Drain Ctrl)
                          │                                      │
   core_step_done_in      │                                      │ user_step_done_out
  ───────────────────────►│                                      ├─────────────────►
                          └──────────────────────────────────────┘
```

### 3.1 Gating Rules

1. **Accumulator Clear Qualification:**
   $$\text{pe\_accum\_clear\_gated} = \text{pe\_accum\_clear\_in} \ \& \ (\text{cmd\_chunk\_idx} == 4'd0)$$
   Accumulators are cleared only during Chunk 0. On Chunks $1, 2, \dots, N-1$, the clear signal is gated low, allowing `mac_unit_40b` to accumulate seamlessly.

2. **OFMAP Drain Suppression:**
   $$\text{pe\_drain\_start\_gated} = \text{pe\_drain\_start\_in} \ \& \ (\text{cmd\_chunk\_idx} == \text{cmd\_total\_chunks} - 1'b1)$$
   The drain controller and requantization unit are engaged only upon completing the final chunk.

3. **Step Completion Multiplexing:**
   - On intermediate chunks, `compute_done` from the feeder directly acknowledges command completion, bypassing the 128-cycle drain latency.
   - On the final chunk, command completion waits for `drain_done` from the OFMAP drain controller.

---

## 4. Protected RTL Change Proposal (For Formal Approval)

If the user approves extending `accelerator_core_top.sv` and `slot_control_unit.sv` in a future milestone:

| File | Proposed Change | Purpose |
| :--- | :--- | :--- |
| `slot_control_unit.sv` | Add input port `input logic accum_preserve` | When high during `ST_ALLOCATED`, gate `accum_clear = 1'b0`. |
| `accelerator_core_top.sv` | Add input port `input logic slot_accum_preserve` | Route preserve flag from core pinout to `u_slot_ctrl`. |

Until explicit approval is granted, **neither file has been modified**, preserving zero diffs across all protected baseline files.

