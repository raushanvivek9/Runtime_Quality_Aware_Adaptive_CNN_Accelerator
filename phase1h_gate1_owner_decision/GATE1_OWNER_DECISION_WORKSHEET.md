# Phase Gate 1: Project Owner Decision Worksheet
## Architecture Conformance Review and Phase 2 Implementation Authorization

**Document ID**: `GATE1_OWNER_DECISION_WORKSHEET.md`  
**Project**: `Neural_Acc`  
**Repository**: `/home/cs25m115/Neural_Acc`  
**Governing Authority**: Project Owner (`Raushan vivek`)  
**Anchored Baseline Commit**: `3d92fdcf39f682e1f7643f79c3d86ac3a9b74a5f`  
**Date of Issuance**: 15 October 2026  

---

## 1. Context and Objective

Following the execution of Phase 1H Steps 1 through 4 (Arithmetic Reference Model, Independent Conformance Audit, Memory Feasibility Audit, and Memory Reconciliation Model), this worksheet provides the **formal governance mechanism for the Project Owner to review technical readiness and authorize Phase 2 (RTL Implementation and Synthesis)**.

### Prior Baseline
- In Gate 0 ([`phase1g_5_28_.../OWNER_DECISION_WORKSHEET.md`](file:///home/cs25m115/Neural_Acc/phase1g_5_28_d09_d13_decision_resolution/OWNER_DECISION_WORKSHEET.md#L114)), Phase 1H was authorized and Phase 2 was explicitly designated as `UNAUTHORIZED (MANDATORY: Requires Gate 1 Audit)`.
- This document constitutes the **Gate 1 Conformance Review and Phase 2 Authorization Charter**.

---

## 2. Technical Findings and Open Decisions

Please review each decision below and indicate your selection by marking `[X]` in the corresponding box.

---

### Decision G1-D01: Phase 2 Authorization and Implementation Strategy

- **Context**: The Phase 1H Implementation Charter defines software benchmark validation (WP-1/WP-4 on VGG-16 and ResNet-18) and multi-tile simulation (WP-2). Phase 2 entails RTL implementation (Verilog/SystemVerilog) and physical/FPGA synthesis.
- **Options**:
  - `[yes  ]` **OPTION G1-01A (Immediate Phase 2 Release with Concurrent 1H Benchmarking)**:  
    Formally authorize immediate commencement of Phase 2 RTL datapath and control unit design, executing Phase 1H software benchmark sweeps concurrently.
  - `[  ]` **OPTION G1-01B (Sequential Release — Complete 1H Benchmarks First)**:  
    Require completion and bit-exact sign-off of Phase 1H Steps 5–8 (VGG-16 / ResNet-18 benchmark layers and CIFAR-10 validation) before releasing Phase 2 RTL synthesis.
  - `[  ]` **OPTION G1-01C (Defer Phase 2 Authorization)**:  
    Withhold Phase 2 authorization pending further microarchitectural modeling.

---

### Decision G1-D02: 32-Byte Saturation Flag Allocation Resolution

- **Context**: Amendment AMD-05 mandates a 1-bit sticky saturation flag per bank-slot ($16 \text{ slots} \times 16 \text{ banks} = 256 \text{ bits} = 32 \text{ bytes}$). The ratified 5,184-byte D-11 budget fully allocates its 1,792-byte control allowance to tags, counters, deskew, drain, and routing, leaving 0 bytes in SRAM for saturation flags.
- **Options**:
  - `[ yes ]` **OPTION G1-02A (Datapath Register File Latches — Recommended)**:  
    Budget the 32 bytes of sticky saturation flags in datapath register latches directly adjacent to the 40-bit accumulators, preserving the hybrid SRAM macro capacity at exactly **5,184 bytes**.
  - `[  ]` **OPTION G1-02B (SRAM Macro Expansion to 5,216 Bytes)**:  
    Expand the hybrid SRAM macro allocation from 5,184 bytes to **5,216 bytes** (+32 bytes, +0.62%) to store saturation flags directly in SRAM memory words.

---

### Decision G1-D03: Interconnect Latency Bounding Policy (Generation-Tag Safety)

- **Context**: Decision D-10 uses 8-bit generation tags ($0..255$) per slot. The layer drain-and-quiesce barrier eliminates inter-layer aliasing, but intra-layer aliasing across tile reallocations ($M > 4,096$) is theoretically possible if a delayed flit survives 256 slot allocations.
- **Options**:
  - `[ yes ]` **OPTION G1-03A (Mandate Interconnect Transit Latency Bound — Recommended)**:  
    Formally ratify an architectural requirement that the Network-on-Chip (NoC) must enforce a maximum transit latency bound:
    $$T_{\text{transit\_max}} < 256 \times T_{\text{slot\_reuse\_min}}$$
    retaining compact 8-bit generation tags.
  - `[  ]` **OPTION G1-03B (Expand to 16-Bit Generation Tags)**:  
    Expand generation tags from 8-bit to 16-bit (+256 bytes SRAM overhead, total budget 5,440 B) to provide 65,536-allocation safety.
  - `[  ]` **OPTION G1-03C (Accept Risk and Defer to NoC Implementation)**:  
    Accept the theoretical wraparound risk as negligible and defer latency bounding to physical interconnect routing.

---

### Decision G1-D04: Transport Reliability Invariant (Scalar K-Progress Counter)

- **Context**: Decision D-09 implements an in-order scalar counter ($K_{\text{resolved}} = K_{\text{executed}} + K_{\text{skipped}} == K_{\text{total}}$). The counter verifies total resolved cardinality but lacks an associative scoreboard to detect a dropped flit paired with a duplicate flit.
- **Options**:
  - `[ yes ]` **OPTION G1-04A (Contract Transport Guarantee — Recommended)**:  
    Formally ratify that the underlying on-chip transport layer is contracted to provide strictly lossless, exactly-once, in-order packet delivery, preserving the area-efficient scalar counter.
  - `[  ]` **OPTION G1-04B (Mandate Hardware Deduplication Scoreboard in RTL)**:  
    Direct the Phase 2 RTL team to implement an associative coordinate scoreboard or packet sequence tracking buffer in the slot control datapath.

---

## 3. Project Owner Execution Block

```
================================================================================
                    PROJECT OWNER GATE 1 EXECUTION BLOCK
================================================================================

I, Raushan vivek, in my capacity as Project Owner of Neural_Acc, have reviewed 
the Gate 1 Conformance Audit findings, the Phase 1H software models, the memory 
accounting reconciliations, and the open technical risk analyses.

I hereby record my formal determinations for Gate 1 and Phase 2:

PROJECT OWNER NAME:      ________Raushan vivek__________________________________

SIGNATURE:               _____________Raushan Vivek__________________________________________

DATE:                    __15__/_10___/2026_________________________________________

GATE 1 DETERMINATION:    [ yes ] FORMALLY APPROVED
                         [  ] PROVISIONALLY APPROVED WITH CONCURRENT BENCHMARKS
                         [  ] WITHHELD / REVISION REQUIRED

PHASE 2 AUTHORIZATION:   [ yes ] FULLY AUTHORIZED (RTL Implementation & Synthesis)
                         [  ] PROVISIONALLY AUTHORIZED (Datapath RTL Only)
                         [  ] UNAUTHORIZED (Blocked Pending Benchmark Clearance)

SPECIAL OWNER DIRECTIVES / WAIVERS (IF ANY):No
________________________________________________________________________________
________________________________________________________________________________
================================================================================
```
