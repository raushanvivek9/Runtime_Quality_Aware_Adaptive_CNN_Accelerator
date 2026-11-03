# TSK-26B Dataset Provenance

This document records the exact provenance, preprocessing steps, sample counts, and cryptographic hashes of the evaluation datasets.

## 1. Dataset Overview

| Dataset | Source Repository | Raw Source File | Source SHA-256 | Deterministic Slice | Saved File | Saved Slice SHA-256 |
|---|---|---|---|---|---|---|
| CIFAR-10 | `uoft-cs/cifar10` | `plain_text/test-00000-of-00001.parquet` | `841389e6f2d64f28...` | 100 images (indices 0..99) | `data/cifar10_test100.pt` | `ba6abd25209b04b5...` |
| CIFAR-100 | `uoft-cs/cifar100` | `cifar100/test-00000-of-00001.parquet` | `98776c529bb146a9...` | 100 images (indices 0..99) | `data/cifar100_test100.pt` | `943dcbe94f935a41...` |

## 2. Preprocessing and Normalization

### 2.1 CIFAR-10 Preprocessing
- **Pixel Normalization**: Scaled to `[0.0, 1.0]` via `transforms.ToTensor()`.
- **Channel Mean**: `[0.4914, 0.4822, 0.4465]`
- **Channel Std**: `[0.2023, 0.1994, 0.201]`
- **Output Tensor Shape**: `(100, 3, 32, 32)` float32 tensor.

### 2.2 CIFAR-100 Preprocessing
- **Pixel Normalization**: Scaled to `[0.0, 1.0]` via `transforms.ToTensor()`.
- **Channel Mean**: `[0.5071, 0.4867, 0.4408]`
- **Channel Std**: `[0.2675, 0.2565, 0.2761]`
- **Output Tensor Shape**: `(100, 3, 32, 32)` float32 tensor.

## 3. Cryptographic Verification Table

```
841389e6f2d64f28bf17310e430aebac20ec3ba611a3c5e231dc93c645ce84de  uoft-cs/cifar10/plain_text/test-00000-of-00001.parquet
98776c529bb146a9c791229df74a5cf076be9b43d82dbbd334b6a7788d73dc68  uoft-cs/cifar100/cifar100/test-00000-of-00001.parquet
ba6abd25209b04b5f69f39648bc54890fe8fa6ef947a5117ff1f1d6f9b28e17e  TSK26B_REAL_CNN_VALIDATION/data/cifar10_test100.pt
943dcbe94f935a41d2a01e9c09bb22bcf61363611671d890eb439f636df97a12  TSK26B_REAL_CNN_VALIDATION/data/cifar100_test100.pt
```
