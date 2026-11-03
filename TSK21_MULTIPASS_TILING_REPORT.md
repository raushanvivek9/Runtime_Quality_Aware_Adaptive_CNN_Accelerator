# TSK-21 Multi-Pass Channel Tiling, Output Preservation & Requantization Report

**Project:** Neural_Acc Accelerator  
**Task:** TSK-21 (Phase B: Multi-pass channel tiling, complete output-channel preservation, requantization unit, and inter-layer handoff)  
**Date:** November 2026  
**Status:** COMPLETE (Zero Regressions, Bit-Exact Equivalence)

---

## 1. Executive Summary

Prior to TSK-21, operating the Neural_Acc accelerator in 16-PE (`2'b00`) or 32-PE (`2'b01`) mode caused catastrophic CNN inference accuracy degradation (~10% baseline accuracy). Architectural audits (TSK-16, TSK-19) identified the root cause:
- Physical PE columns 4..15 (in 16-PE mode) and 8..15 (in 32-PE mode) were clock-gated.
- The single-pass OFMAP drain wrote only 32 words (16 accumulators) in 16-PE mode or 64 words (32 accumulators) in 32-PE mode.
- Consequently, 75% or 50% of the required convolutional output feature channels were completely dropped (truncated to zero).
- Furthermore, the OFMAP buffer stored 40-bit unquantized accumulator values, whereas downstream layer feeders expect 16-bit packed activations, preventing direct autonomous inter-layer pipelining.

In TSK-21:
1. **Multi-Pass Channel Tile Controller (`channel_tile_controller.sv`):** Developed a synthesizable FSM coordinating multi-pass channel tiling:
   - **64-PE Mode:** 1 pass $\times$ 128 words = 128 words (100% channels preserved).
   - **32-PE Mode:** 2 passes $\times$ 64 words = 128 words (100% channels preserved).
   - **16-PE Mode:** 4 passes $\times$ 32 words = 128 words (100% channels preserved).
2. **Requantization Unit (`requantization_unit.sv`):** Implemented a streaming fixed-point requantization module performing configurable bit right-shifting ($S \in [0..31]$), symmetric nearest rounding ($+2^{S-1}$), signed saturation to $[-32768, +32767]$, optional ReLU clamping, and packing of two 16-bit activations into a single 32-bit SRAM word.
3. **Golden Software Reference (`tsk21_reference_model.py`):** Verified bit-exact numerical equivalence between software emulation and RTL across diverse shifting, rounding, and activation regimes, generating `TSK21_NUMERICAL_RESULTS.csv`.
4. **End-to-End Inter-Layer Chaining:** Verified automated streaming of 64 accumulators through the requantizer and writing 32 packed 16-bit words directly into Ping-Pong Buffer B (`14'h1000`), ready for consumption by subsequent layers.
5. **Full Verification Suite (`tb_tsk21_multipass_tiling.sv`):** All 107 checks passed with zero defects.

---

## 2. Multi-Pass Channel Tiling Microarchitecture

### 2.1 Pass Scheduling & Address Generation
For an $N \times C_{out} \times H \times W$ convolutional tensor where 16 output channels $\times$ 4 rows are computed per full tile (64 PEs total):

| Mode | Active Columns | Passes Required | Words / Pass | OFMAP Base Offsets | Total Words Preserved | Channel Preservation |
|---|---|---|---|---|---|---|
| **64-PE (`2'b10`)** | 16 | 1 | 128 | `+0` | 128 (64 accumulators) | **100.0%** |
| **32-PE (`2'b01`)** | 8 | 2 | 64 | `+0, +64` | 128 (64 accumulators) | **100.0%** |
| **16-PE (`2'b00`)** | 4 | 4 | 32 | `+0, +32, +64, +96` | 128 (64 accumulators) | **100.0%** |

### 2.2 Channel Tile Controller FSM
- `ST_IDLE`: Latches `cfg_pe_mode` and base OFMAP address upon `layer_start`.
- `ST_CLEAR_ACCUM`: Pulses `tile_accum_clear` to reset PE array accumulators prior to each pass.
- `ST_FEEDER_RUN`: Pulses `tile_start_feeder` and awaits `feeder_compute_done`.
- `ST_DRAIN_RUN`: Drives `current_ofmap_addr = cfg_base_ofmap_addr + (pass_idx * words_per_tile)`, pulses `tile_start_drain`, and awaits `ofmap_drain_done`.
- `ST_CHECK_TILES`: If `pass_idx + 1 < total_passes`, increments `pass_idx` and loops to `ST_CLEAR_ACCUM`. When all passes finish, asserts `layer_all_tiles_done` and returns to `ST_IDLE`.

