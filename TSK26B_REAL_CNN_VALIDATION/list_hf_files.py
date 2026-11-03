#!/usr/bin/env python3
from huggingface_hub import HfApi
api = HfApi()
try:
    print("edadaltocg/resnet18_cifar10:", api.list_repo_files("edadaltocg/resnet18_cifar10"))
except Exception as e:
    print("cifar10 err:", e)

try:
    print("edadaltocg/resnet18_cifar100:", api.list_repo_files("edadaltocg/resnet18_cifar100"))
except Exception as e:
    print("cifar100 err:", e)

