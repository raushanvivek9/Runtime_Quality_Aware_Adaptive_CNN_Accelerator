#!/usr/bin/env python3
"""
extract_cifar_tensors.py
Extracts real activation and weight tensors across early, middle, and deep layers
for ResNet-18 (CIFAR-10, CIFAR-100) and VGG-16 (CIFAR-10, CIFAR-100).
Quantizes to symmetric INT16 (Q4.12: range [-8.0, 7.9998], S=4096.0).
Generates:
- LAYER_COVERAGE.csv
- ACTIVATION_SPARSITY.csv
- TENSOR_MANIFEST.csv
- tensors/*.npy
"""

import os
import hashlib
import numpy as np
import pandas as pd
import torch
import torch.nn as nn
import torchvision.models as models

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MODELS_DIR = os.path.join(SCRIPT_DIR, "models")
DATA_DIR = os.path.join(SCRIPT_DIR, "data")
TENSORS_DIR = os.path.join(SCRIPT_DIR, "tensors")
os.makedirs(TENSORS_DIR, exist_ok=True)

def sha256_file(filepath):
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def quantize_q4_12(x_np):
    """Symmetric INT16 quantization to Q4.12: scale=4096.0, clamp [-32768, 32767]."""
    x_scaled = np.round(x_np * 4096.0)
    return np.clip(x_scaled, -32768, 32767).astype(np.int16)

def dequantize_q4_12(x_int16):
    return x_int16.astype(np.float32) / 4096.0

