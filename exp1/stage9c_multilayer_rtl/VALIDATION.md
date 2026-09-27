# Stage 9C Validation Notes

## Environment

- OS: Linux
- Conda environment: `neural_acc`
- Simulator: Icarus Verilog (`iverilog` / `vvp`)

## Validation commands used

```bash
cd /home/cs25m115/Neural_Acc/exp1/stage9a_conv_rtl
conda run -n neural_acc iverilog -g2012 -Wall -o stage9a_sim \
  conv_pe.sv conv_pe_array.sv conv_scheduler.sv conv_runtime_top.sv \
  ../stage8a_rtl/runtime_monitor.sv ../stage8a_rtl/feature_calculator.sv \
  ../stage8a_rtl/quality_estimator.sv ../stage8a_rtl/resource_controller.sv \
  ../stage8a_rtl/runtime_controller_top.sv tb_stage9a_conv.sv
conda run -n neural_acc vvp stage9a_sim

cd /home/cs25m115/Neural_Acc/exp1/stage9c_multilayer_rtl
conda run -n neural_acc iverilog -g2012 -Wall -o stage9c_sim \
  conv_layer_wrapper.sv multilayer_cnn_top.sv tb_stage9c_multilayer.sv \
  ../stage8a_rtl/runtime_monitor.sv ../stage8a_rtl/feature_calculator.sv \
  ../stage8a_rtl/quality_estimator.sv ../stage8a_rtl/resource_controller.sv \
  ../stage8a_rtl/runtime_controller_top.sv ../stage9a_conv_rtl/conv_pe.sv \
  ../stage9a_conv_rtl/conv_pe_array.sv ../stage9a_conv_rtl/conv_scheduler.sv \
  ../stage9a_conv_rtl/conv_runtime_top.sv cnn_dataflow_controller.sv pooling2x2.sv
conda run -n neural_acc vvp stage9c_sim
```

## Observed result

The direct Stage 9A harness and the Stage 9C wrapper suite both pass in simulation.

```text
Stage 9A RTL self-check PASS: 6 convolution workloads, 1024 outputs each, 27648 MACs each.
Stage 9C validation: 11 pass checks, 0 fail checks
PASS
```

## Root cause and fix

The Stage 8A monitor and Stage 9A scheduler were not the source of the issue. The remaining boundary defect was in the Stage 9C wrapper state machine: it was not cleanly separating the final valid sample from the `layer_end` signal and returning to a safe idle state before the next layer start.

The wrapped stream was tightened to match the Stage 8A contract exactly:

- sample stream continues with `sample_valid=1`
- final sample is followed by a single `layer_end` cycle with `sample_valid=0`
- wrapper returns to idle and waits for the next `start`

The Stage 9C bench was also corrected to check `output_valid` on the same completion edge as `conv_done`, because the scheduler emits a one-cycle `output_valid` pulse and the earlier check was sampling after the pulse had already collapsed.

## Conclusion

The protected Stage 8A and Stage 9A modules remained unchanged, and the isolated Stage 9C wrapper now matches the protocol correctly. The direct Stage 9A harness and the Stage 9C validation suite are both green in simulation.
