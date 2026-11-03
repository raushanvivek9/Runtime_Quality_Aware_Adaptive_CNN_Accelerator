# TSK-33: Adaptive Resource Allocation Policy Scope and Objectives

## 1. Executive Summary & Context

The Neural_Acc accelerator employs an adaptive processing element (PE) allocation architecture configurable across three distinct active PE modes: **16-PE**, **32-PE**, and **64-PE**. In previous milestones (TSK-29 through TSK-31), an adaptive controller module (`adaptive_pe_controller.sv`) evaluated an input degradation estimate vector ($\hat{D}_{16}, \hat{D}_{32}, \hat{D}_{64}$) against programmable tolerance thresholds ($\tau_{\text{loose}}, \tau_{\text{tight}}$).

However, the independent validation performed in **TSK-32** revealed a critical structural divergence:
1. **Historical Provenance of Degradation Metric:** The degradation metric $\hat{D}_{mode}$ originated in Phase 1 (`exp1_baseline_profiling.py`) as a software channel-pruning proxy, in which a 16-PE mode was modeled by discarding 75% of input/output channels, causing severe top-1 accuracy degradation (up to 85.31%).
2. **True Phase 2 Hardware Operation:** The actual RTL engine (`tsk28_complete_convolution_engine.sv`) executes sub-64 PE modes via **sequential multi-pass channel tiling** (4 passes for 16-PE, 2 passes for 32-PE, 1 pass for 64-PE). In RTL, 100% of input channels, output channels, and spatial reduction terms are fully accumulated into the 40-bit MAC units.
3. **Empirical Numerical Correctness:** Across all 28 evaluated workload/sparsity configurations, the hardware produced **0.000000 arithmetic error** (zero L1, zero L2, zero Max error) and **0.00% model accuracy drop**.
4. **Failure of Legacy Controller:** Because the legacy controller compared non-zero pruning metrics against tight thresholds, it rejected viable 16-PE and 32-PE configurations in 75.0% of evaluated operating points, erroneously falling back to 64-PE under the false belief that numerical degradation would occur. Furthermore, the legacy controller had no mechanism to observe execution deadlines, leading to deadline violations in latency-constrained deployments.

## 2. Core Objectives of TSK-33

The objective of TSK-33 is to design, implement, and formally validate a transparent, deterministic hardware resource allocation policy that replaces ungrounded degradation estimates with measurable operational constraints:

1. **Establish Grounded Allocation Criteria:**
   - **Latency Budgets ($L_{\text{max}}$):** Hard cycle-count deadlines supplied by the system host or real-time application scheduler.
   - **Resource Ceilings ($P_{\text{max}}$):** Physical peak-power or thermal constraints limiting the maximum concurrently active PEs.
   - **Numerical Preservation:** Acknowledgment that all three PE modes preserve 100% numerical correctness.

2. **Define Two Transparent Architectural Policies:**
   - **Policy A (Minimum-Resource / Energy-Priority):** Selects the minimal active PE configuration ($P \in \{16, 32, 64\}$) capable of meeting the prescribed cycle deadline within the active PE ceiling. This minimizes instantaneous active switching capacitance and peak power.
   - **Policy B (Minimum-Latency / Throughput-Priority):** Selects the highest-performance PE configuration permitted by the active PE ceiling, maximizing throughput and frame rate.

3. **Provide Deterministic Hardware RTL Implementation:**
   - Implement `tsk33_transparent_policy_controller.sv` as a synthesizable, non-protected Verilog module with single-cycle resolution, boundary enforcement, and explicit error/fallback status flags (`fallback_asserted`, `budget_violation`).
   - Validate 100% functional correctness across 17 comprehensive test vectors covering exact cycle thresholds, boundary conditions, and invalid inputs.

4. **Preserve Protected Baseline RTL:**
   - Strictly maintain 0 diffs across all five protected baseline RTL files: `accelerator_core_top.sv`, `mac_unit_40b.sv`, `k_progress_tracker.sv`, `slot_control_unit.sv`, and `hybrid_sram_bank.sv`.
   - Maintain 0 Git commits.

---

## 3. Mathematical Policy Formulations

### 3.1 Measured RTL Workload Latency Characterization

