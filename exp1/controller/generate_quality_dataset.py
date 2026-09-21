"""Generate a measured Stage-2 quality-degradation dataset.

This experiment deliberately uses a *software proxy for resource reduction*.
For the selected Conv2d or Linear layer, it computes only a deterministic,
evenly spaced subset of output channels/features and returns zeros for the
uncomputed outputs.  It therefore changes both the numerical model output and
the selected layer's MAC work.  It is not a cycle-accurate PE simulation.

The Stage-1 runner has no labelled dataset or checkpoint: it uses seeded
Gaussian images with a randomly initialised ``SimpleCNN``.  This script keeps
that input distribution and uses each full-resource prediction as a
deterministic pseudo-label.  Loss and accuracy consequently measure agreement
with the 64-resource model, not semantic CIFAR-style classification quality.
"""

from __future__ import annotations

import argparse
import copy
import csv
import json
import math
import sys
from collections import defaultdict
from contextlib import AbstractContextManager
from pathlib import Path
from statistics import mean, pstdev
from typing import Any

import torch
from torch import Tensor, nn
from torch.nn import functional as F


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PYTORCH_DIR = PROJECT_ROOT / "pytorch"
if str(PYTORCH_DIR) not in sys.path:
    sys.path.insert(0, str(PYTORCH_DIR))

from model import SimpleCNN  # noqa: E402


RESOURCE_LEVELS = (16, 32, 64)
FULL_RESOURCE_LEVEL = 64
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "results"
PROXY_NAME = "deterministic_structured_output_channel_reduction"

CSV_FIELDS = [
    "sample_id",
    "label",
    "layer",
    "module_type",
    "sparsity",
    "mean",
    "variance",
    "layer_position",
    "resource_level",
    "retained_output_fraction",
    "baseline_loss",
    "reduced_loss",
    "degradation",
    "baseline_correct",
    "reduced_correct",
    "resource_reduction_proxy",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--samples",
        type=int,
        default=128,
        help="number of deterministic synthetic input samples (default: 128)",
    )
    parser.add_argument(
        "--batch-size", type=int, default=16, help="inference batch size (default: 16)"
    )
    parser.add_argument("--seed", type=int, default=42, help="fixed experiment seed")
    parser.add_argument("--device", default="cpu", help="PyTorch device (default: cpu)")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    return parser.parse_args()


def selected_output_indices(total_outputs: int, resource_level: int) -> Tensor:
    """Return evenly spaced, deterministic output indices for one layer."""
    if resource_level not in RESOURCE_LEVELS:
        raise ValueError(f"unsupported resource level: {resource_level}")
    retained = max(1, round(total_outputs * resource_level / FULL_RESOURCE_LEVEL))
    retained = min(retained, total_outputs)
    return torch.div(
        torch.arange(retained) * total_outputs,
        retained,
        rounding_mode="floor",
    )


class ReducedConv2d(nn.Module):
    """Conv2d wrapper that computes only selected output channels.

    The zero-filled channels preserve the original layer shape for later
    layers; only the selected filters are passed to ``F.conv2d``.  This is a
    structured software proxy for resource reduction, not a hardware timing
    model.
    """

    def __init__(self, source: nn.Conv2d, resource_level: int) -> None:
        super().__init__()
        if source.groups != 1 or source.padding_mode != "zeros":
            raise ValueError(
                "ReducedConv2d currently supports the SimpleCNN's ungrouped, "
                "zero-padded Conv2d layers only."
            )
        self.source = source
        self.register_buffer(
            "active_indices", selected_output_indices(source.out_channels, resource_level)
        )
        self.resource_level = resource_level

    @property
    def retained_fraction(self) -> float:
        return self.active_indices.numel() / self.source.out_channels

    def forward(self, inputs: Tensor) -> Tensor:
        weight = self.source.weight.index_select(0, self.active_indices)
        bias = (
            None
            if self.source.bias is None
            else self.source.bias.index_select(0, self.active_indices)
        )
        active_outputs = F.conv2d(
            inputs,
            weight,
            bias,
            self.source.stride,
            self.source.padding,
            self.source.dilation,
            self.source.groups,
        )
        full_shape = list(active_outputs.shape)
        full_shape[1] = self.source.out_channels
        outputs = active_outputs.new_zeros(full_shape)
        return outputs.index_copy(1, self.active_indices, active_outputs)


