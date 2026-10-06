# Native Activation-Sparse Pilot Design (Blocked)

## Status

Design-only. The native sparse pilot is blocked before implementation or simulation because the current SCALE-Sim compute interface has no activation-dependent per-MAC schedule that can be passed through to its native memory-demand and cycle machinery without defining new architectural semantics.

No pilot runs were launched. This file does not change frozen evidence, masks, or existing experiment outputs.

## Pilot scope and frozen inputs

- Workload/layer: ResNet18/CIFAR10 `layer1.0.conv1`.
- Validated mask: `masks/resnet18_cifar10/layer_01.npy`, binary shape `(10240000, 576)`.
- One image: first 1,024 rows, corresponding to 32 x 32 output positions; the slice was read-only checked as binary.
- Output channels: 64.
- Frozen adaptive PE: 32, confirmed against the Stage 13.1 single-pass audit.
- Existing dense and analytical sparse rows are both successful and must remain unchanged.

## A. Exact sparse compute policy

For image output position `t`, reduction index `k`, and output channel `n`:

- If mask[`t`,`k`] is exactly zero, suppress the corresponding multiply-accumulate for every output channel `n`.
- Otherwise execute that MAC.
- No thresholding, weight pruning, or approximate zero detection is introduced.
- Useful MACs for the image are `active_mask_entries * 64`; skipped MACs are `dense_MACs - useful_MACs`.

This specifies arithmetic semantics only. It does not specify a valid systolic issue schedule.

## B. PE scheduling constraints

The dense WS mapping uses reduction dimension K across array rows and output channels across array columns, with output positions tiled over time. The pilot must retain the frozen 4 x 8 array for 32 PEs and the native WS dataflow/output-channel mapping.

The mask has a different active reduction set for each output position. A native sparse scheduler must preserve original reduction indices so each surviving activation is paired with its corresponding weight. It must also define how variable-length reductions map to the 4 x 8 systolic array, how partial sums are accumulated, and when each output is retired. A scalar `ceil(useful_MACs / 32)` schedule or a per-row count without native array timing is not an acceptable cycle model.

No such policy is implemented by the current native compute classes. Therefore a PE issue schedule cannot be selected here without a new architecture contract and validation.

## C. Memory policy requirements

The current native path derives IFMAP, filter, and OFMAP demand matrices from dense operand matrices. The mask-aware path must explicitly define:

- IFMAP reads and prefetch: whether values are still fetched densely to obtain/confirm zeros, or whether a mask/zero metadata mechanism suppresses requests.
- Filter reads and reuse: whether weights for skipped MACs are fetched, and how reuse across output positions is retained when active K sets differ.
- OFMAP reads/writes: how partial sums are read/updated and final outputs are written when individual MACs are omitted.
- Mask/metadata transport and its storage/access cost.
- How the resulting demand timing is delivered to the existing native double-buffered SRAM and DRAM service.

No IFMAP, filter, or DRAM traffic reduction is assumed. Simply possessing an activation mask does not establish that zero activation eliminates accelerator memory traffic. The required memory policy cannot be derived from the current APIs without first defining the sparse issue/operand-reuse semantics.

## D. Dataset aggregation

The native topology represents one image; the frozen mask contains 10,000 images. For a valid pilot, use only the first image's 1,024 mask rows and compare with the existing one-image dense `COMPUTE_REPORT.csv` result. Do not pass the full 10,240,000-row mask to a one-image topology, and do not multiply an arbitrary one-image sparse cycle count by 10,000. Dataset-level aggregation requires a later explicit policy and validation across image-specific masks.

## Native path contract to preserve

The dense path must remain unchanged. A future native sparse extension must create mask-aware compute timing/demand at the compute/dataflow boundary, preserve the WS array and output mapping, pass IFMAP/filter/OFMAP requests through `double_buffered_scratchpad.service_memory_requests()`, and use the native prefetch, bandwidth, stall, and report mechanisms. The existing analytical `-a` path remains separate for scheduler validation.

## Stop decision

The present source has no native per-MAC activation-mask hook or representation for row-varying reduction schedules. Implementing one requires new compute/systolic schedule semantics plus coupled operand-demand and output-accumulation changes. Per the task's stop condition, no pilot implementation or numerical output is produced until those semantics are specified and tested against dense numerical outputs.
