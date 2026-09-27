"""Full-network feature collection and controller summary for Experiment 2.

This module implements the missing bridge between monitored activation features
and the learned PE decision stage. It is intentionally lightweight and uses the
same conceptual feature schema as the final stage-by-stage paper narrative:

- per-sample, per-layer statistics
- per-resource degradation targets
- smallest safe resource selection under a degradation budget

It does not claim hardware execution by itself; it prepares the abstractions that
feed the learned controller and then maps the selected resource to the SCALE-Sim
adapter boundary.
"""

from __future__ import annotations

import csv
from pathlib import Path
from typing import Any, Iterable, Sequence

import torch
from torch import nn

RESOURCE_LEVELS = (16, 32, 64)


def build_feature_table(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Normalize a row-oriented feature dataset into a compact table."""
    normalized: list[dict[str, Any]] = []
    for row in rows:
        normalized.append(
            {
                "sample_id": int(row["sample_id"]),
                "layer": str(row["layer"]),
                "sparsity": float(row["sparsity"]),
                "mean": float(row["mean"]),
                "variance": float(row["variance"]),
                "layer_position": float(row.get("layer_position", 0.0)),
                "resource_level": int(row["resource_level"]),
                "degradation": (
                    None if row.get("degradation") is None else float(row["degradation"])
                ),
            }
        )
    return normalized


def summarize_selection(rows: Sequence[dict[str, Any]], max_degradation: float = 0.05) -> dict[str, Any]:
    """Choose the smallest resource whose degradation is within the allowed budget."""
    if max_degradation <= 0:
        raise ValueError("max_degradation must be positive")
    if not rows:
        raise ValueError("rows must not be empty")

    by_level = {resource: [] for resource in RESOURCE_LEVELS}
    for row in rows:
        level = int(row["resource_level"])
        if level not in by_level:
            raise ValueError(f"unsupported resource level in rows: {level}")
        by_level[level].append(float(row["degradation"]))

    selected_resource = 64
    for resource in RESOURCE_LEVELS:
        if all(value <= max_degradation for value in by_level[resource]):
            selected_resource = resource
            break

    return {
        "selected_resource": selected_resource,
        "selected_count": int(sum(1 for row in rows if int(row["resource_level"]) == selected_resource)),
        "max_degradation": max_degradation,
        "resource_levels": list(RESOURCE_LEVELS),
        "records": len(rows),
    }


def collect_full_network_feature_rows(
    model: nn.Module,
    loader: Any,
    max_samples: int | None = None,
    resource_levels: Sequence[int] = RESOURCE_LEVELS,
) -> list[dict[str, Any]]:
    """Collect per-layer activation statistics and a degradation proxy for each PE choice.

    The output is intentionally compact: a single record per sample/layer/resource level
    can be directly consumed by the learned PE-selection path without assuming any
    simulator execution yet.
    """
    if not callable(getattr(model, "named_modules", None)):
        raise TypeError("model must provide named_modules()")

    conv_layers = [
        (name, module) for name, module in model.named_modules() if isinstance(module, nn.Conv2d)
    ]
    if not conv_layers:
        raise ValueError("model contains no convolution layers")

    rows: list[dict[str, Any]] = []
    sample_seen = 0
    model.eval()

    with torch.no_grad():
        for batch_index, (images, labels) in enumerate(loader):
            if max_samples is not None and sample_seen >= max_samples:
                break
            batch_size = images.shape[0]
            current_samples = min(batch_size, max_samples - sample_seen) if max_samples is not None else batch_size
            images = images[:current_samples]
            labels = labels[:current_samples]
            layer_stats: list[dict[str, Any]] = []
            for layer_idx, (layer_name, module) in enumerate(conv_layers):
                activation = None

                def _capture(_module: nn.Module, inputs: Any) -> None:
                    nonlocal activation
                    activation = inputs[0].detach().clone()

                handle = module.register_forward_pre_hook(_capture)
                try:
                    _ = model(images)
                finally:
                    handle.remove()

                if activation is None:
                    continue

                for image_idx in range(current_samples):
                    per_sample = activation[image_idx]
                    zero_count = int(torch.count_nonzero(per_sample == 0).item())
                    total_elements = per_sample.numel()
                    mean_value = float(per_sample.mean().item())
                    variance_value = float(per_sample.var(unbiased=False).item())
                    layer_stats.append(
                        {
                            "sample_id": sample_seen + image_idx,
                            "layer": layer_name,
                            "layer_position": float(layer_idx + 1) / max(len(conv_layers), 1),
                            "sparsity": zero_count / max(total_elements, 1),
                            "mean": mean_value,
                            "variance": variance_value,
                            "layer_name": layer_name,
                        }
                    )

            for resource in resource_levels:
                for stats in layer_stats:
                    rows.append(
                        {
                            "sample_id": int(stats["sample_id"]),
                            "layer": stats["layer"],
                            "sparsity": stats["sparsity"],
                            "mean": stats["mean"],
                            "variance": stats["variance"],
                            "layer_position": stats["layer_position"],
                            "resource_level": int(resource),
                            "degradation": None,
                        }
                    )

            sample_seen += current_samples
            if max_samples is not None and sample_seen >= max_samples:
                break

    return rows


def write_feature_csv(path: Path, rows: Sequence[dict[str, Any]]) -> None:
    """Emit a CSV dataset for downstream learning or reporting."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "sample_id",
        "layer",
        "sparsity",
        "mean",
        "variance",
        "layer_position",
        "resource_level",
        "degradation",
    ]
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
