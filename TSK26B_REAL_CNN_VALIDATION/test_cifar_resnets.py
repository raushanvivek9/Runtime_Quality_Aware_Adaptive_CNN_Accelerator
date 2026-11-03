#!/usr/bin/env python3
import torch
import torch.nn as nn
from huggingface_hub import hf_hub_download
from safetensors.torch import load_file
import torchvision.models as models

# 1. Test downloading and loading edadaltocg/resnet18_cifar10
print("--- Testing ResNet-18 CIFAR-10 ---")
f_c10 = hf_hub_download(repo_id="edadaltocg/resnet18_cifar10", filename="model.safetensors")
weights_c10 = load_file(f_c10)
print(f"Loaded weights keys: {len(weights_c10)}")
print(f"conv1.weight shape: {weights_c10['conv1.weight'].shape}")
print(f"fc.weight shape: {weights_c10['fc.weight'].shape}")

# Create CIFAR-adapted ResNet18
m_c10 = models.resnet18(num_classes=10)
m_c10.conv1 = nn.Conv2d(3, 64, kernel_size=3, stride=1, padding=1, bias=False)
m_c10.maxpool = nn.Identity()
m_c10.load_state_dict(weights_c10)
m_c10.eval()
print("[SUCCESS] ResNet-18 CIFAR-10 loaded cleanly into adapted model!")

# 2. Test downloading and loading edadaltocg/resnet18_cifar100
print("\n--- Testing ResNet-18 CIFAR-100 ---")
f_c100 = hf_hub_download(repo_id="edadaltocg/resnet18_cifar100", filename="model.safetensors")
weights_c100 = load_file(f_c100)
print(f"Loaded weights keys: {len(weights_c100)}")
print(f"conv1.weight shape: {weights_c100['conv1.weight'].shape}")
print(f"fc.weight shape: {weights_c100['fc.weight'].shape}")

m_c100 = models.resnet18(num_classes=100)
m_c100.conv1 = nn.Conv2d(3, 64, kernel_size=3, stride=1, padding=1, bias=False)
m_c100.maxpool = nn.Identity()
m_c100.load_state_dict(weights_c100)
m_c100.eval()
print("[SUCCESS] ResNet-18 CIFAR-100 loaded cleanly into adapted model!")

