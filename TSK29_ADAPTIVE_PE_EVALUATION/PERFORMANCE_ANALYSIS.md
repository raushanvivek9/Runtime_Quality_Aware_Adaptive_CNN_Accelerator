# TSK-29 Performance Analysis & Evaluation Report

## 1. Executive Summary

This report presents an empirical analysis of the experimental results obtained from evaluating the seven configurations in milestone **TSK-29**.

All measurements were obtained from cycle-accurate SystemVerilog simulation of [`tsk29_adaptive_convolution_engine.sv`](file:///e:/MTech/LanChain/MTP/TSK29_ADAPTIVE_PE_EVALUATION/tsk29_adaptive_convolution_engine.sv) executing the real-world **ResNet-18 `layer1.0.conv1`** workload ($147,456$ MAC operations across 256 output elements).

---

## 2. Comprehensive Empirical Metrics Table

The following table summarizes the raw metrics captured in [`TSK29_RAW_METRICS.csv`](file:///e:/MTech/LanChain/MTP/TSK29_ADAPTIVE_PE_EVALUATION/TSK29_RAW_METRICS.csv) and derived results from [`TSK29_RESULTS.csv`](file:///e:/MTech/LanChain/MTP/TSK29_ADAPTIVE_PE_EVALUATION/TSK29_RESULTS.csv):

| Config ID | Configuration Name | Allocation | Active PEs | Passes | Sparse En | Total Cycles | Compute Cycles | Latency vs 64PE | Throughput vs 64PE | Weight SRAM Reads | Weight Read Reduction % | PE Footprint Reduction % | Bit-Exact Matches |
| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **C1** | `Fixed_16PE_Dense` | Fixed | 16 | 4 | 0 | 38,225 | 36,864 | 3.99x | 0.25x | 147,456 | 0.00% | 75.0% | 256 / 256 |
| **C2** | `Fixed_16PE_Sparse`| Fixed | 16 | 4 | 1 | 38,225 | 11,468 | 3.99x | 0.25x | 45,872 | **68.89%** | 75.0% | 256 / 256 |
| **C3** | `Fixed_32PE_Dense` | Fixed | 32 | 2 | 0 | 19,121 | 18,432 | 2.00x | 0.50x | 147,456 | 0.00% | 50.0% | 256 / 256 |
| **C4** | `Fixed_32PE_Sparse`| Fixed | 32 | 2 | 1 | 19,121 | 5,734 | 2.00x | 0.50x | 45,872 | **68.89%** | 50.0% | 256 / 256 |
| **C5** | `Fixed_64PE_Dense` | Fixed | 64 | 1 | 0 | **9,569** | 9,216 | **1.00x** | **1.00x** | 147,456 | 0.00% | 0.0% | 256 / 256 |
| **C6** | `Fixed_64PE_Sparse`| Fixed | 64 | 1 | 1 | **9,569** | **2,867** | **1.00x** | **1.00x** | **45,872** | **68.89%** | 0.0% | 256 / 256 |
| **C7** | `Adaptive_Sparse`  | Adaptive| 32 | 2 | 1 | 19,121 | 5,734 | 2.00x | 0.50x | 45,872 | **68.89%** | 50.0% | 256 / 256 |

---

## 3. Analysis of Sparse Execution Benefits

### 3.1 SRAM Weight Read Reductions
In dense execution mode, computing 16 output channels requires fetching a weight word for each active column on every reduction cycle, yielding $16 \text{ positions} \times 9 \text{ chunks} \times 64 \text{ terms} \times 16 \text{ channels} = 147,456$ weight SRAM reads.

In sparse mode:
- Exact-zero activations ($act\_data == 0$) are detected by the compute feeder.
- Weight SRAM addresses for the active columns are not requested.
- Total weight SRAM reads drop from **147,456 to 45,872**.
- This represents an exact **68.89% reduction in weight memory read traffic**, perfectly matching the measured 68.89% activation sparsity in the input tensor!

### 3.2 Compute Cycle Reductions
- In 64-PE mode, active MAC compute cycles drop from **9,216 to 2,867** (a 68.89% reduction in arithmetic switching activity).
- In 32-PE mode, active MAC compute cycles drop from **18,432 to 5,734**.
- In 16-PE mode, active MAC compute cycles drop from **36,864 to 11,468**.

### 3.3 Latency Behavior in Sparse Mode
- Because the uncompressed activation memory in this baseline is indexed sequentially, each zero-activation step takes 1 clock cycle to advance the address index without stalled memory waits.
- Consequently, total wall-clock cycle latency remains identical between dense and sparse modes for a given PE allocation (e.g., 9,569 cycles in 64-PE).
- Achieving cycle-latency compression in addition to memory-read reduction requires an indexed/compressed sparse feeder architecture (such as the run-length compressed feeder demonstrated in TSK-18).

---

## 4. Analysis of Adaptive PE Allocation Trade-offs

### 4.1 Latency Reality: Does Adaptive Allocation Reduce Cycles?
- **Finding**: **NO**. Adaptive PE allocation does NOT reduce total cycle latency compared to fixed 64-PE mode.
  - Fixed 64-PE executes all 16 output channels in **1 pass** ($9,569$ cycles).
  - Fixed 32-PE requires **2 passes** ($19,121$ cycles, $2.0\times$ latency).
  - Fixed 16-PE requires **4 passes** ($38,225$ cycles, $4.0\times$ latency).
  - Adaptive allocation selects 32-PE mode for this layer, resulting in $19,121$ cycles.

### 4.2 Resource and Power-Gating Trade-off
- **Finding**: While Adaptive Allocation does not beat Fixed 64-PE in throughput, it delivers a **50.0% reduction in active physical PE hardware**:
  - In 32-PE mode, 8 of the 16 PE columns are clamped to zero and clock-gated (`pe_array_40b`).
  - When a layer operates within a relaxed throughput budget (where degradation threshold $D_{max} \le 0.05$ permits $2\times$ latency), allocating 32 PEs eliminates unnecessary silicon dynamic toggle activity.
  - Adaptive allocation acts as a **dynamic power-performance dial**, trading execution time for reduced active hardware area.

---

## 5. Conclusions & Engineering Recommendations

1. **Clear Separation of Benefits**:
   - **Sparse Execution** provides massive memory traffic savings (**68.89% reduction in SRAM weight reads**) and **68.89% reduction in MAC switching cycles**.
   - **Adaptive PE Allocation** provides **hardware area / active PE throttling** (up to 75% PE deactivation in 16-PE mode), but introduces proportional multi-pass latency overheads ($2\times$ in 32-PE, $4\times$ in 16-PE).
2. **Unsupported Claims Avoidance**:
   - The project should **not claim that adaptive PE allocation speeds up convolution execution** relative to a fixed 64-PE array.
   - It should be accurately characterized as an **adaptive energy/resource-management mechanism** under throughput constraints.

