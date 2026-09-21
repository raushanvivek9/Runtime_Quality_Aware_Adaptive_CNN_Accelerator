# Stage 8C Validation

Date: 2026-09-20

Environment: `/home/cs25m115/anaconda3/envs/neural_acc`; Icarus Verilog 13.0
(stable), `iverilog -g2012 -Wall`.

| Check | Result | Evidence |
| --- | --- | --- |
| Python activation/Q16.16 reference | PASS | `reference_model.log` |
| Python GEMM golden result | PASS | `C[0][0]=156`, `C[7][7]=1108` |
| RTL compilation | PASS | `stage8c_compile.log`; no compile errors |
| RTL simulation | PASS | `stage8c_sim.log` |
| Waveform generation | PASS | `stage8c_wave.vcd` (252 KiB) |
| Fixed64 comparison | NOT RUN | No second `USE_FIXED64=1` Stage 8C instance was added |

Icarus reports eight `sorry: constant selects in always_* processes are not
fully supported` sensitivity advisories in the unchanged Stage 8A feature and
estimator files. Compilation completed and the self-checking simulation passed.

| Layer | N | Zero count | Sparsity Q16.16 | Mean Q16.16 | Variance Q16.16 | D16 | D32 | D64 | Resource | Active PEs | Scheduler cycles | Result |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| conv1 / 0 | 4 | 2 | 32768 | 32768 | 16384 | 950 | 475 | 0 | 16 | 16 | 32 | PASS |
| conv2 / 1 | 4 | 2 | 32768 | 0 | 294912 | 4200 | 2100 | 0 | 32 | 32 | 16 | PASS |
| conv3 / 2 | 4 | 2 | 32768 | 0 | 524288 | 7000 | 3500 | 0 | 64 | 64 | 8 | PASS |

| Layer | layer_end -> decision | decision -> compute_start | compute_start -> done | layer_end -> done |
| --- | ---: | ---: | ---: | ---: |
| conv1 | 2 cycles | 1 cycle | 35 cycles | 38 cycles |
| conv2 | 2 cycles | 1 cycle | 19 cycles | 22 cycles |
| conv3 | 2 cycles | 1 cycle | 11 cycles | 14 cycles |

The testbench uses `$fatal` for deterministic failures and passed all of the
following checks:

1. PASS: Stage 8B cannot start before a real Stage 8A `decision_valid`.
2. PASS: Stage 8A statistics and estimates reach the integration boundary.
3. PASS: Stage 8A decision and associated layer ID are produced.
4. PASS: the accepted Stage 8A resource equals the boundary capture in real mode.
5. PASS: selected resources configure 16, 32, and 64 active PEs respectively.
6. PASS: PE-enable masks agree with every active-PE count.
7. PASS: every completed GEMM result equals the independent golden matrix.
8. PASS: a test-only live resource candidate was changed during each busy period;
   both integration and Stage 8B captured configurations stayed unchanged.
9. PASS: the next sequential layer captures a different configuration.
10. PASS: conv1, conv2, and conv3 complete in one reset interval.

`stage8c_wave.vcd` contains the required clock/reset, Stage 8A valid signals,
resource capture/start signals, and Stage 8B busy/done, active-PE, enable-mask,
cycle-count, and result-valid signals. Event-level inspection of complete conv1
shows `decision_valid` at 175 ns, capture and `compute_start` at 185 ns,
`compute_busy` with 16 active PEs at 195 ns, and `compute_done` at 535 ns. The
automated checks above are the validation basis; no visual waveform-analysis
tool was required.

Limitations: this validates control handoff and representative GEMM scheduling
only. It does not establish a CNN convolution data path, neural-network
accuracy, performance beyond these simulated cycles, or energy/power/area or
physical-hardware properties. The validated Stage 7 conclusion remains that
64 PE is the only jointly feasible configuration under its current performance,
energy, and degradation constraints.
