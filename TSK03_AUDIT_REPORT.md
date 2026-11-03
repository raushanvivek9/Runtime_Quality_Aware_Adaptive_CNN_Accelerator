# TSK-03 Deep Technical Audit Report: Multi-Bank SRAM Subsystem

**Project**: `Neural_Acc` (`Runtime_Quality_Aware_Adaptive_CNN_Accelerator`)  
**Task Under Audit**: TSK-03 — Multi-bank SRAM Subsystem  
**Date**: 2026-11-01  
**Audit Decision**: **`PASS_WITH_LIMITATIONS`**  
**Working Directory**: `E:\MTech\LanChain\MTP`  
**RTL Directory**: `phase2_step1_microarchitecture_and_rtl`  

---

## 1. Executive Summary & Audit Decision

A rigorous, code-level architectural and verification audit of the completed Multi-Bank SRAM Subsystem was conducted across the source files:
- RTL: [`multibank_sram_subsystem.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv)
- Macro Model: [`hybrid_sram_bank.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv)
- Testbench: [`tb_multibank_sram_subsystem.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_multibank_sram_subsystem.sv)

### Audit Decision: **`PASS_WITH_LIMITATIONS`**

#### Summary of Invariants Verified:
1. **Physical & Logical Capacity**: Physical allocation of two $1024 \times 32$-bit macros per bank ($8,192\text{ Bytes}$ physical capacity) with active bounds clamped strictly at $1,296\text{ words}$ ($5,184\text{ Bytes}$) per bank. In an 8-bank subsystem, total capacity is $41,472\text{ Bytes}$ ($10,368\text{ words}$).
2. **Address Mapping & Interleaving**: Low-order bank interleaving ($\text{Bank} = \text{addr}[2:0]$, $\text{Offset} = \text{addr}[13:3]$) guarantees that global addresses $0 .. 10,367$ map contiguously to valid words with zero internal addressing holes.
3. **Read/Write Semantics**: Synchronous reads with deterministic 1-cycle latency. Dual-ported concurrent access (Port A write + Port B read to the same bank in the same cycle) is guaranteed and verified to exhibit **Read-Old-Data (ROD)** semantics without stalls.
4. **Contention & Backpressure**: Lowest-port-index priority arbitration operates deterministically. Stalled requesters receive `ready=0` and `conflict_stall=1`.
5. **Defect Found & Fixed (TSK03-DEF-01)**: A procedural non-blocking assignment loop defect in the diagnostic counters (`total_conflicts_count`, `total_read_accesses`, `total_write_accesses`) was identified, reproduced, and corrected with a combinational summation tree.
6. **Regression Verification**: All 9 testbenches in the repository (309 total tests) pass 100% under Icarus Verilog 12.0.

#### Limitations & Unresolved Integration Constraints:
* **Unbuffered Interconnect**: The subsystem contains no internal request holding FIFOs. Upstream masters must maintain `req` and `addr` stable when `ready == 0`; dropping a request before `ready == 1` causes request loss.
* **PE Array Bandwidth Mismatch**: The 8-bank subsystem delivers 8 words/cycle (256 bits/cycle). The 64-PE array ([`pe_array_40b.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/pe_array_40b.sv)) organizes PEs as 16 columns $\times$ 4 rows. Feeding 16 columns requires a 2-cycle feed sequence or parameterization to 16 banks.
* **Top-Level Integration Status**: The SRAM subsystem is verified as a standalone unit and is **NOT yet integrated** into [`accelerator_core_top.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv) (scoped for TSK-04/TSK-05).
* **Power-Gating Clarification**: `bank_enable` performs architectural clock/reset request gating. It must **not** be claimed as physical silicon power gating.

---

## 2. Code-Level Inspection: Memory Capacity and Address Mapping

### 2.1 Macro Realization in `hybrid_sram_bank.sv`
Lines 10–14 and lines 36–54 of [`hybrid_sram_bank.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv):
```systemverilog
module hybrid_sram_bank #(
    parameter int TOTAL_BYTES = 5184,
    parameter int DATA_WIDTH  = 32,
    parameter int ADDR_WIDTH  = 11     // 2048 words x 4 bytes = 8192 B physical capacity range
)( ... );

    localparam int NUM_LOGICAL_WORDS = TOTAL_BYTES / 4; // 1296
    localparam int BANK_WORDS        = 1024;

    logic [DATA_WIDTH-1:0] mem_bank0 [0:BANK_WORDS-1];
    logic [DATA_WIDTH-1:0] mem_bank1 [0:BANK_WORDS-1];

    wire a_oob = (addr_a >= NUM_LOGICAL_WORDS);
    wire b_oob = (addr_b >= NUM_LOGICAL_WORDS);
```

