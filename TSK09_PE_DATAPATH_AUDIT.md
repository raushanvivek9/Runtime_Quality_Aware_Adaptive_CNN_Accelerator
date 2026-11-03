# TSK-09: PE Datapath Independent Audit & Parallel Computation Architecture

## 1. Executive Summary & Verdict

### Final Verdict: **FAIL (for Genuine Parallel 4x16 Computation)** / **PASS_WITH_LIMITATIONS (Control Plane & Scalar Broadcast Only)**

An exhaustive architectural and source-level audit of the Neural_Acc Phase 2 RTL was conducted across `pe_array_40b.sv`, `datapath_compute_feeder.sv`, `neural_acc_integrated_top.sv`, `multibank_sram_subsystem.sv`, `dma_to_sram_write_adapter.sv`, `tb_neural_acc_integrated_top.sv`, and `tb_workload_validation.sv`.

### Core Audit Finding
In the integrated accelerator top-level (`neural_acc_integrated_top.sv`):
1. **Identical Operand Broadcast to All 64 PEs:** The datapath compute feeder (`datapath_compute_feeder.sv`) fetches **one single 32-bit word per cycle** from a single SRAM read port (Port B0), unpacking it into one scalar 16-bit activation and one scalar 16-bit weight.
2. **Global Tie-Off of Independent Ports:** In `neural_acc_integrated_top.sv`, the scalar activation is broadcast to all 4 rows, and the scalar weight is broadcast to all 4 rows $\times$ 16 columns (all 64 PEs). The independent 2D per-PE input ports of the PE array (`dummy_act_data`, `dummy_act_mask`) are hardwired to zero.
3. **Severe SRAM Port Underutilization:** The multi-bank SRAM subsystem (`multibank_sram_subsystem.sv`) contains 8 parallel 32-bit read ports and 8 parallel 32-bit write ports. However, **7 of the 8 read ports and 7 of the 8 write ports are permanently tied to ground (`1'b0`)** in the top-level wrapper.
4. **Redundant Execution:** Every active PE in the 64-PE array receives the exact same inputs at every clock cycle, resulting in **64 identical copies of a single scalar MAC computation**. The accelerator currently has the effective arithmetic throughput of a **single 1-MAC unit**, despite instantiating 64 physical DSP blocks.
5. **Testbench Isolation Artifacts:** The existing testbenches (`tb_neural_acc_integrated_top.sv` and `tb_workload_validation.sv`) achieved 800 passing checks because they only asserted that all PEs match the same scalar value (e.g. Scenario 20 checks that all 64 PEs equal `-304`). When the testbench author wanted to test distinct sequences (Category 7), they **bypassed the integrated top-level entirely** and instantiated a standalone `u_standalone_pe_array` driven directly by testbench loops.

---

## 2. Comprehensive Datapath Signal Tracing

```
=======================================================================================================================
CURRENT TOP-LEVEL INTEGRATION DATAPATH (neural_acc_integrated_top.sv)
=======================================================================================================================

  AXI Read Channel (m_axi_rdata[31:0])
         │
         ▼
  dma_controller.sv (TSK-06)
         │  (AW, W, B Master Write)
         ▼
  dma_to_sram_write_adapter.sv
         │  sram_wr_req_0, sram_wr_addr_0, sram_wr_din_0[31:0]
         ▼
  multibank_sram_subsystem.sv (TSK-03)
     ├── Port A0 (Write): Connected to DMA Adapter
     ├── Ports A1..A7 (Write): TIED TO 0 (neural_acc_integrated_top.sv:201-206)
     │
     ├── Port B0 (Read): Connected to Feeder
     └── Ports B1..B7 (Read): TIED TO 0 (neural_acc_integrated_top.sv:230-235)
         │
         │ sram_rd_dout_0[31:0] (1 word / cycle = 32 bits)
         ▼
  datapath_compute_feeder.sv
     ├── sram_act_sample    = sram_rd_dout_0[15:0]   (1 scalar activation)
     └── sram_weight_sample = sram_rd_dout_0[31:16]  (1 scalar weight)
         │
         ├─────────────────────────────────────────────┐
         │ feeder_act_sample                           │ feeder_weight_sample
         ▼                                             ▼
  neural_acc_integrated_top.sv:258-265         neural_acc_integrated_top.sv:261-264
     act_data_row[0..3] = feeder_act_sample        weight_data[0..3][0..15] = feeder_weight_sample
         │                                             │
         │ (Broadcast across 4 rows)                   │ (Broadcast across 4 rows x 16 cols)
         ▼                                             ▼
  pe_array_40b.sv (TSK-01)
     ├── pe_act_in[r][c]    = broadcast_act ? act_data_row[r] : act_data[r][c]  --> ALL PEs GET SAME ACT
     ├── pe_weight_in[r][c] = weight_data[r][c]                                --> ALL PEs GET SAME WEIGHT
     └── dummy_act_data[r][c] = '0                                              --> UNBROADCAST PORTS TIED TO 0
         │
         ▼
  64x mac_unit_40b Instances
     accum_out[0..3][0..15] = ALL COMPUTE IDENTICAL SCALAR DOT PRODUCT (accum_out[r][c] == accum_out[0][0])
=======================================================================================================================
```

