"""Generate a new Stage-2-quality dataset using the corrected V2 proxy.

V2 keeps the existing Conv2d output-channel reduction but reduces the final
classifier by input-feature columns while preserving all class logits.  This
creates new, measured software-proxy labels without changing the original
dataset, quality estimator, Stage-4 controller, monitor, or SCALE-Sim.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from collections import Counter, defaultdict
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

from generate_quality_dataset import (  # noqa: E402
    PerSamplePreLayerCollector,
    evaluate_logits,
)
from model import SimpleCNN  # noqa: E402
from resource_proxy_v2 import (  # noqa: E402
    FULL_RESOURCE_LEVEL,
    PROXY_NAME_V2,
    RESOURCE_LEVELS,
    ResourceProfileV2,
    profile_for_module_v2,
    resource_reduced_model_v2,
    selected_evenly_spaced_indices,
)


DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "results"
DEFAULT_OLD_DATASET = DEFAULT_OUTPUT_DIR / "quality_dataset.csv"
DEFAULT_MODEL_METRICS = DEFAULT_OUTPUT_DIR / "model_metrics.json"
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
    "retained_input_features",
    "retained_output_features",
    "retained_input_fraction",
    "baseline_loss",
    "reduced_loss",
    "degradation",
    "baseline_correct",
    "reduced_correct",
    "resource_reduction_proxy",
]
CLASSIFIER_DIAGNOSTIC_FIELDS = [
    "sample_id",
    "resource",
    "baseline_loss",
    "actual_loss",
    "actual_degradation",
    "retained_input_features",
    "retained_output_features",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=128)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--device", default="cpu", help="PyTorch device (default: cpu)")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--old-dataset", type=Path, default=DEFAULT_OLD_DATASET)
    parser.add_argument("--model-metrics", type=Path, default=DEFAULT_MODEL_METRICS)
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"required file not found: {path}")
    with path.open(encoding="utf-8") as stream:
        data = json.load(stream)
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object in {path}")
    return data


def held_out_sample_ids(model_metrics_path: Path) -> list[int]:
    metrics = read_json(model_metrics_path)
    try:
        values = [int(value) for value in metrics["split"]["sample_ids"]["test"]]
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError(f"{model_metrics_path} has no valid test sample IDs") from error
    if not values or min(values) < 0 or len(values) != len(set(values)):
        raise ValueError("test sample IDs must be non-empty, unique, and non-negative")
    return values


def monitored_layers(model: nn.Module) -> list[tuple[str, nn.Module]]:
    layers = [
        (name, module)
        for name, module in model.named_modules()
        if name and isinstance(module, (nn.Conv2d, nn.Linear))
    ]
    if not layers:
        raise ValueError("the model has no Conv2d/Linear layers")
    if layers[-1][0] != "classifier" or not isinstance(layers[-1][1], nn.Linear):
        raise ValueError("V2 expects the terminal Linear layer to be named 'classifier'")
    return layers


def finite_records(records: list[dict[str, Any]]) -> bool:
    return all(
        math.isfinite(value)
        for record in records
        for value in record.values()
        if isinstance(value, float)
    )


def measured_dataset_v2(
    model: nn.Module,
    inputs: Tensor,
    batch_size: int,
    device: torch.device,
) -> tuple[list[dict[str, Any]], list[tuple[str, nn.Module]], Tensor]:
    """Measure all 128 x 4 x 3 configurations using V2, without predictions."""
    layers = monitored_layers(model)
    layer_names = [name for name, _ in layers]
    module_types = {name: type(module).__name__ for name, module in layers}
    baseline_logits, per_sample_stats = collect_baseline_v2(
        model, inputs, layer_names, batch_size, device
    )
    pseudo_labels = baseline_logits.argmax(dim=1)
    baseline_losses = F.cross_entropy(baseline_logits, pseudo_labels, reduction="none")
    baseline_correct = baseline_logits.argmax(dim=1).eq(pseudo_labels)

    records: list[dict[str, Any]] = []
    for layer_index, (layer_name, module) in enumerate(layers, start=1):
        layer_position = layer_index / len(layers)
        for resource_level in RESOURCE_LEVELS:
            profile = profile_for_module_v2(module, resource_level)
            if resource_level == FULL_RESOURCE_LEVEL:
                reduced_logits = baseline_logits
            else:
                reduced_model, actual_profile = resource_reduced_model_v2(
                    model, layer_name, resource_level, device
                )
                if actual_profile != profile:
                    raise RuntimeError("V2 proxy profile differs from dataset accounting metadata")
                reduced_logits = evaluate_logits(reduced_model, inputs, batch_size, device)
                del reduced_model
            reduced_losses = F.cross_entropy(reduced_logits, pseudo_labels, reduction="none")
            reduced_correct = reduced_logits.argmax(dim=1).eq(pseudo_labels)
            for sample_id in range(len(inputs)):
                stats = per_sample_stats[sample_id][layer_name]
                baseline_loss = float(baseline_losses[sample_id].item())
                actual_loss = float(reduced_losses[sample_id].item())
                records.append(
                    {
                        "sample_id": sample_id,
                        "label": int(pseudo_labels[sample_id].item()),
                        "layer": layer_name,
                        "module_type": module_types[layer_name],
                        "sparsity": float(stats["sparsity"]),
                        "mean": float(stats["mean"]),
                        "variance": float(stats["variance"]),
                        "layer_position": layer_position,
                        "resource_level": resource_level,
                        "retained_output_fraction": profile.retained_output_fraction,
                        "retained_input_features": profile.retained_input_features,
                        "retained_output_features": profile.retained_output_features,
                        "retained_input_fraction": profile.retained_input_fraction,
                        "baseline_loss": baseline_loss,
                        "reduced_loss": actual_loss,
                        "degradation": actual_loss - baseline_loss,
                        "baseline_correct": int(baseline_correct[sample_id].item()),
                        "reduced_correct": int(reduced_correct[sample_id].item()),
                        "resource_reduction_proxy": PROXY_NAME_V2,
                    }
                )
    expected_rows = len(inputs) * len(layers) * len(RESOURCE_LEVELS)
    if len(records) != expected_rows:
        raise RuntimeError(f"expected {expected_rows} rows; received {len(records)}")
    if not finite_records(records):
        raise RuntimeError("V2 dataset contains a NaN or Inf")
    full_degradations = [
        abs(float(row["degradation"]))
        for row in records
        if int(row["resource_level"]) == FULL_RESOURCE_LEVEL
    ]
    if max(full_degradations, default=0.0) > 1e-12:
        raise RuntimeError("64-resource degradation is not zero within tolerance")
    return records, layers, pseudo_labels


def collect_baseline_v2(
    model: nn.Module,
    inputs: Tensor,
    layer_names: list[str],
    batch_size: int,
    device: torch.device,
) -> tuple[Tensor, list[dict[str, dict[str, float]]]]:
    """Use Stage 2's existing per-sample pre-layer aggregate collector unchanged."""
    per_sample_stats: list[dict[str, dict[str, float]]] = [{} for _ in range(len(inputs))]
    logits_chunks: list[Tensor] = []
    with PerSamplePreLayerCollector(model, layer_names) as collector, torch.inference_mode():
        for start in range(0, len(inputs), batch_size):
            collector.begin_batch()
            logits = model(inputs[start : start + batch_size].to(device))
            logits_chunks.append(logits.cpu())
            batch_stats = collector.consume_batch()
            for local_index, sample_id in enumerate(range(start, start + logits.shape[0])):
                per_sample_stats[sample_id] = {
                    layer_name: batch_stats[layer_name][local_index] for layer_name in layer_names
                }
    return torch.cat(logits_chunks, dim=0), per_sample_stats


