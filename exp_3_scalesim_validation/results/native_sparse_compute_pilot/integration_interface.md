# Proposed Phase-B Interface for SparseComputeSchedule

Phase A exposes a compute schedule only. It does not choose or synthesize any memory requests. Phase B may consume this interface only after its memory policy is explicitly specified and reviewed.

## Schedule object

The Phase-A module exposes an immutable `SparseComputeSchedule` containing:

- `array_rows`, `array_cols`, `dataflow`, `output_positions`, `reduction_size`, and `output_channels`;
- `dense_macs`, `useful_macs`, `skipped_macs`, and compute-only `cycles`;
- an ordered tile iterator keyed by `(output_position, output_channel_fold)`;
- `iter_events()`, yielding one `SparseMacEvent` per issued MAC;
- per-tile partial-sum row membership and `output_retire_cycle`.

Each `SparseMacEvent` has:

- `output_position`;
- `original_k` (never compacted);
- `output_channel`;
- `pe_row`, `pe_col`;
- `issue_cycle`, `completion_cycle`.

The Phase-A executor uses this same event stream to update the row-local partial sums, so numerical execution and the exposed timing representation share one schedule source.

## Candidate adapter boundary

A future adapter can map event coordinates into native convolution coordinates using the same topology/operand address mapping as `operand_matrix`:

- IFMAP coordinate: `(output_position, original_k)`;
- filter coordinate: `(original_k, output_channel)`;
- OFMAP/partial-sum coordinate: `(output_position, output_channel)`.

Events retain enough provenance to preserve original reduction indices, channel folds, and issue/completion ordering while building candidate requests. Tile retirement identifies when output values are complete.

## Phase-B decisions still required

The interface intentionally does not state whether a MAC event implies a memory request. In particular, it does not imply that zero activations eliminate IFMAP traffic, nor that filters are read once or only for active positions. Phase B must specify mask storage/lookup, IFMAP and filter reuse, partial-sum SRAM reads/writes, OFMAP writes, prefetch timing, and request-to-cycle semantics. Only then can it adapt events into demand/prefetch matrices and pass those matrices into the native scratchpad service.

No Phase-A `cycles` value may be relabeled as native memory-aware SCALE-Sim total cycles. Native stall and traffic fields remain unavailable until Phase B is implemented and validated.
