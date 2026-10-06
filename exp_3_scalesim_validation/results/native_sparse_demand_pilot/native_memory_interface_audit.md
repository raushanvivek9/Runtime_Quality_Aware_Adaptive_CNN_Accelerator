# Native Memory Interface Compatibility Audit

## Decision

PHASE_B1_BLOCKED

## Evidence from the code

The native SCALE-Sim WS files are built around dense matrices and folded service requests:

- `SCALE-Sim-v3-energy/scalesim/compute/operand_matrix.py` creates dense IFMAP/filter/OFMAP address matrices and keeps a fixed reduction dimension.
- `SCALE-Sim-v3-energy/scalesim/compute/systolic_compute_ws.py` generates `ifmap_demand_matrix`, `filter_demand_matrix`, and `ofmap_demand_matrix` as folded rectangular arrays with null padding.
- `SCALE-Sim-v3-energy/scalesim/memory/read_buffer.py` services reads from dense fetch matrices and active-buffer hit/miss logic.
- `SCALE-Sim-v3-energy/scalesim/memory/double_buffered_scratchpad_mem.py` is designed around per-buffer service of dense demand matrices and stall accounting from buffer misses.

The Phase-A sparse schedule is semantically valid as an event schedule, but it is not a native dense demand matrix and therefore cannot be fed to the existing memory service without inventing semantics.

## Compatibility answers

1. Can IFMAP sparse requests be represented without losing original_k?
   - Not in the native memory-service interface as written. The interface is dense-matrix based and does not preserve per-event original_k semantics.

2. Can FILTER requests preserve native reuse semantics?
   - Not without redefining the native filter reuse model; the current code assumes dense filter-demand folds.

3. Can OFMAP requests preserve native output coordinates?
   - Yes logically, but only as a sparse logical description, not as accepted dense demand matrices.

4. Can partial-sum traffic be represented?
   - Yes logically, but again not in the dense native service without reworking the contract.

5. Can request timing be passed to the native memory service?
   - No, because the service calculates timing from dense arrays and buffer demand generation, not from sparse MAC-event timing.

6. Does the native memory service require rectangular dense matrices?
   - Yes.

7. If yes, can sparse requests be represented without fabricating zero-work traffic?
   - No.

8. Can the existing prefetch structures represent the sparse demand?
   - No.

9. Would converting sparse events into the existing matrices introduce artificial requests?
   - Yes.

10. Would it introduce artificial stalls?
   - Yes.

## Conclusion

The sparse demand representation is valid as a provenance-preserving contract, but it is not currently consumable by the native SCALE-Sim memory interface without changing the native memory semantics or inventing dense traffic and stalls. Therefore, PHASE_B1_BLOCKED is the correct conclusion.
