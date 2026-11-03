#!/usr/bin/env python3
import io
import pandas as pd
from huggingface_hub import hf_hub_download
from PIL import Image
import torch
import torchvision.transforms as transforms

print("Downloading test parquet for CIFAR-10...")
f_c10 = hf_hub_download(repo_id="uoft-cs/cifar10", filename="plain_text/test-00000-of-00001.parquet", repo_type="dataset")
df_c10 = pd.read_parquet(f_c10)
print(f"CIFAR-10 test shape: {df_c10.shape}, columns: {df_c10.columns.tolist()}")
row0 = df_c10.iloc[0]
print(f"Sample 0 label: {row0['label']}, img type: {type(row0['img'])}")

# Check PIL image extraction
img_data = row0['img']
if isinstance(img_data, dict) and 'bytes' in img_data:
    img = Image.open(io.BytesIO(img_data['bytes'])).convert('RGB')
elif hasattr(img_data, 'convert'):
    img = img_data.convert('RGB')
else:
    print("img format:", type(img_data))
    img = Image.open(io.BytesIO(img_data)).convert('RGB')
print(f"PIL Image size: {img.size}, mode: {img.mode}")

# Convert to tensor
to_tensor = transforms.ToTensor()
t = to_tensor(img)
print(f"Tensor shape: {t.shape}, min: {t.min().item():.3f}, max: {t.max().item():.3f}")

print("\nDownloading test parquet for CIFAR-100...")
f_c100 = hf_hub_download(repo_id="uoft-cs/cifar100", filename="cifar100/test-00000-of-00001.parquet", repo_type="dataset")
df_c100 = pd.read_parquet(f_c100)
print(f"CIFAR-100 test shape: {df_c100.shape}, columns: {df_c100.columns.tolist()}")
row0_c100 = df_c100.iloc[0]
print(f"Sample 0 label (fine): {row0_c100.get('fine_label', row0_c100.get('label'))}")

print("\n[SUCCESS] Both CIFAR-10 and CIFAR-100 test datasets readable and verified!")

