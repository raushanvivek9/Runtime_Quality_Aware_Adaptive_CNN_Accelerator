"""Train Stage 3 V2 quality estimators from the corrected V2 proxy dataset.

This is an offline PyTorch/software-proxy experiment only.  It reads
``quality_dataset_v2.csv`` and writes separate ``*_v2`` model, metric, plot,
selection, and report artifacts.  It never changes the original dataset,
estimators, Stage-4 controller, monitor, or SCALE-Sim.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import pickle
import random
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Callable

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import torch
from matplotlib.colors import BoundaryNorm, ListedColormap
from sklearn.ensemble import RandomForestRegressor
from sklearn.linear_model import LinearRegression
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.preprocessing import StandardScaler
from torch import nn


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "results"
DEFAULT_DATASET_PATH = DEFAULT_OUTPUT_DIR / "quality_dataset_v2.csv"
FEATURE_NAMES = ["sparsity", "mean", "variance", "layer_position", "resource_level"]
TARGET_NAME = "degradation"
RESOURCE_LEVELS = (16, 32, 64)
DEFAULT_D_MAX = 0.05
V2_PROXY_PREFIX = "v2_"
EXCLUDED_FEATURES = [
    "baseline_loss",
    "reduced_loss",
    "baseline_correct",
    "reduced_correct",
    "sample_id",
]
SELECTION_FIELDS = [
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


class SmallMLP(nn.Module):
    """The requested 5 -> 16 -> 8 -> 1 regression architecture."""

    def __init__(self) -> None:
        super().__init__()
        self.network = nn.Sequential(
            nn.Linear(5, 16),
            nn.ReLU(),
            nn.Linear(16, 8),
            nn.ReLU(),
            nn.Linear(8, 1),
        )

    def forward(self, values: torch.Tensor) -> torch.Tensor:
        return self.network(values)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET_PATH)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--epochs", type=int, default=500)
    parser.add_argument("--patience", type=int, default=60)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--d-max", type=float, default=DEFAULT_D_MAX)
    return parser.parse_args()


def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.use_deterministic_algorithms(True)


def read_v2_dataset(path: Path) -> tuple[np.ndarray, np.ndarray, list[dict[str, Any]]]:
    """Read V2 features/targets and reject the original non-V2 dataset."""
    if not path.is_file():
        raise FileNotFoundError(f"V2 dataset not found: {path}")
    required = {
        *FEATURE_NAMES,
        TARGET_NAME,
        "sample_id",
        "layer",
        "resource_reduction_proxy",
        "retained_input_features",
        "retained_output_features",
    }
    features: list[list[float]] = []
    targets: list[float] = []
    metadata: list[dict[str, Any]] = []
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise ValueError(
                f"{path} is not the required V2 schema; missing {sorted(missing)}"
            )
        for line_number, row in enumerate(reader, start=2):
            try:
                proxy_name = str(row["resource_reduction_proxy"])
                values = [float(row[name]) for name in FEATURE_NAMES]
                target = float(row[TARGET_NAME])
                sample_id = int(row["sample_id"])
                resource = int(row["resource_level"])
            except (KeyError, TypeError, ValueError) as error:
                raise ValueError(f"invalid row at line {line_number}") from error
            if not proxy_name.startswith(V2_PROXY_PREFIX):
                raise ValueError(
                    f"{path} contains non-V2 proxy data at line {line_number}: {proxy_name!r}"
                )
            if resource not in RESOURCE_LEVELS:
                raise ValueError(f"invalid resource level {resource} at line {line_number}")
            if not all(math.isfinite(value) for value in [*values, target]):
                raise ValueError(f"non-finite feature/target at line {line_number}")
            features.append(values)
            targets.append(target)
            metadata.append(
                {
                    "sample_id": sample_id,
                    "layer": str(row["layer"]),
                    "module_type": str(row.get("module_type", "")),
                    "resource_level": resource,
                }
            )
    if not features:
        raise ValueError("V2 dataset is empty")
    return np.asarray(features, dtype=np.float64), np.asarray(targets, dtype=np.float64), metadata


def split_by_sample_id(metadata: list[dict[str, Any]], seed: int) -> dict[str, np.ndarray]:
    """Create a deterministic 70/15/15 group split with no sample overlap."""
    sample_ids = np.asarray(sorted({int(row["sample_id"]) for row in metadata}), dtype=np.int64)
    if len(sample_ids) < 7:
        raise ValueError("at least seven sample IDs are required")
    shuffled = sample_ids.copy()
    np.random.default_rng(seed).shuffle(shuffled)
    train_count = round(0.70 * len(shuffled))
    validation_count = round(0.15 * len(shuffled))
    split_ids = {
        "train": set(shuffled[:train_count].tolist()),
        "validation": set(shuffled[train_count : train_count + validation_count].tolist()),
        "test": set(shuffled[train_count + validation_count :].tolist()),
    }
    if any(not ids for ids in split_ids.values()):
        raise ValueError("the split contains an empty partition")
    if split_ids["train"] & split_ids["validation"] or split_ids["train"] & split_ids["test"]:
        raise RuntimeError("sample IDs overlap between train and another split")
    if split_ids["validation"] & split_ids["test"]:
        raise RuntimeError("sample IDs overlap between validation and test")
    return {
        split: np.asarray(
            [index for index, row in enumerate(metadata) if row["sample_id"] in ids],
            dtype=np.int64,
        )
        for split, ids in split_ids.items()
    }


def regression_metrics(actual: np.ndarray, predicted: np.ndarray) -> dict[str, float]:
    return {
        "mae": float(mean_absolute_error(actual, predicted)),
        "rmse": float(np.sqrt(mean_squared_error(actual, predicted))),
        "r2": float(r2_score(actual, predicted)),
    }


def train_mlp(
    x_train: np.ndarray,
    y_train: np.ndarray,
    x_validation: np.ndarray,
    y_validation: np.ndarray,
    args: argparse.Namespace,
) -> tuple[SmallMLP, dict[str, float | int]]:
    model = SmallMLP()
    optimizer = torch.optim.Adam(model.parameters(), lr=args.learning_rate)
    loss_function = nn.MSELoss()
    train_x = torch.from_numpy(x_train.astype(np.float32))
    train_y = torch.from_numpy(y_train.astype(np.float32)).unsqueeze(1)
    validation_x = torch.from_numpy(x_validation.astype(np.float32))
    validation_y = torch.from_numpy(y_validation.astype(np.float32)).unsqueeze(1)
    best_state = {name: value.detach().clone() for name, value in model.state_dict().items()}
    best_validation_mse = float("inf")
    best_epoch = 0
    stale_epochs = 0
    for epoch in range(1, args.epochs + 1):
        model.train()
        order = torch.randperm(len(train_x))
        for start in range(0, len(train_x), args.batch_size):
            indices = order[start : start + args.batch_size]
            loss = loss_function(model(train_x[indices]), train_y[indices])
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
        model.eval()
        with torch.inference_mode():
            validation_mse = float(loss_function(model(validation_x), validation_y).item())
        if validation_mse < best_validation_mse:
            best_validation_mse = validation_mse
            best_epoch = epoch
            best_state = {name: value.detach().clone() for name, value in model.state_dict().items()}
            stale_epochs = 0
        else:
            stale_epochs += 1
            if stale_epochs >= args.patience:
                break
    model.load_state_dict(best_state)
    return model, {
        "best_epoch": best_epoch,
        "epochs_completed": epoch,
        "best_validation_mse": best_validation_mse,
    }


def predict_mlp(model: SmallMLP, values: np.ndarray) -> np.ndarray:
    model.eval()
    with torch.inference_mode():
        return model(torch.from_numpy(values.astype(np.float32))).squeeze(1).numpy().astype(np.float64)


def write_pickle(path: Path, value: Any) -> None:
    with path.open("wb") as stream:
        pickle.dump(value, stream)


def feature_importance_rows(
    linear: LinearRegression, forest: RandomForestRegressor
) -> list[dict[str, float | str]]:
    coefficients = np.abs(linear.coef_)
    normalized = coefficients / coefficients.sum() if coefficients.sum() else coefficients
    rows = [
        {
            "feature": feature,
            "random_forest_importance": float(forest.feature_importances_[index]),
            "linear_abs_standardized_coefficient": float(coefficients[index]),
            "linear_normalized_abs_coefficient": float(normalized[index]),
        }
        for index, feature in enumerate(FEATURE_NAMES)
    ]
    return sorted(rows, key=lambda row: float(row["random_forest_importance"]), reverse=True)


def write_feature_importance(
    rows: list[dict[str, float | str]], output_dir: Path
) -> tuple[Path, Path]:
    csv_path = output_dir / "feature_importance_v2.csv"
    image_path = output_dir / "feature_importance_v2.png"
    with csv_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    figure, axis = plt.subplots(figsize=(8.5, 4.8), constrained_layout=True)
    locations = np.arange(len(rows))
    width = 0.36
    axis.bar(
        locations - width / 2,
        [float(row["random_forest_importance"]) for row in rows],
        width,
        color="#276FBF",
        label="Random Forest importance",
    )
    axis.bar(
        locations + width / 2,
        [float(row["linear_normalized_abs_coefficient"]) for row in rows],
        width,
        color="#F4A261",
        label="Linear |coefficient| (normalized)",
    )
    axis.set_xticks(locations, [str(row["feature"]) for row in rows], rotation=25, ha="right")
    axis.set_ylabel("Relative importance")
    axis.set_title("V2 offline quality-estimator feature importance")
    axis.grid(axis="y", alpha=0.2)
    axis.legend()
    figure.savefig(image_path, dpi=180)
    plt.close(figure)
    return csv_path, image_path


def plot_actual_vs_predicted(
    actual: np.ndarray,
    predictions: dict[str, np.ndarray],
    metrics: dict[str, dict[str, dict[str, float]]],
    path: Path,
) -> None:
    figure, axes = plt.subplots(1, len(predictions), figsize=(15, 4.5), constrained_layout=True)
    lower = min(float(actual.min()), *(float(values.min()) for values in predictions.values()))
    upper = max(float(actual.max()), *(float(values.max()) for values in predictions.values()))
    padding = max((upper - lower) * 0.05, 0.001)
    for axis, (model_name, values) in zip(np.atleast_1d(axes), predictions.items()):
        axis.scatter(actual, values, s=18, alpha=0.7, color="#276FBF")
        axis.plot([lower - padding, upper + padding], [lower - padding, upper + padding], "--", color="black")
        axis.set_title(f"{model_name}\nTest MAE={metrics[model_name]['test']['mae']:.5f}")
        axis.set_xlabel("Measured degradation")
        axis.set_ylabel("Predicted degradation")
        axis.grid(alpha=0.2)
    figure.savefig(path, dpi=180)
    plt.close(figure)


def plot_degradation_by_resource(
    resources: np.ndarray,
    actual: np.ndarray,
    prediction: np.ndarray,
    model_name: str,
    path: Path,
) -> None:
    figure, axis = plt.subplots(figsize=(7.5, 4.8), constrained_layout=True)
    positions = np.arange(len(RESOURCE_LEVELS))
    grouped = [actual[resources == resource] for resource in RESOURCE_LEVELS]
    axis.boxplot(grouped, positions=positions, widths=0.5, tick_labels=RESOURCE_LEVELS)
    rng = np.random.default_rng(42)
    for position, resource in zip(positions, RESOURCE_LEVELS):
        values = prediction[resources == resource]
        axis.scatter(
            np.full(len(values), position) + rng.uniform(-0.16, 0.16, len(values)),
            values,
            marker="x",
            color="#D1495B",
            alpha=0.75,
            label=f"{model_name} prediction" if position == 0 else None,
        )
    axis.set_xlabel("Candidate resource level")
    axis.set_ylabel("Degradation")
    axis.set_title("V2 measured test degradation and selected-model predictions")
    axis.grid(axis="y", alpha=0.2)
    axis.legend(loc="best")
    figure.savefig(path, dpi=180)
    plt.close(figure)


def resource_selection_rows(
    metadata: list[dict[str, Any]],
    raw_features: np.ndarray,
    test_indices: np.ndarray,
    predictor: Callable[[np.ndarray], np.ndarray],
    threshold: float,
) -> list[dict[str, Any]]:
    representatives: dict[tuple[int, str], np.ndarray] = {}
    for index in test_indices:
        key = (int(metadata[index]["sample_id"]), str(metadata[index]["layer"]))
        representatives.setdefault(key, raw_features[index].copy())
    rows: list[dict[str, Any]] = []
    for (sample_id, layer), base in sorted(representatives.items()):
        candidates = np.asarray(
            [[base[0], base[1], base[2], base[3], resource] for resource in RESOURCE_LEVELS],
            dtype=np.float64,
        )
        values = predictor(candidates)
        predicted = {resource: float(value) for resource, value in zip(RESOURCE_LEVELS, values)}
        selected = next(
            (resource for resource in RESOURCE_LEVELS if predicted[resource] <= threshold),
            64,
        )
        rows.append(
            {
                "sample_id": sample_id,
                "layer": layer,
                "sparsity": float(base[0]),
                "mean": float(base[1]),
                "variance": float(base[2]),
                "layer_position": float(base[3]),
                "predicted_D16": predicted[16],
                "predicted_D32": predicted[32],
                "predicted_D64": predicted[64],
                "selected_resource": selected,
                "threshold": threshold,
            }
        )
    return rows


def write_resource_selection(rows: list[dict[str, Any]], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=SELECTION_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def predicted_monotonicity(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    violations: list[dict[str, Any]] = []
    for row in rows:
        d16 = float(row["predicted_D16"])
        d32 = float(row["predicted_D32"])
        d64 = float(row["predicted_D64"])
        if d16 < d32:
            violations.append({**row, "relation": "D16 < D32"})
        if d32 < d64:
            violations.append({**row, "relation": "D32 < D64"})
    return violations


def write_monotonicity_report(
    rows: list[dict[str, Any]], violations: list[dict[str, Any]], path: Path, model_name: str
) -> None:
    by_layer = dict(sorted(Counter(str(row["layer"]) for row in violations).items()))
    affected = {(int(row["sample_id"]), str(row["layer"])) for row in violations}
    lines = [
        "Stage 3 V2 - Prediction Monotonicity Report",
        "============================================",
        f"Estimator: {model_name}",
        "Expected ordering: D16 >= D32 >= D64.",
        "Predictions are raw estimator outputs and were not modified or sorted.",
        f"Total test cases: {len(rows)}",
        f"Relationship violations: {len(violations)}",
        f"Test cases with one or more violations: {len(affected)}",
        f"Violations by layer: {by_layer or 'none'}",
        "",
    ]
    if violations:
        lines.append("sample_id  layer       relation     D16          D32          D64")
        for row in violations:
            lines.append(
                f"{int(row['sample_id']):>9}  {str(row['layer']):<10}  {str(row['relation']):<11}  "
                f"{float(row['predicted_D16']):>11.8f}  {float(row['predicted_D32']):>11.8f}  "
                f"{float(row['predicted_D64']):>11.8f}"
            )
    else:
        lines.append("No prediction monotonicity violations found.")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def plot_resource_selection(rows: list[dict[str, Any]], path: Path) -> None:
    sample_ids = sorted({int(row["sample_id"]) for row in rows})
    layers = list(dict.fromkeys(str(row["layer"]) for row in rows))
    lookup = {(int(row["sample_id"]), str(row["layer"])): int(row["selected_resource"]) for row in rows}
    allocation = np.asarray(
        [[lookup[(sample_id, layer)] for layer in layers] for sample_id in sample_ids], dtype=np.int64
    )
    figure, axis = plt.subplots(figsize=(8.2, 7.0), constrained_layout=True)
    colors = ListedColormap(["#2A9D8F", "#E9C46A", "#E76F51"])
    image = axis.imshow(allocation, aspect="auto", cmap=colors, norm=BoundaryNorm([8, 24, 48, 72], 3))
    axis.set_xticks(np.arange(len(layers)), layers)
    axis.set_yticks(np.arange(len(sample_ids)), sample_ids)
    axis.set_xlabel("Layer")
    axis.set_ylabel("Held-out sample ID")
    axis.set_title("Stage 3 V2 preliminary resource selection")
    for row_index, sample_id in enumerate(sample_ids):
        for column_index, layer in enumerate(layers):
            axis.text(column_index, row_index, str(lookup[(sample_id, layer)]), ha="center", va="center", fontsize=8)
    colorbar = figure.colorbar(image, ax=axis, ticks=RESOURCE_LEVELS)
    colorbar.set_label("Selected resource level")
    figure.savefig(path, dpi=180)
    plt.close(figure)


def mae_breakdowns(
    metadata: list[dict[str, Any]], indices: np.ndarray, actual: np.ndarray, predicted: np.ndarray
) -> tuple[dict[str, float], dict[str, float]]:
    resource_values: dict[str, float] = {}
    layer_values: dict[str, float] = {}
    for resource in RESOURCE_LEVELS:
        selected = np.asarray(
            [position for position, index in enumerate(indices) if metadata[index]["resource_level"] == resource]
        )
        resource_values[str(resource)] = float(mean_absolute_error(actual[selected], predicted[selected]))
    for layer in sorted({str(metadata[index]["layer"]) for index in indices}):
        selected = np.asarray(
            [position for position, index in enumerate(indices) if metadata[index]["layer"] == layer]
        )
        layer_values[layer] = float(mean_absolute_error(actual[selected], predicted[selected]))
    return resource_values, layer_values


def actual_degradation_statistics(raw_features: np.ndarray, targets: np.ndarray) -> dict[str, dict[str, float]]:
    resource_column = FEATURE_NAMES.index("resource_level")
    return {
        str(resource): {
            "mean": float(np.mean(targets[raw_features[:, resource_column] == resource])),
            "std": float(np.std(targets[raw_features[:, resource_column] == resource])),
            "minimum": float(np.min(targets[raw_features[:, resource_column] == resource])),
            "maximum": float(np.max(targets[raw_features[:, resource_column] == resource])),
        }
        for resource in RESOURCE_LEVELS
    }


def write_summary(
    path: Path,
    dataset_path: Path,
    metadata: list[dict[str, Any]],
    split_indices: dict[str, np.ndarray],
    metrics: dict[str, dict[str, dict[str, float]]],
    selected_model: str,
    importance: list[dict[str, float | str]],
    actual_statistics: dict[str, dict[str, float]],
    monotonic_rows: list[dict[str, Any]],
    monotonic_violations: list[dict[str, Any]],
    selection_rows: list[dict[str, Any]],
    resource_mae: dict[str, float],
    layer_mae: dict[str, float],
) -> None:
    split_ids = {
        name: sorted({int(metadata[index]["sample_id"]) for index in indices})
        for name, indices in split_indices.items()
    }
    selection_counts = Counter(int(row["selected_resource"]) for row in selection_rows)
    by_layer = dict(sorted(Counter(str(row["layer"]) for row in monotonic_violations).items()))
    lines = [
        "Stage 3 V2 - Offline Quality Estimator",
        "======================================",
        "",
        "Dataset",
        "-------",
        f"Path: {dataset_path}",
        f"Rows: {len(metadata)}",
        f"Unique sample IDs: {len({int(row['sample_id']) for row in metadata})}",
        f"Features: {', '.join(FEATURE_NAMES)}",
        f"Target: {TARGET_NAME}",
        f"Excluded features: {', '.join(EXCLUDED_FEATURES)}",
        "",
        "Group-safe sample-ID split (seed=42)",
        "--------------------------------------",
    ]
    for split in ("train", "validation", "test"):
        lines.append(
            f"{split}: {len(split_ids[split])} IDs, {len(split_indices[split])} rows; IDs={split_ids[split]}"
        )
    lines.extend(["", "Model metrics", "-------------", "model                split        MAE         RMSE        R2"])
    for name, splits in metrics.items():
        for split in ("train", "validation", "test"):
            values = splits[split]
            lines.append(
                f"{name:<20} {split:<10} {values['mae']:<11.8f} {values['rmse']:<11.8f} {values['r2']:.8f}"
            )
    lines.extend(
        [
            "",
            f"Best model by measured test MAE: {selected_model}",
            "",
            "Random Forest feature importance",
            "--------------------------------",
        ]
    )
    for row in importance:
        lines.append(
            f"{row['feature']}: {float(row['random_forest_importance']):.8f}"
        )
    lines.extend(["", "Actual V2 degradation statistics", "-------------------------------"])
    for resource in RESOURCE_LEVELS:
        values = actual_statistics[str(resource)]
        lines.append(
            f"{resource}: mean={values['mean']:.8f}, std={values['std']:.8f}, "
            f"min={values['minimum']:.8f}, max={values['maximum']:.8f}"
        )
    lines.extend(
        [
            "",
            "Selected-model test MAE breakdown",
            "---------------------------------",
            "By resource: " + ", ".join(f"{key}={value:.8f}" for key, value in resource_mae.items()),
            "By layer: " + ", ".join(f"{key}={value:.8f}" for key, value in layer_mae.items()),
            "",
            "Prediction monotonicity",
            "------------------------",
            f"Test cases: {len(monotonic_rows)}",
            f"Relationship violations: {len(monotonic_violations)}",
            f"Violations by layer: {by_layer or 'none'}",
            "",
            "Preliminary resource selection",
            "------------------------------",
            "D_MAX = 0.05; select 16, then 32, then 64; default to 64 if none qualify.",
            f"Decisions: {len(selection_rows)}",
            f"Distribution: 16={selection_counts[16]}, 32={selection_counts[32]}, 64={selection_counts[64]}",
            "",
            "Limitations",
            "-----------",
            "This is an offline estimator trained only on the corrected deterministic PyTorch",
            "software resource-reduction proxy. The resource levels 16/32/64 are abstractions,",
            "not cycle-accurate PE counts. No hardware energy or latency claim is supported,",
            "and SCALE-Sim is intentionally deferred.",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def print_metrics(metrics: dict[str, dict[str, dict[str, float]]]) -> None:
    print("\nModel metrics:")
    print("model                split        MAE         RMSE        R2")
    for name, splits in metrics.items():
        for split in ("train", "validation", "test"):
            values = splits[split]
            print(
                f"{name:<20} {split:<10} {values['mae']:<11.8f} "
                f"{values['rmse']:<11.8f} {values['r2']:.8f}"
            )


def main() -> None:
    args = parse_args()
    if args.epochs < 1 or args.patience < 1 or args.batch_size < 1:
        raise ValueError("--epochs, --patience, and --batch-size must be positive")
    if not math.isfinite(args.d_max):
        raise ValueError("--d-max must be finite")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    set_seed(args.seed)

    raw_features, targets, metadata = read_v2_dataset(args.dataset)
    split_indices = split_by_sample_id(metadata, args.seed)
    split_ids = {
        split: sorted({int(metadata[index]["sample_id"]) for index in indices})
        for split, indices in split_indices.items()
    }
    x_train, y_train = raw_features[split_indices["train"]], targets[split_indices["train"]]
    x_validation, y_validation = raw_features[split_indices["validation"]], targets[split_indices["validation"]]
    x_test, y_test = raw_features[split_indices["test"]], targets[split_indices["test"]]

    scaler = StandardScaler().fit(x_train)
    scaled = {
        "train": scaler.transform(x_train),
        "validation": scaler.transform(x_validation),
        "test": scaler.transform(x_test),
    }
    linear = LinearRegression().fit(scaled["train"], y_train)
    forest = RandomForestRegressor(n_estimators=200, random_state=args.seed, n_jobs=-1).fit(
        x_train, y_train
    )
    mlp, mlp_training = train_mlp(
        scaled["train"], y_train, scaled["validation"], y_validation, args
    )

    predictions = {
        "linear_regression": {
            split: linear.predict(scaled[split]) for split in ("train", "validation", "test")
        },
        "small_mlp": {
            split: predict_mlp(mlp, scaled[split]) for split in ("train", "validation", "test")
        },
        "random_forest": {
            "train": forest.predict(x_train),
            "validation": forest.predict(x_validation),
            "test": forest.predict(x_test),
        },
    }
    targets_by_split = {"train": y_train, "validation": y_validation, "test": y_test}
    metrics = {
        name: {
            split: regression_metrics(targets_by_split[split], values[split])
            for split in ("train", "validation", "test")
        }
        for name, values in predictions.items()
    }
    # The task requests the best model based on measured test performance.
    selected_model = min(metrics, key=lambda name: metrics[name]["test"]["mae"])
    predictor_map: dict[str, Callable[[np.ndarray], np.ndarray]] = {
        "linear_regression": lambda values: linear.predict(scaler.transform(values)),
        "small_mlp": lambda values: predict_mlp(mlp, scaler.transform(values)),
        "random_forest": lambda values: forest.predict(values),
    }
    selected_predictor = predictor_map[selected_model]
    selection_rows = resource_selection_rows(
        metadata, raw_features, split_indices["test"], selected_predictor, args.d_max
    )
    selection_path = args.output_dir / "resource_selection_v2.csv"
    write_resource_selection(selection_rows, selection_path)
    monotonic_violations = predicted_monotonicity(selection_rows)
    monotonicity_path = args.output_dir / "prediction_monotonicity_v2.txt"
    write_monotonicity_report(
        selection_rows, monotonic_violations, monotonicity_path, selected_model
    )
    resource_mae, layer_mae = mae_breakdowns(
        metadata, split_indices["test"], y_test, predictions[selected_model]["test"]
    )

    linear_path = args.output_dir / "quality_estimator_linear_v2.pkl"
    forest_path = args.output_dir / "quality_estimator_rf_v2.pkl"
    scaler_path = args.output_dir / "quality_estimator_v2_scaler.pkl"
    mlp_path = args.output_dir / "quality_estimator_mlp_v2.pt"
    write_pickle(linear_path, linear)
    write_pickle(forest_path, forest)
    write_pickle(scaler_path, scaler)
    torch.save(
        {
            "model_class": "SmallMLP",
            "architecture": [5, 16, 8, 1],
            "feature_names": FEATURE_NAMES,
            "state_dict": mlp.state_dict(),
            "seed": args.seed,
            "training": mlp_training,
        },
        mlp_path,
    )
    importance = feature_importance_rows(linear, forest)
    feature_csv_path, feature_image_path = write_feature_importance(importance, args.output_dir)
    actual_vs_predicted_path = args.output_dir / "actual_vs_predicted_v2.png"
    plot_actual_vs_predicted(
        y_test,
        {name: values["test"] for name, values in predictions.items()},
        metrics,
        actual_vs_predicted_path,
    )
    degradation_by_resource_path = args.output_dir / "degradation_by_resource_v2.png"
    plot_degradation_by_resource(
        x_test[:, FEATURE_NAMES.index("resource_level")],
        y_test,
        predictions[selected_model]["test"],
        selected_model,
        degradation_by_resource_path,
    )
    selection_image_path = args.output_dir / "resource_selection_v2.png"
    plot_resource_selection(selection_rows, selection_image_path)

    actual_statistics = actual_degradation_statistics(raw_features, targets)
    metrics_path = args.output_dir / "model_metrics_v2.json"
    metrics_document = {
        "experiment": "Stage 3 V2 - Offline Quality Estimator",
        "research_scope": "offline estimator over corrected PyTorch software-proxy measurements; not hardware or cycle-accurate simulation",
        "dataset": {
            "path": str(args.dataset),
            "rows": int(len(metadata)),
            "unique_sample_ids": len({int(row["sample_id"]) for row in metadata}),
            "features": FEATURE_NAMES,
            "target": TARGET_NAME,
            "excluded_features": EXCLUDED_FEATURES,
        },
        "split": {
            "seed": args.seed,
            "strategy": "70/15/15 sample_id group split with no cross-split sample IDs",
            "sample_ids": split_ids,
            "unique_sample_id_counts": {name: len(ids) for name, ids in split_ids.items()},
            "row_counts": {name: int(len(indices)) for name, indices in split_indices.items()},
        },
        "models": metrics,
        "mlp_training": mlp_training,
        "selected_model": {"name": selected_model, "criterion": "lowest measured test MAE"},
        "selected_model_test_mae_by_resource": resource_mae,
        "selected_model_test_mae_by_layer": layer_mae,
        "prediction_monotonicity": {
            "test_cases": len(selection_rows),
            "relationship_violations": len(monotonic_violations),
            "violations_by_layer": dict(sorted(Counter(str(row["layer"]) for row in monotonic_violations).items())),
        },
        "resource_selection": {
            "d_max": args.d_max,
            "rows": len(selection_rows),
            "selected_resource_counts": {
                str(resource): Counter(int(row["selected_resource"]) for row in selection_rows)[resource]
                for resource in RESOURCE_LEVELS
            },
        },
        "feature_importance_file": str(feature_csv_path),
    }
    with metrics_path.open("w", encoding="utf-8") as stream:
        json.dump(metrics_document, stream, indent=2)
        stream.write("\n")
    summary_path = args.output_dir / "stage3_v2_summary.txt"
    write_summary(
        summary_path,
        args.dataset,
        metadata,
        split_indices,
        metrics,
        selected_model,
        importance,
        actual_statistics,
        selection_rows,
        monotonic_violations,
        selection_rows,
        resource_mae,
        layer_mae,
    )

    print("Stage 3 V2 - Offline Quality Estimator")
    print(f"V2 dataset read: {args.dataset}")
    print("Features: " + ", ".join(FEATURE_NAMES))
    print("Target: degradation")
    print("Excluded from features: " + ", ".join(EXCLUDED_FEATURES))
    print("\nGroup-safe split by sample_id (seed=42):")
    for split in ("train", "validation", "test"):
        print(f"  {split}: {len(split_ids[split])} unique IDs {split_ids[split]}; {len(split_indices[split])} rows")
    print_metrics(metrics)
    print(f"\nBest model by measured test MAE: {selected_model}")
    print("Random Forest feature importance:")
    for row in importance:
        print(f"  {row['feature']}: {float(row['random_forest_importance']):.8f}")
    print("\nSelected-model test MAE by resource:")
    for resource, value in resource_mae.items():
        print(f"  {resource}: {value:.8f}")
    print("Selected-model test MAE by layer:")
    for layer, value in layer_mae.items():
        print(f"  {layer}: {value:.8f}")
    print("\nPrediction validation examples (test records):")
    print("Layer       Resource  Actual D     Predicted D")
    ordered_test_positions = sorted(
        range(len(split_indices["test"])),
        key=lambda position: (
            int(metadata[split_indices["test"][position]]["sample_id"]),
            str(metadata[split_indices["test"][position]]["layer"]),
            int(metadata[split_indices["test"][position]]["resource_level"]),
        ),
    )
    for position in ordered_test_positions[:20]:
        index = split_indices["test"][position]
        print(
            f"{str(metadata[index]['layer']):<10}  {int(metadata[index]['resource_level']):>8}  "
            f"{targets[index]:>10.8f}  {predictions[selected_model]['test'][position]:>11.8f}"
        )
    selection_counts = Counter(int(row["selected_resource"]) for row in selection_rows)
    print("\nPrediction monotonicity:")
    print(f"  Test cases: {len(selection_rows)}")
    print(f"  Relationship violations: {len(monotonic_violations)}")
    print(f"  Violations by layer: {dict(sorted(Counter(str(row['layer']) for row in monotonic_violations).items())) or 'none'}")
    print(f"\nPreliminary resource selection, D_MAX={args.d_max:.2f}:")
    print(f"  16: {selection_counts[16]}")
    print(f"  32: {selection_counts[32]}")
    print(f"  64: {selection_counts[64]}")
    print("\nCreated files:")
    for path in (
        linear_path,
        forest_path,
        scaler_path,
        mlp_path,
        metrics_path,
        monotonicity_path,
        feature_csv_path,
        feature_image_path,
        actual_vs_predicted_path,
        degradation_by_resource_path,
        selection_path,
        selection_image_path,
        summary_path,
    ):
        print(f"  {path}")


if __name__ == "__main__":
    main()