class ReducedLinear(nn.Module):
    """Linear wrapper that computes only selected output features."""

    def __init__(self, source: nn.Linear, resource_level: int) -> None:
        super().__init__()
        self.source = source
        self.register_buffer(
            "active_indices", selected_output_indices(source.out_features, resource_level)
        )
        self.resource_level = resource_level

    @property
    def retained_fraction(self) -> float:
        return self.active_indices.numel() / self.source.out_features

    def forward(self, inputs: Tensor) -> Tensor:
        weight = self.source.weight.index_select(0, self.active_indices)
        bias = (
            None
            if self.source.bias is None
            else self.source.bias.index_select(0, self.active_indices)
        )
        active_outputs = F.linear(inputs, weight, bias)
        full_shape = list(active_outputs.shape)
        full_shape[-1] = self.source.out_features
        outputs = active_outputs.new_zeros(full_shape)
        return outputs.index_copy(-1, self.active_indices, active_outputs)


def replace_module(model: nn.Module, name: str, replacement: nn.Module) -> None:
    """Replace one named child module in a disposable deep copy of ``model``."""
    parent = model
    parts = name.split(".")
    for part in parts[:-1]:
        parent = getattr(parent, part)
    setattr(parent, parts[-1], replacement)


def resource_reduced_model(
    baseline_model: nn.Module, layer_name: str, resource_level: int, device: torch.device
) -> tuple[nn.Module, float]:
    """Copy a model and proxy-reduce exactly one monitored layer."""
    model = copy.deepcopy(baseline_model).to(device).eval()
    source = dict(model.named_modules())[layer_name]
    if isinstance(source, nn.Conv2d):
        replacement: nn.Module = ReducedConv2d(source, resource_level)
    elif isinstance(source, nn.Linear):
        replacement = ReducedLinear(source, resource_level)
    else:
        raise TypeError(f"unsupported monitored module at {layer_name}: {type(source).__name__}")
    retained_fraction = replacement.retained_fraction  # type: ignore[attr-defined]
    replace_module(model, layer_name, replacement)
    return model, retained_fraction


class PerSamplePreLayerCollector(AbstractContextManager["PerSamplePreLayerCollector"]):
    """Collect only per-sample pre-layer aggregates for the requested modules."""

    def __init__(self, model: nn.Module, layer_names: list[str]) -> None:
        self.model = model
        self.layer_names = layer_names
        self._handles: list[torch.utils.hooks.RemovableHandle] = []
        self._batch_stats: dict[str, list[dict[str, float]]] = {}

    def __enter__(self) -> "PerSamplePreLayerCollector":
        modules = dict(self.model.named_modules())
        for name in self.layer_names:
            self._handles.append(modules[name].register_forward_pre_hook(self._make_hook(name)))
        return self

    def __exit__(self, exc_type: object, exc_value: object, traceback: object) -> None:
        for handle in self._handles:
            handle.remove()
        self._handles.clear()

    def begin_batch(self) -> None:
        self._batch_stats = {}

    def consume_batch(self) -> dict[str, list[dict[str, float]]]:
        missing = set(self.layer_names) - set(self._batch_stats)
        if missing:
            raise RuntimeError(f"pre-layer statistics were not collected for: {sorted(missing)}")
        return self._batch_stats

    def _make_hook(self, layer_name: str):
        def hook(module: nn.Module, inputs: tuple[Any, ...]) -> None:
            if not inputs or not isinstance(inputs[0], Tensor):
                raise TypeError(f"{layer_name} did not receive a tensor input")
            activations = inputs[0].detach().to(device="cpu", dtype=torch.float64)
            if activations.ndim < 1:
                raise ValueError(f"{layer_name} input does not have a batch dimension")
            values = activations.reshape(activations.shape[0], -1)
            element_count = values.shape[1]
            means = values.mean(dim=1)
            variances = torch.clamp_min(torch.mean(values.square(), dim=1) - means.square(), 0)
            zero_counts = torch.count_nonzero(values == 0, dim=1)
            self._batch_stats[layer_name] = [
                {
                    "sparsity": float(zero_counts[index].item() / element_count),
                    "mean": float(means[index].item()),
                    "variance": float(variances[index].item()),
                }
                for index in range(values.shape[0])
            ]

        return hook


