#!/usr/bin/env python3
from huggingface_hub import HfApi
api = HfApi()

print("uoft-cs/cifar10 files:")
for f in api.list_repo_files("uoft-cs/cifar10", repo_type="dataset"):
    print(" ", f)

print("\nuoft-cs/cifar100 files:")
for f in api.list_repo_files("uoft-cs/cifar100", repo_type="dataset"):
    print(" ", f)

