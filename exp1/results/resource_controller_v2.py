"""Stage 4 V2 adaptive-controller evaluation over held-out V2 test samples.

The controller observes compact pre-layer activation statistics, predicts V2
degradation with the already-trained Random Forest, and chooses the smallest
resource satisfying D_MAX. Actual V2 measurements are joined only after the
policy decision to evaluate controller safety. This is an offline PyTorch
software-proxy experiment, not a hardware/cycle-accurate simulation.
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

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import torch


RESULTS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = RESULTS_DIR.parent
PYTORCH_DIR = PROJECT_ROOT / "pytorch"
if str(PYTORCH_DIR) not in sys.path:
    sys.path.insert(0, str(PYTORCH_DIR))

from model import SimpleCNN  # noqa: E402
from monitor import LayerActivationMonitor  # noqa: E402


FEATURE_NAMES = ("sparsity", "mean", "variance", "layer_position", "resource_level")
RESOURCE_LEVELS = (16, 32, 64)
BASELINE_RESOURCE = 64
DEFAULT_D_MAX = 0.05
EXPECTED_TEST_IDS = (8, 12, 13, 14, 19, 22, 35, 36, 41, 47, 53, 64, 65, 66, 77, 97, 107, 109, 113)
DECISION_FIELDS = [
    "sample_id",
    "layer",
    "layer_position",
    "sparsity",
    "mean",
    "variance",
    "predicted_D_16",
    "predicted_D_32",
    "predicted_D_64",
    "selected_resource",
    "predicted_D_selected",
    "actual_D_selected",
    "prediction_error",
    "threshold_satisfied_actual",
    "baseline_resource",
    "resource_reduction_fraction",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-dir", type=Path, default=RESULTS_DIR)
    parser.add_argument(
        "--dataset", type=Path, default=RESULTS_DIR / "quality_dataset_v2.csv"
    )
    parser.add_argument(
        "--metrics", type=Path, default=RESULTS_DIR / "model_metrics_v2.json"
    )
    parser.add_argument(
        "--forest", type=Path, default=RESULTS_DIR / "quality_estimator_rf_v2.pkl"
    )
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--d-max", type=float, default=DEFAULT_D_MAX)
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


def load_test_ids(metrics_path: Path) -> list[int]:
    """Reuse Stage 3 V2's stored group-safe test split and verify its identity."""
    metrics = read_json(metrics_path)
    try:
        test_ids = [int(value) for value in metrics["split"]["sample_ids"]["test"]]
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError(f"{metrics_path} lacks valid split.sample_ids.test") from error
    if tuple(test_ids) != EXPECTED_TEST_IDS:
        raise ValueError(
            "Stage 3 V2 test IDs differ from the required held-out set: "
            f"{test_ids}"
        )
    return test_ids


def load_forest(path: Path) -> Any:
    if not path.is_file():
        raise FileNotFoundError(f"V2 Random Forest not found: {path}")
    with path.open("rb") as stream:
        forest = pickle.load(stream)
    if not callable(getattr(forest, "predict", None)):
        raise TypeError("the loaded V2 estimator does not provide predict()")
    if getattr(forest, "n_features_in_", None) != len(FEATURE_NAMES):
        raise ValueError("the loaded V2 estimator does not accept the required five features")
    return forest


def load_actual_v2(
    path: Path, test_ids: list[int]
) -> tuple[dict[tuple[int, str, int], float], int, list[str]]:
    """Load measured V2 degradation only for post-decision evaluation."""
    required = {
        "sample_id",
        "layer",
        "resource_level",
        "degradation",
        "resource_reduction_proxy",
    }
    if not path.is_file():
        raise FileNotFoundError(f"V2 dataset not found: {path}")
    measured: dict[tuple[int, str, int], float] = {}
    all_sample_ids: set[int] = set()
    layer_order: list[str] = []
    test_set = set(test_ids)
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"{path} does not have V2 fields: {sorted(missing)}")
        for line_number, row in enumerate(reader, start=2):
            try:
                sample_id = int(row["sample_id"])
                layer = str(row["layer"])
                resource = int(row["resource_level"])
                degradation = float(row["degradation"])
            except (KeyError, TypeError, ValueError) as error:
                raise ValueError(f"invalid V2 dataset row {line_number}") from error
            if not str(row["resource_reduction_proxy"]).startswith("v2_"):
                raise ValueError("the controller refuses a non-V2 proxy dataset")
            if resource not in RESOURCE_LEVELS or not math.isfinite(degradation):
                raise ValueError(f"invalid resource/degradation at V2 dataset row {line_number}")
            all_sample_ids.add(sample_id)
            if layer not in layer_order:
                layer_order.append(layer)
            if sample_id in test_set:
                key = (sample_id, layer, resource)
                if key in measured:
                    raise ValueError(f"duplicate V2 measurement for {key}")
                measured[key] = degradation
    expected = {(sample_id, layer, resource) for sample_id in test_ids for layer in layer_order for resource in RESOURCE_LEVELS}
    missing = expected - set(measured)
    if missing:
        raise ValueError(f"V2 measurements missing for test cases: {sorted(missing)}")
    if len(layer_order) != 4:
        raise ValueError(f"expected four V2 layers; found {layer_order}")
    return measured, len(all_sample_ids), layer_order


