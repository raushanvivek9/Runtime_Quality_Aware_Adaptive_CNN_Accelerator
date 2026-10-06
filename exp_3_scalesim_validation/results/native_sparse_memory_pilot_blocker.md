# Native Sparse Memory Pilot Blocker

## Status

`PHASE_B_BLOCKED`

The Phase-B memory-integration pilot is blocked. The compute-only sparse schedule is valid, but the native SCALE-Sim WS memory path cannot consume it without inventing a memory model that does not exist in the codebase.

## Hard stop condition

No Phase-B cycle, stall, bandwidth, or latency totals may be reported from this path until a native sparse demand representation exists and is validated end-to-end.

## Root cause

The native dense WS path in SCALE-Sim is driven by fixed operand matrices and array-fold demand generation:

- `scalesim/compute/operand_matrix.py` allocates dense IFMAP/filter/OFMAP matrices and keeps a regular reduction dimension `K`.
- `scalesim/compute/systolic_compute_ws.py` creates demand matrices by tiling the fixed matrix dimensions across the 2D PE array.
- `scalesim/memory/double_buffered_scratchpad_mem.py::service_memory_requests()` consumes those dense demand matrices and accumulates SRAM/DRAM service and stall timing.

The sparse activation-mask path for this pilot preserves per-output-position active-K information only in the Phase-A compute schedule, but that schedule is not part of the native memory service contract. There is no native representation of:

- per-output-position active `K` indices;
- variable-length reduction windows per output position;
- PE-local skip semantics for masked MACs while keeping the original reduction index provenance;
- a valid conversion from sparse MAC events into `ifmap_demand_mat`, `filter_demand_mat`, and `ofmap_demand_mat` without fabricating traffic.

## Why this is a scientific blocker

The phase-A schedule is valid as a compute schedule, but it is not equivalent to the native SCALE-Sim memory interface. Converting it to native memory requests would require assumptions the project has explicitly rejected:

- using `ceil(useful_macs / PE)` as a latent cycle count;
- replacing sparse work with dense demand matrices without preserving original `K` provenance;
- inferring traffic from zero values or from a mask bit alone;
- merging analytical sparse-cycle totals with native dense memory service timing.

That would produce fabricated memory traffic and false stall cycles, which violates the audit requirement.

## Exact boundary of the blocker

The valid Phase-A object is a sparse compute-event stream with fields such as:

- output position;
- `original_k`;
- output channel;
- PE row/column;
- issue/completion cycle.

The native memory service expects aligned demand matrices and prefetch matrices, not event streams with per-position reduction provenance. Without an explicit adapter contract, the sparse event stream cannot be mapped into the native demand path without inventing semantics.

## Required next implementation before any Phase-B totals

A valid correct extension must first define and verify:

1. a native sparse WS issue/retire policy that preserves original reduction indices;
2. a native sparse demand-generation contract for IFMAP/filter/OFMAP requests;
3. the exact memory-traffic policy for masked activations, filter reuse, and partial-sum writes;
4. a proof that the generated demands are still consistent with the native scratchpad service and not guessed.

Only after this contract exists can a one-image pilot be run with the approved workload and frozen PE configuration.

## In scope and frozen constraints

This blocker record intentionally does not modify any frozen Stage-13 or Stage-13.1 evidence.

Approved scope remains:

- workload: `resnet18_cifar10`
- layer: `layer1.0.conv1`
- input: first CIFAR10 test image
- mask rows: first 1024 validated rows
- array: `4x8`
- PE: `32`

No full-layer or full-66-layer sparse comparisons are authorized from this path.

## Conclusion

The current codebase does not support a native sparse memory-service integration for the WS activation-mask pilot without fabricating memory semantics. Therefore, the Phase-B pilot is blocked and must stop here.