* **Physical Memory**: Two $1024 \times 32$-bit memory macros (`mem_bank0` and `mem_bank1`) provide $2048 \times 32\text{ bits} = 8,192\text{ Bytes}$ of physical RAM.
* **Logical Clamping**: The macro limits active addresses to $0 .. 1295$ ($1296 \times 4 = 5,184\text{ Bytes}$).
  * Addresses $0 .. 1023$ map to `mem_bank0[addr[9:0]]` (`!addr[10]`).
  * Addresses $1024 .. 1295$ map to `mem_bank1[addr[9:0]]` (`addr[10]` with local offset $0 .. 271$).
  * Addresses $1296 .. 2047$ assert `a_oob` and `b_oob`. Writes are inhibited (`if (we_a && !a_oob)`), and reads return `0` with `sram_rvalid_b = 0`. Both assert `sram_oob_err`.

### 2.2 Address Decomposition in `multibank_sram_subsystem.sv`
Lines 51–77 of [`multibank_sram_subsystem.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv):
```systemverilog
    localparam int BANK_SEL_BITS = $clog2(NUM_BANKS);
    localparam int GLOBAL_ADDR_W = BANK_ADDR_W + BANK_SEL_BITS;

    wire [BANK_SEL_BITS-1:0] wr_bank_sel  [0:NUM_WRITE_PORTS-1];
    wire [BANK_ADDR_W-1:0]   wr_bank_addr [0:NUM_WRITE_PORTS-1];

    genvar w_gen;
    generate
        for (w_gen = 0; w_gen < NUM_WRITE_PORTS; w_gen = w_gen + 1) begin : gen_wr_decode
            assign wr_bank_sel[w_gen]  = wr_addr[w_gen][BANK_SEL_BITS-1:0];
            assign wr_bank_addr[w_gen] = wr_addr[w_gen][GLOBAL_ADDR_W-1:BANK_SEL_BITS];
        end
    endgenerate
```

* For `NUM_BANKS = 8`:
  * $\text{BANK\_SEL\_BITS} = 3$, $\text{BANK\_ADDR\_W} = 11$, $\text{GLOBAL\_ADDR\_W} = 14$.
  * Low-order 3 bits: `bank_sel = addr[2:0]`.
  * High-order 11 bits: `bank_offset = addr[13:3]`.
* **Interleaving Analysis**:
  Because bank selection uses low-order bits, consecutive global addresses $0, 1, 2, 3, 4, 5, 6, 7$ map to Banks $0, 1, 2, 3, 4, 5, 6, 7$ at local offset $0$.
  Global addresses $8, 9, 10, 11, 12, 13, 14, 15$ map to Banks $0, 1, 2, 3, 4, 5, 6, 7$ at local offset $1$.
  For non-power-of-two depth ($1,296\text{ words/bank}$):
  $$\text{Max Valid Global Address} = (1295 \times 8) + 7 = 10,367$$
  All addresses in $[0 .. 10367]$ satisfy $\lfloor \text{addr}/8 \rfloor \le 1295$. Hence, **the entire range $0 .. 10,367$ is contiguous and valid with zero holes**.

### 2.3 Address Audit Table

| Global Word Address | Binary [13:0] | Bank Index [2:0] | Local Offset [13:3] | Expected Validity | Actual RTL Behavior | Status |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **0** | `00_0000_0000_0000` | 0 | 0 | VALID (First word Bank 0) | Read/Write OK, `dout_b` valid, no error | **PASS** |
| **1** | `00_0000_0000_0001` | 1 | 0 | VALID (First word Bank 1) | Read/Write OK, `dout_b` valid, no error | **PASS** |
| **7** | `00_0000_0000_0111` | 7 | 0 | VALID (First word Bank 7) | Read/Write OK, `dout_b` valid, no error | **PASS** |
| **8** | `00_0000_0000_1000` | 0 | 1 | VALID (Second word Bank 0) | Read/Write OK, `dout_b` valid, no error | **PASS** |
| **8184** | `01_1111_1111_1000` | 0 | 1023 | VALID (End Macro 0 Bank 0) | Read/Write OK, macro 0 boundary verified | **PASS** |
| **8191** | `01_1111_1111_1111` | 7 | 1023 | VALID (End Macro 0 Bank 7) | Read/Write OK, macro 0 boundary verified | **PASS** |
| **8192** | `10_0000_0000_0000` | 0 | 1024 | VALID (Start Macro 1 Bank 0) | Read/Write OK, `addr[10]=1` macro 1 decode | **PASS** |
| **8199** | `10_0000_0000_0111` | 7 | 1024 | VALID (Start Macro 1 Bank 7) | Read/Write OK, `addr[10]=1` macro 1 decode | **PASS** |
| **10360** | `10_1000_0111_0000` | 0 | 1295 | VALID (Ceiling Bank 0) | Read/Write OK, last valid word Bank 0 | **PASS** |
| **10367** | `10_1000_0111_0111` | 7 | 1295 | VALID (Subsystem Ceiling) | Read/Write OK, last valid word Bank 7 | **PASS** |
| **10368** | `10_1000_1000_0000` | 0 | 1296 | **INVALID (OOB offset)** | Write suppressed; `bank_oob_err[0]=1`; `rd_rvalid=0`; data=0 | **PASS** |
| **10375** | `10_1000_1000_0111` | 7 | 1296 | **INVALID (OOB offset)** | Write suppressed; `bank_oob_err[7]=1`; `rd_rvalid=0`; data=0 | **PASS** |
| **12288** | `11_0000_0000_0000` | 0 | 1536 | **INVALID (OOB offset)** | Write suppressed; `bank_oob_err[0]=1`; `rd_rvalid=0`; data=0 | **PASS** |
| **16383** | `11_1111_1111_1111` | 7 | 2047 | **INVALID (Max 14-bit)** | Write suppressed; `bank_oob_err[7]=1`; `rd_rvalid=0`; data=0 | **PASS** |
| **$\ge 16384$** | `100_0000_0000_0000` | — | — | **OUT-OF-RANGE (>14b)** | Truncated by 14-bit input width | **PASS** |

---

## 3. Code-Level Inspection: Read/Write Semantics and Timing

### 3.1 Synchronous Reads & 1-Cycle Latency
Lines 74–91 of [`hybrid_sram_bank.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv):
```systemverilog
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_b        <= '0;
            sram_rvalid_b <= 1'b0;
        end else if (re_b) begin
            sram_rvalid_b <= !b_oob;
            if (b_oob) begin
                dout_b <= '0;
            end else if (!addr_b[10]) begin
                dout_b <= mem_bank0[addr_b[9:0]];
            end else begin
                dout_b <= mem_bank1[addr_b[9:0]];
            end
        end else begin
            sram_rvalid_b <= 1'b0;
        end
    end
```
* **Synchronous Nature**: `dout_b` and `sram_rvalid_b` are driven exclusively inside an edge-triggered `always_ff` block.
* **Read Latency**: A read request asserted at clock edge $T$ samples `addr_b` and `re_b`. The output is registered and appears at the rising edge of clock cycle $T+1$.
* **Read Response Routing**: Lines 254–287 of `multibank_sram_subsystem.sv` latch the granted port ID into `bank_resp_owner_q` at cycle $T$, and the combinational crossbar multiplexes `bank_dout_b` to `rd_dout[p]` at cycle $T+1$. Latency is **strictly 1 clock cycle**.

