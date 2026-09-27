# Stage 9B Validation

## Summary

| Item | Result |
| --- | --- |
| Simulator version | PASS |
| Python result | PASS |
| Compilation result | PASS |
| Simulation result | PASS |
| Input load test | PASS |
| Weight load test | PASS |
| Load completion | PASS |
| Stage 8A monitoring test | PASS |
| Decision capture test | PASS |
| 16 PE | PASS |
| 32 PE | PASS |
| 64 PE | PASS |
| Output correctness | PASS |
| Output stream correctness | PASS |
| Padding correctness | PASS |
| Disabled PE behavior | PASS |
| Configuration stability during compute | PASS |
| Reconfiguration between workloads | PASS |
| Reset validation | PASS |
| Action counters | PASS |
| MAC count | PASS |
| Real Stage 8A integration | PASS |

## Environment and toolchain

- Python environment: `conda run -n neural_acc`
- RTL simulator: Icarus Verilog (`iverilog -g2012 -Wall`)
- Compiler warnings observed: non-fatal Icarus constant-select advisories in the Stage 9A/Stage 8A files; they did not block compilation or correctness.

## Python model

`reference_model.py` produced a valid 8x8x16 output tensor and reported:

- Input elements: 192
- Weight elements: 432
- Output elements: 1024
- Total MAC operations: 27,648
- Checkpoints: O[0][0][0] = 2, O[0][0][1] = 5, O[1][3][3] = 0, O[15][7][7] = 14

## Simulation evidence

The Stage 9B self-checking testbench passed 17 deterministic tests:

1. reset clears FSM, behavioral buffers, counters, and PE state
2. input loading through tensor loader
3. weight loading through tensor loader
4. load completion flags and counts
5. Stage 8A input-buffer monitoring
6. resource decision capture
7. 16-PE override and full 1024-output correctness
8. output-buffer write accounting
9. padding checkpoints
10. disabled-PE gating
11. configuration stability during compute
12. ordered output streaming without duplicates
13. 32-PE override with output equality
14. 64-PE override with output equality
15. reconfiguration across 16/32/64 workloads without reset
16. real Stage 8A end-to-end integration
17. functional buffer action counters and 27,648 MAC count

## Measured cycle summary

| Configuration | Input load | Weight load | Monitor | Decision wait | Compute | Output stream | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 16 PE | 192 | 432 | 192 | 3 | 1153 | 1024 | 3001 |
| 32 PE | 192 | 432 | 192 | 3 | 1089 | 1024 | 2937 |
| 64 PE | 192 | 432 | 192 | 3 | 1057 | 1024 | 2905 |

## Functional counters

| Counter | Value |
| --- | ---: |
| input_buffer_reads | 23424 |
| input_buffer_writes | 192 |
| weight_buffer_reads | 27648 |
| weight_buffer_writes | 432 |
| output_buffer_writes | 1024 |
| output_stream_reads | 1024 |
| active_pe_mac_count | 27648 |

## Notes

The stage is intentionally a behavioral prototype and does not claim SRAM, DMA, bandwidth, energy, or silicon timing performance.
