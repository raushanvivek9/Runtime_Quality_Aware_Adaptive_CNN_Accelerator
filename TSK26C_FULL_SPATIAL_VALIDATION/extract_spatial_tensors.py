#!/usr/bin/env python3
"""
extract_spatial_tensors.py
Profiles and extracts real CNN tensors for TSK-26C:
1. Deep Layer: VGG-16-BN CIFAR-10 features.37 (2x2 spatial grid = 100% full spatial coverage)
2. Middle Layer: VGG-16-BN CIFAR-10 features.14 (8x8 spatial grid, corner/center positions)
3. Early Layer: ResNet-18 CIFAR-10 layer1.0.conv1 (32x32 spatial grid, boundary/interior positions)
4. Sequential Layers: ResNet-18 CIFAR-10 layer1.0.conv1 -> layer1.0.conv2 chained execution
"""

import os
import sys
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
TSK26B_DIR = os.path.join(REPO_ROOT, "TSK26B_REAL_CNN_VALIDATION")
MODELS_DIR = os.path.join(TSK26B_DIR, "models")
DATA_DIR = os.path.join(TSK26B_DIR, "data")
TENSORS_DIR = os.path.join(SCRIPT_DIR, "tensors")
os.makedirs(TENSORS_DIR, exist_ok=True)

SCALE_FP_TO_INT16 = 4096.0

def float_to_q4_12_int16(arr):
    scaled = np.round(arr * SCALE_FP_TO_INT16)
    clipped = np.clip(scaled, -32768, 32767)
    return clipped.astype(np.int16)

def q4_12_int16_to_float(arr):
    return arr.astype(np.float64) / SCALE_FP_TO_INT16

def extract_im2col_patch(input_tensor_3d, y, x, kh=3, kw=3, padding=1):
    """
    Extracts receptive field patch of shape (Cin * kh * kw,) for spatial position (y, x).
    input_tensor_3d: (Cin, H, W)
    """
    Cin, H, W = input_tensor_3d.shape
    padded = np.pad(input_tensor_3d, ((0, 0), (padding, padding), (padding, padding)), mode='constant')
    # Window in padded coords: y to y+kh, x to x+kw
    patch = padded[:, y:y+kh, x:x+kw] # (Cin, kh, kw)
    return patch.flatten()

