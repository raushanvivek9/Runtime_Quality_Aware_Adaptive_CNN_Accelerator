# TSK-31: Independent Reproducibility and Adaptive-Policy Audit Directory

This directory contains the independent audit harness, regenerated stimulus, reproduction testbenches, and verified audit reports for milestone **TSK-31** of the **Neural_Acc** accelerator project.

---

## 1. Directory Structure

```text
TSK31_INDEPENDENT_REPRODUCIBILITY_AUDIT/
├── README.md                              <- This documentation file
├── FINAL_AUDIT_REPORT.md                  <- Comprehensive final audit report
├── REGRESSION_RESULTS.md                  <- Detailed 20-suite regression breakdown
├── EVIDENCE_GAPS.md                       <- Transparent documentation of limits & gaps
│
├── audit_workloads_and_reproduce.py       <- PyTorch tensor extraction & hash verification
├── audit_and_recalculate_metrics.py       <- Metric recalculation, reconciliation & classification
│
├── tb_tsk31_reproduction.sv               <- Independent Verilog testbench (28 configurations)
├── sim_tsk31                              <- Compiled simulation binary
│
├── tsk30_multi_workload_engine.sv         <- Integration RTL wrapper (unprotected)
├── tsk27c_spatial_accumulation_controller.sv
├── spatial_tile_sequencer.sv
│
├── tensors/                               <- Independently regenerated tensor hex files
│   ├── wl1_act.hex, wl1_wt.hex, wl1_golden.hex
│   ├── wl2_act.hex, wl2_wt.hex, wl2_golden.hex
│   ├── wl3_act.hex, wl3_wt.hex, wl3_golden.hex
│   └── wl4_act.hex, wl4_wt.hex, wl4_golden.hex
│
└── Audit Verification Artifacts (CSV):
    ├── REPRODUCIBILITY_RESULTS.csv        <- 28/28 configuration verification matrix
    ├── SPARSITY_RECONCILIATION.csv        <- Exact zero count vs. weight read reduction
    ├── ADAPTIVE_ESTIMATE_AUDIT.csv        <- Q16.16 degradation calculations & decisions
    ├── NUMERICAL_RECHECK.csv              <- 7,168 output elements vs. golden references
    ├── REPRODUCED_ADAPTIVE_DECISIONS.csv  <- Controller FSM telemetry & fallback validation
    ├── REPRODUCED_RAW_METRICS.csv         <- Raw hardware cycles, reads, and assertions
    └── PERFORMANCE_RECALCULATION.csv      <- Recalculated speedup, throughput & read ratios
```

---

## 2. Reproduction Instructions

To reproduce all results independently from scratch:

### Step 1: Regenerate Stimulus and Golden References
```bash
cd /mnt/e/MTech/LanChain/MTP/TSK31_INDEPENDENT_REPRODUCIBILITY_AUDIT
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python audit_workloads_and_reproduce.py
```
This regenerates all 12 tensor hex files into `tensors/`, checks their SHA-256 hashes against TSK-30, and creates `SPARSITY_RECONCILIATION.csv` and `ADAPTIVE_ESTIMATE_AUDIT.csv`.

### Step 2: Compile and Run Verilog Simulation
```bash
iverilog -g2012 -o sim_tsk31 \
  tb_tsk31_reproduction.sv \
  tsk30_multi_workload_engine.sv \
  tsk27c_spatial_accumulation_controller.sv \
  spatial_tile_sequencer.sv \
  ../phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv \
  ../phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv \
  ../phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv \
  ../phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv \
  ../phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv

vvp ./sim_tsk31
```
This executes all 28 test configurations, logs all hardware telemetry to `REPRODUCED_RAW_METRICS.csv`, dumps all 7,168 output elements to `NUMERICAL_RECHECK.csv`, and records adaptive decisions in `REPRODUCED_ADAPTIVE_DECISIONS.csv`.

### Step 3: Recalculate Metrics and Audit Classification
```bash
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python audit_and_recalculate_metrics.py
```
This verifies 100% bit-exact replication, reconciles sparsity, recalculates performance ratios, and outputs `REPRODUCIBILITY_RESULTS.csv` and `PERFORMANCE_RECALCULATION.csv`.

### Step 4: Run Baseline Regressions
```bash
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python ../phase2_step1_microarchitecture_and_rtl/run_regression.py
```
Confirms that all 20 test suites pass 100% (12,202 / 12,202 checks).

---

## 3. Key Audit Findings

1. **Bit-Exact Reproducibility**: 28 of 28 configurations passed with 0 mismatches across 7,168 output elements.
2. **Sparsity Telemetry**: Weight SRAM read reductions (48.11% to 84.92%) match activation zero rates with 0.00% discrepancy.
3. **Adaptive Controller Policy**: Correctly verified as "Externally Guided Adaptive Allocation" using Q16.16 degradation metrics.
4. **Latency vs. Area Trade-off**: Reduced-PE modes function as an area/power throttle, doubling or quadrupling latency.
5. **Protected Files**: 0 diffs across all 5 protected baseline RTL files.

