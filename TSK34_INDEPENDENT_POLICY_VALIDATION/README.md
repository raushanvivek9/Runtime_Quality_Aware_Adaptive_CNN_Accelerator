# TSK-34: Independent Adaptive Resource Policy Validation

This directory contains the independent software reference model, exhaustive 192-point constraint sweep testbench, latency audit dataset, resource/energy claim analysis, and engineering reports for milestone **TSK-34** of the Neural_Acc project.

## Directory Contents & Artifacts

| File | Type | Description |
| :--- | :--- | :--- |
| `TSK34_REFERENCE_POLICY.py` | Python Script | Independent mathematical software reference implementing Policy A and Policy B; compares 192 test points against RTL outputs and generates audit datasets. |
| `tb_tsk34_policy_sweep.sv` | SystemVerilog | Cycle-accurate verification testbench driving all 192 constraint combinations into `tsk33_transparent_policy_controller.sv` using race-free `@(negedge clk)` timing. |
| `TSK34_RTL_SWEEP_OUTPUT.csv` | Dataset | Raw cycle-accurate simulation log of the 192 sweep vectors produced by Icarus Verilog. |
| `TSK34_CONSTRAINT_SWEEP.csv` | Dataset | Exhaustive 192-point cross-comparison between the independent software reference and RTL simulation (100% PASS). |
| `TSK34_LATENCY_AUDIT.csv` | Dataset | Detailed microarchitectural latency decomposition across 4 CNN workloads in Dense and Sparse regimes. |
| `TSK34_RESOURCE_CLAIM_AUDIT.md` | Document | Rigorous 7-level taxonomy distinguishing active PE counts, switching capacitance, dynamic power, and energy; includes memory-penalty quantitative analysis. |
| `TSK34_TEST_PLAN.md` | Document | Verification plan, test harness architecture, stimulus protocol, and boundary conditions. |
| `TSK34_VALIDATION_REPORT.md` | Document | Formal engineering sign-off report with cryptographic baseline hashes and quantitative results. |
| `README.md` | Document | This overview and reproduction guide. |

---

## Reproduction Instructions

### 1. Execute Hardware 192-Point Sweep Simulation
```bash
iverilog -g2012 -o sim_tsk34 tb_tsk34_policy_sweep.sv ../TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv
vvp ./sim_tsk34
```
Outputs `TSK34_RTL_SWEEP_OUTPUT.csv`.

### 2. Run Independent Software Reference Cross-Validation
```bash
python TSK34_REFERENCE_POLICY.py
```
Performs automated field-by-field scoreboarding and generates:
- `TSK34_CONSTRAINT_SWEEP.csv`
- `TSK34_LATENCY_AUDIT.csv`

---

## Summary of Results

1. **Independent Reference Scoreboarding:** **192 / 192 test points PASSED (100% agreement, 0 defects)** across both Policy A and Policy B.
2. **Boundary Precision:** Exactly validated fine-grained cycle decrements and increments ($\pm 1$ cycle) at 9,569, 19,121, and 38,225 cycles.
3. **Latency Measurement Audit:** Confirmed that cycle counts (9,569; 19,121; 38,225) are 100% deterministic microarchitectural measurements derived directly from the hardware FSM.
4. **Energy Claim Audit:** Proved that 16-PE mode incurs a **$4.0\times$ activation SRAM reload penalty** and **$\approx 4.0\times$ extended leakage integration**, demonstrating why active PE reduction cannot be claimed as total energy reduction without physical silicon characterization.
5. **Protected Baseline RTL Integrity:** Verified **0 diffs** across all five protected baseline RTL files.