def recreate_inputs(seed: int, sample_count: int, device: torch.device) -> tuple[SimpleCNN, torch.Tensor]:
    """Match V2 data generation: seeded model initialization followed by inputs."""
    torch.manual_seed(seed)
    model = SimpleCNN().to(device).eval()
    inputs = torch.randn(sample_count, 3, 32, 32)
    return model, inputs


def collect_one_sample_stats(
    model: torch.nn.Module, sample: torch.Tensor, device: torch.device
) -> list[dict[str, Any]]:
    """Use the existing pre-layer monitor without retaining an activation tensor."""
    with LayerActivationMonitor(model, position="pre") as monitor, torch.inference_mode():
        model(sample.unsqueeze(0).to(device))
    return monitor.summary()


def predict_candidates(
    forest: Any,
    sparsity: float,
    mean: float,
    variance: float,
    layer_position: float,
) -> dict[int, float]:
    values = np.asarray(
        [
            [sparsity, mean, variance, layer_position, resource]
            for resource in RESOURCE_LEVELS
        ],
        dtype=np.float64,
    )
    predictions = forest.predict(values)
    result = {resource: float(prediction) for resource, prediction in zip(RESOURCE_LEVELS, predictions)}
    if not all(math.isfinite(value) for value in result.values()):
        raise RuntimeError("Random Forest produced a non-finite degradation prediction")
    return result


def choose_resource(predictions: dict[int, float], threshold: float) -> int:
    """Policy decision using predictions only: 16, then 32, then 64."""
    return next(
        (resource for resource in RESOURCE_LEVELS if predictions[resource] <= threshold),
        BASELINE_RESOURCE,
    )


def build_policy_decisions(
    model: torch.nn.Module,
    inputs: torch.Tensor,
    test_ids: list[int],
    forest: Any,
    threshold: float,
    device: torch.device,
    expected_layers: list[str],
) -> list[dict[str, Any]]:
    """Make all decisions without reading/using measured degradation values."""
    if max(test_ids) >= len(inputs):
        raise ValueError("test sample ID exceeds reconstructed V2 input count")
    model_layers = [
        name
        for name, module in model.named_modules()
        if name and isinstance(module, (torch.nn.Conv2d, torch.nn.Linear))
    ]
    if model_layers != expected_layers:
        raise RuntimeError(f"model layer order {model_layers} != V2 dataset order {expected_layers}")
    decisions: list[dict[str, Any]] = []
    for sample_id in test_ids:
        statistics = collect_one_sample_stats(model, inputs[sample_id], device)
        if [str(row["layer"]) for row in statistics] != model_layers:
            raise RuntimeError("pre-layer monitor did not return the expected layer order")
        for position, row in enumerate(statistics, start=1):
            sparsity = float(row["sparsity"])
            mean = float(row["mean"])
            variance = float(row["variance"])
            layer_position = position / len(model_layers)
            if not all(math.isfinite(value) for value in (sparsity, mean, variance)):
                raise RuntimeError(f"non-finite activation statistic for sample {sample_id}")
            predictions = predict_candidates(forest, sparsity, mean, variance, layer_position)
            selected = choose_resource(predictions, threshold)
            decisions.append(
                {
                    "sample_id": sample_id,
                    "layer": str(row["layer"]),
                    "layer_position": layer_position,
                    "sparsity": sparsity,
                    "mean": mean,
                    "variance": variance,
                    "predicted_D_16": predictions[16],
                    "predicted_D_32": predictions[32],
                    "predicted_D_64": predictions[64],
                    "selected_resource": selected,
                    "predicted_D_selected": predictions[selected],
                    "baseline_resource": BASELINE_RESOURCE,
                    "resource_reduction_fraction": 1 - selected / BASELINE_RESOURCE,
                }
            )
    expected_decisions = len(test_ids) * len(model_layers)
    if len(decisions) != expected_decisions:
        raise RuntimeError(f"expected {expected_decisions} decisions, generated {len(decisions)}")
    return decisions


