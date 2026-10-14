# Project Owner Approval Sheet: Decisions D-01 through D-04

**Document**: `PROJECT_OWNER_APPROVAL_SHEET.md`  
**Phase**: Phase 1G.5.17 — Human Decision Review: D-01 through D-04  
**Target Authority**: Project Owner / Chief Architect  
**Governance Status**: **`GOVERNANCE REVIEW ONLY — ZERO IMPLEMENTATION AUTHORIZED`**  
**Approval Precondition**: Requires explicit, unprompted human signature before Gate 0 ratification or Phase 1H execution.

---

## Executive Notice to Project Owner

This document isolates the first four decisions (`D-01` through `D-04`) from the Phase 1G.5.15 Human Decision Register. These four decisions govern the core arithmetic and sparsity boundaries of the Neural_Acc accelerator:
1. What defines an activation as sparse (`D-01`).
2. How sub-threshold non-zero values are handled when quantized (`D-02`).
3. The exact mathematical rounding rule for signed values and half-integer ties (`D-03`).
4. The exact scope and ordering of quantization clamping (`D-04`).

No decision has been ratified. All recommendations below are marked `PROPOSED_NOT_APPROVED` or `INSUFFICIENT_EVIDENCE_FOR_RECOMMENDATION`. Gate 0 remains **NOT APPROVED**, and Phase 1H remains **STRICTLY UNAUTHORIZED**.

---

# DECISIONS REQUIRING PROJECT OWNER APPROVAL

---

### Decision D-01: Architectural Activation Sparsity Semantics

1. **Original Question**:  
   *Is architectural activation sparsity exactly FP32 zero before quantization?* (`phase1g_5_15/HUMAN_DECISION_REGISTER.csv:Line 2`)

2. **Recommended Option**:  
   **Option A**: Define architectural activation sparsity strictly as exact FP32 zero ($x == 0.0$) produced post-ReLU.

3. **Recommendation Status**:  
   **`PROPOSED_NOT_APPROVED`**

4. **Exact Approval Question**:  
   > *"Do you confirm that architectural activation sparsity is defined strictly as exact post-ReLU FP32 zero ($x == 0.0$), such that only exact zeros generate bypass tokens and skip MAC operations, preserving exact analytical equivalence with the published thesis baseline?"*

5. **Alternatives**:  
   - **Option B (Quantized Integer Zero)**: Define sparsity as any activation whose 16-bit quantized integer representation is zero ($Q(x) == \mathtt{0x0000}$).
   - **Option C (Threshold-Based Sparsity)**: Define sparsity using an explicit non-zero floating-point threshold ($|x| < \theta$).

6. **Technical Consequences**:  
   - *If Option A is approved*: Maintains 100% mathematical fidelity with published research results (53.85% to 83.45% sparsity in `stage14_thesis_paper/PAPER_DRAFT.md:212-215`). Preserves zero prediction mismatches against PyTorch FP32 models. Does not harvest sub-threshold non-zeros for cycle savings.
   - *If Option B is chosen*: Increases MAC skip rate by absorbing values in $(-0.0005, +0.0005)$ into the zero token stream, but alters published cycle counts and invalidates analytical baseline models.
   - *If Option C is chosen*: Introduces non-linear truncation distortion; violates published thesis equivalence claim; risks unvalidated classification accuracy degradation.

7. **Dependencies**:  
   - Precondition for D-02 (underflow handling), D-04 (clamp scope), D-05 (pipeline order), and D-09 (resolved-K progress tracking).

8. **Evidence Required Before Implementation**:  
   - Explicit written confirmation from Project Owner approving Option A.

---

### Decision D-02: Handling of Nonzero Quantization Underflow

1. **Original Question**:  
   *What must happen when a nonzero activation would otherwise quantize to integer zero?* (`phase1g_5_15/HUMAN_DECISION_REGISTER.csv:Line 3`)

2. **Recommended Option**:  
   **Option A or Option B (Contingent on Interconnect Architecture)**:
   - *If Single-Stream In-Band Architecture*: **Option B** (Zero-Preserving Minimum Magnitude Clamp: $\widetilde{A} = \text{sign}(A) \cdot \max(1, |\text{round}(A \cdot 1000)|)$ for $A \ne 0.0$).
   - *If Dual-Stream Out-of-Band Architecture*: **Option A** (Separate FP32 1-bit zero mask stream; sub-threshold non-zeros quantize to integer 0 without magnitude inflation).

