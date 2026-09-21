# Stage 8A Runtime Monitoring and Resource-Selection RTL Prototype

Stage 8A is a streaming runtime-quality-monitoring and resource-selection prototype. It is isolated from the validated SCALE-Sim, Accelergy, and earlier experiment artifacts. It does not change a neural-network computation, and it is not yet a complete accuracy-adaptive accelerator.

## Architecture

`activation stream -> runtime_monitor -> feature_calculator -> quality_estimator -> resource_controller`

| Module | Purpose |
| --- | --- |
| `runtime_monitor.sv` | Streaming per-layer `element_count`, `zero_count`, signed `sum`, and `sum_square`; it never stores an activation tensor. |
| `feature_calculator.sv` | Calculates Q16.16 sparsity, signed mean, and non-negative variance from the completed statistics. |
| `quality_estimator.sv` | Registers lightweight prototype degradation estimates for 16 and 32 PE. 64 PE is the fixed baseline convention. |
| `resource_controller.sv` | Selects 16, then 32, then conservatively falls back to 64 PE; supports `USE_FIXED64`. |
| `runtime_controller_top.sv` | Connects the pipeline and propagates the captured 2-bit layer ID to the decision. |

### Default widths and fixed point

- Activation data: signed 16 bits by default (`DATA_W`; the testbench uses 16 bits).
- Counts: 32 bits; signed sum: 48 bits; unsigned sum of squares: 64 bits.
- Features and degradation values: 32-bit Q16.16 (`FRAC_W=16`). `sparsity` and `variance` are unsigned; `mean` is signed.
- Arithmetic intermediates are explicitly widened before shifts, divisions, and multiplications. In particular, activation squares use a `2*DATA_W` signed intermediate, and mean-square uses a `2*(SUM_W+FRAC_W)` intermediate.
- For an empty layer, all features are defined as zero. Negative fixed-point variance caused by truncation is clamped to zero. Values beyond unsigned 32-bit Q16.16 are saturated, not wrapped.

The large-value validation vector has variance `1,000,000`, whose exact Q16.16 representation is `65,536,000,000`; this exceeds 32-bit unsigned Q16.16 and is intentionally reported as `32'hffff_ffff`.

## Handshake and layer ID

The preferred deterministic input protocol is:

1. Assert `layer_start=1` with `sample_valid=0`.
2. Present each activation with `sample_valid=1`.
3. Present the final activation with `sample_valid=1` and `layer_end=0`.
4. Assert `layer_end=1` on the following cycle.

`layer_end` is therefore normally asserted after the final sample has been accumulated. The monitor also correctly supports a final `sample_valid` coincident with `layer_end`; their register updates become visible together. `layer_start` captures `layer_id` (`2'd0=conv1`, `2'd1=conv2`, `2'd2=conv3`) and the ID is carried to `decision_layer_id` for future layer-specific coefficients.

For the registered pipeline, a sampled `layer_end` raises `stats_valid` and combinational `features_valid` on that edge. `estimate_valid` follows one rising clock edge later, and `decision_valid` follows two rising edges later. The measured testbench latency is two clocks from sampled `layer_end` to `decision_valid`.

## Resource policy

Resource encodings are fixed:

- `2'b00`: 16 PE / 4x4
- `2'b01`: 32 PE / 4x8
- `2'b10`: 64 PE / 8x8

With `USE_FIXED64=0`, the controller selects 16 PE if `D16 <= D_MAX`, otherwise 32 PE if `D32 <= D_MAX`, otherwise 64 PE and asserts `fallback_to_64`. The default threshold is `D_MAX=3277`, the truncated Q16.16 encoding of 0.05. `USE_FIXED64=1` always selects 64 PE and is not marked as an adaptive fallback. The selected resource configuration changes only when a new estimate is registered, after layer statistics are complete.

## Estimator scope

The estimator is intentionally a lightweight linear prototype:

`D = W_s*sparsity + W_m*abs(mean) + W_v*variance + B`

It uses transparent Q16.16 placeholder coefficients: `(W_s, W_m, W_v)=(1200,300,800)` for 16 PE and `(600,150,400)` for 32 PE, with zero bias. The 64-PE degradation output is zero only because 64 PE is treated as the baseline configuration in this Stage 8A prototype. These values are not learned, calibrated, or a reproduction of the Stage 3 Random Forest.

## Validation assets

`tb_runtime_controller.sv` is self-checking and uses `$fatal` for activation-statistics, Q16.16 feature, layer-isolation, controller-policy, fixed-64, and latency failures. `reference_model.py` derives the expected values with Python integer/float arithmetic and asserts that they agree with every testbench expectation. See `VALIDATION.md` for the recorded simulator run and `stage8a_revision_report.txt` for the revision summary.

To reproduce the verified run with the existing Conda environment:

```sh
conda run -n neural_acc python reference_model.py
conda run -n neural_acc iverilog -g2012 -Wall -o stage8a_sim \
  runtime_monitor.sv feature_calculator.sv quality_estimator.sv \
  resource_controller.sv runtime_controller_top.sv tb_runtime_controller.sv
conda run -n neural_acc vvp stage8a_sim
```

## Limitations

This work has no synthesis, area, timing, power, energy, FPGA, ASIC, or hardware-accuracy result. Integer division is retained as a Stage 8A prototype choice. The controller plumbing does not demonstrate that reducing PE count changes neural-network accuracy, nor does it supersede the validated research conclusion that 64 PE is the only jointly feasible configuration under the existing performance, energy, and degradation constraints.
