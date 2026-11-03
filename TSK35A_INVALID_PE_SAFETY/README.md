# TSK-35A: Invalid PE Limit Safety Correction

## 1. Directory Overview

This directory (`TSK35A_INVALID_PE_SAFETY`) contains the architectural documentation, testbenches, simulation logs, and verification evidence for **TSK-35A**.

The objective of TSK-35A is to correct the invalid PE-limit handling identified during the TSK-34 independent audit. When $P_{\text{max}} < 16$ (e.g., $P_{\text{max}} = 0$ or $15$), the previous TSK-33 controller clamped the selection to 16 PEs while asserting fallback, permitting unauthorized compute execution. TSK-35A implements the smallest safe correction in the policy controller, adding an explicit `invalid_pe_limit` flag, an `execution_enable` gate, driving `resolved_pe_mode = 2'b11` (INVALID) and clearing `active_pe_count = 0`. Furthermore, RTL-level integration testing with `layer_command_sequencer.sv` proves that invalid configurations cannot start computation.

---

## 2. File Inventory

| File | Description |
| :--- | :--- |
| [TSK35A_ROOT_CAUSE_AND_ARCHITECTURE.md](file:///e:/MTech/LanChain/MTP/TSK35A_INVALID_PE_SAFETY/TSK35A_ROOT_CAUSE_AND_ARCHITECTURE.md) | In-depth root cause analysis, state/signal specifications, and two-ring safety architecture. |
| [TSK35A_VERIFICATION_REPORT.md](file:///e:/MTech/LanChain/MTP/TSK35A_INVALID_PE_SAFETY/TSK35A_VERIFICATION_REPORT.md) | Complete verification report covering unit testing, downstream gating integration, and regression sweeps. |
| [tb_tsk35a_invalid_pe_unit.sv](file:///e:/MTech/LanChain/MTP/TSK35A_INVALID_PE_SAFETY/tb_tsk35a_invalid_pe_unit.sv) | Directed SystemVerilog unit testbench validating 31 assertions on $P_{\text{max}} < 16$ and boundary behavior. |
| [TSK35A_UNIT_RESULTS.csv](file:///e:/MTech/LanChain/MTP/TSK35A_INVALID_PE_SAFETY/TSK35A_UNIT_RESULTS.csv) | CSV log recording all 31 directed assertion checks with stimulus parameters and observed signals. |
| [tb_tsk35a_downstream_gating.sv](file:///e:/MTech/LanChain/MTP/TSK35A_INVALID_PE_SAFETY/tb_tsk35a_downstream_gating.sv) | Integration testbench linking `tsk33_transparent_policy_controller.sv` with `layer_command_sequencer.sv`. |
| [TSK35A_DOWNSTREAM_GATING_RESULTS.csv](file:///e:/MTech/LanChain/MTP/TSK35A_INVALID_PE_SAFETY/TSK35A_DOWNSTREAM_GATING_RESULTS.csv) | CSV log recording the 4 downstream integration scenarios and verifying zero compute start pulses. |

---

## 3. Repositories and Components Modified

1. **Policy Controller:**
   - [`TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv`](file:///e:/MTech/LanChain/MTP/TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv)
   - Added ports: `output logic invalid_pe_limit`, `output logic execution_enable`.
   - Explicitly blocks compute and sets `resolved_pe_mode = 2'b11`, `active_pe_count = 0`, `channel_passes = 0` whenever $P_{\text{max}} < 16$.
2. **Policy Controller Regression Testbench:**
   - [`TSK33_ADAPTIVE_RESOURCE_POLICY/tb_tsk33_policy_validation.sv`](file:///e:/MTech/LanChain/MTP/TSK33_ADAPTIVE_RESOURCE_POLICY/tb_tsk33_policy_validation.sv)
   - Updated Test 15 expectations to reflect safe invalid mode (`2'b11`) and zero active PEs.
3. **Reference Software Policy Model:**
   - [`TSK34_INDEPENDENT_POLICY_VALIDATION/TSK34_REFERENCE_POLICY.py`](file:///e:/MTech/LanChain/MTP/TSK34_INDEPENDENT_POLICY_VALIDATION/TSK34_REFERENCE_POLICY.py)
   - Updated to output `mode_code = 3` (`2'b11`), `active_pes = 0`, `passes = 0`, `invalid_pe_limit = 1`, and `execution_enable = 0` when $P_{\text{max}} < 16$.

---

## 4. Protected Baseline Integrity

The 5 mandatory protected RTL baseline files were **not modified** (0 diffs, cryptographic SHA-256 match):
- `phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv`
- `phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv`
- `phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv`
- `phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv`
- `phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv`

---

## 5. Reproduction Instructions

### 5.1 Run Directed Unit Testbench (31 Assertions)
```bash
iverilog -g2012 -o TSK35A_INVALID_PE_SAFETY/sim_tsk35a_unit \
  TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv \
  TSK35A_INVALID_PE_SAFETY/tb_tsk35a_invalid_pe_unit.sv
vvp TSK35A_INVALID_PE_SAFETY/sim_tsk35a_unit
```

### 5.2 Run Downstream Integration Gating Testbench (4 Scenarios)
```bash
iverilog -g2012 -o TSK35A_INVALID_PE_SAFETY/sim_tsk35a_gating \
  TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv \
  phase2_step1_microarchitecture_and_rtl/layer_command_sequencer.sv \
  TSK35A_INVALID_PE_SAFETY/tb_tsk35a_downstream_gating.sv
vvp TSK35A_INVALID_PE_SAFETY/sim_tsk35a_gating
```

### 5.3 Run TSK-33 Regression Suite (17 Tests)
```bash
iverilog -g2012 -o TSK33_ADAPTIVE_RESOURCE_POLICY/sim_tsk33 \
  TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv \
  TSK33_ADAPTIVE_RESOURCE_POLICY/tb_tsk33_policy_validation.sv
vvp TSK33_ADAPTIVE_RESOURCE_POLICY/sim_tsk33
```

### 5.4 Run TSK-34 Independent 192-Point Sweep
```bash
python TSK34_INDEPENDENT_POLICY_VALIDATION/TSK34_REFERENCE_POLICY.py
```

### 5.5 Run Full Accelerator Regression Suite (20 Suites, 12,202 Checks)
```bash
cd phase2_step1_microarchitecture_and_rtl
python run_regression.py
cd ..
```

