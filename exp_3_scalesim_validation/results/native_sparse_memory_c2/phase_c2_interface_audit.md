# Phase C.2 Native Sparse Memory-Service Extension

## Decision

PHASE_C2_BLOCKED

## Exact interface boundary

The sparse Phase-A schedule is valid and preserves output position, original K, output channel, PE identity, and issue timing. However, the native SCALE-Sim memory stack still accepts only dense demand matrices:

- `scalesim/memory/double_buffered_scratchpad_mem.py::service_memory_requests(ifmap_demand_mat, filter_demand_mat, ofmap_demand_mat)`
- `scalesim/memory/read_buffer.py::set_fetch_matrix()` and `service_reads()`

There is no native sparse request API that can admit a per-output-position active-K memory stream without fabricating a dense matrix or synthetic stall model.

## Scientific conclusion

This Phase C.2 extension therefore stops at the true interface boundary instead of manufacturing traffic, stalls, or timing. The blocker is structural rather than numerical.

PHASE_C2_BLOCKED
