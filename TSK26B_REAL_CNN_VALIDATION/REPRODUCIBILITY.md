# TSK-26B: Reproducibility Guide

This document provides clear, reproducible, step-by-step instructions for executing the full TSK-26B verification workflow from scratch.

## Prerequisites

- **Host Environment:** Windows 10/11 with WSL2 (Ubuntu 20.04/22.04 LTS).
- **Toolchain:**
  - `iverilog` (Icarus Verilog version 11.0 or 12.0)
  - `vvp` (Icarus Verilog simulation engine)
  - `python3` (Python 3.10+)
  - `git`

### Python Virtual Environment Setup

A dedicated Python virtual environment is maintained in `Neural_Acc_env`:

```bash
# From repository root in WSL:
cd /mnt/e/MTech/LanChain/MTP

# If not already created:
python3 -m venv Neural_Acc_env
source Neural_Acc_env/bin/activate

# Install required dependencies:
pip install torch torchvision pyarrow pandas numpy huggingface_hub
```

---

## Step-by-Step Reproduction Workflow

### Step 1: Model & Test Dataset Download

Downloads all 4 pretrained PyTorch models and evaluates baseline classification accuracy on 100 deterministic test samples from CIFAR-10 and CIFAR-100:

```bash
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python TSK26B_REAL_CNN_VALIDATION/download_models_and_data.py
```

- **Outputs:**
  - `models/resnet18_cifar10.pt`, `models/resnet18_cifar100.pt`
  - `models/vgg16_cifar10.pt`, `models/vgg16_cifar100.pt`
  - `data/cifar10_test100.pt`, `data/cifar100_test100.pt`
  - `MODEL_PROVENANCE.md`, `DATASET_PROVENANCE.md`, `MODEL_ACCURACY_RESULTS.csv`

---

### Step 2: Layer Profiling & Tensor Extraction

Profiles all 66 convolutional layers across all four models, measures activation sparsity, and extracts the primary $64 \to 64$ ($3 \times 3$, $K=576$) receptive fields:

```bash
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python TSK26B_REAL_CNN_VALIDATION/extract_cifar_tensors.py
```

- **Outputs:**
  - `LAYER_COVERAGE.csv`
  - `ACTIVATION_SPARSITY.csv`
  - `TENSOR_MANIFEST.csv`
  - `tensors/*.npy` (FP32 activations, FP32 weights, INT16 Q4.12 arrays)

---

### Step 3: Convolution Reference & Mathematical Golden Generation

Evaluates true PyTorch Conv2D on the full 576-step receptive field, runs bit-exact 40-bit fixed-point convolution reference, and quantifies SQNR, MAE, RMSE, and dynamic range:

```bash
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python TSK26B_REAL_CNN_VALIDATION/cifar_convolution_reference.py
```

- **Outputs:**
  - `CONVOLUTION_CORRECTNESS.csv`
  - `NUMERICAL_ACCURACY.csv`
  - `golden_accum_*.npy`
  - `golden_requant_*.npy`

---

### Step 4: Hardware Workload Memory Layout Generation

Formats weights and activations into SRAM Buffer A multi-bank 32-bit hex words (10 words per $k$-step across 576 steps = 5,760 words) and generates Buffer B golden reference hex files:

```bash
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python TSK26B_REAL_CNN_VALIDATION/generate_cifar_workloads.py
```

- **Outputs:**
  - 36 preload hex files in `workloads/`:
    - `*_preload_64pe.hex` (1 pass per workload)
    - `*_preload_32pe_p0.hex`, `*_preload_32pe_p1.hex` (2 passes per workload)
    - `*_preload_16pe_p0.hex` .. `p3.hex` (4 passes per workload)
  - Golden OFMAP hex files (`*_golden_ofmap.hex`)
  - Golden packed requantization hex files (`*_golden_packed.hex`)

---

### Step 5: Hardware Simulation Execution & Verification

Stages hex workloads and testbench into the RTL directory, compiles with `iverilog`, simulates with `vvp`, validates all 4 real CNN workloads through RTL, verifies numerical correctness and cross-mode parity, and collects all telemetry CSVs:

```bash
/mnt/e/MTech/LanChain/MTP/Neural_Acc_env/bin/python TSK26B_REAL_CNN_VALIDATION/run_tsk26b_validation.py
```

- **Outputs:**
  - `sim_output.log`
  - `PE_MODE_PERFORMANCE.csv`
  - `DENSE_SPARSE_COMPARISON.csv`
  - `CROSS_MODE_RESULTS.csv`
  - `NUMERICAL_ACCURACY_RTL.csv`

---

### Step 6: Verifying Baseline Preservation

Verify that the 5 protected baseline RTL files have remained untouched:

```bash
git diff --exit-code phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv
git diff --exit-code phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv
git diff --exit-code phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv
git diff --exit-code phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv
git diff --exit-code phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv
```
All commands should exit cleanly with return code 0.