### 3.2 Dual-Port Concurrency & Read-Old-Data (ROD)
Lines 56–72 (Port A Write) and Lines 74–91 (Port B Read) operate concurrently:
* Port A and Port B feature independent address, data, and control lines.
* In SystemVerilog stratified event execution (IEEE 1800 Section 4.4):
  * When Port A writes to address $X$ and Port B reads from address $X$ at the **same clock edge**:
  * In the Active region, the read expression evaluates `mem_bank[addr_b]`, capturing the **current (pre-write) value**.
  * In the Non-Blocking Assignment (NBA) region, the write update `mem_bank[addr_a] <= din_a` commits.
  * Therefore, Port B returns the **prior (old) data**, and Port A commits the new data.
  * Both operations complete in cycle $T$ without stalls (`wr_ready=1`, `wr_ack=1`, `rd_ready=1`, `rd_conflict_stall=0`).
  * Verified in Test 5B of `tb_multibank_sram_subsystem.sv`.

---

## 4. Code-Level Inspection: Arbitration, Backpressure, and Contention

### 4.1 Arbitration Implementation
Lines 193–220 of [`multibank_sram_subsystem.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv):
```systemverilog
    always_comb begin
        for (int b_idx = 0; b_idx < NUM_BANKS; b_idx = b_idx + 1) begin
            granted_rd_port[b_idx]      = '0;
            bank_rd_active[b_idx]       = 1'b0;
            rd_conflict_detected[b_idx] = 1'b0;
            bank_re_b[b_idx]            = 1'b0;
            bank_addr_b[b_idx]          = '0;

            for (int p_idx = 0; p_idx < NUM_READ_PORTS; p_idx = p_idx + 1) begin
                if (rd_req[p_idx] && bank_enable[b_idx] &&
                    (rd_bank_sel[p_idx] == b_idx)) begin
                    if (!bank_rd_active[b_idx]) begin
                        // Grant highest priority (lowest port index)
                        granted_rd_port[b_idx] = p_idx;
                        bank_rd_active[b_idx]  = 1'b1;
                    end else begin
                        // Subsequent read requesters suffer conflict stall
                        rd_conflict_detected[b_idx] = 1'b1;
                    end
                end
            end
```

Lines 223–238:
```systemverilog
        for (int p_idx = 0; p_idx < NUM_READ_PORTS; p_idx = p_idx + 1) begin
            int target_bank;
            target_bank = rd_bank_sel[p_idx];
            if (rd_req[p_idx]) begin
                if (bank_enable[target_bank] && bank_rd_active[target_bank] && (granted_rd_port[target_bank] == p_idx)) begin
                    rd_ready[p_idx]          = 1'b1;
                    rd_conflict_stall[p_idx] = 1'b0;
                end else begin
                    rd_ready[p_idx]          = 1'b0;
                    rd_conflict_stall[p_idx] = 1'b1;
                end
            end else begin
                rd_ready[p_idx]          = 1'b1;
                rd_conflict_stall[p_idx] = 1'b0;
            end
        end
    end
```

### 4.2 Critical Backpressure Contract & Request Retention
> [!WARNING]
> **Interconnect Buffer Absence**:
> `multibank_sram_subsystem.sv` contains **no request holding FIFOs or shadow registers**.
> - When `rd_ready[p] == 0` (or `wr_ready[p] == 0`), the un-granted master is stalled via backpressure.
> - **The upstream master must hold `req` and `addr` stable** until `ready == 1`.
> - If an upstream master deasserts `req` on the next cycle, the request is **dropped**.
> - Test 13 in `tb_multibank_sram_subsystem.sv` models this contract by retaining requests until granted, verifying that Ports 1, 3, 5, 7 contesting Bank 0 serialize over 4 consecutive cycles with zero dropped grants.

### 4.3 Cycle-by-Cycle Contention Traces

#### Read Contention Trace (Ports 0, 1, 2 targeting Bank 3)
```
Cycle T (Request Phase):
  Inputs:  rd_req[0]=1, rd_req[1]=1, rd_req[2]=1 (all targeting Bank 3, offset 42)
  Arbiter: granted_rd_port[3] = 0 (lowest index wins)
           rd_ready[0]=1, rd_conflict_stall[0]=0
           rd_ready[1]=0, rd_conflict_stall[1]=1 (stalled)
           rd_ready[2]=0, rd_conflict_stall[2]=1 (stalled)
           bank_conflict_flags[3]=1
  Bank 3:  bank_re_b[3]=1, bank_addr_b[3]=42

Clock Edge T -> T+1:
  Registers: bank_resp_owner_q[3] <= 0; bank_resp_valid_q[3] <= 1
  Bank 3 Macro: Samples offset 42

Cycle T+1 (Service Port 0, Arbiter Port 1):
  Outputs: Port 0 receives rd_rvalid[0]=1, rd_dout[0]=Data(Bank 3, 42). Port 0 DONE.
  Inputs:  Port 0 drops rd_req[0]=0. Upstream masters hold rd_req[1]=1, rd_req[2]=1.
  Arbiter: granted_rd_port[3] = 1 (Port 1 is now lowest index)
           rd_ready[1]=1, rd_conflict_stall[1]=0
           rd_ready[2]=0, rd_conflict_stall[2]=1 (stalled)
  Bank 3:  bank_re_b[3]=1, bank_addr_b[3]=42

Clock Edge T+1 -> T+2:
  Registers: bank_resp_owner_q[3] <= 1; bank_resp_valid_q[3] <= 1

Cycle T+2 (Service Port 1, Arbiter Port 2):
  Outputs: Port 1 receives rd_rvalid[1]=1, rd_dout[1]=Data. Port 1 DONE.
  Inputs:  Port 1 drops rd_req[1]=0. Master holds rd_req[2]=1.
  Arbiter: granted_rd_port[3] = 2; rd_ready[2]=1, rd_conflict_stall[2]=0.

Cycle T+3:
  Outputs: Port 2 receives rd_rvalid[2]=1, rd_dout[2]=Data. Port 2 DONE.
```

---

## 5. Code-Level Inspection: Bank Enable Behavior

Lines 102–104 of [`multibank_sram_subsystem.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv):
```systemverilog
        for (b = 0; b < NUM_BANKS; b = b + 1) begin : gen_bank
            hybrid_sram_bank #( ... ) u_sram_bank (
                .clk(clk),
                .rst_n(rst_n && bank_enable[b]),
                ...
            );
        end
```

