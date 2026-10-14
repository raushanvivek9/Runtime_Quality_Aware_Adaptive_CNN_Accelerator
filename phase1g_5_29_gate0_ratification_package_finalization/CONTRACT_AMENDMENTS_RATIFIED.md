# Ratified Contract Amendments Addendum: AMD-01 through AMD-07
## Formal Architecture & Datapath Amendments to `FROZEN_ARITHMETIC_AND_DATAPATH_CONTRACT.md`

**Document**: `CONTRACT_AMENDMENTS_RATIFIED.md`  
**Phase**: Phase 1G.5.29 — Gate 0 Ratification Package Finalization and Baseline Verification  
**Governing Authority**: Project Owner (`Raushan vivek`)  
**Ratification Status**: **`RATIFIED BY PROJECT OWNER VIA PHASE 1G.5.28 WORKSHEET`**  
**Authoritative Historical Contract Reference**: [`phase1g_5_11_gate0_ratification_and_phase1h_authorization/FROZEN_ARITHMETIC_AND_DATAPATH_CONTRACT.md`](file:///home/cs25m115/Neural_Acc/phase1g_5_11_gate0_ratification_and_phase1h_authorization/FROZEN_ARITHMETIC_AND_DATAPATH_CONTRACT.md) (SHA-256: `083a179d4e2be638c1ee5dc0918fa02696ce4e5936f0c61e6d4694195468ec02`)  

---

## 1. Notice of Governance and Contract Relationship

> [!IMPORTANT]
> **LEGAL AND ARCHITECTURAL BINDING**:  
> In accordance with the immutable archival retention policy ratified under Decision D-12, the historical file `FROZEN_ARITHMETIC_AND_DATAPATH_CONTRACT.md` in `phase1g_5_11/` remains **100% UNTOUCHED on disk** to preserve forensic integrity.  
> 
> This document (`CONTRACT_AMENDMENTS_RATIFIED.md`) serves as the **official, legally binding addendum**. Where provisions of the original contract conflict with this addendum, **this addendum strictly supersedes the original text**. All Phase 1H software adapters, golden models, and RTL datapath implementations must conform to these ratified amendments.

---

## 2. Schedule of Ratified Contract Amendments (AMD-01 through AMD-07)

---

### Amendment Item AMD-01: Section 1.1 — Activation Quantization, Clamping, and Mask Extraction
- **Source Decision**: `D-01 (Option A)` and `D-04 (Option A)`.
- **Original Contract Reference**: Section 1.1, Lines 15–22.
- **Original Contract Text**:
  ```markdown
  - **Zero-Preserving Clamp Function**:
    $$\widetilde{A} = \begin{cases}
    \mathtt{0x0000}, & \text{if } A == 0.0 \\
    \text{clamp}_{[-32768, 32767]}\Big(\text{sign}(A) \cdot \max\big(1, |\lfloor A \cdot 1000.0 + 0.5 \rfloor|\big)\Big), & \text{if } A \ne 0.0
    \end{cases}$$
  - **Architectural Zero Token**: `0x0000` signals an architectural zero activation and commands the PE datapath to bypass the MAC cycle.
  ```
- **Ratified Replacement Text**:
  ```markdown
  - **Exact Post-ReLU Sparsity Definition & Mask Extraction**:
    Each floating-point activation tensor element $A$ generates a dedicated 1-bit boolean mask bit $M$:
    $$M = \begin{cases} 0, & \text{if } A == +0.0 \lor A == -0.0 \text{ (exact FP32 zero post-ReLU)} \\ 1, & \text{if } A \ne 0.0 \end{cases}$$
  - **Pure Linear Fixed-Point Quantization (No Minimum-Magnitude Clamp)**:
    $$\widetilde{A} = \text{clamp}_{[-32768, 32767]}\Big(\text{sign}(A) \cdot \big\lfloor |A| \cdot 1000.0 + 0.5 \big\rfloor\Big)$$
  - **Sub-Threshold Activation Underflow Semantics**:
    Non-zero activations in the open interval $(-0.0005, +0.0005) \setminus \{0.0\}$ quantize linearly to integer $\mathtt{0x0000}$ with mask bit $M = 1$. They are dispatched to the systolic array as valid executed operations ($0 \times W = 0$), incrementing $K_{\text{executed}}$ with zero numerical noise amplification.
  - **Architectural Zero Gating**:
    MAC bypass is commanded strictly by the 1-bit out-of-band mask wire ($M == 0$), NOT by the integer data value `0x0000`.
  ```
- **Rationale for Change**: Eliminates up to $9\times$ noise amplification on sub-threshold activations caused by the historical $\max(1, \dots)$ clamp. Decouples sparsity detection from numerical quantization.
- **Dependencies**: Coupled with AMD-02 (mask routing) and AMD-03 (symmetric rounding).
- **Owner Approval Evidence**: Approved by Project Owner in `phase1g_5_17/PROJECT_OWNER_APPROVAL_SHEET.md:Line 107, 110` and `phase1g_5_19/OWNER_CLARIFICATION_CHECKLIST.md:Item 1`.
- **Technical Validation Status**: **`PASS_WITH_EVIDENCE`** (Bit-exact verified in Phase 1G.5.25 `test_mask_quantization.py`).
- **Remaining Limitations**: Source adapter `full_layer_adapter.py` must be refactored during Phase 1H.

---

### Amendment Item AMD-02: Section 1.2 & Section 2 — Weight Quantization & Dedicated Mask Storage
- **Source Decision**: `D-02 (Policy 1A + Option 2A)`.
- **Original Contract Reference**: Section 1.2, Lines 25–28, and Section 2, Lines 32–38.
- **Original Contract Text**:
  ```markdown
  - **Weight Clamping**: $\widetilde{W} = \text{clamp}_{[-1000, 1000]}\big(\lfloor W \cdot 1000.0 + 0.5 \rfloor\big)$
  - **Zero Gating**: If $\widetilde{A} == \mathtt{0x0000}$, the multiplier clock/enable is gated, product $P=0$ is forced, and no addition is executed.
  ```
- **Ratified Replacement Text**:
  ```markdown
  - **Dedicated Packed 1-Bit Mask SRAM Array**:
    Activation masks are stored on-chip in a dedicated 1-bit packed SRAM array organized as 16 words of 16 bits (32 bytes per single-buffered tile; 64 bytes per double-buffered tile), providing 16x density advantage over unpacked storage.
  - **Weight Quantization & Scope Guarantee**:
    $$\widetilde{W} = \text{clamp}_{[-1000, 1000]}\Big(\text{sign}(W) \cdot \big\lfloor |W| \cdot 1000.0 + 0.5 \big\rfloor\Big)$$
    Weight tensors MUST NEVER undergo minimum-magnitude clamping. Weights in $(-0.0005, +0.0005)$ round naturally to integer `0x0000`.
  - **PE Datapath Operand Routing & Gating**:
    Each PE in the array receives an activation word $\widetilde{A}$, a weight word $\widetilde{W}$, and an out-of-band mask bit $M$:
    $$\begin{cases}
    \text{Multiplier clock gated, } P = 0, \text{ Acc update bypassed, } K_{\text{skipped}} \mathrel{+}= 1, & \text{if } M == 0 \\
    \text{Multiplier active, } P = \widetilde{A} \times \widetilde{W}, \text{ Acc}_k = \text{sat}_{40}(\text{Acc}_{k-1} + P), K_{\text{executed}} \mathrel{+}= 1, & \text{if } M == 1
    \end{cases}$$
  ```
- **Rationale for Change**: Eliminates in-band integer `0x0000` false-skipping and prevents weight filter distortion.
- **Dependencies**: Coupled with AMD-01 (mask extraction) and AMD-07 (SRAM budgeting).
- **Owner Approval Evidence**: Approved by Project Owner in `phase1g_5_19/OWNER_CLARIFICATION_CHECKLIST.md:Items 1 & 2`.
- **Technical Validation Status**: **`PASS_WITH_EVIDENCE`** (Verified in Phase 1G.5.25 and Phase 1G.5.26 reference model).
- **Remaining Limitations**: Physical mask SRAM macro layout pending Phase 1H RTL.

---

### Amendment Item AMD-03: Line 19 & Section 5 — Symmetric Magnitude Round-Half-Up
- **Source Decision**: `D-03 (Option A)`.
- **Original Contract Reference**: Line 19 and Section 5, Lines 79–81.
- **Original Contract Text**:
  ```markdown
  - **Hardware Rounding**: Round-half-up ($\lfloor x + 0.5 \rfloor$).
  ```
- **Ratified Replacement Text**:
  ```markdown
  - **Hardware Rounding Formula (Symmetric Magnitude Round-Half-Up)**:
    $$Q(x) = \text{sign}(x) \cdot \big\lfloor |x| + 0.5 \big\rfloor$$
    - Positive Half-Integer Ties: $+1.5 \to +2, +2.5 \to +3$.
    - Negative Half-Integer Ties: $-1.5 \to -2, -2.5 \to -3$.
  - **Mathematical Scope**:
    Applied uniformly to all activations and weight quantizers in software adapters, oracles, and RTL fixed-point rounders.
  ```
- **Rationale for Change**: Reconciles the contract prose label ("round-half-up") with exact sign symmetry. Unidirectional $\lfloor x + 0.5 \rfloor$ creates a negative $-1\text{ LSB}$ bias on negative ties ($-1.5 \to -1$), causing directional drift across deep layers.
- **Dependencies**: Coupled with AMD-01, AMD-02, and AMD-06.
- **Owner Approval Evidence**: Approved by Project Owner in `phase1g_5_17/PROJECT_OWNER_APPROVAL_SHEET.md:Line 109`.
- **Technical Validation Status**: **`PASS_WITH_EVIDENCE`** (Bit-exact verified in Phase 1G.5.25 `test_arithmetic.py`, 23/23 tests pass).
- **Remaining Limitations**: RTL rounder datapath logic pending Phase 1H.

---

### Amendment Item AMD-04: Line 52 — Accumulator Bound Reconciliation to Case C
- **Source Decision**: `D-06 (Option A)`.
- **Original Contract Reference**: Line 52.
- **Original Contract Text**:
  ```markdown
  - **Maximum Analytical Accumulation Bound**: $B = 69,120,000,000$ with $7.95\times$ margin against 40-bit accumulator limit.
  ```
- **Ratified Replacement Text**:
  ```markdown
  - **Authoritative Worst-Case Accumulator Bound (Case C Envelope)**:
    For maximum reduction depth $K = 4608$ (ResNet18 / VGG16 late layers), maximum weight clamp magnitude $|W| = 1000$, and ratified INT16 activation clamp envelope $[-32768, +32767]$:
    $$B_C = 4608 \times 32768 \times 1000 = \mathbf{150,994,944,000}$$
  - **Verified Headroom & Guard Bits**:
    Against the signed 40-bit positive saturation boundary ($2^{39}-1 = 549,755,813,887$):
    $$\text{Headroom Ratio} = \frac{549,755,813,887}{150,994,944,000} \approx \mathbf{3.6409\times}$$
    $$\text{Guard Bits} = \log_2(3.640889) \approx \mathbf{1.8643\text{ bits}}$$
  ```
- **Rationale for Change**: The original contract Line 52 figure ($69.12\text{ B}$) assumed an unratified activation clamp of $[-15000, 15000]$, directly contradicting Line 19. Case C bound $B_C$ mathematically harmonizes Line 52 with the ratified $[-32768, 32767]$ INT16 clamp.
- **Dependencies**: Coupled with AMD-01 and AMD-05.
- **Owner Approval Evidence**: Approved by Project Owner in `phase1g_5_21/OWNER_DECISION_SHEET_D05_D08.md:Line 56`.
- **Technical Validation Status**: **`PASS_WITH_EVIDENCE`** (Verified in Phase 1G.5.24 and Phase 1G.5.25).
- **Remaining Limitations**: Empirical validation of activation peaks across all unpruned layers pending Phase 1H.

---

### Amendment Item AMD-05: Line 50 — Signed Asymmetric Saturation & PMU Sticky Flag
- **Source Decision**: `D-07 (Option A)`.
- **Original Contract Reference**: Line 50.
- **Original Contract Text**:
  ```markdown
  - **Accumulator Saturation**: Exact-magnitude symmetric saturation $[-549,755,813,887, +549,755,813,887]$.
  ```
- **Ratified Replacement Text**:
  ```markdown
  - **Signed Asymmetric Two's-Complement Per-Step Saturation**:
    $$\text{sat}_{40}(x) = \begin{cases}
    +549,755,813,887 \ (2^{39}-1), & \text{if } x > 2^{39}-1 \\
    -549,755,813,888 \ (-2^{39}), & \text{if } x < -2^{39} \\
    x, & \text{otherwise}
    \end{cases}$$
  - **Hardware Diagnostic PMU Flag**:
    A 1-bit sticky saturation flag is implemented in each PE accumulator controller. If $\text{sat}_{40}(x)$ clamps an operand, the flag latches high (`1'b1`) and remains asserted until cleared by synchronous software write.
  ```
- **Rationale for Change**: Corrects inaccurate terminology from "symmetric" to standard two's-complement asymmetric saturation, avoiding extra hardware logic to discard $-2^{39}$. Prevents catastrophic modular bit-flipping wraparound while PMU flag enables overflow detection.
- **Dependencies**: Coupled with AMD-04.
- **Owner Approval Evidence**: Approved by Project Owner in `phase1g_5_21/OWNER_DECISION_SHEET_D05_D08.md:Line 71`.
- **Technical Validation Status**: **`PASS_WITH_EVIDENCE`** (Verified in Phase 1G.5.25 and Phase 1G.5.26 reference models).
- **Remaining Limitations**: PMU register map synthesis pending Phase 1H RTL.

---

### Amendment Item AMD-06: Line 80 — Verification Oracle Algorithmic Tie Gate
- **Source Decision**: `D-08 (Option A)`.
- **Original Contract Reference**: Line 80.
- **Original Contract Text**:
  ```markdown
  - **Oracle Verification Contract**: Verification oracles comparing software banker's rounding (`np.round`) to hardware output must accept a $\pm 1\text{ LSB}$ tie-break tolerance on odd half-integers ($2.5, 4.5, \dots$).
  ```
- **Ratified Replacement Text**:
  ```markdown
  - **Algorithmic Tie-Gate Tolerance Gating**:
    Verification oracles comparing symmetric hardware round-half-up against software banker's rounding (`np.round`) accept a $\pm 1\text{ LSB}$ tolerance STRICTLY when the unrounded activation or weight $x$ satisfies:
    $$\big||x| - (\lfloor |x| \rfloor + 0.5)\big| < 1.0 \times 10^{-5} \quad \land \quad \lfloor |x| \rfloor \pmod 2 == 0$$
    Exact bit-true identity ($\Delta == 0$) is strictly required on all other inputs. Blanket $\pm 1\text{ LSB}$ tolerances across non-tie coordinates are strictly barred.
  ```
- **Rationale for Change**: Corrects a mathematical parity error in contract Line 80 (where $2.5$ has floor 2, which is even, not odd). Prevents verification oracles from masking real off-by-one RTL logic bugs.
- **Dependencies**: Coupled with AMD-03.
- **Owner Approval Evidence**: Approved by Project Owner in `phase1g_5_21/OWNER_DECISION_SHEET_D05_D08.md:Line 86`.
- **Technical Validation Status**: **`PASS_WITH_EVIDENCE`** (Verified in Phase 1G.5.25 test oracle).
- **Remaining Limitations**: Oracle test harness full model integration pending Phase 1H.

---

### Amendment Item AMD-07: Line 83 — On-Chip SRAM Budget Provisioning (5,184 Bytes Hybrid)
- **Source Decision**: `D-11 (Option 11-A)`.
- **Original Contract Reference**: Line 83.
- **Original Contract Text**:
  ```markdown
  - **Tile SRAM Budget**: Strict 1.5 KiB cap per tile for all on-chip storage.
  ```
- **Ratified Replacement Text**:
  ```markdown
  - **Ratified Tile SRAM Budget (Hybrid Double-Buffered Model)**:
    Contract Line 83 is amended to provision **5,184 bytes (5.06 KiB)** of total on-chip SRAM and register storage per tile:
    1. Operands (Double-Buffered to hide DRAM reload latency):
       - Weight Buffer: $2 \times (16 \times 16 \times 2\text{ B}) = \mathbf{1024\text{ bytes}}$.
       - Activation Buffer: $2 \times (16 \times 16 \times 2\text{ B}) = \mathbf{1024\text{ bytes}}$.
       - Packed 1-Bit Mask SRAM: $2 \times (16 \times 16 / 8\text{ B}) = \mathbf{64\text{ bytes}}$.
    2. Core Accumulator Storage (Single Bank with Dynamic Tags):
       - 256 physical slots $\times 40\text{ bits} = \mathbf{1280\text{ bytes}}$.
    3. Lifecycle, Routing, and Metadata Storage:
       - Generation Tag Registers: $256 \times 1\text{ B} = \mathbf{256\text{ bytes}}$.
       - Progress Counter Registers: $256 \times 26\text{ bits} / 8 = \mathbf{832\text{ bytes}}$.
       - Input Systolic Deskew FIFOs: $(16+16) \times 4 \times 2\text{ B} = \mathbf{256\text{ bytes}}$.
       - Output Drain FIFOs: $16 \times 4 \times 5\text{ B} = \mathbf{320\text{ bytes}}$.
       - NoC Mesh Router Flit Buffers: $4 \times 4 \times 8\text{ B} = \mathbf{128\text{ bytes}}$.
    $$\text{Total Tile Budget} = 2112\text{ B (operands)} + 1280\text{ B (acc)} + 1088\text{ B (meta)} + 704\text{ B (queues)} = \mathbf{5,184\text{ bytes}} = \mathbf{5.0625\text{ KiB}}$$
  ```
- **Rationale for Change**: Replaces the unfeasible 1.5 KiB figure which omitted activations, mask SRAM, and 40-bit accumulators. 5,184 bytes provisions full double-buffering for inputs while keeping accumulators single-buffered to maximize silicon area efficiency.
- **Dependencies**: Coupled with AMD-01, AMD-02, AMD-04, and AMD-05.
- **Owner Approval Evidence**: Approved by Project Owner in `phase1g_5_28/OWNER_DECISION_WORKSHEET.md:Line 75`.
- **Technical Validation Status**: **`PASS_WITH_EVIDENCE`** (Reconciled analytically in Phase 1G.5.22, 23, 27, 28).
- **Remaining Limitations**: Memory compiler macro layout compilation pending Phase 1H.

---

## 3. Supplementary Architectural Specifications

### Section 3: Authoritative 10-Stage Execution Pipeline Order (D-05)
```
1. Input Load (FP32) -> 2. Mask Extraction (M = A != 0.0) -> 3. Packed-Mask SRAM Storage
-> 4. Linear Scaling (x1000) -> 5. Symmetric Rounding -> 6. INT16 Range Clamp (no min-mag)
-> 7. Tile Dispatch ({M, INT16}) -> 8. PE MAC Gating (M==0 skip)
-> 9. PE Compute & Accumulate -> 10. Resolved-K Progress Commit
```

### Section 4: Progress Tracking Mechanics (D-09 Option 09-A)
$$K_{\text{resolved}} = K_{\text{executed}} + K_{\text{skipped}} == K_{\text{total}}$$
Progress commit occurs strictly when $K_{\text{resolved}} == K_{\text{total}}$. Interconnect must guarantee in-order delivery per tile pair via dimension-order routing.

### Section 5: Layer Drain-and-Quiesce Barrier (D-10 Option 10-C)
To guarantee zero inter-layer packet aliasing, a global hardware barrier controller enforces that layer $L+1$ cannot dispatch reduction tiles until all in-flight flits and partial sum drains from layer $L$ have retired.

### Section 6: Permanent Archival Retention Policy (D-12 Option 12-A)
All historical manifests and files remain immutable. All 22 historical mismatches are permanently classified as `VERIFIED_MISMATCH_CAUSE_UNKNOWN`.

---

## 4. Status Declaration

This addendum is **`RATIFIED AND BINDING`** upon the project architecture, having received explicit human owner sign-off in [`phase1g_5_28_d09_d13_decision_resolution/OWNER_DECISION_WORKSHEET.md`](file:///home/cs25m115/Neural_Acc/phase1g_5_28_d09_d13_decision_resolution/OWNER_DECISION_WORKSHEET.md).

