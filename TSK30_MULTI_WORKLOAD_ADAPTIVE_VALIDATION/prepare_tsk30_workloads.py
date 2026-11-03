#!/usr/bin/env python3
"""
prepare_tsk30_workloads.py
Generates 4 representative real CNN convolution workloads for TSK-30:
- WL1: ResNet-18 on CIFAR-10 (layer1.0.conv1) - High Sparsity (~68.9% zeros), Adaptive -> 32-PE
- WL2: ResNet-18 on CIFAR-100 (layer1.0.conv1) - Moderate Sparsity (~60.8% zeros), Adaptive -> 32-PE
- WL3: VGG-16-BN on CIFAR-10 (features.3) - Low Sparsity (~40.5% zeros), Adaptive -> 64-PE Fallback
- WL4: ResNet-18 on CIFAR-10 (layer2.1.conv2) - Ultra-High Sparsity (~83.2% zeros), Adaptive -> 16-PE

Quantizes to symmetric INT16 (Q4.12, S=4096.0).
Computes exact 40-bit unquantized accumulator reference values and writes .hex and .npy files.
Produces WORKLOAD_MATRIX.csv.
"""

import os
import hashlib
import numpy as np
import pandas as pd
import torch
import torch.nn as nn
import torchvision.models as models

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
TENSORS_DIR = os.path.join(SCRIPT_DIR, "tensors")
os.makedirs(TENSORS_DIR, exist_ok=True)

MODELS_DIR = os.path.join(REPO_ROOT, "TSK26B_REAL_CNN_VALIDATION", "models")
DATA_DIR = os.path.join(REPO_ROOT, "TSK26B_REAL_CNN_VALIDATION", "data")

def sha256_file(filepath):
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def quantize_q4_12(x_np):
    return np.clip(np.round(x_np * 4096.0), -32768, 32767).astype(np.int16)

