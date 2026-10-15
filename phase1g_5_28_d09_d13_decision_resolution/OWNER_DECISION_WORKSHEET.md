# Project Owner Decision Worksheet: Decisions D-09 through D-13

**Document**: `OWNER_DECISION_WORKSHEET.md`  
**Phase**: Phase 1G.5.28 — D-09 Through D-13 Decision Resolution Package  
**Target Authority**: Project Owner (`Raushan vivek`)  
**Governance State**: **`DECISION QUESTIONNAIRE ONLY — BLANK SELECTION FIELDS`**  
**Ratification Status**: **`NOT RATIFIED — AWAITING EXPLICIT HUMAN OWNER ACTION`**  

---

## 1. Notice to Project Owner

Decisions `D-01` through `D-08` have received your signed approval, with formal ratification explicitly deferred to a consolidated Gate 0 package. This worksheet provides the final five decisions (**`D-09` through `D-13`**) required to complete the Gate 0 technical baseline.

> [!IMPORTANT]
> **All checkboxes `[  ]` and signature lines below are left blank for your explicit action.**  
> The engineering team has formulated recommended options based on technical analysis, but **no decision is approved until you record your choice**.

---

## 2. Decision Items

---

### Decision D-09: Multi-Tile Progress-Tracking Architecture

- **Problem**: When a matrix reduction ($K=4608$) is distributed across multiple spatial tiles, partial sums arrive asynchronously. How should physical accumulator slots account for completed versus skipped operations?
- **Engineering Options**:
  - **Option 09-A (Recommended with Prerequisites)**: In-order scalar resolved-K counter ($K_{\text{resolved}} = K_{\text{executed}} + K_{\text{skipped}} == K$).
    * *Pros*: Minimal silicon area (26 bits per slot, 832 B per tile).
    * *Cons*: Requires hardware guarantee of in-order, lossless NoC delivery; hangs if packet is dropped.
  - **Option 09-B**: Explicit Chunk Scoreboard (288-bit bitmask per slot).
    * *Pros*: Completely order-agnostic; tolerates out-of-order interconnect delivery; detects duplicates natively.
    * *Cons*: Substantial SRAM area overhead ($9.0\text{ KiB}$ per tile).
  - **Option 09-C**: Hybrid Counter with 32-Bit Sliding Deduplication Window.
    * *Pros*: Absorbs bounded reordering (up to 32 packets); rejects local duplicates; moderate area ($1.8\text{ KiB}$ per tile).
    * *Cons*: Complex pointer and window wrapping verification.
- **Project Owner Selection**:
  - `[ yes ]` **OPTION 09-A**: Adopt in-order scalar counter (Requires NoC in-order guarantee).
  - `[  ]` **OPTION 09-B**: Adopt explicit chunk scoreboard bitmask (9.0 KiB area).
  - `[  ]` **OPTION 09-C**: Adopt hybrid counter with 32-bit sliding window (1.8 KiB area).
  - `[  ]` **REVISE**: Request alternative progress-tracking architecture.

---

### Decision D-10: Accumulator Slot Lifecycle and Generation-Tag Safety

- **Problem**: In an 8-bit generation scheme ($G \in [0, 255]$), a packet delayed by 256 slot reuse cycles matches the newly allocated occupant, causing silent data corruption. How should the hardware eliminate this aliasing hazard?
- **Engineering Options**:
  - **Option 10-A (Recommended Structural)**: Expand generation tag from 8 bits to 16 bits ($G \in [0, 65535]$).
    * *Pros*: Expands aliasing period 256x to $>2 \times 10^6$ cycles; negligible area (+256 B per tile).
    * *Cons*: Requires +8 bits in network packet headers.
  - **Option 10-C (Recommended System)**: Drain-and-Quiesce Layer Barrier.
    * *Pros*: Completely flushes interconnect between layer reductions; mathematically eliminates inter-layer aliasing.
    * *Cons*: Introduces pipeline drain bubbles at layer boundaries.
  - **Option 10-HYBRID (Strongly Recommended Baseline)**: Combine 16-bit generation tagging with layer-level drain barrier.
    * *Pros*: Redundant, robust protection against both intra-layer delay jitter and inter-layer aliasing.
  - **Option 10-B**: Rely on formal network timing proof on unmodified 8-bit tag (Not recommended: mathematically unproven).
