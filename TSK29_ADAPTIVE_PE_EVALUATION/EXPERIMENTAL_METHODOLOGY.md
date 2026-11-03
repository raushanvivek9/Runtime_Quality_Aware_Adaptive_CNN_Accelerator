# TSK-29 Experimental Methodology Report

## 1. Objective and Hypothesis Formulation

### 1.1 Objective
The objective of milestone **TSK-29** is to perform a scientifically rigorous and empirically verified evaluation of the proposed **Adaptive Processing Element (PE) Allocation** policy in comparison against fixed allocation baselines (16-PE, 32-PE, 64-PE) across dense and activation-sparse execution regimes.

### 1.2 Scientific Hypothesis vs. Empirical Reality
- **Hypothesis**: Dynamic adaptive PE allocation improves execution performance by allocating smaller PE configurations when activation sparsity is high.
- **Null Hypothesis**: Adaptive PE allocation does not reduce total execution cycles below the fixed 64-PE baseline, but provides a resource-adaptation mechanism that reduces active hardware footprint (power-gating) when throughput constraints permit.
- **Experimental Protocol**: To ensure fair comparisons, all evaluated configurations execute the exact same mathematical workload (ResNet-18 `layer1.0.conv1`), with identical input tensors, weights, boundary zero-padding, arithmetic semantics, and measurement boundaries.

---

## 2. Experimental Test Matrix

A total of seven fair configurations are evaluated under identical conditions:

| Config ID | Configuration Name | Allocation Policy | Operating Mode | Active Columns | Active PEs | Channel Passes | Sparsity Regime |
| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **C1** | `Fixed_16PE_Dense` | Fixed | `2'b00` (16-PE) | 4 | 16 | 4 | Dense (0% Skipping) |
| **C2** | `Fixed_16PE_Sparse` | Fixed | `2'b00` (16-PE) | 4 | 16 | 4 | Sparse (Exact-Zero Skipping) |
| **C3** | `Fixed_32PE_Dense` | Fixed | `2'b01` (32-PE) | 8 | 32 | 2 | Dense (0% Skipping) |
| **C4** | `Fixed_32PE_Sparse` | Fixed | `2'b01` (32-PE) | 8 | 32 | 2 | Sparse (Exact-Zero Skipping) |
| **C5** | `Fixed_64PE_Dense` | Fixed | `2'b10` (64-PE) | 16 | 64 | 1 | Dense (0% Skipping) |
| **C6** | `Fixed_64PE_Sparse` | Fixed | `2'b10` (64-PE) | 16 | 64 | 1 | Sparse (Exact-Zero Skipping) |
| **C7** | `Adaptive_Sparse` | Adaptive | Dynamic (`2'b01`) | 8 | 32 | 2 | Sparse (Exact-Zero Skipping) |

---

## 3. Workload and Dataset Provenance

- **Pretrained Model**: ResNet-18 on CIFAR-10 (`edadaltocg/resnet18_cifar10` checkpoint, SHA256 verified).
- **Target Convolution Layer**: `layer1.0.conv1`.
- **Input Feature Map**: Propagated through `conv1 -> bn1 -> relu` using the first deterministic test sample from `cifar10_test100.pt`.
- **Spatial Grid**: $4 \times 4$ spatial feature-map grid (16 coordinates, covering corners, edges, and interior positions).
- **Channels**: $C_{in} = 64, C_{out} = 16$.
- **Reduction Terms**: $K = 3 \times 3 \times 64 = 576$ reduction terms per output element (9 chunks $\times$ 64 channels).
- **Total Workload Operations**: $16 \text{ positions} \times 16 \text{ channels} \times 576 \text{ terms} = 147,456$ MAC operations.
- **Measured Activation Sparsity**: **68.89%** (6,349 zero activations out of 9,216 total input activation words).

---

## 4. Hardware Implementation & Instrumentation

The hardware harness [`tsk29_adaptive_convolution_engine.sv`](file:///e:/MTech/LanChain/MTP/TSK29_ADAPTIVE_PE_EVALUATION/tsk29_adaptive_convolution_engine.sv) connects 16 physical `mac_unit_40b` modules with an autonomous compute feeder and adaptive mode controller.

### 4.1 Telemetry Counter Instrumentation
All metrics are captured by cycle-accurate RTL hardware registers:
- `telemetry_total_cycles`: Counted between `start_req` and `done_pulse`.
- `telemetry_compute_cycles`: Incremented strictly when `mac_enable` is asserted and computing.
- `telemetry_overhead_cycles`: Derived as `total_cycles - compute_cycles`.
- `telemetry_sram_act_reads`: Incremented upon each read access to activation RAM.
- `telemetry_sram_wt_reads`: Incremented by the number of active columns for each weight fetch.
- `telemetry_sram_writes`: Incremented upon writing completed activations into OFMAP RAM.
- `telemetry_skipped_zero_activations`: Incremented when an exact-zero activation bypasses weight fetch and compute.
- `telemetry_output_checksum`: 40-bit running arithmetic checksum of all 256 output elements.

---

## 5. Numerical Verification Scoreboarding

The testbench [`tb_tsk29_adaptive_evaluation.sv`](file:///e:/MTech/LanChain/MTP/TSK29_ADAPTIVE_PE_EVALUATION/tb_tsk29_adaptive_evaluation.sv) compares the output of each configuration element-by-element against the golden reference:
- Exact match check: `assert(rtl_accum_out == gold_accum_mem)`.
- Mismatch threshold: 0 allowable errors.
- Verification records are written to [`NUMERICAL_CORRECTNESS.csv`](file:///e:/MTech/LanChain/MTP/TSK29_ADAPTIVE_PE_EVALUATION/NUMERICAL_CORRECTNESS.csv).

