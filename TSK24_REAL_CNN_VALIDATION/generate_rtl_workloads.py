#!/usr/bin/env python3
"""
Project: Neural_Acc (Phase 2 RTL Implementation)
Task: TSK-24 Real CNN Numerical Validation
Module: generate_rtl_workloads.py
Description: Generates RTL-compatible SRAM memory preload files and golden reference
             data for 4 real ResNet-18 CNN layer workloads:
             - WL1: Early Conv (layer1.0.conv1, K=64)
             - WL2: Sparse Post-ReLU Conv (layer1.1.conv1, K=64, ~39% sparsity)
             - WL3: Middle Downsampling Conv (layer2.0.conv1, K=64)
             - WL4: Deep Downsampling Conv (layer3.0.conv1, K=128, ~60% sparsity)
"""

import os
import sys
import csv
import json
import numpy as np
from cnn_layer_reference import conv2d_im2col_fp32, conv2d_fixed_point_rtl, requantize_element

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

def generate_workloads():
    print("=" * 80)
    print("TSK-24: Generating RTL Workloads from Real ResNet-18 Tensors")
    print("=" * 80)

    workload_configs = [
        {
            "id": "WL1_EARLY_CONV",
            "name": "layer1.0.conv1",
            "act_file": os.path.join(BASE_DIR, "early_conv_act_int16.npy"),
            "wt_file":  os.path.join(BASE_DIR, "early_conv_wt_int16.npy"),
            "k_steps": 64,
            "shift": 4,
            "desc": "ResNet-18 Layer1.0.Conv1 (Early Conv, K=64)"
        },
        {
            "id": "WL2_SPARSE_RELU",
            "name": "layer1.0.relu",
            "act_file": os.path.join(BASE_DIR, "early_relu_act_int16.npy"),
            "wt_file":  os.path.join(BASE_DIR, "early_conv_wt_int16.npy"),
            "k_steps": 64,
            "shift": 4,
            "desc": "ResNet-18 Post-ReLU Sparsity (K=64, ~39% zeros)"
        },
        {
            "id": "WL3_MID_CONV",
            "name": "layer2.0.conv1",
            "act_file": os.path.join(BASE_DIR, "mid_conv_act_int16.npy"),
            "wt_file":  os.path.join(BASE_DIR, "mid_conv_wt_int16.npy"),
            "k_steps": 64,
            "shift": 5,
            "desc": "ResNet-18 Layer2.0.Conv1 (Middle Conv, K=64)"
        },
        {
            "id": "WL4_DEEP_CONV",
            "name": "layer3.0.conv1",
            "act_file": os.path.join(BASE_DIR, "deep_conv_act_int16.npy"),
            "wt_file":  os.path.join(BASE_DIR, "deep_conv_wt_int16.npy"),
            "k_steps": 128,
            "shift": 6,
            "desc": "ResNet-18 Layer3.0.Conv1 (Deep Conv, K=128, ~60% zeros)"
        }
    ]

    ROWS = 4
    COLS = 16
    manifest_rows = []
    all_workloads_data = {}

    for cfg in workload_configs:
        wl_id = cfg["id"]
        wl_name = cfg["name"]
        k_steps = cfg["k_steps"]
        shift = cfg["shift"]
        desc = cfg["desc"]

        print(f"\n--- Processing Workload: {wl_id} ({desc}) ---")

        # Load tensors
        act_raw = np.load(cfg["act_file"])
        wt_raw  = np.load(cfg["wt_file"])

        # Extract 4 spatial patch rows and 16 output channels
        # Reshape act: (1, C, H, W) -> flatten spatial and channel
        act_flat = act_raw.reshape(act_raw.shape[1], -1) # (C_in, H*W)
        wt_flat  = wt_raw.reshape(wt_raw.shape[0], -1)   # (C_out, C_in*K_h*K_w)

        # Slice 4 spatial points x k_steps activations
        # Row 0: patch at pos 0; Row 1: patch at pos 1; Row 2: patch at pos 2; Row 3: patch at pos 3
        act_slice = np.zeros((ROWS, k_steps), dtype=np.int16)
        for r in range(ROWS):
            for k in range(k_steps):
                c_idx = k % act_flat.shape[0]
                p_idx = (r * 10 + (k // act_flat.shape[0])) % act_flat.shape[1]
                act_slice[r, k] = act_flat[c_idx, p_idx]

        # Slice 16 output channels x k_steps weights
        wt_slice = np.zeros((COLS, k_steps), dtype=np.int16)
        for c in range(COLS):
            for k in range(k_steps):
                wt_k_idx = k % wt_flat.shape[1]
                wt_slice[c, k] = wt_flat[c, wt_k_idx]

        # Calculate exact-zero sparsity
        total_act_elems = ROWS * k_steps
        zero_act_elems = int(np.sum(act_slice == 0))
        act_sparsity = (zero_act_elems / total_act_elems) * 100.0

        # Step 3: Compute Independent Golden Accumulators and Requantized Activations
        golden_accums = np.zeros((ROWS, COLS), dtype=np.int64)
        golden_requant = np.zeros((ROWS, COLS), dtype=np.int16)

        SAT_MAX_POS = (1 << 39) - 1
        SAT_MAX_NEG = -(1 << 39)

        for r in range(ROWS):
            for c in range(COLS):
                acc = 0
                for k in range(k_steps):
                    a_val = int(act_slice[r, k])
                    w_val = int(wt_slice[c, k])
                    prod = a_val * w_val
                    acc += prod
                    if acc > SAT_MAX_POS: acc = SAT_MAX_POS
                    elif acc < SAT_MAX_NEG: acc = SAT_MAX_NEG
                golden_accums[r, c] = acc
                golden_requant[r, c] = requantize_element(acc, shift=shift, round_en=True, relu_en=True)

        # Step 4: Serialize golden OFMAP words (128 words for 64-PE, 32-PE, 16-PE)
        golden_ofmap_words = []
        for r in range(ROWS):
            for c in range(COLS):
                w_lo, w_hi = serialize_accum_to_words(golden_accums[r, c])
                golden_ofmap_words.extend([w_lo, w_hi])

        # Step 5: Serialize golden requantized packed words (32 words)
        golden_packed_words = []
        for r in range(ROWS):
            for c in range(0, COLS, 2):
                p_word = pack_two_int16_to_uint32(golden_requant[r, c], golden_requant[r, c+1])
                golden_packed_words.append(p_word)

        # Step 6: Generate SRAM Memory Preload Map for 64-PE Mode
        # Each k step has 10 words: Words 0..7 are col weights, Words 8..9 are row activations
        sram_preload_words_64 = []
        for k in range(k_steps):
            # 8 weight words
            for w in range(8):
                w_lo = wt_slice[w*2, k]
                w_hi = wt_slice[w*2 + 1, k]
                sram_preload_words_64.append(pack_two_int16_to_uint32(w_lo, w_hi))
            # 2 activation words
            sram_preload_words_64.append(pack_two_int16_to_uint32(act_slice[0, k], act_slice[1, k]))
            sram_preload_words_64.append(pack_two_int16_to_uint32(act_slice[2, k], act_slice[3, k]))

        # Step 7: Generate SRAM Memory Preload for 32-PE Mode (2 passes)
        # Pass 0: Channels 0..7 (4 weight words + 2 act words = 6 words/k)
        # Pass 1: Channels 8..15 (4 weight words + 2 act words = 6 words/k)
        sram_preload_words_32_p0 = []
        sram_preload_words_32_p1 = []
        for k in range(k_steps):
            # Pass 0 weights
            for w in range(4):
                sram_preload_words_32_p0.append(pack_two_int16_to_uint32(wt_slice[w*2, k], wt_slice[w*2 + 1, k]))
            sram_preload_words_32_p0.append(pack_two_int16_to_uint32(act_slice[0, k], act_slice[1, k]))
            sram_preload_words_32_p0.append(pack_two_int16_to_uint32(act_slice[2, k], act_slice[3, k]))

            # Pass 1 weights
            for w in range(4, 8):
                sram_preload_words_32_p1.append(pack_two_int16_to_uint32(wt_slice[w*2, k], wt_slice[w*2 + 1, k]))
            sram_preload_words_32_p1.append(pack_two_int16_to_uint32(act_slice[0, k], act_slice[1, k]))
            sram_preload_words_32_p1.append(pack_two_int16_to_uint32(act_slice[2, k], act_slice[3, k]))

        # Step 8: Generate SRAM Memory Preload for 16-PE Mode (4 passes)
        # Each pass has 2 weight words + 2 act words
        sram_preload_words_16_passes = []
        for p in range(4):
            p_words = []
            for k in range(k_steps):
                for w in range(p*2, (p+1)*2):
                    p_words.append(pack_two_int16_to_uint32(wt_slice[w*2, k], wt_slice[w*2 + 1, k]))
                p_words.append(pack_two_int16_to_uint32(act_slice[0, k], act_slice[1, k]))
                p_words.append(pack_two_int16_to_uint32(act_slice[2, k], act_slice[3, k]))
            sram_preload_words_16_passes.append(p_words)

        print(f"  K Steps          : {k_steps}")
        print(f"  Act Sparsity     : {act_sparsity:.2f}% ({zero_act_elems}/{total_act_elems} zeros)")
        print(f"  SRAM Words (64PE): {len(sram_preload_words_64)} words")
        print(f"  Golden OFMAP     : {len(golden_ofmap_words)} words (64 accumulators)")
        print(f"  Golden Requant   : {len(golden_packed_words)} packed words (64 activations)")

        # Store in dict for JSON export
        all_workloads_data[wl_id] = {
            "workload_id": wl_id,
            "layer_name": wl_name,
            "description": desc,
            "k_steps": k_steps,
            "shift": shift,
            "act_sparsity_pct": act_sparsity,
            "zero_activations": zero_act_elems,
            "total_activations": total_act_elems,
            "golden_accums": golden_accums.tolist(),
            "golden_requant": golden_requant.tolist(),
            "golden_ofmap_words": golden_ofmap_words,
            "golden_packed_words": golden_packed_words,
            "preload_64pe": sram_preload_words_64,
            "preload_32pe_p0": sram_preload_words_32_p0,
            "preload_32pe_p1": sram_preload_words_32_p1,
            "preload_16pe_passes": sram_preload_words_16_passes
        }

        manifest_rows.append({
            "Workload_ID": wl_id,
            "Layer_Name": wl_name,
            "Description": desc,
            "K_Steps": k_steps,
            "Shift": shift,
            "Act_Sparsity_Pct": f"{act_sparsity:.2f}%",
            "Zero_Act_Count": zero_act_elems,
            "Total_Act_Count": total_act_elems,
            "SRAM_Preload_Words_64PE": len(sram_preload_words_64),
            "Golden_OFMAP_Words": len(golden_ofmap_words),
            "Golden_Packed_Words": len(golden_packed_words),
            "Min_Accum": int(np.min(golden_accums)),
            "Max_Accum": int(np.max(golden_accums)),
            "Min_Requant": int(np.min(golden_requant)),
            "Max_Requant": int(np.max(golden_requant))
        })

    # Save JSON data file
    json_path = os.path.join(BASE_DIR, "tsk24_workloads_data.json")
    with open(json_path, "w") as f:
        json.dump(all_workloads_data, f, indent=2)
    print(f"\n[SUCCESS] Workloads dataset saved to {json_path}")

    # Save Workload Manifest CSV
    manifest_csv = os.path.join(BASE_DIR, "TSK24_WORKLOAD_MANIFEST.csv")
    with open(manifest_csv, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(manifest_rows[0].keys()))
        writer.writeheader()
        writer.writerows(manifest_rows)
    print(f"[SUCCESS] Workload manifest saved to {manifest_csv}")

    # Generate hex files for RTL $readmemh simulation
    rtl_dir = os.path.join(os.path.dirname(BASE_DIR), "phase2_step1_microarchitecture_and_rtl")

    wl_keys = list(all_workloads_data.keys())
    for idx, wl_id in enumerate(wl_keys, 1):
        wdata = all_workloads_data[wl_id]
        hex_files = [
            (f"wl{idx}_preload.hex", wdata["preload_64pe"]),
            (f"wl{idx}_golden_ofmap.hex", wdata["golden_ofmap_words"]),
            (f"wl{idx}_golden_packed.hex", wdata["golden_packed_words"])
        ]
        for filename, data_list in hex_files:
            # Save in BASE_DIR
            p_base = os.path.join(BASE_DIR, filename)
            with open(p_base, "w") as f:
                for val in data_list:
                    f.write(f"{val:08X}\n")
            # Save copy in rtl_dir
            p_rtl = os.path.join(rtl_dir, filename)
            with open(p_rtl, "w") as f:
                for val in data_list:
                    f.write(f"{val:08X}\n")

    # Generate SV Header / Include file for Testbench (Icarus Verilog compatible)
    svh_path = os.path.join(BASE_DIR, "tsk24_workloads_data.svh")
    svh_rtl = os.path.join(rtl_dir, "tsk24_workloads_data.svh")
    header_content = "// Auto-generated by generate_rtl_workloads.py for TSK-24\n`ifndef TSK24_WORKLOADS_DATA_SVH\n`define TSK24_WORKLOADS_DATA_SVH\n\n"
    for idx, wl_id in enumerate(wl_keys, 1):
        wdata = all_workloads_data[wl_id]
        k_steps = wdata["k_steps"]
        words_64 = len(wdata["preload_64pe"])
        header_content += f"// --- Workload: {wl_id} (K={k_steps}) ---\n"
        header_content += f"localparam int {wl_id}_K_STEPS = {k_steps};\n"
        header_content += f"localparam int {wl_id}_PRELOAD_WORDS = {words_64};\n\n"
    header_content += "`endif // TSK24_WORKLOADS_DATA_SVH\n"

    with open(svh_path, "w") as f:
        f.write(header_content)
    with open(svh_rtl, "w") as f:
        f.write(header_content)

    print(f"[SUCCESS] SystemVerilog testbench package generated: {svh_path}")
    print(f"[SUCCESS] Hex files written to {BASE_DIR} and {rtl_dir}")
    return True

if __name__ == "__main__":
    ok = generate_workloads()
    sys.exit(0 if ok else 1)
