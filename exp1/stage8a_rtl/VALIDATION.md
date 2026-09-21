# Stage 8A Validation

Date: 2026-09-20

## Tool availability and execution

| Item | Status | Result |
| --- | --- | --- |
| Icarus Verilog | PASS | `iverilog` 13.0 installed and run from the existing `neural_acc` Conda environment. |
| Verilator lint | NOT RUN | `verilator` is not installed in the environment. |
| Icarus compilation | PASS | `iverilog -g2012 -Wall -o stage8a_sim runtime_monitor.sv feature_calculator.sv quality_estimator.sv resource_controller.sv runtime_controller_top.sv tb_runtime_controller.sv` completed with exit code 0. |
| Icarus simulation | PASS | `vvp stage8a_sim` completed all self-checks and called `$finish`. |
| Python reference | PASS | `conda run -n neural_acc python reference_model.py` matched every RTL testbench expectation. |

Icarus emitted non-fatal `always_*` constant-select compatibility notices during compilation. They do not indicate a test failure; the simulator reports sensitivity to all bits of the affected signals. There were no compile errors.

Simulator artifacts retained in this directory:

- `stage8a_sim`
- `stage8a_compile.log`
- `stage8a_sim.log`

## Self-checking simulation tests

| Test | Status | Checked result |
| --- | --- | --- |
| 1: all nonzero `[1,2,3,4]` | PASS | `N=4`, `zero=0`, `sum=10`, `sum_square=30`, sparsity `0`. |
| 2: all zero | PASS | `N=4`, `zero=4`, sparsity `65536` (1.0 Q16.16). |
| 3: signed `[0,2,0,-2]` | PASS | `N=4`, `zero=2`, `sum=0`, `sum_square=8`, sparsity `32768`, variance `131072`. |
| 4: alternating `[1,-1,1,-1]` | PASS | variance `65536` (1.0 Q16.16). |
| 5: negative `[-4,-3,-2,-1]` | PASS | `sum=-10`, `sum_square=30`, mean `-163840`, variance `81920`. |
| 6: large `[1000,-1000,1000,-1000]` | PASS | `sum=0`, `sum_square=4000000`, saturated variance `0xffffffff`. |
| 7: consecutive conv1/conv2/conv3 | PASS | Tests 1-3 use IDs 0/1/2 consecutively; no statistics or IDs leaked between layers. |
| 8: zero-length layer | PASS | Defined all-zero statistics/features, valid decision, and no X/Z value passed the case-equality assertions. |
| 9: low controller input | PASS | Prototype `D16=0`, `D32=0`; adaptive selection is 16 PE. |
| 10: medium controller input | PASS | `D16=4000`, `D32=2000`; adaptive selection is 32 PE. |
| 11: high controller input | PASS | `D16=8000`, `D32=4000`; adaptive selection is 64 PE with fallback asserted. |
| 12: `USE_FIXED64=1` | PASS | Fixed-mode instance selects 64 PE for a low-degradation vector while adaptive instance selects 16 PE. |

## Fixed-point numerical checks

`reference_model.py` uses normal Python arithmetic, then applies the RTL's Q16.16 integer truncation, non-negative variance clamp, and output saturation. It agrees with every stream-vector assertion and all four estimator/controller vectors.

The only deliberate loss of exact value is the test-6 output feature: exact variance is `1,000,000` or Q16.16 `65,536,000,000`, which is not representable in a 32-bit unsigned Q16.16 output. The RTL and reference both saturate it to `4,294,967,295` (`0xffffffff`) rather than wrap.

## Latency

Status: PASS.

The testbench measured two rising clock cycles from the edge that samples `layer_end` (and raises `stats_valid`) to the registered `decision_valid` edge. `features_valid` is combinational with `stats_valid`; `estimate_valid` follows one clock later; `decision_valid` follows two clocks later.

## Static checks

Status: PASS (Icarus compilation plus manual source inspection).

- Required RTL, testbench, Python reference, README, and validation files exist.
- Compilation resolved all module instantiations and signal references; no missing module or undeclared-signal error was reported.
- No `real`, `shortreal`, floating-point RTL, or full activation-tensor storage appears in the synthesizable modules.
- The monitor uses signed activation/sum arithmetic and an explicit wide square operand.
- Fixed-point shifts and products use explicitly widened intermediates; division by zero is guarded; variance is clamped and saturated.
- Resource encodings are limited to 16/32/64 PE, and the 64-PE fallback does not compare the placeholder `D64=0` value.
- The testbench contains deterministic `$fatal` assertions.

## Scope retained

No synthesis, timing, area, power, energy, FPGA, ASIC, hardware-accuracy, or dynamic-reconfiguration claim is made. The linear estimator coefficients are prototype placeholders and are not a trained/calibrated Stage 3 Random Forest replacement. No prior Stage 1-7 result or validated SCALE-Sim checkout was modified.
