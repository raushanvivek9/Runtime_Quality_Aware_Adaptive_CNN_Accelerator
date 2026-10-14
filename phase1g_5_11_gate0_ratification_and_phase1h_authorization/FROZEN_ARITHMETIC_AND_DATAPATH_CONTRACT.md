# Frozen Arithmetic and Datapath Contract: Phase 1H Engineering Specification

**Document**: `FROZEN_ARITHMETIC_AND_DATAPATH_CONTRACT.md`  
**Phase**: Phase 1G.5.11 — Gate 0 Ratification and Phase 1H Authorization  
**Authority**: Architecture Governance Committee  
**Status**: **`FROZEN ARITHMETIC CONTRACT FOR PHASE 1H RTL AND SIMULATION`**  

---

## 1. Primary Fixed-Point Scaling & Clamping Contract

### 1.1 Activation Quantization & Clamping
- **Scale Factor**: $S_A = 1000.0$
- **Input Dynamic Range**: $A \in [-32.768, +32.767]$ (Continuous FP32)
- **Zero Definition**: Exact FP32 zero ($A == 0.0$ post-ReLU)
- **Zero-Preserving Clamp Function**:
  $$\widetilde{A} = \begin{cases}
  \mathtt{0x0000}, & \text{if } A == 0.0 \\
  \text{clamp}_{[-32768, 32767]}\Big(\text{sign}(A) \cdot \max\big(1, |\lfloor A \cdot 1000.0 + 0.5 \rfloor|\big)\Big), & \text{if } A \ne 0.0
  \end{cases}$$
- **Data Type**: Signed 16-bit integer (`INT16`), two's complement.
- **Architectural Zero Token**: `0x0000` signals an architectural zero activation and commands the PE datapath to bypass the MAC cycle.

### 1.2 Weight Quantization & Clamping
- **Scale Factor**: $S_W = 1000.0$
- **Weight Dynamic Range**: $W \in [-1.0, +1.0]$ (Continuous FP32)
- **Weight Clamping**:
  $$\widetilde{W} = \text{clamp}_{[-1000, 1000]}\big(\lfloor W \cdot 1000.0 + 0.5 \rfloor\big)$$
- **Data Type**: Signed 16-bit integer (`INT16`), two's complement.
- **Sparsity**: Dense weights in baseline unpruned models.

---

## 2. MAC Datapath & Product Specification

- **Multiplier Input 1**: $\widetilde{A}$ (16-bit signed, $[-32768, +32767]$).
- **Multiplier Input 2**: $\widetilde{W}$ (16-bit signed, $[-1000, +1000]$).
- **Product Range**:
  $$P = \widetilde{A} \times \widetilde{W} \in [-32,768,000, +32,768,000]$$
- **Product Register**: Signed 32-bit integer (`INT32`), capacity $[-2,147,483,648, +2,147,483,647]$.
- **Zero Gating**: If $\widetilde{A} == \mathtt{0x0000}$, the multiplier clock/enable is gated, product $P=0$ is forced, and no addition is executed.

---

## 3. Accumulator Bit-Width & Saturation Clamping

- **Maximum Accumulation Depth**: $K_{\max} = 4608$ (DenseLayer-3).
- **Accumulator Bit-Width**: **40-bit signed integer** (`INT40`, two's complement).
- **Guard Bits**: 8 guard bits above the 32-bit product ($32 + 8 = 40$ bits).
- **Representable Range**:
  $$[-2^{39}, +2^{39} - 1] = [-549,755,813,888, +549,755,813,887]$$
- **Worst-Case Sum**: $B_{\text{sum}} = 4608 \times 15000 \times 1000 = 6.912 \times 10^{10} \implies 7.95\times$ safety margin.
- **Saturation Rule**:
  $$\text{Acc}_{k} = \begin{cases}
  +549,755,813,887, & \text{if } \text{Acc}_{k-1} + P > +549,755,813,887 \\
  -549,755,813,888, & \text{if } \text{Acc}_{k-1} + P < -549,755,813,888 \\
  \text{Acc}_{k-1} + P, & \text{otherwise}
  \end{cases}$$
- **Modular Wraparound**: Strictly prohibited.

---

## 4. Multi-Tile Progress Tracking Contract

- **Elimination of Counter Deadlock**: The predicate `acc.count == K` is completely abolished.
- **Resolved-K Frontier Tracker**:
  Each accumulator slot maintains:
  - $K_{\text{executed}}$: Non-zero products accumulated.
  - $K_{\text{skipped}}$: Zero tokens bypassed.
  - $K_{\text{resolved}} = K_{\text{executed}} + K_{\text{skipped}}$.
- **Finalization Predicate**:
  $$\mathtt{output\_ready} = (K_{\text{resolved}} == K)$$
- **Interconnect Guarantee**: Tile interconnect routers guarantee strict in-order arrival of $K$-slices.

---

## 5. Rounding, Dequantization, & Oracle Tolerance

- **Hardware Rounding**: Round-half-up ($\lfloor x + 0.5 \rfloor$).
- **Oracle Verification Contract**: Verification oracles comparing software banker's rounding (`np.round`) to hardware output must accept a **$\pm 1\text{ LSB}$ tie-break tolerance** on odd half-integers ($2.5, 4.5, \dots$).
- **Dequantized Output**:
  $$\widehat{Y} = \frac{\text{Acc}}{S_A \cdot S_W} = \frac{\text{Acc}}{1,000,000.0}$$
- **Baseline Dataflow Memory Schedule**: **Schedule S1** (Output-stationary per tile with $K$-reduction; 1.5 KiB on-chip SRAM).