### 5.1 Verification Across Operational States
1. **Disabled during Idle**: Bank is held in reset (`rst_n=0`). Outputs `dout_b=0`, `sram_rvalid_b=0`, `sram_oob_err=0`. SRAM internal array contents are preserved.
2. **Disabled during Pending Read**: In line 202, `if (rd_req[p_idx] && bank_enable[b_idx] && ...)`. When `bank_enable[b] == 0`, `bank_rd_active[b]` remains `0`. Line 231 drives `rd_ready = 0` and `rd_conflict_stall = 1`. Read pulse is gated.
3. **Disabled during Pending Write**: In line 142, `if (wr_req[w_idx] && bank_enable[b_idx] && ...)`. Gated low. Line 174 drives `wr_ready = 0`, `wr_ack = 0`, `wr_conflict_stall = 1`. Memory write is inhibited. Verified in Test 17.3D: data at Bank 3 offset 700 remained unchanged (`0xCAFE1730`).
4. **Disabled during Outstanding Read Response**: Read granted at cycle $T$. If `bank_enable` is deasserted before cycle $T+1$, the bank macro's `rst_n` goes low, immediately clearing `sram_rvalid_b` to `0` and `dout_b` to `0`. The crossbar delivers `rd_rvalid = 0`. Response is aborted safely rather than emitting garbage data (verified in Test 17.4B).
5. **Disabled during Conflict**: Multiple requesters targeting a disabled bank are all denied grant (`ready=0`, `conflict_stall=1`).

