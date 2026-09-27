# Stage 13 Final Paper Report

## 1. Objective
Freeze the verified Stage 12 evidence without retraining or changing the experimental methodology.

## 2. Experimental Matrix
- ResNet18 / CIFAR10: PASS
- ResNet18 / CIFAR100: PASS
- VGG16 / CIFAR10: PASS
- VGG16 / CIFAR100: PASS

## 3. Training Methodology
The established 45,000/5,000 split, seed 42, and saved best checkpoints were used.

## 4. Sparse Execution Methodology
Exact-zero activation operands were skipped using identical dense/sparse checkpoint weights.

## 5. Analytical Cycle Methodology
Cycles are analytical ceil(useful_MACs / active_PEs), not hardware latency.

## 6. Final Accuracy Results
- ResNet18 / CIFAR10: test=0.9513, dense=0.9513, sparse=0.9513, mismatches=0
- ResNet18 / CIFAR100: test=0.7697, dense=0.7697, sparse=0.7697, mismatches=0
- VGG16 / CIFAR10: test=0.8846, dense=0.8846, sparse=0.8846, mismatches=0
- VGG16 / CIFAR100: test=0.6557, dense=0.6557, sparse=0.6557, mismatches=0

## 7. Activation Sparsity Results
- ResNet18 / CIFAR10: 62.51186579895019%
- ResNet18 / CIFAR100: 57.68464033508301%
- VGG16 / CIFAR10: 83.45374636136567%
- VGG16 / CIFAR100: 53.85006880540114%

## 8. MAC Reduction Results
- ResNet18 / CIFAR10: 72.24934835338311%
- ResNet18 / CIFAR100: 68.28395165353061%
- VGG16 / CIFAR10: 89.59230678816175%
- VGG16 / CIFAR100: 69.98297529719868%

## 9. Analytical Cycle Results
- ResNet18 / CIFAR10: dense=86784000000, sparse=24083125525
- ResNet18 / CIFAR100: dense=86784000000, sparse=27524455397
- VGG16 / CIFAR10: dense=48936960000, sparse=5093208664
- VGG16 / CIFAR100: dense=48936960000, sparse=14689419372

## 10. Adaptive PE Results
The policy selected 64 PEs for all four workloads at epsilon 0%, 5%, 10%, and 20%.

## 11. Dense vs Sparse Prediction Agreement
All four workloads have zero prediction mismatches and zero accuracy drop.

## 12. RTL Validation Scope
Full-model RTL and physical hardware measurements were not run; reduced-workload RTL remains separate.

## 13. Limitations
See FINAL_LIMITATIONS.md.

## 14. Reproducibility
Run validation/run_stage13_validation.py.

## 15. Final Conclusions
The evaluated exact-zero sparse execution substantially reduces useful MACs and analytical computation while preserving predictions on the evaluated test sets. The adaptive policy selected 64 PEs for all four full-network workloads under the evaluated analytical constraint.
