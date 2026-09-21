"""Run the Stage-4 adaptive resource-controller software prototype.

For each held-out synthetic input, a PyTorch pre-layer hook measures compact
activation statistics before every Conv2d/Linear layer.  The already-trained
Random Forest estimates degradation at resource levels 16, 32, and 64, and the
controller chooses the smallest predicted-safe level.  The levels and the
underlying deterministic output-channel reduction are software abstractions;
this program neither runs SCALE-Sim nor makes hardware timing/energy claims.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import pickle
import sys
from collections import Counter
from pathlib import Path
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import torch
from matplotlib.colors import BoundaryNorm, ListedColormap


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PYTORCH_DIR = PROJECT_ROOT / "pytorch"
if str(PYTORCH_DIR) not in sys.path:
    sys.path.insert(0, str(PYTORCH_DIR))

from model import SimpleCNN  # noqa: E402
from monitor import LayerActivationMonitor  # noqa: E402


FEATURE_NAMES = ["sparsity", "mean", "variance", "layer_position", "resource_level"]
RESOURCE_LEVELS = (16, 32, 64)
DEFAULT_D_MAX = 0.05
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "results"
DECISION_FIELDS = [
    "sample_id",
    "layer",
    "sparsity",
    "mean",
    "variance",
    "layer_position",
    "predicted_D16",
    "predicted_D32",
    "predicted_D64",
    "selected_resource",
    "threshold",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument(
        "--metrics-path",
        type=Path,
        default=DEFAULT_OUTPUT_DIR / "model_metrics.json",
        help="Stage-3 metrics file used to obtain the group-safe test sample IDs",
    )
    parser.add_argument(
        "--baseline-metrics-path",
        type=Path,
        default=DEFAULT_OUTPUT_DIR / "baseline_metrics.json",
        help="Stage-2 metadata used to reproduce its synthetic sample count",
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
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--d-max", type=float, default=DEFAULT_D_MAX)
    parser.add_argument(
        "--representative-samples",
        type=int,
        default=4,
        help="number of held-out samples included in the degradation plot",
    )
    parser.add_argument("--device", default="cpu", help="PyTorch device (default: cpu)")
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"required file not found: {path}")
    with path.open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object in {path}")
    return value


def load_test_sample_ids(metrics_path: Path) -> list[int]:
    """Read the existing Stage-3 held-out IDs without touching the dataset."""
    metrics = read_json(metrics_path)
    try:
        raw_ids = metrics["split"]["sample_ids"]["test"]
    except (KeyError, TypeError) as error:
        raise ValueError(f"{metrics_path} does not contain split.sample_ids.test") from error
    if not isinstance(raw_ids, list) or not raw_ids:
        raise ValueError("the test sample-ID list must be a non-empty list")
    try:
        sample_ids = [int(value) for value in raw_ids]
    except (TypeError, ValueError) as error:
        raise ValueError("test sample IDs must be integers") from error
    if len(sample_ids) != len(set(sample_ids)) or min(sample_ids) < 0:
        raise ValueError("test sample IDs must be unique non-negative integers")
    return sample_ids


def load_synthetic_sample_count(baseline_metrics_path: Path) -> int:
    """Get the Stage-2 sample count needed for exact seeded reconstruction."""
    baseline_metrics = read_json(baseline_metrics_path)
    try:
        sample_count = int(baseline_metrics["number_of_samples"])
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError(
            f"{baseline_metrics_path} does not contain a valid number_of_samples"
        ) from error
    if sample_count < 1:
        raise ValueError("number_of_samples must be positive")
    return sample_count


def load_pickle(path: Path, description: str) -> Any:
    if not path.is_file():
        raise FileNotFoundError(f"{description} not found: {path}")
    with path.open("rb") as stream:
        return pickle.load(stream)


def validate_estimators(forest: Any, scaler: Any) -> None:
    """Check that the persisted Stage-3 artifacts match this controller input."""
    for description, estimator in (("Random Forest", forest), ("scaler", scaler)):
        feature_count = getattr(estimator, "n_features_in_", None)
        if feature_count != len(FEATURE_NAMES):
            raise ValueError(
                f"{description} expects {feature_count!r} features; expected {len(FEATURE_NAMES)}"
            )
    if not callable(getattr(forest, "predict", None)):
        raise TypeError("loaded Random Forest does not provide predict()")


def recreate_stage2_inputs(
    seed: int, sample_count: int, device: torch.device
) -> tuple[SimpleCNN, torch.Tensor]:
    """Recreate Stage 2's seeded model and Gaussian inputs without regenerating data files."""
    torch.manual_seed(seed)
    model = SimpleCNN().to(device).eval()
    # This sequence deliberately matches generate_quality_dataset.py: initialize
    # the model first, then draw all N(0,1) 32x32 RGB inputs.
    inputs = torch.randn(sample_count, 3, 32, 32)
    return model, inputs


