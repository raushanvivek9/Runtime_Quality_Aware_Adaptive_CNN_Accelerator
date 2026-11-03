# TSK-20 Memory Telemetry, Bandwidth & Workload Replay Report

**Project:** Neural_Acc Accelerator  
**Task:** TSK-20 (Phase A: Memory Bandwidth, Bank-Conflict Telemetry, Stalls, and Realistic CNN Memory Replay)  
**Date:** November 2026  
**Status:** COMPLETE (Zero Regressions, Bit-Exact Reproducibility)

---

## 1. Executive Summary

Prior to TSK-20, the Neural_Acc memory subsystem contained internal signals for arbitration stalls and bank conflict flags (`wr_conflict_stall`, `rd_conflict_stall`, `bank_conflict_flags`, `total_conflicts_count`), but these signals were left unconnected `()` at the top-level integration wrapper (`neural_acc_integrated_top.sv`). Consequently, accelerator-level simulation could not quantify exact SRAM read/write bandwidth utilization, bank conflict penalties, or the true memory traffic reductions achieved by sparse feeder skipping.

In TSK-20:
1. **Architectural Observation & Monitoring:** Implemented a synthesizable, non-invasive hardware monitor, `memory_telemetry_monitor.sv`, that captures every accepted read/write transaction, stall cycle, bank conflict flag, and per-bank utilization metric without altering functional RTL or violating protected baselines.
2. **Top-Level Integration:** Connected all multi-bank SRAM subsystem diagnostic ports in `neural_acc_integrated_top.sv` and instantiated the telemetry monitor with automated per-layer clearing upon command handshake.
3. **Microbenchmark Suite (`tb_tsk20_memory_telemetry.sv`):** Verified multi-bank conflict-free reads, 4-port same-bank contention arbitration, simultaneous read/write, write channel contention, reset/clear invariants, and sparsity sweeps with 34/34 passing checks.
4. **Realistic CNN Trace Replay (`tb_tsk20_memory_replay.sv`):** Executed full 4x16 PE array layer computations for four representative CNN workloads (R18-C10, R18-C100, V16-C10, V16-C100) under both Dense and 50% Sparse regimes, logging cycle traces (`TSK20_MEMORY_REPLAY_TRACE.csv`) and aggregate metrics (`TSK20_MEMORY_REPLAY_RESULTS.csv`).

All 20 existing regression suites and both new TSK-20 suites pass with zero defects.

---

## 2. Memory Subsystem Architectural Audit

### 2.1 Multi-Bank SRAM Architecture
- **Total Capacity:** 41,472 Bytes structured across 8 physical dual-port hybrid SRAM banks (5,184 Bytes/bank, 1,296 words/bank).
- **Address Mapping:** Low-order bank interleaving where `bank_id = addr[2:0]` and `row_offset = addr[13:3]`.
- **Port Interfaces:**
  - **Port A (Write Channel):** 8 write ports arbitrated by fixed-priority logic (Port 0 highest priority). In the integrated top:
    - Port A0 is dedicated to DMA Ingestion (`dma_to_sram_write_adapter.sv`).
    - Port A1 is dedicated to OFMAP Drain (`ofmap_drain_controller.sv`).
    - Ports A2..A7 are tied off (idle).
  - **Port B (Read Channel):** 8 read ports arbitrated by fixed-priority logic. In parallel feeder mode (`datapath_compute_feeder.sv`):
    - Weight Fetch: Requests 8 weight words (or mode-dependent subset: 2 words for 16-PE, 4 words for 32-PE, 8 words for 64-PE). Because the 8 weight words have sequential offsets $0..7$, they map to Banks $0..7$ concurrently with **zero bank conflicts**.
    - Activation Fetch: Requests 2 activation words (offsets 8 and 9) on Ports 0 and 1. These map to Bank 0 and Bank 1 with **zero conflicts between each other**.

