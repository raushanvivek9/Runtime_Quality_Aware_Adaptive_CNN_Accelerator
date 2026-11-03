# TSK-28: Complete Convolution Layer Validation

## 1. Overview
TSK-28 validates a complete, non-truncated convolution layer from a real pretrained CNN model (**ResNet-18 on CIFAR-10**, `layer1.0.conv1`) using the actual physical MAC RTL (`mac_unit_40b.sv`), integrated with the TSK-27C spatial sequencer and multi-chunk accumulation controller.

Every single output activation computes all **576 reduction terms** ($K = 3 \times 3 \times 64 = 576$) across all 9 kernel positions and 64 input channels. All 256 output elements of a complete $4 \times 4$ spatial grid across 16 output channels were executed and matched bit-exactly with zero errors against an independent software reference.

---

## 2. Directory Structure

| File / Directory | Description |
| :--- | :--- |
| `tsk28_complete_convolution_engine.sv` | Synthesizable hardware engine integrating controller, 16 physical MAC units, autonomous feeder, and drain logic. |
| `tb_tsk28_complete_convolution.sv` | Verification testbench evaluating 16 test scenarios, assertions, and full-layer scoreboarding. |
| `spatial_tile_sequencer.sv` | 2D spatial coordinate generator submodule. |
| `tsk27c_spatial_accumulation_controller.sv` | Nested loop spatial accumulation controller submodule. |
| `TSK28_RESULTS.csv` | Machine-readable test execution metrics. |
| `NUMERICAL_COMPARISON.csv` | Element-by-element verification results across all 256 output activations. |
| `SOFTWARE_REFERENCE_PREDICTIONS.csv` | Expected values and PyTorch FP32 comparison table. |
| `WORKLOAD_SPECIFICATION.md` | Comprehensive layer parameters, model provenance, and partitioning details. |
| `SOFTWARE_REFERENCE.md` | Mathematical formulation and fixed-point quantization definition. |
| `RTL_INTEGRATION_AUDIT.md` | Audit of TSK-27C baseline and TSK-28 hardware datapath integration. |
| `LIMITATIONS.md` | Boundary limitations, line buffering considerations, and zero-energy claim disclaimers. |
| `FINAL_AUDIT_REPORT.md` | Comprehensive milestone engineering audit report with acceptance scorecard. |
| `tensors/` | Directory containing precomputed `.hex` and `.npy` weights, activations, and golden outputs. |

---

## 3. Reproduction Instructions

### 3.1 Prerequisites
- Icarus Verilog (`iverilog`) v12.0 or later
- Python 3 with PyTorch (optional, to regenerate tensors)

### 3.2 Running the Simulation
Execute the complete verification testbench:

```bash
cd TSK28_COMPLETE_CONVOLUTION_VALIDATION
iverilog -g2012 -o sim_tsk28 \
    ../phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv \
    spatial_tile_sequencer.sv \
    tsk27c_spatial_accumulation_controller.sv \
    tsk28_complete_convolution_engine.sv \
    tb_tsk28_complete_convolution.sv
vvp ./sim_tsk28
```

### 3.3 Expected Simulation Summary
```text
==================================================================
 NUMERICAL ACCURACY AUDIT SUMMARY:
   Total Elements Evaluated : 256
   Exact Bit-Exact Matches  : 256 (100.00%)
   Mismatches               : 0
   Max Absolute Error       : 0
   Mean Absolute Error (MAE): 0.000000
   Root Mean Sq Error (RMSE): 0.000000
==================================================================
 TSK-28 VERIFICATION SUMMARY: 16 Passed, 0 Failed
==================================================================
[SUCCESS] All TSK-28 Complete Convolution Layer Tests PASSED with Zero Defects!
```

