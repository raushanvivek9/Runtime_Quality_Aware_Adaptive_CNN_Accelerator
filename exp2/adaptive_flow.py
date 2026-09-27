"""Feed-forward adaptive PE selection for Experiment 2.

This module is a controller scaffold. It consumes per-layer degradation
predictions from a learned estimator; it does not claim that the predictions
are measured accuracy unless they were produced from a validated dataset.
"""

from __future__ import annotations

from dataclasses import dataclass
from math import isfinite
from typing import Callable, Mapping, Sequence

RESOURCE_LEVELS = (16, 32, 64)


def _clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(value, upper))


@dataclass(frozen=True)
class LayerFeatures:
    """Statistics observed before a layer executes."""

    name: str
    position: float
    sparsity: float
    mean: float
    variance: float


@dataclass(frozen=True)
class QualitySignal:
    """Quality state forwarded from one layer to the next layer.

    A positive normalized margin means the selected resource is predicted to
    be comfortably within the degradation budget. A negative margin means the
    selected resource exceeded the budget. The signal is a controller state,
    not a measured accuracy value by itself.
    """

    normalized_margin: float
    selected_resource: int
    predicted_degradation: float

    @classmethod
    def from_decision(
        cls, selected_resource: int, predicted_degradation: float, threshold: float
    ) -> "QualitySignal":
        if threshold <= 0:
            raise ValueError("threshold must be positive")
        margin = (threshold - predicted_degradation) / threshold
        return cls(
            normalized_margin=_clamp(margin, -1.0, 1.0),
            selected_resource=selected_resource,
            predicted_degradation=predicted_degradation,
        )


@dataclass(frozen=True)
class LayerDecision:
    """Resource decision and the signal that will be forwarded."""

    layer: str
    selected_resource: int
    threshold_used: float
    predicted_degradation: Mapping[int, float]
    signal: QualitySignal


class AdaptivePEController:
    """Select resources while carrying quality state between layers."""

    def __init__(self, max_degradation: float = 0.05, feed_forward_gain: float = 0.20):
        if max_degradation <= 0:
            raise ValueError("max_degradation must be positive")
        if feed_forward_gain < 0:
            raise ValueError("feed_forward_gain must be non-negative")
        self.max_degradation = max_degradation
        self.feed_forward_gain = feed_forward_gain

    def _threshold(self, previous_signal: QualitySignal | None) -> float:
        if previous_signal is None:
            return self.max_degradation
        adjustment = 1.0 + self.feed_forward_gain * previous_signal.normalized_margin
        return max(self.max_degradation * adjustment, 0.0)

    def select_layer(
        self,
        features: LayerFeatures,
        predicted_degradation: Mapping[int, float],
        previous_signal: QualitySignal | None = None,
    ) -> LayerDecision:
        """Select the smallest safe resource and forward its quality signal."""
        missing = set(RESOURCE_LEVELS) - set(predicted_degradation)
        if missing:
            raise ValueError(f"missing predictions for resources: {sorted(missing)}")
        values = {resource: float(predicted_degradation[resource]) for resource in RESOURCE_LEVELS}
        if not all(isfinite(value) for value in values.values()):
            raise ValueError("predicted degradation must be finite")

        threshold = self._threshold(previous_signal)
        selected = next(
            (resource for resource in RESOURCE_LEVELS if values[resource] <= threshold),
            RESOURCE_LEVELS[-1],
        )
        signal = QualitySignal.from_decision(selected, values[selected], threshold)
        return LayerDecision(
            layer=features.name,
            selected_resource=selected,
            threshold_used=threshold,
            predicted_degradation=values,
            signal=signal,
        )

    def run(
        self,
        layers: Sequence[LayerFeatures],
        predictor: Callable[[LayerFeatures, int], float],
    ) -> list[LayerDecision]:
        """Run the sequential controller over a model's monitored layers."""
        decisions: list[LayerDecision] = []
        previous_signal: QualitySignal | None = None
        for features in layers:
            predictions = {
                resource: predictor(features, resource) for resource in RESOURCE_LEVELS
            }
            decision = self.select_layer(features, predictions, previous_signal)
            decisions.append(decision)
            previous_signal = decision.signal
        return decisions
