# TSK-29: Adaptive PE Allocation and Sparse Execution Evaluation

## 1. Overview
The **TSK-29** milestone delivers an empirical, cycle-accurate evaluation of the `Neural_Acc` accelerator's adaptive processing element (PE) allocation mechanism and sparse activation zero-skipping logic.

Using the fully validated real-model convolution workload from **TSK-28** (**ResNet-18 on CIFAR-10**, `layer1.0.conv1`, $4 \times 4$ spatial grid, 16 output channels, 64 input channels, $K = 576$ reduction terms = 147,456 total MAC operations), this evaluation rigorously compares **7 distinct operating configurations** spanning fixed 16-PE, 32-PE, 64-PE, and Stage 8A dynamic adaptive allocation under both dense and sparse activation regimes.

---

## 2. Key Empirical Findings

1. **Numerical Correctness & Mode Equivalence**:
   - All 7 configurations achieved **100% bit-exact equivalence** with the software golden reference and across modes.
   - 256/256 output elements matched exactly with zero numerical mismatches ($\text{MAE} = 0$, $\text{RMSE} = 0$, $\text{Max Error} = 0$).
2. **Sparse Activation Skipping Benefits**:
   - ResNet-18 post-ReLU activations exhibited **68.89% exact-zero sparsity** (6,349 zeros out of 9,216 input activations).
   - Sparse zero-skipping reduced weight SRAM read transactions from **147,456 down to 45,872** (an exact **68.89% memory traffic reduction**).
   - MAC active compute switching cycles decreased by **68.89%** (from 9,216 down to 2,867 in 64-PE mode).
3. **Adaptive PE Allocation Trade-Off**:
   - Adaptive allocation operates as an **area/power throttle**, rather than a latency accelerator.
   - When degradation constraints permit ($\hat{D}_{mode} \le D_{max}$), the controller selects 32-PE mode, reducing active PE hardware by **50.0%**.
   - Because 32-PE mode requires 2 channel passes over the $C_{out} = 16$ workload, latency scales by $2.0\times$ (**19,121 cycles** vs. **9,569 cycles** in 64-PE).
   - Adaptive PE allocation does **not** improve latency over Fixed 64-PE, but enables thermal/power throttling or multi-tenant core sharing.

---

## 3. Directory Structure

| File / Directory | Description |
| :--- | :--- |
| `tsk29_adaptive_convolution_engine.sv` | Synthesizable hardware engine supporting 16/32/64-PE channel tiling, dense/sparse execution, and adaptive controller integration. |
| `tb_tsk29_adaptive_evaluation.sv` | Comprehensive verification testbench executing all 7 configurations with automated scoreboarding and assertion checking. |
| `CONFIGURATION_MATRIX.csv` | Machine-readable definition of all 7 evaluated configurations and channel-pass allocations. |
| `TSK29_RAW_METRICS.csv` | Raw hardware cycle counts, SRAM read counts, and telemetry counters captured during RTL simulation. |
| `TSK29_RESULTS.csv` | Complete consolidated performance metrics, latency ratios, and SRAM reduction percentages. |
| `NUMERICAL_CORRECTNESS.csv` | Full element-by-element numerical verification table for all 256 outputs across all 7 configurations (1,792 evaluated values). |
| `ADAPTIVE_DECISIONS.csv` | Detailed log of the Stage 8A adaptive PE controller mode selection, degradation thresholds, and fallback assertion status. |
| `EXPERIMENTAL_METHODOLOGY.md` | Full documentation of benchmarking protocols, test matrix, and metric calculation formulas. |
| `PERFORMANCE_ANALYSIS.md` | In-depth engineering analysis comparing cycle latency, throughput, memory bandwidth, and architectural trade-offs. |
| `LIMITATIONS.md` | Architectural boundaries, zero-skipping without cycle compaction, line buffering, and physical hardware disclaimers. |
| `FINAL_AUDIT_REPORT.md` | Engineering milestone audit report with Acceptance Criteria Scorecard and baseline integrity verification. |
| `generate_tsk29_results.py` | Python script to parse raw metrics and generate consolidated comparison tables. |
| `tensors/` | Quantized input activations, weights, and golden reference predictions from TSK-28. |

---

## 4. Reproduction Instructions

### 4.1 Prerequisites
- Icarus Verilog (`iverilog`) v12.0 or later
- Python 3.8+ (for metrics generation and verification)

### 4.2 Running the Simulation
Execute the complete multi-configuration simulation suite:

```bash
cd TSK29_ADAPTIVE_PE_EVALUATION
iverilog -g2012 -o sim_tsk29 \
    ../phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv \
    ../phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv \
    spatial_tile_sequencer.sv \
    tsk27c_spatial_accumulation_controller.sv \
    tsk29_adaptive_convolution_engine.sv \
    tb_tsk29_adaptive_evaluation.sv
vvp ./sim_tsk29
```

### 4.3 Generating Consolidated Analysis Tables
Run the post-processing script:
```bash
python3 generate_tsk29_results.py
```

### 4.4 Expected Simulation Output
```text
==================================================================
 TSK-29 COMPREHENSIVE VERIFICATION AUDIT SUMMARY
==================================================================
 Total Configurations Evaluated : 7
 Total Test Scenarios Checked   : 28
 Total Assertions Passed        : 28
 Total Assertions Failed        : 0
 Numerical Mismatches Across All: 0
 Overall Status                 : ALL 7 CONFIGURATIONS PASSED
==================================================================
```