def add_actual_evaluation(
    policy_decisions: list[dict[str, Any]], measured: dict[tuple[int, str, int], float], threshold: float
) -> list[dict[str, Any]]:
    """Attach actual data after policy selection, never before it."""
    evaluated: list[dict[str, Any]] = []
    for decision in policy_decisions:
        actual = measured[(int(decision["sample_id"]), str(decision["layer"]), int(decision["selected_resource"]))]
        evaluated.append(
            {
                **decision,
                "actual_D_selected": actual,
                "prediction_error": float(decision["predicted_D_selected"]) - actual,
                "threshold_satisfied_actual": actual <= threshold,
            }
        )
    return evaluated


def monotonicity_violations(values_by_case: dict[tuple[int, str], dict[int, float]]) -> list[dict[str, Any]]:
    violations: list[dict[str, Any]] = []
    for (sample_id, layer), values in sorted(values_by_case.items()):
        if values[16] < values[32]:
            violations.append({"sample_id": sample_id, "layer": layer, "relation": "D16 < D32"})
        if values[32] < values[64]:
            violations.append({"sample_id": sample_id, "layer": layer, "relation": "D32 < D64"})
    return violations


def candidate_maps(
    decisions: list[dict[str, Any]], measured: dict[tuple[int, str, int], float]
) -> tuple[dict[tuple[int, str], dict[int, float]], dict[tuple[int, str], dict[int, float]]]:
    predicted: dict[tuple[int, str], dict[int, float]] = {}
    actual: dict[tuple[int, str], dict[int, float]] = {}
    for row in decisions:
        key = (int(row["sample_id"]), str(row["layer"]))
        predicted[key] = {
            16: float(row["predicted_D_16"]),
            32: float(row["predicted_D_32"]),
            64: float(row["predicted_D_64"]),
        }
        actual[key] = {resource: measured[(key[0], key[1], resource)] for resource in RESOURCE_LEVELS}
    return predicted, actual


def summary_statistics(values: list[float]) -> dict[str, float]:
    return {
        "mean": float(np.mean(values)),
        "std": float(np.std(values)),
        "minimum": float(np.min(values)),
        "maximum": float(np.max(values)),
    }


def layer_rows(decisions: list[dict[str, Any]], threshold: float) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for decision in decisions:
        grouped[str(decision["layer"])].append(decision)
    rows: list[dict[str, Any]] = []
    for layer, values in grouped.items():
        selected = Counter(int(value["selected_resource"]) for value in values)
        violations = sum(not bool(value["threshold_satisfied_actual"]) for value in values)
        rows.append(
            {
                "layer": layer,
                "decisions": len(values),
                "selected_16": selected[16],
                "selected_32": selected[32],
                "selected_64": selected[64],
                "average_selected_resource": float(np.mean([value["selected_resource"] for value in values])),
                "average_resource_reduction": float(np.mean([value["resource_reduction_fraction"] for value in values])),
                "actual_threshold_violations": violations,
                "actual_threshold_violation_rate_percent": 100 * violations / len(values),
                "average_actual_D_selected": float(np.mean([value["actual_D_selected"] for value in values])),
                "average_abs_prediction_error": float(np.mean([abs(value["prediction_error"]) for value in values])),
                "threshold": threshold,
            }
        )
    return sorted(rows, key=lambda row: str(row["layer"]))


