# VGG Training Regime Report

## Scope and controls
All diagnostic runs used the same first 32 CIFAR-10 training samples, labels, current CIFAR normalization, no augmentation, batch size 32, and 500 optimizer steps. No test-set data was used. `CifarVgg16Canonical` was not changed and BatchNorm was not added.

## 32-image training-regime matrix
| config | optimizer | lr | weight decay | initial loss | final loss | best loss | final accuracy | best accuracy | Conv1 grad | classifier grad | Conv1 update |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| A | SGD | 0.1 | 0.0005 | 2.303578 | 2.174427 | 2.095170 | 0.1562 | 0.3125 | 2.613896e-09 | 2.021104e-01 | 1.003594e+00 |
| B | SGD | 0.01 | 0.0005 | 2.303578 | 2.169061 | 2.159622 | 0.1875 | 0.1875 | 5.009825e-07 | 2.642646e-01 | 1.113975e-01 |
| C | SGD | 0.001 | 0.0005 | 2.303578 | 2.189706 | 2.187418 | 0.1875 | 0.2500 | 5.482420e-07 | 2.129460e-01 | 1.125621e-02 |
| D | Adam | 0.001 | 0.0 | 2.303578 | 0.029700 | 0.001569 | 1.0000 | 1.0000 | 5.445757e-02 | 3.918418e-01 | 3.815748e+00 |
| E | AdamW | 0.001 | 0.0005 | 2.303578 | 0.514924 | 0.000047 | 0.9688 | 1.0000 | 2.693042e-01 | 9.789805e-01 | 3.535790e+00 |

## Findings
- Original SGD (A, lr=0.1) ended at 0.1562 accuracy and loss 2.174427; changing weight decay was previously shown to have negligible effect.
- Learning rate alone did not rescue SGD in this controlled 500-step matrix; the optimizer change is the dominant observed training-regime effect.
- Best non-BatchNorm matrix result: Adam at lr=0.001, final accuracy=1.0000, final loss=0.029700.
- AdamW is reported separately from Adam; no architecture or evaluation policy was changed.

## Initialization
The canonical model uses PyTorch module defaults. The torchvision-compatible diagnostic uses the installed torchvision VGG policy: Conv2d Kaiming-normal fan-out, zero Conv bias, Linear normal(std=0.01), and zero Linear bias. Layer-level values are in `initialization_layer_comparison.csv`; the inspected source is in `torchvision_vgg16_source.txt`.

| initialization | final loss | best loss | final accuracy | best accuracy |
|---|---:|---:|---:|---:|
| canonical | 2.169061 | 2.159622 | 0.1875 | 0.1875 |
| torchvision | 0.379681 | 0.000780 | 0.8750 | 1.0000 |

## Gradient depth
Gradient records were collected for Conv1 through Conv13 at steps 1, 10, 50, 100, and 500 for SGD lr=0.01 and Adam lr=1e-3. The complete data is in `gradient_depth_training_regime.csv`; use it to determine whether Adam prevents the early-depth collapse.
- SGD records: 65; Adam records: 65.

## Dropout
- Adam dropout=0.5: final loss=0.029700, final accuracy=1.0000, best accuracy=1.0000.
- Adam dropout=0.0: final loss=1.003172, final accuracy=0.7500, best accuracy=1.0000.

## Normalization
- current_normalization with Adam: final loss=0.029700, final accuracy=1.0000, best accuracy=1.0000.
- tensor_only with Adam: final loss=0.014107, final accuracy=1.0000, best accuracy=1.0000.

## Candidate and pilot
Candidate selection used only the 32-image training diagnostic: `Adam` lr=0.001 weight_decay=0.0. It met the >=90% diagnostic gate: 1.0000 final accuracy.

The 5-epoch full-data pilot was run with the candidate and used the existing 45,000/5,000 train/validation split, augmentation, and normalization.

| epoch | train loss | train accuracy | val loss | val accuracy | lr | epoch time |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 2.157716 | 0.1515 | 1.891354 | 0.2172 | 0.001 | 21.78 |
| 2 | 1.836933 | 0.2625 | 1.747880 | 0.3164 | 0.001 | 22.98 |
| 3 | 1.630058 | 0.3509 | 1.489106 | 0.4084 | 0.001 | 21.31 |
| 4 | 1.464625 | 0.4403 | 1.342998 | 0.4936 | 0.001 | 21.21 |
| 5 | 1.321342 | 0.5147 | 1.203458 | 0.5628 | 0.001 | 21.55 |

5-epoch pilot decision: **READY**.

## Final gate
- Diagnostic controls: BatchNorm and prior torchvision controls remain diagnostic only.
- Candidate final configuration: Adam lr=0.001 weight_decay=0.0.
- Final experiment configuration: unchanged and not launched.
- 150-epoch training: **NOT STARTED**.
- Decision: **READY**.
