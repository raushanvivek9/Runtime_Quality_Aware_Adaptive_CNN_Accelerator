import numpy as np

from sparse_scheduler import schedule_activation_mask, schedule_unfolded_activation


def test_irregular_activation_mask_is_scheduled_without_shared_columns():
    unfolded = np.array(
        [
            [0, 4, 0, 8],
            [3, 0, 7, 0],
            [0, 0, 5, 0],
        ],
        dtype=np.int32,
    )

    result = schedule_unfolded_activation(unfolded, output_channels=3, pe_count=2)

    assert result.dense_macs == 36
    assert result.useful_macs == 15
    assert result.skipped_macs == 21
    assert result.dense_cycles == 18
    assert result.sparse_cycles == 8
    assert result.row_useful_macs == (6, 6, 3)
    assert sum(result.pe_work) == result.useful_macs


def test_non_binary_mask_is_rejected():
    mask = np.array([[1, 2]], dtype=np.int8)

    try:
        schedule_activation_mask(mask, output_channels=1, pe_count=1)
    except ValueError as error:
        assert "binary" in str(error)
    else:
        raise AssertionError("non-binary masks must be rejected")