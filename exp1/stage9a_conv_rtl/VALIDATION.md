# Stage 9A Validation

Date: 2026-09-20

Simulator: Icarus Verilog 13.0 (stable) from
`/home/cs25m115/anaconda3/envs/neural_acc`, using `iverilog -g2012 -Wall`.

| Validation item | Result | Evidence |
| --- | --- | --- |
| Python integer convolution | PASS | `reference_model.log`, `golden_output.mem`, `golden_output.txt` |
| 16-PE override convolution | PASS | 1024 RTL outputs match Python |
| 32-PE override convolution | PASS | 1024 RTL outputs match Python and 16-PE output |
| 64-PE override convolution | PASS | 1024 RTL outputs match Python, 16-PE, and 32-PE outputs |
| Reset | PASS | controls, outputs, and all PE accumulators reset |
| Active PE count and enable mask | PASS | every bit checked for 16, 32, and 64 modes |
| Disabled PE gating | PASS | disabled PEs receive no valid MAC and retain their accumulator |
| Padding and output channels | PASS | full tensor and four explicit checkpoints match Python |
| Busy-time configuration stability | PASS | live candidate changes do not alter captured configuration |
| Reconfiguration | PASS | 16 -> 32 -> 64 workloads complete without reset |
| Real Stage 8A integration | PASS | natural Stage 8A decisions drive all three modes |
| Compilation | PASS | `stage9a_compile.log`, no errors |
| RTL simulation | PASS | `stage9a_sim.log` |
| Waveform generation and inspection | PASS | `stage9a_wave.vcd` |

The compilation log has eight Icarus `always_*` sensitivity advisories in the
unchanged Stage 8A feature/estimator files. They are not compilation errors;
the complete self-checking RTL run passed.

## Python Reference

The independent Python model generated the entire 8x8x16 output tensor using
normal integer arithmetic and padding=1. It reports 1024 output elements, 27
MACs per output, and 27,648 total MACs.

| Python checkpoint | Value |
| --- | ---: |
| `O[0][0][0]` | 2 |
| `O[0][0][1]` | 5 |
| `O[1][3][3]` | 0 |
| `O[15][7][7]` | 14 |

## Override Results

| Configuration | Active PEs | Scheduler MAC cycles | `conv_start` -> `conv_done` | `layer_end` -> `conv_done` | Output |
| --- | ---: | ---: | ---: | ---: | --- |
| 16 PE | 16 | 1728 | 1794 cycles | 1797 cycles | PASS |
| 32 PE | 32 | 864 | 898 cycles | 901 cycles | PASS |
| 64 PE | 64 | 432 | 450 cycles | 453 cycles | PASS |

For every row, measured `layer_end` -> `decision_valid` latency was 2 cycles,
and measured `decision_valid` -> `conv_start` latency was 1 cycle. Scheduler
cycles count only MAC-state cycles; start-to-done includes the measured batch
clear and control-state overhead. No cycle count was normalized or scaled.

## Real Stage 8A Results

| Monitoring layer | Activation stream | D16 | D32 | Stage 8A / captured config | Active PEs | Scheduler cycles | Output |
| --- | --- | ---: | ---: | --- | ---: | ---: | --- |
| conv1 / 0 | `[1, 0, 1, 0]` | 950 | 475 | 16 PE | 16 | 1728 | PASS |
| conv2 / 1 | `[0, 3, 0, -3]` | 4200 | 2100 | 32 PE | 32 | 864 | PASS |
| conv3 / 2 | `[0, 4, 0, -4]` | 7000 | 3500 | 64 PE | 64 | 432 | PASS |

The testbench verifies `stage8a_resource_cfg == stage8a_resource_at_capture`
in real mode, and that the captured value, active-PE count, and full output
remain correct. `RESOURCE_OVERRIDE` is used only for the separate physical
mode tests.

## Waveform

`stage9a_wave.vcd` is 440 KiB and contains the required monitoring, decision,
capture, start, busy, done, active-PE, mask, output-index, output-write, and
output-valid signals. Event-level inspection of the first 16-PE workload shows
`decision_valid` at 175 ns, resource capture and `conv_start` at 185 ns,
`conv_busy` at 195 ns, first batch result write at 465 ns, final batch base
1008 at 17,835 ns, final write at 18,105 ns, and `conv_done` at 18,125 ns.
The first batch includes the explicit padded boundary outputs; the independent
full-tensor comparison covers both those and the final output.

## Test Count

PASS: 14 validation groups: the 12 required testbench categories, the real
Stage 8A end-to-end integration, and the independent Python reference.

## Limitations

This is a functional RTL convolution prototype with register-array memory
models. It does not model physical SRAM, a complete CNN data path, DMA,
bandwidth, energy, power, area, timing, FPGA/ASIC implementation, or neural
network accuracy. The reduced 8x8 spatial workload preserves the conv1
structure (3 input channels, 3x3 kernel, 16 output channels) but must not have
its raw cycles compared directly to the 32x32 Stage 5/7 SCALE-Sim workload.