def grouped_records(records: list[dict[str, Any]]) -> dict[tuple[int, str], dict[int, dict[str, Any]]]:
    grouped: dict[tuple[int, str], dict[int, dict[str, Any]]] = defaultdict(dict)
    for record in records:
        key = (int(record["sample_id"]), str(record["layer"]))
        resource = int(record["resource_level"])
        if resource in grouped[key]:
            raise RuntimeError(f"duplicate resource record for {key}, {resource}")
        grouped[key][resource] = record
    for key, values in grouped.items():
        if set(values) != set(RESOURCE_LEVELS):
            raise RuntimeError(f"missing a resource record for {key}")
    return grouped


def monotonicity_violations(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Report raw measured violations; no degradation is reordered or corrected."""
    violations: list[dict[str, Any]] = []
    for (sample_id, layer), values in sorted(grouped_records(records).items()):
        d16 = float(values[16]["degradation"])
        d32 = float(values[32]["degradation"])
        d64 = float(values[64]["degradation"])
        if d16 < d32:
            violations.append(
                {"sample_id": sample_id, "layer": layer, "relation": "D16 < D32", "D16": d16, "D32": d32, "D64": d64}
            )
        if d32 < d64:
            violations.append(
                {"sample_id": sample_id, "layer": layer, "relation": "D32 < D64", "D16": d16, "D32": d32, "D64": d64}
            )
    return violations


def degradation_statistics(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[int, list[float]] = defaultdict(list)
    for record in records:
        grouped[int(record["resource_level"])].append(float(record["degradation"]))
    return [
        {
            "resource": resource,
            "rows": len(grouped[resource]),
            "mean": mean(grouped[resource]),
            "std": pstdev(grouped[resource]),
            "minimum": min(grouped[resource]),
            "maximum": max(grouped[resource]),
        }
        for resource in RESOURCE_LEVELS
    ]


def old_classifier_statistics(old_dataset_path: Path) -> tuple[dict[int, float], int]:
    """Read comparison-only statistics from the preserved original dataset."""
    if not old_dataset_path.is_file():
        raise FileNotFoundError(f"original dataset required for comparison: {old_dataset_path}")
    grouped: dict[tuple[int, str], dict[int, float]] = defaultdict(dict)
    with old_dataset_path.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            if row["layer"] != "classifier":
                continue
            grouped[(int(row["sample_id"]), row["layer"])][int(row["resource_level"])] = float(
                row["degradation"]
            )
    means = {
        resource: mean(values[resource] for values in grouped.values())
        for resource in RESOURCE_LEVELS
    }
    violations = sum(
        values[16] < values[32] for values in grouped.values()
    ) + sum(values[32] < values[64] for values in grouped.values())
    return means, violations


def classifier_diagnostic_rows(
    records: list[dict[str, Any]], test_ids: list[int]
) -> list[dict[str, Any]]:
    test_set = set(test_ids)
    rows = [
        {
            "sample_id": int(record["sample_id"]),
            "resource": int(record["resource_level"]),
            "baseline_loss": float(record["baseline_loss"]),
            "actual_loss": float(record["reduced_loss"]),
            "actual_degradation": float(record["degradation"]),
            "retained_input_features": int(record["retained_input_features"]),
            "retained_output_features": int(record["retained_output_features"]),
        }
        for record in records
        if record["layer"] == "classifier" and int(record["sample_id"]) in test_set
    ]
    expected_rows = len(test_ids) * len(RESOURCE_LEVELS)
    if len(rows) != expected_rows:
        raise RuntimeError(f"expected {expected_rows} classifier diagnostic rows; got {len(rows)}")
    return sorted(rows, key=lambda row: (int(row["sample_id"]), int(row["resource"])))


def validate_classifier_shapes(
    model: nn.Module, inputs: Tensor, test_ids: list[int], device: torch.device
) -> dict[int, tuple[int, ...]]:
    """Directly verify the V2 classifier remains batch x 10 at every resource level."""
    sample = inputs[test_ids[0]].unsqueeze(0).to(device)
    shapes: dict[int, tuple[int, ...]] = {}
    for resource in RESOURCE_LEVELS:
        if resource == FULL_RESOURCE_LEVEL:
            candidate = model
        else:
            candidate, _ = resource_reduced_model_v2(model, "classifier", resource, device)
        with torch.inference_mode():
            output = candidate(sample)
        shapes[resource] = tuple(output.shape)
        if output.ndim != 2 or output.shape[0] != 1 or output.shape[1] != 10:
            raise RuntimeError(f"classifier output is not (1, 10) at resource {resource}: {shapes[resource]}")
        if resource != FULL_RESOURCE_LEVEL:
            del candidate
    return shapes


def write_dataset(records: list[dict[str, Any]], output_dir: Path) -> tuple[Path, Path]:
    csv_path = output_dir / "quality_dataset_v2.csv"
    json_path = output_dir / "quality_dataset_v2.json"
    with csv_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(records)
    with json_path.open("w", encoding="utf-8") as stream:
        json.dump(records, stream, indent=2)
        stream.write("\n")
    return csv_path, json_path


def write_classifier_diagnostic(rows: list[dict[str, Any]], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=CLASSIFIER_DIAGNOSTIC_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def write_summary(
    path: Path,
    records: list[dict[str, Any]],
    layers: list[tuple[str, nn.Module]],
    violations: list[dict[str, Any]],
    old_means: dict[int, float],
    old_violations: int,
    classifier_rows: list[dict[str, Any]],
    shapes: dict[int, tuple[int, ...]],
) -> None:
    stats = degradation_statistics(records)
    violation_counts = dict(sorted(Counter(str(row["layer"]) for row in violations).items()))
    new_classifier_means = {
        resource: mean(
            float(row["actual_degradation"])
            for row in classifier_rows
            if int(row["resource"]) == resource
        )
        for resource in RESOURCE_LEVELS
    }
    classifier_module = dict(layers)["classifier"]
    assert isinstance(classifier_module, nn.Linear)
    classifier_input_indices = {
        resource: selected_evenly_spaced_indices(classifier_module.in_features, resource).tolist()
        for resource in RESOURCE_LEVELS
    }
    lines = [
        "Stage 2 V2 - Corrected Software Resource-Reduction Dataset",
        "===========================================================",
        "",
        "Scope",
        "-----",
        "V2 preserves the original experiment's seeded random model, seeded Gaussian inputs,",
        "pseudo-label procedure, monitored layers, resource levels, and measured-loss target.",
        "It changes only the terminal-classifier proxy rule. The original dataset and estimator",
        "remain unchanged; this file is a separate software-proxy experiment.",
        "",
        "Dataset",
        "-------",
        f"Rows: {len(records)}",
        f"Unique samples: {len({int(row['sample_id']) for row in records})}",
        f"Layers: {len(layers)} ({', '.join(name for name, _ in layers)})",
        f"Resource distribution: {dict(sorted(Counter(int(row['resource_level']) for row in records).items()))}",
        f"Proxy: {PROXY_NAME_V2}",
        "",
        "Measured degradation statistics",
        "-------------------------------",
        "resource  rows  mean_degradation  std_degradation  min_degradation  max_degradation",
    ]
    for row in stats:
        lines.append(
            f"{row['resource']:>8}  {row['rows']:>4}  {row['mean']:>16.8f}  {row['std']:>15.8f}  "
            f"{row['minimum']:>15.8f}  {row['maximum']:>15.8f}"
        )
    lines.extend(
        [
            "",
            "Classifier V2 mapping",
            "---------------------",
            "The classifier always retains all 10 output classes and its original bias.",
            "resource  retained input columns  retained input features  retained output features  output shape",
        ]
    )
    for resource in RESOURCE_LEVELS:
        lines.append(
            f"{resource:>8}  {classifier_input_indices[resource]}  "
            f"{len(classifier_input_indices[resource]):>23}  {10:>24}  {shapes[resource]}"
        )
    lines.extend(
        [
            "",
            "Actual monotonicity check",
            "--------------------------",
            "Expected ordering: D16 >= D32 >= D64. Values were not changed or sorted.",
            f"Relationship violations: {len(violations)}",
            f"Violations by layer: {violation_counts or 'none'}",
        ]
    )
    if violations:
        lines.append("sample_id  layer       relation     D16          D32          D64")
        for row in violations:
            lines.append(
                f"{int(row['sample_id']):>9}  {str(row['layer']):<10}  {str(row['relation']):<11}  "
                f"{float(row['D16']):>11.8f}  {float(row['D32']):>11.8f}  {float(row['D64']):>11.8f}"
            )
    lines.extend(
        [
            "",
            "Comparison with original output-logit proxy",
            "-------------------------------------------",
            "Original classifier: output rows/classes were retained at 16=2, 32=5, 64=10.",
            "V2 classifier: input columns are retained at 16=16, 32=32, 64=64; all 10 output rows remain.",
            "resource  old classifier mean degradation  V2 classifier mean degradation",
        ]
    )
    for resource in RESOURCE_LEVELS:
        lines.append(
            f"{resource:>8}  {old_means[resource]:>31.8f}  {new_classifier_means[resource]:>30.8f}"
        )
    lines.extend(
        [
            f"Original classifier monotonicity relationship violations (all 128 samples): {old_violations}",
            f"V2 monotonicity relationship violations (all layers, all 128 samples): {len(violations)}",
            "",
            "Limitations",
            "-----------",
            "This is still an offline/PyTorch software resource-reduction proxy. Resources 16/32/64",
            "are abstractions, not cycle-accurate PE counts. The V2 rule preserves classifier class",
            "semantics and reduces its MAC computation, but does not mathematically enforce monotonic",
            "loss. No hardware energy or latency claim is supported, and SCALE-Sim is deferred.",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def print_classifier_results(
    rows: list[dict[str, Any]], shapes: dict[int, tuple[int, ...]], violations: list[dict[str, Any]]
) -> None:
    grouped: dict[int, dict[int, dict[str, Any]]] = defaultdict(dict)
    for row in rows:
        grouped[int(row["sample_id"])][int(row["resource"])] = row
    print("\nClassifier direct degradation, all 19 held-out samples:")
    print("sample_id  D16         D32         D64")
    for sample_id in sorted(grouped):
        print(
            f"{sample_id:>9}  {float(grouped[sample_id][16]['actual_degradation']):>10.8f}  "
            f"{float(grouped[sample_id][32]['actual_degradation']):>10.8f}  "
            f"{float(grouped[sample_id][64]['actual_degradation']):>10.8f}"
        )
    means = {
        resource: mean(
            float(row["actual_degradation"])
            for row in rows
            if int(row["resource"]) == resource
        )
        for resource in RESOURCE_LEVELS
    }
    classifier_violations = [row for row in violations if row["layer"] == "classifier"]
    print(f"\nClassifier monotonicity violations: {len(classifier_violations)}")
    print(f"Average classifier D16: {means[16]:.8f}")
    print(f"Average classifier D32: {means[32]:.8f}")
    print(f"Average classifier D64: {means[64]:.8f}")
    print("Classifier output shape by resource:")
    for resource in RESOURCE_LEVELS:
        print(f"  {resource}: {shapes[resource]}")


def main() -> None:
    args = parse_args()
    if args.samples < 1 or args.batch_size < 1:
        raise ValueError("--samples and --batch-size must be positive")
    if args.device != "cpu" and not torch.cuda.is_available():
        raise ValueError(f"requested device {args.device!r}, but CUDA is not available")

    test_ids = held_out_sample_ids(args.model_metrics)
    if max(test_ids) >= args.samples:
        raise ValueError("held-out test IDs exceed --samples")
    torch.manual_seed(args.seed)
    device = torch.device(args.device)
    model = SimpleCNN().to(device).eval()
    # Match the original experiment: initialize model first, then draw all inputs.
    inputs = torch.randn(args.samples, 3, 32, 32)
    records, layers, _ = measured_dataset_v2(model, inputs, args.batch_size, device)
    violations = monotonicity_violations(records)
    classifier_rows = classifier_diagnostic_rows(records, test_ids)
    shapes = validate_classifier_shapes(model, inputs, test_ids, device)
    old_means, old_violations = old_classifier_statistics(args.old_dataset)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    dataset_csv, dataset_json = write_dataset(records, args.output_dir)
    summary_path = args.output_dir / "quality_dataset_v2_summary.txt"
    diagnostic_path = args.output_dir / "classifier_proxy_v2_diagnostic.csv"
    write_classifier_diagnostic(classifier_rows, diagnostic_path)
    write_summary(
        summary_path,
        records,
        layers,
        violations,
        old_means,
        old_violations,
        classifier_rows,
        shapes,
    )

    print("Stage 2 V2 - Corrected Software Resource-Reduction Dataset")
    print(f"Rows: {len(records)}; samples: {args.samples}; layers: {len(layers)}")
    print(f"Resource distribution: {dict(sorted(Counter(int(row['resource_level']) for row in records).items()))}")
    print_classifier_results(classifier_rows, shapes, violations)
    print("\nFiles created:")
    for path in (dataset_csv, dataset_json, summary_path, diagnostic_path):
        print(f"  {path}")


if __name__ == "__main__":
    main()