def main():
    print("=" * 80)
    print(" TSK-26C: REAL CNN TENSOR EXTRACTION FOR FULL SPATIAL & MULTI-LAYER")
    print("=" * 80)

    # 1. Load test samples
    c10_data = torch.load(os.path.join(DATA_DIR, "cifar10_test100.pt"), weights_only=True)
    images_c10 = c10_data['images'] # (100, 3, 32, 32)
    sample_img = images_c10[0:1] # First deterministic test sample

    import torchvision.models as models

    # 2. Load ResNet-18 on CIFAR-10
    print("\n[Step 1] Loading ResNet-18 CIFAR-10 model...")
    r18_path = os.path.join(MODELS_DIR, "resnet18_cifar10.pt")
    r18_model = models.resnet18(num_classes=10)
    r18_model.conv1 = nn.Conv2d(3, 64, kernel_size=3, stride=1, padding=1, bias=False)
    r18_model.maxpool = nn.Identity()
    r18_model.load_state_dict(torch.load(r18_path, weights_only=True))
    r18_model.eval()

    # 3. Load VGG-16-BN on CIFAR-10
    print("\n[Step 2] Loading VGG-16-BN CIFAR-10 model...")
    vgg_path = os.path.join(MODELS_DIR, "vgg16_cifar10.pt")
    vgg_model = torch.hub.load("chenyaofo/pytorch-cifar-models", "cifar10_vgg16_bn", pretrained=False)
    vgg_model.load_state_dict(torch.load(vgg_path, weights_only=True))
    vgg_model.eval()

    # -------------------------------------------------------------------------
    # Workload 1: Deep Layer Full Spatial Feature Map (VGG-16 features.37)
    # Output spatial dimensions: 2x2 = 4 positions total: (0,0), (0,1), (1,0), (1,1)
    # ROWS=4 rows computes ALL 4 SPATIAL POSITIONS SIMULTANEOUSLY!
    # -------------------------------------------------------------------------
    print("\n[Step 3] Extracting Deep Layer (VGG-16 features.37: 2x2 spatial grid, 100% spatial coverage)...")
    vgg_activations = {}
    def hook_vgg(name):
        def fn(module, inp, out):
            vgg_activations[name + "_in"] = inp[0].detach()
            vgg_activations[name + "_out"] = out.detach()
        return fn

    h37 = vgg_model.features[37].register_forward_hook(hook_vgg("feat37"))
    h14 = vgg_model.features[14].register_forward_hook(hook_vgg("feat14"))
    with torch.no_grad():
        _ = vgg_model(sample_img)
    h37.remove()
    h14.remove()

    feat37_in = vgg_activations["feat37_in"][0].cpu().numpy() # (512, 2, 2)
    feat37_weight = vgg_model.features[37].weight.detach().cpu().numpy() # (512, 512, 3, 3)
    feat37_bias = vgg_model.features[37].bias.detach().cpu().numpy() if vgg_model.features[37].bias is not None else None

    # Slice Cin=64 channels to fit K=576 in Buffer A, and Cout=16
    cin_slice = 64
    cout_slice = 16
    feat37_in_slice = feat37_in[:cin_slice, :, :] # (64, 2, 2)
    feat37_wt_slice = feat37_weight[:cout_slice, :cin_slice, :, :] # (16, 64, 3, 3)

    # Flatten weights to (16, 576)
    feat37_wt_flat = feat37_wt_slice.reshape(cout_slice, -1) # (16, 576)

    # Extract all 4 spatial positions: (0,0), (0,1), (1,0), (1,1)
    spatial_coords_deep = [(0, 0), (0, 1), (1, 0), (1, 1)]
    deep_patches = np.zeros((4, cin_slice * 9), dtype=np.float32)
    for r, (y, x) in enumerate(spatial_coords_deep):
        deep_patches[r, :] = extract_im2col_patch(feat37_in_slice, y, x, kh=3, kw=3, padding=1)

    deep_patches_int16 = float_to_q4_12_int16(deep_patches)
    deep_wt_int16 = float_to_q4_12_int16(feat37_wt_flat)

    np.save(os.path.join(TENSORS_DIR, "deep_patches_int16.npy"), deep_patches_int16)
    np.save(os.path.join(TENSORS_DIR, "deep_wt_int16.npy"), deep_wt_int16)
    print(f"  [PASS] Deep layer: 4 spatial positions extracted (100% of 2x2 grid), shape: {deep_patches_int16.shape}")

    # -------------------------------------------------------------------------
    # Workload 2: Middle Layer (VGG-16 features.14: 8x8 spatial grid)
    # Extract 4 representative spatial positions:
    # Row 0: Top-Left (0, 0)
    # Row 1: Top-Right (0, 7)
    # Row 2: Center (3, 4)
    # Row 3: Bottom-Right (7, 7)
    # -------------------------------------------------------------------------
    print("\n[Step 4] Extracting Middle Layer (VGG-16 features.14: 8x8 spatial grid)...")
    feat14_in = vgg_activations["feat14_in"][0].cpu().numpy() # (128, 8, 8)
    feat14_weight = vgg_model.features[14].weight.detach().cpu().numpy() # (256, 128, 3, 3)
    feat14_in_slice = feat14_in[:cin_slice, :, :] # (64, 8, 8)
    feat14_wt_slice = feat14_weight[:cout_slice, :cin_slice, :, :] # (16, 64, 3, 3)
    feat14_wt_flat = feat14_wt_slice.reshape(cout_slice, -1) # (16, 576)

    spatial_coords_mid = [(0, 0), (0, 7), (3, 4), (7, 7)]
    mid_patches = np.zeros((4, cin_slice * 9), dtype=np.float32)
    for r, (y, x) in enumerate(spatial_coords_mid):
        mid_patches[r, :] = extract_im2col_patch(feat14_in_slice, y, x, kh=3, kw=3, padding=1)

    mid_patches_int16 = float_to_q4_12_int16(mid_patches)
    mid_wt_int16 = float_to_q4_12_int16(feat14_wt_flat)

    np.save(os.path.join(TENSORS_DIR, "mid_patches_int16.npy"), mid_patches_int16)
    np.save(os.path.join(TENSORS_DIR, "mid_wt_int16.npy"), mid_wt_int16)
    print(f"  [PASS] Middle layer: 4 spatial positions extracted (corners + center of 8x8 grid), shape: {mid_patches_int16.shape}")

    # -------------------------------------------------------------------------
    # Workload 3: Early Layer (ResNet-18 layer1.0.conv1: 32x32 spatial grid)
    # Extract 4 representative spatial positions:
    # Row 0: Top-Left (0, 0)
    # Row 1: Top-Right (0, 31)
    # Row 2: Center (15, 15)
    # Row 3: Bottom-Right (31, 31)
    # -------------------------------------------------------------------------
    print("\n[Step 5] Extracting Early Layer (ResNet-18 layer1.0.conv1: 32x32 spatial grid)...")
    r18_activations = {}
    def hook_r18(name):
        def fn(module, inp, out):
            r18_activations[name + "_in"] = inp[0].detach()
            r18_activations[name + "_out"] = out.detach()
        return fn

    hc1 = r18_model.layer1[0].conv1.register_forward_hook(hook_r18("l1_conv1"))
    hc2 = r18_model.layer1[0].conv2.register_forward_hook(hook_r18("l1_conv2"))
    with torch.no_grad():
        _ = r18_model(sample_img)
    hc1.remove()
    hc2.remove()

    l1_c1_in = r18_activations["l1_conv1_in"][0].cpu().numpy() # (64, 32, 32)
    l1_c1_wt = r18_model.layer1[0].conv1.weight.detach().cpu().numpy() # (64, 64, 3, 3)
    l1_c1_wt_slice = l1_c1_wt[:cout_slice, :, :, :] # (16, 64, 3, 3)
    l1_c1_wt_flat = l1_c1_wt_slice.reshape(cout_slice, -1) # (16, 576)

    spatial_coords_early = [(0, 0), (0, 31), (15, 15), (31, 31)]
    early_patches = np.zeros((4, cin_slice * 9), dtype=np.float32)
    for r, (y, x) in enumerate(spatial_coords_early):
        early_patches[r, :] = extract_im2col_patch(l1_c1_in, y, x, kh=3, kw=3, padding=1)

    early_patches_int16 = float_to_q4_12_int16(early_patches)
    early_wt_int16 = float_to_q4_12_int16(l1_c1_wt_flat)

    np.save(os.path.join(TENSORS_DIR, "early_patches_int16.npy"), early_patches_int16)
    np.save(os.path.join(TENSORS_DIR, "early_wt_int16.npy"), early_wt_int16)
    print(f"  [PASS] Early layer: 4 spatial positions extracted (boundary + interior of 32x32 grid), shape: {early_patches_int16.shape}")

    # -------------------------------------------------------------------------
    # Workload 4: Sequential Chained Execution (layer1.0.conv1 -> layer1.0.conv2)
    # Layer 1 produces outputs. Requantization unit requantizes them.
    # Layer 2 consumes the requantized activations!
    # We select 4 consecutive spatial positions (y=10, x in 10..13)
    # -------------------------------------------------------------------------
    print("\n[Step 6] Extracting Sequential Chained Layers (layer1.0.conv1 -> layer1.0.conv2)...")
    chain_spatial_coords = [(10, 10), (10, 11), (10, 12), (10, 13)]

    # Layer 1 patches
    chain_c1_patches = np.zeros((4, cin_slice * 9), dtype=np.float32)
    for r, (y, x) in enumerate(chain_spatial_coords):
        chain_c1_patches[r, :] = extract_im2col_patch(l1_c1_in, y, x, kh=3, kw=3, padding=1)
    chain_c1_patches_int16 = float_to_q4_12_int16(chain_c1_patches)
    chain_c1_wt_int16 = float_to_q4_12_int16(l1_c1_wt_flat)

    # Layer 2 weights: layer1.0.conv2 (64, 64, 3, 3)
    l1_c2_wt = r18_model.layer1[0].conv2.weight.detach().cpu().numpy()
    l1_c2_wt_slice = l1_c2_wt[:cout_slice, :, :, :] # (16, 64, 3, 3)
    l1_c2_wt_flat = l1_c2_wt_slice.reshape(cout_slice, -1) # (16, 576)
    chain_c2_wt_int16 = float_to_q4_12_int16(l1_c2_wt_flat)

    # Full Layer 1 output from PyTorch for golden reference
    l1_c1_out_pyt = r18_activations["l1_conv1_out"][0].cpu().numpy() # (64, 32, 32)
    # Requantized Layer 1 output: ReLU(l1_c1_out)
    l1_relu_out_pyt = np.maximum(l1_c1_out_pyt, 0.0) # (64, 32, 32)
    l1_relu_out_int16 = float_to_q4_12_int16(l1_relu_out_pyt)

    # Layer 2 input patches extracted from the requantized Layer 1 output
    chain_c2_patches_int16 = np.zeros((4, cin_slice * 9), dtype=np.int16)
    for r, (y, x) in enumerate(chain_spatial_coords):
        # Using the int16 version of layer 1's post-relu output
        chain_c2_patches_int16[r, :] = extract_im2col_patch(l1_relu_out_int16, y, x, kh=3, kw=3, padding=1)

    np.save(os.path.join(TENSORS_DIR, "chain_c1_patches_int16.npy"), chain_c1_patches_int16)
    np.save(os.path.join(TENSORS_DIR, "chain_c1_wt_int16.npy"), chain_c1_wt_int16)
    np.save(os.path.join(TENSORS_DIR, "chain_c2_patches_int16.npy"), chain_c2_patches_int16)
    np.save(os.path.join(TENSORS_DIR, "chain_c2_wt_int16.npy"), chain_c2_wt_int16)
    np.save(os.path.join(TENSORS_DIR, "chain_l1_relu_out_int16.npy"), l1_relu_out_int16)

    print(f"  [PASS] Chained layers prepared. Layer 1 patches: {chain_c1_patches_int16.shape}, Layer 2 patches: {chain_c2_patches_int16.shape}")

    print("\n" + "=" * 80)
    print(" ALL SPATIAL TENSORS SUCCESSFULLY EXTRACTED & SAVED TO tensors/")
    print("=" * 80)

if __name__ == "__main__":
    main()
