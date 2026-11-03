#!/usr/bin/env python3
import torch
repo = "chenyaofo/pytorch-cifar-models"
models = torch.hub.list(repo)
print(f"Available models in {repo}:")
for m in models:
    print(" ", m)

