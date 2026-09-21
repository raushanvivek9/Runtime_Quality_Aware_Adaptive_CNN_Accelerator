# Stage 8B Adaptive PE-Array RTL Prototype

Stage 8B demonstrates the hardware mechanism that can consume a Stage 8A `resource_cfg`: actual PE enable gating controls a single physical 64-PE array while the same deterministic 8x8 GEMM result is preserved.

## Architecture

```text
resource_cfg (captured at start)
            |
            v
adaptive_pe_controller -- pe_enable[63:0] --> one physical 64-PE array
                                                    |
matrix A, B --> batched GEMM scheduler --> result C, done, cycle_count
```

| Module | Role |
| --- | --- |
| `pe_mac.sv` | Registered signed MAC PE. It updates only when both `enable` and `valid` are asserted. |
| `adaptive_pe_controller.sv` | Decodes a captured resource configuration into active count and the 64-bit enable mask. |
| `pe_array.sv` | Generates exactly 64 MAC PEs and schedules output elements across only the enabled subset. |
| `adaptive_compute_top.sv` | Captures configuration at workload start and exposes debug enables, PE-valid, and accumulator signals. |
| `tb_adaptive_compute.sv` | Deterministic, self-checking RTL validation. |

The prototype contains one 8x8 physical PE array, not separate 16-, 32-, and 64-PE implementations. The modes are logical active-PE modes:

- `2'b00`: PEs 0–15 enabled (16 active)
- `2'b01`: PEs 0–31 enabled (32 active)
- `2'b10`: PEs 0–63 enabled (64 active)

All other PEs receive `enable=0`, no valid MAC work, and retain their accumulator state.

## Computation and scheduler

The workload is a deterministic signed-integer 8x8 matrix multiplication, `C = A × B`:

`A[i][k] = i + k + 2`

`B[k][j] = j - k + 8`

For each batch, PE `p` computes output `C[batch_base + p]` over eight `k` MAC cycles. At `k=0`, its accumulator input is zero; at later `k`, it receives its registered previous accumulation. Each output element is assigned once, with no duplicate output computation.

The measured `cycle_count` increments for every active scheduler MAC cycle; it deliberately excludes the one-cycle captured-configuration handoff and the completion handoff. The validated results are:

| Logical active PEs | Measured MAC cycles | Result |
| ---: | ---: | --- |
| 16 | 32 | Correct 8x8 `C` |
| 32 | 16 | Correct 8x8 `C` |
| 64 | 8 | Correct 8x8 `C` |

These are simulation measurements for this scheduler and workload. They demonstrate more or fewer concurrently active compute elements, not physical performance, energy, or neural-network accuracy.

## Configuration capture and future Stage 8A integration

At an accepted `start`, `adaptive_compute_top` captures `resource_cfg`. The captured value drives `active_pe_count` and `pe_enable_debug` until `done`; changes at the `resource_cfg` input while `busy=1` do not affect the active computation. A subsequent workload can capture a new configuration.

The intended future boundary is:

```text
Stage 8A: decision_valid, resource_cfg
                         |
                         v
Stage 8B: start (or start_layer), resource_cfg, done (or layer_done)
```

Stage 8A is not instantiated or modified by this stage. The Stage 8B testbench supplies `resource_cfg` directly.

## Reproduction

Use the existing `neural_acc` Conda environment:

```sh
./run_sim.sh
```

This runs the Python golden model and then Icarus Verilog 13.0. It writes `reference_model.log`, `stage8b_compile.log`, `stage8b_sim.log`, `stage8b_sim`, and `stage8b_wave.vcd` in this directory.

## Scope and limitations

- This is a 64-PE physical-array prototype; its 16/32/64 modes are logical active-PE modes.
- It is not a complete Eyeriss implementation, a SCALE-Sim RTL reproduction, or a final accelerator dataflow.
- Resource gating is demonstrated at RTL for this deterministic GEMM workload.
- No physical energy, area, timing closure, FPGA, ASIC, synthesis, or hardware measurement was performed.
- No neural-network accuracy improvement is demonstrated. Changing active PE count here changes the scheduler parallelism, not the GEMM mathematics.
- The scheduler is deliberately small and is not necessarily the final accelerator dataflow.
