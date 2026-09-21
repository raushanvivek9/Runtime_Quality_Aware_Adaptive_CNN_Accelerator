# Stage 8C: End-to-End RTL Integration Prototype

Stage 8C connects the validated Stage 8A runtime controller to the validated
Stage 8B adaptive 64-PE GEMM array without changing either source directory.
It is an RTL integration prototype for the runtime-control path.

```text
Activation stream
       |
Runtime Monitor -> Features -> Quality Estimator -> Resource Controller
                                                   |
                                      decision_valid / resource_cfg
                                                   |
                                            Resource Capture
                                                   |
                                      Adaptive 64-PE GEMM Array
                                                   |
                                              GEMM result
```

`integration_top.sv` instantiates the existing `runtime_controller_top` and
`adaptive_compute_top`. A resource configuration is registered only when the
real Stage 8A `decision_valid` is observed. That registered value drives Stage
8B; neither a later Stage 8A output nor the test-only live candidate can alter
the PE population while Stage 8B is busy.

The testbench runs three sequential streams. They naturally yield the shown
resource decisions through the existing Stage 8A coefficients; no coefficients
or thresholds are changed to produce them.

| Layer | Activation stream | D16 | D32 | Selected resource |
| --- | --- | ---: | ---: | ---: |
| conv1 / 0 | `[1, 0, 1, 0]` | 950 | 475 | 16 |
| conv2 / 1 | `[0, 3, 0, -3]` | 4200 | 2100 | 32 |
| conv3 / 2 | `[0, 4, 0, -4]` | 7000 | 3500 | 64 |

The Stage 8B workload remains its deterministic 8x8 integer GEMM. The
activation stream is monitoring stimulus; it is not a CNN data path feeding
the GEMM inputs.

Run the complete Python and RTL validation with:

```bash
cd /home/cs25m115/Neural_Acc/exp1/stage8c_integration
./run_sim.sh
```

The script activates `/home/cs25m115/anaconda3/envs/neural_acc` and uses
Icarus Verilog 13.0. Outputs are `reference_model.log`, `stage8c_compile.log`,
`stage8c_sim.log`, `stage8c_sim`, and `stage8c_wave.vcd`.

Stage 8C is not a complete CNN accelerator, Eyeriss implementation, SCALE-Sim
RTL implementation, energy model, physical-hardware implementation, or
neural-network accuracy evaluation. It makes no energy, area, timing, FPGA,
ASIC, power, or accuracy claims.
