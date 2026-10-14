# Project Owner Decision Sheet: Decisions D-05 through D-08

**Document**: `OWNER_DECISION_SHEET_D05_D08.md`  
**Phase**: Phase 1G.5.21 — D05–D08 Owner Decision and Consistency Review  
**Target Authority**: Project Owner (`Raushan vivek`)  
**Governance State**: **`DECISION QUESTIONNAIRE ONLY — DEFERRED RATIFICATION GOVERNANCE MODEL`**  
**Ratification Status**: **`NOT RATIFIED — AWAITING CONSOLIDATED GATE 0 RATIFICATION`**  

---

## 1. Notice to Project Owner

Decisions `D-01` through `D-04` have received your technical guidance (confirming exact post-ReLU FP32 zero sparsity, out-of-band 1-bit packed mask SRAM, symmetric magnitude rounding, and pure linear activation quantization). Formal ratification was explicitly **deferred** until all 13 decisions are resolved.

This questionnaire covers **Group 2: Pipeline, Arithmetic Bounds, Saturation, and Oracle Tolerance (`D-05` through `D-08`)**.

> [!NOTE]
> All checkbox selections below are left **blank** for your explicit determination. The signature block is unexecuted. No decision is considered approved without your explicit action.

---

## 2. Targeted Owner Decision Items

---

### Decision D-05: Authoritative 10-Stage Execution Pipeline Order
1. **Original Question**:  
   *What is the complete authoritative order of zero detection; scaling; rounding; minimum magnitude; clamp; token generation; skip; and progress update?* (`HUMAN_DECISION_REGISTER.csv:Line 6`)
2. **Proposed Option A (Recommended)**:  
   Ratify the 10-stage execution pipeline incorporating the packed-mask SRAM architecture:
   ```
   1. Input Load (FP32) -> 2. Mask Extraction (M = A != 0.0) -> 3. Packed-Mask SRAM Storage
   -> 4. Linear Scaling (x1000) -> 5. Symmetric Rounding -> 6. INT16 Range Clamp (no min-mag)
   -> 7. Tile Dispatch ({M, INT16}) -> 8. PE MAC Gating (M==0 skip)
   -> 9. PE Compute & Accumulate -> 10. Resolved-K Progress Commit
   ```
3. **Trade-Offs**:  
   - *Option A*: Eliminates all pipeline ambiguity across software adapters, oracles, and RTL; incorporates your approved packed-mask SRAM.
   - *Option B (Historical In-Band)*: Inspects integer `0x0000` at PE (directly conflicts with approved out-of-band mask).
4. **Owner Determination**:
   - `[ yes ]` **OPTION A APPROVED**: Ratify the refined 10-stage pipeline with packed-mask SRAM integration.
   - `[  ]` **REJECTED / REVISED**: Request modifications to the pipeline order.

---

### Decision D-06: Case C Accumulator Bounds & Contract Line 52 Reconciliation
1. **Original Question**:  
   *Are Case C operand bounds justified for the actual model and which accumulation envelope governs the contract?* (`HUMAN_DECISION_REGISTER.csv:Line 7`)
2. **Proposed Option A (Recommended)**:  
   Reconcile contract Line 52 to state the verified Case C bound of $B_C = 150,994,944,000$ with $3.6409\times$ headroom ratio, harmonizing it with the ratified signed INT16 clamp ($[-32768, +32767]$).
3. **Trade-Offs**:  
   - *Option A*: Resolves the direct contradiction in contract Line 52 without altering the INT16 clamp; mathematically proves 40-bit accumulator provides $1.864$ guard bits above worst case.
   - *Option B*: Tighten activation clamp in Line 19 to $[-15000, +15000]$ to restore the earlier claimed $7.95\times$ margin (risks clipping activation spikes in deep unpruned layers).
4. **Owner Determination**:
   - `[ yes ]` **OPTION A APPROVED**: Reconcile Line 52 to state $B_C = 150,994,944,000$ ($3.6409\times$ headroom).
   - `[  ]` **OPTION B APPROVED**: Tighten activation clamp to $[-15000, +15000]$.
   - `[  ]` **REJECTED / REVISED**: Request alternative accumulation envelope.

---

### Decision D-07: Accumulator Saturation Semantics & Terminology
1. **Original Question**:  
   *Is saturation exact-magnitude symmetric or full two's-complement; and is it per accumulation step?* (`HUMAN_DECISION_REGISTER.csv:Line 8`)
2. **Proposed Option A (Recommended)**:  
   Ratify asymmetric two's-complement per-step saturation ($[-2^{39}, +2^{39}-1] = [-549,755,813,888, +549,755,813,887]$), correct contract terminology from 'symmetric' to 'asymmetric', and mandate a 1-bit sticky saturation flag in the hardware PMU.
3. **Trade-Offs**:  
   - *Option A*: Prevents two's-complement modular wraparound bit-flipping while maintaining standard DSP datapath efficiency. Because $B_C$ is $3.641\times$ below threshold, saturation is never triggered during valid inference, preserving linearity and associativity across reduction orders.
   - *Option B*: Enforce exact-magnitude symmetric saturation $[-549,755,813,887, +549,755,813,887]$ (discards $-2^{39}$; requires additional hardware comparator logic in every PE).
4. **Owner Determination**:
   - `[ yes ]` **OPTION A APPROVED**: Ratify asymmetric two's-complement per-step saturation and PMU sticky flag.
   - `[  ]` **OPTION B APPROVED**: Enforce exact-magnitude symmetric saturation.
   - `[  ]` **REJECTED / REVISED**: Request alternative saturation rule.

---

### Decision D-08: Verification Oracle 1-LSB Tolerance Gating
1. **Original Question**:  
   *When exactly may an oracle accept a one-LSB difference?* (`HUMAN_DECISION_REGISTER.csv:Line 9`)
2. **Proposed Option A (Recommended)**:  
   Replace contract Line 80 with an algorithmic tie gate: verification oracles accept a $\pm 1\text{ LSB}$ delta against NumPy banker's rounding strictly when $|x|$ is within $\epsilon = 1.0 \times 10^{-5}$ of an **even** half-integer ($\lfloor |x| \rfloor \pmod 2 == 0$), requiring exact bit-true equality ($\Delta == 0$) on all other coordinates.
3. **Trade-Offs**:  
   - *Option A*: Corrects contract Line 80 parity error (2.5 is even floor, not odd); prevents blanket 1-LSB tolerance from masking real off-by-one RTL arithmetic bugs.
   - *Option B*: Permit blanket $\pm 1\text{ LSB}$ tolerance across all coordinates (high risk of masking RTL logic defects).
4. **Owner Determination**:
   - `[ yes ]` **OPTION A APPROVED**: Adopt algorithmic tie gate with even half-integer restriction.
   - `[  ]` **OPTION B APPROVED**: Maintain blanket $\pm 1\text{ LSB}$ tolerance.
   - `[  ]` **REJECTED / REVISED**: Request alternative oracle tolerance rule.

---

## 3. Project Owner Sign-Off Block

```
PROJECT OWNER NAME:      ________________Raushan vivek____________________
SIGNATURE:               _______________Raushan vivek_____________________
DATE:                    ___________________15/10/26_________________
RATIFICATION STATUS:     [ ] RATIFIED    [  yes] DEFERRED TO CONSOLIDATED GATE 0
```