For a standard $3 \times 3$ convolution tile with $C_{\text{in}}=64$, $C_{\text{out}}=64$, and $14 \times 14$ spatial output geometry ($K=576$, 196 spatial positions), the total execution latency $T_{\text{total}}(P)$ measured on the RTL hardware is given by:

$$T_{\text{total}}(P) = N_{\text{passes}}(P) \times \left( T_{\text{drain\_init}} + H_{\text{out}} \times \left( W_{\text{out}} \times (K + \text{pipe\_lat}) + T_{\text{line\_overhead}} \right) \right)$$

where:
- $N_{\text{passes}}(16) = 4 \implies T_{\text{total}}(16) = 38,225\text{ cycles}$
- $N_{\text{passes}}(32) = 2 \implies T_{\text{total}}(32) = 19,121\text{ cycles}$
- $N_{\text{passes}}(64) = 1 \implies T_{\text{total}}(64) = 9,569\text{ cycles}$

### 3.2 Policy A: Minimum-Resource Allocation (Energy Priority)

Policy A targets battery-constrained or thermally throttled edge environments where minimizing instantaneous power draw and active compute silicon is prioritized over completing early:

$$\text{minimize } P \in \{16, 32, 64\}$$
$$\text{subject to: } T_{\text{total}}(P) \le L_{\text{max}} \quad \text{and} \quad P \le P_{\text{max}}$$

**Decision Rule:**
$$\text{Mode}_A = \begin{cases} 
\text{16-PE} & \text{if } T_{\text{total}}(16) \le L_{\text{max}} \land P_{\text{max}} \ge 16 \\ 
\text{32-PE} & \text{else if } T_{\text{total}}(32) \le L_{\text{max}} \land P_{\text{max}} \ge 32 \\ 
\text{64-PE} & \text{else if } T_{\text{total}}(64) \le L_{\text{max}} \land P_{\text{max}} \ge 64 \\ 
\text{Fallback} & \text{otherwise} 
\end{cases}$$

**Defensive Fallback:** If no configuration satisfies both constraints jointly, Policy A selects the highest PE count respecting $P_{\text{max}}$ (to get as close to the deadline as possible without violating physical power limits) and asserts:
$$\text{fallback\_asserted} = 1, \quad \text{budget\_violation} = 1$$

### 3.3 Policy B: Minimum-Latency Allocation (Throughput Priority)

Policy B targets cloud-inference or high-frame-rate computer vision deployments where maximum throughput is desired while staying strictly within physical hardware resource limits:

$$\text{maximize } P \in \{16, 32, 64\}$$
$$\text{subject to: } P \le P_{\text{max}}$$

**Decision Rule:**
$$\text{Mode}_B = \begin{cases} 
\text{64-PE} & \text{if } P_{\text{max}} \ge 64 \\ 
\text{32-PE} & \text{else if } P_{\text{max}} \ge 32 \\ 
\text{16-PE} & \text{else if } P_{\text{max}} \ge 16 \\ 
\text{16-PE (Defensive)} & \text{otherwise } (P_{\text{max}} < 16) 
\end{cases}$$

**Deadline Tracking:** Policy B asserts $\text{budget\_violation} = 1$ if $T_{\text{total}}(\text{Mode}_B) > L_{\text{max}}$, informing the host scheduler of the deficit without altering the optimal high-throughput mode.

---

## 4. Architectural Boundaries and Limitations

1. **Microarchitectural vs. Silicon Metrics:** All metrics reported herein (execution cycles, SRAM read counts, zero-skips, active PE counts) are deterministic microarchitectural measurements derived directly from cycle-accurate Verilog simulation. Dynamic energy dissipation ($\text{nJ}$), leakage power ($\mu\text{W}$), and cell silicon area ($\mu\text{m}^2$) require post-synthesis standard cell placement and parasitic extraction (e.g. TSMC 28nm/16nm PDKs), and are therefore not claimed without silicon characterization.
2. **Channel Tiling Memory Access Trade-Off:** While 16-PE mode reduces active MAC switching logic by 75%, multi-pass channel tiling requires reloading the activation feature map 4 times (36,864 SRAM word reads vs. 9,216 for 64-PE). System designers must evaluate this compute-vs-memory balance against external memory bandwidth constraints.

