# Final paper evaluation summary

This artifact set reflects the validated Stage 12 evidence in the project results directory. The following model/dataset pairs are confirmed as final paper results:
- ResNet18 / CIFAR10
- ResNet18 / CIFAR100
- VGG16 / CIFAR10
- VGG16 / CIFAR100

All four model/dataset pairs have completed checkpoint-based evaluation. The dense and sparse test-set accuracies agree exactly in every pair.

The dense and sparse test-set accuracies agree exactly in each validated case, and the MAC/cycle reductions are taken from the saved analytical evaluation outputs in the project results directory.

## Measured comparison
- ResNet18/CIFAR10: test_accuracy=0.9513, activation_sparsity=62.51186579895019%, MAC_reduction=72.24934835338311%, fixed64_dense_cycles=86784000000, fixed64_sparse_cycles=24083125525, status=PASS
- ResNet18/CIFAR100: test_accuracy=0.7697, activation_sparsity=57.68464033508301%, MAC_reduction=68.28395165353061%, fixed64_dense_cycles=86784000000, fixed64_sparse_cycles=27524455397, status=PASS
- VGG16/CIFAR10: test_accuracy=0.8846, activation_sparsity=83.45374636136567%, MAC_reduction=89.59230678816175%, fixed64_dense_cycles=48936960000, fixed64_sparse_cycles=5093208664, status=PASS
- VGG16/CIFAR100: test_accuracy=0.6557, activation_sparsity=53.85006880540114%, MAC_reduction=69.98297529719868%, fixed64_dense_cycles=48936960000, fixed64_sparse_cycles=14689419372, status=PASS

## Adaptive resource policy
Measured policy rows for epsilon values 0%, 5%, 10%, and 20% are recorded in RESOURCE_POLICY_TABLE.csv and RESOURCE_POLICY_TABLE.md. All four model/dataset pairs have complete policy evidence.
