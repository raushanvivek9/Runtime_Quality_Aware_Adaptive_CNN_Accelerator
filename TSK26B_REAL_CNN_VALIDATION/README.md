# TSK-26B: Real CNN Numerical Validation on CIFAR-10 and CIFAR-100 Using Neural_Acc RTL

## Executive Summary

Milestone **TSK-26B** advances the Neural_Acc verification program from synthetic alternating-zero patterns and truncated kernel fragments to **full-depth mathematical convolution validation** using real pretrained convolutional neural network weights and real activation tensors across four standardized model-dataset benchmarks:

1. **ResNet-18 on CIFAR-10** (11.17M parameters, 94.98% reference accuracy)
2. **ResNet-18 on CIFAR-100** (11.22M parameters, 79.26% reference accuracy)
3. **VGG-16-BN on CIFAR-10** (15.25M parameters, 93.96% reference accuracy)
4. **VGG-16-BN on CIFAR-100** (15.30M parameters, 74.01% reference accuracy)

### Key Achievements

- **Full Mathematical Reduction ($K = C_{in} \times K_H \times K_W = 64 \times 3 \times 3 = 576$):**
  Unlike earlier milestones that truncated the inner product to $K=64$ or evaluated isolated center-pixel fragments, TSK-26B verified the **complete 576-step reduction dimension** encompassing all 9 spatial kernel tap positions across all 64 input channels in a single continuous hardware execution pass (`cmd_k_total = 576`).
- **100% Bit-Exact RTL Numerical Match:**
  All 64 output channel accumulators ($4 \times 16$ grid) produced by the RTL datapath match the software golden integer reference model with **0 mismatches (100.0% match rate)**.
- **100% Bit-Exact Cross-Mode Equivalence:**
  Outputs produced across **16-PE (4 passes), 32-PE (2 passes), and 64-PE (1 pass)** configurations are identical with **0 mismatches across all 64 elements**.
- **Quantization Fidelity (INT16 Q4.12):**
  Quantization against 32-bit floating point achieved high signal fidelity:
  - ResNet-18 CIFAR-10: **SQNR = 57.18 dB**, MAE = $8.50 \times 10^{-5}$
  - ResNet-18 CIFAR-100: **SQNR = 51.65 dB**, MAE = $6.90 \times 10^{-5}$
  - VGG-16-BN CIFAR-10: **SQNR = 54.78 dB**, MAE = $6.50 \times 10^{-5}$
  - VGG-16-BN CIFAR-100: **SQNR = 60.71 dB**, MAE = $1.26 \times 10^{-4}$
- **Requantization Unit Bit-Exact Packing:**
  Hardware requantization (scale shift = 12, rounding, ReLU, INT16 saturation) matched the golden packed 32-bit words with **100% bit-exact equivalence**.
- **Real Activation Sparsity & Hardware Performance:**
  Real post-ReLU activation sparsity translated directly into compute cycle and SRAM bandwidth savings:
  - ResNet-18 CIFAR-10 (63.19% sparse): **50.13% cycle reduction**, **50.56% SRAM read reduction**
  - ResNet-18 CIFAR-100 (60.76% sparse): **49.39% cycle reduction**, **48.61% SRAM read reduction**
  - VGG-16 CIFAR-10 (40.45% sparse): **43.14% cycle reduction**, **42.22% SRAM read reduction**
  - VGG-16 CIFAR-100 (37.50% sparse): **42.23% cycle reduction**, **41.39% SRAM read reduction**
- **Protected RTL Baseline:**
  All five core RTL baseline files remain **100% unchanged (0 diffs)**.

---

## Directory Structure

