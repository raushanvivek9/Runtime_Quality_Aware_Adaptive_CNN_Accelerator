#!/usr/bin/env python3
import torch
print("Testing torch hub with trust_repo=True...")
try:
    m = torch.hub.load("huyvnphan/PyTorch_CIFAR10", "cifar10_resnet18", pretrained=True, trust_repo=True)
    print("[SUCCESS] Loaded huyvnphan cifar10_resnet18 successfully!")
    print("Conv1 shape:", m.conv1.weight.shape)
    print("Number of parameters:", sum(p.numel() for p in m.parameters()))
except Exception as e:
    print(f"[ERROR] {e}")
