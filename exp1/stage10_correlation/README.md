# Stage 10 Analytical ↔ RTL Correlation

This directory contains the isolated Stage 10 experiment for correlating the analytical compute model with the validated Stage 9A RTL convolution implementation.

## Purpose

The goal is to compare the same reduced convolution workload under the same 16/32/64 active-PE configurations across:

- the Python golden convolution reference
- the analytical compute model
- the validated RTL convolution path

This is a cycle-correlation experiment only. It does not perform energy analysis, physical timing analysis, or hardware claims.

## Workload

- Input: 8×8×3
- Kernel: 3×3
- Output channels: 16
- Stride: 1
- Padding: 1
- Output: 8×8×16
- Total outputs: 1024
- MACs per output: 27
- Total MACs: 27,648

The deterministic generation matches the validated Stage 9A workload:

- input[ic][h][w] = ((ic + h + w) % 5) - 2
- weight[oc][ic][kh][kw] = ((oc + ic + kh + kw) % 3) - 1

## Files

- `stage10_python_reference.py` — Python convolution reference and checkpoint validation
- `analytical_model.py` — analytical compute-cycle model
- `stage10_tb.sv` — isolated RTL harness for 16/32/64 active-PE runs
- `run_stage10.sh` — full workflow: reference, analysis, compile, simulation, CSVs, plot, report
- `python_reference.txt` — flattened Python golden output
- `analytical_results.csv` — ideal compute-cycle estimate
- `rtl_results.csv` — measured RTL results
- `correlation_results.csv` — correlation metrics
- `correlation_plot.png` — cycle comparison plot
- `VALIDATION.md` — pass/fail summary
- `stage10_report.txt` — narrative report

## Expected analytical cycles

- 16 PE: 1728
- 32 PE: 864
- 64 PE: 432

## RTL model

The RTL uses the same validated Stage 9A modules already present in the project:

- ../stage9a_conv_rtl/conv_pe.sv
- ../stage9a_conv_rtl/conv_pe_array.sv
- ../stage9a_conv_rtl/conv_scheduler.sv
- ../stage9a_conv_rtl/conv_runtime_top.sv

The Stage 8A runtime monitor and controller are also used only as required by the validated Stage 9A harness.

## Commands

```bash
cd /home/cs25m115/Neural_Acc/exp1/stage10_correlation
bash ./run_stage10.sh
```

## Limitations

- This is a reduced, common-workload correlation experiment only.
- It does not attempt to generalize beyond this workload.
- It does not claim hardware-level timing, energy, or physical synthesis results.