```
TSK26B_REAL_CNN_VALIDATION/
├── README.md                          # Milestone overview and summary (this file)
├── REPRODUCIBILITY.md                 # Complete reproduction workflow and instructions
├── LIMITATIONS.md                     # Technical scope and boundary analysis
├── FINAL_AUDIT_REPORT.md              # Comprehensive engineering audit report
├── MODEL_PROVENANCE.md                # Checkpoint origins, hashes, and accuracies
├── DATASET_PROVENANCE.md              # Dataset sources, extraction methods, and samples
├── MODEL_ACCURACY_RESULTS.csv         # Evaluated Top-1 / Top-5 model accuracy
├── LAYER_COVERAGE.csv                 # Comprehensive layer profiling across all 4 models
├── ACTIVATION_SPARSITY.csv            # Statistical sparsity distributions per layer
├── TENSOR_MANIFEST.csv                # Extracted tensor shapes, paths, and metadata
├── CONVOLUTION_CORRECTNESS.csv        # Mathematical convolution dimension verification
├── NUMERICAL_ACCURACY.csv             # SQNR, MAE, RMSE, and dynamic range metrics
├── PE_MODE_PERFORMANCE.csv            # RTL cycle, read, and speedup telemetry
├── DENSE_SPARSE_COMPARISON.csv        # Hardware savings from activation sparsity
├── CROSS_MODE_RESULTS.csv             # 16-PE vs 32-PE vs 64-PE equivalence checks
├── NUMERICAL_ACCURACY_RTL.csv         # Hardware vs Golden accumulator verification
├── download_models_and_data.py        # Model checkpoint & test set downloader
├── extract_cifar_tensors.py           # Profiling and tensor extraction pipeline
├── cifar_convolution_reference.py     # Golden convolution & fixed-point reference
├── generate_cifar_workloads.py        # SRAM Buffer A/B hex preload generator
├── tb_tsk26b_real_cnn_validation.sv   # Icarus Verilog system testbench
├── run_tsk26b_validation.py           # End-to-end hardware simulation harness
├── sim_output.log                     # Complete hardware simulation execution log
├── models/                            # PyTorch model checkpoints (.pt)
├── data/                              # Deterministic evaluation test sets (.pt)
├── tensors/                           # Extracted FP32 and INT16 arrays (.npy)
└── workloads/                         # Preload and golden hex files (.hex)
```

---

## Deliverables Summary

| Deliverable | Format | Purpose |
| :--- | :--- | :--- |
| `MODEL_PROVENANCE.md` | Markdown | Document model origins, architectures, weights SHA-256 |
| `DATASET_PROVENANCE.md` | Markdown | Document test dataset sources, deterministic samples |
| `MODEL_ACCURACY_RESULTS.csv` | CSV | Validation of Top-1 / Top-5 classification accuracy |
| `LAYER_COVERAGE.csv` | CSV | Profiling of 66 convolutional layers across all models |
| `ACTIVATION_SPARSITY.csv` | CSV | Activation sparsity statistics across models and layers |
| `TENSOR_MANIFEST.csv` | CSV | Manifest of extracted tensor patches and dimensions |
| `CONVOLUTION_CORRECTNESS.csv` | CSV | Verification of full $K=576$ mathematical reduction |
| `NUMERICAL_ACCURACY.csv` | CSV | Fixed-point vs floating-point SQNR and error metrics |
| `PE_MODE_PERFORMANCE.csv` | CSV | RTL cycle counts, compute, drain, and speedups |
| `DENSE_SPARSE_COMPARISON.csv` | CSV | Dense vs Sparse hardware performance comparisons |
| `CROSS_MODE_RESULTS.csv` | CSV | 16-PE, 32-PE, and 64-PE cross-mode output equivalence |
| `NUMERICAL_ACCURACY_RTL.csv` | CSV | Hardware accumulator match against golden reference |
| `FINAL_AUDIT_REPORT.md` | Markdown | Complete engineering audit and evidence synthesis |
| `REPRODUCIBILITY.md` | Markdown | Step-by-step reproduction guide |
| `LIMITATIONS.md` | Markdown | Architectural scope and operational boundary analysis |

