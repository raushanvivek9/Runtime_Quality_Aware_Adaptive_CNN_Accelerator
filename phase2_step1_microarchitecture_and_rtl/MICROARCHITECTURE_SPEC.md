# Phase 2 Step 1: Microarchitecture & RTL Datapath Specification
## 5,184-Byte Hybrid SRAM Sparse CNN Accelerator Core

**Project**: `Neural_Acc`  
**Phase**: Phase 2 — Hardware Implementation and Synthesis  
**Step**: Step 1 — Microarchitecture Specification and SystemVerilog RTL Implementation  
**Target Core**: `accelerator_core_top`  
**Governing Authority**: Project Owner (`Raushan vivek`)  
**Ratified Decisions**: D-01 through D-13, AMD-01 through AMD-07, Gate 1 Decisions G1-D01 through G1-D04  

---

## 1. Architectural Overview & Block Diagram

The accelerator core implements an area-efficient sparse convolution engine designed around an exact **5,184-byte hybrid SRAM memory macro** and dedicated datapath register file latches for sticky saturation flags.

```
       ┌─────────────────────────────────────────────────────────────┐
       │                   ACCELERATOR CORE TOP                      │
       │                                                             │
       │  ┌────────────────────┐            ┌─────────────────────┐  │
NoC ──>│  Slot Control Unit    │── alloc ──>│ 5,184-Byte Hybrid   │  │
Flits  │  (6-State FSM,        │            │ SRAM Memory Array   │  │
       │   8-bit Tag Check,    │            │ (16 Slots x 16 Bnk) │  │
       │   Drain Barrier)      │            └─────────────────────┘  │
       │  └────────┬───────────┘                       ▲             │
       │           │                                   │             │
       │           │ valid, tag match                  │             │
       │           ▼                                   │             │
       │  ┌────────────────────┐                       │             │
       │  │ Resolved-K Tracker │                       │             │
       │  │ (In-Order Scalar,  │                       │             │
       │  │  K_exec + K_skip)  │                       │             │
       │  └────────┬───────────┘                       │             │
       │           │                                   │             │
       │           │ mac_exec_trigger                  │             │
       │           ▼                                   ▼             │
       │  ┌───────────────────────────────────────────────────────┐  │
       │  │ 40-Bit Saturating MAC Unit                            │  │
       │  │ - Exact-Zero Detection / Bypass                       │  │
       │  │ - 16b x 16b -> 32b Multiplier (Scale S=1000)          │  │
       │  │ - 40b Saturating Adder [-2^39, 2^39-1]                │  │
       │  │ - 1-bit Sticky Saturation Register Latch (G1-D02)     │  │
       │  └───────────────────────────────────────────────────────┘  │
       └─────────────────────────────────────────────────────────────┘
```

---

## 2. Microarchitectural Modules

### 2.1 40-Bit Saturating MAC Unit (`mac_unit_40b.sv`)
- **Operands**:
  * Activation: 16-bit signed integer ($A_{\text{quant}}$).
  * Exact-Zero Mask: 1-bit token ($M$).
  * Weight: 16-bit signed integer ($W_{\text{quant}}$).
- **Exact-Zero Bypass**:
  If $M == 0$ or $A_{\text{quant}} == 0$, arithmetic is bypassed, preventing unnecessary toggling and power dissipation.
- **Saturation Bounds**:
  * Positive maximum: `40'sh7F_FFFF_FFFF` ($+549,755,813,887$).
  * Negative maximum: `-40'sh80_0000_0000` ($-549,755,813,888$).
- **Sticky Saturation Latch**:
  Implemented as a dedicated flip-flop in the datapath register file (Option G1-02A), keeping the SRAM macro budget at exactly 5,184 bytes.

### 2.2 Resolved-K Progress Tracker (`k_progress_tracker.sv`)
- **Invariant**:
  $$K_{\text{resolved}} = K_{\text{executed}} + K_{\text{skipped}} == K_{\text{total}}$$
- **In-Order Monotonic Check**:
  Compares incoming flit reduction coordinate against `k_expected`.
  * If in-order, advances counter and triggers MAC arithmetic or skip.
  * If out-of-order, raises `seq_error` and halts slot progress until resolved.

### 2.3 Slot Control Unit (`slot_control_unit.sv`)
- **6-State Lifecycle FSM**:
  1. `ST_FREE`: Idle slot, credit available.
  2. `ST_ALLOCATED`: Allocated for new channel computation; clears accumulator.
  3. `ST_COMPUTING`: Actively accepting flits and accumulating partials.
  4. `ST_DRAINING`: Draining completed partial products to write buffer.
  5. `ST_QUIESCENT`: Barrier synchronized; pipeline empty.
  6. `ST_RELEASE`: Credit returned; returns to `ST_FREE`.
- **Generation-Tag Verification**:
  Maintains an 8-bit generation tag ($0..255$) incremented modulo 256 upon allocation.
  Flits carrying stale tags from delayed routes are rejected.
  *NoC Latency Bound*: $T_{\text{transit\_max}} < 256 \times T_{\text{slot\_reuse\_min}}$ (Option G1-03A).

### 2.4 Hybrid SRAM Bank (`hybrid_sram_bank.sv`)
- Parameterized dual-ported banking memory model:
  * Total capacity: **5,184 bytes** (1,296 words of 32 bits).
  * Port A: Write port for network ingestion.
  * Port B: Read port for datapath operand fetch.

---

## 3. Verification & Simulation Results

All RTL modules were simulated using `iverilog -g2012` and `vvp`:
- **Compilation**: 0 errors, 0 warnings.
- **Simulation**: 9 / 9 tests passed (100% PASS).
- **Bit-Exact Conformance**: Multiplier and accumulator verified identical to Phase 1H software golden models.

