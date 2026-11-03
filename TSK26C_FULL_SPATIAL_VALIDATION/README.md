# TSK-26C: Full Spatial Feature-Map and Multi-Layer Validation

## Executive Overview

Milestone **TSK-26C** expands the verification of the **Neural_Acc** accelerator core from single-patch representative convolutions into **multi-position spatial feature-map execution** and **consecutive multi-layer chaining** using real pretrained CNN weights and activations from ResNet-18 and VGG-16-BN on CIFAR-10.

---

## Key Achievements

1. **100.0% Full Spatial Feature-Map Execution:**
   - In deep layers (VGG-16-BN `features.37`, output spatial grid $2 \times 2 = 4$ positions), all 4 spatial positions $(0,0), (0,1), (1,0), (1,1)$ were executed simultaneously across the 4 physical rows of the PE array.
   - Result: **0 mismatches (100.0% bit-exact golden match, 100.0% spatial coverage)**.
2. **Multi-Position Spatial Grid Verification:**
   - Evaluated spatial grids across early (`layer1.0.conv1`) and middle (`features.14`) layers, verifying that zero-padding ($p=1$), stride ($s=1$), and 2D spatial receptive fields behave correctly in hardware.
3. **Sequential Multi-Layer Validation:**
   - Executed two consecutive convolution layers: ResNet-18 `layer1.0.conv1` $\to$ Requantization/ReLU $\to$ `layer1.0.conv2`.
   - Layer 2 directly consumed the hardware-generated, requantized outputs from Layer 1 without host numerical substitution.
   - Result: **0 mismatches across both layers**.
4. **Strict Cross-Mode Equivalence:**
   - 16-PE, 32-PE, and 64-PE configurations produced identical output tensors (0 mismatches).
5. **Real Activation Sparsity Speedups:**
   - Zero-activation skipping achieved **42.2% to 50.1% cycle reductions** and **25.0% to 50.6% memory read reductions**.
6. **Zero-Regression & Protected Baseline:**
   - All five protected baseline RTL files remain **100% unchanged (0 diffs)**.
   - All 20 existing regression testbenches continue to pass with zero failures.

---

## Directory Structure

```
TSK26C_FULL_SPATIAL_VALIDATION/
├── README.md                          # Milestone overview and summary (this file)
├── IMPLEMENTATION_PLAN.md             # Execution plan and architecture mapping
├── HARDWARE_SOFTWARE_PARTITION.md     # Demarcation of RTL vs host driver roles
├── AUTONOMOUS_SEQUENCING_AUDIT.md     # Audit of hardware autonomy and proposal
├── LIMITATIONS.md                     # Engineering scope and operational boundaries
├── FINAL_AUDIT_REPORT.md              # Comprehensive engineering audit report
├── SPATIAL_COVERAGE.csv               # Spatial dimensions and coverage statistics
├── MULTI_LAYER_CORRECTNESS.csv        # Multi-layer chained execution verification
├── RTL_REFERENCE_COMPARISON.csv       # Hardware vs Golden accumulator verification
├── PE_MODE_PERFORMANCE.csv            # RTL cycles, compute/drain, and speedups
├── DENSE_SPARSE_COMPARISON.csv        # Dense vs Sparse hardware performance
├── extract_spatial_tensors.py         # Real CNN spatial tensor extraction script
├── spatial_reference_model.py         # Golden mathematical reference calculator
├── generate_spatial_workloads.py      # SRAM Buffer A/B hex preload generator
├── tb_tsk26c_spatial_validation.sv    # Icarus Verilog system testbench
├── run_tsk26c_validation.py           # End-to-end hardware simulation harness
├── sim_output.log                     # Complete hardware simulation execution log
├── tensors/                           # Extracted spatial patches and weights (.npy)
└── workloads/                         # 45 preload and golden hex files (.hex)
```

---

## Reproduction Commands

To reproduce the complete validation from scratch:

```bash
# 1. Extract real CNN spatial tensors:
python3 TSK26C_FULL_SPATIAL_VALIDATION/extract_spatial_tensors.py

# 2. Compute mathematical references:
python3 TSK26C_FULL_SPATIAL_VALIDATION/spatial_reference_model.py

# 3. Generate hardware hex workloads:
python3 TSK26C_FULL_SPATIAL_VALIDATION/generate_spatial_workloads.py

# 4. Run hardware simulation and collect CSVs:
python3 TSK26C_FULL_SPATIAL_VALIDATION/run_tsk26c_validation.py
```