3. **Recommendation Status**:  
   **`INSUFFICIENT_EVIDENCE_FOR_RECOMMENDATION`** (Requires hardware architecture decision on in-band vs out-of-band token routing, and empirical validation of 9x noise amplification under Option B).

4. **Exact Approval Question**:  
   > *"Do you approve the zero-preserving minimum magnitude clamp ($\max(1, \dots)$ forcing non-zero activations to magnitude $\ge 1$ for in-band token encoding), OR do you mandate carrying a separate 1-bit exact-zero mask stream across the memory and PE interconnect to allow linear integer underflow without noise amplification?"*

5. **Alternatives**:  
   - **Option A (Separate 1-bit Mask Stream)**: Carry an out-of-band 1-bit valid/zero mask from FP32 extraction. Non-zeros in $(-0.0005, +0.0005)$ quantize to integer 0 without noise amplification; PE does not skip them because their mask bit is 1.
   - **Option B (Zero-Preserving Minimum Magnitude Clamp)**: Force every non-zero activation to integer magnitude $\ge 1$ ($\pm 1$). Enables in-band `0x0000` skip token without extra metadata wires, but amplifies noise for $0 < |x| < 0.0005$ by up to $9\times$.
   - **Option C (Allow Integer Zero Underflow & Skip)**: Allow sub-threshold non-zeros to quantize to `0x0000` and command MAC bypass.

6. **Technical Consequences**:  
   - *If Option A is chosen*: Zero artificial noise amplification. Perfect linear fixed-point quantization. Increases memory bandwidth and interconnect area to route 1-bit mask per activation.
   - *If Option B is chosen*: Zero interconnect wire overhead. In-band `0x0000` is 100% uniquely identified with exact FP32 zero. Introduces up to $9\times$ amplification on sub-threshold signals ($0.0001 \to 0.001$), which must be verified against model accuracy.
   - *If Option C is chosen*: Conflates quantization underflow with ReLU sparsity; unverified prediction accuracy impact.

7. **Dependencies**:  
   - Depends directly on D-01. Dictates D-04 clamping scope. Directly influences hardware datapath design in Phase 1H.

8. **Evidence Required Before Implementation**:  
   - Interconnect area and bandwidth trade-off study between in-band token vs 1-bit mask stream.
   - Empirical validation of Option B on full validation set (CIFAR-10 / CIFAR-100 / ImageNet) confirming top-1 accuracy impact is $< 0.1\%$.

---

### Decision D-03: Positive and Negative Rounding Semantics

1. **Original Question**:  
   *Which rule controls negative values and ties: written floor-based activation expression or symmetric magnitude round-half-up?* (`phase1g_5_15/HUMAN_DECISION_REGISTER.csv:Line 4`)

2. **Recommended Option**:  
   **Option A**: Formally adopt symmetric magnitude round-half-up ($Q(x) = \text{sign}(x) \cdot \lfloor |x| + 0.5 \rfloor$), with activation formula: $\widetilde{A} = \text{sign}(A) \cdot \max(1, \lfloor |A| \cdot 1000.0 + 0.5 \rfloor)$ for $A \ne 0.0$.

3. **Recommendation Status**:  
   **`PROPOSED_NOT_APPROVED`**

4. **Exact Approval Question**:  
   > *"Do you approve amending the written activation formula in Line 19 of the frozen contract to adopt symmetric magnitude round-half-up ($\widetilde{A} = \text{sign}(A) \cdot \max(1, \lfloor |A| \cdot 1000.0 + 0.5 \rfloor)$), eliminating the asymmetric negative tie bias where $-1.5$ currently evaluates to $-1$ instead of $-2$?"*

