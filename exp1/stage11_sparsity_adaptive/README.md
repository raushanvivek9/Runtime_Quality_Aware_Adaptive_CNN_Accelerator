# Stage 11 — Sparsity-Aware Adaptive Computation

This stage isolates a zero-skipping convolution experiment to evaluate whether runtime activation sparsity can reduce effective computation and cycle count without changing the deterministic workload from Stage 9A/10.

## Relation to earlier stages

- Stage 7C showed that PE-count-only adaptation did not beat fixed 64 PE in the validated design space.
- Stage 10 established the analytical compute model and verified the dense RTL scheduler cycle counts for the reduced workload.
- Stage 11 adds a separate sparse execution mechanism that skips zero-valued activations while preserving the exact same mathematical output.

## Workload

- input: 8×8×3
- kernel: 3×3
- output channels: 16
- stride: 1
- padding: 1
- total outputs: 1024
- dense MACs: 27,648

The exact deterministic generation is unchanged from Stage 9A/10:

- input[ic][h][w] = ((ic + h + w) % 5) - 2
- weight[oc][ic][kh][kw] = ((oc + ic + kh + kw) % 3) - 1

## Sparse mechanism

The sparse execution path counts each MAC as useful only when the corresponding activation is non-zero. Zero-valued input activations and out-of-range padded values are skipped. This is an execution optimization only; it is not an accuracy change.

## PE configurations

- 16 active PE
- 32 active PE
- 64 active PE

The architecture remains a single 64-PE physical array with logical active modes.

## Commands

```bash
cd /home/cs25m115/Neural_Acc/exp1/stage11_sparsity_adaptive
bash ./run_stage11.sh
```

## Expected outputs

- Python dense and sparse validation
- analytical sparse cycle model
- sparse RTL validation for 16/32/64 PE
- stage11_results.csv
- VALIDATION.md
- stage11_report.txt
- stage11_plot.png

## Limitations

- This experiment is intentionally limited to the fixed Stage 10 workload.
- It does not claim energy savings from cycle reduction alone.
- It does not claim accuracy improvement.
- It does not modify the protected Stage 8A/9A/9B/9C/10 implementations.
