# Native Sparse Pilot Blocker

## Status

`NATIVE_SPARSE_PILOT_BLOCKED`

The pilot was not implemented or run. Producing native sparse cycles, stalls, utilization, bandwidth, or memory traffic from the current activation-mask path would be invalid. No source files, masks, frozen Stage 13.1 artifacts, or existing 132-run results were changed.

## Exact code locations

- `SCALE-Sim-v3-energy/scalesim/scale.py`: `-a` currently dispatches to the analytical activation-mask entry point; there is no distinct native activation-sparse option.
- `SCALE-Sim-v3-energy/scalesim/scale_sim.py`: `scalesim.run_activation_sparse()` loads the NumPy mask and calls `simulator.run_activation_sparse()`.
- `SCALE-Sim-v3-energy/scalesim/simulator.py`: `simulator.run_activation_sparse()` obtains only output-channel count and PE count, invokes `scalesim.activation_sparse.schedule_activation_mask()`, and writes `ACTIVATION_SPARSE_REPORT.csv`. It does not call `simulator.run()`, `single_layer_sim.run()`, or `generate_reports()`.
- `SCALE-Sim-v3-energy/scalesim/activation_sparse.py`: the scheduler reduces the mask to per-row nonzero counts, distributes aggregate PE work, and directly computes `ceil(useful_macs / PE_count)`.
- `SCALE-Sim-v3-energy/scalesim/single_layer_sim.py`: native compute builds dense operand matrices, derives prefetch and demand matrices through the selected dataflow engine, then sends those demands to the memory system.
- `SCALE-Sim-v3-energy/scalesim/compute/operand_matrix.py`: operands are regular matrices with a shared K reduction dimension. No activation-mask/per-MAC scheduling representation is present.
- `SCALE-Sim-v3-energy/scalesim/compute/systolic_compute_ws.py`: WS demand generation tiles fixed matrix dimensions into array-row/array-column folds and generates regular skew/pipeline demand matrices. It has no per-output-position active-K schedule.
- `SCALE-Sim-v3-energy/scalesim/memory/double_buffered_scratchpad_mem.py::service_memory_requests()`: consumes aligned IFMAP, filter, and OFMAP demand matrices and accumulates service stalls. It does not receive activation masks or MAC-enable events.

## Architectural limitation

The native WS path maps K reduction rows and output-channel columns onto a systolic array. The validated mask varies over both output position and K. For each output position, zero entries suppress the matching MACs across all output channels, but the surviving K indices and reduction lengths vary by position. Native demand generation assumes fixed, tiled matrix dimensions; it has no mechanism to carry original K indices for irregular compaction, suppress individual PE MACs, schedule variable-length reductions, or update/retire partial sums under that schedule.

The per-image mask issue is separately manageable: the validated mask has 10,240,000 rows for 10,000 images, while the native topology represents one image. A read-only check confirmed the first image is a binary 1,024 x 576 slice. That slice alone does not solve the native schedule limitation.

## Why simple fixes are insufficient

- Filtering IFMAP addresses changes read traffic, but the current systolic compute schedule is still derived from fixed folds and does not know which per-position MACs were suppressed. This can misalign IFMAP, filter, and OFMAP timing and cannot establish skipped-MAC cycle savings.
- Replacing zero activations with zero-valued operands does not skip MACs. The fixed native schedule still issues the corresponding multiply-accumulate slots and generates regular compute demands.
- Removing K entries globally is incorrect because active K indices differ by output position; it would pair activations with incorrect weights or discard valid work.
- Reporting `ceil(useful_macs / PE)` bypasses native array mapping, buffering, prefetch, bandwidth, and stall accounting, and is precisely the analytical scheduler result that the audit rejected.
- Reusing dense memory demands with a separate analytical sparse cycle number would combine two different timelines, not a coupled native sparse execution.

## Interfaces that must change

A correct extension needs, at minimum:

1. A native compute API accepting a per-image binary `[M, K]` activation mask and preserving each active element's original reduction index.
2. A WS systolic sparse scheduler that models per-position active MAC enables, mapping to the frozen array geometry, output-channel lanes, partial-sum accumulation, array fill/drain, and completion timing.
3. Coupled IFMAP/filter/OFMAP demand and prefetch generation from that schedule, with an explicit documented policy for whether zero values, weights, or mask metadata still generate memory requests. No memory-traffic elimination may be inferred from a zero mask bit alone.
4. An adapter from sparse compute demand timing to the existing `double_buffered_scratchpad.service_memory_requests()` inputs, preserving shared SRAM/DRAM service and native stall accounting.
5. Native sparse report generation using the native cycle/stall/utilization/mapping fields plus MAC counts, mask path, and a provenance field proving cycle source is the native memory-aware simulator.
6. A numerical regression that compares native dense and sparse outputs on a small irregular mask and on the one-image pilot input before interpreting cycles.

## Minimum next implementation step

Specify and review the irregular WS issue/partial-sum policy and conservative memory-traffic semantics first. Then implement the compute-schedule and demand-generation interface jointly, route those demands through the existing scratchpad service, and prove numerical equivalence on a tiny irregular case. Only after that may the one-image `resnet18_cifar10/layer1.0.conv1` pilot run be attempted using the first 1,024 rows of the existing validated mask and frozen PE=32. Existing dense results can be reused; no masks or PE allocations need regeneration.

## Verification performed

- Read-only source trace covered the CLI, wrapper, simulator, operand matrices, WS dataflow, single-layer orchestration, and double-buffered memory service.
- The first 1,024 activation-mask rows were checked as binary with shape `(1024, 576)`; mask file was opened read-only with memory mapping.
- The final results row and frozen Stage 13.1 audit both report selected PE=32 for the pilot layer, with dense and analytical sparse statuses `SUCCESS`.
- No SCALE-Sim process was launched for this task.
