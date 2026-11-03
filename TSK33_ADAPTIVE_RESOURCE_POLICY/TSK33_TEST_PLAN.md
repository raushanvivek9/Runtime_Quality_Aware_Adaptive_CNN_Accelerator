# TSK-33: Transparent Policy Controller Test Plan & Verification Strategy

## 1. Scope & Objective

The objective of this verification plan is to rigorously validate the functional correctness, boundary enforcement, defensive fallback behavior, and timing integrity of the redesigned hardware module `tsk33_transparent_policy_controller.sv`.

The test suite must verify that the controller:
1. Deterministically selects the optimal PE configuration under **Policy A (Minimum-Resource / Energy-Priority)** and **Policy B (Minimum-Latency / Throughput-Priority)**.
2. Accurately evaluates cycle boundaries at exact cycle thresholds (38,225; 19,121; 9,569; and 1-cycle decrements).
3. Strictly enforces active PE limits ($P_{\text{max}} = 16, 32, 64$).
4. Correctly triggers defensive fallback modes and status flags (`fallback_asserted`, `budget_violation`) when constraints cannot be satisfied or when invalid descriptors are presented.
5. Reliably initializes and recovers from asynchronous reset.

---

## 2. Verification Harness Architecture

The testbench is implemented in SystemVerilog as `tb_tsk33_policy_validation.sv`:
- **Clock Frequency:** 100 MHz (10 ns period, 5 ns half-cycle).
- **Stimulus Protocol:** Inputs (`cmd_valid`, `policy_select`, `latency_budget_cycles`, `max_active_pe_limit`) are driven synchronously on the **negative clock edge** (`@(negedge clk)`), providing a guaranteed 5 ns setup margin before the rising clock edge.
- **Handshake Protocol:** Command strobe `cmd_valid` is asserted for exactly one cycle and cleared on the subsequent half-cycle.
- **Sampling Protocol:** DUT registered outputs (`resolved_pe_mode`, `active_pe_count`, `channel_passes`, `fallback_asserted`, `budget_violation`) are sampled on the following negative clock edge when all internal flip-flop state transitions have completely settled.
- **Automated Logging:** Test execution logs every vector to standard console output and writes formatted CSV records to `TSK33_RTL_TEST_RESULTS.csv`.

```
                  100 MHz Clock
  clk:            __|---|___|---|___|---|___|---|___
  cmd_valid:      ____/---------\___________________
  Inputs Driven:      ^ (negedge)
  DUT Registered:           ^ (posedge)
  Outputs Sampled:                ^ (negedge check)
```

---

## 3. Test Vector Matrix & Coverage

The test suite consists of 17 comprehensive test vectors categorized into four functional groups:

| Test ID | Category | Policy | Latency Budget ($L_{\text{max}}$) | Active PE Cap ($P_{\text{max}}$) | Expected Mode | Expected PEs | Fallback Asserted | Budget Violation | Test Intent / Functional Check |
| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **01** | Policy A: Budget | 0 (A) | 50,000 cyc | 64 | `2'b00` | 16 | 0 | 0 | Relaxed budget: verify selection of smallest compute configuration |
| **02** | Policy A: Boundary | 0 (A) | 38,225 cyc | 64 | `2'b00` | 16 | 0 | 0 | Exact boundary equality for 16-PE mode ($T_{\text{total}} = 38,225$) |
| **03** | Policy A: Boundary | 0 (A) | 38,224 cyc | 64 | `2'b01` | 32 | 0 | 0 | Exactly 1 cycle below 16-PE: verify immediate transition to 32-PE |
| **04** | Policy A: Boundary | 0 (A) | 19,121 cyc | 64 | `2'b01` | 32 | 0 | 0 | Exact boundary equality for 32-PE mode ($T_{\text{total}} = 19,121$) |
| **05** | Policy A: Boundary | 0 (A) | 19,120 cyc | 64 | `2'b10` | 64 | 0 | 0 | Exactly 1 cycle below 32-PE: verify immediate transition to 64-PE |
| **06** | Policy A: Boundary | 0 (A) | 9,569 cyc | 64 | `2'b10` | 64 | 0 | 0 | Exact boundary equality for 64-PE mode ($T_{\text{total}} = 9,569$) |
| **07** | Policy A: Fallback | 0 (A) | 5,000 cyc | 64 | `2'b10` | 64 | 1 | 1 | Infeasible deadline: verify fallback to fastest mode with violation flags |
| **08** | Policy A: Resource | 0 (A) | 50,000 cyc | 32 | `2'b00` | 16 | 0 | 0 | Relaxed budget with 32-PE cap: verify 16-PE chosen (satisfies $16 \le 32$) |
| **09** | Policy A: Resource | 0 (A) | 20,000 cyc | 32 | `2'b01` | 32 | 0 | 0 | Moderate budget with 32-PE cap: verify 32-PE chosen ($19,121 \le 20,000$) |
| **10** | Policy A: Resource | 0 (A) | 10,000 cyc | 32 | `2'b01` | 32 | 1 | 1 | Tight budget with 32-PE cap: cannot run 64-PE; fallback to 32-PE with violation |
| **11** | Policy B: Throughput | 1 (B) | 50,000 cyc | 64 | `2'b10` | 64 | 0 | 0 | Unconstrained: verify maximum throughput mode (64-PE) selected |
| **12** | Policy B: Resource | 1 (B) | 50,000 cyc | 32 | `2'b01` | 32 | 0 | 0 | Clamped to 32 PEs: verify fastest permitted mode (32-PE) selected |
| **13** | Policy B: Resource | 1 (B) | 50,000 cyc | 16 | `2'b00` | 16 | 0 | 0 | Clamped to 16 PEs: verify fastest permitted mode (16-PE) selected |
| **14** | Policy B: Violation | 1 (B) | 5,000 cyc | 64 | `2'b10` | 64 | 0 | 1 | Impossible budget: verify 64-PE maintained while asserting budget violation |
| **15** | Defensive Boundary | 0 (A) | 50,000 cyc | 8 | `2'b00` | 16 | 1 | 1 | Invalid active PE limit ($<16$): verify safe clamp to 16-PE with violation |
| **16** | Defensive Boundary | 0 (A) | 0 cyc | 64 | `2'b10` | 64 | 1 | 1 | Zero cycle budget: verify fallback to fastest mode with violation |
| **17** | Asynchronous Reset | N/A | N/A | N/A | `2'b10` | 64 | 0 | 0 | Low pulse on `rst_n`: verify clean asynchronous reset to default 64-PE state |

---

## 4. Pass/Fail Criteria & Test Outcome

- **Pass Criterion:** Each assertion must strictly match all five output signals:
  - `resolved_pe_mode === exp_mode`
  - `active_pe_count === exp_pes`
  - `fallback_asserted === exp_fallback`
  - `budget_violation === exp_violation`
  - Handshake readiness `cmd_ready === 1'b1`
- **Execution Command:**
  ```bash
  iverilog -g2012 -o sim_tsk33 tb_tsk33_policy_validation.sv tsk33_transparent_policy_controller.sv
  vvp ./sim_tsk33
  ```
- **Verification Result:**
  - Total Tests Evaluated: **17**
  - Passed Assertions: **17**
  - Failed Assertions: **0**
  - Verification Status: **100% PASS (Zero Defects)**