5. **Alternatives**:  
   - **Option B (Written Floor-Based Expression)**: Retain literal contract Line 19 formula: $\widetilde{A} = \text{sign}(A) \cdot \max(1, |\lfloor A \cdot 1000.0 + 0.5 \rfloor|)$.
   - **Option C (Convergent / Banker's Rounding)**: Adopt round-half-to-even ($np.round$ default) across both hardware and software.

6. **Technical Consequences**:  
   - *If Option A is approved*: Eliminates negative directional bias. Standardizes fixed-point behavior across DSPs, multipliers, and software oracles ($+1.5 \to +2$, $-1.5 \to -2$). Requires one-line text correction in contract Line 19.
   - *If Option B is retained*: Evaluates $+1.5 \to +2$ but $-1.5 \to -1$. Creates a systematic $-1\text{ LSB}$ negative bias on ties. Diverges from standard DSP arithmetic.
   - *If Option C is chosen*: Minimizes statistical drift on deep accumulation, but requires additional hardware comparator logic to inspect LSB of integer part, increasing PE area.

7. **Dependencies**:  
   - Governs D-05 (pipeline stage 4), D-08 (oracle 1-LSB tolerance gating), and Level B/C numerical verification oracles.

8. **Evidence Required Before Implementation**:  
   - Formal amendment of `FROZEN_ARITHMETIC_AND_DATAPATH_CONTRACT.md` Line 19.
   - Static test harness validating that software oracle and RTL testbench implement identical tie-handling logic.

---

### Decision D-04: Clamp Scope and Zero-Preservation Behavior

1. **Original Question**:  
   *Is forcing each nonzero input to magnitude at least one approved and what is its exact scope?* (`phase1g_5_15/HUMAN_DECISION_REGISTER.csv:Line 5`)

2. **Recommended Option**:  
   **Option A**: Scope the minimum magnitude 1 clamp strictly to post-ReLU activation tensors; weights must follow standard unconstrained quantization ($\text{clamp}_{[-1000, 1000]}(\lfloor W \cdot 1000.0 + 0.5 \rfloor)$).

3. **Recommendation Status**:  
   **`PROPOSED_NOT_APPROVED`**

4. **Exact Approval Question**:  
   > *"Do you confirm that the minimum magnitude 1 clamp ($\max(1, \dots)$) is scoped strictly and exclusively to post-ReLU activation tensors, and that weight tensors MUST NOT use minimum-magnitude clamping, preserving linear weight precision and preventing repetition of the Phase 1G.3 sentinel defect?"*

5. **Alternatives**:  
   - **Option B (Universal Minimum Magnitude Clamp)**: Apply minimum magnitude 1 universally to both activations and weights.
   - **Option C (No Minimum Magnitude Clamp on Any Tensor)**: Use standard uniform clamping on all tensors (contingent on D-02 Option A separate mask stream).

6. **Technical Consequences**:  
   - *If Option A is approved*: Weights maintain precise linear scaling around zero. Unpruned dense weights near zero round naturally to zero or $\pm 1$ without artificial inflation. Activation tokens maintain exact-zero preservation. Eliminates the risk of catastrophic filter distortion.
   - *If Option B is chosen*: Severely distorts convolution kernels by forcing weights in $(-0.0005, +0.0005)$ to $\pm 1$. Reintroduces the Phase 1G.3 sentinel substitution defect (`full_layer_adapter.py:292-293`), leading to complete prediction failure.
   - *If Option C is chosen*: Standardizes quantizer logic across all data streams, but requires separate 1-bit mask stream to prevent false zero MAC skips.

7. **Dependencies**:  
   - Coupled with D-02 (underflow policy) and D-05 (pipeline order). Precondition for finalizing tensor adapter and simulator inputs.

8. **Evidence Required Before Implementation**:  
   - Specification review confirming adapter code implements separate, unshared quantization paths for activation tensors versus weight tensors.
   - Explicit confirmation that weights with $W \approx 0.0$ are permitted to quantize to integer 0 without modification.

---

## Project Owner Signature Block

```
DECISION D-01:  [ yes ] OPTION A APPROVED    [  ] REJECTED / REVISED
DECISION D-02:  [ yes ] OPTION A APPROVED    [  ] OPTION B APPROVED    [  ] REJECTED / REVISED
DECISION D-03:  [ yes ] OPTION A APPROVED    [  ] OPTION B APPROVED    [  ] REJECTED / REVISED
DECISION D-04:  [ yes ] OPTION A APPROVED    [  ] REJECTED / REVISED

PROJECT OWNER SIGNATURE: _____Raushan vivek_______________________________
DATE:   15-10-2026                 ____________________________________
RATIFICATION STATUS:     NOT RATIFIED — AWAITING HUMAN OWNER ACTION
```
