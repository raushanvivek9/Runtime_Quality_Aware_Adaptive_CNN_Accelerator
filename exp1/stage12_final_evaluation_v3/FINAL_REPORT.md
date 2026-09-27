# Stage 12 Final Evaluation v3

## 1. Objective
Train CIFAR-compatible ResNet-18 and VGG-16 on the full CIFAR training data, then measure exact-zero convolution-input skipping.

## 2. Experimental setup
Seed 42, deterministic 45,000/5,000 train/validation split, full 10,000-image test set, local CIFAR pickle loader, and CPU-only neural_acc execution.

## 3. Dataset
CIFAR-10 and CIFAR-100 counts, shapes, labels, and normalization are recorded in results/dataset_validation.txt.

## 4. Training methodology
Training uses RandomCrop(32, padding=4), RandomHorizontalFlip, SGD with momentum 0.9, weight decay 5e-4, cosine annealing, batch size 256, and the declared 50-epoch CPU target. The requested 150 epochs was not feasible on this CPU-only host and is recorded in CONFIG.yaml.

## 5. Model architectures
ResNet-18 uses a 3x3 stride-1 first convolution with no ImageNet max-pooling. VGG-16 uses CIFAR-compatible pooling and adaptive 1x1 classifier pooling.

## 6. Training results
- resnet18/cifar10: epochs=150, best_val=0.9586, status=PASS
- resnet18/cifar100: epochs=150, best_val=0.7758, status=PASS
- vgg16/cifar10: epochs=150, best_val=0.8948, status=PASS
- vgg16/cifar100: epochs=150, best_val=0.6618, status=PASS

## 7. Test accuracy
Only best-checkpoint, completed-training test accuracy is presented as final accuracy.

## 8. Runtime activation monitoring
Convolution inputs are monitored with streaming exact-zero counts and unfolded operands.

## 9. Activation sparsity
Both pre-padding activation sparsity and effective unfolded sparsity are reported.

## 10. Exact-zero sparse inference
Sparse mode masks only values exactly equal to zero at convolution inputs. No weights, labels, test samples, architecture, or nonzero values are changed.

## 11. Accuracy preservation
Dense and sparse logits, prediction mismatches, and percentage-point accuracy change are measured in dense_vs_sparse.csv and accuracy_preservation.csv.

## 12. MAC reduction
MACs account for channels, kernels, stride, padding, and output geometry.

## 13. Fixed64 analytical performance
Cycles are ceil(MACs / 64) and are analytical, not RTL cycles.

## 14. Adaptive resource allocation
The unchanged v2 epsilon policy tests 0%, 5%, 10%, and 20% and selects the smallest PE count within each declared latency bound. It is resource-aware adaptive execution, not an accuracy policy.

## 15. RTL evidence
NOT RUN. No full-model RTL is claimed; previous-stage RTL remains separate.

## 16. Energy evidence
NOT RUN. No uncalibrated Accelergy unit was converted to joules.

## 17. Limitations
CPU-only training used the declared 50-epoch maximum-feasible target rather than 150 requested epochs. Any pair below 50 epochs is incomplete and excluded from final accuracy evaluation.

## 18. Main findings
- resnet18/cifar10: dense_accuracy=0.9513, sparse_accuracy=0.9513, MAC_reduction=72.24934835338311%, cycle_reduction=72.24934835338311%, average_active_PEs=64.0
- resnet18/cifar100: dense_accuracy=0.7697, sparse_accuracy=0.7697, MAC_reduction=68.28395165353061%, cycle_reduction=68.28395165353061%, average_active_PEs=64.0
- vgg16/cifar10: dense_accuracy=0.8846, sparse_accuracy=0.8846, MAC_reduction=89.59230678816175%, cycle_reduction=89.59230678816175%, average_active_PEs=64.0
- vgg16/cifar100: dense_accuracy=0.6557, sparse_accuracy=0.6557, MAC_reduction=69.98297529719868%, cycle_reduction=69.98297529719868%, average_active_PEs=64.0

## 19. Reproducibility
bash ./run_stage12_final_v3.sh