def evaluate_logits(
    model: nn.Module, inputs: Tensor, batch_size: int, device: torch.device
) -> Tensor:
    """Run batched inference without retaining intermediate activations."""
    outputs: list[Tensor] = []
    with torch.inference_mode():
        for start in range(0, len(inputs), batch_size):
            logits = model(inputs[start : start + batch_size].to(device))
            outputs.append(logits.cpu())
    return torch.cat(outputs, dim=0)


def collect_baseline(
    model: nn.Module,
    inputs: Tensor,
    layer_names: list[str],
    batch_size: int,
    device: torch.device,
) -> tuple[Tensor, list[dict[str, dict[str, float]]]]:
    """Evaluate resource-64 inference and collect its per-sample pre-layer features."""
    per_sample_stats: list[dict[str, dict[str, float]]] = [{} for _ in range(len(inputs))]
    logits_chunks: list[Tensor] = []
    with PerSamplePreLayerCollector(model, layer_names) as collector, torch.inference_mode():
        for start in range(0, len(inputs), batch_size):
            collector.begin_batch()
            logits = model(inputs[start : start + batch_size].to(device))
            logits_chunks.append(logits.cpu())
            batch_stats = collector.consume_batch()
            stop = start + logits.shape[0]
            for local_index, sample_index in enumerate(range(start, stop)):
                per_sample_stats[sample_index] = {
                    layer_name: batch_stats[layer_name][local_index] for layer_name in layer_names
                }
    return torch.cat(logits_chunks, dim=0), per_sample_stats


def finite_records(records: list[dict[str, Any]]) -> bool:
    for record in records:
        for value in record.values():
            if isinstance(value, float) and not math.isfinite(value):
                return False
    return True


def resource_statistics(records: list[dict[str, Any]]) -> list[dict[str, float | int]]:
    grouped: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        grouped[int(record["resource_level"])].append(record)

    rows: list[dict[str, float | int]] = []
    for resource in RESOURCE_LEVELS:
        values = grouped[resource]
        degradations = [float(row["degradation"]) for row in values]
        baseline_accuracy = mean(float(row["baseline_correct"]) for row in values)
        reduced_accuracy = mean(float(row["reduced_correct"]) for row in values)
        rows.append(
            {
                "resource_level": resource,
                "rows": len(values),
                "mean_degradation": mean(degradations),
                "std_degradation": pstdev(degradations),
                "minimum_degradation": min(degradations),
                "maximum_degradation": max(degradations),
                "baseline_accuracy": baseline_accuracy,
                "reduced_accuracy": reduced_accuracy,
                "accuracy_degradation": baseline_accuracy - reduced_accuracy,
            }
        )
    return rows