def resource_rows(decisions: list[dict[str, Any]], threshold: float) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for resource in RESOURCE_LEVELS:
        values = [row for row in decisions if int(row["selected_resource"]) == resource]
        violations = sum(not bool(row["threshold_satisfied_actual"]) for row in values)
        rows.append(
            {
                "selected_resource": resource,
                "decisions": len(values),
                "average_predicted_D_selected": float(np.mean([row["predicted_D_selected"] for row in values])) if values else None,
                "average_actual_D_selected": float(np.mean([row["actual_D_selected"] for row in values])) if values else None,
                "average_abs_prediction_error": float(np.mean([abs(row["prediction_error"]) for row in values])) if values else None,
                "actual_threshold_violations": violations,
                "actual_threshold_violation_rate_percent": 100 * violations / len(values) if values else 0.0,
                "resource_reduction_fraction": 1 - resource / BASELINE_RESOURCE,
                "threshold": threshold,
            }
        )
    return rows


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def plot_prediction_vs_actual(decisions: list[dict[str, Any]], path: Path) -> None:
    actual = np.asarray([float(row["actual_D_selected"]) for row in decisions])
    predicted = np.asarray([float(row["predicted_D_selected"]) for row in decisions])
    maximum = max(float(actual.max()), float(predicted.max()), 0.001)
    figure, axis = plt.subplots(figsize=(6.6, 5.4), constrained_layout=True)
    for resource, color in zip(RESOURCE_LEVELS, ("#2A9D8F", "#E9C46A", "#E76F51")):
        indices = [index for index, row in enumerate(decisions) if int(row["selected_resource"]) == resource]
        if indices:
            axis.scatter(actual[indices], predicted[indices], s=42, alpha=0.82, color=color, label=f"Selected {resource}")
    axis.plot([0, maximum], [0, maximum], "--", color="black", label="y=x")
    axis.set_xlabel("Actual selected-resource degradation")
    axis.set_ylabel("Predicted selected-resource degradation")
    axis.set_title("Stage 4 V2: predicted versus actual degradation")
    axis.grid(alpha=0.25)
    axis.legend()
    figure.savefig(path, dpi=180)
    plt.close(figure)


def plot_resource_distribution(decisions: list[dict[str, Any]], path: Path) -> None:
    counts = Counter(int(row["selected_resource"]) for row in decisions)
    figure, axis = plt.subplots(figsize=(6.4, 4.6), constrained_layout=True)
    resources = list(RESOURCE_LEVELS)
    bars = axis.bar(resources, [counts[resource] for resource in resources], color=["#2A9D8F", "#E9C46A", "#E76F51"], width=10)
    for bar, resource in zip(bars, resources):
        axis.text(bar.get_x() + bar.get_width() / 2, bar.get_height(), str(counts[resource]), ha="center", va="bottom")
    axis.set_xticks(resources)
    axis.set_xlabel("Selected resource level")
    axis.set_ylabel("Decision count")
    axis.set_title("Stage 4 V2 resource-selection distribution")
    axis.grid(axis="y", alpha=0.25)
    figure.savefig(path, dpi=180)
    plt.close(figure)


def plot_threshold_check(decisions: list[dict[str, Any]], threshold: float, path: Path) -> None:
    ordered = sorted(decisions, key=lambda row: (int(row["sample_id"]), str(row["layer"])))
    x_values = np.arange(len(ordered))
    actual = [float(row["actual_D_selected"]) for row in ordered]
    colors = ["#2A9D8F" if int(row["selected_resource"]) == 32 else "#E76F51" for row in ordered]
    figure, axis = plt.subplots(figsize=(11, 4.8), constrained_layout=True)
    axis.scatter(x_values, actual, c=colors, s=42, alpha=0.85, label="Actual selected-resource degradation")
    axis.axhline(threshold, color="black", linestyle="--", linewidth=1.3, label=f"D_MAX={threshold:.2f}")
    axis.set_xlabel("Test sample/layer decision index")
    axis.set_ylabel("Actual selected-resource degradation")
    axis.set_title("Stage 4 V2 controller threshold check")
    axis.grid(axis="y", alpha=0.25)
    axis.legend()
    figure.savefig(path, dpi=180)
    plt.close(figure)


