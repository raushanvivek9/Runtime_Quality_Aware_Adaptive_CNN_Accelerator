# Neural_Acc — TSK-08 Remaining Gaps & Architectural Audit Report

**Project**: `Neural_Acc` (`Runtime_Quality_Aware_Adaptive_CNN_Accelerator`)  
**Audit Target**: Phase 2 Implementation Milestones (TSK-01 through TSK-08)  
**Repository Working Directory**: `E:\MTech\LanChain\MTP`  
**RTL Directory**: `phase2_step1_microarchitecture_and_rtl`  
**Date**: November 1, 2026  
**Auditor**: Independent Microarchitecture & Verification Auditor (Antigravity Advanced Agentic System)  
**Final Verdict**: **`PASS_WITH_LIMITATIONS`**

---

## 1. Executive Summary & Verdict

This audit independently determines what remains before `Neural_Acc` can legitimately claim to be a **functionally validated, adaptive processing element (PE) allocation CNN accelerator**.

While prior task reports claim 14 passing testbenches with 800/800 checks, an independent source-code and microarchitectural audit reveals significant functional and architectural boundaries between what has been simulated and what constitutes a complete, hardware-accelerated CNN system.

### Summary Assessment:
1. **Simulation Regression Status (`PASS`)**:
   - All 14 SystemVerilog testbenches compile cleanly with Icarus Verilog (`iverilog -g2012`) and pass 100% of their assertion checks (**800/800 passing checks**).
   - Baseline RTL files ([`accelerator_core_top.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv), [`mac_unit_40b.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv), [`k_progress_tracker.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv), [`slot_control_unit.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv), and [`hybrid_sram_bank.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv)) remain bit-exact and unmodified.
2. **Core Computational Contract (`PASS`)**:
   - The arithmetic pipeline performs bit-exact signed $16\text{b} \times 16\text{b} \to 32\text{b}$ multiplication, dynamic exact-zero skipping (`bypass_mac`), and 40-bit sticky saturation clamping at $[+549,755,813,887, -549,755,813,888]$.
3. **Primary Architectural Limitations (`LIMITATIONS`)**:
   - **Scalar Broadcast Only in Integrated Top-Level**: In [`neural_acc_integrated_top.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/neural_acc_integrated_top.sv), the compute feeder ([`datapath_compute_feeder.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv)) fetches only **one 32-bit word per clock cycle** from SRAM Port B0. It broadcasts 1 activation across all 4 rows and 1 weight across all 16 columns. All active PEs compute the **identical scalar dot product**. True parallel General Matrix Multiply (GEMM) or 2D Convolution (where distinct PEs compute distinct output channels) is **unimplemented** at the top level.
   - **Stranded SRAM Bandwidth**: 7 out of 8 read ports and 7 out of 8 write ports on the [`multibank_sram_subsystem.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv) are permanently tied to zero in the integrated wrapper.
   - **Simultaneous DMA & Compute Unstimulated in Integration**: All integration tests execute sequentially (DMA transfer $\to$ wait done $\to$ issue command $\to$ wait done). Concurrent DMA ingestion into Buffer B while computing from Buffer A is completely unexercised at the top level.
   - **Single-Beat AXI4 Streaming**: The DMA master engine issues single-beat transactions (`arlen=0`, `awlen=0`) rather than true multi-beat AXI4 bursts.
   - **Absence of Physical Evidence**: Zero synthesis, cell library mapping, static timing analysis (STA), or physical power characterization (PrimeTime PX / Joules) has been performed.

---

## 2. Component Implementation & Verification Status Table

| Module Name | Implemented | Integrated in Top | Functionally Verified | Synthesized | Timing Verified | Power Evaluated | Evidence / Source Locations |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **`mac_unit_40b`** | **YES** | **YES** | **YES** | **NO** | **NO** | **NO** | [`mac_unit_40b.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv#L1-L93) |
| **`k_progress_tracker`** | **YES** | **NO** | **YES** | **NO** | **NO** | **NO** | [`k_progress_tracker.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv#L1-L100) (Baseline only) |
| **`slot_control_unit`** | **YES** | **NO** | **YES** | **NO** | **NO** | **NO** | [`slot_control_unit.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv#L1-L120) (Baseline only) |
| **`hybrid_sram_bank`** | **YES** | **YES** | **YES** | **NO** | **NO** | **NO** | [`hybrid_sram_bank.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv#L1-L115) (Sub-bank of SRAM) |
| **`accelerator_core_top`** | **YES** | **NO** | **YES** | **NO** | **NO** | **NO** | [`accelerator_core_top.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv#L1-L150) (Step 1 Baseline) |
| **`pe_array_40b`** | **YES** | **YES** | **YES** | **NO** | **NO** | **NO** | [`pe_array_40b.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/pe_array_40b.sv#L1-L173) |
| **`adaptive_pe_controller`** | **YES** | **YES** | **YES** | **NO** | **NO** | **NO** | [`adaptive_pe_controller.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv#L1-L259) |
| **`multibank_sram_subsystem`**| **YES** | **PARTIAL** | **YES** | **NO** | **NO** | **NO** | [`multibank_sram_subsystem.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv#L1-L327) (Only Port 0 wired) |
| **`ping_pong_buffer_controller`**| **YES**| **YES** | **YES** | **NO** | **NO** | **NO** | [`ping_pong_buffer_controller.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/ping_pong_buffer_controller.sv#L1-L380) |
| **`layer_command_sequencer`**| **YES** | **YES** | **YES** | **NO** | **NO** | **NO** | [`layer_command_sequencer.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/layer_command_sequencer.sv#L1-L470) |
| **`dma_controller`** | **YES** | **YES** | **YES** | **NO** | **NO** | **NO** | [`dma_controller.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/dma_controller.sv#L1-L495) (Single-beat AXI4) |
| **`dma_to_sram_write_adapter`**| **YES**| **YES** | **YES** | **NO** | **NO** | **NO** | [`dma_to_sram_write_adapter.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/dma_to_sram_write_adapter.sv#L1-L115) |
| **`datapath_compute_feeder`** | **YES** | **YES** | **YES** | **NO** | **NO** | **NO** | [`datapath_compute_feeder.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv#L1-L179) (Scalar broadcast) |
| **`neural_acc_integrated_top`**| **YES**| **YES** | **YES** | **NO** | **NO** | **NO** | [`neural_acc_integrated_top.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/neural_acc_integrated_top.sv#L1-L578) |

---

## 3. Audit A — Actual Regression Results & Exit Status

All 14 testbenches were compiled and simulated directly using Icarus Verilog (`iverilog 12.0 (devel)`) on Ubuntu (WSL).

### Regression Execution Log:

| # | Testbench Name | Category | Exact Compilation Command | Compile Exit | Sim Exit | Assertion Checks | Status |
| :-: | :--- | :---: | :--- | :-: | :-: | :-: | :-: |
| 1 | `tb_accelerator_core` | Baseline | `iverilog -g2012 -o /tmp/sim_b1 accelerator_core_top.sv mac_unit_40b.sv hybrid_sram_bank.sv slot_control_unit.sv k_progress_tracker.sv tb_accelerator_core.sv && vvp /tmp/sim_b1` | 0 | 0 | 9 / 9 | **PASS** |
| 2 | `tb_mac_saturation` | Baseline | `iverilog -g2012 -o /tmp/sim_b2 mac_unit_40b.sv tb_mac_saturation.sv && vvp /tmp/sim_b2` | 0 | 0 | 11 / 11 | **PASS** |
| 3 | `tb_k_progress_tracker` | Baseline | `iverilog -g2012 -o /tmp/sim_b3 k_progress_tracker.sv tb_k_progress_tracker.sv && vvp /tmp/sim_b3` | 0 | 0 | 14 / 14 | **PASS** |
| 4 | `tb_hybrid_sram_bank` | Baseline | `iverilog -g2012 -o /tmp/sim_b4 hybrid_sram_bank.sv tb_hybrid_sram_bank.sv && vvp /tmp/sim_b4` | 0 | 0 | 13 / 13 | **PASS** |
| 5 | `tb_drain_backpressure` | Baseline | `iverilog -g2012 -o /tmp/sim_b5 slot_control_unit.sv tb_drain_backpressure.sv && vvp /tmp/sim_b5` | 0 | 0 | 15 / 15 | **PASS** |
| 6 | `tb_acceptance_integrated` | Baseline | `iverilog -g2012 -o /tmp/sim_b6 accelerator_core_top.sv mac_unit_40b.sv hybrid_sram_bank.sv slot_control_unit.sv k_progress_tracker.sv tb_acceptance_integrated.sv && vvp /tmp/sim_b6` | 0 | 0 | 29 / 29 | **PASS** |
| 7 | `tb_pe_array_40b` | Subsystem | `iverilog -g2012 -o /tmp/sim_s1 mac_unit_40b.sv pe_array_40b.sv tb_pe_array_40b.sv && vvp /tmp/sim_s1` | 0 | 0 | 28 / 28 | **PASS** |
| 8 | `tb_adaptive_pe_controller` | Subsystem | `iverilog -g2012 -o /tmp/sim_s2 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv tb_adaptive_pe_controller.sv && vvp /tmp/sim_s2` | 0 | 0 | 53 / 53 | **PASS** |
| 9 | `tb_multibank_sram_subsystem` | Subsystem | `iverilog -g2012 -o /tmp/sim_s3 hybrid_sram_bank.sv multibank_sram_subsystem.sv tb_multibank_sram_subsystem.sv && vvp /tmp/sim_s3` | 0 | 0 | 137 / 137 | **PASS** |
| 10 | `tb_ping_pong_buffer_controller` | Subsystem | `iverilog -g2012 -o /tmp/sim_s4 ping_pong_buffer_controller.sv tb_ping_pong_buffer_controller.sv && vvp /tmp/sim_s4` | 0 | 0 | 117 / 117 | **PASS** |
| 11 | `tb_layer_command_sequencer` | Subsystem | `iverilog -g2012 -o /tmp/sim_s5 layer_command_sequencer.sv tb_layer_command_sequencer.sv && vvp /tmp/sim_s5` | 0 | 0 | 97 / 97 | **PASS** |
| 12 | `tb_dma_controller` | Subsystem | `iverilog -g2012 -o /tmp/sim_s6 dma_controller.sv tb_dma_controller.sv && vvp /tmp/sim_s6` | 0 | 0 | 87 / 87 | **PASS** |
| 13 | `tb_neural_acc_integrated_top` | Integration | `iverilog -g2012 -o /tmp/sim_s7 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv ping_pong_buffer_controller.sv hybrid_sram_bank.sv multibank_sram_subsystem.sv dma_controller.sv layer_command_sequencer.sv dma_to_sram_write_adapter.sv datapath_compute_feeder.sv neural_acc_integrated_top.sv tb_neural_acc_integrated_top.sv && vvp /tmp/sim_s7` | 0 | 0 | 132 / 132 | **PASS** |
| 14 | `tb_workload_validation` | Integration | `iverilog -g2012 -o /tmp/sim_s8 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv ping_pong_buffer_controller.sv hybrid_sram_bank.sv multibank_sram_subsystem.sv dma_controller.sv layer_command_sequencer.sv dma_to_sram_write_adapter.sv datapath_compute_feeder.sv neural_acc_integrated_top.sv tb_workload_validation.sv && vvp /tmp/sim_s8` | 0 | 0 | 58 / 58 | **PASS** |
| **TOTAL** | **14 Testbenches** | — | — | **0** | **0** | **800 / 800** | **100% PASS** |

### Regression Tooling Defect Identified:
- **`run_regression.py` Exit Status Flaw**: Inspection of [`run_regression.py`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/run_regression.py#L58) reveals that the script summarizes passed and failed test counts, but **does not invoke `sys.exit(1)` upon failure**. The Python script terminates with exit status `0` even when sub-processes fail.
- **Obsolete Shell Script**: [`run_sim.sh`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/run_sim.sh#L9-L10) contains hardcoded binary paths (`/home/cs25m115/anaconda3/...`) and only covers baseline suite #1.

---

## 4. Audit B — PE Datapath Analysis

### 4.1 Signal Tracing from SRAM to PEs
1. **SRAM Interface**: Feeder reads 32-bit word `sram_rd_dout_0` from SRAM Port B0.
2. **Word Unpacking** ([`datapath_compute_feeder.sv:90-91`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv#L90-L91)):
   - `sram_act_sample = sram_rd_dout[15:0]`
   - `sram_weight_sample = sram_rd_dout[31:16]`
3. **Array Interconnect** ([`neural_acc_integrated_top.sv:258-264`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/neural_acc_integrated_top.sv#L258-L264)):
   ```systemverilog
   for (dr_pe = 0; dr_pe < ROWS; dr_pe = dr_pe + 1) begin : gen_pe_act_broadcast
       assign act_data_row[dr_pe] = feeder_act_sample;
       assign act_mask_row[dr_pe] = feeder_act_mask;
       for (dc_pe = 0; dc_pe < COLS; dc_pe = dc_pe + 1) begin : gen_pe_w_broadcast
           assign weight_data[dr_pe][dc_pe] = feeder_weight_sample;
       end
   end
   ```
4. **PE Core Processing** ([`pe_array_40b.sv:117-119`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/pe_array_40b.sv#L117-L119)):
   - `broadcast_act` is tied to `1'b1`.
   - Every active PE receives `pe_act_in = feeder_act_sample` and `pe_weight_in = feeder_weight_sample`.

> [!WARNING]
> **Major Architectural Gap**: Operand delivery in the integrated accelerator does **not** support independent values per PE. It broadcasts a single scalar activation $A$ across all 4 rows and a single scalar weight $W$ across all 16 columns. Every active PE computes the identical scalar dot product:
> $$\text{PE}[r][c] = \sum_{k=0}^{K-1} A(k) \times W(k)$$
> True 2D convolution and GEMM matrix multiplication are **unsupported** by the current feeder datapath.

### 4.2 Active vs. Inactive PE Behavior
- **16-PE Mode (`2'b00`)**: Columns 0..3 active (16 PEs). Columns 4..15 inactive:
  - Multiplier inputs clamped to 0: `pe_act_in = 0`, `pe_weight_in = 0`.
  - MAC clock enable gated to 0: `pe_mac_enable = 0`.
  - Output accumulator clamped to 0: `accum_out = 40'sd0`.
- **32-PE Mode (`2'b01`)**: Columns 0..7 active (32 PEs). Columns 8..15 inactive (clamped).
- **64-PE Mode (`2'b10`)**: All 16 columns active (64 PEs).
- **Invalid Mode (`2'b11`)**: All columns disabled, `cfg_invalid = 1`.

### 4.3 Arithmetic Correctness & Assertions
- **Signed Arithmetic**: Validated across positive, negative, and mixed signs. Full 32-bit signed product retained.
- **Exact-Zero Bypass**: Verified: `bypass_mac = (!mask) || (act_data == '0)`. Skips multiplier trigger and asserts `cycle_skipped`.
- **40-bit Saturation**: Clamping confirmed at $+549,755,813,887$ and $-549,755,813,888$ with persistent `sticky_saturation`.
- **Weakness in Integration Testing**: Because top-level integration tests broadcast identical values to all PEs, internal array routing errors or row/column index swaps cannot be observed at the top level. They are only verified in standalone [`tb_pe_array_40b.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/tb_pe_array_40b.sv).

---

## 5. Audit C — Adaptive Control Evaluation

### 5.1 Decision Path & Thresholding
- **Threshold Evaluation** ([`adaptive_pe_controller.sv:90-101`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv#L90-L101)):
  - Evaluates host-supplied estimates: `degradation_hat_16`, `degradation_hat_32`, `degradation_hat_64` against `D_MAX_Q16 = 3277` (5%).
  - Selection: If $\hat{D}_{16} \le 3277 \implies \text{MODE\_16PE}$; else if $\hat{D}_{32} \le 3277 \implies \text{MODE\_32PE}$; else $\text{MODE\_64PE}$ (`fallback_to_64 = 1`).
- **Mode Switching Latency**:
  - The controller latches configuration changes during state `ST_CLEAR`.
  - `ST_CLEAR` is a mandatory 1-cycle state executed on every layer start to clear accumulators.
  - Therefore, dynamic mode switching introduces **0 additional stall cycles or pipeline bubbles**.

### 5.2 Confirmation of Controller Nature
> [!IMPORTANT]
> The RTL controller is strictly a **decision rule** executing threshold comparison on externally supplied estimates. It is **not** an on-chip neural network quality estimator.

---

## 6. Audit D — Memory and Buffers

### 6.1 Address Progression & Interleaving
- **Interleaving Scheme** ([`multibank_sram_subsystem.sv:63-64, 74-75`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv#L63-L64)):
  - Global Word Address: 14 bits (`addr[13:0]`).
  - Low-order bank select: `bank_sel = addr[2:0]` (Bank 0..7).
  - Word address within bank: `bank_addr = addr[13:3]` (Offset 0..1023).
  - Successive sequential addresses automatically cycle across physical Banks 0 through 7.
- **Buffer Base Addresses**:
  - Buffer A Base: `14'h0000` $\implies$ Bank 0, Word 0.
  - Buffer B Base: `14'h1000` ($4096_{10}$) $\implies$ Bank 0, Word 512.
- **Bandwidth Underutilization**:
  - In [`neural_acc_integrated_top.sv:198-206, 229-235`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/neural_acc_integrated_top.sv#L198-L206), Read Ports 1..7 and Write Ports 1..7 are tied off to 0.
  - Only Port 0 is connected. The multi-bank crossbar's 8-word/cycle concurrent throughput is unexploited.

### 6.2 Concurrent Producer / Consumer Operations
- While [`ping_pong_buffer_controller.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/ping_pong_buffer_controller.sv) and [`hybrid_sram_bank.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv) support simultaneous Port A write and Port B read, **no test in `tb_neural_acc_integrated_top.sv` stimulates DMA writing to Buffer B while the PE array actively computes on Buffer A**.
- All existing tests execute DMA sequentially before issuing compute commands.

---

## 7. Audit E — DMA & AXI Interface

### 7.1 Single-Beat AXI4 Master Implementation
- Inspection of [`dma_controller.sv:61-93`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/dma_controller.sv#L61-L93) confirms:
  - `m_axi_arlen = 8'd0`
  - `m_axi_awlen = 8'd0`
  - `m_axi_arsize = 3'b010` (4 bytes)
  - `m_axi_arburst = 2'b01` (INCR)
- The DMA controller generates **single-beat requests** for every 32-bit word. It does not perform true AXI4 multi-beat bursting (`INCR16`, `INCR64`, etc.).

### 7.2 Control Interface
- The DMA engine is controlled via parallel dedicated wires (`dma_start`, `dma_src_addr`, `dma_dst_addr`, `dma_transfer_len`). It does **not** implement an AXI4-Lite slave register bank.

---

## 8. Audit F — System Integration & Unconnected Modules

### 8.1 Active Integrated Hierarchy
[`neural_acc_integrated_top.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/neural_acc_integrated_top.sv) correctly instantiates and interconnects:
1. `u_sequencer` ([`layer_command_sequencer.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/layer_command_sequencer.sv))
2. `u_pe_controller` ([`adaptive_pe_controller.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/adaptive_pe_controller.sv))
3. `u_ping_pong` ([`ping_pong_buffer_controller.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/ping_pong_buffer_controller.sv))
4. `u_dma` ([`dma_controller.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/dma_controller.sv))
5. `u_dma_sram_adpt` ([`dma_to_sram_write_adapter.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/dma_to_sram_write_adapter.sv))
6. `u_sram_subsystem` ([`multibank_sram_subsystem.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/multibank_sram_subsystem.sv))
7. `u_feeder` ([`datapath_compute_feeder.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/datapath_compute_feeder.sv))
8. `u_pe_array` ([`pe_array_40b.sv`](file:///E:/MTech/LanChain/MTP/phase2_step1_microarchitecture_and_rtl/pe_array_40b.sv))

### 8.2 Unconnected Baseline Modules
The following modules exist in the repository and pass independent tests, but are **not connected** to `neural_acc_integrated_top.sv`:
- **`accelerator_core_top.sv`**: Standalone single-MAC baseline core from Step 1.
- **`k_progress_tracker.sv`**: Out-of-order flit and duplicate sequence error detector used only in `accelerator_core_top.sv`.
- **`slot_control_unit.sv`**: Slot lifecycle FSM used only in `accelerator_core_top.sv`.
- *Assessment*: Progress and drain tracking in the integrated design were superseded by internal counters in `datapath_compute_feeder.sv`. These baseline modules are functionally orphaned in Phase 2.

---

## 9. Audit G — Research Evidence & Claim Separation

| Claim / Metric | Supported by Simulation | Requires Workload Experiments | Requires Synthesis / Physical Implementation | Classification |
| :--- | :---: | :---: | :---: | :---: |
| **Signed 16b x 16b MAC Math** | **YES** | NO | NO | **DIRECTLY MEASURED** |
| **40-bit Saturation Clamping** | **YES** | NO | NO | **DIRECTLY MEASURED** |
| **Exact-Zero Multiplier Skip** | **YES** | NO | NO | **DIRECTLY MEASURED** |
| **FSM Cycle Counts & Latency** | **YES** | NO | NO | **DIRECTLY MEASURED** |
| **Adaptive Decision Thresholds**| **YES** | NO | NO | **DIRECTLY MEASURED** |
| **PE Dynamic Activity Gating** | **YES** | NO | NO | **DIRECTLY MEASURED (Signal level)** |
| **Multi-Channel Parallel GEMM** | **NO** | **YES** | NO | **UNIMPLEMENTED IN INTEGRATION** |
| **Simultaneous DMA & Compute** | **NO** | **YES** | NO | **UNTESTED IN INTEGRATION** |
| **True Clock Gating Efficiency**| **NO** | NO | **YES** | **ANALYTICAL ESTIMATE ONLY** |
| **Physical Power / Energy Savings**| **NO** | NO | **YES** | **UNVERIFIED CLAIM** |
| **Silicon Area & Gate Count** | **NO** | NO | **YES** | **UNVERIFIED CLAIM** |
| **Operating Frequency ($f_{\text{max}}$)**| **NO** | NO | **YES** | **UNVERIFIED CLAIM** |

---

## 10. Classified Audit Findings

### 10.1 Finding Summary Table

| Finding ID | Severity | Affected File(s) | Line Number(s) | Summary |
| :--- | :---: | :--- | :--- | :--- |
| **F-01** | **MAJOR** | `datapath_compute_feeder.sv`<br>`neural_acc_integrated_top.sv` | `L65-70, L100-103`<br>`L258-264, L564-570` | Feeder broadcasts scalar activation/weight; general 2D GEMM parallel acceleration is unimplemented. |
| **F-02** | **MAJOR** | `tb_neural_acc_integrated_top.sv`<br>`tb_workload_validation.sv` | Multiple (`start_dma`) | Simultaneous DMA ingestion and PE computation is completely unexercised in top-level testbenches. |
| **F-03** | **MAJOR** | `neural_acc_integrated_top.sv`<br>`multibank_sram_subsystem.sv` | `L198-206, L229-235`<br>`L30-41` | 7 out of 8 SRAM read and write ports are tied to zero; multi-port concurrent memory bandwidth is stranded. |
| **F-04** | **MAJOR** | `dma_controller.sv` | `L13-18, L62, L78` | DMA controller only issues single-beat AXI4 transactions (`arlen=0, awlen=0`); true bursting is absent. |
| **F-05** | **MINOR** | `phase2_step1_.../run_regression.py` | `L34, L58` | Regression runner does not propagate non-zero exit status (`sys.exit(1)`) on test failures. |
| **F-06** | **MINOR** | `neural_acc_integrated_top.sv`<br>`k_progress_tracker.sv` | N/A | Baseline progress tracker and slot control modules are disconnected from integrated accelerator core. |
| **F-07** | **OBSERVATION** | Entire Repository | N/A | Zero physical synthesis, STA, or power analysis performed; energy savings claims remain unverified. |
| **F-08** | **OBSERVATION** | `adaptive_pe_controller.sv` | `L90-101` | Controller is a threshold comparator for external software estimates, not an on-chip accuracy estimator. |

---

## 11. Exact Tests Needed to Close Each Functional Gap

1. **Closing F-01 (Parallel GEMM Datapath)**:
   - Modify `datapath_compute_feeder.sv` to stream 2D vectors across rows/columns.
   - Deassert `broadcast_act` (`1'b0`) in `neural_acc_integrated_top.sv`.
   - Create `tb_gemm_convolution.sv` executing an authentic $4 \times 16 \times K$ matrix multiplication, comparing all 64 PE outputs against a golden NumPy matrix dot product.
2. **Closing F-02 (Simultaneous DMA & Compute)**:
   - Add Scenario 21 to `tb_neural_acc_integrated_top.sv`:
     1. Start Layer 1 compute on Buffer A ($K=16$).
     2. At cycle 5 of compute, assert `start_dma` targeting Buffer B ($len=16$).
     3. Verify `dma_busy` and `sequencer_busy` remain high simultaneously.
     4. Verify Buffer A computation finishes with exact expected sum.
     5. Verify Buffer B DMA finishes with exact data written and zero Port A/Port B memory collisions.
3. **Closing F-03 (Multi-Port SRAM Utilization)**:
   - Wire all 8 read ports of `multibank_sram_subsystem` to the upgraded feeder datapath.
   - Run parallel 8-word bursts and verify that `total_read_accesses` increments by 8 per cycle.
4. **Closing F-04 (Multi-Beat AXI4 Bursting)**:
   - Implement burst address tracking in `dma_controller.sv` with `arlen = 15` and `awlen = 15`.
   - Update AXI slave model in testbenches to verify 16-beat data streams terminated with `rlast` and `wlast`.
5. **Closing F-05 (Regression Runner Script)**:
   - Append `if total_failed > 0: sys.exit(1)` to `run_regression.py`.

---

## 12. Prioritized Milestones for Phase 2 Step 2

```
                                MILESTONE ROADMAP
                                
  ┌────────────────────────────────────────────────────────────────────────┐
  │ MS-1: Overlapped Ping-Pong Verification (Immediate Testbench Task)      │
  │       - Prove concurrent DMA write to Buf B & PE compute from Buf A    │
  └───────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │ MS-2: Multi-Bank Parallel Feeder Expansion                             │
  │       - Connect all 8 SRAM read ports to datapath compute feeder       │
  │       - Support distinct 2D inputs to PE array for true parallel GEMM  │
  └───────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │ MS-3: True AXI4 Multi-Beat Bursting Engine                             │
  │       - Upgrade DMA to support INCR16/INCR64 with 4KB boundary checks   │
  └───────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │ MS-4: ASIC Standard-Cell Synthesis & Static Timing Analysis            │
  │       - Map RTL to standard-cell library (e.g. FreePDK45 / TSMC 28nm)  │
  │       - Establish f_max, critical path slack, cell area, and gate count│
  └───────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │ MS-5: Gate-Level Power & Energy Evaluation                             │
  │       - Dump SAIF activity from standardized workload simulations      │
  │       - Measure true mW/pJ savings across 16-PE, 32-PE, 64-PE modes    │
  └────────────────────────────────────────────────────────────────────────┘
```

---

## 13. Final Audit Verdict

### Final Verdict: **`PASS_WITH_LIMITATIONS`**

- **`PASS`**: The digital logic, handshaking interfaces, arithmetic accuracy, saturation behavior, and configuration state machines are 100% verified and free of simulation bugs across 14 regression testbenches (800/800 passed checks).
- **`LIMITATIONS`**: The integrated accelerator currently implements a scalar-broadcast reduction engine, rather than a full multi-channel parallel CNN accelerator. Memory bandwidth across Banks 1..7 is unexploited, concurrent DMA/compute streaming remains unverified in top-level testbenches, AXI4 operates in single-beat mode, and physical synthesis/timing/power metrics are completely absent. These limitations must be resolved in Phase 2 Step 2 before making physical accelerator performance claims.