def write_outputs(
    output_dir: Path,
    baseline_metrics: dict[str, Any],
    records: list[dict[str, Any]],
    summary_text: str,
) -> tuple[Path, Path, Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    baseline_path = output_dir / "baseline_metrics.json"
    csv_path = output_dir / "quality_dataset.csv"
    json_path = output_dir / "quality_dataset.json"
    summary_path = output_dir / "quality_dataset_summary.txt"

    with baseline_path.open("w", encoding="utf-8") as stream:
        json.dump(baseline_metrics, stream, indent=2)
        stream.write("\n")
    with csv_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(records)
    with json_path.open("w", encoding="utf-8") as stream:
        json.dump(records, stream, indent=2)
        stream.write("\n")
    summary_path.write_text(summary_text, encoding="utf-8")
    return baseline_path, csv_path, json_path, summary_path


def make_summary(
    args: argparse.Namespace,
    baseline_metrics: dict[str, Any],
    records: list[dict[str, Any]],
    layer_names: list[str],
    stats: list[dict[str, float | int]],
) -> str:
    lines = [
        "Stage 2 - Quality Degradation Dataset",
        "=" * 40,
        f"Seed: {args.seed}",
        f"Device: {args.device}",
        f"Rows: {len(records)}",
        f"Samples: {args.samples}",
        f"Monitored layers: {', '.join(layer_names)}",
        f"Resource levels: {', '.join(map(str, RESOURCE_LEVELS))}; {FULL_RESOURCE_LEVEL} is baseline.",
        "",
        "Input/label protocol:",
        "  Inputs are seeded N(0, 1) 32x32 RGB tensors, matching Stage 1.",
        "  No labelled dataset or checkpoint exists in this project.",
        "  Labels are deterministic full-resource argmax pseudo-labels, so the loss and",
        "  accuracy measure agreement with the 64-resource model rather than semantic accuracy.",
        "",
        "Software proxy for resource reduction:",
        "  One selected Conv2d/Linear layer computes an evenly spaced subset of output",
        "  channels/features (25% at 16, 50% at 32 where dimensions permit); the omitted",
        "  outputs are zero-filled to keep following-layer shapes unchanged.",
        "  This reduces arithmetic in that layer and changes logits, but is not a",
        "  cycle-accurate PE/resource-allocation simulation. SCALE-Sim is deferred.",
        "",
        "Baseline metrics:",
        f"  Mean loss: {baseline_metrics['baseline_loss']:.8f}",
        f"  Baseline agreement accuracy: {baseline_metrics['baseline_accuracy']:.8f}",
        "",
        "Degradation statistics grouped by resource:",
        "resource  rows  mean_loss_delta  std_loss_delta  min_delta  max_delta  accuracy_delta",
    ]
    for row in stats:
        lines.append(
            f"{row['resource_level']:>8}  {row['rows']:>4}  "
            f"{row['mean_degradation']:>15.8f}  {row['std_degradation']:>14.8f}  "
            f"{row['minimum_degradation']:>9.8f}  {row['maximum_degradation']:>9.8f}  "
            f"{row['accuracy_degradation']:>14.8f}"
        )
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    args = parse_args()
    if args.samples < 1 or args.batch_size < 1:
        raise ValueError("--samples and --batch-size must be positive")
    if args.device != "cpu" and not torch.cuda.is_available():
        raise ValueError(f"requested device {args.device!r}, but CUDA is not available")

    # A fixed seed reproduces model initialization and the synthetic Stage-1 inputs.
    torch.manual_seed(args.seed)
    device = torch.device(args.device)
    model = SimpleCNN().to(device).eval()
    monitored = [
        (name, module)
        for name, module in model.named_modules()
        if name and isinstance(module, (nn.Conv2d, nn.Linear))
    ]
    layer_names = [name for name, _ in monitored]
    module_types = {name: type(module).__name__ for name, module in monitored}

    # Stage 1 has no external data loader.  Generate the same deterministic input type.
    inputs = torch.randn(args.samples, 3, 32, 32)
    baseline_logits, per_sample_stats = collect_baseline(
        model, inputs, layer_names, args.batch_size, device
    )
    pseudo_labels = baseline_logits.argmax(dim=1)
    baseline_losses = F.cross_entropy(baseline_logits, pseudo_labels, reduction="none")
    baseline_correct = baseline_logits.argmax(dim=1).eq(pseudo_labels)
    baseline_metrics: dict[str, Any] = {
        "number_of_samples": args.samples,
        "baseline_loss": float(baseline_losses.mean().item()),
        "baseline_accuracy": float(baseline_correct.float().mean().item()),
        "accuracy_metric": "agreement with full-resource argmax pseudo-labels",
        "loss_metric": "cross-entropy against full-resource argmax pseudo-labels",
        "model_name": type(model).__name__,
        "model_checkpoint": None,
        "model_initialization": "randomly initialized with fixed seed",
        "input_source": "seeded Gaussian synthetic tensors; no external dataset configured in Stage 1",
        "label_source": "full-resource model argmax pseudo-labels; no ground-truth labels available",
        "monitored_layers": layer_names,
        "resource_baseline": FULL_RESOURCE_LEVEL,
        "seed": args.seed,
        "software_proxy": PROXY_NAME,
    }

    records: list[dict[str, Any]] = []
    for layer_index, layer_name in enumerate(layer_names, start=1):
        layer_position = layer_index / len(layer_names)
        for resource_level in RESOURCE_LEVELS:
            if resource_level == FULL_RESOURCE_LEVEL:
                reduced_logits = baseline_logits
                retained_fraction = 1.0
            else:
                reduced_model, retained_fraction = resource_reduced_model(
                    model, layer_name, resource_level, device
                )
                reduced_logits = evaluate_logits(reduced_model, inputs, args.batch_size, device)
                del reduced_model

            reduced_losses = F.cross_entropy(reduced_logits, pseudo_labels, reduction="none")
            reduced_correct = reduced_logits.argmax(dim=1).eq(pseudo_labels)
            for sample_index in range(args.samples):
                features = per_sample_stats[sample_index][layer_name]
                baseline_loss = float(baseline_losses[sample_index].item())
                reduced_loss = float(reduced_losses[sample_index].item())
                records.append(
                    {
                        "sample_id": sample_index,
                        "label": int(pseudo_labels[sample_index].item()),
                        "layer": layer_name,
                        "module_type": module_types[layer_name],
                        "sparsity": features["sparsity"],
                        "mean": features["mean"],
                        "variance": features["variance"],
                        "layer_position": layer_position,
                        "resource_level": resource_level,
                        "retained_output_fraction": retained_fraction,
                        "baseline_loss": baseline_loss,
                        "reduced_loss": reduced_loss,
                        "degradation": reduced_loss - baseline_loss,
                        "baseline_correct": int(baseline_correct[sample_index].item()),
                        "reduced_correct": int(reduced_correct[sample_index].item()),
                        "resource_reduction_proxy": PROXY_NAME,
                    }
                )

    expected_rows = args.samples * len(layer_names) * len(RESOURCE_LEVELS)
    if len(records) != expected_rows:
        raise RuntimeError(f"expected {expected_rows} records but created {len(records)}")
    if not finite_records(records):
        raise RuntimeError("dataset contains a NaN or Inf value")
    if set(record["layer"] for record in records) != set(layer_names):
        raise RuntimeError("dataset does not contain every monitored layer")
    resource_64_degradation = [
        abs(float(record["degradation"]))
        for record in records
        if record["resource_level"] == FULL_RESOURCE_LEVEL
    ]
    if max(resource_64_degradation, default=0.0) > 1e-12:
        raise RuntimeError("64-resource degradation is not zero within tolerance")

    stats = resource_statistics(records)
    summary_text = make_summary(args, baseline_metrics, records, layer_names, stats)
    baseline_path, csv_path, json_path, summary_path = write_outputs(
        args.output_dir, baseline_metrics, records, summary_text
    )

    print("Baseline metrics:")
    print(json.dumps(baseline_metrics, indent=2))
    print(f"\nGenerated rows: {len(records)}")
    print(f"Unique layers: {len(layer_names)} ({', '.join(layer_names)})")
    print("Resource-level counts:")
    for row in stats:
        print(f"  {row['resource_level']}: {row['rows']}")
    print("Degradation statistics grouped by resource:")
    for row in stats:
        print(
            f"  resource={row['resource_level']}: mean={row['mean_degradation']:.8f}, "
            f"std={row['std_degradation']:.8f}, min={row['minimum_degradation']:.8f}, "
            f"max={row['maximum_degradation']:.8f}, "
            f"accuracy_degradation={row['accuracy_degradation']:.8f}"
        )
    print("Validation: no NaN/Inf; all monitored layers present; resource-64 degradation is zero.")
    print("First 10 rows of quality_dataset.csv:")
    with csv_path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream):
            if line_number > 10:
                break
            print(line.rstrip())
    print("Created files:")
    for path in (baseline_path, csv_path, json_path, summary_path):
        print(f"  {path}")


if __name__ == "__main__":
    main()
