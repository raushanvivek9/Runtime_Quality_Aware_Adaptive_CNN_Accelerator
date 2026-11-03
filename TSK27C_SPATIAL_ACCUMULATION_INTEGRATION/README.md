# TSK-27C: Spatial Sequencer Integration and Multi-Chunk Accumulation

## 1. Overview
TSK-27C integrates the standalone spatial tile sequencer (`spatial_tile_sequencer.sv`, developed in TSK-27A) with the accumulator-preservation control logic established in TSK-27B. The resulting synthesizable integration controller (`tsk27c_spatial_accumulation_controller.sv`) manages 2D spatial coordinate traversal alongside multi-chunk inner channel reductions without modifying any protected baseline RTL files.

---

## 2. Directory Contents

| File | Description |
| :--- | :--- |
| `tsk27c_spatial_accumulation_controller.sv` | Synthesizable integration module orchestrating spatial sequencing and multi-chunk accumulation control. |
| `spatial_tile_sequencer.sv` | Standalone 2D spatial tile sequencer submodule (from TSK-27A). |
| `mac_unit_40b.sv` | Verbatim copy of baseline 40-bit saturating MAC unit used for Phase 6 numerical verification. |
| `tb_tsk27c_spatial_accumulation_controller.sv` | Complete SystemVerilog verification testbench evaluating 16 scenarios and real hardware MAC accumulation. |
| `TSK27C_RESULTS.csv` | Machine-readable verification results across all 16 test suites. |
| `ARCHITECTURE.md` | Formal architecture specification, state machine diagrams, and timing interface contracts. |
| `TSK27C_INTEGRATION_PLAN.md` | Architectural trade-off analysis and step-by-step execution roadmap. |
| `TSK27C_INTERFACE_AUDIT.md` | Pre-implementation interface audit of existing RTL control signals. |
| `TSK27C_LIMITATIONS.md` | Boundary limitations, line buffering considerations, and zero-energy claim disclaimers. |
| `FINAL_AUDIT_REPORT.md` | Comprehensive milestone engineering audit report with acceptance scorecard. |

---

## 3. Architecture Summary

### 3.1 Two-Level Loop Hierarchy
The controller implements a hardware-managed nested loop structure:
```text
for y in 0 .. H_tiles - 1:
  for x in 0 .. W_tiles - 1:
    for chunk in 0 .. N_chunks - 1:
      1. Issue compute command to core
      2. If chunk == 0: assert accum_clear = 1
      3. If chunk > 0:  suppress accum_clear = 0 (preserve accumulator)
      4. Wait for core compute completion
    5. Issue OFMAP drain request (chunk == N_chunks - 1)
    6. Wait for drain ready/done
    7. Step spatial coordinates (x, y)
```

### 3.2 Control Signal Protocol
- `core_accum_clear`: Asserted during `chunk_idx == 0` compute setup; held low for all intermediate chunks.
- `core_drain_req`: Held low during chunks $0 \dots N-2$; asserted only upon completion of final chunk $N-1$.
- `spatial_step`: Pulsed only after `core_drain_ready` confirms final tile drain completion.

---

## 4. Verification and Reproduction

### 4.1 Prerequisites
- Icarus Verilog (`iverilog`) v12.0 or later
- SystemVerilog 2012 syntax support (`-g2012`)

### 4.2 Running the Simulation
Execute the testbench from the command line:

```bash
cd TSK27C_SPATIAL_ACCUMULATION_INTEGRATION
iverilog -g2012 -o sim_tsk27c spatial_tile_sequencer.sv mac_unit_40b.sv tsk27c_spatial_accumulation_controller.sv tb_tsk27c_spatial_accumulation_controller.sv
vvp ./sim_tsk27c
```

### 4.3 Expected Output Summary
```text
======================================================================
 TSK-27C TEST SUMMARY: 41 Passed, 0 Failed
======================================================================
 [SUCCESS] All TSK-27C Spatial Integration & Accumulation Tests PASSED!
======================================================================
```

---

## 5. Test Suite Matrix

| ID | Scenario | Grid | Chunks | Reductions | Verification Focus | Result |
| :--- | :--- | :---: | :---: | :---: | :--- | :---: |
| **S1** | Grid 1x1, Chunk 1 | $1 \times 1$ | 1 | 1 | Single-pass baseline tile execution | **PASS** |
| **S2** | Grid 2x2, Chunk 1 | $2 \times 2$ | 1 | 4 | Multi-tile spatial traversal with 1 chunk | **PASS** |
| **S3** | Grid 2x2, Chunk 3 | $2 \times 2$ | 3 | 12 | 2D spatial traversal with 3-chunk accumulation | **PASS** |
| **S4** | Grid 3x2, Chunk 2 | $3 \times 2$ | 2 | 12 | Rectangular spatial grid with 2 chunks | **PASS** |
| **S5-7** | Invariant Checks | $2 \times 2$ | 3 | 12 | Verify zero premature drains and proper clears | **PASS** |
| **S8** | Spatial Backpressure | $2 \times 2$ | 2 | 8 | Pausing between spatial tile transitions | **PASS** |
| **S9** | Interm. Backpressure | $2 \times 1$ | 3 | 6 | Stall cycles between reduction chunks | **PASS** |
| **S10** | Drain Backpressure | $2 \times 1$ | 2 | 4 | Prolonged stalls during OFMAP drain | **PASS** |
| **S11** | Start While Busy | $2 \times 2$ | 2 | 8 | Protocol rejection of start pulse while running | **PASS** |
| **S12** | Invalid Dimensions | $0 \times 4$ | 2 | 0 | Error assertion on invalid grid dimension | **PASS** |
| **S13** | Invalid Chunk Count | $2 \times 2$ | 0 | 0 | Error assertion on chunk count == 0 | **PASS** |
| **S14** | Abort Handling | $3 \times 3$ | 4 | 36 | Graceful abort and return to IDLE | **PASS** |
| **S15** | Active Reset | $2 \times 2$ | 2 | 8 | Asynchronous/Synchronous reset recovery | **PASS** |
| **S16** | Consecutive Runs | $2 \times 1$ | 2 | 4 | Back-to-back layer execution without hang | **PASS** |
| **P6** | Numerical 3-Chunk HW MAC | $1 \times 1$ | 3 | 3 | Physical 40-bit MAC hardware accumulation | **PASS** |

