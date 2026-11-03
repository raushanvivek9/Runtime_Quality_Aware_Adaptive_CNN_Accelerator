# TSK-11B Interface Notes: SRAM Subsystem Handshake, Address Mapping & Memory Map Analysis

**Project:** Neural_Acc (Phase 2 RTL Implementation)  
**Workspace:** `E:\MTech\LanChain\MTP`  
**RTL Directory:** `phase2_step1_microarchitecture_and_rtl`  
**Milestone:** TSK-11 Phase 2A (Standalone OFMAP Drain Controller)  
**Date:** November 1, 2026  
**Status:** Interface & Address Decoder Verification Complete

---

## 1. Verified SRAM Write Interface & Handshake Timing

The write interface of [`multibank_sram_subsystem.sv`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv) was inspected directly in RTL.

### 1.1 Signals and Port Widths
* **Port Count:** 8 write ports (`NUM_WRITE_PORTS = 8`).
* **Request:** `wr_req[7:0]` (1 bit per port).
* **Word Address:** `wr_addr[0:7]` (14 bits per port, `GLOBAL_ADDR_W = BANK_ADDR_W + $clog2(NUM_BANKS) = 11 + 3 = 14`).
* **Write Data:** `wr_din[0:7]` (32 bits per port, `DATA_WIDTH = 32`).
* **Byte Enable:** `wr_byte_we[0:7]` (4 bits per port).
* **Ready:** `wr_ready[7:0]` (1 bit per port).
* **Acknowledgment:** `wr_ack[7:0]` (1 bit per port).
* **Conflict Stall:** `wr_conflict_stall[7:0]` (1 bit per port).

---

