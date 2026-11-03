# TSK-33: Adaptive Resource Allocation Policy Redesign & Validation

This directory contains the complete implementation, verification testbench, quantitative comparison datasets, and engineering documentation for milestone **TSK-33** of the Neural_Acc project.

## Directory Structure & Artifacts

| File | Type | Description |
| :--- | :--- | :--- |
| `tsk33_transparent_policy_controller.sv` | SystemVerilog | Synthesizable hardware resource allocation controller implementing Policy A and Policy B with defensive fallback logic. |
| `tb_tsk33_policy_validation.sv` | SystemVerilog | Cycle-accurate testbench verifying 17 boundary, threshold, resource-cap, and reset test vectors. |
| `generate_tsk33_data.py` | Python Script | Generates reproducible workload measurement datasets and multi-scenario policy comparison matrices. |
| `TSK33_MEASUREMENT_RESULTS.csv` | Dataset | Measured RTL cycle counts, SRAM activation/weight reads, zero-skips, and integer error for 28 configurations across 4 workloads. |
| `TSK33_POLICY_COMPARISON.csv` | Dataset | Direct comparison of Legacy (TSK-30), Policy A, and Policy B across 16 scenario-workload deployment points. |
| `TSK33_RTL_TEST_RESULTS.csv` | Dataset | Output test execution log confirming 17/17 passing hardware assertions with 0 failures. |
| `TSK33_SCOPE_AND_OBJECTIVE.md` | Document | Detailed formulation of Policy A and Policy B, mathematical bounds, and microarchitectural boundaries. |
| `TSK33_POLICY_COMPARISON.md` | Document | In-depth comparative analysis detailing the failure mechanisms of the legacy controller and compute-vs-memory trade-offs. |
| `TSK33_TEST_PLAN.md` | Document | Verification plan, test harness architecture, stimulus protocol, and coverage matrix. |
| `TSK33_VALIDATION_REPORT.md` | Document | Formal engineering sign-off report with cryptographic baseline hashes and quantitative results. |
| `README.md` | Document | This overview and reproduction guide. |

---

## Reproduction Instructions

### 1. Reproduce Measurement and Policy Datasets
```bash
python generate_tsk33_data.py
```
Outputs `TSK33_MEASUREMENT_RESULTS.csv` and `TSK33_POLICY_COMPARISON.csv`.

### 2. Compile and Simulate Hardware Policy Controller
```bash
iverilog -g2012 -o sim_tsk33 tb_tsk33_policy_validation.sv tsk33_transparent_policy_controller.sv
vvp ./sim_tsk33
```
Outputs console pass/fail status and creates `TSK33_RTL_TEST_RESULTS.csv` confirming 17/17 tests passing.

---

## Summary of Results

1. **Hardware Verification:** **17 / 17 tests passed (100% pass rate, 0 defects)**.
2. **Legacy Deadlock Elimination:** The legacy controller missed 75% of real-time deadlines in tight-latency scenarios; Policy A and Policy B achieved **100% deadline satisfaction**.
3. **Power / Thermal Cap Compliance:** Policy A and Policy B strictly respect the active PE ceiling ($P_{\text{max}}$), preventing the 100% thermal over-allocation caused by the legacy controller in high-sparsity layers.
4. **Protected Baseline RTL Integrity:** Verified **0 diffs** across all five baseline RTL files.

