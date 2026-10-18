# Host Driver and Completion Consumer Contract

**Project**: `Neural_Acc`  
**Subsystem**: Host Interface & Hardware Accelerator Core Top  
**Governing Baseline Commit**: `09a1be3e85f008a5de2bf70d19e04481faf0b982` on branch `main`  
**Classification**: Normative Specification for Host Driver & Runtime Software  
**Status**: `RATIFIED_CONTRACT_SPECIFICATION`  
**Date**: 2026-10-18  

---

## 1. Single-Outstanding-Operation Requirement ($N_{\text{outstanding}} \le 1$)

### 1.1 Hardware Serialization Boundary
The Phase 2 Step 1 accelerator core hardware implements a **single physical execution slot** (`SLOT_ID = 0`). The slot controller strictly enforces sequential execution through the 7-state lifecycle:
$$\text{ST\_FREE} \to \text{ST\_ALLOCATED} \to \text{ST\_COMPUTING} \to \text{ST\_DRAINING} \to \text{ST\_HANDSHAKE} \to \text{ST\_QUIESCENT} \to \text{ST\_RELEASE} \to \text{ST\_FREE}$$

- **Core Rule**: `slot_alloc_ready` is asserted **if and only if** `state_q == ST_FREE`.
- **Driver Constraint**: The host driver **must not** issue a new slot allocation request (`slot_alloc_req = 1`) until `slot_alloc_ready == 1`. Any allocation attempt asserted while the core is outside `ST_FREE` is strictly ignored by hardware.
- **Lock-Step Execution**: At any given moment, there is **at most one active transaction in hardware** ($N_{\text{outstanding}} \le 1$).

---

## 2. Completion Acceptance and Correlation Protocol

### 2.1 Interface Signal Definitions
The top-level hardware interface (`accelerator_core_top`) exposes the following completion lines:

| Signal | Direction | Width | Protocol Semantics |
| :--- | :---: | :---: | :--- |
| `completion_valid` | Output | 1 | Asserted by hardware upon entering `ST_HANDSHAKE`. Indicates reduction is complete, drain FIFO is empty, and outputs are valid and stable. |
| `completion_ready` | Input | 1 | Asserted by host consumer to acknowledge and accept completion. Default input value is `1'b1`. |
| `accum_result` | Output | 40 | Signed 40-bit accumulator result. |
| `sticky_saturation`| Output | 1 | Latching saturation flag (1 if numerical overflow clamped to $[-2^{39}, 2^{39}-1]$). |
| `k_resolved` | Output | 16 | Number of reduction flits processed (equals `slot_k_total`). |
| `sticky_seq_error` | Output | 1 | Sequence violation flag (1 if an out-of-order or duplicate flit arrived). |

### 2.2 Atomic Handshake Transfer
- **Acceptance Condition**: Completion acceptance occurs **strictly on the rising clock edge (`posedge clk`) where `completion_valid == 1` and `completion_ready == 1` simultaneously**.
- **Hardware Reaction**: On the cycle immediately following acceptance, the hardware FSM transitions to `ST_QUIESCENT`, and `completion_valid` drops to `0`.
- **Single-Cycle Validity**: `completion_valid` asserts for exactly one continuous duration until accepted. Once accepted, it deasserts and cannot re-assert until a new transaction completes computation.
- **Sampling Window**: The host consumer must sample `accum_result` and status flags synchronously with or immediately upon the acceptance edge. Once the slot transitions past `ST_RELEASE`, accumulator contents are subject to clearing upon subsequent allocation.

---

## 3. Limits of the 8-Bit Hardware Generation Tag

### 3.1 Hardware Tag Lifecycle
- `active_gen_tag` is maintained by an 8-bit internal register (`gen_tag_q[7:0]`) in `slot_control_unit.sv`.
- The tag increments strictly by $+1 \pmod{256}$ upon each new allocation from `ST_FREE`.
- After 256 transactions, the tag wraps from `8'hFF` back to `8'h00`.

### 3.2 Inability of Hardware to Detect Stale Completions
Because the top-level core pinout adheres to the frozen pinout boundary (Owner Decision Choice B) and does **not** expose a dedicated transaction ID pin:
1. **Unconditional Acceptance**: If the host consumer delays and asserts `completion_ready = 1` for an old transaction after the hardware has already retired it and allocated a new transaction 256 cycles later, **the hardware will accept the transfer unconditionally**.
2. **Data Overwrite**: The data transferred will belong to the *new* transaction, not the *old* transaction.
3. **Hardware Non-Enforceability**: The hardware interface alone **cannot detect or reject a stale completion attempt by a desynchronized host consumer**.

