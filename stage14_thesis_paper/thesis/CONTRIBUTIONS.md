# Contributions

## A. Methodological contribution
The work defines an evidence-based evaluation flow for exact-zero activation sparsity, analytical useful-MAC reduction, and dense/sparse prediction comparison.

## B. Runtime monitoring contribution
The project measures activation zero counts and related per-layer statistics during inference. The Stage 13 evidence supports characterization, not a claim of physical runtime implementation for the full networks.

## C. Sparse computation contribution
The experiments evaluate skipping exact-zero convolution input operands with unchanged checkpoint weights.

## D. Resource-policy evaluation
The existing analytical policy is evaluated at four epsilon values and selects 64 PEs for all four final workloads. This is an evaluated result, not a claim of adaptive improvement.

## E. Accelerator/RTL prototype contribution
Earlier Stage 8–11 artifacts provide reduced-workload RTL/prototype evidence. Full ResNet18/VGG16 RTL validation is outside the demonstrated scope.

## F. Experimental contribution
The final matrix covers ResNet18 and VGG16 on CIFAR10 and CIFAR100 with complete test-set dense/sparse comparisons.

Novelty and state-of-the-art claims require literature verification and are intentionally not made here.
