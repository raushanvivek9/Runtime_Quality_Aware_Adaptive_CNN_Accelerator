# TSK-13: Limitations and Reproducibility Manual
## Research Guide, Limitations Audit, and Verification Handbook for Neural_Acc

**Project:** Neural_Acc — Phase 2 RTL Microarchitecture and Verification  
**Repository:** `E:\MTech\LanChain\MTP`  
**RTL Directory:** `phase2_step1_microarchitecture_and_rtl`  
**Date:** November 2, 2026  
**Document Purpose:** Reproducibility protocol, dataset traceability, comprehensive research limitations audit, and Phase 3 transition roadmap.  
**Classification:** **`READY_WITH_LIMITATIONS`**

---

## 1. Overview & Reproducibility Standard

This document serves as the authoritative reproducibility manual and research limitations audit for the `Neural_Acc` accelerator following the integration of **TSK-12D-B (Mode-Dependent OFMAP Drain Optimization)** and **TSK-12D-C (Mode-Dependent Operand Fetching and Feeder Gating)**.

To meet the highest standards of scientific reproducibility, every experimental claim, simulation cycle count, memory transaction count, and verification assertion must be independently reproducible from the repository source code without manual intervention or proprietary tool dependencies.

---

## 2. Step-by-Step Reproducibility Guide

### 2.1 Toolchain Prerequisites
The entire verification harness runs on open-source, standard tools:
- **HDL Simulator:** Icarus Verilog (`iverilog`) version 12.0 (stable).
- **Simulation Engine:** `vvp` runtime engine version 12.0 (stable).
- **Automation / Reference Model:** Python 3.10+ (tested on Python 3.12.3).
- **Execution Shell:** Linux bash (native Linux or Ubuntu on Windows Subsystem for Linux — WSL2).

### 2.2 Execution Commands

#### 1. Full 19-Suite Automated Regression Run
To re-run the entire test suite, compile all 19 testbenches, evaluate all 11,712 assertion checks, and verify exit codes:
```bash
wsl bash -c "cd /mnt/e/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl && python3 run_regression.py"
```
**Expected Outcome:**
- Total Testbenches: 19
- Passed: 19, Failed: 0
- Checks Evaluated: 11,712
- Grand Total Passed: 11,712
- Exit Code: `0`

#### 2. Standalone Adaptive PE Allocation Experiment (Suite 19)
To run only the comprehensive 35-workload experiment evaluating latency, memory access counts, MAC events, and CSV export:
```bash
wsl bash -c "cd /mnt/e/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl && iverilog -g2012 -o /tmp/sim_s13 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv ping_pong_buffer_controller.sv hybrid_sram_bank.sv multibank_sram_subsystem.sv dma_controller.sv layer_command_sequencer.sv dma_to_sram_write_adapter.sv datapath_compute_feeder.sv ofmap_drain_controller.sv neural_acc_integrated_top.sv tb_tsk12_adaptive_experiment.sv && vvp /tmp/sim_s13"
```
**Expected Outcome:**
- 5,846 checks evaluated, 5,846 passed, 0 failed.
- Generates updated `tsk12d_feeder_optimization_results.csv` in local directory and root.

#### 3. Standalone CNN Reference Model Verification
To verify the independent Python reference model that computes mathematical ground truth for multi-K reduction steps:
```bash
python3 phase2_step1_microarchitecture_and_rtl/functional_cnn_reference.py
```
**Expected Outcome:**
- All self-tests pass with zero assertion mismatches.

---

## 3. Dataset Traceability and Integrity

The experimental results are preserved across a traceable lineage of CSV datasets. All historical files must remain bit-exact.

```
+------------------------------------+      +------------------------------------+
|   tsk12_experiment_results.csv     |      | tsk12d_instrumentation_results.csv |
| (16 columns, 32 runs, pre-opt)     |      | (20 columns, 32 runs, added MACs)  |
+-----------------+------------------+      +-----------------+------------------+
                  |                                           |
                  +---------------------+---------------------+
                                        |
                                        v
                    +------------------------------------+
                    | tsk12d_drain_optimization_results.csv|
                    | (21 columns, 35 runs, opt OFMAP)   |
                    +-------------------+----------------+
                                        |
                                        v
                    +------------------------------------+
                    | tsk12d_feeder_optimization_results.csv|
                    | (24 columns, 35 runs, opt Feeder)  |
                    +-------------------+----------------+
                                        |
                                        v
                    +------------------------------------+
                    |   tsk13_consolidated_results.csv   |
                    | (38 columns, 35 runs, comprehensive)|
                    +------------------------------------+
```