def monitored_layer_names(model: torch.nn.Module) -> list[str]:
    names = [
        name
        for name, module in model.named_modules()
        if name and isinstance(module, (torch.nn.Conv2d, torch.nn.Linear))
    ]
    if not names:
        raise ValueError("model has no Conv2d or Linear layers to monitor")
    return names


def collect_sample_statistics(
    model: torch.nn.Module, sample: torch.Tensor, device: torch.device
) -> list[dict[str, Any]]:
    """Use the existing pre-layer monitor for one sample and retain only aggregates."""
    # Creating a fresh monitor for each sample prevents cross-sample aggregation.
    # LayerActivationMonitor stores sums/counts rather than activation tensors.
    with LayerActivationMonitor(model, position="pre") as monitor, torch.inference_mode():
        model(sample.unsqueeze(0).to(device))
    return monitor.summary()


def predict_degradations(
    forest: Any,
    sparsity: float,
    mean: float,
    variance: float,
    layer_position: float,
) -> dict[int, float]:
    """Predict D16/D32/D64 with raw Stage-3 RF features in their exact order."""
    features = np.asarray(
        [
            [sparsity, mean, variance, layer_position, resource_level]
            for resource_level in RESOURCE_LEVELS
        ],
        dtype=np.float64,
    )
    predictions = forest.predict(features)
    if len(predictions) != len(RESOURCE_LEVELS):
        raise RuntimeError("Random Forest did not return one prediction per resource level")
    values = {resource: float(value) for resource, value in zip(RESOURCE_LEVELS, predictions)}
    if not all(math.isfinite(value) for value in values.values()):
        raise RuntimeError("Random Forest produced a NaN or Inf prediction")
    return values


def select_resource(predicted: dict[int, float], threshold: float) -> int:
    """Return the minimum predicted-safe resource level; 64 is the fallback."""
    for resource_level in RESOURCE_LEVELS:
        if predicted[resource_level] <= threshold:
            return resource_level
    return 64


