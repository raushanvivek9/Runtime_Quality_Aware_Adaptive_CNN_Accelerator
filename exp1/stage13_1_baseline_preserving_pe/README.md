# Stage 13.1: Baseline-Preserving Adaptive PE Allocation

This directory is a completely isolated experiment that does not modify the frozen Stage 13 artifacts, frozen checkpoints, or previous experimental outputs.

## 1. Concept and motivation

Stage 13 is frozen and remains the reference methodology. Stage 13.1 is a separate analytical experiment designed to answer a narrower question:

> Can we reduce the processing element (PE) width layer by layer while preserving the original dense baseline cycle budget, using only exact-zero activation sparsity and the measured useful MAC count?

The key constraint is that this experiment is intentionally conservative. It does not modify the frozen Stage 13 model, data pipeline, or validation logic. It reuses the frozen Stage 12 V3 checkpoint stack and the Stage 13 evaluation methodology, then adds a new policy that is stricter and more baseline-preserving than the earlier Stage 13 epsilon-based threshold approach.

In other words, Stage 13.1 asks whether a PE decision can be made without relaxing the dense 64-PE budget. The answer is computed analytically from the actual activation statistics of each convolution layer.

---

## 2. Core idea

For each convolution layer, we compute:

- dense MAC count: the full MAC workload if all activations are processed in the dense reference mode
- useful MAC count: the number of MACs that remain relevant after exact-zero activations are removed
- activation sparsity: the fraction of exact-zero activations in the layer input tensor
- baseline cycle count: the cycle requirement of the dense reference design with 64 PEs
- sparse cycle count for candidate PE widths: 16, 32, and 64

The policy is:

1. Preserve the dense reference cycle budget, defined as `ceil(MAC_dense / 64)`.
2. For each PE candidate `P`, compute `ceil(MAC_useful / P)`.
3. A PE is feasible only if the sparse cycle count remains no worse than the dense baseline cycle count.
4. Choose the smallest feasible PE.
5. If no candidate is feasible, default to 64 PE.

This preserves the original dense analytical cost envelope while allowing the PE width to shrink only when the useful workload is low enough to stay within that baseline budget.

---

## 3. Exact-zero sparse definition

The experiment is based on exact-zero activation pruning semantics, not approximate thresholding.

- Exact-zero activation means: `activation == 0`
- Approximate-zero values such as `1e-6` or `1e-3` are not treated as sparse
- The useful work is computed from the real convolution input operands rather than from an arbitrarily imposed sparsity target

This matters because the experiment is meant to be faithful to the frozen evaluation stack and to avoid introducing a synthetic tolerance parameter.

---

## 4. Full formulas used in the experiment

### 4.1 Dense MAC count

For a convolution layer,

`MAC_dense = O_h * O_w * O_c * K_h * K_w * I_c`

where:

- `O_h` = output height
- `O_w` = output width
- `O_c` = number of output channels
- `K_h`, `K_w` = kernel height and width
- `I_c` = number of input channels

This is the dense reference MAC count used by the baseline architecture.

### 4.2 Useful MAC count

The useful MAC count is derived from exact-zero activation filtering at the convolution input:

`MAC_useful = count_nonzero(input_activation_operands)`

Equivalently, the skipped MACs are:

`MAC_skipped = MAC_dense - MAC_useful`

and the layerwise reduction is:

`MAC_reduction_percent = (MAC_skipped / MAC_dense) * 100`

### 4.3 Activation sparsity

Layer activation sparsity is defined as:

`activation_sparsity = (zero_activations / activation_elements) * 100`

where:

- `zero_activations` = number of exact-zero activation entries in the input tensor
- `activation_elements` = total number of activation elements in that tensor

### 4.4 Baseline dense cycle count

The reference dense cycle budget is computed with 64 PEs:

`C_baseline = ceil(MAC_dense / 64)`

### 4.5 Sparse cycle count for candidate PE widths

For a candidate PE width `P in {16, 32, 64}`:

`C_P = ceil(MAC_useful / P)`

A candidate is feasible only when:

`C_P <= C_baseline`

### 4.6 PE selection rule

The experiment selects the smallest feasible PE:

`P_selected = min { P in {16, 32, 64} : C_P <= C_baseline }`

If none of the candidates satisfy the inequality, then:

`P_selected = 64`

This enforces that PE reduction only occurs when the useful-MAC workload is still within the original dense 64-PE cycle envelope.

---

## 5. Why this is baseline-preserving

The Stage 13.1 policy is intentionally restrictive. It does not allow the layer to “borrow” extra cycle slack from the dense design. The dense baseline remains the ceiling:

`C_baseline = ceil(MAC_dense / 64)`

and the sparse configuration cannot exceed that cost envelope. This is different from a threshold-based or epsilon-based policy, where a tolerance region may allow a wider PE choice even when the sparse cycle count exceeds the original dense budget.

The Stage 13.1 rule therefore answers a precise engineering question:

> “How much PE reduction is possible while staying within the same dense analytical budget?”

---

## 6. Validation logic

The experiment validates three conditions before accepting the layer-wise PE decision:

1. `MAC_dense >= MAC_useful >= 0`
2. `MAC_skipped = MAC_dense - MAC_useful`
3. `C_P = ceil(MAC_useful / P)` and `C_baseline = ceil(MAC_dense / 64)` must match the recorded layer values exactly

It also checks the PE selection consistency:

- if `C_16 <= C_baseline`, 16 PE is eligible
- else if `C_32 <= C_baseline`, 32 PE is eligible
- else if `C_64 <= C_baseline`, 64 PE is eligible
- otherwise default to 64 PE

The validation summary then verifies that the resulting PE allocation is internally consistent and that the dense/sparse prediction behavior remains identical across the workload run.

---

## 7. Workloads evaluated

- ResNet18 + CIFAR10
- ResNet18 + CIFAR100
- VGG16 + CIFAR10
- VGG16 + CIFAR100

These evaluations are run using the frozen Stage 12 V3 checkpoint stack and the frozen Stage 13 validation logic without altering either.

---

## 8. Run commands

```bash
source /home/cs25m115/anaconda3/etc/profile.d/conda.sh
conda activate neural_acc
python exp1/stage13_1_baseline_preserving_pe/run_stage13_1.py --smoke resnet18 cifar10
python exp1/stage13_1_baseline_preserving_pe/run_stage13_1.py
```

---

## 9. Output files

- `results/layerwise_results.csv`
- `results/workload_summary.csv`
- `results/stage13_vs_stage13_1.csv`
- `results/validation_summary.json`
- `stage13_1_report.txt`

---

## 10. Limitations

- This experiment is analytical and does not claim measured hardware latency or throughput.
- It uses exact-zero activation sparsity only and does not introduce approximate-zero tolerances.
- It is isolated from the frozen Stage 13 artifacts and does not modify the authoritative Stage 13 results.
- The PE decision is a layer-wise policy derived strictly from the exact-zero monitored input activations.

This makes Stage 13.1 a clean, conservative extension of the frozen Stage 13 evidence: a new baseline-preserving PE policy evaluated against the same frozen model and dataset stack without changing the original frozen result set.
