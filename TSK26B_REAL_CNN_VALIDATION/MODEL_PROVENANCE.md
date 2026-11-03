# TSK-26B Model Provenance

This document records the exact provenance, source checkpoints, parameter counts, and SHA-256 hashes of the four CNN models used in the TSK-26B Neural_Acc hardware validation.

## 1. Summary of Evaluated Models

| Model | Dataset | Classes | Parameters | Reported Top-1 Acc | 100-Sample Eval Top-1 | 100-Sample Eval Top-5 | Checkpoint File | SHA-256 Hash |
|---|---|---|---|---|---|---|---|---|
| ResNet-18 | CIFAR-10 | 10 | 11,173,962 | 94.98% | 95.00% | 100.00% | `resnet18_cifar10.pt` | `ee0e4efc476cc7b1...` |
| ResNet-18 | CIFAR-100 | 100 | 11,220,132 | 79.26% | 79.00% | 94.00% | `resnet18_cifar100.pt` | `e71011071af235a0...` |
| VGG-16-BN | CIFAR-10 | 10 | 15,253,578 | 93.96% | 95.00% | 100.00% | `vgg16bn_cifar10.pt` | `0607244ff73ea067...` |
| VGG-16-BN | CIFAR-100 | 100 | 15,299,748 | 74.01% | 71.00% | 87.00% | `vgg16bn_cifar100.pt` | `7fdd177a9880e3c0...` |

## 2. Checkpoint Details & Architectures

### 2.1 ResNet-18 on CIFAR-10
- **Origin**: HuggingFace Hub `edadaltocg/resnet18_cifar10`
- **Local Weight File**: `models/resnet18_cifar10.pt` (SHA-256: `ee0e4efc476cc7b116d9350430fd70c2a19e3f30e170762314e9187fc03e01f7`)
- **Architecture Adaptation**: Standard CIFAR adaptation where `conv1` is replaced by $3 \times 3$, stride 1, padding 1 (without max-pooling) to preserve $32 \times 32$ spatial dimensions.
- **Total Parameters**: 11,173,962
- **Validation Performance**: 95.00% Top-1 on deterministic test subset (matches ~94.98% reported test set accuracy).

### 2.2 ResNet-18 on CIFAR-100
- **Origin**: HuggingFace Hub `edadaltocg/resnet18_cifar100`
- **Local Weight File**: `models/resnet18_cifar100.pt` (SHA-256: `e71011071af235a01f9c0983f302feac94f6fafa49d40c39ad7aa0753f1cbf5c`)
- **Architecture Adaptation**: Standard CIFAR adaptation with $3 \times 3$ conv1, no maxpool, and 100-way linear classifier.
- **Total Parameters**: 11,220,132
- **Validation Performance**: 79.00% Top-1 on deterministic test subset (matches ~79.26% reported test set accuracy).

### 2.3 VGG-16 with Batch Normalization on CIFAR-10
- **Origin**: PyTorch CIFAR Models `cifar10_vgg16_bn` via `chenyaofo/pytorch-cifar-models`
- **Local Weight File**: `models/vgg16_cifar10.pt` (SHA-256: `0607244ff73ea0679feb66791d39a9cc5dd0e41feedca8e0573b4156eae5bcf8`)
- **Total Parameters**: 15,253,578
- **Validation Performance**: 95.00% Top-1 on deterministic test subset (matches ~93.96% reported test set accuracy).

### 2.4 VGG-16 with Batch Normalization on CIFAR-100
- **Origin**: PyTorch CIFAR Models `cifar100_vgg16_bn` via `chenyaofo/pytorch-cifar-models`
- **Local Weight File**: `models/vgg16_cifar100.pt` (SHA-256: `7fdd177a9880e3c0b48c13894242db6c32fda0fcf4ac1aabb5722ba6bb647311`)
- **Total Parameters**: 15,299,748
- **Validation Performance**: 71.00% Top-1 on deterministic test subset (matches ~74.01% reported test set accuracy).
