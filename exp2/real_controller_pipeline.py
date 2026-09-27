#!/usr/bin/env python3
"""Real checkpoint-driven controller pipeline for Experiment 2.

This script closes the remaining gap between the synthetic Exp2 scaffold and the
actual frozen CIFAR model checkpoints from Stage 12. It loads a validated model,
collects per-layer activation statistics, trains candidate regressors with
sample-safe group splits, then reports which PE policy is the best fit under a
max-degradation constraint.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from sklearn.ensemble import RandomForestRegressor
from sklearn.linear_model import LinearRegression
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.model_selection import GroupShuffleSplit
from sklearn.neural_network import MLPRegressor

from adaptive_flow import AdaptivePEController, LayerFeatures
from full_network_pipeline import RESOURCE_LEVELS, collect_full_network_feature_rows

ROOT = Path(__file__).resolve().parent
STAGE12_ROOT = ROOT.parent / "exp1" / "stage12_final_evaluation_v3"
CHECKPOINT_ROOT = STAGE12_ROOT / "checkpoints"
DATA_ROOT = STAGE12_ROOT / "data"
RESULTS_ROOT = ROOT / "results"


def _load_model(model_name: str, dataset_name: str) -> torch.nn.Module:
    import sys

    sys.path.insert(0, str(STAGE12_ROOT))
    from common import CifarDataset, make_model

    classes = {"cifar10": 10, "cifar100": 100}
    checkpoint = CHECKPOINT_ROOT / f"{model_name}_{dataset_name}_best.pt"
    if not checkpoint.exists():
        raise FileNotFoundError(f"missing checkpoint: {checkpoint}")

    model = make_model(model_name, classes[dataset_name])
    payload = torch.load(checkpoint, map_location="cpu")
    state_dict = payload.get("model_state_dict", payload)
    model.load_state_dict(state_dict, strict=True)
    model.eval()
    return model


def _make_loader(dataset_name: str, max_samples: int | None = None, batch_size: int = 128):
    import sys

    sys.path.insert(0, str(STAGE12_ROOT))
    from common import CifarDataset

    dataset = CifarDataset(dataset_name, train=False)
    if max_samples is not None:
        indices = list(range(min(max_samples, len(dataset))))
        dataset = torch.utils.data.Subset(dataset, indices)
    return torch.utils.data.DataLoader(dataset, batch_size=batch_size, shuffle=False, num_workers=0)


def _feature_frame(rows: list[dict]) -> pd.DataFrame:
    frame = pd.DataFrame(rows)
    if frame.empty:
        raise ValueError("feature rows are empty")
    frame["layer_code"] = frame["layer"].astype("category").cat.codes
    return frame


def _build_regressors() -> dict[str, object]:
    return {
        "linear_regression": LinearRegression(),
        "mlp": MLPRegressor(
            hidden_layer_sizes=(32, 16),
            activation="relu",
            solver="adam",
            learning_rate_init=0.01,
            max_iter=600,
            random_state=42,
            early_stopping=True,
        ),
        "random_forest": RandomForestRegressor(
            n_estimators=200,
            max_depth=None,
            min_samples_leaf=1,
            random_state=42,
        ),
    }


def _evaluate_regressor(name: str, regressor: object, X_train: pd.DataFrame, X_test: pd.DataFrame, y_train: pd.Series, y_test: pd.Series) -> dict:
    regressor.fit(X_train, y_train)
    predictions = regressor.predict(X_test)
    mae = mean_absolute_error(y_test, predictions)
    rmse = float(np.sqrt(mean_squared_error(y_test, predictions)))
    r2 = r2_score(y_test, predictions)
    return {
        "name": name,
        "mae": float(mae),
        "rmse": float(rmse),
        "r2": float(r2),
    }


def _select_best_regressor(frame: pd.DataFrame) -> tuple[str, dict, pd.DataFrame, pd.DataFrame]:
    feature_columns = ["sparsity", "mean", "variance", "layer_position", "resource_level", "layer_code"]
    X = frame[feature_columns]
    y = pd.to_numeric(frame["degradation"], errors="coerce")
    if not np.isfinite(y.to_numpy()).all():
        raise ValueError(
            "controller training requires measured degradation labels; "
            "activation collection does not generate PE-dependent labels"
        )
    if y.nunique() < 2:
        raise ValueError("controller training target has no variation")
    splitter = GroupShuffleSplit(n_splits=1, test_size=0.25, random_state=42)
    train_idx, test_idx = next(splitter.split(X, y, groups=frame["sample_id"]))
    X_train, X_test = X.iloc[train_idx], X.iloc[test_idx]
    y_train, y_test = y.iloc[train_idx], y.iloc[test_idx]

    metrics: list[dict] = []
    for name, regressor in _build_regressors().items():
        metrics.append(_evaluate_regressor(name, regressor, X_train, X_test, y_train, y_test))

    best = min(metrics, key=lambda row: (row["mae"], row["rmse"]))
    return best["name"], best, X_train, X_test


def _summarize_controller(frame: pd.DataFrame, model_name: str, dataset_name: str, best_regressor_name: str, best_metrics: dict) -> dict:
    feature_columns = ["sparsity", "mean", "variance", "layer_position", "resource_level", "layer_code"]
    regressor_map = _build_regressors()
    model = regressor_map[best_regressor_name]
    model.fit(frame[feature_columns], frame["degradation"])

    layer_code_map = {layer: idx for idx, layer in enumerate(sorted(frame["layer"].unique().tolist()))}
    controller = AdaptivePEController(max_degradation=0.05)
    representative_layers = []
    for layer_name, group in frame.groupby("layer"):
        aggregated = group.iloc[0].to_dict()
        representative_layers.append(
            LayerFeatures(
                name=layer_name,
                position=float(aggregated["layer_position"]),
                sparsity=float(aggregated["sparsity"]),
                mean=float(aggregated["mean"]),
                variance=float(aggregated["variance"]),
            )
        )

    decisions = []
    previous_signal = None
    for layer in representative_layers:
        predictions = {}
        for resource in RESOURCE_LEVELS:
            feature_row = pd.DataFrame(
                [{
                    "sparsity": layer.sparsity,
                    "mean": layer.mean,
                    "variance": layer.variance,
                    "layer_position": layer.position,
                    "resource_level": resource,
                    "layer_code": layer_code_map.get(layer.name, 0),
                }]
            )
            predictions[resource] = float(model.predict(feature_row)[0])
        decision = controller.select_layer(layer, predictions, previous_signal)
        decisions.append({
            "layer": layer.name,
            "selected_resource": decision.selected_resource,
            "threshold_used": decision.threshold_used,
            "predicted_degradation": {str(k): float(v) for k, v in decision.predicted_degradation.items()},
        })
        previous_signal = decision.signal

    return {
        "model": model_name,
        "dataset": dataset_name,
        "best_regressor": best_regressor_name,
        "metrics": best_metrics,
        "selected_resources": decisions,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the real checkpoint-driven Exp2 controller pipeline")
    parser.add_argument("--model", choices=["resnet18", "vgg16"], default="resnet18")
    parser.add_argument("--dataset", choices=["cifar10", "cifar100"], default="cifar10")
    parser.add_argument("--max-samples", type=int, default=64)
    parser.add_argument("--batch-size", type=int, default=64)
    args = parser.parse_args()

    RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
    model = _load_model(args.model, args.dataset)
    loader = _make_loader(args.dataset, max_samples=args.max_samples, batch_size=args.batch_size)
    rows = collect_full_network_feature_rows(model, loader, max_samples=args.max_samples)
    frame = _feature_frame(rows)

    dataset_path = RESULTS_ROOT / f"{args.model}_{args.dataset}_controller_dataset.csv"
    best_regressor_name, best_metrics, _, _ = _select_best_regressor(frame)
    summary = _summarize_controller(frame, args.model, args.dataset, best_regressor_name, best_metrics)
    frame.to_csv(dataset_path, index=False)
    summary_path = RESULTS_ROOT / f"{args.model}_{args.dataset}_controller_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")

    print(json.dumps({
        "dataset_path": str(dataset_path),
        "summary_path": str(summary_path),
        "model": args.model,
        "dataset": args.dataset,
        "best_regressor": best_regressor_name,
        "metrics": best_metrics,
        "rows": len(frame),
    }, indent=2))


if __name__ == "__main__":
    main()
