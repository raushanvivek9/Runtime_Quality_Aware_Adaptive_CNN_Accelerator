# Stage 9A: Actual CNN Convolution RTL Prototype

Stage 9A is an isolated, functional RTL prototype that connects the existing
Stage 8A runtime decision to an actual signed, padded 3x3 convolution.

```text
Loaded 8x8x3 tensor                  Monitoring activation stream
       |                                          |
       |                                  Runtime Monitor -> Features
       |                                          |
       |                                  Quality Estimator -> Resource Controller
       |                                                       |
       +----------------------------------------- Resource Capture
                                                              |
                                              Explicit convolution scheduler
                                                              |
                                               One physical 64-PE MAC array
                                                              |
                                                     8x8x16 output tensor
```

The monitoring stream is deliberately separate from the tensor loaded into
`input_mem`. The stream is tapped by Stage 8A, and the loaded deterministic
input and weights are used by the scheduler only after its decision has been
captured. This demonstrates the control path without claiming a finished
memory or dataflow architecture.

## Layer

| Property | Value |
| --- | --- |
| Input | 8x8, 3 channels |
| Kernel | 3x3, signed integer |
| Output channels | 16 |
| Stride / padding | 1 / 1 |
| Output | 8x8x16 = 1024 elements |
| MACs per output | 27 |
| Total MACs | 27,648 |
| Arithmetic | signed 16-bit input/weight, 48-bit accumulator |

`conv_scheduler.sv` maps up to 64 output elements per batch. Every assigned PE
executes the 27 `ic, kh, kw` MACs for one output, including zero-padding for
out-of-range input coordinates. There is exactly one generated 64-PE array;
the captured resource configuration enables its first 16, 32, or 64 PEs.

Two test modes are intentionally separate:

- `RESOURCE_OVERRIDE`: a testbench-selected 16/32/64 configuration verifies
  all physical gating modes on identical tensor data.
- `REAL_STAGE8A`: an unmodified Stage 8A decision is captured and drives the
  same convolution. The deterministic streams selected 16, 32, then 64 PEs.

Run all checks with the project environment:

```bash
cd /home/cs25m115/Neural_Acc/exp1/stage9a_conv_rtl
./run_sim.sh
```

The runner activates `/home/cs25m115/anaconda3/envs/neural_acc`, generates the
independent `golden_output.mem` and `golden_output.txt`, then runs Icarus 13.0.

Stage 9A does not establish neural-network accuracy, energy, power, area,
timing, FPGA, ASIC, or physical-hardware properties. It is not a full CNN
accelerator, Eyeriss implementation, SCALE-Sim RTL implementation, SRAM
architecture, or ASIC-ready design. Stage 7's validated conclusion about 64 PE
remaining the only jointly feasible current configuration is unchanged.
