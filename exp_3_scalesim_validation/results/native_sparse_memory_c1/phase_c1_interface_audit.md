# Phase C.1 Native Sparse Memory Interface Audit

## Decision

PHASE_C1_BLOCKED

## Exact interface boundary

The valid sparse event stream is preserved as a logical sparse request stream, but the actual native SCALE-Sim memory service still requires dense 2D demand matrices. The concrete gate is:

- `scalesim/memory/read_buffer.py::set_fetch_matrix()` and `service_reads()` operate on dense fetch arrays.
- `scalesim/memory/double_buffered_scratchpad_mem.py::service_memory_requests()` accepts `ifmap_demand_mat`, `filter_demand_mat`, and `ofmap_demand_mat` created by the dense compute flow.
- `scalesim/single_layer_sim.py` calls `compute_system.get_demand_matrices()` and only then services the memory arrays.

There is no supported native sparse receive path for per-output-position active-K memory requests.

## Scientific interpretation

The Phase-A sparse schedule is valid as a compute schedule and preserves output position, original K, output channel, PE location, and issue/completion timing. However, that schedule is not a native dense demand matrix and cannot be admitted to the native memory service without fabricating dense traffic or synthetic stalls. The prototype therefore stops at the interface boundary and reports a blocker result instead of a fake performance number.

## Result

PHASE_C1_BLOCKED
