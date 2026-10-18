# Phase 2 Step 2 Entry Criteria and Pre-requisites

**Project**: `Neural_Acc`  
**Phase**: Boundary between Phase 2 Step 1 and Phase 2 Step 2  
**Governing Baseline Commit**: `09a1be3e85f008a5de2bf70d19e04481faf0b982` on branch `main`  
**Document Status**: Proposed Gate 2 Entry Criteria  
**Date**: 2026-10-18  

---

## 1. Scope Boundary: Step 1 vs Step 2

- **Phase 2 Step 1 (Current Scope — Completed)**:
  - Single-slot hardware datapath and lifecycle FSM (`accelerator_core_top.sv`, `slot_control_unit.sv`).
  - 40-bit saturating MAC unit with exact-zero bypass (`mac_unit_40b.sv`).
  - 5,184-byte dual-bank physical SRAM array (`hybrid_sram_bank.sv`).
  - Scalar in-order resolved-K progress tracker with first-fault diagnostics (`k_progress_tracker.sv`).
  - Hardware completion handshake (Choice B: `completion_valid`, `completion_ready`, `ST_HANDSHAKE = 3'b110`).
  - 10,000-operation closed-loop golden regression with active completion monitoring.
- **Phase 2 Step 2 (Future Scope — NOT STARTED)**:
  - Multi-slot hardware scheduling and credit allocation across multiple concurrent execution slots.
  - Multi-tile interconnect network integration and mesh routing.
  - External memory controller and burst DMA interfaces.
  - Hardware host interface MMIO register file and interrupt controller.

---

## 2. Mandatory Safety Pre-requisites (Must Be Satisfied Prior to Step 2 Entry)

The following criteria represent non-negotiable safety conditions that must be formally satisfied before Phase 2 Step 2 development is authorized:

| ID | Mandatory Pre-requisite | Verification & Evidence Artifact | Responsible Party | Status |
| :--- | :--- | :--- | :---: | :---: |
| `PRQ-01` | **Formal Gate 2 Owner Ratification**: Explicit, recorded approval of Gate 2 Review Package by Project Owner Raushan vivek. | `GATE2_RATIFICATION_RECORD.md` (to be executed by Owner) | Project Owner | **PENDING OWNER REVIEW** |
| `PRQ-02` | **Host Driver Contract Ratification**: Adoption of `HOST_DRIVER_CONTRACT.md` requiring strict lock-step retirement ($N_{\text{outstanding}} \le 1$) and 64-bit `op_id` tracking. | `HOST_DRIVER_CONTRACT.md` | Software & Driver Team | **SPECIFIED_READY** |
| `PRQ-03` | **Closed-Loop Non-Regression Baseline**: Mandatory inclusion of `tb_golden_closed_loop_handshake.sv` in continuous integration regression. | `CLOSED_LOOP_GOLDEN_RESULTS.csv` (10000/10000 Pass) | Verification Team | **VERIFIED_PASS** |
| `PRQ-04` | **Pinout Stability & Interface Lockdown**: Confirmation that core top-level pinout (`completion_valid`, `completion_ready`) is frozen for macro integration. | `RTL_DIFF_SUMMARY.md` | Lead Microarchitect | **VERIFIED_PASS** |
| `PRQ-05` | **Zero Repository Tampering**: Pristine preservation of governing commit `09a1be3e85f008a5de2bf70d19e04481faf0b982` and historical audit directories. | `PRESERVATION_REPORT.md` | Verification Auditor | **VERIFIED_PASS** |

---

## 3. Future Improvements & Enhancements (Non-Blocking for Step 1 Closure)

The following items are recognized architectural enhancements that are deferred to Phase 2 Step 2 or subsequent project phases:

1. **Formal SVA Proof Sign-Off**:
   - *Current State*: All 9 SVA properties and 3 cover properties are fully specified in `REVISED_SVA_SPECIFICATION.md` but marked `NOT EXECUTED / NOT PROVEN` due to absence of formal model checkers.
   - *Step 2 Action*: Provision a formal property checking tool (e.g., SymbiYosys, JasperGold) to execute bounded and unbounded formal proofs.
2. **Multi-Slot Credit Architecture**:
   - *Current State*: Hardware enforces single-slot execution ($N_{\text{outstanding}} \le 1$).
   - *Step 2 Action*: Expand `slot_control_unit.sv` into a multi-slot allocator managing 16 parallel slot tracking credits.
3. **Transaction ID Expansion**:
   - *Current State*: Internal 8-bit generation tag wraps modulo 256; top-level core pins do not export transaction IDs.
   - *Step 2 Action*: When top-level bus wrappers (AXI/TileLink) are designed in Step 2, incorporate a 16-bit or 32-bit hardware transaction ID on the completion response channel.
4. **Hardware Abort Diagnostic Register**:
   - *Current State*: Aborted operations reset hardware to `ST_FREE` without persistent status flags; host software tracks abort via watchdog.
   - *Step 2 Action*: Implement an MMIO fault status register that latches the last abort cause (watchdog reset, sequence error, parity fault).

---

## 4. Governance & Authorization Rule

> [!IMPORTANT]
> **GOVERNANCE CONSTRAINT: No Automatic Step 2 Authorization**  
> The generation of this review package **does not constitute authorization to begin Phase 2 Step 2**.  
> Phase 2 Step 2 work must remain strictly paused until the Project Owner formally ratifies the Gate 2 decision record.  
> As of this document, **Phase 2 Step 2 has NOT started**.

