#!/usr/bin/env python3
from huggingface_hub import HfApi
api = HfApi()

print("Searching datasets on HuggingFace for cifar10...")
datasets = list(api.list_datasets(search="cifar10", limit=5))
for d in datasets:
    print(d.id)

