# TSK-30: Multi-Workload Adaptive PE Allocation Validation

## 1. Overview
The **TSK-30** milestone provides an empirical, cycle-accurate evaluation of the `Neural_Acc` accelerator's adaptive processing element (PE) allocation mechanism and sparse activation zero-skipping logic across **multiple real CNN convolution workloads**.

Using validated model checkpoints (**ResNet-18 on CIFAR-10**, **ResNet-18 on CIFAR-100**, and **VGG-16-BN on CIFAR-10**), TSK-30 evaluates **28 distinct configurations** (7 per workload) across Fixed 16-PE, 32-PE, 64-PE, and Stage 8A dynamic adaptive allocation under both dense and sparse activation regimes.

---

## 2. Key Empirical Findings

1. **Numerical Correctness & Cross-Mode Equivalence**:
   - All 28 configurations achieved **100% bit-exact equivalence** with the software golden reference and across modes.
   - Evaluated 7,168 total output elements with **0 mismatches** ($\text{MAE} = 0$, $\text{RMSE} = 0$, $\text{Max Error} = 0$).
2. **Sparse Activation Skipping Benefits**:
   - Weight SRAM read reductions directly matched activation sparsity across all layers:
     - **WL3 (VGG-16 Early)**: 48.11% sparsity $\rightarrow$ **48.11% weight SRAM reduction** (76,512 reads)
     - **WL2 (R18-C100 Early)**: 66.57% sparsity $\rightarrow$ **66.57% weight SRAM reduction** (49,296 reads)
     - **WL1 (R18-C10 Early)**: 68.89% sparsity $\rightarrow$ **68.89% weight SRAM reduction** (45,872 reads)
     - **WL4 (R18-C10 Deep)**: 84.92% sparsity $\rightarrow$ **84.92% weight SRAM reduction** (22,240 reads)
   - Active MAC compute switching cycles dropped by the identical percentages.
3. **Adaptive PE Selection Policy Verification**:
   - **Smallest Mode Selection**: In WL4 ($\hat{D}_{16} \le D_{max}$), the controller successfully selected **16-PE mode**, deactivating **75.0% of PE columns** with zero fallback.
   - **Intermediate Mode Selection**: In WL1 and WL2 ($\hat{D}_{32} \le D_{max}$), the controller selected **32-PE mode**, deactivating **50.0% of PE columns**.
   - **Conservative Fallback**: In WL3 (where neither mode satisfies $D_{max}$), the controller asserted `fallback_asserted = 1'b1` and selected **64-PE mode**, ensuring model accuracy is preserved.
4. **Latency vs. Area Trade-Off**:
   - Adaptive allocation acts as an **area/power throttle**, not a latency accelerator. Reduced PE modes incur proportional multi-pass channel tiling latency ($2.0\times$ in 32-PE, $4.0\times$ in 16-PE).

---

## 3. Directory Structure

| File / Directory | Description |
| :--- | :--- |
| `tsk30_multi_workload_engine.sv` | Synthesizable hardware engine integrating `adaptive_pe_controller.sv`, 16 physical MAC units, parametric addressing, and telemetry. |
| `tb_tsk30_multi_workload_validation.sv` | Comprehensive verification testbench executing all 28 configurations across 4 workloads. |
| `WORKLOAD_MATRIX.csv` | Layer parameters, dimensions, sparsity, and degradation thresholds for all 4 workloads. |
| `CONFIGURATION_MATRIX.csv` | Detailed matrix of all 28 evaluated configurations. |
| `RAW_METRICS.csv` | Raw hardware cycle counts, SRAM read counts, and telemetry captured during simulation. |
| `TSK30_RESULTS.csv` | Consolidated cross-workload comparison table with latency ratios and reduction percentages. |
| `NUMERICAL_CORRECTNESS.csv` | Complete element-by-element numerical verification table for all 7,168 outputs. |
| `ADAPTIVE_DECISIONS.csv` | Log of Stage 8A adaptive PE controller mode selection and fallback status. |
| `EXPERIMENTAL_METHODOLOGY.md` | Benchmarking protocols, workload provenance, and metric formulas. |
| `PERFORMANCE_ANALYSIS.md` | In-depth engineering analysis addressing the 5 core research questions. |
| `LIMITATIONS.md` | Microarchitectural boundaries and physical hardware disclaimers. |
| `FINAL_AUDIT_REPORT.md` | Milestone engineering audit report with Acceptance Criteria Scorecard. |
| `prepare_tsk30_workloads.py` | Python script to extract real model activations/weights and generate golden references. |
| `generate_tsk30_results.py` | Python script to parse raw metrics and generate consolidated comparison tables. |
| `tensors/` | Quantized input activations, weights, and golden reference predictions for WL1-WL4. |

---

## 4. Reproduction Instructions

### 4.1 Prerequisites
- Icarus Verilog (`iverilog`) v12.0 or later
- Python 3.8+ with PyTorch and Pandas

### 4.2 Regenerating Workload Tensors (Optional)
```bash
python3 prepare_tsk30_workloads.py
```

### 4.3 Running the Simulation
```bash
cd TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION
iverilog -g2012 -o sim_tsk30 \
    ../phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv \
    ../phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv \
    spatial_tile_sequencer.sv \
    tsk27c_spatial_accumulation_controller.sv \
    tsk30_multi_workload_engine.sv \
    tb_tsk30_multi_workload_validation.sv
vvp ./sim_tsk30
```

### 4.4 Generating Consolidated Results
```bash
python3 generate_tsk30_results.py
```

### 4.5 Expected Simulation Summary
```text
==================================================================
 TSK-30 COMPREHENSIVE VERIFICATION AUDIT SUMMARY
==================================================================
 Total Workloads Evaluated      : 4 (WL1, WL2, WL3, WL4)
 Total Configurations Evaluated : 28 (7 per Workload)
 Total Assertions Passed        : 120
 Total Assertions Failed        : 0
 Overall Verification Status    : ALL 28 CONFIGURATIONS PASSED
==================================================================
[SUCCESS] All TSK-30 Multi-Workload Tests PASSED with Zero Defects!
```

