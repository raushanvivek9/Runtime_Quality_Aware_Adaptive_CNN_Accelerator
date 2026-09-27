# Thesis Draft: Runtime Activation Monitoring and Sparse Resource Evaluation for Neural Network Accelerators

## Chapter 1 — Introduction
Deep neural networks perform repeated convolutional operations over intermediate activations. The project studies whether exact-zero activation information can characterize computation and support analytical sparse execution. The objective is to measure activation behavior, estimate useful computation, compare dense and sparse predictions, and evaluate an analytical PE policy without making a physical hardware performance claim.

The final evaluation covers four workloads: ResNet18/CIFAR10, ResNet18/CIFAR100, VGG16/CIFAR10, and VGG16/CIFAR100. The scope is limited to the frozen Stage 13 evidence.

## Chapter 2 — Background and Related Work
Neural accelerators, processing-element arrays, sparse execution, runtime monitoring, and adaptive allocation require external literature support. Citation placeholders are recorded in `references/REQUIRED_LITERATURE_SEARCH.md`; no unsupported prior-art or novelty claim is made here.

## Chapter 3 — Proposed Approach
The conceptual flow is: neural network, intermediate activation monitoring, zero-count and statistical summaries, quality/degradation estimation, analytical resource policy, PE configuration, and exact-zero sparse computation. In this project, the final full-network evidence measures exact-zero operands and analytical consequences. It does not establish full-network RTL timing or physical power.

## Chapter 4 — Accelerator Architecture and Prototype
The project includes reduced-workload RTL/prototype evidence from earlier stages. That evidence remains separate from the Stage 13 full-network analytical evaluation. The thesis must not imply that complete ResNet18 or VGG16 networks were synthesized or physically benchmarked.

## Chapter 5 — Experimental Methodology
CIFAR10 and CIFAR100 use 45,000 training images, 5,000 validation images, and 10,000 test images with seed 42. Best checkpoints are selected by validation accuracy. Dense and sparse inference use the same weights and complete test set. Sparse execution skips only exactly zero convolution input operands. MAC reduction is based on dense, useful, and skipped MACs. Analytical cycles use ceil(MACs/active_PEs), PE candidates 16, 32, and 64, and epsilon values 0%, 5%, 10%, and 20%.

## Chapter 6 — Experimental Results
- ResNet18 / CIFAR10: test accuracy 0.9513, activation sparsity 62.51186579895019%, MAC reduction 72.24934835338311%, dense/sparse mismatches 0, analytical sparse cycles 24083125525.
- ResNet18 / CIFAR100: test accuracy 0.7697, activation sparsity 57.68464033508301%, MAC reduction 68.28395165353061%, dense/sparse mismatches 0, analytical sparse cycles 27524455397.
- VGG16 / CIFAR10: test accuracy 0.8846, activation sparsity 83.45374636136567%, MAC reduction 89.59230678816175%, dense/sparse mismatches 0, analytical sparse cycles 5093208664.
- VGG16 / CIFAR100: test accuracy 0.6557, activation sparsity 53.85006880540114%, MAC reduction 69.98297529719868%, dense/sparse mismatches 0, analytical sparse cycles 14689419372.

All four workloads preserve predictions under exact-zero sparse execution: dense and sparse accuracies are equal and mismatch counts are zero. VGG16/CIFAR10 has the highest measured aggregate activation sparsity. The adaptive policy selects 64 PEs for every workload and epsilon value.

## Chapter 7 — Discussion
The results separate two effects. Exact-zero activation sparsity reduces useful MACs and analytical cycles. The evaluated latency-constrained PE policy does not reduce the selected PE count for these full-network workloads. This is a neutral result that indicates computation sparsity and PE-count adaptation are distinct opportunities.

## Chapter 8 — Limitations
Analytical cycles are not measured hardware latency. Full-model RTL, physical timing, power, and energy are not validated. Earlier reduced-workload RTL results remain supporting evidence with a different scope. Results are limited to four workloads and exact-zero activation sparsity.

## Chapter 9 — Conclusion and Future Work
The evidence demonstrates measurable activation sparsity, substantial analytical useful-MAC reduction, and exact dense/sparse prediction agreement on the evaluated test sets. Future work includes broader models and datasets, hardware-aware policies, full-network RTL, FPGA implementation, and physical latency/power/energy measurements.

## Appendices
Appendices should include the complete tables, per-layer sparsity, policy rows, RTL scope, and reproducibility manifest.