### 5.2 Architectural vs. Physical Reality
* In this RTL model, `bank_enable[b]` controls request qualification and reset gating.
* **It is not physical silicon power gating.** Physical power gating requires sleep transistors (header/footer switches), isolation cells, level shifters, and power management controllers.
* No power savings or energy reductions are claimed without physical synthesis, UPF definitions, and power measurement tools.

---

## 6. Confirmed Defects and Corrections

### Defect TSK03-DEF-01: Multi-Bank Event Counter Under-Reporting
* **Severity**: Moderate (Diagnostic/Performance Profiling Metric Under-reporting).
* **Location**: [`multibank_sram_subsystem.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv), lines 300–325.
* **Pre-Audit Code**:
  ```systemverilog
  always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
          total_conflicts_count <= '0;
          total_read_accesses   <= '0;
          total_write_accesses  <= '0;
      end else begin
          for (int b_idx = 0; b_idx < NUM_BANKS; b_idx = b_idx + 1) begin
              if (bank_conflict_flags[b_idx]) total_conflicts_count <= total_conflicts_count + 1'b1;
              if (bank_rd_active[b_idx])      total_read_accesses   <= total_read_accesses + 1'b1;
              if (bank_wr_active[b_idx])      total_write_accesses  <= total_write_accesses + 1'b1;
          end
      end
  end
  ```
* **Mechanism of Failure**:
  In SystemVerilog IEEE 1800 Section 10.4.2: Multiple non-blocking assignments scheduled to the same register in the same simulation time step schedule updates using the *pre-clock value*. In the NBA commit region, the last scheduled assignment overwrites prior ones. When 8 banks performed reads simultaneously, all 8 assignments evaluated `total_read_accesses + 1`. The counter incremented by **1** instead of **8**.
* **Reproduction**:
  Executed a dedicated reproduction test in Icarus Verilog (`scratch/test_fail_cnt.sv`) issuing 8 concurrent reads:
  ```text
  ACTUAL total_read_accesses = 1, EXPECTED = 8
  FAIL: Counter only incremented by 1 (DEFECT REPRODUCED)
  ```
* **Correction Applied**:
  Replaced the sequential loop with a synthesizable combinational adder tree:
  ```systemverilog
  int unsigned num_conflicts_cycle;
  int unsigned num_reads_cycle;
  int unsigned num_writes_cycle;

  always_comb begin
      num_conflicts_cycle = 0;
      num_reads_cycle     = 0;
      num_writes_cycle    = 0;
      for (int b_idx = 0; b_idx < NUM_BANKS; b_idx = b_idx + 1) begin
          if (bank_conflict_flags[b_idx]) num_conflicts_cycle = num_conflicts_cycle + 1;
          if (bank_rd_active[b_idx])      num_reads_cycle     = num_reads_cycle + 1;
          if (bank_wr_active[b_idx])      num_writes_cycle    = num_writes_cycle + 1;
      end
  end

  always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
          total_conflicts_count <= '0;
          total_read_accesses   <= '0;
          total_write_accesses  <= '0;
      end else begin
          total_conflicts_count <= total_conflicts_count + num_conflicts_cycle;
          total_read_accesses   <= total_read_accesses   + num_reads_cycle;
          total_write_accesses  <= total_write_accesses  + num_writes_cycle;
      end
  end
  ```
* **Post-Fix Verification**: Verified in simulation; 8 concurrent reads increment by exactly 8; 2 concurrent bank conflicts increment by exactly 2.

---

## 7. Performance Reality: Theoretical vs. Measured Bandwidth

| Parameter | Theoretical Maximum | Measured Value | Measurement Condition |
| :--- | :---: | :---: | :--- |
| **Peak Read Bandwidth** | **256 bits/cycle** (32 B/cyc) | **256 bits/cycle** (32 B/cyc) | Test 11: 50 continuous streaming cycles across 8 ports (400 words read, 0 bubbles). |
| **Peak Write Bandwidth** | **256 bits/cycle** (32 B/cyc) | **256 bits/cycle** (32 B/cyc) | Test 11: 50 continuous parallel write cycles across 8 ports (400 words written). |
| **Concurrent Dual-Port Bandwidth** | **512 bits/cycle** (64 B/cyc) | **512 bits/cycle** (64 B/cyc) | Test 5B: Simultaneous Port A write + Port B read across banks ($6.4\text{ GB/s}$ @ $100\text{ MHz}$). |
| **Read Latency** | **1 clock cycle** | **1 clock cycle** | Test 12: Cycle-accurate measurement; valid data on cycle $T+1$. |
| **Throughput Under 4:1 Contention** | **32 bits/cycle** (4 B/cyc) | **32 bits/cycle** (4 B/cyc) | Test 13: 4 ports contesting Bank 0 serialized over 4 cycles (25% efficiency). |
| **Multi-PE Array Feeding Reality** | **8 words/cycle** | — | Array requires 16 words for 16 columns $\implies$ 2-cycle feed sequence required. |

---

## 8. Test Count Reconciliation & Regression Results

### 8.1 Discrepancy Reconciliation
In the prior session output, two conflicting numbers were reported:
1. "119 cumulative regression tests" in the executive summary.
2. "240 tests" in the summary table.

**Root Cause of Discrepancy**:
- Prior task suites: $28\text{ (PE array)} + 53\text{ (Controller)} = 81\text{ tests}$.
- Baseline suites: $9\text{ (Core)} + 29\text{ (Acceptance)} = 38\text{ tests}$.
- Subtotal of non-TSK03 tests: $81 + 38 = \mathbf{119\text{ tests}}$.
- The prior author added TSK-03 ($121$) to this subtotal ($121 + 119 = 240$), but wrote "119 cumulative" in the text, confusing the subtotal with the grand total.
- Furthermore, 4 additional baseline testbenches in the directory (`tb_hybrid_sram_bank.sv`, `tb_mac_saturation.sv`, `tb_drain_backpressure.sv`, `tb_k_progress_tracker.sv`) were omitted from that count.

### 8.2 Full Repository Regression (9 Testbenches)
With TSK-03 expanded to 137 tests, the complete regression across all 9 testbenches yields **309 tests passing with 0 failures**:

| Testbench File | Target Module | Pass | Fail | Command / Verification Status |
| :--- | :--- | :---: | :---: | :--- |
| [`tb_multibank_sram_subsystem.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_multibank_sram_subsystem.sv) | `multibank_sram_subsystem` | **137** | **0** | `iverilog -g2012 ... tb_multibank_sram_subsystem.sv && vvp` $\to$ **PASS** |
| [`tb_pe_array_40b.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_pe_array_40b.sv) | `pe_array_40b` | **28** | **0** | `iverilog -g2012 ... tb_pe_array_40b.sv && vvp` $\to$ **PASS** |
| [`tb_adaptive_pe_controller.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_adaptive_pe_controller.sv) | `adaptive_pe_controller` | **53** | **0** | `iverilog -g2012 ... tb_adaptive_pe_controller.sv && vvp` $\to$ **PASS** |
| [`tb_hybrid_sram_bank.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_hybrid_sram_bank.sv) | `hybrid_sram_bank` | **13** | **0** | `iverilog -g2012 ... tb_hybrid_sram_bank.sv && vvp` $\to$ **PASS** |
| [`tb_mac_saturation.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_mac_saturation.sv) | `mac_unit_40b` | **11** | **0** | `iverilog -g2012 ... tb_mac_saturation.sv && vvp` $\to$ **PASS** |
| [`tb_drain_backpressure.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_drain_backpressure.sv) | `slot_control_unit` | **15** | **0** | `iverilog -g2012 ... tb_drain_backpressure.sv && vvp` $\to$ **PASS** |
| [`tb_k_progress_tracker.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_k_progress_tracker.sv) | `k_progress_tracker` | **14** | **0** | `iverilog -g2012 ... tb_k_progress_tracker.sv && vvp` $\to$ **PASS** |
| [`tb_accelerator_core.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_accelerator_core.sv) | `accelerator_core_top` | **9** | **0** | `iverilog -g2012 ... tb_accelerator_core.sv && vvp` $\to$ **PASS** |
| [`tb_acceptance_integrated.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_acceptance_integrated.sv) | Top-Level Acceptance Matrix | **29** | **0** | `iverilog -g2012 ... tb_acceptance_integrated.sv && vvp` $\to$ **PASS** |
| **Total Cumulative Regression** | — | **309** | **0** | **100% PASS** |

### 8.3 Git Repository Status
- `git diff` against `origin/main` is **empty** (0 lines modified in baseline tracked files).
- Verified baseline RTL files are preserved without any modification.

---

## 9. Remaining Integration Assumptions for TSK-04

Before designing TSK-04 (Ping-Pong Buffer Controller), the following architectural assumptions must govern the integration:
1. **Upstream Request Holding**: The ping-pong controller and command sequencer must not drop `rd_req` or `wr_req` until the corresponding `ready` signal is asserted.
2. **Double-Buffering Mapping**: The ping-pong controller must allocate banks cleanly (e.g., Banks 0..3 for Buffer A, Banks 4..7 for Buffer B, or ping-ponging across time) to avoid read/write bank conflicts.
3. **PE Array Feeder**: Since the 8-bank subsystem outputs 8 words/cycle and the 64-PE array has 16 columns, the sequencer must pipeline operand loading across 2 cycles or expand the subsystem to 16 banks.
4. **Collision Reality in ASIC**: While SystemVerilog simulation provides Read-Old-Data semantics on simultaneous same-address access, physical dual-port macros may require collision avoidance logic if simultaneous same-address access occurs in hardware.
