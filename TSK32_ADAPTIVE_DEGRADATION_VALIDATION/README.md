# TSK-32: Adaptive Degradation Estimator Validation Directory

This directory contains the independent evaluation scripts, error measurement artifacts, provenance audits, and decision validation reports for milestone **TSK-32** of the **Neural_Acc** accelerator project.

---

## 1. Directory Structure

```text
TSK32_ADAPTIVE_DEGRADATION_VALIDATION/
├── README.md                              <- This directory guide
├── FINAL_AUDIT_REPORT.md                  <- Comprehensive final audit report
├── DEGRADATION_DEFINITION.md              <- Formal mathematical & provenance trace
├── EXPERIMENTAL_METHODOLOGY.md            <- Detailed experimental setup & metric formulations
├── LIMITATIONS.md                         <- Scientific limits, gaps, and threats to validity
│
├── validate_degradation_estimates.py      <- Autonomous validation and metric extraction script
│
└── Audit Verification Artifacts (CSV):
    ├── ESTIMATE_PROVENANCE.csv            <- Forensic trace of degradation values & origin
    ├── MEASURED_ERROR_METRICS.csv         <- MAE, RMSE, RelErr, SQNR, and model accuracy
    ├── ADAPTIVE_DECISION_VALIDATION.csv   <- Controller decision vs. actual constraint satisfaction
    ├── CONSTRAINT_VIOLATIONS.csv          <- Analysis of false-safe vs. overly conservative rates
    └── WORKLOAD_COVERAGE.csv              <- Coverage table of evaluated and extended layers
```

---

## 2. Reproduction Instructions

To reproduce all measurements and evaluations:

### Step 1: Run Degradation Validation Script
```bash
cd /mnt/e/MTech/LanChain/MTP/TSK32_ADAPTIVE_DEGRADATION_VALIDATION
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python validate_degradation_estimates.py
```
This script loads the CIFAR models and 100-sample test sets, extracts input patches and weights, computes true FP32 references and INT16 multi-pass accumulations, evaluates model classification accuracy, and regenerates all 5 CSV deliverables.

### Step 2: Run Verilog Regression Suite
```bash
cd /mnt/e/MTech/LanChain/MTP/TSK31_INDEPENDENT_REPRODUCIBILITY_AUDIT
vvp ./sim_tsk31
```
Executes all 28 configurations to confirm bit-exact hardware telemetry across 16-PE, 32-PE, and 64-PE modes.

### Step 3: Run Full Repository Master Regression
```bash
cd /mnt/e/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python run_regression.py
```
Confirms that all 20 test suites pass (12,202 / 12,202 checks).

---

## 3. Key Findings Summary

1. **Zero On-Chip Estimator**: The hardware contains no loss profiling or error estimation circuits.
2. **Estimates vs. Hardware Reality**: The estimates were derived from an early software channel-pruning proxy (`exp1`). In actual RTL, multi-pass channel tiling computes all channels, resulting in **0.000000 numerical error** and **0.00% accuracy loss** across all PE modes.
3. **Decision Audit**:
   - False-Safe Rate: **0.0%** (0 / 4)
   - Overly Conservative Rate: **75.0%** (3 / 4)
4. **Overall Verdict**: **`PARTIALLY_VALIDATED`**.

