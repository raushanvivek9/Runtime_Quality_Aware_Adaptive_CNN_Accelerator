# TSK-35B: Adaptive Resource Allocation Policy Benefit Evaluation

## 1. Directory Overview

This directory (`TSK35B_POLICY_BENEFIT_EVALUATION`) contains the empirical evaluation suite, cycle-accurate simulation logs, and analysis artifacts for **TSK-35B**.

The objective of TSK-35B is to rigorously evaluate whether the transparent resource-allocation policies (Policy A: Min-Resource, Policy B: Min-Latency) developed in TSK-33 and corrected in TSK-35A provide measurable operational advantages over fixed 16-, 32-, and 64-PE hardware baselines across real CNN workloads.

---

## 2. File Inventory

| File | Description |
| :--- | :--- |
| [TSK35B_INSPECTION_AND_METHODOLOGY.md](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_INSPECTION_AND_METHODOLOGY.md) | Phase 1 & 2 audit report: workload provenance, tensor dimensions, and fair comparison protocols. |
| [TSK35B_POLICY_BENEFIT_REPORT.md](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_POLICY_BENEFIT_REPORT.md) | In-depth engineering evaluation report comprehensively answering the 7 core research questions. |
| [tb_tsk35b_policy_benefit.sv](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/tb_tsk35b_policy_benefit.sv) | Synthesizable SystemVerilog testbench integrating the policy controller, convolution engine, and SRAM. |
| [process_tsk35b_results.py](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/process_tsk35b_results.py) | Python data analysis script processing raw simulation CSVs into comparative summaries. |
| [TSK35B_ALL_SCENARIOS_MEASURED.csv](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_ALL_SCENARIOS_MEASURED.csv) | Full empirical database of 560 dynamic policy evaluations ($4\text{ workloads} \times 140\text{ scenarios}$). |
| [TSK35B_BASELINE_MEASURED.csv](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_BASELINE_MEASURED.csv) | Hardware cycle and telemetry measurements for the 24 fixed baselines across Dense and Sparse regimes. |
| [TSK35B_POLICY_BENEFIT_SUMMARY.csv](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_POLICY_BENEFIT_SUMMARY.csv) | Paired comparative analysis between Policy A and Policy B across all parameter combinations. |
| [TSK35B_SPARSITY_VS_DENSE.csv](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_SPARSITY_VS_DENSE.csv) | Disaggregated breakdown showing cycle count, compute activity, and memory reads for Dense vs Sparse. |
| [TSK35B_SRAM_TRAFFIC_ANALYSIS.csv](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_SRAM_TRAFFIC_ANALYSIS.csv) | Detailed breakdown of multi-pass activation re-read overhead in 16-PE and 32-PE modes. |
| [TSK35B_POLICY_DECISION_DISTRIBUTION.csv](file:///e:/MTech/LanChain/MTP/TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_POLICY_DECISION_DISTRIBUTION.csv) | Frequency and percentage distribution of mode selections across evaluated policies. |

---

## 3. Reproduction Instructions

### 3.1 Compile and Run the Cycle-Accurate RTL Simulation
```bash
cd TSK35B_POLICY_BENEFIT_EVALUATION
iverilog -g2012 -o sim_tsk35b \
    ../phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv \
    ../phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv \
    ../TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/spatial_tile_sequencer.sv \
    ../TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tsk27c_spatial_accumulation_controller.sv \
    ../TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tsk30_multi_workload_engine.sv \
    ../TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv \
    tb_tsk35b_policy_benefit.sv
vvp ./sim_tsk35b
```

### 3.2 Run Statistical Analysis & Table Generation
```bash
python3 process_tsk35b_results.py
```

---

## 4. Protected Baseline Integrity

As strictly required, the five baseline RTL files were preserved without modification (0 diffs, cryptographic hash match):
- `phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv`
- `phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv`
- `phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv`
- `phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv`
- `phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv`