def build_decisions(
    model: torch.nn.Module,
    inputs: torch.Tensor,
    test_sample_ids: list[int],
    forest: Any,
    threshold: float,
    device: torch.device,
) -> list[dict[str, Any]]:
    layer_names = monitored_layer_names(model)
    if max(test_sample_ids) >= len(inputs):
        raise ValueError(
            "a Stage-3 test sample ID is outside the reconstructed Stage-2 input range"
        )

    rows: list[dict[str, Any]] = []
    for sample_id in test_sample_ids:
        statistics = collect_sample_statistics(model, inputs[sample_id], device)
        observed_names = [str(row["layer"]) for row in statistics]
        if observed_names != layer_names:
            raise RuntimeError(
                f"monitor layer order {observed_names} does not match model order {layer_names}"
            )
        for layer_index, stat in enumerate(statistics, start=1):
            sparsity = float(stat["sparsity"])
            mean = float(stat["mean"])
            variance = float(stat["variance"])
            if not all(math.isfinite(value) for value in (sparsity, mean, variance)):
                raise RuntimeError(f"non-finite activation statistic for sample {sample_id}")
            layer_position = layer_index / len(layer_names)
            predicted = predict_degradations(
                forest, sparsity, mean, variance, layer_position
            )
            rows.append(
                {
                    "sample_id": sample_id,
                    "layer": stat["layer"],
                    "sparsity": sparsity,
                    "mean": mean,
                    "variance": variance,
                    "layer_position": layer_position,
                    "predicted_D16": predicted[16],
                    "predicted_D32": predicted[32],
                    "predicted_D64": predicted[64],
                    "selected_resource": select_resource(predicted, threshold),
                    "threshold": threshold,
                }
            )
    expected_rows = len(test_sample_ids) * len(layer_names)
    if len(rows) != expected_rows:
        raise RuntimeError(f"expected {expected_rows} controller decisions, received {len(rows)}")
    return rows