### 1.2 Address Units: Word Address vs. Byte Address
* **Word Address Unit:** The 14-bit `wr_addr` is strictly a **32-bit word address**.
  * Incrementing `wr_addr` by 1 points to the next 32-bit word (4 bytes).
  * In [`dma_to_sram_write_adapter.sv#L61`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/dma_to_sram_write_adapter.sv#L61):
    ```systemverilog
    wire [SRAM_ADDR_W-1:0] incoming_word_addr = s_axi_awaddr[SRAM_ADDR_W+1:2];
    ```
    The AXI master write byte address `s_axi_awaddr[15:2]` is directly shifted right by 2 to form the 14-bit word address.
  * In [`hybrid_sram_bank.sv#L56-L72`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv#L56-L72):
    `addr_a` directly indexes 32-bit words inside the memory arrays (`mem_bank0[addr_a[9:0]]` and `mem_bank1[addr_a[9:0]]`).

---

### 1.3 Exact Acceptance Condition & Timing
* **Handshake Logic (from lines 168-183 of `multibank_sram_subsystem.sv`):**
  ```systemverilog
  if (wr_req[w_idx]) begin
      if (bank_enable[target_bank] && bank_wr_active[target_bank] && (granted_wr_port[target_bank] == w_idx)) begin
          wr_ready[w_idx]          = 1'b1;
          wr_ack[w_idx]            = 1'b1;
          wr_conflict_stall[w_idx] = 1'b0;
      end else begin
          wr_ready[w_idx]          = 1'b0;
          wr_ack[w_idx]            = 1'b0;
          wr_conflict_stall[w_idx] = 1'b1;
      end
  end
  ```
* **Exact Acceptance Condition:**
  A write is accepted on clock cycle $T$ **if and only if**:
  $$\text{sram\_wr\_req} == 1 \quad \text{AND} \quad \text{sram\_wr\_ready} == 1 \quad (\equiv \text{sram\_wr\_ack} == 1)$$
* **Latency:** Synchronous single-cycle commit. The data is written into the physical SRAM macro on the rising edge of `clk` where `wr_req && wr_ready` is sampled high.
* **Hold Requirement:** Whenever `sram_wr_ready == 1'b0`, the master **must** keep `sram_wr_req`, `sram_wr_addr`, `sram_wr_din`, and `sram_wr_byte_we` stable.

---

### 1.4 Conflict Resolution Between Port 0 and Port 1
* Each of the 8 physical banks has **exactly one physical write port**.
* Fixed-priority arbitration grants the lowest port index: `Port 0 > Port 1 > ... > Port 7`.
* If Port 0 (DMA Ingress) and Port 1 (OFMAP Drain) target the same bank in the same cycle:
  * Port 0 is granted (`granted_wr_port = 0`).
  * Port 1 is stalled: `wr_ready[1] = 1'b0`, `wr_ack[1] = 1'b0`, `wr_conflict_stall[1] = 1'b1`.
* If Port 0 and Port 1 target different banks in the same cycle, both writes commit simultaneously with zero stalls.

---

## 2. In-Depth Address Mapping & OFMAP Address Conflict Analysis

### 2.1 Low-Order Bank Interleaving
Address decoding in `multibank_sram_subsystem.sv` ([lines 62-66](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv#L62-L66)):
$$\text{Bank ID} = \text{wr\_addr}[2:0] = \text{wr\_addr} \pmod 8$$
$$\text{Bank Row} = \text{wr\_addr}[13:3] = \lfloor \text{wr\_addr} / 8 \rfloor$$

### 2.2 Physical Capacity & Bounds
* Each bank macro contains `TOTAL_BYTES = 5184`, corresponding to `1296 words per bank`.
* Legal Bank Row range: $0 \le \text{Bank Row} < 1296$.
* Total Physical Capacity across all 8 banks:
  $$\text{Total Physical Capacity} = 8 \times 1296 = 10,368 \text{ words} = 41,472 \text{ bytes}$$
* **Maximum Legal Word Address:** `10,368 - 1 = 10,367` (`14'h287F`).
  Any write to word address $\ge 10,368$ (`14'h2880`) trips `a_oob = 1'b1` in [`hybrid_sram_bank.sv#L48`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv#L48) and suppresses the write.

---

### 2.3 The "Base Address 0x2000" Conflict Analysis

The user request highlighted:
> *"The proposed OFMAP base address 0x2000 conflicts with the reported 14-bit address width. Do not truncate, reinterpret, or silently change this address. If the intended memory map cannot be established from the RTL, document the blocker and propose valid candidate addresses based on the real decoder. Do not invent an address map."*

Here is the exact architectural origin and resolution of this conflict:

#### Conflict Factor 1: Byte Address vs. Word Address Semantics
* In AXI systems, software and drivers specify addresses in **byte units**.
* If a host program specifies `0x2000` as a **byte address**:
  * Byte address: `0x2000` ($8,192$ bytes).
  * Word address: `0x2000 >> 2 = 0x0800` ($2,048$ words).
  * **Hazard:** In [`datapath_compute_feeder.sv#L22-L23`](file:///e:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv#L22-L23), Ping-Pong Buffer A is at word address `14'h0000` (Words $0 \dots 4095$, Bytes `0x0000 - 0x3FFF`), and Buffer B is at word address `14'h1000` (Words $4096 \dots 8191$, Bytes `0x4000 - 0x7FFF`).
  * If `0x2000` were interpreted as a byte address (`Word 14'h0800`), the OFMAP would be written directly into the middle of Buffer A, destroying active CNN input features!

#### Conflict Factor 2: Word Address Interpretation on 14-Bit Bus
* If `0x2000` is interpreted directly as a **word address** (`14'h2000`):
  * Word address: `14'h2000` ($8,192$ words).
  * Byte address: $8,192 \times 4 = 32,768 \text{ bytes} = \text{0x8000}$.
  * Address bit width check:
    * $8,192 = 2^{13}$. In binary: `14'b10_0000_0000_0000`.
    * A 14-bit bus can represent up to $2^{14}-1 = 16,383$ (`14'h3FFF`).
    * Therefore, `14'h2000` fits within 14 bits.
  * Physical boundary check:
    * Word 8,192 has Bank ID $= 8192 \pmod 8 = 0$, Bank Row $= 8192 / 8 = 1024$.
    * Since $1024 < 1296$, row 1024 is physically present inside the memory macro.
    * Tile 0 spans 128 words: Words $8,192 \dots 8,319$ (`14'h2000` to `14'h207F`).
    * Word 8,319 has Bank Row $= 8319 / 8 = 1039 \le 1295$ (completely inside bounds).
  * **Bus Discrepancy:** On an external 14-bit *byte* interface, byte address `0x8000` (bit 15) cannot be represented without 16 address bits. However, the internal SRAM port is a 14-bit *word* interface.

#### Conflict Factor 3: Memory Map Candidates Based on Real RTL

| Candidate | Unit Type | Word Addr | Byte Addr | SRAM Location | Feasibility Assessment |
| :---: | :---: | :---: | :---: | :--- | :--- |
| **Candidate 1** | Word Address | `14'h2000` | `0x8000` | Words 8,192–8,319 (Row 1024–1039) | **Valid & Recommended:** Resides safely above Buffer B (`14'h1000 - 14'h1FFF`) and below physical limit (`14'h287F`). Zero overlap with input buffers. |
| **Candidate 2** | Byte Address | `14'h0800` | `0x2000` | Words 2,048–2,175 (Row 256–271) | **Invalid / Overlap Hazard:** Overlaps with Ping-Pong Buffer A (`14'h0000 - 14'h0FFF`). |
| **Candidate 3** | Configurable | `base_addr` | User-defined | Configurable via input port | **Adopted Hardware Solution:** Controller exposes `input logic [13:0] base_addr`. Hardware validates `base_addr + 128 <= 10368` and rejects invalid ranges with `drain_error_flag = 1`. |

---

## 3. Implementation Decision

To eliminate hardcoded assumptions and strictly adhere to the RTL decoder:
1. `ofmap_drain_controller.sv` provides an explicit port: `input logic [SRAM_ADDR_W-1:0] base_addr`.
2. Hardware parameter validation dynamically checks:
   $$\text{target\_end\_addr} = \text{base\_addr} + 128$$
   If $\text{target\_end\_addr} > 10,368$, the controller asserts `drain_error_flag = 1'b1`, refuses to assert `sram_wr_req`, and remains safely in `ST_IDLE`.
3. This guarantees that neither byte/word reinterpretation nor out-of-bounds corruption can compromise the physical SRAM.
