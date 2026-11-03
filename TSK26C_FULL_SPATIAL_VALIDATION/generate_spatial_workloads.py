#!/usr/bin/env python3
"""
generate_spatial_workloads.py
Generates hardware hex preload files for TSK-26C:
- deep: VGG-16 features.37 (2x2 full spatial grid)
- mid: VGG-16 features.14 (8x8 grid, 4 positions)
- early: ResNet-18 layer1.0.conv1 (32x32 grid, 4 positions)
- chain_c1: ResNet-18 layer1.0.conv1 (chained layer 1)
- chain_c2: ResNet-18 layer1.0.conv2 (chained layer 2 consuming layer 1 outputs)
For each workload, generates:
- preload_64pe.hex (1 pass)
- preload_32pe_p0.hex, preload_32pe_p1.hex (2 passes)
- preload_16pe_p0..p3.hex (4 passes)
- golden_ofmap.hex (128 words)
- golden_packed.hex (32 words)
"""

import os
import sys
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TENSORS_DIR = os.path.join(SCRIPT_DIR, "tensors")
WORKLOADS_DIR = os.path.join(SCRIPT_DIR, "workloads")
os.makedirs(WORKLOADS_DIR, exist_ok=True)

K_STEPS = 576
ROWS = 4
COLS = 16

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
    print("=" * 80)
    print(" TSK-26C: GENERATING HARDWARE PRELOAD HEX FILES")
    print("=" * 80)

    tags = ["deep", "mid", "early", "chain_c1", "chain_c2"]

    for tag in tags:
        print(f"\nGenerating hex files for workload: {tag}...")

        # Load patches (4, 576) and weights (16, 576)
        patches = np.load(os.path.join(TENSORS_DIR, f"{tag}_patches_int16.npy")) # (4, 576)
        weights = np.load(os.path.join(TENSORS_DIR, f"{tag}_wt_int16.npy")) # (16, 576)
        gold_accum = np.load(os.path.join(TENSORS_DIR, f"gold_accum_{tag}.npy")) # (4, 16)
        gold_requant = np.load(os.path.join(TENSORS_DIR, f"gold_requant_{tag}.npy")) # (4, 16)

        # 1. 64-PE Preload (5,760 words)
        preload_64pe = []
        for k in range(K_STEPS):
            for w in range(8):
                preload_64pe.append(pack_two_int16_to_uint32(weights[w*2, k], weights[w*2 + 1, k]))
            preload_64pe.append(pack_two_int16_to_uint32(patches[0, k], patches[1, k]))
            preload_64pe.append(pack_two_int16_to_uint32(patches[2, k], patches[3, k]))
        assert len(preload_64pe) == 5760
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_64pe.hex"), preload_64pe)

        # 2. 32-PE Preload (2 passes: 5,760 words each)
        preload_32pe_p0 = []
        preload_32pe_p1 = []
        for k in range(K_STEPS):
            # Pass 0: Cols 0..7 (Words 0..3), Words 4..7 unused, Words 8..9 Acts
            for w in range(4):
                preload_32pe_p0.append(pack_two_int16_to_uint32(weights[w*2, k], weights[w*2 + 1, k]))
            preload_32pe_p0.extend([0, 0, 0, 0])
            preload_32pe_p0.append(pack_two_int16_to_uint32(patches[0, k], patches[1, k]))
            preload_32pe_p0.append(pack_two_int16_to_uint32(patches[2, k], patches[3, k]))

            # Pass 1: Cols 8..15 (Words 0..3), Words 4..7 unused, Words 8..9 Acts
            for w in range(4, 8):
                preload_32pe_p1.append(pack_two_int16_to_uint32(weights[w*2, k], weights[w*2 + 1, k]))
            preload_32pe_p1.extend([0, 0, 0, 0])
            preload_32pe_p1.append(pack_two_int16_to_uint32(patches[0, k], patches[1, k]))
            preload_32pe_p1.append(pack_two_int16_to_uint32(patches[2, k], patches[3, k]))

        assert len(preload_32pe_p0) == 5760
        assert len(preload_32pe_p1) == 5760
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_32pe_p0.hex"), preload_32pe_p0)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_32pe_p1.hex"), preload_32pe_p1)

        # 3. 16-PE Preload (4 passes: 5,760 words each)
        preload_16pe_p0 = []
        preload_16pe_p1 = []
        preload_16pe_p2 = []
        preload_16pe_p3 = []
        for k in range(K_STEPS):
            # P0: Cols 0..3
            for w in range(0, 2): preload_16pe_p0.append(pack_two_int16_to_uint32(weights[w*2, k], weights[w*2 + 1, k]))
            preload_16pe_p0.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p0.append(pack_two_int16_to_uint32(patches[0, k], patches[1, k]))
            preload_16pe_p0.append(pack_two_int16_to_uint32(patches[2, k], patches[3, k]))

            # P1: Cols 4..7
            for w in range(2, 4): preload_16pe_p1.append(pack_two_int16_to_uint32(weights[w*2, k], weights[w*2 + 1, k]))
            preload_16pe_p1.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p1.append(pack_two_int16_to_uint32(patches[0, k], patches[1, k]))
            preload_16pe_p1.append(pack_two_int16_to_uint32(patches[2, k], patches[3, k]))

            # P2: Cols 8..11
            for w in range(4, 6): preload_16pe_p2.append(pack_two_int16_to_uint32(weights[w*2, k], weights[w*2 + 1, k]))
            preload_16pe_p2.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p2.append(pack_two_int16_to_uint32(patches[0, k], patches[1, k]))
            preload_16pe_p2.append(pack_two_int16_to_uint32(patches[2, k], patches[3, k]))

            # P3: Cols 12..15
            for w in range(6, 8): preload_16pe_p3.append(pack_two_int16_to_uint32(weights[w*2, k], weights[w*2 + 1, k]))
            preload_16pe_p3.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p3.append(pack_two_int16_to_uint32(patches[0, k], patches[1, k]))
            preload_16pe_p3.append(pack_two_int16_to_uint32(patches[2, k], patches[3, k]))

        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_16pe_p0.hex"), preload_16pe_p0)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_16pe_p1.hex"), preload_16pe_p1)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_16pe_p2.hex"), preload_16pe_p2)
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_preload_16pe_p3.hex"), preload_16pe_p3)

        # 4. Golden OFMAP (128 words: 4 rows x 16 cols x 2 words/accum)
        golden_ofmap = []
        for r in range(ROWS):
            for c in range(COLS):
                w_lo, w_hi = serialize_accum_to_words(gold_accum[r, c])
                golden_ofmap.extend([w_lo, w_hi])
        assert len(golden_ofmap) == 128
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_golden_ofmap.hex"), golden_ofmap)

        # 5. Golden Requantized Packed (32 words: 4 rows x 8 packed pairs)
        golden_packed = []
        for r in range(ROWS):
            for c in range(0, COLS, 2):
                golden_packed.append(pack_two_int16_to_uint32(gold_requant[r, c], gold_requant[r, c+1]))
        assert len(golden_packed) == 32
        write_hex(os.path.join(WORKLOADS_DIR, f"{tag}_golden_packed.hex"), golden_packed)

        print(f"  [PASS] Successfully generated 9 hex files for {tag}")

    print("\n" + "=" * 80)
    print(" ALL 45 WORKLOAD HEX FILES GENERATED SUCCESSFULLY IN workloads/")
    print("=" * 80)

if __name__ == "__main__":
    main()

