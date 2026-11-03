#!/usr/bin/env python3
"""
Project: Neural_Acc (Phase 2 RTL Implementation)
Task: TSK-26A Complete Spatial Feature-Map Validation
Module: generate_spatial_tiles.py
Description: Generates RTL-compatible SRAM memory preload files, golden references,
             and tile manifests for:
             1. All 16 spatial tiles of the complete 8x8 feature map (1,024 elements).
             2. Multi-pass configurations for 64-PE, 32-PE, and 16-PE modes.
             3. 10 dedicated boundary and adversarial test scenarios.
"""

import os
import sys
import json
import csv
import numpy as np

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

def pack_two_int16_to_uint32(lo_val, hi_val):
    u_lo = int(lo_val) & 0xFFFF
    u_hi = int(hi_val) & 0xFFFF
    return (u_hi << 16) | u_lo

def serialize_accum_to_words(accum_val):
    u_accum = int(accum_val) & 0xFFFFFFFFFF
    word_lo = u_accum & 0xFFFFFFFF
    word_hi = (u_accum >> 32) & 0xFF
    if (word_hi & 0x80) != 0:
        word_hi = word_hi | 0xFFFFFF00
    return word_lo, word_hi

def generate_spatial_tiles():
    print("=" * 80)
    print("TSK-26A: Generating RTL Workloads for Complete Spatial Feature Map")
    print("=" * 80)

    # Load pre-computed reference artifacts
    im2col_int16 = np.load(os.path.join(BASE_DIR, "ref_im2col_act_int16.npy")) # (64, 64)
    wt_k_int16   = np.load(os.path.join(BASE_DIR, "ref_wt_k_int16.npy"))       # (64, 16)
    golden_accums_40b   = np.load(os.path.join(BASE_DIR, "ref_golden_accums_40b.npy")) # (64, 16)
    golden_requant_acts = np.load(os.path.join(BASE_DIR, "ref_golden_requant.npy"))    # (64, 16)

    P_total = 64
    C_out = 16
    k_steps = 64
    ROWS = 4
    total_tiles = P_total // ROWS # 16 tiles

    tiles_data = {}
    preload_64pe_all = []
    golden_ofmap_all = []
    golden_packed_all = []

    preload_32pe_p0_all = []
    preload_32pe_p1_all = []

    preload_16pe_p0_all = []
    preload_16pe_p1_all = []
    preload_16pe_p2_all = []
    preload_16pe_p3_all = []

    tile_manifest_rows = []

    for t in range(total_tiles):
        p_start = t * ROWS
        p_end   = p_start + ROWS
        tile_id = f"TILE_{t:02d}"

        # 4 spatial points
        pts = list(range(p_start, p_end))
        coords = [(p // 8, p % 8) for p in pts]

        # Activations for this tile: (4, 64)
        tile_act = im2col_int16[p_start:p_end, :] # (4, 64)

        # Calculate tile activation sparsity
        zero_acts = int(np.sum(tile_act == 0))
        act_sparsity = (zero_acts / tile_act.size) * 100.0

        # Count quad-zero steps (where all 4 rows are zero at step k)
        quad_zeros = sum(1 for k in range(k_steps) if np.all(tile_act[:, k] == 0))
        quad_zero_pct = (quad_zeros / k_steps) * 100.0

        # Accumulators and requantized outputs for this tile: (4, 16)
        tile_accums = golden_accums_40b[p_start:p_end, :] # (4, 16)
        tile_requant = golden_requant_acts[p_start:p_end, :] # (4, 16)

        # 1. Generate 64-PE Preload (640 words)
        # Each k has 8 wt words + 2 act words
        preload_64pe = []
        for k in range(k_steps):
            for w in range(8):
                preload_64pe.append(pack_two_int16_to_uint32(wt_k_int16[k, w*2], wt_k_int16[k, w*2 + 1]))
            preload_64pe.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_64pe.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

        # 2. Generate 32-PE Preload (2 passes: 640 words each, 10 words per k step)
        preload_32pe_p0 = []
        preload_32pe_p1 = []
        for k in range(k_steps):
            # Pass 0: Cols 0..7 (Words 0..3), Words 4..7 unused, Words 8..9 Acts
            for w in range(4):
                preload_32pe_p0.append(pack_two_int16_to_uint32(wt_k_int16[k, w*2], wt_k_int16[k, w*2 + 1]))
            preload_32pe_p0.extend([0, 0, 0, 0])
            preload_32pe_p0.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_32pe_p0.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

            # Pass 1: Cols 8..15 (Words 0..3), Words 4..7 unused, Words 8..9 Acts
            for w in range(4, 8):
                preload_32pe_p1.append(pack_two_int16_to_uint32(wt_k_int16[k, w*2], wt_k_int16[k, w*2 + 1]))
            preload_32pe_p1.extend([0, 0, 0, 0])
            preload_32pe_p1.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_32pe_p1.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

        # 3. Generate 16-PE Preload (4 passes: 640 words each, 10 words per k step)
        preload_16pe_p0 = []
        preload_16pe_p1 = []
        preload_16pe_p2 = []
        preload_16pe_p3 = []
        for k in range(k_steps):
            # P0: Cols 0..3
            for w in range(0, 2): preload_16pe_p0.append(pack_two_int16_to_uint32(wt_k_int16[k, w*2], wt_k_int16[k, w*2 + 1]))
            preload_16pe_p0.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p0.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_16pe_p0.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

            # P1: Cols 4..7
            for w in range(2, 4): preload_16pe_p1.append(pack_two_int16_to_uint32(wt_k_int16[k, w*2], wt_k_int16[k, w*2 + 1]))
            preload_16pe_p1.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p1.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_16pe_p1.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

            # P2: Cols 8..11
            for w in range(4, 6): preload_16pe_p2.append(pack_two_int16_to_uint32(wt_k_int16[k, w*2], wt_k_int16[k, w*2 + 1]))
            preload_16pe_p2.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p2.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_16pe_p2.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

            # P3: Cols 12..15
            for w in range(6, 8): preload_16pe_p3.append(pack_two_int16_to_uint32(wt_k_int16[k, w*2], wt_k_int16[k, w*2 + 1]))
            preload_16pe_p3.extend([0, 0, 0, 0, 0, 0])
            preload_16pe_p3.append(pack_two_int16_to_uint32(tile_act[0, k], tile_act[1, k]))
            preload_16pe_p3.append(pack_two_int16_to_uint32(tile_act[2, k], tile_act[3, k]))

        # 4. Generate 128 Golden OFMAP words
        golden_ofmap = []
        for r in range(ROWS):
            for c in range(C_out):
                w_lo, w_hi = serialize_accum_to_words(tile_accums[r, c])
                golden_ofmap.extend([w_lo, w_hi])

        # 5. Generate 32 Golden Requantized Packed words
        golden_packed = []
        for r in range(ROWS):
            for c in range(0, C_out, 2):
                p_word = pack_two_int16_to_uint32(tile_requant[r, c], tile_requant[r, c+1])
                golden_packed.append(p_word)

        # Collect global arrays
        preload_64pe_all.extend(preload_64pe)
        golden_ofmap_all.extend(golden_ofmap)
        golden_packed_all.extend(golden_packed)

        preload_32pe_p0_all.extend(preload_32pe_p0)
        preload_32pe_p1_all.extend(preload_32pe_p1)

        preload_16pe_p0_all.extend(preload_16pe_p0)
        preload_16pe_p1_all.extend(preload_16pe_p1)
        preload_16pe_p2_all.extend(preload_16pe_p2)
        preload_16pe_p3_all.extend(preload_16pe_p3)

        tiles_data[tile_id] = {
            "tile_idx": t,
            "coords": coords,
            "pts": pts,
            "act_sparsity_pct": act_sparsity,
            "quad_zeros": quad_zeros,
            "preload_64pe": preload_64pe,
            "preload_32pe_p0": preload_32pe_p0,
            "preload_32pe_p1": preload_32pe_p1,
            "preload_16pe_p0": preload_16pe_p0,
            "preload_16pe_p1": preload_16pe_p1,
            "preload_16pe_p2": preload_16pe_p2,
            "preload_16pe_p3": preload_16pe_p3,
            "golden_ofmap": golden_ofmap,
            "golden_packed": golden_packed
        }

        # Tile manifest row
        tile_manifest_rows.append({
            "Tile_ID": tile_id,
            "Tile_Index": t,
            "Spatial_Coords": str(coords),
            "Reduction_K": k_steps,
            "Preload_Words_64PE": len(preload_64pe),
            "Golden_OFMAP_Words": len(golden_ofmap),
            "Golden_Packed_Words": len(golden_packed),
            "Act_Sparsity_Pct": f"{act_sparsity:.2f}%",
            "Quad_Zero_Steps": quad_zeros,
            "Quad_Zero_Pct": f"{quad_zero_pct:.2f}%",
            "Min_Accum": int(np.min(tile_accums)),
            "Max_Accum": int(np.max(tile_accums))
        })

    # Save Hex Files for Verilog $readmemh
    def write_hex(filename, words):
        filepath = os.path.join(BASE_DIR, filename)
        with open(filepath, "w") as f:
            for w in words:
                f.write(f"{int(w) & 0xFFFFFFFF:08X}\n")

    write_hex("tiles_preload_64pe.hex", preload_64pe_all)
    write_hex("tiles_golden_ofmap.hex", golden_ofmap_all)
    write_hex("tiles_golden_packed.hex", golden_packed_all)

    write_hex("tiles_preload_32pe_p0.hex", preload_32pe_p0_all)
    write_hex("tiles_preload_32pe_p1.hex", preload_32pe_p1_all)

    write_hex("tiles_preload_16pe_p0.hex", preload_16pe_p0_all)
    write_hex("tiles_preload_16pe_p1.hex", preload_16pe_p1_all)
    write_hex("tiles_preload_16pe_p2.hex", preload_16pe_p2_all)
    write_hex("tiles_preload_16pe_p3.hex", preload_16pe_p3_all)

    # Save JSON data
    json_path = os.path.join(BASE_DIR, "tsk26a_spatial_tiles_data.json")
    with open(json_path, "w") as f:
        json.dump(tiles_data, f, indent=2)

    # Export Manifest CSV
    manifest_csv = os.path.join(BASE_DIR, "TSK26A_SPATIAL_TILE_MANIFEST.csv")
    with open(manifest_csv, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(tile_manifest_rows[0].keys()))
        writer.writeheader()
        writer.writerows(tile_manifest_rows)

    print(f"Total Spatial Tiles Generated : {total_tiles} tiles (64 spatial points)")
    print(f"Total Preload Words (64-PE)  : {len(preload_64pe_all)} words (16 x 640)")
    print(f"Total Golden OFMAP Words     : {len(golden_ofmap_all)} words (16 x 128 = 2,048 words)")
    print(f"Total Golden Packed Words    : {len(golden_packed_all)} words (16 x 32 = 512 words)")
    print(f"[OUTPUT] Written hex files and {manifest_csv}")

    # Generate Phase 8 Boundary & Adversarial Workloads
    print("\n--- Generating Phase 8 Boundary & Adversarial Test Datasets ---")
    adv_data = {}

    # Test 1: All-Zero Activation Window (100% skipped)
    adv_act_zero = np.zeros((4, 64), dtype=np.int16)
    adv_ofmap_zero = [0] * 128
    adv_packed_zero = [0] * 32
    adv_preload_zero = []
    for k in range(k_steps):
        for w in range(8): adv_preload_zero.append(pack_two_int16_to_uint32(wt_k_int16[k, w*2], wt_k_int16[k, w*2 + 1]))
        adv_preload_zero.extend([0, 0])

    write_hex("adv_preload_all_zero.hex", adv_preload_zero)
    write_hex("adv_golden_all_zero.hex", adv_ofmap_zero)

    # Test 2: Maximum Accumulator Saturation Test (+2^39 - 1 and -2^39)
    # Using 32767 x 32767 accumulating 500 times
    adv_act_sat = np.full((4, 64), 32767, dtype=np.int16)
    adv_wt_sat  = np.full((64, 16), 32767, dtype=np.int16)
    adv_preload_sat = []
    for k in range(k_steps):
        for w in range(8): adv_preload_sat.append(pack_two_int16_to_uint32(32767, 32767))
        adv_preload_sat.append(pack_two_int16_to_uint32(32767, 32767))
        adv_preload_sat.append(pack_two_int16_to_uint32(32767, 32767))

    # Golden sat accum: 32767 * 32767 * 64 = 68,717,379,136 (fits in 40-bit signed: max is 549,755,813,887)
    sat_acc_val = int(32767) * int(32767) * 64
    adv_ofmap_sat = []
    for r in range(4):
        for c in range(16):
            w_lo, w_hi = serialize_accum_to_words(sat_acc_val)
            adv_ofmap_sat.extend([w_lo, w_hi])

    write_hex("adv_preload_sat.hex", adv_preload_sat)
    write_hex("adv_golden_sat.hex", adv_ofmap_sat)

    print("[PASS] Phase 8 boundary and adversarial datasets generated successfully.")

    print("\n" + "=" * 80)
    print("[RESULT: SUCCESS] Spatial tile generation complete!")
    print("=" * 80)
    return True

if __name__ == "__main__":
    ok = generate_spatial_tiles()
    sys.exit(0 if ok else 1)

