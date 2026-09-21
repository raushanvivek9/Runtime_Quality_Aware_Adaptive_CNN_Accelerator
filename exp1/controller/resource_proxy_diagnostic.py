"""Diagnose Stage-4.5 resource-proxy monotonicity without changing prior stages.

This script directly executes the existing deterministic resource-reduction
proxy from Stage 2.  It does not retrain the Random Forest, regenerate the
quality dataset, change the Stage-4 controller, or invoke SCALE-Sim.  The
result is a diagnostic comparison of actual software-proxy degradation with
the persisted Random Forest predictions.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import pickle
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

import numpy as np
import torch
from torch.nn import functional as F


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PYTORCH_DIR = PROJECT_ROOT / "pytorch"
if str(PYTORCH_DIR) not in sys.path:
    sys.path.insert(0, str(PYTORCH_DIR))

from generate_quality_dataset import (  # noqa: E402
    RESOURCE_LEVELS,
    evaluate_logits,
    resource_reduced_model,
    selected_output_indices,
)
from model import SimpleCNN  # noqa: E402


FEATURE_NAMES = ("sparsity", "mean", "variance", "layer_position", "resource_level")
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "results"
DEFAULT_SEED = 42
DEFAULT_BATCH_SIZE = 16
CSV_FIELDS = [
    "sample_id",
    "layer",
    "resource",
    "original_size",
    "retained_size",
    "retained_fraction",
    "actual_loss",
    "actual_degradation",
    "predicted_degradation",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument(
        "--metrics-path", type=Path, default=DEFAULT_OUTPUT_DIR / "model_metrics.json"
    )
    parser.add_argument(
        "--baseline-metrics-path",
        type=Path,
        default=DEFAULT_OUTPUT_DIR / "baseline_metrics.json",
    )
    parser.add_argument(
        "--decisions-path",
        type=Path,
        default=DEFAULT_OUTPUT_DIR / "adaptive_resource_decisions.csv",
        help="Stage-4 rows that provide pre-layer features for RF comparison",
    )
    parser.add_argument(
        "--forest-path",
        type=Path,
        default=DEFAULT_OUTPUT_DIR / "quality_estimator_rf.pkl",
    )
    parser.add_argument(
        "--scaler-path",
        type=Path,
        default=DEFAULT_OUTPUT_DIR / "quality_estimator_scaler.pkl",
    )
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--device", default="cpu", help="PyTorch device (default: cpu)")
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"required file not found: {path}")
    with path.open(encoding="utf-8") as stream:
        data = json.load(stream)
    if not isinstance(data, dict):
        raise ValueError(f"expected a JSON object in {path}")
    return data


def test_sample_ids(metrics_path: Path) -> list[int]:
    metrics = read_json(metrics_path)
    try:
        values = metrics["split"]["sample_ids"]["test"]
        sample_ids = [int(value) for value in values]
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError(f"{metrics_path} lacks valid split.sample_ids.test") from error
    if not sample_ids or min(sample_ids) < 0 or len(sample_ids) != len(set(sample_ids)):
        raise ValueError("test sample IDs must be unique, non-negative, and non-empty")
    return sample_ids


def synthetic_sample_count(baseline_metrics_path: Path) -> int:
    baseline = read_json(baseline_metrics_path)
    try:
        count = int(baseline["number_of_samples"])
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError(f"{baseline_metrics_path} lacks a valid number_of_samples") from error
    if count < 1:
        raise ValueError("number_of_samples must be positive")
    return count


def load_pickle(path: Path, description: str) -> Any:
    if not path.is_file():
        raise FileNotFoundError(f"{description} not found: {path}")
    with path.open("rb") as stream:
        return pickle.load(stream)


def validate_artifacts(forest: Any, scaler: Any) -> None:
    for name, artifact in (("Random Forest", forest), ("scaler", scaler)):
        feature_count = getattr(artifact, "n_features_in_", None)
        if feature_count != len(FEATURE_NAMES):
            raise ValueError(
                f"{name} expects {feature_count!r} input features, not {len(FEATURE_NAMES)}"
            )
    if not callable(getattr(forest, "predict", None)):
        raise TypeError("the saved Random Forest does not provide predict()")


def decision_features(path: Path) -> dict[tuple[int, str], dict[str, float]]:
    """Read only Stage-4 aggregate features; no stored activations are used."""
    # Stage 4 stores the four observed features.  ``resource_level`` is a
    # candidate supplied below for each direct 16/32/64 comparison.
    required = {"sample_id", "layer", "sparsity", "mean", "variance", "layer_position"}
    if not path.is_file():
        raise FileNotFoundError(f"Stage-4 decisions not found: {path}")
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        columns = set(reader.fieldnames or [])
        missing = required - columns
        if missing:
            raise ValueError(f"{path} is missing columns: {sorted(missing)}")
        features: dict[tuple[int, str], dict[str, float]] = {}
        for line_number, row in enumerate(reader, start=2):
            try:
                key = (int(row["sample_id"]), str(row["layer"]))
                values = {
                    name: float(row[name])
                    for name in ("sparsity", "mean", "variance", "layer_position")
                }
            except (KeyError, TypeError, ValueError) as error:
                raise ValueError(f"invalid feature row at line {line_number}") from error
            if key in features:
                raise ValueError(f"duplicate Stage-4 feature row for {key}")
            if not all(math.isfinite(value) for value in values.values()):
                raise ValueError(f"non-finite Stage-4 feature row for {key}")
            features[key] = values
    if not features:
        raise ValueError("Stage-4 decisions file is empty")
    return features


def recreate_stage2_model_and_inputs(
    seed: int, sample_count: int, device: torch.device
) -> tuple[SimpleCNN, torch.Tensor]:
    """Match Stage 2's sequence: seeded model initialization then seeded inputs."""
    torch.manual_seed(seed)
    model = SimpleCNN().to(device).eval()
    return model, torch.randn(sample_count, 3, 32, 32)