def write_text_summary(
    path: Path,
    test_ids: list[int],
    decisions: list[dict[str, Any]],
    layer_summary: list[dict[str, Any]],
    resource_summary: list[dict[str, Any]],
    predicted_violations: list[dict[str, Any]],
    actual_violations: list[dict[str, Any]],
    threshold: float,
    baseline_average: float,
) -> None:
    selected = Counter(int(row["selected_resource"]) for row in decisions)
    reductions = [float(row["resource_reduction_fraction"]) for row in decisions]
    predicted_selected = [float(row["predicted_D_selected"]) for row in decisions]
    actual_selected = [float(row["actual_D_selected"]) for row in decisions]
    absolute_errors = [abs(float(row["prediction_error"])) for row in decisions]
    violations = [row for row in decisions if not bool(row["threshold_satisfied_actual"])]
    lines = [
        "Stage 4 V2 - Adaptive Resource Controller Evaluation",
        "====================================================",
        "",
        "Scope",
        "-----",
        "Policy decisions use only pre-layer activation statistics and the persisted V2",
        "Random Forest. Measured V2 degradation is joined only after selection for evaluation.",
        "This is an offline/PyTorch software resource-proxy experiment, not a hardware simulation.",
        "",
        "Evaluation set",
        "--------------",
        f"Test sample IDs ({len(test_ids)}): {test_ids}",
        f"Decisions: {len(decisions)} ({len(test_ids)} samples x 4 layers)",
        f"D_MAX: {threshold:.8f}",
        "",
        "Controller metrics",
        "------------------",
        f"Selection distribution: 16={selected[16]}, 32={selected[32]}, 64={selected[64]}",
        f"Average selected resource: {np.mean([row['selected_resource'] for row in decisions]):.8f}",
        f"Average resource reduction: {np.mean(reductions):.8f}",
        f"Minimum/maximum resource reduction: {min(reductions):.8f} / {max(reductions):.8f}",
        "Predicted selected-resource degradation: " + json.dumps(summary_statistics(predicted_selected)),
        "Actual selected-resource degradation: " + json.dumps(summary_statistics(actual_selected)),
        f"Average absolute prediction error: {np.mean(absolute_errors):.8f}",
        f"Maximum absolute prediction error: {max(absolute_errors):.8f}",
        f"Actual threshold-satisfying decisions: {len(decisions) - len(violations)}",
        f"Actual threshold violations: {len(violations)} ({100 * len(violations) / len(decisions):.8f}%)",
        "",
        "Fixed 64-resource baseline comparison",
        "------------------------------------",
        f"Baseline average actual degradation: {baseline_average:.8f}",
        f"Controller average actual degradation: {np.mean(actual_selected):.8f}",
        f"Controller actual threshold violation rate: {100 * len(violations) / len(decisions):.8f}%",
        f"Controller average resource reduction: {np.mean(reductions):.8f}",
        "This comparison does not establish energy savings or speedup.",
        "",
        "Resource selection by layer",
        "---------------------------",
        "layer       decisions  sel16  sel32  sel64  avg_resource  avg_reduction  actual_violation_rate",
    ]
    for row in layer_summary:
        lines.append(
            f"{row['layer']:<10} {row['decisions']:>9}  {row['selected_16']:>5}  {row['selected_32']:>5}  "
            f"{row['selected_64']:>5}  {row['average_selected_resource']:>12.8f}  "
            f"{row['average_resource_reduction']:>13.8f}  {row['actual_threshold_violation_rate_percent']:>20.8f}%"
        )
    lines.extend(
        [
            "",
            "Monotonicity checks",
            "-------------------",
            "Expected ordering: D16 >= D32 >= D64. No values were reordered or corrected.",
            f"Predicted cases: {len(decisions)}; relationship violations: {len(predicted_violations)}",
            f"Actual V2 cases: {len(decisions)}; relationship violations: {len(actual_violations)}",
            "",
            "Per-decision predicted-versus-actual evaluation",
            "----------------------------------------------",
            "sample_id  layer       Dhat16      Dhat32      Dhat64      selected  actual_selected  threshold_ok",
        ]
    )
    for row in sorted(decisions, key=lambda item: (int(item["sample_id"]), str(item["layer"]))):
        lines.append(
            f"{int(row['sample_id']):>9}  {str(row['layer']):<10}  {float(row['predicted_D_16']):>10.8f}  "
            f"{float(row['predicted_D_32']):>10.8f}  {float(row['predicted_D_64']):>10.8f}  "
            f"{int(row['selected_resource']):>8}  {float(row['actual_D_selected']):>15.8f}  "
            f"{bool(row['threshold_satisfied_actual'])}"
        )
    lines.extend(
        [
            "",
            "Limitations",
            "-----------",
            "Resource levels 16/32/64 remain deterministic software-proxy abstractions, not",
            "cycle-accurate PE counts. No hardware energy, latency, throughput, or speedup",
            "claim can be made, and SCALE-Sim is intentionally not invoked.",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    args = parse_args()
    if not math.isfinite(args.d_max):
        raise ValueError("--d-max must be finite")
    if args.device != "cpu" and not torch.cuda.is_available():
        raise ValueError(f"requested device {args.device!r}, but CUDA is not available")
    args.results_dir.mkdir(parents=True, exist_ok=True)

    test_ids = load_test_ids(args.metrics)
    forest = load_forest(args.forest)
    # The dataset is read here solely to provide post-policy ground truth and
    # test-input cardinality; it is not supplied to the selection policy.
    measured, sample_count, layers = load_actual_v2(args.dataset, test_ids)
    model, inputs = recreate_inputs(args.seed, sample_count, torch.device(args.device))
    policy_decisions = build_policy_decisions(
        model, inputs, test_ids, forest, args.d_max, torch.device(args.device), layers
    )
    decisions = add_actual_evaluation(policy_decisions, measured, args.d_max)
    if len(decisions) != 76:
        raise RuntimeError(f"expected 76 held-out controller decisions; received {len(decisions)}")

    predicted_candidates, actual_candidates = candidate_maps(decisions, measured)
    predicted_violations = monotonicity_violations(predicted_candidates)
    actual_violations = monotonicity_violations(actual_candidates)
    layer_summary = layer_rows(decisions, args.d_max)
    resource_summary = resource_rows(decisions, args.d_max)
    baseline_average = float(np.mean([values[BASELINE_RESOURCE] for values in actual_candidates.values()]))
    actual_baseline_maximum = max(abs(values[BASELINE_RESOURCE]) for values in actual_candidates.values())
    if actual_baseline_maximum > 1e-12:
        raise RuntimeError("V2 64-resource baseline degradation is not zero within tolerance")

    decisions_path = args.results_dir / "controller_decisions_v2.csv"
    by_layer_path = args.results_dir / "controller_by_layer_v2.csv"
    by_resource_path = args.results_dir / "controller_by_resource_v2.csv"
    summary_json_path = args.results_dir / "controller_summary_v2.json"
    prediction_plot_path = args.results_dir / "controller_prediction_vs_actual_v2.png"
    selection_plot_path = args.results_dir / "resource_selection_v2.png"
    threshold_plot_path = args.results_dir / "controller_threshold_check_v2.png"
    summary_text_path = args.results_dir / "stage4_v2_summary.txt"
    write_csv(decisions_path, decisions, DECISION_FIELDS)
    write_csv(by_layer_path, layer_summary, list(layer_summary[0]))
    write_csv(by_resource_path, resource_summary, list(resource_summary[0]))
    plot_prediction_vs_actual(decisions, prediction_plot_path)
    plot_resource_distribution(decisions, selection_plot_path)
    plot_threshold_check(decisions, args.d_max, threshold_plot_path)

    selection_counts = Counter(int(row["selected_resource"]) for row in decisions)
    threshold_violations = sum(not bool(row["threshold_satisfied_actual"]) for row in decisions)
    summary = {
        "experiment": "Stage 4 V2 - Adaptive Resource Controller",
        "research_scope": "offline PyTorch software-proxy controller evaluation; no cycle-accurate hardware simulation",
        "test_sample_ids": test_ids,
        "test_samples": len(test_ids),
        "decisions": len(decisions),
        "layers": layers,
        "policy": {
            "estimator": str(args.forest),
            "features": FEATURE_NAMES,
            "d_max": args.d_max,
            "resource_order": list(RESOURCE_LEVELS),
            "baseline_resource": BASELINE_RESOURCE,
            "selection_rule": "smallest predicted-safe resource; fallback to 64",
            "actual_measurements_used_for_selection": False,
        },
        "selection_distribution": {str(resource): selection_counts[resource] for resource in RESOURCE_LEVELS},
        "selected_resource_statistics": summary_statistics([float(row["selected_resource"]) for row in decisions]),
        "resource_reduction_statistics": summary_statistics([float(row["resource_reduction_fraction"]) for row in decisions]),
        "predicted_selected_degradation_statistics": summary_statistics([float(row["predicted_D_selected"]) for row in decisions]),
        "actual_selected_degradation_statistics": summary_statistics([float(row["actual_D_selected"]) for row in decisions]),
        "average_absolute_prediction_error": float(np.mean([abs(float(row["prediction_error"])) for row in decisions])),
        "maximum_absolute_prediction_error": float(max(abs(float(row["prediction_error"])) for row in decisions)),
        "threshold_correctness": {
            "satisfying": len(decisions) - threshold_violations,
            "violating": threshold_violations,
            "violation_rate_percent": 100 * threshold_violations / len(decisions),
        },
        "baseline_comparison": {
            "fixed_resource": BASELINE_RESOURCE,
            "baseline_average_actual_degradation": baseline_average,
            "controller_average_actual_degradation": float(np.mean([row["actual_D_selected"] for row in decisions])),
            "controller_actual_threshold_violation_rate_percent": 100 * threshold_violations / len(decisions),
            "controller_average_resource_reduction": float(np.mean([row["resource_reduction_fraction"] for row in decisions])),
        },
        "predicted_monotonicity": {
            "cases": len(decisions),
            "relationship_violations": len(predicted_violations),
            "violations_by_layer": dict(sorted(Counter(row["layer"] for row in predicted_violations).items())),
        },
        "actual_v2_monotonicity": {
            "cases": len(decisions),
            "relationship_violations": len(actual_violations),
            "violations_by_layer": dict(sorted(Counter(row["layer"] for row in actual_violations).items())),
        },
        "files": {
            "decisions": str(decisions_path),
            "by_layer": str(by_layer_path),
            "by_resource": str(by_resource_path),
            "prediction_vs_actual_plot": str(prediction_plot_path),
            "resource_selection_plot": str(selection_plot_path),
            "threshold_check_plot": str(threshold_plot_path),
        },
    }
    with summary_json_path.open("w", encoding="utf-8") as stream:
        json.dump(summary, stream, indent=2)
        stream.write("\n")
    write_text_summary(
        summary_text_path,
        test_ids,
        decisions,
        layer_summary,
        resource_summary,
        predicted_violations,
        actual_violations,
        args.d_max,
        baseline_average,
    )

    print("Stage 4 V2 - Adaptive Resource Controller")
    print(f"Held-out test samples: {len(test_ids)}")
    print(f"Decisions: {len(decisions)}")
    print(f"Selection distribution: 16={selection_counts[16]}, 32={selection_counts[32]}, 64={selection_counts[64]}")
    print(f"Average selected resource: {np.mean([row['selected_resource'] for row in decisions]):.8f}")
    print(f"Average resource reduction: {np.mean([row['resource_reduction_fraction'] for row in decisions]):.8f}")
    print(f"Actual threshold violations: {threshold_violations} ({100 * threshold_violations / len(decisions):.8f}%)")
    print(f"Average absolute prediction error: {np.mean([abs(row['prediction_error']) for row in decisions]):.8f}")
    print(f"Maximum absolute prediction error: {max(abs(row['prediction_error']) for row in decisions):.8f}")
    print(f"Predicted monotonicity violations: {len(predicted_violations)}")
    print(f"Actual V2 monotonicity violations: {len(actual_violations)}")
    print("\nPer-decision evaluation:")
    print("Sample  Layer       Dhat16      Dhat32      Dhat64      Selected  Actual D   Threshold")
    for row in sorted(decisions, key=lambda item: (int(item["sample_id"]), str(item["layer"]))):
        print(
            f"{int(row['sample_id']):>6}  {str(row['layer']):<10}  {float(row['predicted_D_16']):>10.8f}  "
            f"{float(row['predicted_D_32']):>10.8f}  {float(row['predicted_D_64']):>10.8f}  "
            f"{int(row['selected_resource']):>8}  {float(row['actual_D_selected']):>8.6f}  {bool(row['threshold_satisfied_actual'])}"
        )
    print("\nFiles created:")
    for path in (
        decisions_path,
        summary_json_path,
        by_layer_path,
        by_resource_path,
        prediction_plot_path,
        selection_plot_path,
        threshold_plot_path,
        summary_text_path,
    ):
        print(f"  {path}")


if __name__ == "__main__":
    main()
