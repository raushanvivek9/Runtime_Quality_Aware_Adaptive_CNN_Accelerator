# Experiment 1: pre-layer activation monitoring

`run_monitor.py` runs a small 32 x 32 CNN and attaches PyTorch
`register_forward_pre_hook` callbacks to its `Conv2d` and `Linear` layers. Each
callback observes the activation **entering** a layer, updates streaming
aggregates, and releases the tensor. It does not retain full feature maps.

## Architecture

```text
input -> Conv1 -> ReLU -> Pool -> Conv2 -> ReLU -> Pool -> Conv3 -> ReLU -> FC
          ^                         ^                         ^            ^
          |                         |                         |            |
          +--- pre-hook monitor ----+--- pre-hook monitor -----+------------+
                              (sparsity, mean, variance, min, max)
                                                |
                                                v
                           ../results/activation_stats.{csv,json}
                                                |
                                                v
                      ../controller (future resource-allocation policy)
                                                |
                                                v
                      ../scalesim (future hardware-cost estimation)
```

The monitor records population variance, so it directly follows
`variance = mean(x^2) - mean(x)^2`. The `sparsity` column is the fraction of
activation elements exactly equal to zero.

## Run

From `~/Neural_Acc/exp1/pytorch`:

```bash
conda activate neural_acc
python run_monitor.py
```

For a shorter smoke test:

```bash
python run_monitor.py --batches 1 --batch-size 2
```

Results are written to `~/Neural_Acc/exp1/results/activation_stats.csv` and
`activation_stats.json`.

## Stage 2 - Quality Degradation Dataset

`../controller/generate_quality_dataset.py` builds the offline supervised data
for a later, lightweight resource-sensitivity regressor. It does **not** train
that estimator. For every input sample, monitored layer, and resource level,
the CSV/JSON record contains these input features:

```text
[sparsity, mean, variance, normalized_layer_position, resource_level]
```

The target is measured loss degradation relative to the 64-resource execution:

```text
degradation = loss_reduced - loss_full
```

The script uses resource levels 16, 32, and 64, treating 64 as the full
resource baseline. It also reports dataset-level accuracy degradation as
`accuracy_full - accuracy_reduced`.

### Software proxy for resource reduction

Changing a Python PE-count variable would not change a PyTorch result, so this
stage uses a deterministic **software proxy for resource reduction**. For the
one Conv2d or Linear layer being evaluated, it computes only an evenly spaced
subset of output channels/features (about 25% at resource 16 and 50% at
resource 32) and fills omitted output positions with zeros. This preserves the
original tensor shape for following layers while reducing the selected layer's
actual arithmetic and changing the final logits.

This proxy is reproducible, structured, and useful for collecting an initial
sensitivity dataset, but it is **not** a cycle-accurate PE simulation. A later
stage will use SCALE-Sim for accelerator-level allocation and cost evaluation.

The current Stage-1 project has neither a labelled dataset nor a trained
checkpoint: `run_monitor.py` generates seeded Gaussian images and evaluates a
randomly initialized model. Stage 2 therefore uses the full-resource argmax as
a deterministic pseudo-label. The resulting loss/accuracy quantify agreement
with the 64-resource model, not semantic classification accuracy; that is
recorded in `baseline_metrics.json` and the summary.

Run from `~/Neural_Acc/exp1`:

```bash
python controller/generate_quality_dataset.py
```

For a quick smoke test:

```bash
python controller/generate_quality_dataset.py --samples 8 --batch-size 4
```

The script writes `baseline_metrics.json`, `quality_dataset.csv`,
`quality_dataset.json`, and `quality_dataset_summary.txt` to `results/`.

## Stage 3 - Offline Quality Estimator

Stage 3 trains offline regression models using the existing
`../results/quality_dataset.csv`; it never regenerates or modifies that
dataset. The data path is:

```text
pre-layer monitor -> activation statistics -> offline degradation dataset
                  -> regression model -> predicted degradation -> resource selection
```

The regressors use only `sparsity`, `mean`, `variance`, `layer_position`, and
`resource_level` to predict the measured `degradation` target. They explicitly
exclude `baseline_loss`, `reduced_loss`, correctness fields, and `sample_id` to
prevent target leakage. Train, validation, and test partitions are formed by
`sample_id` (70% / 15% / 15%, seed 42), so rows from one source input cannot
cross split boundaries.

The script trains Linear Regression, a 5 -> 16 -> 8 -> 1 ReLU MLP, and a
Random Forest Regressor. The lowest-validation-MAE model is used in the
demonstration to predict D16/D32/D64 for each test `(sample_id, layer)` pair.
It selects the smallest resource whose prediction is at most `D_MAX = 0.05`,
falling back to 64 when none qualifies.

Run from `~/Neural_Acc/exp1`:

```bash
conda run -n neural_acc python controller/train_quality_estimator.py
```

This remains an **offline software quality estimator**. It is not hardware
implemented and does not claim cycle-accurate PE/resource simulation; SCALE-Sim
integration is a later stage.

## Stage 4 - Adaptive Resource Controller

`../controller/adaptive_controller.py` is an **offline/PyTorch software
adaptive controller**. It runs the existing pre-layer monitor for each
held-out synthetic sample, supplies `sparsity`, `mean`, `variance`, and
`layer_position` to the existing trained Random Forest, and predicts candidate
degradations at resource levels 16, 32, and 64. It then records the smallest
level whose predicted degradation is at most `D_MAX = 0.05`.

The values 16/32/64 are **resource-level abstractions**, not cycle-accurate PE
counts. The deterministic output-channel reduction used to produce the prior
quality dataset is a software proxy only. Consequently, this stage does not
claim hardware energy or latency improvements and does not run or modify
SCALE-Sim.

Run from `~/Neural_Acc/exp1`:

```bash
conda run -n neural_acc python controller/adaptive_controller.py
```

It writes these Stage-4 artifacts to `results/`:

- `adaptive_resource_decisions.csv`
- `prediction_monotonicity_report.txt`
- `adaptive_resource_allocation.png`
- `predicted_degradation_vs_resource.png`