---

## 3. Requantization Unit Specification

### 3.1 Mathematical Specification
$$Y = \text{clamp}\left(\left\lfloor \frac{A + \text{round\_offset}}{2^S} \right\rfloor, -32768, 32767\right)$$
$$\text{If } \text{relu\_en} = 1: \quad Y_{final} = \max(0, Y)$$

Where:
- $A \in [-2^{39}, 2^{39}-1]$ is the 40-bit signed accumulator.
- $S \in [0, 31]$ is the programmable right shift (`cfg_scale_shift`).
- $\text{round\_offset} = 2^{S-1}$ if $\text{round\_en} = 1 \text{ and } S > 0$, else 0.
- Clamping prevents arithmetic overflow: values exceeding $+32767$ saturate to $+32767$; values below $-32768$ saturate to $-32768$.

### 3.2 Packing Logic
Activations arrive sequentially. A 1-slot staging register holds activation 0 (`pack_lo_q`). When activation 1 arrives, the unit emits a single 32-bit word:
$$\text{out\_word}[31:0] = \{Y_1[15:0], Y_0[15:0]\}$$
The word stream interfaces directly with Multi-Bank SRAM Port A0 or Port A1, enabling single-cycle writes to the next layer's Ping-Pong buffer.

---

## 4. Numerical Equivalence & Evaluation Results

### 4.1 Python Golden Model Verification (`TSK21_NUMERICAL_RESULTS.csv`)
| Test Case | Shift ($S$) | Rounding | ReLU | Input Accums | Output Words | Min Clips | Max Clips | ReLU Zeros | Min Output | Max Output |
|---|---|---|---|---|---|---|---|---|---|---|
| **Linear_Shift4_Round** | 4 | Enabled | Disabled | 64 | 32 | 0 | 0 | 0 | -1938 | +2670 |
| **Linear_Shift6_Trunc** | 6 | Disabled | Disabled | 64 | 32 | 0 | 0 | 0 | -485 | +667 |
| **ReLU_Shift5_Round** | 5 | Enabled | Enabled | 64 | 32 | 0 | 0 | 19 | 0 | +1335 |
| **ReLU_Shift8_Round** | 8 | Enabled | Enabled | 64 | 32 | 0 | 0 | 19 | 0 | +167 |

Bit-exact match was confirmed between `tsk21_reference_model.py` and RTL simulation across all test cases.

---

## 5. Testbench Verification Summary (`tb_tsk21_multipass_tiling.sv`)

| Verification Section | Checks Evaluated | Checks Passed | Failures | Status |
|---|---|---|---|---|
| **Part 1: 64-PE Mode (1 pass $\times$ 128 words)** | 6 | 6 | 0 | PASS |
| **Part 1: 32-PE Mode (2 passes $\times$ 64 words)** | 7 | 7 | 0 | PASS |
| **Part 1: 16-PE Mode (4 passes $\times$ 32 words)** | 11 | 11 | 0 | PASS |
| **Part 2: Requantization Datapath & Rounding** | 3 | 3 | 0 | PASS |
| **Part 2: Word Packing & Flow Control** | 3 | 3 | 0 | PASS |
| **Part 2: ReLU Activation Clamping** | 2 | 2 | 0 | PASS |
| **Part 2: Positive & Negative Saturation** | 4 | 4 | 0 | PASS |
| **Part 3: End-to-End Inter-Layer Chaining** | 3 | 3 | 0 | PASS |
| **Part 3: SRAM Readback Verification** | 64 | 64 | 0 | PASS |
| **Part 3: Diagnostic Counter Invariants** | 4 | 4 | 0 | PASS |
| **Total Across Entire Suite** | **107** | **107** | **0** | **ALL PASS** |

---

## 6. Artifacts Summary
- **RTL Modules:**
  - `phase2_step1_microarchitecture_and_rtl/channel_tile_controller.sv`
  - `phase2_step1_microarchitecture_and_rtl/requantization_unit.sv`
- **Documentation & Maps:**
  - `TSK21_TENSOR_LAYOUT.md`
  - `TSK21_MEMORY_MAP.csv`
- **Reference & Verification:**
  - `phase2_step1_microarchitecture_and_rtl/tsk21_reference_model.py`
  - `phase2_step1_microarchitecture_and_rtl/tb_tsk21_multipass_tiling.sv`
  - `TSK21_NUMERICAL_RESULTS.csv`
- **Regression:** 20 original suites + TSK-20 suites + TSK-21 suite all pass 100%.