### 3.3 Mandatory Driver-Level Correlation Guarantee
To maintain system integrity:
1. **Host-Side 64-Bit Sequence ID**: Host software **must maintain an internal 64-bit monotonically increasing transaction counter (`uint64_t op_id`)**.
2. **Synchronous Retirement**: The driver must correlate each completion with the in-flight `op_id` before retiring the software transaction descriptor.
3. **No Speculative Re-use**: The host driver must not dispatch transaction $N+1$ until transaction $N$ has been fully acknowledged (`completion_valid && completion_ready`) and the core has asserted `slot_alloc_ready == 1`.

---

## 4. Timeout, Reset, and Abort Recovery

### 4.1 Downstream Backpressure Handling
- Hardware contains **no autonomous cycle timer or auto-clearing watchdog**.
- If the host consumer deasserts `completion_ready = 0` (e.g. queue full, bus stall), the core **freezes in `ST_HANDSHAKE` indefinitely**.
- While frozen, all metadata (`accum_result`, status flags) remain 100% stable and invariant.
- Pipeline barriers (`layer_barrier_req`) will wait indefinitely (`slot_quiescent == 0`).

### 4.2 Software Watchdog Requirement
- The host driver must maintain a software watchdog timer for every dispatched transaction.
- Recommended timeout threshold: $\tau_{\text{watchdog}} = \max(5000\,\text{cycles}, 2 \times T_{\text{expected\_layer}})$.
- If the watchdog expires before `completion_valid && completion_ready` occurs, the host driver **must initiate an abort sequence**.

### 4.3 Asynchronous Reset Abort Sequence
To abort a stalled or hung transaction:
1. Host asserts asynchronous reset: `!rst_n = 0`.
2. Hold reset for at least 2 clock cycles ($20\,\text{ns}$ at $100\,\text{MHz}$).
3. Deassert reset: `!rst_n = 1`.
4. Wait for `slot_alloc_ready == 1` (occurs combinationally upon reset deassertion).

### 4.4 Strict Prohibition: Never Report Aborted Operations as Successful
> [!CAUTION]
> **PROHIBITION ON FALSE REPORTING**:  
> Upon reset assertion, the hardware clears `completion_valid` to `0` and zeroes `accum_result`. Zero completion handshakes are registered.  
> **Host driver software is strictly prohibited from:**
> 1. Synthesizing a completion event for an aborted transaction.
> 2. Returning the zeroed accumulator or partial datapath contents to the application.
> 3. Reporting `SUCCESS` or `COMPLETED` status to higher software layers.
> 
> **Mandatory Action**: The driver must transition the in-flight transaction descriptor to `STATUS_ABORTED_BY_WATCHDOG_RESET` and return an explicit error code (e.g., `-ETIMEDOUT` or `EIO`) to the calling framework.

---

## 5. Summary of System Responsibilities

| Responsibility | Hardware Core Top | Host Driver / Consumer Software |
| :--- | :---: | :---: |
| Single-slot execution enforcement | **ENFORCED** (`alloc_ready == 0` when busy) | **COMPLIANT** (issues alloc only when ready=1) |
| Exactly-once completion transfer | **ENFORCED** (1-cycle transfer at posedge clk) | **COMPLIANT** (pulses/holds ready as required) |
| Metadata stability during backpressure | **ENFORCED** (100% frozen in `ST_HANDSHAKE`) | **RELIANT** (may stall ready without data loss) |
| Layer barrier gating | **ENFORCED** (`quiescent=0` until accepted) | **RELIANT** (waits for barrier clearance) |
| Timeout detection & recovery | **NOT IMPLEMENTED** (hardware stalls indefinitely) | **MANDATORY** (software watchdog + `!rst_n`) |
| Modulo-256 tag wraparound protection | **PARTIAL** (8-bit hardware tag increments) | **MANDATORY** (64-bit software `op_id` tracking) |
| Abort vs idle state discrimination | **NOT IMPLEMENTED** (hardware resets to `ST_FREE`) | **MANDATORY** (software tracks transaction disposition) |

