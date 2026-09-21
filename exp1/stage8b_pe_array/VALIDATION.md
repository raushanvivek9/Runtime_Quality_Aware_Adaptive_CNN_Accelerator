# Stage 8B Validation

Date: 2026-09-20

## Execution status

| Check | Status | Result |
| --- | --- | --- |
| Python reference | PASS | `conda run -n neural_acc python reference_model.py` produced the deterministic integer 8x8 golden matrix. |
| Icarus availability | PASS | Icarus Verilog 13.0 and `vvp` are available in the `neural_acc` Conda environment. |
| Compilation | PASS | All five SV files compiled with `iverilog -g2012 -Wall`; no compiler warnings or errors were emitted. |
| RTL simulation | PASS | `vvp stage8b_sim` completed every `$fatal`-guarded check and called `$finish`. |
| Waveform | PASS | `stage8b_wave.vcd` was generated from the self-checking testbench. |

Compile command:

```sh
conda run -n neural_acc iverilog -g2012 -Wall -o stage8b_sim \
  pe_mac.sv pe_array.sv adaptive_pe_controller.sv \
  adaptive_compute_top.sv tb_adaptive_compute.sv
```

## Self-checking RTL tests

| Test | Status | Evidence |
| --- | --- | --- |
| 1: 16-PE GEMM | PASS | All 64 results match the independent testbench golden matrix; `active_pe_count=16`; `cycle_count=32`. |
| 2: 32-PE GEMM | PASS | All 64 results match; `active_pe_count=32`; `cycle_count=16`. |
| 3: 64-PE GEMM | PASS | All 64 results match; `active_pe_count=64`; `cycle_count=8`. |
| 4: active-count and enable mask | PASS | For each configuration, every PE below the active count is enabled and every remaining PE is disabled. |
| 5: disabled-PE gating | PASS | After reset, inactive PE accumulators remain zero; active PE accumulators change. `pe_valid_debug` is zero for every disabled PE during computation. |
| 6: boundary reconfiguration | PASS | Three workloads run without reset in 16 → 32 → 64 configuration order; each captures its new setting and produces the golden result. |
| 7: mid-computation stability | PASS | The input `resource_cfg` changes while `busy`; captured config, active count, and enable mask remain unchanged through completion. |
| 8: reset | PASS | Busy, done, result-valid, cycle count, result matrix, and all PE accumulators reset to zero. |
| 9: Python agreement | PASS | Python and testbench use the same documented deterministic workload; Python golden `C[0][0]=156` and `C[7][7]=1108` match the RTL-checked matrix. |
| 10: cycle counter | PASS | The testbench asserts exactly 32, 16, and 8 scheduler MAC cycles for 16, 32, and 64 active PEs respectively. |

## Measured cycle counts

| `resource_cfg` | Active PEs | `cycle_count` | Result correctness |
| --- | ---: | ---: | --- |
| `2'b00` | 16 | 32 | PASS |
| `2'b01` | 32 | 16 | PASS |
| `2'b10` | 64 | 8 | PASS |

`cycle_count` measures scheduler MAC cycles after the top-level configuration capture. It is not a physical timing, latency, throughput, or energy measurement.

## Static checks

Status: PASS.

- One `generate` loop instantiates exactly 64 `pe_mac` modules in `pe_array.sv`.
- The synthesizable modules contain no `real`, `shortreal`, floating-point, or tensor-result storage for the workload beyond fixed 8x8 matrices and PE state.
- MAC data, weight, multiplication, and accumulator signals are explicitly signed. The MAC uses a widened product intermediate.
- Disabled PEs have `enable=0`, see no `valid` work, and do not update their `acc_out` register.
- Compilation resolves every module/interface and reports no missing or undeclared signal.
- The testbench uses deterministic `$fatal` assertions for all required behavior.

## Retained artifacts

- `stage8b_sim`
- `stage8b_compile.log`
- `stage8b_sim.log`
- `reference_model.log`
- `stage8b_wave.vcd`

## Scope retained

This validates an RTL mechanism for logical PE gating and a deterministic GEMM computation. It does not establish energy savings, area, timing closure, FPGA/ASIC feasibility, a full Eyeriss architecture, a SCALE-Sim RTL equivalence, a neural-network accuracy change, or a lower-resource research result. Stage 8A and all Stage 1–7 artifacts remain untouched.
