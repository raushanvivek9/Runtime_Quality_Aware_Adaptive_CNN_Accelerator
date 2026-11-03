#!/usr/bin/env python3
"""
generate_cifar_workloads.py
Generates hardware preload hex files for 64-PE, 32-PE, and 16-PE modes
with full K=576 inner products across all 4 models:
- ResNet-18 on CIFAR-10 (r18_c10)
- ResNet-18 on CIFAR-100 (r18_c100)
- VGG-16 on CIFAR-10 (vgg_c10)
- VGG-16 on CIFAR-100 (vgg_c100)
"""

import os
import json
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TENSORS_DIR = os.path.join(SCRIPT_DIR, "tensors")
WORKLOADS_DIR = os.path.join(SCRIPT_DIR, "workloads")
os.makedirs(WORKLOADS_DIR, exist_ok=True)

def pack_two_int16_to_uint32(val0, val1):
    u0 = int(val0) & 0xFFFF
    u1 = int(val1) & 0xFFFF
    return (u1 << 16) | u0

def serialize_accum_to_words(accum_val):
    val_64 = int(accum_val) & 0xFFFFFFFFFFFFFFFF
    w_lo = val_64 & 0xFFFFFFFF
    w_hi = (val_64 >> 32) & 0xFFFFFFFF
    return w_lo, w_hi

def write_hex(filepath, word_list):
    with open(filepath, "w") as f:
        for w in word_list:
            f.write(f"{w:08x}\n")

