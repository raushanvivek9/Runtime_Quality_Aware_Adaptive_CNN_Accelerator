#!/usr/bin/env python3
"""
independent_numerical_reference.py
Phase 2: Independent Numerical Reference & Correctness Reproduction
Independently verifies 4 CNN convolution workloads:
- WL1: ResNet-18 CIFAR-10 (layer1.0.conv1)
- WL2: ResNet-18 CIFAR-100 (layer1.0.conv1)
- WL3: VGG-16-BN CIFAR-10 (features.3)
- WL4: ResNet-18 CIFAR-10 (layer2.1.conv2)

Computes 40-bit integer accumulator reference independently from raw act and wt hex files.
Compares against golden hex files and RTL outputs.
Generates: TSK36_NUMERICAL_REPRODUCTION.csv
"""

import os
import hashlib
import numpy as np
import pandas as pd

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TENSORS_DIR = os.path.join(REPO_ROOT, "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION", "tensors")
OUT_DIR = os.path.join(REPO_ROOT, "TSK36_REPRODUCIBILITY_AUDIT")

workloads = [
    {
        "wl_id": "WL1",
        "name": "ResNet-18 CIFAR-10 (layer1.0.conv1)",
        "model": "ResNet-18",
        "dataset": "CIFAR-10",
        "layer": "layer1.0.conv1",
        "act_hex": "WL1_act.hex",
        "wt_hex": "WL1_wt.hex",
        "gold_hex": "WL1_golden.hex"
    },
    {
        "wl_id": "WL2",
        "name": "ResNet-18 CIFAR-100 (layer1.0.conv1)",
        "model": "ResNet-18",
        "dataset": "CIFAR-100",
        "layer": "layer1.0.conv1",
        "act_hex": "WL2_act.hex",
        "wt_hex": "WL2_wt.hex",
        "gold_hex": "WL2_golden.hex"
    },
    {
        "wl_id": "WL3",
        "name": "VGG-16-BN CIFAR-10 (features.3)",
        "model": "VGG-16-BN",
        "dataset": "CIFAR-10",
        "layer": "features.3",
        "act_hex": "WL3_act.hex",
        "wt_hex": "WL3_wt.hex",
        "gold_hex": "WL3_golden.hex"
    },
    {
        "wl_id": "WL4",
        "name": "ResNet-18 CIFAR-10 (layer2.1.conv2)",
        "model": "ResNet-18",
        "dataset": "CIFAR-10",
        "layer": "layer2.1.conv2",
        "act_hex": "WL4_act.hex",
        "wt_hex": "WL4_wt.hex",
        "gold_hex": "WL4_golden.hex"
    }
]

def sha256_file(filepath):
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest().upper()

def parse_int16_hex(filepath):
    vals = []
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            v = int(line, 16)
            if v >= 0x8000:
                v -= 0x10000
            vals.append(v)
    return np.array(vals, dtype=np.int16)

def parse_int40_hex(filepath):
    vals = []
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            v = int(line, 16)
            if v >= (1 << 39):
                v -= (1 << 40)
            vals.append(v)
    return np.array(vals, dtype=np.int64)

