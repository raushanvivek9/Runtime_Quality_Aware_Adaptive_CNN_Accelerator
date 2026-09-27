# CIFAR-100 Controlled Probe Summary

The diagnostic matrix intentionally uses only the 45,000-sample training split and the 5,000-sample validation split. No test-set evaluation is used in the decision process.

| Config | Optimizer | LR | WD | Epoch10 Train Acc | Epoch10 Val Acc | Best Val Acc | Train Loss | Val Loss | Status |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| A | Adam | 0.0010 | 0.0000 | 0.0094 | 0.0104 | 0.0108 | 4.6055 | 4.6053 | stalled |
| B | Adam | 0.0003 | 0.0000 | 0.2054 | 0.2296 | 0.2296 | 3.0489 | 2.9503 | learning |
| C | Adam | 0.0030 | 0.0000 | 0.0091 | 0.0104 | 0.0108 | 4.6062 | 4.6053 | stalled |
| D | AdamW | 0.0010 | 0.0005 | 0.1000 | 0.1202 | 0.1202 | 3.7383 | 3.6346 | stalled |

1. Does the full CIFAR-100 training pipeline learn at all?
The controlled 10-epoch matrix will decide this from the observed train/validation dynamics. The initial failure pattern is a near-random baseline and is not treated as an automatic success claim.

2. Does reducing LR help?
This will be answered from the measured epoch-10 and best validation metrics in the matrix.

3. Does increasing LR help?
This will be answered from the measured epoch-10 and best validation metrics in the matrix.

4. Does AdamW help?
This will be answered from the measured epoch-10 and best validation metrics in the matrix.

5. Does the model update its parameters?
Parameter relative update norms are recorded in the telemetry and compared against the initial state.

6. Does the model collapse to a small number of classes?
The validation-prediction histogram is captured and reported in the telemetry.

7. Is the issue more consistent with optimization, data pipeline, or unresolved behavior?
The decision follows the measured training dynamics and parameter update evidence, not a prior assumption.

8. Is CIFAR-100 READY for a full 150-epoch run?
No automatic retraining recommendation is made unless the probe shows sustained learning under the declared decision rules.