def proxy_mapping(model: torch.nn.Module) -> list[dict[str, Any]]:
    """Describe exact source-layer output retention selected by the existing proxy."""
    rows: list[dict[str, Any]] = []
    for layer, module in model.named_modules():
        if isinstance(module, torch.nn.Conv2d):
            original_size = module.out_channels
            layer_type = "Conv2d"
        elif isinstance(module, torch.nn.Linear):
            original_size = module.out_features
            layer_type = "Linear"
        else:
            continue
        for resource in RESOURCE_LEVELS:
            indices = selected_output_indices(original_size, resource)
            rows.append(
                {
                    "layer": layer,
                    "layer_type": layer_type,
                    "resource": int(resource),
                    "original_size": original_size,
                    "retained_size": int(indices.numel()),
                    "retained_fraction": float(indices.numel() / original_size),
                    "indices": indices.tolist(),
                }
            )
    if not rows:
        raise ValueError("no Conv2d or Linear layers were found")
    return rows


def predict_degradation(forest: Any, features: dict[str, float], resource: int) -> float:
    candidate = np.asarray(
        [
            [
                features["sparsity"],
                features["mean"],
                features["variance"],
                features["layer_position"],
                resource,
            ]
        ],
        dtype=np.float64,
    )
    prediction = float(forest.predict(candidate)[0])
    if not math.isfinite(prediction):
        raise RuntimeError("Random Forest produced a NaN or Inf prediction")
    return prediction


def direct_proxy_experiment(
    model: torch.nn.Module,
    inputs: torch.Tensor,
    sample_ids: list[int],
    feature_rows: dict[tuple[int, str], dict[str, float]],
    forest: Any,
    device: torch.device,
    batch_size: int,
) -> tuple[list[dict[str, Any]], torch.Tensor]:
    """Measure loss changes using the unmodified Stage-2 proxy, not the RF."""
    if max(sample_ids) >= len(inputs):
        raise ValueError("a held-out sample ID is outside the reconstructed input range")
    layer_modules = {
        name: module
        for name, module in model.named_modules()
        if name and isinstance(module, (torch.nn.Conv2d, torch.nn.Linear))
    }
    missing_features = {
        (sample_id, layer)
        for sample_id in sample_ids
        for layer in layer_modules
        if (sample_id, layer) not in feature_rows
    }
    if missing_features:
        raise ValueError(f"Stage-4 feature rows missing for: {sorted(missing_features)}")

    baseline_logits = evaluate_logits(model, inputs, batch_size, device)
    pseudo_labels = baseline_logits.argmax(dim=1)
    baseline_losses = F.cross_entropy(baseline_logits, pseudo_labels, reduction="none")
    records: list[dict[str, Any]] = []
    for layer, module in layer_modules.items():
        original_size = module.out_channels if isinstance(module, torch.nn.Conv2d) else module.out_features
        for resource in RESOURCE_LEVELS:
            indices = selected_output_indices(original_size, resource)
            if resource == 64:
                reduced_logits = baseline_logits
            else:
                reduced_model, _ = resource_reduced_model(model, layer, resource, device)
                reduced_logits = evaluate_logits(reduced_model, inputs, batch_size, device)
                del reduced_model
            reduced_losses = F.cross_entropy(reduced_logits, pseudo_labels, reduction="none")
            for sample_id in sample_ids:
                features = feature_rows[(sample_id, layer)]
                actual_loss = float(reduced_losses[sample_id].item())
                baseline_loss = float(baseline_losses[sample_id].item())
                records.append(
                    {
                        "sample_id": sample_id,
                        "layer": layer,
                        "resource": int(resource),
                        "original_size": original_size,
                        "retained_size": int(indices.numel()),
                        "retained_fraction": float(indices.numel() / original_size),
                        "actual_loss": actual_loss,
                        "actual_degradation": actual_loss - baseline_loss,
                        "predicted_degradation": predict_degradation(forest, features, int(resource)),
                        "baseline_loss": baseline_loss,
                    }
                )
    return records, pseudo_labels


