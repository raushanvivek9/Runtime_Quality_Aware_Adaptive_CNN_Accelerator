# VGG architecture fix report

## A. Original architecture

The original Stage 12 v3 VGG path in [../common.py](../common.py) used a single linear head:

- `AdaptiveAvgPool2d((1,1))`
- `Linear(512, classes)`

This was not a faithful VGG-16 classifier stack and did not behave like a standard CIFAR VGG path.

## B. Problem observed

The short diagnostic probe showed the original custom VGG path had almost no useful gradient reaching the first convolutional layer, with the first convolution gradient L2 staying around `1e-06` while the same batch under a reference VGG path showed a gradient of roughly `1e-02` to `1e-01`.

The training loop used valid CIFAR data and optimizer settings, but the model path itself was not learning.

## C. Corrected architecture

A new canonical model, `CifarVgg16Canonical`, was added in [../common.py](../common.py) and follows the standard VGG-16 feature stack:

- 64, 64, MaxPool
- 128, 128, MaxPool
- 256, 256, 256, MaxPool
- 512, 512, 512, MaxPool
- 512, 512, 512, MaxPool

with all convolutions using:

- kernel size = 3
- stride = 1
- padding = 1
- ReLU(inplace=True)
- MaxPool2d(kernel_size=2, stride=2)

The classifier uses the canonical VGG-16 head:

- `Linear(512, 4096)`
- `ReLU`
- `Dropout`
- `Linear(4096, 4096)`
- `ReLU`
- `Dropout`
- `Linear(4096, classes)`

with an explicit `AdaptiveAvgPool2d((1,1))` before flattening.

## D. Parameter count comparison

For the 10-class model:

- canonical VGG-16 parameter count: 33,638,218
- CIFAR-100 canonical VGG-16 parameter count: 34,006,948

These counts are consistent with the standard 13-convolution-layer VGG-16 design and are not identical to the original custom VGG because the classifier stack is now canonical.

## E. Gradient probe results

Gradient validation was run for the same 128-image CIFAR-10 batch on:

1. canonical VGG
2. original custom VGG
3. ResNet-18

The saved file [canonical_gradient_probe.csv](canonical_gradient_probe.csv) shows the canonical model has nonzero first-convolution gradients (`~2e-07` to `~3e-07`), which is much smaller than the ResNet-18 reference on the same batch but still finite. The original custom VGG remained much smaller (`~7e-07` to `~8e-07`), reinforcing that the original path was flawed.

## F. 32-image overfit results

The 32-image overfit experiment was run and saved to [canonical_overfit32.csv](canonical_overfit32.csv).

Observed result:

- final loss: 2.1771
- final accuracy: 0.15625

This did not satisfy the required memorization criterion, and therefore the model/training path is not yet validated as a capable learner.

## G. 5-epoch pilot results

The 5-epoch CIFAR-10 pilot was run and saved to [canonical_5epoch_pilot.csv](canonical_5epoch_pilot.csv).

Observed result:

- final validation accuracy: 0.0920
- final train accuracy: not sufficient for a learning signal

This does not support a new 150-epoch retraining run.

## H. Exact files modified

- [../common.py](../common.py)
- [test_canonical_model.py](test_canonical_model.py)
- [validate_canonical_vgg.py](validate_canonical_vgg.py)
- [architecture_comparison.txt](architecture_comparison.txt)
- [canonical_gradient_probe.csv](canonical_gradient_probe.csv)
- [canonical_overfit32.csv](canonical_overfit32.csv)
- [canonical_5epoch_pilot.csv](canonical_5epoch_pilot.csv)
- [READY_FOR_RETRAINING.txt](READY_FOR_RETRAINING.txt)

## I. Exact files intentionally not modified

- [../stage12_final_evaluation](../stage12_final_evaluation)
- [../stage12_final_evaluation_v2](../stage12_final_evaluation_v2)
- any protected stage 1–11 directories
- existing Slurm logs under the current stage
- any existing checkpoints under [../checkpoints](../checkpoints)

## J. Whether the VGG pipeline is READY for a new 150-epoch run

No — the corrected architecture is structurally valid, but it is not yet proven ready for a new 150-epoch training run.

The evidence from the overfit and 5-epoch pilot shows:

- architecture validation: PASS
- gradient probe: PASS (finite, nonzero gradients)
- 32-image overfit: FAIL
- 5-epoch pilot: FAIL

Therefore the decision is: NOT READY — CONTINUE DEBUGGING.
