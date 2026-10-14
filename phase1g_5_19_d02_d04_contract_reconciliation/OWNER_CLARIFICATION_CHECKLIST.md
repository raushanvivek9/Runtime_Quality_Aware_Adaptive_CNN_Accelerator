# Project Owner Clarification Checklist: Decisions D-02 through D-04

**Document**: `OWNER_CLARIFICATION_CHECKLIST.md`  
**Phase**: Phase 1G.5.19 — D02–D04 Contract Reconciliation Proposal  
**Target Authority**: Project Owner (`Raushan vivek`)  
**Purpose**: High-Priority Technical Clarifications to Harmonize Contract Amendments Prior to Gate 0 Ratification  

---

## 1. Context & Objective

In Phase 1G.5.17, you formally recorded your approval for:
- **`D-01 (Option A)`**: Exact post-ReLU FP32 zero ($x == 0.0$).
- **`D-02 (Option A)`**: Out-of-band 1-bit mask stream.
- **`D-03 (Option A)`**: Symmetric magnitude round-half-up ($Q(x) = \text{sign}(x) \cdot \lfloor |x| + 0.5 \rfloor$).
- **`D-04 (Option A)`**: Scoping minimum magnitude 1 strictly to activations; weights unconstrained.

This checklist provides the exact technical clarifications needed to draft an internally consistent, ratified contract addendum.

---

## 2. High-Priority Clarification Items

### Clarification Item 1: Activation Minimum-Magnitude Clamp Redundancy (D-02 vs. D-04)
- **Background**:  
  Under an in-band architecture, $\max(1, \dots)$ was required on activations to prevent sub-threshold inputs ($0 < |A| < 0.0005$) from emitting `0x0000` and triggering false MAC skips. However, because you approved **D-02 Option A** (carrying a separate 1-bit mask wire $M$), the systolic PE skips MACs strictly when $M == 0$. When $M == 1$, the PE executes the operation, even if the quantized integer is `0x0000` ($0 \times W = 0$).
- **Question**:  
  Do you confirm that activation tensors should use **pure linear uniform quantization without the minimum-magnitude clamp** ($\max(1, \dots)$ omitted), eliminating the $9\times$ noise amplification on sub-threshold inputs?
- **Owner Action**:
  - `[ yes ]` **POLICY 1A (RECOMMENDED)**: Omit $\max(1, \dots)$ from activations; adopt pure linear quantization with 1-bit out-of-band mask.
  - `[  ]` **POLICY 1B**: Retain $\max(1, \dots)$ on activations, accepting up to $9\times$ noise amplification on sub-threshold inputs.

---

### Clarification Item 2: On-Chip Mask Buffer Organization (D-02 Implementation)
- **Background**:  
  An out-of-band 1-bit mask can be stored and transported in hardware using either packed bitmasks or widened memory channels.
- **Question**:  
  Which microarchitectural storage topology should be codified in the hardware contract specification for on-chip activation SRAM?
- **Owner Action**:
  - `[yes  ]` **OPTION 2A (Packed Bitmask SRAM)**: Store masks in a dedicated 1-bit packed SRAM array (16x area density for masks; requires bit-indexing shifter during dispatch).
  - `[  ]` **OPTION 2B (Widened 17-Bit Channels)**: Interleave masks directly with activation words in 17-bit SRAM words (`{mask, int16_data}`) for synchronous lockstep routing.

---

### Clarification Item 3: Adoption of Proposed Contract Amendments AMD-01 through AMD-04
- **Background**:  
  `PROPOSED_CONTRACT_AMENDMENTS.md` drafts exact text replacements for Section 1.1 (linear activation quantization), Section 1.2 (symmetric weight rounding), Section 2 (multiplier gating on mask bit), and Section 5 (symmetric magnitude rounding).
- **Question**:  
  Do you approve adopting Amendments AMD-01 through AMD-04 into `FROZEN_ARITHMETIC_AND_DATAPATH_CONTRACT.md` upon formal ratification?
- **Owner Action**:
  - `[  ]` **APPROVE**: Authorize the adoption of Amendments AMD-01 through AMD-04.
  - `[ yes ]` **REVISE**: Request adjustments prior to contract modification.

---

### Clarification Item 4: Transition of Approval Sheet Ratification Status Line
- **Background**:  
  Line 169 of `phase1g_5_17_d01_d04_sparsity_quantization_review/PROJECT_OWNER_APPROVAL_SHEET.md` currently reads:  
  `RATIFICATION STATUS: NOT RATIFIED — AWAITING HUMAN OWNER ACTION`.
- **Question**:  
  Do you authorize updating this status line to reflect formal ratification for decisions D-01 through D-04 once the contract amendments are approved?
- **Owner Action**:
  - `[  ]` **AUTHORIZE**: Update Line 169 to `RATIFIED_BY_PROJECT_OWNER (D-01 through D-04)`.
  - `[ yes ]` **DEFER**: Keep as `NOT RATIFIED` until the entire 13-decision Gate 0 package is complete.

---

## 3. Project Owner Sign-Off Block

```
PROJECT OWNER NAME:      ____________Raushan vivek________________________
SIGNATURE:               _______________Raushan Vivek_____________________
DATE:                    ___________15/10/2026_________________________
```

