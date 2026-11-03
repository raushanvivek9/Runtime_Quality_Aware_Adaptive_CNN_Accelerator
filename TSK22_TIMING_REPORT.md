# TSK-22 Static Timing Analysis (STA) & Critical Path Report

**Project:** Neural_Acc Accelerator  
**Task:** TSK-22 (Phase C: RTL Synthesis, Static Timing Analysis, FPGA Resource Evaluation, Power-Estimation Preparation)  
**Date:** November 2026  
**Status:** CONSTRAINTS COMPLETE | PHYSICAL STA BLOCKED (Host Toolchain Limitation)  

---

## 1. Timing Specification & Clock Constraints

The Neural_Acc accelerator is designed for embedded edge CNN inference at a target operating frequency of **100.0 MHz** ($T_{clk} = 10.000\text{ ns}$).

### 1.1 Complete Constraint Definition (`timing_constraints.sdc` / `timing_constraints.xdc`)
- **Primary Clock:** `clk`, period = $10.000\text{ ns}$ (50% duty cycle).
- **Clock Uncertainty:**
  - Setup Uncertainty: $0.200\text{ ns}$ (accounting for PLL jitter and clock network skew).
  - Hold Uncertainty: $0.100\text{ ns}$.
- **Input Delay Budget:** $T_{in\_max} = 2.000\text{ ns}$ ($20\%$ of cycle time) on all external command, AXI, and configuration ports.
- **Output Delay Budget:** $T_{out\_max} = 2.000\text{ ns}$ ($20\%$ of cycle time) on all telemetry, status, and memory outputs.
- **Internal Core Budget:** $T_{core\_avail} = 10.000 - (0.200 + 2.000) = \mathbf{7.800\text{ ns}}$ available for internal combinatorial paths.

---

## 2. Microarchitectural Critical Path Analysis

Four key timing-critical paths exist in the microarchitecture:

### 2.1 Critical Path 1: MAC Datapath & Saturation Unit (`mac_unit_40b.sv`)
- **Startpoint:** Weight register / Activation staging register (`weight_stage_q`, `act_stage_q`).
- **Path Components:**
  1. $16\text{-bit} \times 16\text{-bit}$ Signed Multiplier ($1.8\text{ ns}$ in DSP48E1 / $3.2\text{ ns}$ in soft logic).
  2. 40-bit Signed Adder ($0.8\text{ ns}$ in DSP48E1 carry chain / $1.2\text{ ns}$ soft).
  3. 40-bit Upper-bit Saturation Detection ($0.6\text{ ns}$).
  4. Accumulator Input Multiplexer ($0.4\text{ ns}$).
- **Endpoint:** Accumulator Register (`accum_q[39:0]`).
- **Estimated Total Delay:** $\sim 3.60\text{ ns}$ (DSP48E1 mapping) / $\sim 5.40\text{ ns}$ (soft logic).
- **Estimated Setup Slack at 100 MHz:** $+4.20\text{ ns}$ (DSP48E1) / $+2.40\text{ ns}$ (soft logic). **MEETS TIMING ($F_{max} \approx 185\text{ MHz}$)**.

### 2.2 Critical Path 2: Sparse Feeder Zero-Detection & Address Generation (`datapath_compute_feeder.sv`)
- **Startpoint:** Multi-Bank SRAM Port B Read Data Registers (`bank_dout_b`).
- **Path Components:**
  1. Continuous slice to 4 row activations: `act_wire[0..3]` ($0.2\text{ ns}$).
  2. 4-way 16-bit zero comparator: `all_acts_zero = act_zero_0 && ... && act_zero_3` ($1.2\text{ ns}$).
  3. Feeder FSM Next-State Evaluation: `ST_SPARSE_WAIT_A` transition ($1.0\text{ ns}$).
  4. Base address adder: `active_base + (req_cnt_q * 10)` ($1.1\text{ ns}$).
- **Endpoint:** SRAM Read Address Bus Register (`sram_rd_addr_bus`).
- **Estimated Total Delay:** $\sim 3.50\text{ ns}$.
- **Estimated Setup Slack at 100 MHz:** $+4.30\text{ ns}$. **MEETS TIMING ($F_{max} \approx 200\text{ MHz}$)**.

### 2.3 Critical Path 3: Multi-Bank SRAM Conflict Crossbar (`multibank_sram_subsystem.sv`)
- **Startpoint:** Read Port Request Registers (`rd_req[0..7]`, `rd_addr[0..7]`).
- **Path Components:**
  1. Address bit decode: `bank_sel = rd_addr[2:0]` ($0.3\text{ ns}$).
  2. 8-port priority arbitration logic: `granted_rd_port[b]` ($1.6\text{ ns}$).
  3. Bank read enable generation: `bank_re_b[b]` ($0.5\text{ ns}$).
- **Endpoint:** Physical SRAM macro address / enable pin (`bank_addr_b`, `bank_re_b`).
- **Estimated Total Delay:** $\sim 2.40\text{ ns}$.
- **Estimated Setup Slack at 100 MHz:** $+5.40\text{ ns}$. **MEETS TIMING ($F_{max} \approx 250\text{ MHz}$)**.

### 2.4 Critical Path 4: Requantization Unit Scaling & Saturation (`requantization_unit.sv`)
- **Startpoint:** Accumulator Input Valid / Data (`in_accum[39:0]`).
- **Path Components:**
  1. 41-bit round offset addition ($0.9\text{ ns}$).
  2. 31-bit arithmetic barrel right-shifter ($1.4\text{ ns}$).
  3. Dual-bound comparison against $[-32768, +32767]$ ($0.8\text{ ns}$).
  4. Saturation and optional ReLU multiplexer ($0.5\text{ ns}$).
- **Endpoint:** Staging register (`pack_lo_q`) or output word buffer (`out_word_q`).
- **Estimated Total Delay:** $\sim 3.60\text{ ns}$.
- **Estimated Setup Slack at 100 MHz:** $+4.20\text{ ns}$. **MEETS TIMING ($F_{max} \approx 190\text{ MHz}$)**.

---

## 3. False Paths & Timing Exceptions

1. **Asynchronous Reset (`rst_n`):**
   - Asserted asynchronously by external reset controller, deasserted synchronously.
   - Configured as `set_false_path -from [get_ports rst_n]` to prevent reset tree setup violations while allowing standard reset-recovery checks.
2. **Static Mode Configurations:**
   - Static flags such as `cfg_parallel_en`, `cfg_sparse_feeder_en`, `cfg_ofmap_drain_en`, and `cfg_ofmap_base_addr` are statically driven before layer initiation.
   - Constrained as false paths through XDC to avoid artificial path pessimism.

---

## 4. Static Timing Analysis Status

| Requirement | Status | Reference File |
|---|---|---|
| SDC Constraints Generated | **PASS** | `phase2_step1_microarchitecture_and_rtl/timing_constraints.sdc` |
| XDC Constraints Generated | **PASS** | `phase2_step1_microarchitecture_and_rtl/timing_constraints.xdc` |
| Analytical Slack Evaluation | **PASS (Estimated +4.2 ns slack at 100 MHz)** | Section 2 above |
| Post-Implementation Signoff STA | **BLOCKED** | Absence of Vivado / OpenSTA binary on host |

