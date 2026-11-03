# TSK-30 Experimental Methodology: Multi-Workload Adaptive PE Allocation Validation

## 1. Executive Summary & Experimental Objectives

The primary objective of **TSK-30** is to empirically validate whether the adaptive Processing Element (PE) allocation policy in the `Neural_Acc` accelerator makes justified, deterministic, and useful decisions across multiple real convolutional workloads with varying activation sparsity levels and numerical characteristics.

Rather than assuming that adaptive allocation is inherently advantageous or claiming artificial speedups, TSK-30 evaluates the selection policy, latency trade-offs, and memory access dynamics against fixed 16-, 32-, and 64-PE baselines in both dense and sparse regimes across four real CNN workloads.

---

## 2. Workload Matrix & Provenance

Four representative convolutional layers were extracted from validated model checkpoints and quantized to symmetric INT16 (Q4.12, scale $S = 4096.0$):

| Workload ID | Model | Dataset | Layer Name | Layer Category | Spatial Grid | $C_{in}$ | $C_{out}$ | Kernel | Reduction $K$ | Total MACs | Measured Sparsity |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL1** | ResNet-18 | CIFAR-10 | `layer1.0.conv1` | Early Residual Conv | $4 \times 4$ (16 tiles) | 64 | 16 | $3 \times 3$ | 576 | 147,456 | **68.89%** |
| **WL2** | ResNet-18 | CIFAR-100 | `layer1.0.conv1` | Fine-Grained Early Conv | $4 \times 4$ (16 tiles) | 64 | 16 | $3 \times 3$ | 576 | 147,456 | **66.57%** |
| **WL3** | VGG-16-BN | CIFAR-10 | `features.3` | Early Dense Conv | $4 \times 4$ (16 tiles) | 64 | 16 | $3 \times 3$ | 576 | 147,456 | **48.11%** |
| **WL4** | ResNet-18 | CIFAR-10 | `layer2.1.conv2` | Deep Residual Conv | $4 \times 4$ (16 tiles) | 64 | 16 | $3 \times 3$ | 576 | 147,456 | **84.92%** |

### Provenance Details
- **ResNet-18 CIFAR-10**: Checkpoint from HuggingFace `edadaltocg/resnet18_cifar10` (SHA-256: `ee0e4efc476cc7b116d9350430fd70c2a19e3f30e170762314e9187fc03e01f7`).
- **ResNet-18 CIFAR-100**: Checkpoint from HuggingFace `edadaltocg/resnet18_cifar100` (SHA-256: `e71011071af235a01f9c0983f302feac94f6fafa49d40c39ad7aa0753f1cbf5c`).
- **VGG-16-BN CIFAR-10**: Checkpoint from `chenyaofo/pytorch-cifar-models` (SHA-256: `0607244ff73ea0679feb66791d39a9cc5dd0e41feedca8e0573b4156eae5bcf8`).

---

## 3. Adaptive Allocation Policy & Decision Mechanism

### 3.1 Controller Interface & Degradation Profiling
Mode selection is coordinated directly by the hardware module [`adaptive_pe_controller.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv) instantiated inside the engine.
Degradation metrics ($\hat{D}_{16}, \hat{D}_{32}, \hat{D}_{64}$) enter the accelerator via host configuration registers or layer descriptor headers. This represents **externally guided adaptive allocation**; the hardware datapath does not independently infer whole-model accuracy loss online.

### 3.2 Decision Rules (Stage 8A Ratified Policy)
The controller evaluates the smallest hardware allocation that meets the maximum allowable task degradation threshold $D_{max}$ ($D_{max} = 3277 \approx 0.05$ in Q16.16 fixed-point format):
1. **Rule 1 (16-PE Selection)**: If $\hat{D}_{16} \le D_{max}$, select `MODE_16PE` (2'b00, 4 columns, 4 passes). Fallback = 0.
2. **Rule 2 (32-PE Selection)**: Else if $\hat{D}_{32} \le D_{max}$, select `MODE_32PE` (2'b01, 8 columns, 2 passes). Fallback = 0.
3. **Rule 3 (64-PE Fallback)**: Otherwise, neither reduced mode satisfies the constraint; assert `fallback_to_64 = 1'b1` and select `MODE_64PE` (2'b10, 16 columns, 1 pass).

### 3.3 Workload Decision Profiles