### Exact Signal Tracing Table

| Stage | Source Signal | Target Signal | File & Lines | Signal Characteristics & Observations |
|---|---|---|---|---|
| **Ingestion** | `m_axi_rdata[31:0]` | `u_dma.m_axi_rdata` | `neural_acc_integrated_top.sv:435` | 32-bit external memory data word ingested into DMA FIFO. |
| **Ingestion** | `dma_wdata[31:0]` | `s_axi_wdata[31:0]` | `neural_acc_integrated_top.sv:472` | DMA AXI master write bus driving adapter. |
| **Adapter** | `s_axi_wdata[31:0]` | `sram_wr_din_0[31:0]` | `dma_to_sram_write_adapter.sv:68` | Single-cycle translation to native SRAM Port A write. |
| **SRAM Write** | `sram_wr_req_0` | `sram_wr_req_bus[0]` | `neural_acc_integrated_top.sv:192` | Only Port 0 connected. |
| **SRAM Write** | `'0` | `sram_wr_req_bus[1..7]` | `neural_acc_integrated_top.sv:202` | **Ports 1..7 tied off to 0.** |
| **SRAM Read** | `sram_rd_req_0` | `sram_rd_req_bus[0]` | `neural_acc_integrated_top.sv:223` | Only Port 0 connected. |
| **SRAM Read** | `'0` | `sram_rd_req_bus[1..7]` | `neural_acc_integrated_top.sv:232` | **Ports 1..7 tied off to 0.** |
| **Feeder Unpack** | `sram_rd_dout_0[15:0]` | `sram_act_sample` | `datapath_compute_feeder.sv:90` | Single 16-bit scalar activation per cycle. |
| **Feeder Unpack** | `sram_rd_dout_0[31:16]` | `sram_weight_sample` | `datapath_compute_feeder.sv:91` | Single 16-bit scalar weight per cycle. |
| **Feeder Out** | `sram_act_sample` | `feeder_act_sample` | `datapath_compute_feeder.sv:101` | Scalar sample output. |
| **Feeder Out** | `sram_weight_sample` | `feeder_weight_sample` | `datapath_compute_feeder.sv:103` | Scalar sample output. |
| **Feeder Out** | `1'b1` | `broadcast_act` | `datapath_compute_feeder.sv:97` | Hardcoded broadcast enable flag. |
| **Top Interconnect** | `feeder_act_sample` | `act_data_row[0..3]` | `neural_acc_integrated_top.sv:259` | Replicated across all 4 rows. |
| **Top Interconnect** | `feeder_weight_sample`| `weight_data[0..3][0..15]` | `neural_acc_integrated_top.sv:262` | Replicated across all 4 rows and 16 cols. |
| **Top Interconnect** | `'0` | `dummy_act_data[0..3][0..15]` | `neural_acc_integrated_top.sv:275` | 2D per-PE activation inputs tied off. |
| **PE Array Input** | `act_data_row[r]` | `pe_act_in[r][c]` | `pe_array_40b.sv:117` | Mux selects row broadcast: all PEs get scalar sample. |
| **PE Array Input** | `weight_data[r][c]` | `pe_weight_in[r][c]` | `pe_array_40b.sv:119` | All PEs receive identical scalar weight. |
| **PE Enable** | `feeder_compute_enable_in`| `pe_mac_enable` | `adaptive_pe_controller.sv:115`, `pe_array_40b.sv:109` | Synchronous compute enable gating. |
| **Accumulator** | `u_pe_mac.accum_q` | `accum_out[r][c]` | `pe_array_40b.sv:141` | Independent registers, identical values computed. |