def groups(records: list[dict[str, Any]]) -> dict[tuple[int, str], dict[int, dict[str, Any]]]:
    grouped: dict[tuple[int, str], dict[int, dict[str, Any]]] = defaultdict(dict)
    for record in records:
        key = (int(record["sample_id"]), str(record["layer"]))
        resource = int(record["resource"])
        if resource in grouped[key]:
            raise ValueError(f"duplicate diagnostic record for {key}, resource {resource}")
        grouped[key][resource] = record
    for key, values in grouped.items():
        if set(values) != set(RESOURCE_LEVELS):
            raise ValueError(f"diagnostic records missing a resource level for {key}")
    return grouped


def monotonicity_violations(
    grouped: dict[tuple[int, str], dict[int, dict[str, Any]]], value_name: str
) -> list[dict[str, Any]]:
    violations: list[dict[str, Any]] = []
    for (sample_id, layer), values in sorted(grouped.items()):
        d16 = float(values[16][value_name])
        d32 = float(values[32][value_name])
        d64 = float(values[64][value_name])
        if d16 < d32:
            violations.append(
                {
                    "sample_id": sample_id,
                    "layer": layer,
                    "relation": "D16 < D32",
                    "D16": d16,
                    "D32": d32,
                    "D64": d64,
                }
            )
        if d32 < d64:
            violations.append(
                {
                    "sample_id": sample_id,
                    "layer": layer,
                    "relation": "D32 < D64",
                    "D16": d16,
                    "D32": d32,
                    "D64": d64,
                }
            )
    return violations


def monotonicity_by_layer(violations: list[dict[str, Any]]) -> dict[str, int]:
    return dict(sorted(Counter(str(row["layer"]) for row in violations).items()))


