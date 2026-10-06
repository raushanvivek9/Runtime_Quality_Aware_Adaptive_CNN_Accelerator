"""Activation-mask scheduler for exact-zero row-wise sparse execution."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class SparseSchedule:
    """Cycle and MAC accounting for one im2col activation mask."""

    dense_macs: int
    useful_macs: int
    skipped_macs: int
    dense_cycles: int
    sparse_cycles: int
    row_useful_macs: tuple[int, ...]
    pe_work: tuple[int, ...]


def schedule_unfolded_activation(
    unfolded_activation: np.ndarray,
    output_channels: int,
    pe_count: int,
) -> SparseSchedule:
    """Build an exact-zero mask from an im2col activation matrix and schedule it."""

    unfolded = np.asarray(unfolded_activation)
    if unfolded.ndim != 2:
        raise ValueError("unfolded_activation must have shape [im2col_rows, K]")
    return schedule_activation_mask((unfolded != 0).astype(np.uint8), output_channels, pe_count)


def schedule_row_work(row_useful_macs: tuple[int, ...], dense_macs: int, pe_count: int) -> SparseSchedule:
    """Schedule pre-counted row work using the same mask scheduler semantics."""

    if dense_macs < 0:
        raise ValueError("dense_macs must be non-negative")
    if pe_count <= 0:
        raise ValueError("pe_count must be positive")
    if any(row_macs < 0 for row_macs in row_useful_macs):
        raise ValueError("row useful MAC counts must be non-negative")

    useful_macs = int(sum(row_useful_macs))
    if useful_macs > dense_macs:
        raise ValueError("useful MACs cannot exceed dense MACs")
    pe_work = [0] * pe_count
    next_pe = 0
    for row_macs in row_useful_macs:
        full_rounds, remainder = divmod(row_macs, pe_count)
        for pe_index in range(pe_count):
            pe_work[pe_index] += full_rounds
        for offset in range(remainder):
            pe_work[(next_pe + offset) % pe_count] += 1
        next_pe = (next_pe + remainder) % pe_count
    return SparseSchedule(
        dense_macs=dense_macs,
        useful_macs=useful_macs,
        skipped_macs=dense_macs - useful_macs,
        dense_cycles=(dense_macs + pe_count - 1) // pe_count,
        sparse_cycles=(useful_macs + pe_count - 1) // pe_count,
        row_useful_macs=tuple(row_useful_macs),
        pe_work=tuple(pe_work),
    )


def schedule_activation_mask(
    activation_mask: np.ndarray,
    output_channels: int,
    pe_count: int,
) -> SparseSchedule:
    """Schedule nonzero activation MACs row-wise across PE lanes.

    ``activation_mask`` must be a binary array shaped ``[im2col_rows, K]``.
    Each nonzero mask entry represents one input activation used by every
    output channel, so it contributes ``output_channels`` MACs. Rows are
    consumed in order and their work is packed continuously onto PE lanes;
    no shared zero-column or other structured-sparsity assumption is made.
    """

    mask = np.asarray(activation_mask)
    if mask.ndim != 2:
        raise ValueError("activation_mask must have shape [im2col_rows, K]")
    if output_channels <= 0:
        raise ValueError("output_channels must be positive")
    if pe_count <= 0:
        raise ValueError("pe_count must be positive")
    if not np.all((mask == 0) | (mask == 1)):
        raise ValueError("activation_mask must contain only binary values")

    row_useful_macs = tuple(int(nonzero_count * output_channels) for nonzero_count in mask.sum(axis=1))
    dense_macs = int(mask.shape[0] * mask.shape[1] * output_channels)
    useful_macs = int(sum(row_useful_macs))
    skipped_macs = dense_macs - useful_macs

    return schedule_row_work(row_useful_macs, dense_macs, pe_count)