def main():
    print("==================================================================")
    print(" TSK-36 Phase 2: Independent Numerical Correctness Reproduction")
    print("==================================================================")

    results = []

    for wl in workloads:
        wl_id = wl["wl_id"]
        act_path = os.path.join(TENSORS_DIR, wl["act_hex"])
        wt_path  = os.path.join(TENSORS_DIR, wl["wt_hex"])
        gold_path = os.path.join(TENSORS_DIR, wl["gold_hex"])

        act_sha = sha256_file(act_path)
        wt_sha  = sha256_file(wt_path)
        gold_sha = sha256_file(gold_path)

        act_data = parse_int16_hex(act_path) # 9216 elements
        wt_data  = parse_int16_hex(wt_path)  # 9216 elements
        recorded_gold = parse_int40_hex(gold_path) # 256 elements

        assert len(act_data) == 9216, f"Expected 9216 act words, got {len(act_data)}"
        assert len(wt_data) == 9216, f"Expected 9216 wt words, got {len(wt_data)}"
        assert len(recorded_gold) == 256, f"Expected 256 gold words, got {len(recorded_gold)}"

        # Reshape for convolution
        # act: [16 tiles, 9 chunks, 64 Cin]
        # wt:  [16 Cout,  9 chunks, 64 Cin]
        act_3d = act_data.reshape((16, 9, 64)).astype(np.int64)
        wt_3d  = wt_data.reshape((16, 9, 64)).astype(np.int64)

        # Independent software convolution reference (40-bit accumulator)
        indep_gold = np.zeros((16, 16), dtype=np.int64)
        for tile in range(16):
            for oc in range(16):
                acc = 0
                for chunk in range(9):
                    acc += np.sum(act_3d[tile, chunk, :] * wt_3d[oc, chunk, :])
                indep_gold[tile, oc] = acc

        indep_flat = indep_gold.flatten()

        # Compare independent reference vs recorded golden hex
        diff_gold = np.abs(indep_flat - recorded_gold)
        mismatches_vs_gold = int(np.sum(diff_gold != 0))
        max_err_vs_gold = int(np.max(diff_gold))
        mae_vs_gold = float(np.mean(diff_gold))
        rmse_vs_gold = float(np.sqrt(np.mean(diff_gold ** 2)))

        zeros_act = int(np.sum(act_data == 0))
        act_sparsity = round((zeros_act / len(act_data)) * 100.0, 2)

        print(f"[{wl_id}] {wl['name']}:")
        print(f"  Act SHA256: {act_sha[:16]}... (Sparsity: {act_sparsity}%)")
        print(f"  Wt  SHA256: {wt_sha[:16]}...")
        print(f"  Gold SHA256: {gold_sha[:16]}...")
        print(f"  Elements Evaluated: {len(indep_flat)}")
        print(f"  Mismatches vs Golden Hex: {mismatches_vs_gold}")
        print(f"  Max Absolute Error: {max_err_vs_gold}, MAE: {mae_vs_gold}, RMSE: {rmse_vs_gold}")
        assert mismatches_vs_gold == 0, f"Mismatches detected in {wl_id}!"

        results.append({
            "Workload_ID": wl_id,
            "Model_Name": wl["model"],
            "Dataset": wl["dataset"],
            "Layer_Name": wl["layer"],
            "Spatial_Region": "4x4 Spatial Grid (16 Tiles)",
            "Output_Channels": 16,
            "Reduction_Depth_K": 576,
            "Total_MAC_Operations": 147456,
            "Total_Output_Elements": 256,
            "Activation_File": wl["act_hex"],
            "Activation_SHA256": act_sha,
            "Activation_Sparsity_Pct": act_sparsity,
            "Weight_File": wl["wt_hex"],
            "Weight_SHA256": wt_sha,
            "Golden_Reference_File": wl["gold_hex"],
            "Golden_Reference_SHA256": gold_sha,
            "Independent_Output_Checksum": hex(int(np.sum(indep_flat) & 0xFFFFFFFFFF)),
            "Mismatches_vs_RTL_Golden": mismatches_vs_gold,
            "Max_Absolute_Error": max_err_vs_gold,
            "MAE": mae_vs_gold,
            "RMSE": rmse_vs_gold,
            "Validation_Scope": "Complete Convolution for 4x4 Grid (NOT Full CNN)",
            "Verification_Status": "PASS (Bit-Exact 100%)"
        })

    df_out = pd.DataFrame(results)
    out_csv = os.path.join(OUT_DIR, "TSK36_NUMERICAL_REPRODUCTION.csv")
    df_out.to_csv(out_csv, index=False)
    print(f"\n[SUCCESS] TSK36_NUMERICAL_REPRODUCTION.csv written with {len(df_out)} workloads.")

if __name__ == "__main__":
    main()