---

## 3. Evaluation of Current Computation

### Does each PE compute a distinct output?
**No.** All active PEs compute the exact same mathematical value.

### Source-Level Evidence:
1. **`datapath_compute_feeder.sv` (Lines 90–103):**
   ```systemverilog
   wire [ACT_WIDTH-1:0]    sram_act_sample    = sram_rd_dout[ACT_WIDTH-1:0];
   wire [WEIGHT_WIDTH-1:0] sram_weight_sample = sram_rd_dout[DATA_WIDTH-1:ACT_WIDTH];

   assign sram_rd_req     = (state_q == ST_FETCH) && (req_cnt_q < k_total_q) && sram_rd_ready;
   assign sram_rd_addr    = active_base + req_cnt_q[SRAM_ADDR_W-1:0];
   assign broadcast_act   = 1'b1;
   assign act_sample      = (sram_rd_rvalid && (state_q == ST_FETCH)) ? sram_act_sample : '0;
   assign act_mask_sample = (sram_rd_rvalid && (state_q == ST_FETCH));
   assign weight_sample   = (sram_rd_rvalid && (state_q == ST_FETCH)) ? sram_weight_sample : '0;
   ```
   *Finding:* The feeder is architected around a single scalar pair `(act_sample, weight_sample)` packed into one 32-bit SRAM word.

2. **`neural_acc_integrated_top.sv` (Lines 256–265):**
   ```systemverilog
   genvar dr_pe, dc_pe;
   generate
       for (dr_pe = 0; dr_pe < ROWS; dr_pe = dr_pe + 1) begin : gen_pe_act_broadcast
           assign act_data_row[dr_pe] = feeder_act_sample;
           assign act_mask_row[dr_pe] = feeder_act_mask;
           for (dc_pe = 0; dc_pe < COLS; dc_pe = dc_pe + 1) begin : gen_pe_w_broadcast
               assign weight_data[dr_pe][dc_pe] = feeder_weight_sample;
           end
       end
   endgenerate
   ```
   *Finding:* The single scalar `feeder_act_sample` is duplicated across all 4 rows, and `feeder_weight_sample` is duplicated across all 64 elements of `weight_data[0:3][0:15]`.

3. **`neural_acc_integrated_top.sv` (Lines 268–279):**
   ```systemverilog
   logic signed [ACT_WIDTH-1:0] dummy_act_data [0:ROWS-1][0:COLS-1];
   logic                        dummy_act_mask [0:ROWS-1][0:COLS-1];

   genvar dr, dc;
   generate
       for (dr = 0; dr < ROWS; dr = dr + 1) begin : gen_dummy_r
           for (dc = 0; dc < COLS; dc = dc + 1) begin : gen_dummy_c
               assign dummy_act_data[dr][dc] = '0;
               assign dummy_act_mask[dr][dc] = 1'b0;
           end
       end
   endgenerate
   ```
   *Finding:* The unbroadcast 2D activation ports are clamped to 0.

4. **`tb_neural_acc_integrated_top.sv` (Lines 742–748):**
   ```systemverilog
   // Verify across all active rows and columns against golden reference
   for (idx = 0; idx < ROWS; idx = idx + 1) begin
       for (loop_i = 0; loop_i < COLS; loop_i = loop_i + 1) begin
           check_val40($sformatf("S20.3: PE[%0d][%0d] matches software model (-304)", idx, loop_i),
                       accum_out[idx][loop_i], golden_ref_sum);
       end
   end
   ```
   *Finding:* The testbench asserts that every single PE produces the identical scalar result `-304`.

