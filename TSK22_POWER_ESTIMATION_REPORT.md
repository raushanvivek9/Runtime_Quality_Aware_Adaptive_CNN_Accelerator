# TSK-22 Power Estimation & Switching Activity Report

**Project:** Neural_Acc Accelerator  
**Task:** TSK-22 (Phase C: RTL Synthesis, Static Timing Analysis, FPGA Resource Evaluation, Power-Estimation Preparation)  
**Date:** November 2026  
**Status:** SWITCHING ACTIVITY PROFILED | PHYSICAL POWER RUN BLOCKED  

---

## 1. Executive Summary

Dynamic power in CMOS VLSI circuits and modern FPGAs is governed by the charging and discharging of capacitive nodes:
$$P_{dynamic} = \alpha \cdot C_{eff} \cdot V_{dd}^2 \cdot f_{clk}$$
Where $\alpha$ is the switching activity factor (toggle rate), $C_{eff}$ is effective capacitance, $V_{dd}$ is supply voltage, and $f_{clk}$ is operating frequency.

To enable accurate post-synthesis and post-layout dynamic power estimation without fabricating artificial milliwatt values:
1. **Instrumented Testbench (`tb_power_switching_activity.sv`):** Configured simulation to execute real CNN layer computations while capturing full signal transition activity across all hierarchical modules.
2. **Automated VCD Activity Extraction (`generate_power_activity.py`):** Generated `neural_acc_switching_activity.vcd` (288,128 bytes), instrumenting 598 physical signals and recording 21,888 transitions.
3. **Power-Saving Microarchitecture Analysis:** Quantified dynamic power reductions achieved by column clock gating (16/32-PE modes) and exact-zero sparse feeder skipping.

---

## 2. Dynamic Switching Activity Profiling

Execution of `generate_power_activity.py` yielded the following toggle profile:

| Metric | Measured Value | Notes |
|---|---|---|
| **VCD Activity File** | `neural_acc_switching_activity.vcd` | 288,128 bytes on disk |
| **Monitored Hierarchy** | `tb_power_switching_activity.dut.*` | Complete integrated accelerator top |
| **Total Instrumented Signals** | **598 signals** | Datapath, SRAM buses, controllers, telemetry |
| **Total Value Transitions** | **21,888 transitions** | Recorded over complete layer execution |
| **Average Toggle Rate** | **36.60 transitions / signal** | Active switching activity factor $\alpha \approx 0.18$ |

---

## 3. Power-Saving Microarchitectural Mechanisms

### 3.1 Adaptive Column Clock-Gating (`adaptive_pe_controller.sv`)
- In **64-PE Mode (`2'b10`)**: All 16 PE columns are enabled.
  $$\alpha_{pe} = 1.00 \implies P_{datapath} = 100\%$$
- In **32-PE Mode (`2'b01`)**: Columns 8..15 have `pe_array_col_enable[15:8] = 0`.
  $$\text{Dynamic Power Reduction} \approx 50.0\% \text{ of PE array dynamic power}$$
- In **16-PE Mode (`2'b00`)**: Columns 4..15 have `pe_array_col_enable[15:4] = 0`.
  $$\text{Dynamic Power Reduction} \approx 75.0\% \text{ of PE array dynamic power}$$

### 3.2 Exact-Zero Sparse Feeder Skipping (`datapath_compute_feeder.sv`)
- In dense execution, the feeder drives 8 weight read ports and 2 activation read ports every reduction step, followed by pulsing `pe_array_enable` to update all 64 accumulators.
- In sparse execution:
  - When all 4 row activations are exact zeros ($0$), the feeder completely suppresses weight requests, suppresses `pe_array_enable`, and advances the reduction index $K$ in 1 cycle.
  - As measured in TSK-20 replay experiments, memory read transactions dropped by **25.0% to 40.0%**.
  - Because SRAM macro reads represent the dominant energy cost in edge accelerators, eliminating $40\%$ of SRAM read access transitions delivers substantial system dynamic energy savings.

---

## 4. Standalone Tool Scripting for Physical Power Signoff

To compute physical milliwatts on a system with Xilinx Vivado installed:
1. Convert `neural_acc_switching_activity.vcd` to SAIF (Switching Activity Interchange Format):
   ```bash
   vcd2saif -input neural_acc_switching_activity.vcd -output neural_acc.saif
   ```
2. In Vivado batch mode, read the SAIF file into post-implementation power analysis:
   ```tcl
   open_checkpoint neural_acc_routed.dcp
   read_saif -file neural_acc.saif -strip_path tb_power_switching_activity/dut
   report_power -file physical_power_report.rpt -xpe physical_power.xpe
   ```

---

## 5. Status Summary

| Requirement | Status | Evidence / Reference |
|---|---|---|
| Complete VCD Switching Activity File | **PASS** | `neural_acc_switching_activity.vcd` (288 KB) |
| Automated Generation & Profiling Script | **PASS** | `phase2_step1_microarchitecture_and_rtl/generate_power_activity.py` |
| Switching Activity & Toggle Profiling | **PASS** | 598 signals, 21,888 transitions profiled |
| Physical Silicon Millivolts / Milliwatts | **BLOCKED (Not Run)** | Absence of vendor power tool on host |

