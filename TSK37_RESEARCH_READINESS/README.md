# TSK-37: Research Evidence Package and Paper Readiness Audit

**Project:** Neural_Acc — Activation-Sparse CNN Accelerator with Adaptive PE Allocation  
**Directory:** `TSK37_RESEARCH_READINESS/`  
**Date:** November 4, 2026  

---

## Overview

This directory contains the consolidated, independently audited research evidence package for the `Neural_Acc` project, covering milestones TSK-28 through TSK-37. All datasets, scripts, testbenches, and reports herein have been verified against the protected baseline RTL without modifying any baseline hardware or creating Git commits.

---

## Directory Contents

| File Name | Description | Key Metric / Status |
| :--- | :--- | :--- |
| **`TSK37_RESEARCH_READINESS_REPORT.md`** | Comprehensive 10-section paper readiness audit report | Full cross-milestone audit |
| **`TSK37_LIMITATIONS_AND_OPEN_QUESTIONS.md`** | Detailed boundary conditions, microarchitectural trade-offs, and open research questions | Mandatory author/reviewer guide |
| **`TSK37_RESEARCH_CLAIM_MATRIX.csv`** | Mapping of 10 scientific claims to evidence, status, limitations, and paper wording | 10 audited scientific claims |
| **`TSK37_EXPERIMENT_PROVENANCE.csv`** | Provenance of 19 core repository artifacts with SHA-256 hashes, sizes, commands, and tool versions | 19 audited artifacts |
| **`TSK37_NUMERICAL_EVIDENCE.csv`** | Independent re-computation of 40-bit convolution across WL1–WL4 | 1,024 elements, 0 mismatches, MAE=0.0 |
| **`TSK37_SPARSE_EXECUTION_RESULTS.csv`** | Matched Dense vs Sparse execution audit across 12 workload-mode configurations | Latency: 0.00% Δ; Switching: -48% to -85% |
| **`TSK37_ADAPTIVE_POLICY_RESULTS.csv`** | Exhaustive 201-point boundary sweep of Policy A and B with safety interlock tests | 201/201 passed; 100% blocked on Pmax < 16 |
| **`reproduce_numerical_evidence.py`** | Standalone Python script for independent numerical reference generation | Pure Python dot-product engine |
| **`reproduce_sparse_evidence.py`** | Standalone Python script for sparse execution and SRAM trade-off auditing | Direct raw telemetry auditor |
| **`tb_tsk37_policy_audit.sv`** | SystemVerilog testbench sweeping 200 policy boundary combinations + recovery | Cycle-accurate RTL verification |
| **`generate_provenance.py`** | Python script generating cryptographic artifact provenance dataset | Automated SHA-256 auditor |
| **`generate_claim_matrix.py`** | Python script generating research claim matrix | Formatted publication claim dataset |

---

## How to Reproduce All Results

### 1. Re-Run Master Regression Suite
```bash
cd /mnt/e/MTech/LanChain/MTP
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python run_regression.py
```
*Expected: 20/20 testbenches pass, 12,202 checks pass, 0 failures, exit code 0.*

### 2. Reproduce Numerical Correctness
```bash
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python TSK37_RESEARCH_READINESS/reproduce_numerical_evidence.py
```
*Expected: 0 mismatches, MAE = 0.0, RMSE = 0.0 across 1,024 elements in WL1–WL4.*

### 3. Reproduce Sparse Execution Audit
```bash
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python TSK37_RESEARCH_READINESS/reproduce_sparse_evidence.py
```
*Expected: Confirms 0.00% latency reduction and 48.11%–84.92% weight read reduction.*

### 4. Reproduce Adaptive Policy Boundary Sweep
```bash
iverilog -g2012 -o TSK37_RESEARCH_READINESS/sim_tsk37_policy \
    TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv \
    TSK37_RESEARCH_READINESS/tb_tsk37_policy_audit.sv
vvp TSK37_RESEARCH_READINESS/sim_tsk37_policy
```
*Expected: 201 tests evaluated, 201 passed, 0 failed, ALL PASS.*

---

## Key Scientific Verdicts Summary

1. **Numerical Equivalence:** **VERIFIED** (Bit-exact MAE = 0.0 across 4 CNN layers on 4x4 spatial patches).
2. **Sparsity Switching Reduction:** **VERIFIED** (-48.1% to -84.9% weight reads and compute cycles).
3. **Sparsity Latency Speedup:** **REFUTED** (0.00% speedup due to synchronous channel stepping).
4. **Policy Determinism & Safety:** **VERIFIED** (Deterministic 16/32/64 PE selection; 100% blocked on $P_{\max} < 16$).
5. **Multi-Pass Memory Overhead:** **VERIFIED** (+100% activation reads in 32-PE, +300% in 16-PE).
6. **Total System Energy Reduction:** **NOT MEASURED** (Unsubstantiated without physical silicon characterization).

