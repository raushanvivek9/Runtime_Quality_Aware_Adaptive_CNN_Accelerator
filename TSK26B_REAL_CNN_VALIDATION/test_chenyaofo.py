#!/usr/bin/env python3
import torch
print("Testing chenyaofo/pytorch-cifar-models...")
try:
    m = torch.hub.load("chenyaofo/pytorch-cifar-models", "cifar10_vgg16_bn", pretrained=True, trust_repo=True)
    print("[SUCCESS] Loaded chenyaofo cifar10_vgg16_bn!")
    print(m)
except Exception as e:
    print(f"[ERROR] {e}")