### 3.1 Dataset Inventory & Checksums

| Dataset Filename | Scope & Milestone | Columns | Rows | Verification Integrity |
| :--- | :--- | :---: | :---: | :---: |
| `tsk12_experiment_results.csv` | TSK-12B Initial Baseline | 16 | 32 data + 1 header | Preserved Bit-Exact |
| `tsk12d_instrumentation_results.csv` | TSK-12D-A HW MAC Instrumentation | 20 | 32 data + 1 header | Preserved Bit-Exact |
| `tsk12d_drain_optimization_results.csv` | TSK-12D-B OFMAP Drain Optimization | 21 | 35 data + 1 header | Preserved Bit-Exact |
| `tsk12d_feeder_optimization_results.csv` | TSK-12D-C Feeder Gating Optimization | 24 | 35 data + 1 header | Preserved Bit-Exact |
| `tsk13_consolidated_results.csv` | TSK-13 Final Consolidated Research Dataset | 38 | 35 data + 1 header | Verified & Validated |

### 3.2 Key Consolidated Metric Formulas
In `tsk13_consolidated_results.csv`:
- `total_stalls = feeder_stalls + drain_stalls`
- `hw_mac_enabled = k_steps * active_pes = hw_mac_skipped + hw_mac_executed`
- `read_reduction_pct = ((baseline_sram_reads - sram_rd_accepted) / baseline_sram_reads) * 100`
- `write_reduction_pct = ((baseline_sram_writes - sram_wr_accepted) / baseline_sram_writes) * 100`
- `total_access_reduction_pct = ((baseline_total_accesses - total_sram_accesses) / baseline_total_accesses) * 100`
- `latency_speedup_pct = ((baseline_total_cycles - total_cycles) / baseline_total_cycles) * 100`

---

## 4. Comprehensive Audit of Research Limitations

To maintain rigorous scientific standards, researchers must not overstate the capabilities of the current implementation. The following structural limitations are verified to exist in the architecture:

