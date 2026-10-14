# Consolidated Gate 0 Ratification and Architecture Charter (Proposed)

**Document**: `D13_PROPOSED_GATE0_RATIFICATION_CHARTER.md`  
**Phase**: Phase 1G.5.28 — D-09 Through D-13 Decision Resolution Package  
**Target Authority**: Project Owner (`Raushan vivek`)  
**Governance State**: **`PROPOSED CHARTER ONLY — ZERO LEGAL RATIFICATION EFFECT`**  
**Ratification Status**: **`NOT RATIFIED — STRICTLY PENDING EXPLICIT OWNER SIGNATURE`**  
**Phase 1H Authorization**: **`UNAUTHORIZED`**  
**Phase 2 Authorization**: **`UNAUTHORIZED`**  

> [!WARNING]
> **MANDATORY GOVERNANCE NOTICE**:  
> 1. An engineering recommendation is **NOT** owner approval.  
> 2. Documenting owner choices does **NOT** automatically ratify the entire package.  
> 3. Documentation completion is **NOT** hardware validation.  
> 4. Passing Python software unit tests is **NOT** proof of physical hardware correctness.  
> 5. Gate 0 remains **NOT RATIFIED** until explicit signature and Git commit anchoring occur.  
> 6. Phase 1H and Phase 2 remain **STRICTLY UNAUTHORIZED** until explicitly granted below.

---

## 1. Scope of the Ratified Architecture

This charter binds the architectural baseline of the `Neural_Acc` deep learning accelerator for sparse post-ReLU linear algebra:
- **Spatial Processing Element Array**: $16 \times 16$ array of processing elements (256 PEs).
- **Arithmetic Precision**: Signed 16-bit operands (INT16 activations and INT16 weights) with linear scaling factor $S = 1000.0$.
- **Accumulator Datapath**: 40-bit signed accumulator per PE with asymmetric per-step saturation $[-2^{39}, 2^{39}-1]$.
- **Sparsity Architecture**: Exact post-ReLU FP32 zero token skipping with dedicated 1-bit packed mask SRAM.
- **Execution Dataflow**: Output-stationary multi-tile reduction (Schedule S1) with resolved-K tracking and generation tagging.

---

## 2. Decision Traceability Matrix (D-01 through D-13)

| Decision ID | Architectural Topic | Governed Baseline Option | Owner Choice Provenance | Contract Status |
|---|---|---|---|---|
| **D-01** | FP32 Zero Sparsity Semantics | Option A: Exact post-ReLU FP32 zero ($x == 0.0$) | Signed 15-10-2026 (`phase1g_5_17`) | Bound by AMD-01 |
| **D-02** | Quantized-Zero & Mask SRAM | Policy 1A + Option 2A: Packed 1-bit mask SRAM | Signed 15/10/2026 (`phase1g_5_19`) | Bound by AMD-02 |
| **D-03** | Rounding & Half-Integer Ties | Option A: Symmetric magnitude round-half-up | Signed 15-10-2026 (`phase1g_5_17`) | Bound by AMD-03 |
| **D-04** | Activation Clamping Scope | Option A: Pure linear $[-32768, 32767]$ (no min-mag) | Signed 15-10-2026 (`phase1g_5_17/19`) | Bound by AMD-01 |
| **D-05** | Authoritative 10-Stage Pipeline | Option A: 10-stage execution with mask SRAM | Signed 15/10/26 (`phase1g_5_21`) | Bound by Addendum |
| **D-06** | Accumulator Bounds Reconciliation | Option A: Reconcile Line 52 to Case C ($B_C = 150,994,944,000$) | Signed 15/10/26 (`phase1g_5_21`) | Bound by AMD-04 |
| **D-07** | Saturation Semantics & PMU | Option A: Asymmetric 40b per-step saturation + PMU flag | Signed 15/10/26 (`phase1g_5_21`) | Bound by AMD-05 |
| **D-08** | Verification Oracle Tolerance | Option A: Algorithmic tie-gate on even half-integers | Signed 15/10/26 (`phase1g_5_21`) | Bound by AMD-06 |
| **D-09** | Multi-Tile Progress Tracking | Option 09-A: Scalar resolved-K counter ($K_{\text{res}} == K$) | Awaiting Owner Selection | To be bound |
| **D-10** | Slot Lifecycle & Generation | Option 10-HYBRID: 16-bit tag + layer drain barrier | Awaiting Owner Selection | To be bound |
| **D-11** | S1 On-Chip SRAM Budget | Option 11-A: 5,184 bytes (5.06 KiB) hybrid budget | Awaiting Owner Selection | Bound by AMD-07 |
| **D-12** | Historical Archival Policy | Option 12-A: Immutable archival retention | Awaiting Owner Selection | Bound by Charter |
| **D-13** | Gate 0 Consolidated Ratification | Option 13-A: Formal ratification & Phase 1H release | Awaiting Owner Selection | Bound by Charter |

