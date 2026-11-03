import os
import torch

mod_dir = "/mnt/e/MTech/LanChain/MTP/TSK26B_REAL_CNN_VALIDATION/models"
print("Models in dir:", os.listdir(mod_dir))

for fname in os.listdir(mod_dir):
    if fname.endswith(".pt"):
        fpath = os.path.join(mod_dir, fname)
        print("\n---", fname, "---")
        sd = torch.load(fpath, map_location="cpu", weights_only=False)
        if isinstance(sd, dict):
            for k, v in list(sd.items())[:15]:
                if hasattr(v, "shape"):
                    print(f"  {k}: {v.shape}")
                else:
                    print(f"  {k}: {type(v)}")