def write_csv(records: list[dict[str, Any]], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(
            {name: record[name] for name in CSV_FIELDS}
            for record in sorted(records, key=lambda row: (int(row["sample_id"]), str(row["layer"]), int(row["resource"])))
        )


def violation_lines(violations: list[dict[str, Any]]) -> list[str]:
    if not violations:
        return ["  None."]
    lines = ["  sample_id  layer       relation     D16          D32          D64"]
    for row in violations:
        lines.append(
            f"  {int(row['sample_id']):>9}  {str(row['layer']):<10}  {str(row['relation']):<11}  "
            f"{float(row['D16']):>11.8f}  {float(row['D32']):>11.8f}  {float(row['D64']):>11.8f}"
        )
    return lines


def classifier_table(
    grouped: dict[tuple[int, str], dict[int, dict[str, Any]]]
) -> list[str]:
    lines = [
        "sample_id  resource  baseline_loss  actual_loss  actual_degradation  predicted_degradation"
    ]
    for sample_id, layer in sorted(grouped):
        if layer != "classifier":
            continue
        for resource in RESOURCE_LEVELS:
            row = grouped[(sample_id, layer)][resource]
            lines.append(
                f"{sample_id:>9}  {resource:>8}  {float(row['baseline_loss']):>13.8f}  "
                f"{float(row['actual_loss']):>11.8f}  {float(row['actual_degradation']):>18.8f}  "
                f"{float(row['predicted_degradation']):>21.8f}"
            )
    return lines


def mapping_lines(mapping: list[dict[str, Any]]) -> list[str]:
    lines = ["layer       type    resource  original  retained  fraction  selected output indices"]
    for row in mapping:
        lines.append(
            f"{str(row['layer']):<10}  {str(row['layer_type']):<6}  {int(row['resource']):>8}  "
            f"{int(row['original_size']):>8}  {int(row['retained_size']):>8}  "
            f"{float(row['retained_fraction']):>8.3f}  {row['indices']}"
        )
    return lines


def root_cause_lines(
    labels: torch.Tensor,
    sample_ids: list[int],
    mapping: list[dict[str, Any]],
    actual_violations: list[dict[str, Any]],
    predicted_violations: list[dict[str, Any]],
) -> list[str]:
    classifier_mapping = {
        int(row["resource"]): row
        for row in mapping
        if row["layer"] == "classifier"
    }
    held_out_labels = [int(labels[sample_id].item()) for sample_id in sample_ids]
    label_counts = dict(sorted(Counter(held_out_labels).items()))
    retained_target_counts = {
        resource: sum(label in set(classifier_mapping[resource]["indices"]) for label in held_out_labels)
        for resource in RESOURCE_LEVELS
    }
    actual_classifier = [row for row in actual_violations if row["layer"] == "classifier"]
    predicted_classifier = [row for row in predicted_violations if row["layer"] == "classifier"]
    return [
        "Root-cause evidence",
        "-------------------",
        f"Held-out baseline pseudo-label distribution: {label_counts}",
        "Classifier selected output indices: "
        + ", ".join(
            f"{resource} -> {classifier_mapping[resource]['indices']}"
            for resource in RESOURCE_LEVELS
        ),
        "Held-out targets retained by classifier proxy: "
        + ", ".join(
            f"{resource} -> {retained_target_counts[resource]}/{len(held_out_labels)}"
            for resource in RESOURCE_LEVELS
        ),
        f"Actual classifier relationship violations: {len(actual_classifier)}",
        f"RF classifier relationship violations: {len(predicted_classifier)}",
        "",
        "The source implementation is functioning as written: its resource level maps to",
        "the number of *output* features. For the terminal Linear layer, output features",
        "are class logits. At 16 and 32 resources, omitted logits are replaced by exact",
        "zeros, including every held-out target logit when the retained-target count is zero.",
        "The remaining non-target logits differ between 16 and 32, changing the softmax",
        "denominator while the target logit remains zero. Cross-entropy can therefore be",
        "higher at 32 than at 16. This is an actual proxy behavior, not a correction made",
        "or invented by the Random Forest. It is a semantic mismatch in applying an",
        "output-channel-masking proxy to a final classifier, not an arithmetic error in",
        "the selected-index formula or loss calculation.",
        "",
        "Proposed correction (not implemented)",
        "-------------------------------------",
        "Keep all classifier output logits/classes, and reduce classifier computation by",
        "selecting input-feature columns instead. For this 64-input, 10-output Linear",
        "layer, use 16, 32, and 64 evenly spaced input features respectively; apply the",
        "corresponding weight columns to the selected activation features, while retaining",
        "all ten weight rows and the original bias. This reduces classifier MACs without",
        "removing class semantics or zeroing a target logit. It makes larger resource",
        "levels algorithmically meaningful; it does not mathematically force monotonic",
        "loss. Because it changes the proxy definition, it would require a new dataset and",
        "estimator training in a later, explicitly authorized stage. No correction is",
        "implemented by this diagnostic.",
    ]


def write_report(
    path: Path,
    mapping: list[dict[str, Any]],
    grouped: dict[tuple[int, str], dict[int, dict[str, Any]]],
    labels: torch.Tensor,
    sample_ids: list[int],
    actual_violations: list[dict[str, Any]],
    predicted_violations: list[dict[str, Any]],
) -> None:
    actual_by_layer = monotonicity_by_layer(actual_violations)
    predicted_by_layer = monotonicity_by_layer(predicted_violations)
    lines = [
        "Stage 4.5 - Resource Proxy Diagnostic",
        "======================================",
        "",
        "Scope",
        "-----",
        "This diagnostic directly runs the existing Stage-2 deterministic software proxy.",
        "It does not retrain the Random Forest, regenerate the quality dataset, modify the",
        "Stage-4 controller threshold, modify the existing monitor, or run SCALE-Sim.",
        "",
        "Current proxy implementation",
        "----------------------------",
        "selected_output_indices(total_outputs, resource) computes:",
        "  retained = min(max(1, round(total_outputs * resource / 64)), total_outputs)",
        "  selected[k] = floor(k * total_outputs / retained), for k = 0..retained-1",
        "",
        "Conv2d: the proxy selects filter rows and bias elements for the chosen output",
        "channels, runs F.conv2d only for those channels, creates a zero tensor with the",
        "full output shape, then index-copies the computed channels into it. Omitted output",
        "channels are exactly zero.",
        "",
        "Linear: the proxy selects weight rows and bias elements for chosen output features,",
        "runs F.linear only for those features, creates a zero tensor with the full output",
        "shape, then index-copies computed features into it. For classifier, these output",
        "features are class logits; omitted class logits are exactly zero.",
        "",
        "Retained output mapping",
        "-----------------------",
        *mapping_lines(mapping),
        "",
        "Direct classifier experiment (all 19 held-out samples; no Random Forest for actual loss)",
        "------------------------------------------------------------------------------------------",
        *classifier_table(grouped),
        "",
        "A. Actual degradation monotonicity",
        "----------------------------------",
        "Expected order: D16 >= D32 >= D64.",
        f"Relationship violations: {len(actual_violations)}",
        f"Violations by layer: {actual_by_layer or 'none'}",
        *violation_lines(actual_violations),
        "",
        "B. Random Forest predicted degradation monotonicity",
        "----------------------------------------------------",
        "Predictions use the unmodified persisted RF and raw feature order:",
        "[sparsity, mean, variance, layer_position, resource_level].",
        f"Relationship violations: {len(predicted_violations)}",
        f"Violations by layer: {predicted_by_layer or 'none'}",
        *violation_lines(predicted_violations),
        "",
        *root_cause_lines(labels, sample_ids, mapping, actual_violations, predicted_violations),
        "",
        "Research limitation",
        "-------------------",
        "This remains an offline/PyTorch software diagnostic. Resources 16/32/64 are",
        "abstractions, not cycle-accurate PE counts. No hardware energy or latency claim",
        "can be made from this result, and SCALE-Sim is intentionally deferred.",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    args = parse_args()
    if args.batch_size < 1:
        raise ValueError("--batch-size must be positive")
    if args.device != "cpu" and not torch.cuda.is_available():
        raise ValueError(f"requested device {args.device!r}, but CUDA is not available")

    sample_ids = test_sample_ids(args.metrics_path)
    feature_rows = decision_features(args.decisions_path)
    forest = load_pickle(args.forest_path, "trained Random Forest")
    scaler = load_pickle(args.scaler_path, "quality-estimator scaler")
    validate_artifacts(forest, scaler)
    device = torch.device(args.device)
    model, inputs = recreate_stage2_model_and_inputs(
        args.seed, synthetic_sample_count(args.baseline_metrics_path), device
    )
    mapping = proxy_mapping(model)
    records, labels = direct_proxy_experiment(
        model, inputs, sample_ids, feature_rows, forest, device, args.batch_size
    )
    grouped = groups(records)
    actual_violations = monotonicity_violations(grouped, "actual_degradation")
    predicted_violations = monotonicity_violations(grouped, "predicted_degradation")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    csv_path = args.output_dir / "resource_proxy_diagnostic.csv"
    report_path = args.output_dir / "resource_proxy_diagnostic.txt"
    write_csv(records, csv_path)
    write_report(
        report_path,
        mapping,
        grouped,
        labels,
        sample_ids,
        actual_violations,
        predicted_violations,
    )

    print("Stage 4.5 - Resource Proxy Diagnostic")
    print(f"Held-out samples evaluated: {len(sample_ids)}")
    print(f"Direct proxy records: {len(records)}")
    print(f"Actual monotonicity violations: {len(actual_violations)}")
    print(f"Random Forest monotonicity violations: {len(predicted_violations)}")
    print(f"Actual violations by layer: {monotonicity_by_layer(actual_violations) or 'none'}")
    print(f"RF violations by layer: {monotonicity_by_layer(predicted_violations) or 'none'}")
    print("Created files:")
    print(f"  {csv_path}")
    print(f"  {report_path}")


if __name__ == "__main__":
    main()