5. **`tb_workload_validation.sv` (Lines 204–233 & 708–734):**
   *Finding:* The integrated accelerator only runs duplicate checks (`accum_out[0][0] == accum_out[3][15]`). When Category 7 ("Distinct Sequences Across Multiple PEs") was tested, `tb_workload_validation.sv` instantiated a separate `u_standalone_pe_array` and stimulated it directly, avoiding the top-level integration entirely.

---

## 4. Verification of PE Features & Operating Modes

| Feature / Mode | RTL Implementation Status | Source Location | Behavioral Verification Findings |
|---|---|---|---|
| **16-PE Mode (2'b00)** | Verified in RTL & Subsystem | `pe_array_40b.sv:69-73` | Columns 0..3 active (16 PEs). Columns 4..15 inactive. Inactive columns have `pe_mac_enable = 0`, inputs clamped to 0, outputs clamped to `40'sd0`. |
| **32-PE Mode (2'b01)** | Verified in RTL & Subsystem | `pe_array_40b.sv:74-78` | Columns 0..7 active (32 PEs). Columns 8..15 inactive. Inactive columns isolated. |
| **64-PE Mode (2'b10)** | Verified in RTL & Subsystem | `pe_array_40b.sv:79-83` | All columns 0..15 active (64 PEs). |
| **Inactive PE Behavior** | Verified in RTL | `pe_array_40b.sv:106-120, 140-144` | Complete multiplier input zeroing, enable gating, and output clamping to 0. Prevents switching power on inactive columns. |
| **Exact-Zero Skipping** | Verified in RTL | `mac_unit_40b.sv:92-96, 126-135` | When `act_data == 0` or `act_mask == 0`, `is_zero` asserts, bypassing accumulator addition and raising `cycle_skipped`. |
| **Signed Arithmetic** | Verified in RTL | `mac_unit_40b.sv:87, 102` | Signed multiplication: `$signed(act_data) * $signed(weight_data)`. Correct for positive, negative, and mixed signs. |
| **40-bit Saturation** | Verified in RTL | `mac_unit_40b.sv:107-124` | Clamping at `40'sh7F_FFFF_FFFF` (max positive) and `-40'sh80_0000_0000` (max negative). Sticky saturation latches until `sat_clear`. |
| **Independent Accumulators** | Physically Independent, Federally Bound | `pe_array_40b.sv:122-138` | Each PE has its own physical 40-bit accumulator flip-flop register. They are physically capable of holding distinct sums, but currently receive identical inputs. |

---

## 5. Memory Subsystem & Throughput Evaluation

### 5.1. SRAM Bank Interleaving and Capacity
- **Subsystem Architecture (`multibank_sram_subsystem.sv`):**
  - 8 independent physical SRAM banks (`hybrid_sram_bank.sv`).
  - Total memory: $8 \text{ banks} \times 5,184 \text{ bytes} = 41,472 \text{ bytes}$ ($10,368 \times 32\text{-bit}$ words).
  - Address mapping: Low-order interleaving.
    - Bank Select: `addr[2:0]` (bits 2..0).
    - Bank Row Address: `addr[13:3]` (bits 13..3).
- **Dual-Port Capability per Bank:**
  - Port A: Write (Ingestion/Writeback).
  - Port B: Read (Datapath Feeder).
  - Concurrent read and write to different ports on the same bank proceed with zero stalls. Bank conflict occurs ONLY when two or more read ports target the same bank in the same cycle.

### 5.2. Port Utilization Deficit
- **Hardware Capability:**
  - 8 Read Ports $\times$ 32 bits = **256 bits/cycle read throughput** (equivalent to 16 halfwords of 16-bit data per clock cycle).
- **Current Top-Level Utilization:**
  - Only Port B0 is connected.
  - Read throughput: **32 bits/cycle (1 word = 1 activation + 1 weight)**.
  - Port utilization: $1 / 8 = 12.5\%$.
  - Idle SRAM bandwidth: **$87.5\%$ of read bandwidth is permanently grounded.**

### 5.3. Bandwidth Requirements for Distinct 4x16 Matrix Multiplication
In standard 2D matrix multiplication ($C[M, N] += A[M, K] \times W[K, N]$) with $M=4$ rows and $N=16$ columns:
- At each step along reduction dimension $K$:
  - **4 distinct activations** are needed ($A[0..3, k]$), broadcast horizontally across rows.
  - **16 distinct weights** are needed ($W[k, 0..15]$), broadcast vertically across columns.
  - Each PE $(r, c)$ computes:
    $$C[r, c] \mathrel{+}= A[r, k] \times W[k, c]$$
- **Total operand delivery per cycle:**
  - Activations: $4 \times 16\text{-bit} = 64\text{ bits/cycle}$ ($2 \times 32\text{-bit words}$).
  - Weights: $16 \times 16\text{-bit} = 256\text{ bits/cycle}$ ($8 \times 32\text{-bit words}$).
  - Total bandwidth needed per compute cycle = **320 bits/cycle (10 words/cycle)**.

Since the 8 SRAM read ports provide at most $8 \times 32\text{-bit} = 256\text{ bits/cycle}$, a direct single-cycle unbuffered fetch of all 20 operands from SRAM in every cycle is mathematically impossible with an 8-port 32-bit SRAM.

Therefore, an architectural solution must use either:
1. **Weight-Stationary Register File / Line Buffer:**
   Weights ($4 \times 16 = 64$ weights or $1 \times 16$ column weights) are pre-fetched from SRAM across multiple cycles into local registers, after which activations stream at 64 bits/cycle (2 SRAM ports).
2. **Multi-Cycle Feeder Accumulation (Time-Multiplexed / Ping-Pong Staging):**
   Feeder gathers operands over 2 clock cycles before asserting `compute_enable_in`, or uses 8 SRAM read ports across consecutive cycles.

---

## 6. Proposed Minimum Architecture for Distinct Parallel Computation

### 6.1. Selected Dataflow: Row-Activation / Column-Weight Broadcast (GEMM 4x16)

```
                            Weight Inputs (from SRAM / Weight Buffer)
                            W[k,0]   W[k,1]   W[k,2]   ...   W[k,15]
                              │        │        │               │
                              ▼        ▼        ▼               ▼
Activation Inputs           ┌────┐   ┌────┐   ┌────┐         ┌────┐
A[0, k] (Row 0) ───────────►│PE00│───│PE01│───│PE02│─── ... ───│PE0F│ ──► C[0, 0..15]
                            └────┘   └────┘   └────┘         └────┘
                              │        │        │               │
A[1, k] (Row 1) ───────────►│PE10│───│PE11│───│PE12│─── ... ───│PE1F│ ──► C[1, 0..15]
                            └────┘   └────┘   └────┘         └────┘
                              │        │        │               │
A[2, k] (Row 2) ───────────►│PE20│───│PE21│───│PE22│─── ... ───│PE2F│ ──► C[2, 0..15]
                            └────┘   └────┘   └────┘         └────┘
                              │        │        │               │
A[3, k] (Row 3) ───────────►│PE30│───│PE31│───│PE32│─── ... ───│PE3F│ ──► C[3, 0..15]
                            └────┘   └────┘   └────┘         └────┘
```

In this architecture:
- `pe_array_40b` already has `act_data_row[0:ROWS-1]`!
  - Row 0 receives $A[0, k]$
  - Row 1 receives $A[1, k]$
  - Row 2 receives $A[2, k]$
  - Row 3 receives $A[3, k]$
- For weights, each column $c \in [0..15]$ receives $W[k, c]$:
  - Column 0 PEs (PE[0..3][0]) receive $W[k, 0]$
  - Column 1 PEs (PE[0..3][1]) receive $W[k, 1]$
  - Column 15 PEs (PE[0..3][15]) receive $W[k, 15]$
- **Result:** Every PE $[r][c]$ computes a mathematically distinct output:
  $$C[r, c] = \sum_{k=0}^{K-1} A[r, k] \cdot W[k, c]$$

### 6.2. Concrete Arithmetic Example

Let $K = 2$.
- **Activations (4 rows):**
  - Row 0: $A[0, :] = [1, 2]$
  - Row 1: $A[1, :] = [3, 4]$
  - Row 2: $A[2, :] = [5, 6]$
  - Row 3: $A[3, :] = [7, 8]$
- **Weights (16 columns):**
  - Col $c \in [0..15]$: $W[:, c] = [c+1, 10(c+1)]$
    - Col 0: $[1, 10]$
    - Col 1: $[2, 20]$
    - Col 15: $[16, 160]$
- **Resulting Accumulations:**
  - $C[0, 0]  = (1 \times 1) + (2 \times 10) = 1 + 20 = \mathbf{21}$
  - $C[0, 1]  = (1 \times 2) + (2 \times 20) = 2 + 40 = \mathbf{42}$
  - $C[1, 0]  = (3 \times 1) + (4 \times 10) = 3 + 40 = \mathbf{43}$
  - $C[1, 1]  = (3 \times 2) + (4 \times 20) = 6 + 80 = \mathbf{86}$
  - $C[3, 15] = (7 \times 16) + (8 \times 160) = 112 + 1280 = \mathbf{1392}$

**Outcome:** Every one of the 64 output accumulators $C[r, c]$ produces a unique, mathematically correct inner-product value.

---

## 7. Required RTL & Interface Changes

To implement genuine parallel computation without modifying the protected baseline RTL (`hybrid_sram_bank.sv`, `mac_unit_40b.sv`, `accelerator_core_top.sv`, `k_progress_tracker.sv`, `slot_control_unit.sv`), the following minimum changes are required in the Phase 2 modules:

### 1. `datapath_compute_feeder.sv`
- **Current Interface:**
  - 1 SRAM read port (`sram_rd_dout[31:0]`).
  - Scalar outputs: `act_sample`, `weight_sample`.
- **Required Interface:**
  - Connect to **8 SRAM read ports**:
    ```systemverilog
    output logic [NUM_BANKS-1:0]        sram_rd_req_bus,
    output logic [SRAM_ADDR_W-1:0]      sram_rd_addr_bus [0:NUM_BANKS-1],
    input  logic [NUM_BANKS-1:0]        sram_rd_ready_bus,
    input  logic [NUM_BANKS-1:0]        sram_rd_rvalid_bus,
    input  logic [DATA_WIDTH-1:0]       sram_rd_dout_bus [0:NUM_BANKS-1],
    ```
  - Vector operand outputs:
    ```systemverilog
    output logic signed [ACT_WIDTH-1:0]    act_data_row   [0:ROWS-1],
    output logic                           act_mask_row   [0:ROWS-1],
    output logic signed [WEIGHT_WIDTH-1:0] weight_data_col[0:COLS-1],
    ```
  - **Internal Staging:**
    - Include a small $16 \times 16\text{-bit}$ Weight Staging Buffer.
    - Fetch weights across 2 cycles ($8 \times 16\text{-bit} = 4 \text{ words/cycle}$) or utilize banked burst alignment.
    - Fetch 4 row activations ($2 \text{ words/cycle}$).

### 2. `neural_acc_integrated_top.sv`
- **SRAM Read Port Bus:**
  - Remove tie-offs on Ports B1..B7 (`neural_acc_integrated_top.sv:230-235`).
  - Wire all 8 read ports from `multibank_sram_subsystem` to `datapath_compute_feeder`.
- **PE Array Operand Connections:**
  - Remove scalar broadcast loop (`neural_acc_integrated_top.sv:258-265`).
  - Connect feeder's `act_data_row[0..3]` directly to `u_pe_array.act_data_row[0..3]`.
  - Connect feeder's `weight_data_col[c]` to column inputs:
    ```systemverilog
    for (dr_pe = 0; dr_pe < ROWS; dr_pe = dr_pe + 1) begin : gen_pe_w_col
        for (dc_pe = 0; dc_pe < COLS; dc_pe = dc_pe + 1) begin : gen_pe_w_row
            assign weight_data[dr_pe][dc_pe] = feeder_weight_col[dc_pe];
        end
    end
    ```

### 3. `dma_to_sram_write_adapter.sv` & Memory Ingestion Layout
- Maintain contiguous block or interleaved layout in Buffer A / Buffer B so that weight blocks and activation blocks reside in predictable banks, avoiding bank conflicts during multi-port read cycles.

---

## 8. Verification Plan for Genuine Parallel Computation

A dedicated verification test suite must be established to independently prove parallel computation:

1. **Distinct 64-PE Parallel Correctness Test:**
   - Supply 4 distinct row activations and 16 distinct column weights over $K=4$ steps.
   - Sample all 64 outputs $C[r, c]$.
   - Assert $C[r, c] == \text{Expected}[r, c]$ across all 64 locations, ensuring zero duplicate values between different rows and columns.
2. **Selective Zero-Skipping Test:**
   - Row 0 receives zero ($A[0, k] = 0$), Row 1 receives non-zero ($A[1, k] = 15$).
   - Verify that Row 0 asserts `cycle_skipped` while Row 1 accumulates normally.
3. **Selective Saturation Isolation Test:**
   - Drive inputs such that PE[0][0] hits saturation (`+SAT_MAX_POS`), while PE[0][1..15] and all other rows remain at nominal small values.
   - Verify that sticky saturation is set on Column 0 only (`col_sticky_saturation[0] == 1`, `col_sticky_saturation[1..15] == 0`) and other accumulators are unaffected.
4. **Adaptive Allocation (16 / 32 / 64 PEs) with Distinct Operands:**
   - **Mode 0 (16 PEs):** Columns 0..3 compute distinct values; Columns 4..15 strictly output 0.
   - **Mode 1 (32 PEs):** Columns 0..7 compute distinct values; Columns 8..15 strictly output 0.
   - **Mode 2 (64 PEs):** All 16 columns compute distinct values.
5. **Multi-Bank SRAM Conflict Monitoring:**
   - Monitor `multibank_sram_subsystem.total_conflicts_count` during multi-port feeder execution.
   - Verify that properly aligned memory layouts achieve zero conflict stalls (`total_conflicts_count == 0`).
6. **Concurrent Ping-Pong Buffering under Parallel Compute:**
   - Execute parallel 64-PE compute on Buffer A while DMA ingests the next layer's weights/activations into Buffer B.
   - Verify zero corruption and seamless buffer toggle.

---

## 9. Implementation Dependencies & Risk Assessment

| Risk Item | Impact | Severity | Mitigation Strategy |
|---|---|---|---|
| **SRAM Bank Conflicts on Multi-Port Read** | Feeder stalls if multiple read ports request the same physical bank in the same cycle. | High | Group activations and weights into distinct bank groups or structure feeder read requests with staggered bank strides. |
| **Feeder State Machine Complexity** | Feeder must manage multi-cycle staging for weights and activations before firing compute enable. | Medium | Use a 2-stage pipeline in the feeder: Stage 1 = Multi-Bank SRAM Fetch, Stage 2 = Register Staging & Datapath Drive. |
| **AXI Ingestion Data Layout Overhead** | System memory must organize tensors to match the multi-bank layout. | Medium | Document tensor layout specification (e.g. Channel-first or blocked $4 \times 16$ packing) for DMA burst transfers. |
| **Protected Baseline Integrity** | Risk of accidental modification to baseline RTL. | Critical | Keep baseline files strictly untouched; all changes are confined to `datapath_compute_feeder.sv` and `neural_acc_integrated_top.sv`. |

---

## 10. Recommended Implementation Sequence

To resolve this gap cleanly, the following sequence should be executed:
1. **Step 1: Feeder Multi-Port Read Architecture Design**
   - Update `datapath_compute_feeder.sv` to instantiate a multi-bank read client connecting to all 8 ports of `multibank_sram_subsystem`.
   - Incorporate a 16-element column weight staging register and 4-element row activation register.
2. **Step 2: Top-Level Integration Wrapper Wiring**
   - Update `neural_acc_integrated_top.sv` to wire all 8 read ports and distribute vector operands (`act_data_row[0..3]`, `weight_data_col[0..15]`).
3. **Step 3: Standalone Feeder-to-PE Array Testbench**
   - Validate that feeder delivers distinct values from multi-bank SRAM to PE array without DMA.
4. **Step 4: End-to-End System Regression**
   - Update `tb_neural_acc_integrated_top.sv` and `tb_workload_validation.sv` with distinct matrix workloads.
   - Run complete 14-suite regression via `python3 run_regression.py`.

