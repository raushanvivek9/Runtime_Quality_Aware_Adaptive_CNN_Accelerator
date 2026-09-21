"""Train the Stage-3 offline quality-degradation estimators.

This program reads the existing Stage-2 dataset without modifying it.  It
trains regressors from pre-layer activation aggregates and a candidate resource
level to the *measured* ``degradation`` target.  It is an offline software
estimator; it neither implements a hardware controller nor simulates PE timing.
"""

from __future__ import annotations

import argparse
import copy
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
from sklearn.ensemble import RandomForestRegressor
from sklearn.linear_model import LinearRegression
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.preprocessing import StandardScaler
from torch import nn


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATASET_PATH = PROJECT_ROOT / "results" / "quality_dataset.csv"
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "results"
FEATURE_NAMES = ["sparsity", "mean", "variance", "layer_position", "resource_level"]
TARGET_NAME = "degradation"
LEAKAGE_COLUMNS = [
    "baseline_loss",
    "reduced_loss",
    "baseline_correct",
    "reduced_correct",
    "sample_id",
]
RESOURCE_LEVELS = (16, 32, 64)


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
    parser.add_argument("--d-max", type=float, default=0.05)
    return parser.parse_args()


def set_seed(seed: int) -> None:
    """Set the sources of randomness used by the split and MLP training."""
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.use_deterministic_algorithms(True)


def read_dataset(dataset_path: Path) -> tuple[np.ndarray, np.ndarray, list[dict[str, Any]]]:
    """Read only allowed feature columns, target, and split/selection metadata."""
    if not dataset_path.is_file():
        raise FileNotFoundError(f"quality dataset not found: {dataset_path}")

    with dataset_path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        available_columns = set(reader.fieldnames or [])
        required_columns = set(FEATURE_NAMES + [TARGET_NAME, "sample_id", "layer"])
        missing = required_columns - available_columns
        if missing:
            raise ValueError(f"dataset is missing required columns: {sorted(missing)}")

        features: list[list[float]] = []
        targets: list[float] = []
        metadata: list[dict[str, Any]] = []
        for row_number, row in enumerate(reader, start=2):
            try:
                feature_values = [float(row[name]) for name in FEATURE_NAMES]
                target = float(row[TARGET_NAME])
                sample_id = int(row["sample_id"])
            except (TypeError, ValueError) as error:
                raise ValueError(f"invalid numeric data at CSV row {row_number}") from error
            if not all(math.isfinite(value) for value in feature_values + [target]):
                raise ValueError(f"non-finite value at CSV row {row_number}")
            features.append(feature_values)
            targets.append(target)
            metadata.append(
                {
                    "sample_id": sample_id,
                    "layer": row["layer"],
                    "module_type": row.get("module_type", ""),
                }
            )

    if not features:
        raise ValueError("quality dataset is empty")
    return np.asarray(features, dtype=np.float64), np.asarray(targets, dtype=np.float64), metadata


