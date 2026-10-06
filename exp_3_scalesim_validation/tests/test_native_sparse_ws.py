from pathlib import Path
import sys

import numpy as np

SCALESIM_ROOT = Path(__file__).resolve().parents[2] / "SCALE-Sim-v3-energy"
sys.path.insert(0, str(SCALESIM_ROOT))

from scalesim.compute.native_sparse_ws import build_sparse_ws_schedule, execute_sparse_ws


def test_irregular_ws_schedule_preserves_k_mapping_and_matches_dense_output():
    active_sets = ([0, 2, 5], [1, 4], [0, 3, 7, 8], [2, 6, 9, 11])
    output_positions, reduction_size, output_channels = 4, 12, 10
    mask = np.zeros((output_positions, reduction_size), dtype=np.uint8)
    rng = np.random.default_rng(24)
    activations = np.zeros((output_positions, reduction_size), dtype=np.float32)
    for position, active_k in enumerate(active_sets):
        mask[position, active_k] = 1
        activations[position, active_k] = rng.normal(size=len(active_k))
    weights = rng.normal(size=(reduction_size, output_channels)).astype(np.float32)

    schedule = build_sparse_ws_schedule(mask, output_channels, array_rows=4, array_cols=8)
    events = list(schedule.iter_events())
    dense_output = activations @ weights
    sparse_output = execute_sparse_ws(activations, weights, mask, schedule)

    assert schedule.active_mask_entries == sum(map(len, active_sets))
    assert schedule.useful_macs == schedule.active_mask_entries * output_channels
    assert schedule.dense_macs == output_positions * reduction_size * output_channels
    assert schedule.useful_macs + schedule.skipped_macs == schedule.dense_macs
    assert schedule.skipped_macs == (output_positions * reduction_size - schedule.active_mask_entries) * output_channels
    assert len(events) == schedule.useful_macs
    assert schedule.cycles != schedule.analytical_lower_bound

    observed_by_position = {position: set() for position in range(output_positions)}
    coordinates = set()
    occupied_pes = set()
    for event in events:
        assert event.original_k in active_sets[event.output_position]
        assert event.pe_row == event.original_k % 4
        assert event.pe_col == event.output_channel % 8
        assert 0 <= event.pe_row < 4
        assert 0 <= event.pe_col < 8
        assert event.completion_cycle == event.issue_cycle + 1
        coordinates.add((event.output_position, event.original_k, event.output_channel))
        observed_by_position[event.output_position].add(event.original_k)
        pe_slot = (event.issue_cycle, event.pe_row, event.pe_col)
        assert pe_slot not in occupied_pes
        occupied_pes.add(pe_slot)

    assert len(coordinates) == schedule.useful_macs
    assert tuple(observed_by_position[position] for position in range(output_positions)) == tuple(
        set(active_k) for active_k in active_sets
    )
    assert sparse_output.shape == dense_output.shape == (output_positions, output_channels)
    np.testing.assert_allclose(sparse_output, dense_output, rtol=2e-6, atol=2e-6)


def test_non_binary_activation_mask_is_rejected():
    mask = np.array([[1, 0, 2]], dtype=np.int8)
    try:
        build_sparse_ws_schedule(mask, output_channels=2)
    except ValueError as error:
        assert "binary" in str(error)
    else:
        raise AssertionError("non-binary activation masks must be rejected")