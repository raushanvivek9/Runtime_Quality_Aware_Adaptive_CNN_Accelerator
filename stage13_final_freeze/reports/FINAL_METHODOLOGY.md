# Final Methodology

## Datasets
CIFAR-10 and CIFAR-100 use the established local pickle datasets with 50,000 original training images split into 45,000 training and 5,000 validation images, plus the complete 10,000-image test set. Inputs are 3x32x32, seed 42, and the established CIFAR normalization.

## Models and training
The evaluated models are CIFAR-compatible ResNet18 and VGG16. Best checkpoints are selected by validation accuracy; no Stage 13 retraining or methodological changes were performed.

## Sparse execution
Sparse execution skips only exact-zero convolution input operands. Dense and sparse inference use identical checkpoint weights and the same complete test set.

## MAC and cycles
Dense, useful, and skipped MACs are calculated analytically. Skipped MACs equal dense MACs minus useful MACs. Analytical cycles are ceil(MACs / active PEs), with PE candidates 16, 32, and 64.

## Adaptive policy
The existing policy is evaluated at epsilon values 0%, 5%, 10%, and 20% without modification.

## Limitations
These are analytical cycles, not measured hardware latency. Full-model RTL, FPGA/ASIC timing, power, and physical energy were not measured. Accelergy units were not converted to joules.
