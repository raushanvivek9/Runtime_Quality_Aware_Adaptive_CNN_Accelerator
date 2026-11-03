# TSK-36: Independent Reproducibility & Research-Claim Audit

## 1. Directory Overview

This directory (`TSK36_REPRODUCIBILITY_AUDIT`) contains the independent audit reports, verification testbenches, reproduction scripts, and research-claim classification matrices for **TSK-36**.

The objective of TSK-36 is to independently audit the reproducibility, correctness, measurement methodology, and scientific claims established across milestones **TSK-28 through TSK-35B** for the `Neural_Acc` accelerator project.

---

## 2. File Inventory

| File | Description |
| :--- | :--- |
| [TSK36_REPRODUCIBILITY_REPORT.md](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/TSK36_REPRODUCIBILITY_REPORT.md) | Comprehensive engineering audit report covering all six phases and evidence separations. |
| [TSK36_ARTIFACT_PROVENANCE.csv](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/TSK36_ARTIFACT_PROVENANCE.csv) | Cryptographic census and tool provenance across 35 core project artifacts. |
| [TSK36_NUMERICAL_REPRODUCTION.csv](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/TSK36_NUMERICAL_REPRODUCTION.csv) | Element-by-element numerical verification across 4 real CNN layers (1,024 elements). |
| [TSK36_POLICY_BOUNDARY_AUDIT.csv](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/TSK36_POLICY_BOUNDARY_AUDIT.csv) | Audit of 200 policy boundary combinations and recovery scenarios. |
| [TSK36_SPARSE_EXECUTION_AUDIT.csv](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/TSK36_SPARSE_EXECUTION_AUDIT.csv) | Disaggregated Dense vs Sparse execution comparison auditing latency vs power claims. |
| [TSK36_RESOURCE_LATENCY_AUDIT.csv](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/TSK36_RESOURCE_LATENCY_AUDIT.csv) | Recalculation of mode cycle counts, setup/drain breakdown, and memory traffic trade-offs. |
| [TSK36_RESEARCH_CLAIM_MATRIX.csv](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/TSK36_RESEARCH_CLAIM_MATRIX.csv) | Formal classification of 8 research claims into VERIFIED, REFUTED, and NOT MEASURED. |
| [independent_numerical_reference.py](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/independent_numerical_reference.py) | Standalone Python software convolution reference model. |
| [tb_tsk36_policy_audit.sv](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/tb_tsk36_policy_audit.sv) | SystemVerilog testbench evaluating 202 policy boundary combinations. |
| [audit_sparse_execution.py](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/audit_sparse_execution.py) | Python script auditing sparse execution claims and cycle deltas. |
| [audit_resource_latency.py](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/audit_resource_latency.py) | Python script recalculating speedups, PE reductions, and multi-pass SRAM overheads. |
| [generate_provenance.py](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/generate_provenance.py) | Python script auditing file sizes and SHA-256 hashes. |
| [generate_claim_matrix.py](file:///e:/MTech/LanChain/MTP/TSK36_REPRODUCIBILITY_AUDIT/generate_claim_matrix.py) | Python script compiling the research claim matrix. |

---

## 3. Reproduction Instructions

### 3.1 Run Independent Numerical Reference Verification (Phase 2)
```bash
python independent_numerical_reference.py
```

### 3.2 Run Independent Policy Boundary RTL Simulation (Phase 3)
```bash
iverilog -g2012 -o sim_tsk36_policy \
    ../TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv \
    tb_tsk36_policy_audit.sv
vvp ./sim_tsk36_policy
```

### 3.3 Audit Sparse Execution Claims (Phase 4)
```bash
python audit_sparse_execution.py
```

### 3.4 Audit Resource vs Latency Trade-Offs (Phase 5)
```bash
python audit_resource_latency.py
```

### 3.5 Run Master Regression Suite (Phase 6)
```bash
cd ../phase2_step1_microarchitecture_and_rtl
python run_regression.py
cd ../TSK36_REPRODUCIBILITY_AUDIT
```

---

## 4. Protected Baseline Integrity

As strictly required, the five baseline RTL files were verified unmodified (0 diffs, cryptographic hash match):
- `phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv`
- `phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv`
- `phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv`
- `phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv`
- `phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv`

