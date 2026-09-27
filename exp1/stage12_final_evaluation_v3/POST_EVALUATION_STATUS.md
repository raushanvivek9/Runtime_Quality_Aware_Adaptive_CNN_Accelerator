# POST-EVALUATION STATUS

## 1. VGG16 CIFAR-10 TRAINING

- Best epoch: 127
- Best validation accuracy: 0.8948
- Final validation accuracy: 0.8938
- Checkpoint selected: /home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3/checkpoints/vgg16_cifar10_best.pt

## 2. VGG16 CIFAR-10 TEST EVALUATION

Using the best validation checkpoint selected before evaluating the test set:

- Test accuracy: 0.8846
- Dense accuracy: 0.8846
- Sparse accuracy: 0.8846
- Dense/sparse prediction mismatch count: 0
- Mean activation sparsity: 83.4537%
- MAC reduction: 89.5923%
- Fixed64 dense analytical cycles: 48,936,960,000
- Fixed64 sparse analytical cycles: 5,093,208,664
- Adaptive sparse analytical cycles: 5,093,208,664
- Average active PE allocation: 64.0

This validates the previously declared evaluator policy on the trained CIFAR-10 model. The dense and sparse inference paths are behaviorally equivalent on the full 10,000-sample test set under the exact-zero masking methodology used by the project.

## 3. VGG16 CIFAR-100 DIAGNOSTIC

### Failure evidence from the existing run

The previous CIFAR-100 training run failed to learn under the full 150-epoch pipeline:

- Best validation accuracy: 0.0092 (0.92%)
- Final training accuracy: approximately 1.04%
- Final validation accuracy: 0.68%
- Final train loss: approximately 4.605
- Final validation loss: approximately 4.607

### Dataset checks

The CIFAR-100 dataset used by the project is valid:

- labels are integers
- minimum label: 0
- maximum label: 99
- exactly 100 classes
- class counts are sensible and within [0, 99]
- identity of the train/validation/test split is deterministic
- split counts are 45,000 train / 5,000 validation / 10,000 test
- no test-data leakage into the validation split was found

Saved artifacts:
- cifar100_label_distribution.csv
- dataset_split_check.txt

### Model checks

The CIFAR-100 model instantiation used the same code path as the training pipeline:

- classifier output dimension: 100
- one-batch input shape: [8, 3, 32, 32]
- target shape: [8]
- target min/max: 0 / 90
- logits shape: [8, 100]
- cross-entropy loss: 4.5992 for the initial batch

Saved artifacts:
- model_output_check.txt
- label_logit_loss_sanity.txt

### Tiny overfit test (32 CIFAR-100 samples, 500 optimizer steps)

This is the key diagnostic result:

- initial loss: 4.6067
- final loss: 0.0219
- best loss: 0.0081
- initial accuracy: 0.0
- final accuracy: 1.0
- best accuracy: 1.0
- Conv1 gradient norm: 6.2053e-07
- classifier gradient norm: 0.1997
- Conv1 parameter update norm: 7.7978e-04

The model can definitely overfit 32 CIFAR-100 samples under the same architecture, optimizer, and learning rate, which means the issue is not basic label-space mismatch, wrong output cardinality, or a totally broken optimizer path. The evidence does not support a simple data or model defect.

### Likely root cause

No model/data defect was found in the evidence. The 32-sample overfit succeeds, so the full-data CIFAR-100 failure remains unresolved as a full-training pipeline problem rather than a schema or label bug. A controlled CIFAR-100 training configuration must be established and validated before any additional 150-epoch retraining is launched.

## 4. NEXT ACTION

- CIFAR-100 is NOT READY FOR RETRAINING.
- The code and data checks passed, but the full-data training pipeline remains unvalidated.
- The next step is not another blind 150-epoch run; it is a controlled CIFAR-100 training probe with explicit verification before any expensive full retraining is approved.
- Do not claim success without a fresh, validated full-data training run on CIFAR-100.

| Dataset | Training status | Best Val Acc | Test Evaluation | Thesis-ready? |
| --- | --- | ---: | --- | --- |
| CIFAR-10 | PASS | 0.8948 | dense/sparse accuracy 0.8846, matches exactly, zero mismatches | YES |
| CIFAR-100 | FAILED / not validated | 0.0092 | not yet valid; full-data training not thesis-ready | NO |
