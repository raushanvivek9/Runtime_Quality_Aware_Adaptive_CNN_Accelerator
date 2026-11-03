import numpy as np
import os

repo_root = "/mnt/e/MTech/LanChain/MTP"
hex_path = os.path.join(repo_root, "TSK28_COMPLETE_CONVOLUTION_VALIDATION/tensors/act_data.hex")

with open(hex_path, "r") as f:
    lines = [line.strip() for line in f if line.strip()]

vals = [int(x, 16) for x in lines]
# Sign extend to int16
signed_vals = [(v - 65536 if v >= 32768 else v) for v in vals]
arr = np.array(signed_vals, dtype=np.int16)

total_count = len(arr)
zero_count = np.sum(arr == 0)
sparsity_pct = (zero_count / total_count) * 100.0

print(f"Total activation words: {total_count}")
print(f"Zero activation words:  {zero_count}")
print(f"Non-zero words:         {total_count - zero_count}")
print(f"Activation Sparsity:    {sparsity_pct:.2f}%")

