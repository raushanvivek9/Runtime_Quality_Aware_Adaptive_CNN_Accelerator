# Isolated AlexNet-MNIST Experiment

This directory is independent of all existing Stage 12 ResNet18 and VGG16 experiments. The pilot is five epochs only; no final long-training job is launched automatically.

## Model

The explicit MNIST-compatible AlexNet-style model accepts `[N, 1, 28, 28]` and returns `[N, 10]`:

`Conv(1,64,3,pad=1) -> ReLU -> MaxPool(2) -> Conv(64,192,3,pad=1) -> ReLU -> MaxPool(2) -> Conv(192,384,3,pad=1) -> ReLU -> Conv(384,256,3,pad=1) -> ReLU -> Conv(256,256,3,pad=1) -> ReLU -> AdaptiveAvgPool(1,1) -> Linear(256,10)`.

No BatchNorm, augmentation, pruning, quantization, or ImageNet AlexNet weights are used.

## Training and data

- Dataset: MNIST, deterministic seed-42 split of 55,000 training, 5,000 validation, and 10,000 test samples.
- Normalization: `ToTensor()` followed by `Normalize((0.1307,), (0.3081,))`.
- Optimizer: SGD, learning rate `0.1`, momentum `0.9`, weight decay `5e-4`.
- Batch size: `128`; scheduler: cosine annealing over five pilot epochs.
- Reproducibility: Python, NumPy, PyTorch, and CUDA seeds are `42`; deterministic cuDNN settings are enabled where practical.

## Evaluation methodology

For each convolution layer, activation sparsity is the fraction of exact tensor values equal to zero. Convolution useful MACs count nonzero unfolded activation operands multiplied by output channels. Dense MACs use the full output geometry and kernel/channel dimensions; `skipped_MACs = dense_MACs - useful_MACs` and `MAC_reduction = skipped_MACs / dense_MACs`. Dense and sparse predictions use the same checkpoint and weights; sparse execution skips only exact-zero activation operands.

Analytical cycles use `ceil(useful_MACs / active_PEs)`. Fixed baselines use 64 PEs. Adaptive allocation tests epsilon values `0%`, `5%`, `10%`, and `20%`, selecting the smallest of 16, 32, and 64 PEs satisfying `ceil(useful_MACs / PE) <= ceil(useful_MACs / 64) * (1 + epsilon)`. This is a resource policy, never an accuracy policy.

RTL correlation is `NOT RUN` because no compatible AlexNet RTL adapter is assumed. Energy evaluation is `NOT RUN` unless a validated compatible mapping is added explicitly.