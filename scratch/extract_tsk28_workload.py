#!/usr/bin/env python3
"""
extract_tsk28_workload.py
Extracts real ResNet-18 layer1.0.conv1 tensors and generates deterministic
golden reference outputs for TSK-28 Complete Convolution Layer Validation.
"""

import os
import sys
import numpy as np
import torch
import torch.nn as nn
import torchvision.models as models

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = "/mnt/e/MTech/LanChain/MTP"
TSK26B_DIR = os.path.join(REPO_ROOT, "TSK26B_REAL_CNN_VALIDATION")
MODELS_DIR = os.path.join(TSK26B_DIR, "models")
DATA_DIR = os.path.join(TSK26B_DIR, "data")
OUT_DIR = os.path.join(REPO_ROOT, "TSK28_COMPLETE_CONVOLUTION_VALIDATION")
os.makedirs(OUT_DIR, exist_ok=True)
TENSORS_DIR = os.path.join(OUT_DIR, "tensors")
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
    Extracts receptive field patch of shape (Cin, kh, kw) for position (y, x).
    input_tensor_3d: (Cin, H, W)
    """
    Cin, H, W = input_tensor_3d.shape
    padded = np.pad(input_tensor_3d, ((0, 0), (padding, padding), (padding, padding)), mode='constant')
    patch = padded[:, y:y+kh, x:x+kw] # (Cin, kh, kw)
    return patch

def main():
    print("=" * 80)
    print(" TSK-28: EXTRACTING COMPLETE CONVOLUTION WORKLOAD (ResNet-18 layer1.0.conv1)")
    print("=" * 80)

    # 1. Load test dataset
    c10_data = torch.load(os.path.join(DATA_DIR, "cifar10_test100.pt"), map_location="cpu", weights_only=True)
    images_c10 = c10_data['images'] # (100, 3, 32, 32)
    sample_img = images_c10[0:1] # First deterministic test sample

    # 2. Load ResNet-18 CIFAR-10 model
    r18_path = os.path.join(MODELS_DIR, "resnet18_cifar10.pt")
    r18_model = models.resnet18(num_classes=10)
    r18_model.conv1 = nn.Conv2d(3, 64, kernel_size=3, stride=1, padding=1, bias=False)
    r18_model.maxpool = nn.Identity()
    r18_model.load_state_dict(torch.load(r18_path, map_location="cpu", weights_only=True))
    r18_model.eval()

    # Hook conv1 output (input to layer1.0.conv1)
    activations = {}
    def hook_fn(name):
        def fn(module, inp, out):
            activations[name] = out.detach()
        return fn

    # conv1 -> bn1 -> relu -> layer1.0.conv1
    h_relu = r18_model.relu.register_forward_hook(hook_fn("relu_out"))
    h_conv1 = r18_model.layer1[0].conv1.register_forward_hook(hook_fn("l1_c1_out"))
    with torch.no_grad():
        _ = r18_model(sample_img)
    h_relu.remove()
    h_conv1.remove()

    l1_c1_in_fp = activations["relu_out"][0].cpu().numpy() # (64, 32, 32)
    l1_c1_out_fp = activations["l1_c1_out"][0].cpu().numpy() # (64, 32, 32)
    l1_c1_wt_fp = r18_model.layer1[0].conv1.weight.detach().cpu().numpy() # (64, 64, 3, 3)

    print(f"Layer input shape:  {l1_c1_in_fp.shape}")
    print(f"Layer weight shape: {l1_c1_wt_fp.shape}")
    print(f"Layer output shape: {l1_c1_out_fp.shape}")

    # Configuration for manageable complete convolution:
    # Grid: 4x4 spatial positions (16 positions)
    # Output channels: 16 channels (Cout = 16)
    # Input channels: 64 channels (Cin = 64)
    # Kernel: 3x3 (Kh = 3, Kw = 3)
    # Reduction depth: K = 3 * 3 * 64 = 576 terms per output activation
    # Total output elements: 16 * 16 = 256
    GRID_H = 4
    GRID_W = 4
    COUT = 16
    CIN = 64
    KH = 3
    KW = 3
    K_TOTAL = KH * KW * CIN # 576
    TOTAL_CHUNKS = 9
    K_PER_CHUNK = 64 # 64 channels per chunk

    wt_slice_fp = l1_c1_wt_fp[:COUT, :CIN, :, :] # (16, 64, 3, 3)
    wt_slice_int16 = float_to_q4_12_int16(wt_slice_fp) # (16, 64, 3, 3)

    # Convert entire input feature map to Q4.12 int16
    l1_c1_in_int16 = float_to_q4_12_int16(l1_c1_in_fp) # (64, 32, 32)

    # Extract 4x4 spatial patches and compute bit-exact golden reference
    # Coordinates: y in [0..3], x in [0..3]
    spatial_coords = []
    for y in range(GRID_H):
        for x in range(GRID_W):
            spatial_coords.append((y, x))

    print(f"\nEvaluating complete 4x4 spatial grid ({len(spatial_coords)} positions) x {COUT} output channels...")
    print(f"Reduction terms per element: K = {K_TOTAL} (9 chunks x 64 channels)")
    print(f"Total output elements: {len(spatial_coords) * COUT}")
    print(f"Total MAC operations: {len(spatial_coords) * COUT * K_TOTAL}")

    # Prepare arrays:
    # Act patches: shape (16_positions, 9_chunks, 64_channels)
    act_chunks_int16 = np.zeros((len(spatial_coords), TOTAL_CHUNKS, K_PER_CHUNK), dtype=np.int16)
    # Weight chunks: shape (16_channels, 9_chunks, 64_channels)
    wt_chunks_int16 = np.zeros((COUT, TOTAL_CHUNKS, K_PER_CHUNK), dtype=np.int16)

    # Populate weight chunks:
    # Chunk index c = ky * 3 + kx, where ky in [0..2], kx in [0..2]
    for oc in range(COUT):
        for ky in range(KH):
            for kx in range(KW):
                chunk_idx = ky * KW + kx
                wt_chunks_int16[oc, chunk_idx, :] = wt_slice_int16[oc, :, ky, kx]

    # Populate activation chunks and compute golden outputs
    gold_accum_40b = np.zeros((len(spatial_coords), COUT), dtype=np.int64)
    gold_fp32_conv = np.zeros((len(spatial_coords), COUT), dtype=np.float32)

    for p_idx, (y, x) in enumerate(spatial_coords):
        patch = extract_im2col_patch(l1_c1_in_int16, y, x, kh=KH, kw=KW, padding=1) # (64, 3, 3)
        for ky in range(KH):
            for kx in range(KW):
                chunk_idx = ky * KW + kx
                act_chunks_int16[p_idx, chunk_idx, :] = patch[:, ky, kx]

        # Bit-exact integer simulation of MAC hardware
        for oc in range(COUT):
            accum = np.int64(0)
            for chunk_idx in range(TOTAL_CHUNKS):
                for k in range(K_PER_CHUNK):
                    a = np.int64(act_chunks_int16[p_idx, chunk_idx, k])
                    w = np.int64(wt_chunks_int16[oc, chunk_idx, k])
                    prod = a * w # 32-bit product
                    accum += prod # 40-bit accumulation
            gold_accum_40b[p_idx, oc] = accum

        # PyTorch FP32 golden reference for comparison
        for oc in range(COUT):
            gold_fp32_conv[p_idx, oc] = l1_c1_out_fp[oc, y, x]

    # Requantized golden output: scale >> 12, saturate to INT16
    # Note: Q4.12 * Q4.12 = Q8.24. Scale by 2^-12 -> Q8.12.
    gold_requant_int16 = np.clip(np.round(gold_accum_40b.astype(np.float64) / 4096.0), -32768, 32767).astype(np.int16)
    gold_relu_int16 = np.maximum(gold_requant_int16, 0)

    # Save tensors to .npy and .hex
    np.save(os.path.join(TENSORS_DIR, "act_chunks_int16.npy"), act_chunks_int16)
    np.save(os.path.join(TENSORS_DIR, "wt_chunks_int16.npy"), wt_chunks_int16)
    np.save(os.path.join(TENSORS_DIR, "gold_accum_40b.npy"), gold_accum_40b)
    np.save(os.path.join(TENSORS_DIR, "gold_requant_int16.npy"), gold_requant_int16)
    np.save(os.path.join(TENSORS_DIR, "gold_fp32_conv.npy"), gold_fp32_conv)

    # Export hex files for Verilog $readmemh
    # 1. Activation memory: (16 positions * 9 chunks * 64 channels = 9216 words of 16-bit)
    with open(os.path.join(TENSORS_DIR, "act_data.hex"), "w") as f:
        for p in range(len(spatial_coords)):
            for c in range(TOTAL_CHUNKS):
                for k in range(K_PER_CHUNK):
                    val = int(act_chunks_int16[p, c, k]) & 0xFFFF
                    f.write(f"{val:04x}\n")

    # 2. Weight memory: (16 channels * 9 chunks * 64 channels = 9216 words of 16-bit)
    with open(os.path.join(TENSORS_DIR, "wt_data.hex"), "w") as f:
        for oc in range(COUT):
            for c in range(TOTAL_CHUNKS):
                for k in range(K_PER_CHUNK):
                    val = int(wt_chunks_int16[oc, c, k]) & 0xFFFF
                    f.write(f"{val:04x}\n")

    # 3. Golden accumulators: (16 positions * 16 channels = 256 words of 40-bit)
    with open(os.path.join(TENSORS_DIR, "gold_accum.hex"), "w") as f:
        for p in range(len(spatial_coords)):
            for oc in range(COUT):
                val = int(gold_accum_40b[p, oc]) & 0xFFFFFFFFFF
                f.write(f"{val:010x}\n")

    # 4. Golden requant: (16 positions * 16 channels = 256 words of 16-bit)
    with open(os.path.join(TENSORS_DIR, "gold_requant.hex"), "w") as f:
        for p in range(len(spatial_coords)):
            for oc in range(COUT):
                val = int(gold_requant_int16[p, oc]) & 0xFFFF
                f.write(f"{val:04x}\n")

    # Also export CSV summary of golden reference
    import pandas as pd
    records = []
    for p, (y, x) in enumerate(spatial_coords):
        for oc in range(COUT):
            acc = int(gold_accum_40b[p, oc])
            req = int(gold_requant_int16[p, oc])
            relu = int(gold_relu_int16[p, oc])
            pyt = float(gold_fp32_conv[p, oc])
            sim_float = acc / (4096.0 * 4096.0)
            diff = abs(sim_float - pyt)
            records.append({
                "pos_idx": p,
                "y": y,
                "x": x,
                "cout_idx": oc,
                "accum_40b": acc,
                "requant_int16": req,
                "relu_int16": relu,
                "pyt_float32": pyt,
                "fixed_point_float": sim_float,
                "abs_diff_vs_pyt": diff
            })
    df = pd.DataFrame(records)
    csv_path = os.path.join(OUT_DIR, "SOFTWARE_REFERENCE_PREDICTIONS.csv")
    df.to_csv(csv_path, index=False)

    print(f"\n[PASS] Workload extracted successfully!")
    print(f"  Activation hex: {os.path.join(TENSORS_DIR, 'act_data.hex')} ({len(spatial_coords) * TOTAL_CHUNKS * K_PER_CHUNK} words)")
    print(f"  Weight hex:     {os.path.join(TENSORS_DIR, 'wt_data.hex')} ({COUT * TOTAL_CHUNKS * K_PER_CHUNK} words)")
    print(f"  Golden hex:     {os.path.join(TENSORS_DIR, 'gold_accum.hex')} ({len(spatial_coords) * COUT} words)")
    print(f"  CSV manifest:   {csv_path}")

    # Check SQNR between fixed-point and PyTorch float
    signal_pow = np.mean(df['pyt_float32']**2)
    noise_pow = np.mean(df['abs_diff_vs_pyt']**2)
    sqnr = 10 * np.log10(signal_pow / noise_pow) if noise_pow > 0 else 999.0
    print(f"  Fixed-point Q4.12 vs PyTorch FP32 SQNR: {sqnr:.2f} dB (Max diff: {df['abs_diff_vs_pyt'].max():.6f})")

if __name__ == "__main__":
    main()

