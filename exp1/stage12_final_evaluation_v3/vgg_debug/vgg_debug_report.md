# Stage 12 Final Evaluation v3 — VGG debug report

## Decision

Do not start the 150-epoch VGG retraining job from the current code path.

The original investigation identified a serious model-definition problem in the legacy custom VGG implementation. That issue was corrected by replacing the non-standard head with a canonical VGG-16 feature extractor and classifier stack, but the resulting model still fails the short learning gates. Therefore the path is still not validated for a long retraining run.

## Evidence

### 1) The original custom VGG path was materially different from a standard VGG-16

The project model in [common.py](../common.py) originally defined a custom path with:

- `self.avgpool = nn.AdaptiveAvgPool2d((1, 1))`
- `self.classifier = nn.Linear(512, classes)`

This is a single linear head. Standard VGG-16 uses the full three-layer classifier block:

- `nn.Linear(512, 4096)`
- `ReLU`
- `Dropout`
- `nn.Linear(4096, 4096)`
- `ReLU`
- `Dropout`
- `nn.Linear(4096, classes)`

The legacy custom model therefore had materially lower representational power and different learning dynamics than a real VGG-16.

### 2) The architecture fix is structurally correct

A canonical implementation, `CifarVgg16Canonical`, was added in [common.py](../common.py). It matches the standard VGG-16 structure:

- 13 Conv2d layers
- 5 MaxPool2d layers
- channel progression `[64, 64, 128, 128, 256, 256, 256, 512, 512, 512, 512, 512, 512]`
- `AdaptiveAvgPool2d((1, 1))`
- canonical classifier stack with `Linear(512, 4096) -> ReLU -> Dropout -> Linear(4096, 4096) -> ReLU -> Dropout -> Linear(4096, classes)`

The comparison in [architecture_comparison.txt](architecture_comparison.txt) confirms the feature extractor matches the reference VGG-16 structure, including the `32 -> 16 -> 8 -> 4 -> 2 -> 1` spatial reduction pattern.

### 3) Short validation after the fix shows the model is structurally valid but not empirically ready

The post-fix validation on the idle cluster node produced:

- architecture: PASS
- output shape: PASS
- gradient flow: PASS
- 32-image overfit: FAIL
- 5-epoch pilot: FAIL

The saved evidence files are:

- [canonical_gradient_probe.csv](canonical_gradient_probe.csv)
- [canonical_overfit32.csv](canonical_overfit32.csv)
- [canonical_5epoch_pilot.csv](canonical_5epoch_pilot.csv)

The small overfit run did not memorize the training subset:

- final loss: 2.1771
- final accuracy: 0.15625

The short 5-epoch pilot also did not learn meaningfully:

- final validation accuracy: 0.0920

### 4) The surrounding training loop is not the culprit

The training loop in [train_models.py](../train_models.py) remains consistent with the dataset and optimizer setup:

- SGD with momentum 0.9
- weight decay 5e-4
- cosine LR scheduler
- standard cross-entropy loss
- valid labeled batch shapes

The failure remains in the model learning behavior itself, not in the data pipeline or optimizer configuration.

## Root cause

The original `CifarVgg16` definition was not a faithful VGG-16 reference implementation because it replaced the standard classifier stack with an underpowered single-layer head. The corrected canonical VGG implementation is structurally correct, but the model still does not pass the validation gates required before a long training run. This means the problem is resolved at the architecture level but not yet at the empirical learning level.

## Validity gate for any future retraining

A future VGG run is only justified if the architecture is corrected to a canonical VGG-16 implementation and the same short probes pass before the 150-epoch job begins.

The required gates are:

1. architecture equivalence to VGG-16
2. valid output shape and stable gradient flow
3. successful tiny overfit memorization
4. successful short pilot learning

At the present state, the canonical VGG passes the first two but fails the final two, so the path is not yet valid for a 150-epoch retraining run.

## Summary

- Data and labels: valid
- Optimizer/scheduler: valid
- Training loop: valid
- Legacy custom VGG: invalid and root cause of poor learning
- Canonical VGG: structurally correct, not yet empirically validated
- Decision: stop and continue debugging; do not start the 150-epoch retraining job yet