def write_decisions(rows: list[dict[str, Any]], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=DECISION_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def selected_prediction(row: dict[str, Any]) -> float:
    return float(row[f"predicted_D{int(row['selected_resource'])}"])


def monotonicity_violations(rows: list[dict[str, Any]]) -> list[tuple[dict[str, Any], str]]:
    """Return all raw-prediction violations; predictions are never corrected."""
    violations: list[tuple[dict[str, Any], str]] = []
    for row in rows:
        d16 = float(row["predicted_D16"])
        d32 = float(row["predicted_D32"])
        d64 = float(row["predicted_D64"])
        if d16 < d32:
            violations.append((row, "D16 < D32"))
        if d32 < d64:
            violations.append((row, "D32 < D64"))
    return violations


def write_monotonicity_report(
    rows: list[dict[str, Any]], violations: list[tuple[dict[str, Any], str]], path: Path
) -> None:
    affected_decisions = {(int(row["sample_id"]), str(row["layer"])) for row, _ in violations}
    lines = [
        "Stage 4 - Random Forest prediction monotonicity report",
        "=" * 52,
        "Expected ordering for increasing resource is D16 >= D32 >= D64.",
        "Predictions below are raw Random Forest outputs and were not corrected.",
        f"Decisions checked: {len(rows)}",
        f"Relationship violations: {len(violations)}",
        f"Decisions with one or more violations: {len(affected_decisions)}",
        "",
    ]
    if violations:
        lines.append("sample_id  layer       violation    D16          D32          D64")
        for row, relationship in violations:
            lines.append(
                f"{int(row['sample_id']):>9}  {str(row['layer']):<10}  {relationship:<11}  "
                f"{float(row['predicted_D16']):>11.8f}  "
                f"{float(row['predicted_D32']):>11.8f}  "
                f"{float(row['predicted_D64']):>11.8f}"
            )
    else:
        lines.append("No monotonicity violations found.")
    lines.extend(
        [
            "",
            "Research limitation:",
            "  This is a PyTorch software controller.",
            "  16/32/64 are resource-level abstractions using the existing deterministic software proxy.",
            "  It is not cycle-accurate PE simulation and not a SCALE-Sim evaluation.",
            "  This experiment does not support hardware energy or latency claims.",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def plot_resource_allocation(rows: list[dict[str, Any]], path: Path) -> None:
    """Draw the selected resource level for every held-out sample/layer decision."""
    sample_ids = sorted({int(row["sample_id"]) for row in rows})
    layer_names = list(dict.fromkeys(str(row["layer"]) for row in rows))
    lookup = {(int(row["sample_id"]), str(row["layer"])): int(row["selected_resource"]) for row in rows}
    allocation = np.asarray(
        [[lookup[(sample_id, layer)] for layer in layer_names] for sample_id in sample_ids],
        dtype=np.int64,
    )

    figure, axis = plt.subplots(figsize=(8.2, 7.0), constrained_layout=True)
    colors = ListedColormap(["#2A9D8F", "#E9C46A", "#E76F51"])
    norm = BoundaryNorm([8, 24, 48, 72], colors.N)
    image = axis.imshow(allocation, aspect="auto", cmap=colors, norm=norm)
    axis.set_xticks(np.arange(len(layer_names)), layer_names)
    axis.set_yticks(np.arange(len(sample_ids)), sample_ids)
    axis.set_xlabel("Layer")
    axis.set_ylabel("Held-out sample ID")
    axis.set_title("Adaptive resource allocation across held-out samples and layers")
    for row_index, sample_id in enumerate(sample_ids):
        for column_index, layer in enumerate(layer_names):
            axis.text(
                column_index,
                row_index,
                str(lookup[(sample_id, layer)]),
                ha="center",
                va="center",
                fontsize=8,
            )
    colorbar = figure.colorbar(image, ax=axis, ticks=RESOURCE_LEVELS)
    colorbar.set_label("Selected resource level")
    figure.savefig(path, dpi=180)
    plt.close(figure)


def plot_predicted_degradation(
    rows: list[dict[str, Any]], representative_count: int, threshold: float, path: Path
) -> list[int]:
    """Plot D16/D32/D64 curves for several held-out samples, with the D_MAX line."""
    sample_ids = sorted({int(row["sample_id"]) for row in rows})
    representative_ids = sample_ids[: min(representative_count, len(sample_ids))]
    layer_names = list(dict.fromkeys(str(row["layer"]) for row in rows))
    columns = min(2, len(representative_ids))
    plot_rows = math.ceil(len(representative_ids) / columns)
    figure, axes = plt.subplots(
        plot_rows,
        columns,
        figsize=(6.4 * columns, 4.5 * plot_rows),
        squeeze=False,
        constrained_layout=True,
    )
    lookup = {(int(row["sample_id"]), str(row["layer"])): row for row in rows}
    for axis, sample_id in zip(axes.flat, representative_ids):
        for layer in layer_names:
            row = lookup[(sample_id, layer)]
            axis.plot(
                RESOURCE_LEVELS,
                [
                    float(row["predicted_D16"]),
                    float(row["predicted_D32"]),
                    float(row["predicted_D64"]),
                ],
                marker="o",
                linewidth=1.8,
                label=layer,
            )
        axis.axhline(threshold, color="black", linestyle="--", linewidth=1.2, label="D_MAX")
        axis.set_xticks(RESOURCE_LEVELS)
        axis.set_xlabel("Candidate resource level")
        axis.set_ylabel("Predicted degradation")
        axis.set_title(f"Sample {sample_id}")
        axis.grid(alpha=0.25)
        axis.legend(fontsize=8)
    for axis in axes.flat[len(representative_ids) :]:
        axis.set_visible(False)
    figure.suptitle("Predicted degradation versus resource level", fontsize=14)
    figure.savefig(path, dpi=180)
    plt.close(figure)
    return representative_ids


def print_decision_summary(rows: list[dict[str, Any]], violations: list[tuple[dict[str, Any], str]]) -> None:
    counts = Counter(int(row["selected_resource"]) for row in rows)
    selected_values = [selected_prediction(row) for row in rows]
    candidate_values = [
        float(row[column])
        for row in rows
        for column in ("predicted_D16", "predicted_D32", "predicted_D64")
    ]
    threshold_violations = [row for row in rows if selected_prediction(row) > float(row["threshold"])]
    layer_count = len({str(row["layer"]) for row in rows})
    print("\nController decisions:")
    print("Sample  Layer       Sparsity    Mean        Variance    D16         D32         D64         Selected")
    for row in rows:
        print(
            f"{int(row['sample_id']):>6}  {str(row['layer']):<10}  "
            f"{float(row['sparsity']):>8.5f}  {float(row['mean']):>10.6f}  "
            f"{float(row['variance']):>10.6f}  {float(row['predicted_D16']):>10.6f}  "
            f"{float(row['predicted_D32']):>10.6f}  {float(row['predicted_D64']):>10.6f}  "
            f"{int(row['selected_resource']):>8}"
        )
    print("\nExecution summary:")
    print(f"  Number of distinct layers evaluated: {layer_count}")
    print(f"  Total decisions: {len(rows)}")
    print(f"  16-resource decisions: {counts[16]}")
    print(f"  32-resource decisions: {counts[32]}")
    print(f"  64-resource decisions: {counts[64]}")
    print(f"  Average predicted degradation (all candidates): {np.mean(candidate_values):.8f}")
    print(f"  Maximum predicted degradation (all candidates): {np.max(candidate_values):.8f}")
    print(f"  Average predicted degradation (selected resource): {np.mean(selected_values):.8f}")
    print(f"  Maximum predicted degradation (selected resource): {np.max(selected_values):.8f}")
    print(f"  Threshold violations after selection: {len(threshold_violations)}")
    print(f"  Monotonicity violations: {len(violations)}")


def main() -> None:
    args = parse_args()
    if not math.isfinite(args.d_max):
        raise ValueError("--d-max must be finite")
    if args.representative_samples < 1:
        raise ValueError("--representative-samples must be positive")
    if args.device != "cpu" and not torch.cuda.is_available():
        raise ValueError(f"requested device {args.device!r}, but CUDA is not available")

    test_sample_ids = load_test_sample_ids(args.metrics_path)
    sample_count = load_synthetic_sample_count(args.baseline_metrics_path)
    forest = load_pickle(args.forest_path, "trained Random Forest")
    # The scaler is persisted alongside the forest by Stage 3.  It is loaded
    # and validated for artifact consistency, but RF training used raw inputs.
    scaler = load_pickle(args.scaler_path, "quality-estimator scaler")
    validate_estimators(forest, scaler)

    device = torch.device(args.device)
    model, inputs = recreate_stage2_inputs(args.seed, sample_count, device)
    decisions = build_decisions(model, inputs, test_sample_ids, forest, args.d_max, device)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    decisions_path = args.output_dir / "adaptive_resource_decisions.csv"
    allocation_path = args.output_dir / "adaptive_resource_allocation.png"
    degradation_path = args.output_dir / "predicted_degradation_vs_resource.png"
    monotonicity_path = args.output_dir / "prediction_monotonicity_report.txt"
    write_decisions(decisions, decisions_path)
    violations = monotonicity_violations(decisions)
    write_monotonicity_report(decisions, violations, monotonicity_path)
    plot_resource_allocation(decisions, allocation_path)
    representative_ids = plot_predicted_degradation(
        decisions, args.representative_samples, args.d_max, degradation_path
    )

    print("Stage 4 - Adaptive Resource Controller Software Prototype")
    print(f"Held-out test samples: {len(test_sample_ids)} ({', '.join(map(str, test_sample_ids))})")
    print(f"Random Forest feature order: {', '.join(FEATURE_NAMES)}")
    print("Random Forest input scaling: raw features (matches Stage-3 RF training).")
    print(f"D_MAX: {args.d_max:.6f}")
    print_decision_summary(decisions, violations)
    print(f"Representative samples plotted: {', '.join(map(str, representative_ids))}")
    print("\nResearch limitation: PyTorch software controller; resource levels are abstractions")
    print("using the existing deterministic proxy. This is neither cycle-accurate PE simulation")
    print("nor SCALE-Sim evaluation, and it does not support hardware energy/latency claims.")
    print("\nCreated files:")
    for path in (decisions_path, allocation_path, degradation_path, monotonicity_path):
        print(f"  {path}")


if __name__ == "__main__":
    main()
