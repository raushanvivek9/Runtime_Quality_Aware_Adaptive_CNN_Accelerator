"""Low-overhead activation monitoring with PyTorch forward hooks."""

from __future__ import annotations

import csv
import json
from collections import OrderedDict
from pathlib import Path
from typing import Any, Iterable, Sequence

import torch
from torch import Tensor, nn


class LayerActivationMonitor:
    """Collect streaming activation statistics for selected modules.

    With ``position='pre'`` (the default), hooks observe the activation entering
    every selected layer. This is the signal available before that layer starts
    its computation, so it can drive a next-layer resource-controller policy.
    Only aggregates are retained; full activation tensors are never stored.
    """

    def __init__(
        self,
        model: nn.Module,
        module_types: tuple[type[nn.Module], ...] = (nn.Conv2d, nn.Linear),
        position: str = "pre",
    ) -> None:
        if position not in {"pre", "post"}:
            raise ValueError("position must be 'pre' or 'post'")

        self.model = model
        self.module_types = module_types
        self.position = position
        self._handles: list[torch.utils.hooks.RemovableHandle] = []
        self._stats: OrderedDict[str, dict[str, Any]] = OrderedDict()

    def start(self) -> "LayerActivationMonitor":
        """Register one hook on each selected named module."""
        if self._handles:
            raise RuntimeError("monitor is already active")

        for name, module in self.model.named_modules():
            if not name or not isinstance(module, self.module_types):
                continue
            if self.position == "pre":
                handle = module.register_forward_pre_hook(self._make_pre_hook(name))
            else:
                handle = module.register_forward_hook(self._make_post_hook(name))
            self._handles.append(handle)
        return self

    def stop(self) -> None:
        """Remove all hooks so a later experiment cannot double-count data."""
        for handle in self._handles:
            handle.remove()
        self._handles.clear()

    def __enter__(self) -> "LayerActivationMonitor":
        return self.start()

    def __exit__(self, exc_type: object, exc_value: object, traceback: object) -> None:
        self.stop()

    def _make_pre_hook(self, layer_name: str):
        def hook(module: nn.Module, inputs: tuple[Any, ...]) -> None:
            tensor = self._first_tensor(inputs)
            if tensor is not None:
                self._update(layer_name, module, tensor)

        return hook

    def _make_post_hook(self, layer_name: str):
        def hook(module: nn.Module, inputs: tuple[Any, ...], output: Any) -> None:
            tensor = self._first_tensor(output)
            if tensor is not None:
                self._update(layer_name, module, tensor)

        return hook

    @staticmethod
    def _first_tensor(value: Any) -> Tensor | None:
        if isinstance(value, Tensor):
            return value
        if isinstance(value, (tuple, list)):
            return next((item for item in value if isinstance(item, Tensor)), None)
        return None

    def _update(self, layer_name: str, module: nn.Module, activation: Tensor) -> None:
        detached = activation.detach()
        values = detached.to(device="cpu", dtype=torch.float64)
        count = values.numel()
        if count == 0:
            return

        record = self._stats.setdefault(
            layer_name,
            {
                "layer": layer_name,
                "module_type": type(module).__name__,
                "hook_position": self.position,
                "calls": 0,
                "elements": 0,
                "zero_elements": 0,
                "sum": 0.0,
                "sum_of_squares": 0.0,
                "min": float("inf"),
                "max": float("-inf"),
                "last_shape": [],
            },
        )

        record["calls"] += 1
        record["elements"] += count
        record["zero_elements"] += int(torch.count_nonzero(values == 0).item())
        record["sum"] += float(values.sum().item())
        record["sum_of_squares"] += float(torch.square(values).sum().item())
        record["min"] = min(record["min"], float(values.min().item()))
        record["max"] = max(record["max"], float(values.max().item()))
        record["last_shape"] = list(detached.shape)

    def summary(self) -> list[dict[str, Any]]:
        """Return sparsity, mean, and population variance for every layer."""
        rows: list[dict[str, Any]] = []
        for record in self._stats.values():
            elements = record["elements"]
            mean = record["sum"] / elements
            variance = max(record["sum_of_squares"] / elements - mean * mean, 0.0)
            rows.append(
                {
                    "layer": record["layer"],
                    "module_type": record["module_type"],
                    "hook_position": record["hook_position"],
                    "calls": record["calls"],
                    "activation_shape": "x".join(map(str, record["last_shape"])),
                    "elements": elements,
                    "zero_elements": record["zero_elements"],
                    "sparsity": record["zero_elements"] / elements,
                    "mean": mean,
                    "variance": variance,
                    "minimum": record["min"],
                    "maximum": record["max"],
                }
            )
        return rows

    def save(self, output_dir: Path) -> tuple[Path, Path]:
        """Save the compact layer summaries in portable CSV and JSON formats."""
        output_dir.mkdir(parents=True, exist_ok=True)
        rows = self.summary()
        csv_path = output_dir / "activation_stats.csv"
        json_path = output_dir / "activation_stats.json"

        with csv_path.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]) if rows else [])
            if rows:
                writer.writeheader()
                writer.writerows(rows)

        with json_path.open("w", encoding="utf-8") as stream:
            json.dump(rows, stream, indent=2)
            stream.write("\n")
        return csv_path, json_path
