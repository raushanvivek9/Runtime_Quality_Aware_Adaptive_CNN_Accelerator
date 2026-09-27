# Stage 13 Results Discussion

Activation sparsity varies across model and dataset. VGG16/CIFAR10 has the highest aggregate activation sparsity at 83.4537%. All four evaluated cases preserve dense predictions under exact-zero sparse execution with zero mismatches. Analytical MAC reduction is substantial, and analytical sparse cycle reduction follows the useful-MAC reduction.

The adaptive PE policy selected 64 PEs for every full-network workload at every evaluated epsilon. Therefore, sparsity exploitation and PE adaptation are separate effects in this evidence: sparse useful computation is reduced, but the current latency-constrained policy does not reduce the PE count. Reduced-workload RTL evidence from earlier stages remains separate from these full-model analytical results.