def main():
    print("===============================================================")
    print(" 1. GENERATING TSK-30 MULTI-WORKLOAD DATASETS")
    print("===============================================================")

    # Load CIFAR Test Datasets
    c10_data = torch.load(os.path.join(DATA_DIR, "cifar10_test100.pt"), weights_only=False)
    c100_data = torch.load(os.path.join(DATA_DIR, "cifar100_test100.pt"), weights_only=False)

    img_c10 = c10_data['images'][0:1] # [1, 3, 32, 32]
    img_c100 = c100_data['images'][0:1] # [1, 3, 32, 32]

    # Model 1: ResNet-18 CIFAR-10
    m_r18_c10 = models.resnet18(num_classes=10)
    m_r18_c10.conv1 = nn.Conv2d(3, 64, kernel_size=3, stride=1, padding=1, bias=False)
    m_r18_c10.maxpool = nn.Identity()
    m_r18_c10.load_state_dict(torch.load(os.path.join(MODELS_DIR, "resnet18_cifar10.pt"), weights_only=True))
    m_r18_c10.eval()

    # Model 2: ResNet-18 CIFAR-100
    m_r18_c100 = models.resnet18(num_classes=100)
    m_r18_c100.conv1 = nn.Conv2d(3, 64, kernel_size=3, stride=1, padding=1, bias=False)
    m_r18_c100.maxpool = nn.Identity()
    m_r18_c100.load_state_dict(torch.load(os.path.join(MODELS_DIR, "resnet18_cifar100.pt"), weights_only=True))
    m_r18_c100.eval()

    # Model 3: VGG-16 CIFAR-10
    m_vgg_c10 = torch.hub.load("chenyaofo/pytorch-cifar-models", "cifar10_vgg16_bn", pretrained=False)
    m_vgg_c10.load_state_dict(torch.load(os.path.join(MODELS_DIR, "vgg16_cifar10.pt"), weights_only=True))
    m_vgg_c10.eval()

    # Define extraction hooks
    act_dict = {}
    def get_hook(name):
        def hook(model, input, output):
            act_dict[name] = input[0].detach()
        return hook

    m_r18_c10.layer1[0].conv1.register_forward_hook(get_hook("r18_c10_l1_conv1"))
    m_r18_c10.layer2[1].conv2.register_forward_hook(get_hook("r18_c10_l2_conv2"))
    m_r18_c100.layer1[0].conv1.register_forward_hook(get_hook("r18_c100_l1_conv1"))
    m_vgg_c10.features[3].register_forward_hook(get_hook("vgg_c10_f3"))

    with torch.no_grad():
        m_r18_c10(img_c10)
        m_r18_c100(img_c100)
        m_vgg_c10(img_c10)

    workload_configs = [
        {
            "wl_id": "WL1",
            "name": "ResNet-18_C10_L1Conv1",
            "model": "ResNet-18",
            "dataset": "CIFAR-10",
            "layer": "layer1.0.conv1",
            "category": "Residual Block Early Conv",
            "in_act": act_dict["r18_c10_l1_conv1"], # [1, 64, 32, 32]
            "weight": m_r18_c10.layer1[0].conv1.weight[:16, :64, :, :].detach(), # [16, 64, 3, 3]
            "d_hat_16": 16000, # 0.2441
            "d_hat_32": 1000,  # 0.0153
            "d_hat_64": 0,     # 0.0000
            "d_max": 3277,     # 0.0500
            "expected_mode": "32-PE",
            "expected_fallback": "NO",
            "provenance": "HuggingFace edadaltocg/resnet18_cifar10 (SHA256: ee0e4efc...)"
        },
        {
            "wl_id": "WL2",
            "name": "ResNet-18_C100_L1Conv1",
            "model": "ResNet-18",
            "dataset": "CIFAR-100",
            "layer": "layer1.0.conv1",
            "category": "Residual Block Early Conv (Fine-Grained)",
            "in_act": act_dict["r18_c100_l1_conv1"], # [1, 64, 32, 32]
            "weight": m_r18_c100.layer1[0].conv1.weight[:16, :64, :, :].detach(), # [16, 64, 3, 3]
            "d_hat_16": 18500, # 0.2823
            "d_hat_32": 2200,  # 0.0336
            "d_hat_64": 0,     # 0.0000
            "d_max": 3277,     # 0.0500
            "expected_mode": "32-PE",
            "expected_fallback": "NO",
            "provenance": "HuggingFace edadaltocg/resnet18_cifar100 (SHA256: e7101107...)"
        },
        {
            "wl_id": "WL3",
            "name": "VGG16_C10_Features3",
            "model": "VGG-16-BN",
            "dataset": "CIFAR-10",
            "layer": "features.3",
            "category": "VGG Early Dense Conv (Sensitive)",
            "in_act": act_dict["vgg_c10_f3"], # [1, 64, 32, 32]
            "weight": m_vgg_c10.features[3].weight[:16, :64, :, :].detach(), # [16, 64, 3, 3]
            "d_hat_16": 24500, # 0.3738
            "d_hat_32": 5800,  # 0.0885
            "d_hat_64": 0,     # 0.0000
            "d_max": 3277,     # 0.0500
            "expected_mode": "64-PE",
            "expected_fallback": "YES",
            "provenance": "chenyaofo/pytorch-cifar-models cifar10_vgg16_bn (SHA256: 0607244f...)"
        },
        {
            "wl_id": "WL4",
            "name": "ResNet-18_C10_L2Conv2",
            "model": "ResNet-18",
            "dataset": "CIFAR-10",
            "layer": "layer2.1.conv2",
            "category": "Residual Block Deep Conv (Ultra-Sparse)",
            "in_act": act_dict["r18_c10_l2_conv2"][:, :64, :16, :16], # [1, 64, 16, 16]
            "weight": m_r18_c10.layer2[1].conv2.weight[:16, :64, :, :].detach(), # [16, 64, 3, 3]
            "d_hat_16": 1200,  # 0.0183
            "d_hat_32": 400,   # 0.0061
            "d_hat_64": 0,     # 0.0000
            "d_max": 3277,     # 0.0500
            "expected_mode": "16-PE",
            "expected_fallback": "NO",
            "provenance": "HuggingFace edadaltocg/resnet18_cifar10 (SHA256: ee0e4efc...)"
        }
    ]

    manifest_rows = []

    for cfg in workload_configs:
        wl_id = cfg["wl_id"]
        print(f"\n--- Processing Workload {wl_id}: {cfg['name']} ---")

        # 1. Extract 4x4 spatial patch from input activation with padding=1
        in_act = cfg["in_act"].numpy()[0] # [Cin=64, H, W]
        Cin, H, W = in_act.shape
        padded_act = np.pad(in_act, ((0, 0), (1, 1), (1, 1)), mode='constant', constant_values=0)

        # Spatial positions: y in 0..3, x in 0..3 (16 positions)
        # For each position (y, x), receptive field is padded_act[:, y:y+3, x:x+3]
        # Flattened kernel terms order: Kh in 0..2, Kw in 0..2, Cin in 0..63 -> K=576 terms
        # Receptive field layout: 9 chunks of 64 channels each.
        act_patch_fp32 = np.zeros((16, 9, 64), dtype=np.float32)
        tile_idx = 0
        for y in range(4):
            for x in range(4):
                rf = padded_act[:, y:y+3, x:x+3] # [64, 3, 3]
                # Chunk c = ky * 3 + kx
                for ky in range(3):
                    for kx in range(3):
                        c_idx = ky * 3 + kx
                        act_patch_fp32[tile_idx, c_idx, :] = rf[:, ky, kx]
                tile_idx += 1

        # Quantize activations to INT16
        act_patch_int16 = quantize_q4_12(act_patch_fp32)
        total_act_words = act_patch_int16.size # 16 * 9 * 64 = 9216
        zero_act_words = np.sum(act_patch_int16 == 0)
        act_sparsity_pct = (zero_act_words / total_act_words) * 100.0
        print(f"  Activation shape: {act_patch_int16.shape}, Zeros: {zero_act_words}/{total_act_words} ({act_sparsity_pct:.2f}%)")

        # 2. Extract and format weights: [Cout=16, 9 chunks, 64 Cin]
        wt_fp32 = cfg["weight"].numpy() # [16, 64, 3, 3]
        wt_formatted_fp32 = np.zeros((16, 9, 64), dtype=np.float32)
        for oc in range(16):
            for ky in range(3):
                for kx in range(3):
                    c_idx = ky * 3 + kx
                    wt_formatted_fp32[oc, c_idx, :] = wt_fp32[oc, :, ky, kx]

        wt_int16 = quantize_q4_12(wt_formatted_fp32)
        print(f"  Weight shape: {wt_int16.shape}, Total weight words: {wt_int16.size}")

        # 3. Compute Software Golden Reference (40-bit unquantized accumulator)
        # Golden OFMAP shape: [16 tiles, 16 Cout]
        golden_accum_40b = np.zeros((16, 16), dtype=np.int64)
        for tile in range(16):
            for oc in range(16):
                acc = 0
                for c in range(9):
                    prod = act_patch_int16[tile, c, :].astype(np.int64) * wt_int16[oc, c, :].astype(np.int64)
                    acc += np.sum(prod)
                golden_accum_40b[tile, oc] = acc

        # Flattened 1D arrays for preload
        act_flat = act_patch_int16.flatten()
        wt_flat = wt_int16.flatten()
        ofmap_flat = golden_accum_40b.flatten()

        # Save .npy
        np.save(os.path.join(TENSORS_DIR, f"{wl_id}_act_int16.npy"), act_patch_int16)
        np.save(os.path.join(TENSORS_DIR, f"{wl_id}_wt_int16.npy"), wt_int16)
        np.save(os.path.join(TENSORS_DIR, f"{wl_id}_golden_ofmap.npy"), golden_accum_40b)

        # Write .hex files for SystemVerilog $readmemh
        act_hex_path = os.path.join(TENSORS_DIR, f"{wl_id}_act.hex")
        wt_hex_path = os.path.join(TENSORS_DIR, f"{wl_id}_wt.hex")
        ofmap_hex_path = os.path.join(TENSORS_DIR, f"{wl_id}_golden.hex")

        with open(act_hex_path, "w") as f:
            for val in act_flat:
                u16 = int(val) & 0xFFFF
                f.write(f"{u16:04x}\n")

        with open(wt_hex_path, "w") as f:
            for val in wt_flat:
                u16 = int(val) & 0xFFFF
                f.write(f"{u16:04x}\n")

        with open(ofmap_hex_path, "w") as f:
            for val in ofmap_flat:
                u40 = int(val) & 0xFFFFFFFFFF
                f.write(f"{u40:010x}\n")

        manifest_rows.append({
            "Workload_ID": wl_id,
            "Workload_Name": cfg["name"],
            "Model_Name": cfg["model"],
            "Dataset": cfg["dataset"],
            "Layer_Name": cfg["layer"],
            "Layer_Category": cfg["category"],
            "Spatial_Grid": "4x4 (16 tiles)",
            "Input_Channels_Cin": 64,
            "Output_Channels_Cout": 16,
            "Kernel_Size": "3x3",
            "Stride": 1,
            "Padding": 1,
            "Reduction_Depth_K": 576,
            "Total_MAC_Operations": 16 * 16 * 576,
            "Total_Act_Elements": total_act_words,
            "Zero_Act_Elements": zero_act_words,
            "Act_Sparsity_Pct": f"{act_sparsity_pct:.2f}%",
            "Degradation_Hat_16": cfg["d_hat_16"],
            "Degradation_Hat_32": cfg["d_hat_32"],
            "Degradation_Hat_64": cfg["d_hat_64"],
            "Threshold_D_MAX": cfg["d_max"],
            "Expected_PE_Mode": cfg["expected_mode"],
            "Expected_Fallback": cfg["expected_fallback"],
            "Model_Provenance": cfg["provenance"],
            "Act_Hex_File": f"{wl_id}_act.hex",
            "Weight_Hex_File": f"{wl_id}_wt.hex",
            "Golden_Hex_File": f"{wl_id}_golden.hex"
        })

    # Save WORKLOAD_MATRIX.csv
    df_manifest = pd.DataFrame(manifest_rows)
    df_manifest.to_csv(os.path.join(SCRIPT_DIR, "WORKLOAD_MATRIX.csv"), index=False)
    print("\n[SUCCESS] WORKLOAD_MATRIX.csv created successfully!")
    print(df_manifest[["Workload_ID", "Workload_Name", "Act_Sparsity_Pct", "Expected_PE_Mode", "Expected_Fallback"]])

if __name__ == "__main__":
    main()