---

## 3. Formal Contract Version and Amendments

Upon ratification, the historical contract [`FROZEN_ARITHMETIC_AND_DATAPATH_CONTRACT.md`](file:///home/cs25m115/Neural_Acc/phase1g_5_11_gate0_ratification_and_phase1h_authorization/FROZEN_ARITHMETIC_AND_DATAPATH_CONTRACT.md) (SHA-256: `083a179d4e2be638c1ee5dc0918fa02696ce4e5936f0c61e6d4694195468ec02`) is amended by binding addendum `CONTRACT_AMENDMENTS_RATIFIED.md` incorporating:
- **AMD-01 (Section 1.1)**: Pure linear activation quantization; $\max(1, \dots)$ deleted; clamp $[-32768, 32767]$.
- **AMD-02 (Section 1.2 & 2)**: Dedicated 1-bit packed mask SRAM; token skip asserted strictly when $M == 0$.
- **AMD-03 (Line 19 & Section 5)**: Symmetric magnitude round-half-up: $\text{sign}(x) \times \lfloor |x| + 0.5 \rfloor$.
- **AMD-04 (Line 52)**: Worst-case bound updated to Case C ($B_C = 150,994,944,000$ with $3.6409\times$ headroom).
- **AMD-05 (Line 50)**: Saturation codified as asymmetric two's-complement $[-2^{39}, 2^{39}-1]$ with PMU sticky flag.
- **AMD-06 (Line 80)**: Oracle tie-gate tolerance restricted strictly to even half-integers ($\lfloor |x| \rfloor \pmod 2 == 0$).
- **AMD-07 (Line 83)**: On-chip SRAM budget updated from 1.5 KiB to 5,184 bytes (5.06 KiB).

---

## 4. Hardware Verification Preconditions for Phase 1H and Phase 2

### 4.1 Conditions Precedent to Phase 1H Release
Phase 1H (Software Adapter Refactoring, Sparse Golden Model, and RTL Datapath Preparation) may commence **only after**:
1. Project Owner explicitly executes the signature block below.
2. The complete ratified package is anchored by a Git commit on `main`.
3. Contract amendments AMD-01 through AMD-07 are committed to the repository.

### 4.2 Conditions Precedent to Phase 2 Release
Phase 2 (Full Hardware Implementation and Synthesis) remains **STRICTLY BLOCKED** until:
1. Phase 1H adapter and golden model pass full-layer bit-exact equivalence on VGG16 and ResNet18 benchmarks.
2. Cycle-accurate simulation verifies deadlock freedom for multi-tile interconnect under maximum backpressure.
3. Commercial foundry SRAM compiler confirms physical layout, area, power, and timing feasibility for the 5,184-byte budget.
4. Gate 1 Architecture Conformance Audit is passed and signed by the Project Owner.

---

## 5. Known Unresolved Limitations and Open Risks

1. **Interconnect Aliasing**: While a 16-bit tag and layer drain barrier eliminate inter-layer aliasing, intra-layer packet transit time must be bounded by NoC design.
2. **SRAM Compiler Verification**: Actual silicon area and power consumption are analytical estimates until commercial memory compiler macros are generated.
3. **Multi-Tile Deadlock**: General deadlock freedom in the presence of DRAM refresh backpressure requires formal dimension-order routing verification in Phase 1H.

---

## 6. Project Owner Execution Block

```
I hereby confirm that I have reviewed the Consolidated Gate 0 Decision Package (D-01 through D-13), the Contract Amendments (AMD-01 through AMD-07), and the Phase 1H Preconditions.

PROJECT OWNER NAME:      __________________________________________________
SIGNATURE:               __________________________________________________
DATE:                    __________________________________________________
GATE 0 DETERMINATION:    [  ] FORMALLY RATIFIED    [  ] RATIFICATION DEFERRED
PHASE 1H AUTHORIZATION:  [  ] AUTHORIZED           [  ] UNAUTHORIZED / WITHHELD
PHASE 2 AUTHORIZATION:   [  ] UNAUTHORIZED (MANDATORY: Requires Gate 1 Audit)
```

