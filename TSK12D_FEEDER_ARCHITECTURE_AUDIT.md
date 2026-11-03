# TSK-12D-C: Feeder Architecture Audit and Mode-Dependent Operand Fetching Design

**Project:** Neural_Acc — Phase 2 RTL Microarchitecture and Verification  
**Repository:** `E:\MTech\LanChain\MTP`  
**RTL Directory:** `phase2_step1_microarchitecture_and_rtl`  
**Status:** Architecture Audit & Feeder Optimization Design (Pre-Modification)  
**Date:** November 2, 2026  

---

## 1. Executive Summary

This architecture audit evaluates the feasibility, safety, and performance impact of implementing **mode-dependent operand fetching and feeder gating (TSK-12D-C)** for the `Neural_Acc` accelerator core.

In the baseline Phase 2 implementation ([`datapath_compute_feeder.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv)), the compute feeder issues **10 SRAM read requests per K-reduction step** across all configurations:
- 8 read requests in Phase A (`ST_PAR_REQ_W`) across read ports 0..7 to fetch 16 column weights (2 weights per 32-bit word).
- 2 read requests in Phase B (`ST_PAR_REQ_A`) across read ports 0..1 to fetch 4 row activations (2 activations per 32-bit word).

When operating in 16-PE mode (4 columns active) or 32-PE mode (8 columns active), weights for inactive columns ($c \ge 4$ in 16-PE, $c \ge 8$ in 32-PE) are fetched from SRAM but subsequently ignored by the gated MAC units in [`pe_array_40b.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/pe_array_40b.sv).

This audit rigorously investigates the operand memory layout, bank interleaving, request scheduling, and downstream compatibility before modifying RTL.

---

## 2. Phase 1 Architecture Audit Findings

### 2.1 Trace of Existing Operand Schedule

#### 1. Which SRAM banks supply activation words?
In Phase B (`ST_PAR_REQ_A`), the feeder requests two 32-bit activation words via Read Port 0 and Read Port 1:
- `sram_rd_addr_bus[0] = active_base + (req_cnt_q * 10) + 8` (Word 8: activations for Rows 0 and 1)
- `sram_rd_addr_bus[1] = active_base + (req_cnt_q * 10) + 9` (Word 9: activations for Rows 2 and 3)

In [`multibank_sram_subsystem.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv), low-order bank interleaving routes addresses by:
$$\text{Bank ID} = \text{Addr}[2:0] = \text{Addr} \pmod 8$$
Since `active_base` is always 8-word aligned (`14'h0000` for Buffer A, `14'h1000` for Buffer B, with `active_base[2:0] == 3'b000`):
$$\text{Bank}(\text{Word 8}) = (10 \times K + 8) \pmod 8 = (2K) \pmod 8$$
$$\text{Bank}(\text{Word 9}) = (10 \times K + 9) \pmod 8 = (2K + 1) \pmod 8$$

**Bank Allocation across K-steps:**
- $K=0$: Word 8 is in **Bank 0**, Word 9 is in **Bank 1**.
- $K=1$: Word 8 is in **Bank 2**, Word 9 is in **Bank 3**.
- $K=2$: Word 8 is in **Bank 4**, Word 9 is in **Bank 5**.
- $K=3$: Word 8 is in **Bank 6**, Word 9 is in **Bank 7**.
- $K=4$: Word 8 is in **Bank 0**, Word 9 is in **Bank 1** (cyclic wrap mod 8).

Activation words always reside in the even/odd bank pair `(2K mod 8, 2K+1 mod 8)`.

---

#### 2. Which SRAM banks supply weight words?
In Phase A (`ST_PAR_REQ_W`), the feeder requests 8 words across Read Ports $0 \dots 7$:
$$\text{sram\_rd\_addr\_bus}[b_i] = \text{active\_base} + (K \times 10) + b_i \quad \text{for } b_i \in \{0, 1, 2, 3, 4, 5, 6, 7\}$$
The bank targeted by Read Port $b_i$ is:
$$\text{Bank}(b_i) = (10 \times K + b_i) \pmod 8 = (2K + b_i) \pmod 8$$

Because $b_i$ iterates through $\{0, 1, 2, 3, 4, 5, 6, 7\}$, the set of targeted banks $\{(2K + b_i) \pmod 8\}$ forms a complete permutation of all 8 SRAM banks $\{0, 1, 2, 3, 4, 5, 6, 7\}$ for every $K$-step. In 64-PE mode, **all 8 SRAM banks** supply weight words with zero intra-feeder bank conflicts.

---

#### 3. Which banks are accessed for each PE configuration?
Each weight word $w \in \{0, \dots, 7\}$ holds two 16-bit column weights:
- Word 0: Columns 0 and 1
- Word 1: Columns 2 and 3
- Word 2: Columns 4 and 5
- Word 3: Columns 6 and 7
- Word 4: Columns 8 and 9
- Word 5: Columns 10 and 11
- Word 6: Columns 12 and 13
- Word 7: Columns 14 and 15

Configuration breakdown:
- **16-PE Mode (Cols 0..3 active):**
  - Only Columns 0, 1, 2, 3 are used.
  - Required weights reside strictly in **Word 0** and **Word 1**.
  - Words 2 through 7 (Ports 2..7) hold weights for inactive columns 4..15.
  - Active weight banks: **2 banks** ($(2K) \pmod 8$ and $(2K+1) \pmod 8$).
  - Inactive weight banks: **6 banks** ($(2K+2 \dots 2K+7) \pmod 8$).
- **32-PE Mode (Cols 0..7 active):**
  - Only Columns 0 through 7 are used.
  - Required weights reside strictly in **Words 0, 1, 2, 3**.
  - Words 4 through 7 (Ports 4..7) hold weights for inactive columns 8..15.
  - Active weight banks: **4 banks** ($(2K+0 \dots 2K+3) \pmod 8$).
  - Inactive weight banks: **4 banks** ($(2K+4 \dots 2K+7) \pmod 8$).
- **64-PE Mode (Cols 0..15 active):**
  - All 16 columns active; all 8 words (Ports 0..7) are required across **all 8 banks**.

---

#### 4. How row activations and column weights are aligned?
- **Activation Slicing:**
  `act_wire[0] = sram_rd_dout_bus[0][15:0]`  (Row 0 activation)  
  `act_wire[1] = sram_rd_dout_bus[0][31:16]` (Row 1 activation)  
  `act_wire[2] = sram_rd_dout_bus[1][15:0]`  (Row 2 activation)  
  `act_wire[3] = sram_rd_dout_bus[1][31:16]` (Row 3 activation)
- **Weight Slicing:**
  For $w \in [0..7]$:
  `weight_stage_d[2w]   = sram_rd_dout_bus[w][15:0]`  (Col $2w$ weight)  
  `weight_stage_d[2w+1] = sram_rd_dout_bus[w][31:16]` (Col $2w+1$ weight)
- **PE Array Delivery:**
  In `pe_array_40b.sv`, physical PE$(r, c)$ receives `act_data_row[r]` and `weight_data_col[c]`, computing:
  $$\text{accum}[r][c] \leftarrow \text{accum}[r][c] + (\text{act\_data\_row}[r] \times \text{weight\_data\_col}[c])$$
  When PE column $c$ is disabled (`col_active[c] == 0`), the MAC unit is gated off and its accumulator remains strictly undisturbed.

---

#### 5. How the feeder handles request backpressure and read responses?
In `datapath_compute_feeder.sv`:
- **Phase A (`ST_PAR_REQ_W`):** Feeder asserts read requests and waits for `&sram_rd_ready_bus`. If any requested port experiences backpressure (e.g., contention from DMA Port A), the feeder holds request addresses stable until ready.
- **Phase B (`ST_PAR_REQ_A`):** Feeder simultaneously:
  1. Latches returning weight data when `&sram_rd_rvalid_bus` is asserted.
  2. Asserts read requests on Port 0 and Port 1 for activations, waiting for `sram_rd_ready_bus[0] && sram_rd_ready_bus[1]`.
- **Phase C (`ST_PAR_COMPUTE`):** Feeder waits for returning activations (`sram_rd_rvalid_bus[0] && sram_rd_rvalid_bus[1]`), pulses `compute_enable_in = 1'b1`, increments `exec_cnt_q` and `req_cnt_q`, and advances to the next K-step or `ST_COMP_DONE`.

**Critical Audit Insight on Gating:**
In baseline `ST_PAR_REQ_A`, the FSM checks `if (&sram_rd_rvalid_bus)` to latch weights. If read ports 2..7 are gated off in 16-PE mode, `sram_rd_rvalid_bus[2..7]` will remain `0`. Thus, **the read response check must be made mode-dependent**:
- 16-PE: Check `if (sram_rd_rvalid_bus[0] && sram_rd_rvalid_bus[1])` and zero-clamp `weight_stage_d[4..15] = '0`.
- 32-PE: Check `if (&sram_rd_rvalid_bus[3:0])` and zero-clamp `weight_stage_d[8..15] = '0`.
- 64-PE: Check `if (&sram_rd_rvalid_bus[7:0])`.

---

#### 6. Whether the current fixed 10-word stride is part of the memory-layout contract?
**YES. The 10-word stride is an inviolable architectural contract between system memory, DMA, and the accelerator feeder.**
- **Evidence:**
  Across all testbenches (`tb_parallel_pe_operand_delivery.sv`, `tb_tsk10_cnn_workload.sv`, `tb_tsk11_ofmap_integration.sv`, `tb_tsk12_adaptive_experiment.sv`), input operands are packed into system memory via `pack_k_step(k * 10, w_packed, a_packed)`.
  The DMA controller transfers frames using `dma_transfer_len = k_len * 10 * 4` bytes.
  Every K-step frame occupies exactly 10 contiguous 32-bit words (40 bytes) in SRAM Buffer A or B.
- **Contract Preservation:**
  Altering the frame size to 4 words in 16-PE mode would break every existing testbench, disrupt DMA burst boundaries, and require dynamic packing logic in host drivers.
  **Therefore, the 10-word frame stride must remain strictly preserved.** Feeder gating must operate by selectively disabling read requests within the fixed 10-word frame, keeping address stride $K \times 10$ invariant.

---

#### 7. Whether changing the number of fetched words affects the next K-step or a subsequent layer?
- By preserving the 10-word frame stride (`active_base + req_cnt_q * 10`), the starting address of step $K+1$ is always `active_base + (K+1) * 10`.
- Gating inactive read ports has **zero effect on subsequent K-step address generation** and **zero effect on subsequent layers**.
- Unread SRAM words (offsets 2..7 in 16-PE, offsets 4..7 in 32-PE) remain in SRAM unaccessed, saving memory read energy and freeing banks from arbitration.

---

## 3. Structural Bank Conflict Analysis: Why Compute Latency is Invariant

A key question is whether Phase A (`ST_PAR_REQ_W`) and Phase B (`ST_PAR_REQ_A`) could be merged into a single cycle for 16-PE mode (fetching 2 weights + 2 activations = 4 words simultaneously across 8 read ports).

### Mathematical Proof of Structural Hazard:
Recall the bank mapping for 16-PE operands:
$$\text{Bank}(\text{Word 0, Col 0..1 Weights}) = (10K + 0) \pmod 8 = (2K) \pmod 8$$
$$\text{Bank}(\text{Word 1, Col 2..3 Weights}) = (10K + 1) \pmod 8 = (2K + 1) \pmod 8$$
$$\text{Bank}(\text{Word 8, Row 0..1 Activations}) = (10K + 8) \pmod 8 = (2K) \pmod 8$$
$$\text{Bank}(\text{Word 9, Row 2..3 Activations}) = (10K + 9) \pmod 8 = (2K + 1) \pmod 8$$

Notice:
$$\mathbf{\text{Bank}(\text{Word 8}) \equiv \text{Bank}(\text{Word 0}) \pmod 8}$$
$$\mathbf{\text{Bank}(\text{Word 9}) \equiv \text{Bank}(\text{Word 1}) \pmod 8}$$

Word 8 (activations) and Word 0 (weights) reside in the **exact same physical SRAM bank**!
Similarly, Word 9 and Word 1 reside in the **exact same physical SRAM bank**!
Because each hybrid SRAM bank possesses only a single read port (Port B), **reading Word 0 and Word 8 concurrently is physically impossible without a bank collision stall**.

### Architectural Implication:
1. Feeder Phase A (`ST_PAR_REQ_W`) and Phase B (`ST_PAR_REQ_A`) **must remain sequential**.
2. **Compute latency ($T_{\text{comp}}$) is fundamentally invariant:**
   - $K=1$: 4 cycles
   - $K=2$: 7 cycles
   - $K=4$: 13 cycles
   - $K=8$: 25 cycles
3. Feeder gating optimizes **SRAM read traffic, memory bandwidth, and bank conflict vulnerability**, but does not alter compute cycle latency.

---

## 4. Phase 2 Safe Feeder Optimization Specification

### 4.1 Interface Update in `datapath_compute_feeder.sv`
Add input port `input logic [1:0] cfg_mode`:
- `2'b00`: 16-PE Mode
- `2'b01`: 32-PE Mode
- `2'b10`: 64-PE Mode (default fallback)

In `neural_acc_integrated_top.sv`, connect `pe_array_cfg_mode` to `.cfg_mode(pe_array_cfg_mode)`.

### 4.2 Revised Operand Schedule per Mode

| Metric / Phase | 16-PE Mode (`2'b00`) | 32-PE Mode (`2'b01`) | 64-PE Mode (`2'b10`) |
| :--- | :---: | :---: | :---: |
| **Active Columns** | Cols 0..3 (4 cols) | Cols 0..7 (8 cols) | Cols 0..15 (16 cols) |
| **Phase A Active Ports** | Ports 0, 1 (2 ports) | Ports 0, 1, 2, 3 (4 ports) | Ports 0..7 (8 ports) |
| **Phase A Gated Ports** | Ports 2..7 (6 ports idle) | Ports 4..7 (4 ports idle) | None (0 ports idle) |
| **Phase A Address Span** | $10K + 0 \dots 10K + 1$ | $10K + 0 \dots 10K + 3$ | $10K + 0 \dots 10K + 7$ |
| **Phase A Ready Check** | `sram_rd_ready_bus[0] && sram_rd_ready_bus[1]` | `&sram_rd_ready_bus[3:0]` | `&sram_rd_ready_bus[7:0]` |
| **Phase B Active Ports** | Ports 0, 1 (2 ports) | Ports 0, 1 (2 ports) | Ports 0, 1 (2 ports) |
| **Phase B Address Span** | $10K + 8 \dots 10K + 9$ | $10K + 8 \dots 10K + 9$ | $10K + 8 \dots 10K + 9$ |
| **Phase B Weights Latch** | Ports 0, 1 (`weight_stage[4..15]=0`) | Ports 0..3 (`weight_stage[8..15]=0`) | Ports 0..7 (`weight_stage[0..15]`) |
| **Reads per K-Step** | **4 reads** | **6 reads** | **10 reads** |
| **Read Reduction vs Baseline** | **-60.0%** (4 vs 10) | **-40.0%** (6 vs 10) | **0.0%** (Invariant) |
| **Compute Cycles per K-Step** | 3 cycles (Invariant) | 3 cycles (Invariant) | 3 cycles (Invariant) |

---

## 5. Implementation Plan & Safety Constraints

1. **RTL Changes:**
   - Update `datapath_compute_feeder.sv` to latch `cfg_mode` on `compute_start`, gate `sram_rd_req_bus` during `ST_PAR_REQ_W`, and qualify ready/rvalid checks per mode.
   - Connect `.cfg_mode(pe_array_cfg_mode)` in `neural_acc_integrated_top.sv`.
2. **Safety Invariants:**
   - Zero changes to the 5 protected baseline RTL files.
   - 64-PE mode behavior remains 100% bit-exact and cycle-identical.
   - TSK-12D-B OFMAP drain optimization preserved.
   - All 19 regression suites must pass with zero failures.
3. **Experiment Metrics:**
   - Generate new dataset `tsk12d_feeder_optimization_results.csv` recording both requested and accepted reads, stalls, and MAC events.