### 4.1 External Degradation Estimates (No On-Chip Oracle)
- **RTL Reality:** In [`adaptive_pe_controller.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv#L110-L135), the decision logic compares `cmd_degradation_hat_16` and `cmd_degradation_hat_32` against a fixed register `target_threshold` ($3,277$).
- **Limitation:** The hardware has **no autonomous ability to evaluate output accuracy or loss**. It depends 100% on software profiling or compilation heuristics providing accurate degradation estimates.
- **Risk:** Inaccurate compiler estimates could cause the hardware to under-allocate PEs (degrading network inference accuracy) or over-allocate PEs (sacrificing throughput and energy savings).

### 4.2 Invariant 10-Word SRAM Frame Stride (Memory Fragmentation)
- **RTL Reality:** In [`datapath_compute_feeder.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv#L255), weight addresses for reduction step $K$ are strictly computed as:
  $$\text{addr} = \text{active\_base} + 10K + \text{offset}$$
- **Limitation:** When operating in 16-PE mode (reading only Words 0 and 1) or 32-PE mode (reading only Words 0..3), the unaccessed words (offsets 2..7 or 4..7) remain allocated but empty in SRAM Buffer A/B.
- **Memory Footprint Impact:** Feeder gating saves **read energy and port bandwidth**, but **does not reduce SRAM storage footprint**. Denser packing without gaps would require dynamic stride hardware in both the DMA engine and feeder.

### 4.3 Inability to Directly Reuse Layer Outputs as Layer Inputs
- **RTL Reality:**
  - **OFMAP Drain Serialization ([`ofmap_drain_controller.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/ofmap_drain_controller.sv#L103-L140)):** Accumulator outputs are serialized as 40-bit quantities packed across **two 32-bit words per PE** in column-major order:
    - Word $2i$: `accum[31:0]`
    - Word $2i+1$: `accum[39:32]` sign-extended to 32 bits
  - **Feeder Ingestion Requirement ([`datapath_compute_feeder.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv#L121-L124)):** The feeder expects input activations packed as **two 16-bit signed integers per 32-bit word** in Words 8 and 9 of a 10-word frame.
- **Architectural Implication:** **Layer $N$ outputs cannot be directly chained into Layer $N+1$ inputs within SRAM.** Direct ping-pong layer chaining without host/DMA intervention is physically impossible in the current hardware because the accelerator lacks an on-chip quantization and tensor-restriding engine.

### 4.4 Compact OFMAP Host Unpacking Requirement
- Under TSK-12D-B, the OFMAP drain writes only active PE words (32 words in 16-PE, 64 words in 32-PE, 128 words in 64-PE).
- **Host Requirement:** The host driver or DMA controller must query `active_cfg_mode` or the command response before reading back the OFMAP buffer. If the host naively reads a fixed 128 words after a 16-PE layer, it will ingest stale or unwritten data from words 32..127.

### 4.5 Structural Bank Conflict (Compute Latency Invariance)
- **Mathematical Proof:** Weight Word 0 and Activation Word 8 both map to Bank $(2K) \pmod 8$. Because each hybrid SRAM bank contains only a single read port, reading weights and activations in the same cycle triggers a physical bank conflict.
- **Implication:** Compute latency ($T_{\text{comp}} = 3K + 1$) is **physically invariant**. Feeder gating reduces memory traffic, but does not accelerate the compute phase.

### 4.6 Lack of Physical Power, Energy, and Area Measurements
- **Simulation Boundary:** All reported savings (-60% read requests, -71.43% total SRAM accesses, $3.23\times$ latency speedup) are derived from cycle-accurate RTL simulation.
- **Physical Exclusion:** **No logic synthesis, standard cell placement, clock tree routing, parasitic extraction (SPEF), or gate-level power simulation (VCD/SAIF) has been performed.**
- **Strict Rule:** Functional transaction reductions eliminate dynamic switching events in unaccessed banks, but must not be cited as physical silicon power or energy numbers.

### 4.7 Lack of End-to-End CNN Inference Engine
- The current accelerator core executes single tile GEMM / 2D convolution reduction operations.
- Dedicated hardware for activation functions (ReLU, GELU, Sigmoid), spatial pooling (MaxPooling, AvgPooling), residual additions, and batch normalization is not integrated on-chip. Complete model inference requires host software orchestration between layer kernel launches.

---

## 5. Technical Roadmap for Future Development (Phase 3)

To address the limitations identified above and prepare the architecture for silicon tape-out and top-tier conference publication, the following microarchitectural enhancements are recommended:

1. **Hardware Quantization & Activation Unit (HQAU):**
   - Insert an inline post-processing pipeline stage between the accumulator shadow registers and OFMAP drain serializer.
   - Support programmable affine requantization ($Y = \text{clamp}(\lfloor (X - Z) \times S \rceil)$) from 40-bit accumulators down to 16-bit or 8-bit activations, accompanied by activation functions (ReLU, Clipped ReLU).
   - This will enable direct on-chip layer-to-layer ping-pong pipelining without DMA or host round-trips.
2. **Dense SRAM Ingestion Striding:**
   - Enhance `dma_controller.sv` and `datapath_compute_feeder.sv` with runtime programmable frame strides ($4, 6, 10$ words) to eliminate memory fragmentation during sub-64-PE layers.
3. **Physical Design & Characterization:**
   - Synthesize the RTL in a commercial foundry standard cell library (e.g., TSMC 28nm HPC+ or 65nm GP).
   - Perform full place-and-route, sign-off static timing analysis (STA at $\ge 500\text{ MHz}$), and gate-level power analysis using PrimeTime PX or Cadence Joules driven by switching activity vector dumps.

---

## 6. Final Research Evaluation Verdict

### Classification: **`READY_WITH_LIMITATIONS`**

### Verdict Breakdown:
- **`READY_FOR_PAPER_DRAFT` (Deferred):** Deferred until physical synthesis/P&R data is gathered and direct layer-to-layer chaining is resolved.
- **`READY_WITH_LIMITATIONS` (Approved):** The microarchitecture, testbench suites, and experimental CSV datasets represent a complete, mathematically validated, fully reproducible hardware research artifact. All 11,712 assertion checks pass with zero defects.
- **`NOT_READY` (Rejected):** The architecture is thoroughly verified, robust against contention and invalid commands, fully documented, and backed by verifiable hardware traces.