def split_by_sample_id(metadata: list[dict[str, Any]], seed: int) -> dict[str, np.ndarray]:
    """Assign every row from a sample ID to exactly one 70/15/15 split."""
    sample_ids = np.asarray(sorted({int(row["sample_id"]) for row in metadata}), dtype=np.int64)
    if len(sample_ids) < 7:
        raise ValueError("at least seven sample IDs are required for a 70/15/15 split")

    shuffled_ids = sample_ids.copy()
    np.random.default_rng(seed).shuffle(shuffled_ids)
    train_count = round(0.70 * len(shuffled_ids))
    validation_count = round(0.15 * len(shuffled_ids))
    test_count = len(shuffled_ids) - train_count - validation_count
    if min(train_count, validation_count, test_count) < 1:
        raise ValueError("the requested split would create an empty partition")

    split_ids = {
        "train": set(shuffled_ids[:train_count].tolist()),
        "validation": set(shuffled_ids[train_count : train_count + validation_count].tolist()),
        "test": set(shuffled_ids[train_count + validation_count :].tolist()),
    }
    if split_ids["train"] & split_ids["validation"] or split_ids["train"] & split_ids["test"]:
        raise RuntimeError("sample ID overlap detected in split construction")
    if split_ids["validation"] & split_ids["test"]:
        raise RuntimeError("sample ID overlap detected in split construction")

    return {
        name: np.asarray(
            [index for index, row in enumerate(metadata) if row["sample_id"] in ids], dtype=np.int64
        )
        for name, ids in split_ids.items()
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
    """Train with validation early stopping and restore the best validation state."""
    model = SmallMLP()
    optimizer = torch.optim.Adam(model.parameters(), lr=args.learning_rate)
    loss_function = nn.MSELoss()
    train_x = torch.from_numpy(x_train.astype(np.float32))
    train_y = torch.from_numpy(y_train.astype(np.float32)).unsqueeze(1)
    validation_x = torch.from_numpy(x_validation.astype(np.float32))
    validation_y = torch.from_numpy(y_validation.astype(np.float32)).unsqueeze(1)

    best_state = copy.deepcopy(model.state_dict())
    best_validation_mse = float("inf")
    best_epoch = 0
    stale_epochs = 0
    for epoch in range(1, args.epochs + 1):
        model.train()
        order = torch.randperm(len(train_x))
        for start in range(0, len(train_x), args.batch_size):
            indices = order[start : start + args.batch_size]
            prediction = model(train_x[indices])
            loss = loss_function(prediction, train_y[indices])
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

        model.eval()
        with torch.inference_mode():
            validation_mse = float(loss_function(model(validation_x), validation_y).item())
        if validation_mse < best_validation_mse:
            best_validation_mse = validation_mse
            best_epoch = epoch
            best_state = copy.deepcopy(model.state_dict())
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


def write_pickle(path: Path, object_to_save: Any) -> None:
    with path.open("wb") as stream:
        pickle.dump(object_to_save, stream)


def plot_actual_vs_predicted(
    actual: np.ndarray, predictions: dict[str, np.ndarray], metrics: dict[str, Any], output_path: Path
) -> None:
    figure, axes = plt.subplots(1, len(predictions), figsize=(15, 4.5), constrained_layout=True)
    lower = min(float(actual.min()), *(float(values.min()) for values in predictions.values()))
    upper = max(float(actual.max()), *(float(values.max()) for values in predictions.values()))
    padding = max((upper - lower) * 0.05, 0.001)
    for axis, (name, values) in zip(np.atleast_1d(axes), predictions.items()):
        axis.scatter(actual, values, s=18, alpha=0.7, color="#276FBF")
        axis.plot([lower - padding, upper + padding], [lower - padding, upper + padding], "--", color="black")
        axis.set_title(f"{name}\nTest MAE={metrics[name]['test']['mae']:.5f}")
        axis.set_xlabel("Actual degradation")
        axis.set_ylabel("Predicted degradation")
        axis.grid(alpha=0.2)
    figure.savefig(output_path, dpi=180)
    plt.close(figure)


def plot_degradation_by_resource(
    resources: np.ndarray,
    actual: np.ndarray,
    selected_prediction: np.ndarray,
    selected_model: str,
    output_path: Path,
) -> None:
    """Plot measured test degradation and the deployed estimator prediction."""
    figure, axis = plt.subplots(figsize=(7.5, 4.8), constrained_layout=True)
    grouped_actual = [actual[resources == resource] for resource in RESOURCE_LEVELS]
    positions = np.arange(len(RESOURCE_LEVELS))
    axis.boxplot(grouped_actual, positions=positions, widths=0.5, tick_labels=RESOURCE_LEVELS)
    rng = np.random.default_rng(42)
    for position, resource in zip(positions, RESOURCE_LEVELS):
        selected = selected_prediction[resources == resource]
        jitter = rng.uniform(-0.16, 0.16, len(selected))
        axis.scatter(
            np.full(len(selected), position) + jitter,
            selected,
            marker="x",
            color="#D1495B",
            alpha=0.75,
            label=f"{selected_model} prediction" if position == 0 else None,
        )
    axis.set_xlabel("Candidate resource level")
    axis.set_ylabel("Degradation")
    axis.set_title("Test degradation by resource: measured distribution and model predictions")
    axis.legend(loc="best")
    axis.grid(axis="y", alpha=0.2)
    figure.savefig(output_path, dpi=180)
    plt.close(figure)


def write_feature_importance(
    output_dir: Path, linear: LinearRegression, forest: RandomForestRegressor
) -> tuple[Path, Path, list[dict[str, float | str]]]:
    linear_abs = np.abs(linear.coef_)
    linear_normalized = linear_abs / linear_abs.sum() if linear_abs.sum() else linear_abs
    rows = [
        {
            "feature": feature,
            "random_forest_importance": float(forest.feature_importances_[index]),
            "linear_abs_standardized_coefficient": float(linear_abs[index]),
            "linear_normalized_abs_coefficient": float(linear_normalized[index]),
        }
        for index, feature in enumerate(FEATURE_NAMES)
    ]
    rows.sort(key=lambda row: float(row["random_forest_importance"]), reverse=True)
    csv_path = output_dir / "feature_importance.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    figure, axis = plt.subplots(figsize=(8.5, 4.8), constrained_layout=True)
    names = [str(row["feature"]) for row in rows]
    locations = np.arange(len(rows))
    width = 0.36
    axis.bar(
        locations - width / 2,
        [float(row["random_forest_importance"]) for row in rows],
        width,
        label="Random Forest importance",
        color="#276FBF",
    )
    axis.bar(
        locations + width / 2,
        [float(row["linear_normalized_abs_coefficient"]) for row in rows],
        width,
        label="Linear |coefficient| (normalized)",
        color="#F4A261",
    )
    axis.set_xticks(locations, names, rotation=25, ha="right")
    axis.set_ylabel("Relative importance")
    axis.set_title("Feature importance from offline regressors")
    axis.legend()
    axis.grid(axis="y", alpha=0.2)
    image_path = output_dir / "feature_importance.png"
    figure.savefig(image_path, dpi=180)
    plt.close(figure)
    return csv_path, image_path, rows


def write_resource_selection(
    metadata: list[dict[str, Any]],
    raw_features: np.ndarray,
    test_indices: np.ndarray,
    predictor: Callable[[np.ndarray], np.ndarray],
    d_max: float,
    output_path: Path,
) -> tuple[list[dict[str, Any]], Counter[int]]:
    """Predict D16/D32/D64 for every test (sample, layer) pair."""
    representatives: dict[tuple[int, str], np.ndarray] = {}
    for index in test_indices:
        key = (int(metadata[index]["sample_id"]), str(metadata[index]["layer"]))
        representatives.setdefault(key, raw_features[index].copy())

    rows: list[dict[str, Any]] = []
    for (sample_id, layer), base_features in sorted(representatives.items()):
        candidates = np.vstack(
            [
                np.asarray([*base_features[:4], resource_level], dtype=np.float64)
                for resource_level in RESOURCE_LEVELS
            ]
        )
        values = predictor(candidates)
        predicted = {resource: float(value) for resource, value in zip(RESOURCE_LEVELS, values)}
        acceptable = [resource for resource in RESOURCE_LEVELS if predicted[resource] <= d_max]
        selected_resource = min(acceptable) if acceptable else 64
        rows.append(
            {
                "sample_id": sample_id,
                "layer": layer,
                "predicted_D16": predicted[16],
                "predicted_D32": predicted[32],
                "predicted_D64": predicted[64],
                "selected_resource": selected_resource,
            }
        )

    with output_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    return rows, Counter(int(row["selected_resource"]) for row in rows)


def print_metrics(model_metrics: dict[str, dict[str, dict[str, float]]]) -> None:
    print("\nModel metrics:")
    print("model                split        MAE         RMSE        R^2")
    for name, splits in model_metrics.items():
        for split_name in ("validation", "test"):
            values = splits[split_name]
            print(
                f"{name:<20} {split_name:<10} {values['mae']:<11.8f} "
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

    raw_features, targets, metadata = read_dataset(args.dataset)
    split_indices = split_by_sample_id(metadata, args.seed)
    x_train, y_train = raw_features[split_indices["train"]], targets[split_indices["train"]]
    x_validation, y_validation = (
        raw_features[split_indices["validation"]],
        targets[split_indices["validation"]],
    )
    x_test, y_test = raw_features[split_indices["test"]], targets[split_indices["test"]]

    scaler = StandardScaler().fit(x_train)
    x_train_scaled = scaler.transform(x_train)
    x_validation_scaled = scaler.transform(x_validation)
    x_test_scaled = scaler.transform(x_test)

    linear = LinearRegression().fit(x_train_scaled, y_train)
    forest = RandomForestRegressor(
        n_estimators=300,
        random_state=args.seed,
        n_jobs=-1,
    ).fit(x_train, y_train)
    mlp, mlp_training = train_mlp(
        x_train_scaled, y_train, x_validation_scaled, y_validation, args
    )

    predictions = {
        "linear_regression": {
            "validation": linear.predict(x_validation_scaled),
            "test": linear.predict(x_test_scaled),
        },
        "small_mlp": {
            "validation": predict_mlp(mlp, x_validation_scaled),
            "test": predict_mlp(mlp, x_test_scaled),
        },
        "random_forest": {
            "validation": forest.predict(x_validation),
            "test": forest.predict(x_test),
        },
    }
    model_metrics = {
        name: {
            "validation": regression_metrics(y_validation, values["validation"]),
            "test": regression_metrics(y_test, values["test"]),
        }
        for name, values in predictions.items()
    }
    selected_model = min(model_metrics, key=lambda name: model_metrics[name]["validation"]["mae"])

    predictor_map: dict[str, Callable[[np.ndarray], np.ndarray]] = {
        "linear_regression": lambda values: linear.predict(scaler.transform(values)),
        "small_mlp": lambda values: predict_mlp(mlp, scaler.transform(values)),
        "random_forest": lambda values: forest.predict(values),
    }
    selection_rows, selection_counts = write_resource_selection(
        metadata,
        raw_features,
        split_indices["test"],
        predictor_map[selected_model],
        args.d_max,
        args.output_dir / "resource_selection.csv",
    )

    linear_path = args.output_dir / "quality_estimator_linear.pkl"
    forest_path = args.output_dir / "quality_estimator_rf.pkl"
    scaler_path = args.output_dir / "quality_estimator_scaler.pkl"
    mlp_path = args.output_dir / "quality_estimator_mlp.pt"
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

    actual_vs_predicted_path = args.output_dir / "actual_vs_predicted.png"
    plot_actual_vs_predicted(
        y_test,
        {name: values["test"] for name, values in predictions.items()},
        model_metrics,
        actual_vs_predicted_path,
    )
    degradation_by_resource_path = args.output_dir / "degradation_by_resource.png"
    plot_degradation_by_resource(
        x_test[:, FEATURE_NAMES.index("resource_level")],
        y_test,
        predictions[selected_model]["test"],
        selected_model,
        degradation_by_resource_path,
    )
    feature_csv_path, feature_image_path, feature_rows = write_feature_importance(
        args.output_dir, linear, forest
    )

    split_sample_ids = {
        split: sorted({int(metadata[index]["sample_id"]) for index in indices})
        for split, indices in split_indices.items()
    }
    metrics_document = {
        "experiment": "Stage 3 - Offline Quality Estimator",
        "research_scope": (
            "offline software quality estimation only; not hardware implemented and not "
            "a cycle-accurate PE simulation"
        ),
        "dataset": {
            "path": str(args.dataset),
            "rows": int(len(raw_features)),
            "unique_sample_ids": int(len({row["sample_id"] for row in metadata})),
            "input_features": FEATURE_NAMES,
            "target": TARGET_NAME,
            "excluded_leakage_columns": LEAKAGE_COLUMNS,
        },
        "split": {
            "seed": args.seed,
            "strategy": "sample_id group split; no sample ID is shared between splits",
            "fractions": {"train": 0.70, "validation": 0.15, "test": 0.15},
            "unique_sample_id_counts": {name: len(ids) for name, ids in split_sample_ids.items()},
            "row_counts": {name: int(len(indices)) for name, indices in split_indices.items()},
            "sample_ids": split_sample_ids,
        },
        "models": model_metrics,
        "mlp_training": mlp_training,
        "resource_selection": {
            "model": selected_model,
            "selection_criterion": "lowest validation MAE",
            "d_max": args.d_max,
            "rows": len(selection_rows),
            "selected_resource_counts": {str(key): value for key, value in sorted(selection_counts.items())},
        },
        "feature_importance_file": str(feature_csv_path),
    }
    metrics_path = args.output_dir / "model_metrics.json"
    with metrics_path.open("w", encoding="utf-8") as stream:
        json.dump(metrics_document, stream, indent=2)
        stream.write("\n")

    print("Stage 3 - Offline Quality Estimator")
    print(f"Dataset read without modification: {args.dataset}")
    print("Input features: " + ", ".join(FEATURE_NAMES))
    print("Target: degradation")
    print("Excluded from model inputs: " + ", ".join(LEAKAGE_COLUMNS))
    print("\nGroup-safe split by sample_id (seed=42):")
    for split_name in ("train", "validation", "test"):
        print(
            f"  {split_name}: {len(split_sample_ids[split_name])} sample IDs, "
            f"{len(split_indices[split_name])} rows"
        )
    print_metrics(model_metrics)
    print("\nFeature importance:")
    for row in feature_rows:
        print(
            f"  {row['feature']}: RF={row['random_forest_importance']:.6f}, "
            f"linear_normalized_abs_coefficient={row['linear_normalized_abs_coefficient']:.6f}"
        )
    print(f"\nResource selection uses {selected_model} (lowest validation MAE), D_MAX={args.d_max:.3f}")
    for row in selection_rows[:8]:
        print(
            f"  Sample: {row['sample_id']}, Layer: {row['layer']}, "
            f"D16={row['predicted_D16']:.6f}, D32={row['predicted_D32']:.6f}, "
            f"D64={row['predicted_D64']:.6f}, Selected resource={row['selected_resource']}"
        )
    print("\nActual vs predicted degradation examples (selected estimator, test rows):")
    for index, prediction in zip(split_indices["test"][:8], predictions[selected_model]["test"][:8]):
        print(
            f"  Sample: {metadata[index]['sample_id']}, Layer: {metadata[index]['layer']}, "
            f"resource={int(raw_features[index, 4])}, actual={targets[index]:.6f}, "
            f"predicted={prediction:.6f}"
        )
    print("\nCreated files:")
    for path in (
        mlp_path,
        forest_path,
        linear_path,
        scaler_path,
        metrics_path,
        actual_vs_predicted_path,
        degradation_by_resource_path,
        feature_csv_path,
        feature_image_path,
        args.output_dir / "resource_selection.csv",
    ):
        print(f"  {path}")


if __name__ == "__main__":
    main()
