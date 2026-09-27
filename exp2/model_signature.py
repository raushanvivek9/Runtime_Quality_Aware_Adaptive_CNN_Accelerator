"""Model-signature detection and reconfiguration metadata for Experiment 2."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from typing import Any, Iterable


@dataclass(frozen=True)
class ModelSignature:
    """Stable architecture signature used to detect unseen models."""

    identifier: str
    layers: tuple[dict[str, Any], ...]


@dataclass(frozen=True)
class SignatureObservation:
    signature: ModelSignature
    known: bool
    action: str


def _module_descriptor(name: str, module: Any) -> dict[str, Any] | None:
    class_name = type(module).__name__
    relevant_attributes = (
        "in_channels",
        "out_channels",
        "kernel_size",
        "stride",
        "padding",
        "groups",
        "in_features",
        "out_features",
    )
    descriptor: dict[str, Any] = {"name": name, "type": class_name}
    found_attribute = False
    for attribute in relevant_attributes:
        if hasattr(module, attribute):
            value = getattr(module, attribute)
            if isinstance(value, tuple):
                value = list(value)
            descriptor[attribute] = value
            found_attribute = True
    if class_name in {"Conv1d", "Conv2d", "Conv3d", "Linear"} or found_attribute:
        return descriptor
    return None


def build_model_signature(model: Any) -> ModelSignature:
    """Build a deterministic signature from named CNN compute modules."""
    if not callable(getattr(model, "named_modules", None)):
        raise TypeError("model must provide named_modules()")
    descriptors = []
    for name, module in model.named_modules():
        if not name:
            continue
        descriptor = _module_descriptor(str(name), module)
        if descriptor is not None:
            descriptors.append(descriptor)
    if not descriptors:
        raise ValueError("model signature contains no supported compute layers")
    canonical = json.dumps(descriptors, sort_keys=True, separators=(",", ":"))
    identifier = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]
    return ModelSignature(identifier=identifier, layers=tuple(descriptors))


class SignatureRegistry:
    """Remember known model signatures and describe unseen-model actions."""

    def __init__(self, known_identifiers: Iterable[str] = ()) -> None:
        self._known_identifiers = set(known_identifiers)

    def observe(self, model: Any) -> SignatureObservation:
        signature = build_model_signature(model)
        known = signature.identifier in self._known_identifiers
        if not known:
            self._known_identifiers.add(signature.identifier)
        action = "reuse_controller" if known else "calibrate_and_reconfigure"
        return SignatureObservation(signature=signature, known=known, action=action)

    def reconfiguration_plan(self, observation: SignatureObservation) -> dict[str, Any]:
        """Return metadata for a SCALE-Sim/controller reconfiguration step."""
        return {
            "model_signature": observation.signature.identifier,
            "action": observation.action,
            "layer_count": len(observation.signature.layers),
            "resource_levels": [16, 32, 64],
            "requires_new_calibration": not observation.known,
        }