| Workload ID | $\hat{D}_{16}$ | $\hat{D}_{32}$ | $\hat{D}_{64}$ | $D_{max}$ | Evaluated Condition | Resolved Mode | Fallback |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **WL1** | 16000 (0.2441) | 1000 (0.0153) | 0 (0.0000) | 3277 (0.05) | $\hat{D}_{16} > D_{max}$, $\hat{D}_{32} \le D_{max}$ | **32-PE** | **NO** |
| **WL2** | 18500 (0.2823) | 2200 (0.0336) | 0 (0.0000) | 3277 (0.05) | $\hat{D}_{16} > D_{max}$, $\hat{D}_{32} \le D_{max}$ | **32-PE** | **NO** |
| **WL3** | 24500 (0.3738) | 5800 (0.0885) | 0 (0.0000) | 3277 (0.05) | $\hat{D}_{16} > D_{max}$, $\hat{D}_{32} > D_{max}$ | **64-PE** | **YES** |
| **WL4** | 1200 (0.0183) | 400 (0.0061) | 0 (0.0000) | 3277 (0.05) | $\hat{D}_{16} \le D_{max}$ | **16-PE** | **NO** |

---

## 4. Evaluated Configuration Matrix

For every workload, 7 distinct operational configurations were evaluated (28 total test scenarios):
1. **Fixed 16-PE Dense**: 4 active columns, 4 sequential channel passes, dense MAC streaming.
2. **Fixed 16-PE Sparse**: 4 active columns, 4 channel passes, zero-activation skipping.
3. **Fixed 32-PE Dense**: 8 active columns, 2 channel passes, dense MAC streaming.
4. **Fixed 32-PE Sparse**: 8 active columns, 2 channel passes, zero-activation skipping.
5. **Fixed 64-PE Dense**: 16 active columns, 1 channel pass, dense MAC streaming (Baseline).
6. **Fixed 64-PE Sparse**: 16 active columns, 1 channel pass, zero-activation skipping.
7. **Adaptive Sparse**: Dynamic mode resolution via `adaptive_pe_controller.sv` with zero-activation skipping.

---

## 5. Metric Definitions & Formulas

### 5.1 Latency & Throughput Ratios
- **Latency Ratio vs. 64-PE Dense**:
  $$\text{Latency Ratio} = \frac{\text{Total Cycles}_{\text{config}}}{\text{Total Cycles}_{\text{64PE\_Dense}}}$$
- **Relative Throughput**:
  $$\text{Throughput} = \frac{\text{Total Cycles}_{\text{64PE\_Dense}}}{\text{Total Cycles}_{\text{config}}}$$

### 5.2 Memory Traffic Reduction
- **Weight SRAM Read Reduction Percentage**:
  $$\text{Reduction}_{\text{wt}} = \left( 1 - \frac{\text{Weight Reads}_{\text{sparse}}}{\text{Weight Reads}_{\text{dense}}} \right) \times 100\%$$
- **Active PE Hardware Reduction Percentage**:
  $$\text{PE Hardware Reduction} = \left( 1 - \frac{\text{Active PEs}}{64} \right) \times 100\%$$

### 5.3 PE Utilization
- **Documented Formula**:
  $$\text{PE Utilization} = \frac{\text{Total MAC Operations Executed}}{\text{Total Execution Cycles} \times \text{Active PEs}} \times 100\%$$

### 5.4 Numerical Verification Metrics
- **Mean Absolute Error (MAE)**:
  $$\text{MAE} = \frac{1}{256} \sum_{i=0}^{255} |y_{\text{hw}}[i] - y_{\text{golden}}[i]|$$
- **Root Mean Square Error (RMSE)**:
  $$\text{RMSE} = \sqrt{\frac{1}{256} \sum_{i=0}^{255} (y_{\text{hw}}[i] - y_{\text{golden}}[i])^2}$$

---

## 6. Verification Tooling & Environment
- **RTL Simulator**: Icarus Verilog (`iverilog` / `vvp`) v12.0
- **Python Environment**: Python 3.12, PyTorch 2.5.0, NumPy 2.2.0, Pandas 2.2.3
- **Testbench**: [`tb_tsk30_multi_workload_validation.sv`](file:///e:/MTech/LanChain/MTP/TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tb_tsk30_multi_workload_validation.sv)

