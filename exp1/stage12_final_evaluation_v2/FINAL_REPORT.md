# Stage 12 Final Evaluation v2

## 1. Objective
Obtain trained CIFAR model accuracy and separate it from exact-zero sparsity, analytical execution, RTL correlation, and energy evidence.

## 2. Experimental Setup
CIFAR-compatible local ResNet-18 and VGG-16; deterministic seed 42; configuration is frozen in CONFIG.yaml.
Python 3.11.16, PyTorch 2.14.0+cpu, device=cpu.

## 3. Hardware/software environment
Training uses the neural_acc conda environment and the available CPU/CUDA state recorded in training_environment.json.

## 4. Dataset preparation
Standard CIFAR pickle files are loaded without torchvision. Dataset validation is recorded in dataset_validation.txt.

## 5. Model architectures
ResNet-18 uses a 3x3 stride-1 first convolution with no ImageNet max-pool. VGG-16 uses CIFAR-compatible pooling and adaptive 1x1 classifier pooling.

## 6. Training procedure
One deterministic epoch over the predeclared 5,000-sample training subset, 1,000-sample validation split, SGD, cosine schedule, and best-validation checkpointing. Missing or failed pairs remain NOT RUN.

## 7. Accuracy results
- resnet18/cifar10: test_accuracy=0.149200, samples=10000, status=PASS
- resnet18/cifar100: test_accuracy=0.030600, samples=10000, status=PASS
- vgg16/cifar10: test_accuracy=0.100000, samples=10000, status=PASS
- vgg16/cifar100: test_accuracy=0.010000, samples=10000, status=PASS

## 8. Runtime activation monitoring
Convolution-input hooks collect streaming exact-zero counts and unfolded nonzero operands.

## 9. Sparsity results
See per_layer_sparsity.csv. Padding, stride, kernel, channels, and output geometry are included in the unfolded operand count.

## 10. Exact-zero computation skipping
Sparse inference only masks exact-zero convolution inputs; weights and architecture are unchanged. Dense/sparse logits and prediction mismatches are measured.

## 11. Fixed64 baseline
Analytical dense and sparse cycles use ceil(MACs / 64); they are not RTL cycles.

## 12. Adaptive resource policy
The predeclared policy chooses the smallest PE count satisfying ceil(useful_MACs / PE) <= ceil(ceil(useful_MACs / 64) * (1 + epsilon)). Epsilon sensitivity is reported for 0%, 5%, 10%, and 20%. This is resource-aware adaptive execution, not an accuracy policy.

## 13. RTL correlation
Representative-layer RTL correlation only. The isolated gate records NOT RUN because no compatible model workload adapter was validated.

## 14. Energy evaluation
ENERGY_NOT_RUN. No arbitrary Accelergy output was converted to joules.

## 15. Limitations
The declared one-epoch subset training budget is not a convergence study. Analytical cycles omit memory/control overhead. Full ResNet-18/VGG-16 RTL was not claimed.

## 16. Conclusions
Results distinguish trained accuracy, measured exact-zero sparsity, analytical cycles, RTL evidence, and energy evidence. Any missing component remains explicitly NOT RUN.

## 17. Reproducibility commands
bash ./run_stage12_final_v2.sh
