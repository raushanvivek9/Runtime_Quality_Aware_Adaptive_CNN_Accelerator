# Stage 9C: Isolated Multi-Layer CNN RTL Prototype

This directory contains the isolated Stage 9C prototype for a multi-layer CNN wrapper around the protected Stage 8A and Stage 9A datapaths.

## Scope

- Preserve the validated Stage 8A runtime monitor and Stage 9A convolution datapath without modifying them.
- Build a thin Stage 9C wrapper that sequences a layered tensor flow and the Stage 8A/9A handoff boundary.
- Validate the stream protocol using the same clock and sample semantics previously proven in the protected stages.

## Modules

- `conv_layer_wrapper.sv`: wrapper around the Stage 8A/9A boundary with explicit `sample_valid` and single-cycle `layer_end` timing.
- `cnn_dataflow_controller.sv`: higher-level sequencing logic for the multi-layer flow.
- `pooling2x2.sv`: pooling stage used by the layered prototype.
- `multilayer_cnn_top.sv`: top-level composition of the multi-layer flow.
- `tb_stage9c_multilayer.sv`: deterministic verification bench for the Stage 9C prototype.
- `reference_model.py`: Python reference for the layer sequence.

## Current status

The Stage 9C wrapper and validation suite are now green in simulation.

Validated results:

- Stage 9A direct harness: PASS
- Stage 9C wrapper suite: PASS (`Stage 9C validation: 11 pass checks, 0 fail checks`)

The root cause was not in the preserved Stage 8A or Stage 9A logic. The fix was to tighten the Stage 9C wrapper to the Stage 8A stream contract: final valid sample, then one-cycle `layer_end` with `sample_valid` low, then clean return to idle before the next `start`. The Stage 9C bench was also corrected to sample the one-cycle `output_valid` pulse on the exact completion edge instead of one nanosecond later.

## Validation command

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

## Artifacts

- `stage9c_wave.vcd`: generated waveform from the Stage 9C simulation.
- `stage9c_sim.log`: captured simulation output.
- `stage9c_reference.log`: Python reference output.
- `stage9c_report.txt`: summary of the validated prototype state.

## Notes

- No unsupported physical hardware claims are made.
- This is a prototype-level RTL path validated in simulation only.
