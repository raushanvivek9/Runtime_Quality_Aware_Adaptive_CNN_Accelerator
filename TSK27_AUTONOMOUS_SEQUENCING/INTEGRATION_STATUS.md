# TSK-27A: Hardware Integration Status Report
## Standalone Verification vs. Top-Level Integration Assessment

**Milestone Identifier:** TSK-27A  
**Project:** Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Status:** STANDALONE VERIFIED / TOP-LEVEL PROPOSED (Zero Protected Diffs)  

---

## 1. Separation of Standalone Verification and Top-Level Integration

> [!IMPORTANT]
> In strict accordance with the TSK-27A acceptance criteria:
> - **Standalone Sequencer:** Fully implemented, synthesizable, and rigorously verified in [`spatial_tile_sequencer.sv`](file:///e:/MTech/LanChain/MTP/TSK27_AUTONOMOUS_SEQUENCING/spatial_tile_sequencer.sv) across 12 exhaustive scenarios with **30/30 passed assertions (0 failures)**.
> - **Top-Level Integration:** **NOT claimed as integrated into `neural_acc_integrated_top.sv`**. Top-level wiring was intentionally kept untouched to guarantee zero side-effects on the existing 20-suite regression and preserve 100% baseline RTL integrity.

---

## 2. Integration Feasibility Assessment

### 2.1 Upstream Interface Compatibility
The command outputs of `spatial_tile_sequencer.sv` match the upstream layer command interface of [`layer_command_sequencer.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/layer_command_sequencer.sv):

| `spatial_tile_sequencer` Output | `layer_command_sequencer` Input | Function |
| :--- | :--- | :--- |
| `cmd_valid` | `cmd_valid` | Asserted when spatial tile parameters are stable |
| `cmd_ready` (input) | `cmd_ready` (output) | Ready handshake from command sequencer |
| `cmd_layer_id` | `cmd_layer_id` | Layer identification tag |
| `cmd_pe_mode` | `cmd_pe_mode` | 16-PE, 32-PE, or 64-PE allocation mode |
| `cmd_k_total` | `cmd_k_total` | Reduction length per tile |
| `step_done` (input) | `layer_done_pulse` (output) | Tile completion pulse triggering spatial advance |

### 2.2 Address Mapping and SRAM Pointers
- In `spatial_tile_sequencer.sv`, the address generator computes:
  $$\text{curr\_ifmap\_addr} = \text{base\_ifmap} + y \cdot \text{stride\_ifmap\_y} + x \cdot \text{stride\_ifmap\_x}$$
  $$\text{curr\_ofmap\_addr} = \text{base\_ofmap} + \text{tile\_idx} \cdot \text{stride\_ofmap}$$
- Currently, `neural_acc_integrated_top.sv` accepts `cfg_ofmap_base_addr` as a static configuration parameter. To connect `cmd_ofmap_addr`, the top-level wrapper would dynamically latch `cfg_ofmap_base_addr` per command.

---

## 3. Top-Level Integration Roadmap

To integrate `spatial_tile_sequencer.sv` into the top level safely:

```
[Host System]
     │ Single START (Grid W, H, Base Addrs, Strides)
     ▼
┌────────────────────────────────────────────────────────┐
│            neural_acc_autonomous_top.sv                │
│                                                        │
│  ┌───────────────────────────┐                         │
│  │ spatial_tile_sequencer.sv │                         │
│  └─────────────┬─────────────┘                         │
│                │ Autonomous cmd_valid / step_done      │
│                ▼                                       │
│  ┌───────────────────────────┐                         │
│  │  neural_acc_integrated_top│                         │
│  │                           │                         │
│  │   • layer_command_seq     │                         │
│  │   • adaptive_pe_ctrl      │                         │
│  │   • pe_array_40b (64 PEs) │                         │
│  │   • multibank_sram        │                         │
│  │   • ofmap_drain_ctrl      │                         │
│  │   • requantization_unit   │                         │
│  └───────────────────────────┘                         │
└────────────────────────────────────────────────────────┘
```

1. Create a non-invasive outer wrapper (`neural_acc_autonomous_top.sv`) instantiating `spatial_tile_sequencer.sv` and `neural_acc_integrated_top.sv`.
2. Connect `cmd_valid / cmd_ready` and `layer_done_pulse -> step_done`.
3. Route `done_pulse` to the top-level external interface as `feature_map_done`.
4. Keep the original `neural_acc_integrated_top.sv` intact so all existing regression testbenches run without modification.