### 2.2 Previously Unconnected Signals in `neural_acc_integrated_top.sv`
Lines 561-573 of `neural_acc_integrated_top.sv` left the diagnostic ports open:
```verilog
    .wr_conflict_stall     (),
    .rd_conflict_stall     (),
    .bank_conflict_flags   (),
    .bank_oob_err          (),
    .oob_error_any         (),
    .total_conflicts_count (),
    .total_read_accesses   (),
    .total_write_accesses  ()
```
These ports are now fully wired to internal telemetry buses and fed into `memory_telemetry_monitor.sv`.

---

## 3. Hardware Telemetry Monitor Specification (`memory_telemetry_monitor.sv`)

### 3.1 Monitored Signals
- Handshake signals: `wr_req`, `wr_ready`, `wr_ack`, `wr_conflict_stall` (8 bits each)
- Handshake signals: `rd_req`, `rd_ready`, `rd_rvalid`, `rd_conflict_stall` (8 bits each)
- Diagnostic flags: `bank_conflict_flags` (8 bits)

### 3.2 Accumulated Performance Metrics
| Metric Output | Width | Description |
|---|---|---|
| `mon_total_cycles` | 32-bit | Total elapsed clock cycles while monitoring |
| `mon_idle_cycles` | 32-bit | Cycles where neither read nor write requests were asserted |
| `mon_rd_req_cycles` | 32-bit | Cycles where at least one read channel was requested |
| `mon_wr_req_cycles` | 32-bit | Cycles where at least one write channel was requested |
| `mon_rd_accepted_trans` | 32-bit | Cumulative accepted read words (`rd_req && rd_ready`) |
| `mon_wr_accepted_trans` | 32-bit | Cumulative accepted write words (`wr_req && wr_ready`) |
| `mon_rd_stall_cycles` | 32-bit | Cycles where at least one read port suffered conflict stall |
| `mon_wr_stall_cycles` | 32-bit | Cycles where at least one write port suffered conflict stall |
| `mon_bank_conflict_cycles`| 32-bit | Cycles where at least one bank conflict was asserted |
| `mon_total_bank_conflicts` | 32-bit | Cumulative sum of conflict flags across all banks |
| `mon_bank_rd_trans[0:7]` | 32-bit $\times$ 8 | Per-bank accepted read transaction counters |
| `mon_bank_wr_trans[0:7]` | 32-bit $\times$ 8 | Per-bank accepted write transaction counters |
| `mon_bank_conflicts[0:7]` | 32-bit $\times$ 8 | Per-bank conflict incident counters |
| `mon_peak_rd_per_cycle` | 4-bit | Peak read bandwidth (up to 8 words/cycle) |
| `mon_peak_wr_per_cycle` | 4-bit | Peak write bandwidth (up to 8 words/cycle) |

---

## 4. Microbenchmark Verification Results (`tb_tsk20_memory_telemetry.sv`)

The synthetic microbenchmark exercises boundary conditions and handshake corner cases across 6 scenarios:

| Scenario | Description | Key Checks | Result |
|---|---|---|---|
| **Scenario 1** | Conflict-free 8-port parallel read | All 8 read ports ready; 0 stalls; 0 conflict flags; 8 reads accepted; peak rd = 8 | PASS |
| **Scenario 2** | Severe same-bank read contention | Ports 0..3 target Bank 0; Port 0 granted, Ports 1..3 stalled; Bank 0 conflict flag = 1; stall counter = 1 | PASS |
| **Scenario 3** | Concurrent read/write to disjoint banks | Port A0 writes Bank 2, Port B0 reads Bank 5; both ready; 0 conflicts; both accepted | PASS |
| **Scenario 4** | Write channel contention | Port A0 & Port A1 both target Bank 4; Port A0 granted, Port A1 stalled; Bank 4 conflict flag = 1 | PASS |
| **Scenario 5** | Telemetry clear / reset pulse | Assert `telemetry_clear`; verify all cumulative counters reset to zero | PASS |
| **Scenario 6** | Sparsity sweep handshakes | Cycle 1: Dense (8 reads); Cycle 2: 50% sparse (4 reads); Cycle 3: 100% idle (0 reads); total = 12 reads; 1 idle cycle | PASS |

**Total Microbenchmark Checks:** 34 Evaluated | 34 Passed | 0 Failed.

---

## 5. Workload Replay Results (`tb_tsk20_memory_replay.sv`)