def main():
    print("=======================================================")
    print(" 1. LOADING DATA AND MODELS")
    print("=======================================================")

    c10_data = torch.load(os.path.join(DATA_DIR, "cifar10_test100.pt"))
    c100_data = torch.load(os.path.join(DATA_DIR, "cifar100_test100.pt"))

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

    # Model 4: VGG-16 CIFAR-100
    m_vgg_c100 = torch.hub.load("chenyaofo/pytorch-cifar-models", "cifar100_vgg16_bn", pretrained=False)
    m_vgg_c100.load_state_dict(torch.load(os.path.join(MODELS_DIR, "vgg16_cifar100.pt"), weights_only=True))
    m_vgg_c100.eval()

    model_configs = [
        ("ResNet-18", "CIFAR-10", m_r18_c10, c10_data['images'][:10]),
        ("ResNet-18", "CIFAR-100", m_r18_c100, c100_data['images'][:10]),
        ("VGG-16-BN", "CIFAR-10", m_vgg_c10, c10_data['images'][:10]),
        ("VGG-16-BN", "CIFAR-100", m_vgg_c100, c100_data['images'][:10]),
    ]

    print("\n=======================================================")
    print(" 2. PROFILING ALL CONV LAYERS & SPARSITY")
    print("=======================================================")

    layer_coverage_rows = []
    sparsity_rows = []

    for model_name, dataset_name, model, test_imgs in model_configs:
        activations = {}
        hooks = []

        def get_hook(name):
            def hook_fn(module, input, output):
                activations[name] = {
                    "input": input[0].detach(),
                    "output": output.detach()
                }
            return hook_fn

        for name, module in model.named_modules():
            if isinstance(module, nn.Conv2d):
                hooks.append(module.register_forward_hook(get_hook(name)))

        with torch.no_grad():
            out = model(test_imgs)

        for h in hooks:
            h.remove()

        # Classify layer depth
        conv_names = [name for name, m in model.named_modules() if isinstance(m, nn.Conv2d)]
        n_conv = len(conv_names)

        for idx, name in enumerate(conv_names):
            module = dict(model.named_modules())[name]
            act = activations[name]
            in_t = act["input"]
            out_t = act["output"]
            w_t = module.weight.detach()

            # Sparsity of output after ReLU (if followed by ReLU or >= 0)
            relu_out = torch.relu(out_t)
            n_elem = relu_out.numel()
            n_zeros = (relu_out == 0).sum().item()
            sparsity_pct = (n_zeros / n_elem) * 100.0

            if idx < n_conv // 3:
                depth_category = "Early"
            elif idx < 2 * (n_conv // 3):
                depth_category = "Middle"
            else:
                depth_category = "Deep"

            # Check RTL compatibility
            # RTL PE array supports Cout up to 64 per tile, 3x3 kernels, Cin up to memory capacity
            is_rtl_tileable = (module.kernel_size == (3, 3) or module.kernel_size == 3)
            
            layer_coverage_rows.append({
                "model_name": model_name,
                "dataset": dataset_name,
                "layer_idx": idx,
                "layer_name": name,
                "depth_category": depth_category,
                "in_channels": module.in_channels,
                "out_channels": module.out_channels,
                "kernel_size": f"{module.kernel_size[0]}x{module.kernel_size[1]}",
                "stride": module.stride[0],
                "padding": module.padding[0],
                "input_shape": list(in_t.shape[1:]),
                "output_shape": list(out_t.shape[1:]),
                "k_reduction_dim": module.in_channels * module.kernel_size[0] * module.kernel_size[1],
                "relu_sparsity_pct": round(sparsity_pct, 2),
                "rtl_compatible": is_rtl_tileable
            })

            sparsity_rows.append({
                "model_name": model_name,
                "dataset": dataset_name,
                "layer_name": name,
                "depth_category": depth_category,
                "total_elements": n_elem,
                "zero_elements": n_zeros,
                "sparsity_percentage": round(sparsity_pct, 2)
            })

    pd.DataFrame(layer_coverage_rows).to_csv(os.path.join(SCRIPT_DIR, "LAYER_COVERAGE.csv"), index=False)
    pd.DataFrame(sparsity_rows).to_csv(os.path.join(SCRIPT_DIR, "ACTIVATION_SPARSITY.csv"), index=False)
    print("Saved LAYER_COVERAGE.csv and ACTIVATION_SPARSITY.csv")

    print("\n=======================================================")
    print(" 3. EXTRACTING PRIMARY HARDWARE RECEPTIVE FIELD PATCHES")
    print("=======================================================")

    # Target Primary Layer across all 4 models:
    # ResNet-18: layer1.0.conv1 (Cin=64, Cout=64, K=3x3, stride=1, padding=1)
    # VGG-16: features.3 (Cin=64, Cout=64, K=3x3, stride=1, padding=1)
    # Both evaluate full K = 64 * 3 * 3 = 576 inner products for 64 output channels!

    target_layers = [
        ("r18_c10", "ResNet-18", "CIFAR-10", m_r18_c10, c10_data['images'][0:1], "layer1.0.conv1"),
        ("r18_c100", "ResNet-18", "CIFAR-100", m_r18_c100, c100_data['images'][0:1], "layer1.0.conv1"),
        ("vgg_c10", "VGG-16-BN", "CIFAR-10", m_vgg_c10, c10_data['images'][0:1], "features.3"),
        ("vgg_c100", "VGG-16-BN", "CIFAR-100", m_vgg_c100, c100_data['images'][0:1], "features.3"),
    ]

    tensor_manifest_rows = []

    for tag, model_name, dataset_name, model, single_img, layer_name in target_layers:
        print(f"\nProcessing {model_name} / {dataset_name} ({layer_name})...")
        activations = {}
        def hook_fn(module, input, output):
            activations["input"] = input[0].detach()
            activations["output"] = output.detach()

        module = dict(model.named_modules())[layer_name]
        h = module.register_forward_hook(hook_fn)
        with torch.no_grad():
            _ = model(single_img)
        h.remove()

        in_fmap = activations["input"][0] # (64, H, W)
        weights = module.weight.detach() # (64, 64, 3, 3)

        # Spatial patch at center position (y=1, x=1) with padding=1:
        # Padded input:
        pad_fmap = nn.functional.pad(in_fmap.unsqueeze(0), (1, 1, 1, 1), mode="constant", value=0.0)[0] # (64, H+2, W+2)
        # Receptive field for output (y=1, x=1) in 1-based padded coordinates: [1:4, 1:4]
        patch_3x3 = pad_fmap[:, 1:4, 1:4] # (64, 3, 3)
        assert patch_3x3.shape == (64, 3, 3), f"Expected (64,3,3), got {patch_3x3.shape}"

        # Flatten into K=576 vector ordered: c_in (0..63), ky (0..2), kx (0..2)
        # Note: In standard convolution: output[c_out] = sum_{c_in, ky, kx} patch[c_in, ky, kx] * weight[c_out, c_in, ky, kx]
        patch_k576 = patch_3x3.numpy().reshape(-1) # shape (576,)
        weights_k576 = weights.numpy().reshape(64, -1) # shape (64, 576)

        # Quantize to Q4.12 INT16
        patch_int16 = quantize_q4_12(patch_k576)
        weights_int16 = quantize_q4_12(weights_k576)

        # Save files
        p_in_fp32 = os.path.join(TENSORS_DIR, f"{tag}_input_patch_fp32.npy")
        p_in_int16 = os.path.join(TENSORS_DIR, f"{tag}_input_patch_int16.npy")
        p_w_fp32 = os.path.join(TENSORS_DIR, f"{tag}_weights_fp32.npy")
        p_w_int16 = os.path.join(TENSORS_DIR, f"{tag}_weights_int16.npy")

        np.save(p_in_fp32, patch_k576)
        np.save(p_in_int16, patch_int16)
        np.save(p_w_fp32, weights_k576)
        np.save(p_w_int16, weights_int16)

        # Count zero sparsity in INT16 input patch
        n_zeros = np.sum(patch_int16 == 0)
        patch_sparsity = (n_zeros / 576) * 100.0
        print(f"  Input patch INT16: min={patch_int16.min()}, max={patch_int16.max()}, zero count={n_zeros}/576 ({patch_sparsity:.2f}% sparse)")
        print(f"  Weights INT16: min={weights_int16.min()}, max={weights_int16.max()}, shape={weights_int16.shape}")

        for p, desc, dt, shp in [
            (p_in_fp32, "Input receptive field patch (FP32)", "float32", patch_k576.shape),
            (p_in_int16, "Input receptive field patch (INT16 Q4.12)", "int16", patch_int16.shape),
            (p_w_fp32, "Kernel weights (FP32)", "float32", weights_k576.shape),
            (p_w_int16, "Kernel weights (INT16 Q4.12)", "int16", weights_int16.shape),
        ]:
            tensor_manifest_rows.append({
                "model_name": model_name,
                "dataset": dataset_name,
                "layer_name": layer_name,
                "tensor_tag": tag,
                "description": desc,
                "filename": os.path.basename(p),
                "data_type": dt,
                "shape": str(shp),
                "sha256": sha256_file(p)
            })

    pd.DataFrame(tensor_manifest_rows).to_csv(os.path.join(SCRIPT_DIR, "TENSOR_MANIFEST.csv"), index=False)
    print("\nSaved TENSOR_MANIFEST.csv")
    print("[SUCCESS] Phase 2 Tensor Extraction & Quantization complete!")

if __name__ == "__main__":
    main()

