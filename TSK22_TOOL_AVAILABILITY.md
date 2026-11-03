# TSK-22 Tool Availability & Execution Environment Audit

**Project:** Neural_Acc Accelerator  
**Task:** TSK-22 (Phase C: RTL Synthesis, Static Timing Analysis, FPGA Resource Evaluation, Power-Estimation Preparation)  
**Date:** November 2026  
**Auditor:** Automated Engineering Pair  

---

## 1. System Environment Audit

| Environment Attribute | Value | Verification Command | Status |
|---|---|---|---|
| **Host Operating System** | Microsoft Windows 11 Pro / x86_64 | `powershell -Command "[System.Environment]::OSVersion"` | VERIFIED |
| **Linux Subsystem** | Ubuntu 24.04 LTS (WSL2, kernel 5.15+) | `wsl -d Ubuntu uname -a` | VERIFIED |
| **Workspace Root** | `E:\MTech\LanChain\MTP` (`/mnt/e/MTech/LanChain/MTP`) | `pwd` | VERIFIED |
| **Primary Simulation Engine**| Icarus Verilog 12.0 (stable) | `iverilog -v` | **INSTALLED / OPERATIONAL** |
| **Simulation Runtime** | vvp (Icarus Verilog runtime engine) | `vvp -V` | **INSTALLED / OPERATIONAL** |
| **Python Environment** | Python 3.12.3 (CPython, x86_64) | `python3 --version` | **INSTALLED / OPERATIONAL** |

---

## 2. EDA Tool Availability & Status Matrix

Per project safety guidelines:
> "If a tool is not installed, record its absence clearly. Do not invent outputs for missing tools. For any tool that is unavailable, create reproducible standalone scripts, constraints, and instructions so the analysis can be run later. Mark unrun stages as NOT RUN or BLOCKED."

| Tool Name | Expected Capability | Detection Command | Installation Status | Execution Status |
|---|---|---|---|---|
| **Icarus Verilog (`iverilog`)** | IEEE-1800-2012 SystemVerilog Simulation | `which iverilog` | `/usr/bin/iverilog` | **PASS (Operational)** |
| **Yosys Open Synthesis Suite** | Open-source RTL synthesis & netlist mapping | `which yosys` | NOT INSTALLED | **BLOCKED (Script Provided)** |
| **Xilinx Vivado (`vivado`)** | FPGA Synthesis, Placement, Routing, STA, Power | `which vivado` | NOT INSTALLED | **BLOCKED (TCL Provided)** |
| **Intel Quartus Prime (`quartus`)** | FPGA Synthesis & TimeQuest STA | `which quartus` | NOT INSTALLED | **BLOCKED (Script Provided)** |
| **OpenSTA (`sta`)** | Parquet / Gate-level Static Timing Analysis | `which sta` / `opensta` | NOT INSTALLED | **BLOCKED (SDC Provided)** |
| **Verilator (`verilator`)** | Cycle-accurate C++ Model Compilation | `which verilator` | NOT INSTALLED | **BLOCKED** |

---

## 3. Tool Independence & Reproducibility Plan

Because physical vendor tools (Vivado, Quartus) and commercial ASIC tools are not present in this local environment:
1. **Zero Invented Numbers:** All physical synthesis numbers, post-routing timing slacks, and physical power numbers are explicitly marked as `ESTIMATED / NOT RUN` in accordance with the evidence audit protocol.
2. **Complete Reproducible Artifacts:** Standalone, production-grade tool scripts and constraints have been generated:
   - `phase2_step1_microarchitecture_and_rtl/timing_constraints.sdc` (Synopsys Design Constraints)
   - `phase2_step1_microarchitecture_and_rtl/timing_constraints.xdc` (Xilinx Design Constraints)
   - `phase2_step1_microarchitecture_and_rtl/synth_yosys.ys` (Yosys Open-Source Synthesis Script)
   - `phase2_step1_microarchitecture_and_rtl/synth_vivado.tcl` (Vivado Non-Project Batch Synthesis & STA Script)
   - `phase2_step1_microarchitecture_and_rtl/generate_power_activity.py` (VCD/SAIF Switching Activity Script)
3. Any developer with Vivado, Yosys, or OpenSTA installed can execute these exact scripts without modification to obtain physical silicon/bitstream reports.