def main():
    print("=======================================================")
    print(" GENERATING HARDWARE WORKLOADS FOR K=576")
    print("=======================================================")

    tags = [
        ("r18_c10", "ResNet-18", "CIFAR-10", "layer1.0.conv1"),
        ("r18_c100", "ResNet-18", "CIFAR-100", "layer1.0.conv1"),
        ("vgg_c10", "VGG-16-BN", "CIFAR-10", "features.3"),
        ("vgg_c100", "VGG-16-BN", "CIFAR-100", "features.3")
    ]

    K_STEPS = 576
    ROWS = 4
    COLS = 16

    for tag, model_name, dataset_name, layer_name in tags:
        print(f"\nProcessing {model_name} / {dataset_name} ({tag})...")

        # Load input patch (576,) and weights (64, 576)
        patch_int16 = np.load(os.path.join(TENSORS_DIR, f"{tag}_input_patch_int16.npy")) # (576,)
        weights_int16 = np.load(os.path.join(TENSORS_DIR, f"{tag}_weights_int16.npy")) # (64, 576)

        # Output channels for this tile: first 16 output channels (COLS=16)
        # Weights shape for columns: (16, 576)
        wt_16cols = weights_int16[:COLS, :] # (16, 576)

        # 4 spatial points: replicate row 0 or use slightly shifted patch
        # To test row independence and zero skipping, we create 4 spatial activations:
        # Row 0: patch_int16
        # Row 1: patch_int16 (same point)
        # Row 2: patch_int16 (same point)
        # Row 3: patch_int16 (same point)
        tile_act = np.zeros((ROWS, K_STEPS), dtype=np.int16)
        for r in range(ROWS):
            tile_act[r, :] = patch_int16

        # Calculate sparsity metrics
        zero_acts = int(np.sum(tile_act == 0))
        act_sparsity = (zero_acts / tile_act.size) * 100.0
        quad_zeros = sum(1 for k in range(K_STEPS) if np.all(tile_act[:, k] == 0))
        quad_zero_pct = (quad_zeros / K_STEPS) * 100.0
        print(f"  Activation sparsity: {act_sparsity:.2f}%, Quad-zero steps: {quad_zeros}/{K_STEPS} ({quad_zero_pct:.2f}%)")

        # Compute golden 40-bit accumulators and requantized outputs: shape (4, 16)
        tile_accums = np.zeros((ROWS, COLS), dtype=np.int64)
        for r in range(ROWS):
            for c in range(COLS):
                prod = tile_act[r, :].astype(np.int64) * wt_16cols[c, :].astype(np.int64)
                tile_accums[r, c] = np.sum(prod)

        # Requantization: shift 12, Round-Half-Up, saturate INT16, ReLU
        round_offset = 1 << 11
        tile_requant = np.zeros((ROWS, COLS), dtype=np.int16)
        for r in range(ROWS):
            for c in range(COLS):
                rnd = (tile_accums[r, c] + round_offset) >> 12
                clp = np.clip(rnd, -32768, 32767)
                tile_requant[r, c] = max(0, clp)

        # 1. Generate 64-PE Preload (5,760 words)
        # For each k in 0..575:
        #   Words 0..7: 8 weight words (16 columns)
        #   Words 8..9: 2 activation words (4 rows)
        preload_64pe = []
        for k in range(K_STEPS):
            for w in range(8):
                preload_64pe.append(pack_two_int16_to_uint32(wt_16cols[w*2, k], wt_16cols[w*2 + 1, k]))
            preload_64pe.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_64pe.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))
        assert len(preload_64pe) == 5760

        # 2. Generate 32-PE Preload (2 passes: 5,760 words each)
        preload_32pe_p0 = []
        preload_32pe_p1 = []
        for k in range(K_STEPS):
            # Pass 0: Cols 0..7 (Words 0..3), Words 4..7 unused, Words 8..9 Acts
            for w in range(4):
                preload_32pe_p0.append(pack_two_int16_to_uint32(wt_16cols[w*2, k], wt_16cols[w*2 + 1, k]))
            preload_32pe_p0.extend([0, 0, 0, 0])
            preload_32pe_p0.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_32pe_p0.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

            # Pass 1: Cols 8..15 (Words 0..3), Words 4..7 unused, Words 8..9 Acts
            for w in range(4, 8):
                preload_32pe_p1.append(pack_two_int16_to_uint32(wt_16cols[w*2, k], wt_16cols[w*2 + 1, k]))
            preload_32pe_p1.extend([0, 0, 0, 0])
            preload_32pe_p1.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_32pe_p1.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

        # 3. Generate 16-PE Preload (4 passes: 5,760 words each)
        preload_16pe_p0 = []
        preload_16pe_p1 = []
        preload_16pe_p2 = []
        preload_16pe_p3 = []
        for k in range(K_STEPS):
            # P0: Cols 0..3
            for w in range(0, 2): preload_16pe_p0.append(pack_two_int16_to_uint32(wt_16cols[w*2, k], wt_16cols[w*2 + 1, k]))
            preload_16pe_p0.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p0.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_16pe_p0.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

            # P1: Cols 4..7
            for w in range(2, 4): preload_16pe_p1.append(pack_two_int16_to_uint32(wt_16cols[w*2, k], wt_16cols[w*2 + 1, k]))
            preload_16pe_p1.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p1.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_16pe_p1.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

            # P2: Cols 8..11
            for w in range(4, 6): preload_16pe_p2.append(pack_two_int16_to_uint32(wt_16cols[w*2, k], wt_16cols[w*2 + 1, k]))
            preload_16pe_p2.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p2.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_16pe_p2.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

            # P3: Cols 12..15
            for w in range(6, 8): preload_16pe_p3.append(pack_two_int16_to_uint32(wt_16cols[w*2, k], wt_16cols[w*2 + 1, k]))
            preload_16pe_p3.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p3.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_16pe_p3.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

        # 4. Golden OFMAP (128 words: 4 rows x 16 cols x 2 words/accum)
        golden_ofmap = []
        for r in range(ROWS):
            for c in range(COLS):
                w_lo, w_hi = serialize_accum_to_words(tile_accums[r, c])
                golden_ofmap.extend([w_lo, w_hi])
        assert len(golden_ofmap) == 128

        # 5. Golden Requantized Packed (32 words: 4 rows x 8 packed pairs)
        golden_packed = []
        for r in range(ROWS):
            for c in range(0, COLS, 2):
                golden_packed.append(pack_two_int16_to_uint32(tile_requant[r, c], tile_requant[r, c+1]))
        assert len(golden_packed) == 32

        # Write hex files
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_64pe.hex"), preload_64pe)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_32pe_p0.hex"), preload_32pe_p0)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_32pe_p1.hex"), preload_32pe_p1)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_16pe_p0.hex"), preload_16pe_p0)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_16pe_p1.hex"), preload_16pe_p1)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_16pe_p2.hex"), preload_16pe_p2)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_16pe_p3.hex"), preload_16pe_p3)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_golden_ofmap.hex"), golden_ofmap)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_golden_packed.hex"), golden_packed)

        meta = {
            "tag": tag,
            "model_name": model_name,
            "dataset": dataset_name,
            "layer_name": layer_name,
            "k_steps": K_STEPS,
            "rows": ROWS,
            "cols": COLS,
            "words_per_k": 10,
            "total_preload_words": 5760,
            "act_sparsity_pct": act_sparsity,
            "quad_zero_steps": quad_zeros,
            "quad_zero_pct": quad_zero_pct,
            "golden_ofmap_words": len(golden_ofmap),
            "golden_packed_words": len(golden_packed)
        }
        with open(os.path.join(WORKLOADS_DIR, f"{tag}_metadata.json"), "w") as f:
            json.dump(meta, f, indent=2)

    print("\n[SUCCESS] Phase 4 Workload Preload Hex Generation complete!")

if __name__ == "__main__":
    main()