Four real CNN workloads were simulated on the full integrated accelerator (`neural_acc_integrated_top` with 4x16 PE array and OFMAP drain) under both Dense and 50% Sparse regimes:

| Workload | PE Mode | K Steps | Regime | Total Cycles | Idle Cycles | Rd Req Cycles | Rd Accepted (Words) | Wr Accepted (Words) | Stall Ratio | Bandwidth (Words/Cyc) | Cycle Reduction | Memory Reduction |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **R18-C10** | 64-PE | 16 | DENSE | 184 | 24 | 32 | 160 | 128 | 0.00% | 5.00 | Baseline | Baseline |
| **R18-C10** | 64-PE | 16 | SPARSE | 161 | 9 | 24 | 96 | 128 | 0.00% | 4.00 | **-12.5%** | **-40.0%** |
| **R18-C100** | 32-PE | 16 | DENSE | 120 | 24 | 32 | 96 | 64 | 0.00% | 3.00 | Baseline | Baseline |
| **R18-C100** | 32-PE | 16 | SPARSE | 97 | 9 | 24 | 64 | 64 | 0.00% | 2.67 | **-19.2%** | **-33.3%** |
| **V16-C10** | 16-PE | 24 | DENSE | 112 | 32 | 48 | 96 | 32 | 0.00% | 2.00 | Baseline | Baseline |
| **V16-C10** | 16-PE | 24 | SPARSE | 77 | 9 | 36 | 72 | 32 | 0.00% | 2.00 | **-31.2%** | **-25.0%** |
| **V16-C100** | 64-PE | 24 | DENSE | 208 | 32 | 48 | 240 | 128 | 0.00% | 5.00 | Baseline | Baseline |
| **V16-C100** | 64-PE | 24 | SPARSE | 173 | 9 | 36 | 144 | 128 | 0.00% | 4.00 | **-16.8%** | **-40.0%** |

### 5.1 Observations and Architectural Insights
1. **Zero Bank Conflicts During Feeder Read:**
   - In both 16-PE, 32-PE, and 64-PE modes, the weight fetch maps cleanly to consecutive bank indices (`addr + 0` to `addr + 7`), and activation fetch maps to Banks 0 and 1. Bank conflict cycles during feeder execution are strictly zero (`0.00%` stall ratio).
2. **Bandwidth Utilization:**
   - In 64-PE mode, the feeder requests 8 words for weights in Phase A and 2 words for activations in Phase B (total 10 words over 2 request cycles = 5.00 words/cycle).
   - In 32-PE mode, 4 words for weights and 2 words for activations (total 6 words over 2 cycles = 3.00 words/cycle).
   - In 16-PE mode, 2 words for weights and 2 words for activations (total 4 words over 2 cycles = 2.00 words/cycle).
3. **Sparse Feeder Savings:**
   - In sparse mode with 50% exact-zero activation steps, memory read traffic dropped by **25.0% to 40.0%**, directly reducing memory energy and bus activity.
   - Total execution cycles dropped by **12.5% to 31.2%**, proving that skipping all-zero reduction steps reduces both memory traffic and latency.

---

## 6. Verification and Regression Summary

- **New RTL Module:** `phase2_step1_microarchitecture_and_rtl/memory_telemetry_monitor.sv`
- **Updated Top-Level RTL:** `phase2_step1_microarchitecture_and_rtl/neural_acc_integrated_top.sv`
- **New Testbenches:**
  - `phase2_step1_microarchitecture_and_rtl/tb_tsk20_memory_telemetry.sv` (34 / 34 checks passed)
  - `phase2_step1_microarchitecture_and_rtl/tb_tsk20_memory_replay.sv` (28 / 28 checks passed)
- **Artifacts Generated:**
  - `TSK20_MEMORY_REPLAY_RESULTS.csv`
  - `TSK20_MEMORY_REPLAY_TRACE.csv`
- **Protected Baselines:** All 5 protected baseline RTL files remain untouched.
- **Full Regression Status:** 20 / 20 original suites pass (12,202 / 12,202 checks) + 2 new suites pass (62 / 62 checks). Total: **12,264 checks passed, 0 failures**.