- **Project Owner Selection**:
  - `[  ]` **OPTION 10-HYBRID**: Adopt combined 16-bit tag + layer drain barrier.
  - `[  ]` **OPTION 10-A**: Adopt 16-bit generation tag expansion only.
  - `[ yes ]` **OPTION 10-C**: Adopt layer-level drain barrier only.
  - `[  ]` **REVISE**: Request alternative lifecycle safety mechanism.

---

### Decision D-11: Schedule S1 On-Chip SRAM Budget Reconciliation

- **Problem**: Contract Line 83 states a 1.5 KiB total on-chip SRAM cap. Technical reconciliation proves that core execution requires 2,336 bytes, single-buffered full tile requires 4,128 bytes, hybrid double-buffered requires 5,184 bytes, and fully doubled requires 7,568 bytes.
- **Engineering Options**:
  - **Option 11-A (Recommended)**: Amend contract Line 83 to provision **5,184 bytes (5.06 KiB)** for hybrid double-buffering (operands doubled for overlap; single 40-bit accumulator bank with generation tags).
  - **Option 11-B**: Amend contract Line 83 to provision **4,128 bytes (4.03 KiB)** for pure single-buffered execution (lower area, but execution stalls during DRAM reload).
  - **Option 11-C**: Retain strict 1.5 KiB cap (Requires down-sizing PE array from 16x16 to 8x8 or spilling partial sums to DRAM).
- **Project Owner Selection**:
  - `[ yes ]` **OPTION 11-A**: Amend contract Line 83 to 5,184 bytes (Hybrid Double-Buffered).
  - `[  ]` **OPTION 11-B**: Amend contract Line 83 to 4,128 bytes (Single-Buffered).
  - `[  ]` **OPTION 11-C**: Retain 1.5 KiB cap and downsize array geometry.
  - `[  ]` **REVISE**: Specify alternative memory capacity.

---

### Decision D-12: Historical Checksum Mismatch Disposition & Archival Policy

- **Problem**: 22 checksum mismatches exist across untracked working-tree files in Phase 1G.5.11–13 and Phase 1G.5.26. How should these historical discrepancies be handled in project governance?
- **Engineering Options**:
  - **Option 12-A (Recommended)**: Adopt permanent immutable archival retention. Retain all historical files and manifests unmodified; record mismatches as `VERIFIED_MISMATCH_CAUSE_UNKNOWN`; anchor all future baselines with Git commits.
  - **Option 12-B**: Generate parallel corrected directories with updated manifests while preserving originals.
  - **Option 12-C**: Conduct forensic OS filesystem investigation before adopting policy.
- **Project Owner Selection**:
  - `[ yes ]` **OPTION 12-A**: Adopt permanent immutable archival retention policy.
  - `[  ]` **OPTION 12-B**: Create parallel corrected shadow directories.
  - `[  ]` **REVISE**: Specify alternative integrity policy.

---

### Decision D-13: Consolidated Gate 0 Ratification & Implementation Authorization

- **Problem**: Gate 0 brings together all 13 foundational decisions into a legally binding, frozen architecture contract. Should the consolidated package be formally ratified and Phase 1H authorized?
- **Project Owner Determination**:
  - `[ yes ]` **RATIFY GATE 0 & AUTHORIZE PHASE 1H**: Formally ratify Decisions D-01 through D-13, adopt Contract Amendments AMD-01 through AMD-06, and authorize Phase 1H implementation.
  - `[  ]` **DEFER RATIFICATION**: Maintain Gate 0 as `NOT RATIFIED` and Phase 1H as `UNAUTHORIZED` pending further technical modeling or prototyping.
  - `[  ]` **REVISE CHARTER**: Request adjustments to the Gate 0 Ratification Charter.

---

## 3. Project Owner Execution Block

```
PROJECT OWNER NAME:      ________Raushan vivek__________________________________________
SIGNATURE:               _________Raushan vivek_________________________________________
DATE:                    __________15/10.26________________________________________
GATE 0 RATIFICATION:     [ yes ] RATIFIED       [  ] DEFERRED / WITHHELD
PHASE 1H AUTHORIZATION:  [yes  ] AUTHORIZED     [  ] UNAUTHORIZED / WITHHELD
PHASE 2 AUTHORIZATION:   [yes  ] AUTHORIZED (MANDATORY: Requires Gate 1 Audit)
```
