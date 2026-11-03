#!/usr/bin/env python3
"""
Test CIFAR dataset download and Torch Hub checkpoint availability.
"""
import os
import sys
import torch
import torchvision
import torchvision.transforms as transforms

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
os.makedirs(DATA_DIR, exist_ok=True)

print("PyTorch version:", torch.__version__)
print("Torchvision version:", torchvision.__version__)

# Test CIFAR-10
print("\n--- Checking CIFAR-10 Test Set ---")
try:
    cifar10_test = torchvision.datasets.CIFAR10(
        root=DATA_DIR, train=False, download=True,
        transform=transforms.ToTensor()
    )
    print(f"[SUCCESS] CIFAR-10 Test Set ready. Total samples: {len(cifar10_test)}")
except Exception as e:
    print(f"[ERROR] Failed to download/load CIFAR-10: {e}")

# Test CIFAR-100
print("\n--- Checking CIFAR-100 Test Set ---")
try:
    cifar100_test = torchvision.datasets.CIFAR100(
        root=DATA_DIR, train=False, download=True,
        transform=transforms.ToTensor()
    )
    print(f"[SUCCESS] CIFAR-100 Test Set ready. Total samples: {len(cifar100_test)}")
except Exception as e:
    print(f"[ERROR] Failed to download/load CIFAR-100: {e}")

