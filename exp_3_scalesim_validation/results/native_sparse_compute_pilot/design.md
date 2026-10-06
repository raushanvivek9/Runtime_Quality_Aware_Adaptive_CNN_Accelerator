# Phase-A Native WS Sparse Compute Pilot Design

## Scope and status

This is a compute-only WS schedule prototype. It does not enter SCALE-Sim's CLI, `run_scale()`, memory system, or report generation. Dense SCALE-Sim behavior and the analytical `activation_sparse.py` scheduler remain untouched. No mask, frozen allocation, Stage 13.1 artifact, or existing final result is rewritten.

Pilot target: ResNet18/CIFAR10 `layer1.0.conv1`, one image, frozen 4 x 8 array, frozen PE=32. The existing mask is 10,240,000 x 576 for the full test set; this pilot uses only rows 0:1024 for the first 32 x 32 image. The one-image mask slice is required to match the captured layer input exactly under `activation != 0`.

## Exact-zero compute semantics

For output position `t`, original reduction index `k`, and output channel `n`, issue exactly one MAC when `mask[t,k] == 1`; issue no MAC when `mask[t,k] == 0`. This is exact equality to zero, with no thresholding and no weight pruning. The weight lookup always uses the original `k`; K is never globally compacted or renumbered.

`dense_macs = M * K * N`; `useful_macs = active_mask_entries * N`; `skipped_macs = dense_macs - useful_macs`. The scheduler checks both conservation identities before returning.

## WS mapping and issue schedule

- Reduction index `k` maps to WS array row `k % 4`; its fold identity remains `k // 4` and its original weight address remains `k`.
- Output channel `n` maps to column `n % 8`; the output-channel fold is `n // 8`.
- Output positions are visited in row-major order. Output-channel folds are visited in ascending order for each position.
- For each position and output-channel fold, active K indices are grouped by their physical row and kept ascending within that row. Wave `w` issues the `w`-th active K from each row concurrently. Thus a wave contains at most four K indices, with no two operations assigned to the same PE row; each selected K issues across the eight output-channel columns.
- A missing K entry creates no MAC event and consumes no issue wave. Later events retain their original K and corresponding weight address. Different positions may therefore have different K schedules.
- The explicit `SparseMacEvent` contains output position, original K, output channel, PE row, PE column, issue cycle, and completion cycle.

This is a new compute-only schedule model aligned to the native WS row/column mapping; it is not a claim that the existing native SCALE-Sim compute or memory path executed these events.

## Partial sums, pipeline fill/drain, and cycle accounting

At the beginning of each `(output_position, output_channel_fold)` tile, four row-local partial-sum vectors are initialized to zero. Each issued event completes one cycle after issue and adds `activation[t,k] * weight[k,n]` to the accumulator for its physical PE row and output channel. Skipped K entries cause no event, no accumulator update, and no issue-wave delay.

After the final wave completes, the four row-local partial sums are combined through a fixed balanced 4-to-1 reduction tree taking two cycles. Outputs retire after that tree. A three-cycle array fill is charged before the first wave and a three-cycle drain after retirement for every serialized tile. Empty tiles still retire zero-valued outputs with fill/reduction/drain timing, but emit no MAC events. Tiles do not overlap in Phase A.

The reported `sparse_compute_cycles` is the elapsed schedule from cycle 0 through the last tile's drain. It is computed by accumulating per-tile fill + wave issue + reduction + drain durations. It is not `ceil(useful_macs / 32)` and does not model memory stalls, prefetch, bandwidth, or SCALE-Sim total cycles. `ceil(useful_macs / 32)` is emitted only as `analytical_lower_bound` for debugging.

## Numerical validation

Dense reference output is computed from the identical unfolded input and weight matrix (`A @ W`, independently checked against PyTorch `conv2d`). Sparse execution follows the explicit scheduled MAC events, accumulates row-local partial sums, and reduces them. Numerical comparison uses documented float tolerances because the reduction association differs from dense accumulation. Synthetic validation must use irregular, different active-K sets per position and verify original-K identities, PE bounds, channel mapping, MAC counts, and output equivalence before the real-image validation runs.

## Memory boundary

Phase A has no memory policy and emits no IFMAP/filter/OFMAP requests. It makes no claims about SRAM/DRAM traffic, stalls, utilization, bandwidth, prefetch, energy, or native sparse total cycles. Phase B must define memory request and mask-metadata semantics before consuming this schedule.
