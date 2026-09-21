"""Versioned software resource-reduction proxy for the corrected experiment.

Conv2d layers retain the Stage-2 structured output-channel reduction.  The
terminal classifier is intentionally different: it retains all output logits
and reduces MACs by selecting input-feature columns.  This preserves class
semantics while remaining a software proxy rather than a PE simulation.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass

import torch
from torch import Tensor, nn
from torch.nn import functional as F


RESOURCE_LEVELS = (16, 32, 64)
FULL_RESOURCE_LEVEL = 64
PROXY_NAME_V2 = (
    "v2_conv_output_channel_reduction_classifier_input_feature_reduction"
)


def selected_evenly_spaced_indices(total_features: int, resource_level: int) -> Tensor:
    """Select a deterministic 16/32/64-proportional subset of feature indices."""
    if resource_level not in RESOURCE_LEVELS:
        raise ValueError(f"unsupported resource level: {resource_level}")
    if total_features < 1:
        raise ValueError("total_features must be positive")
    retained = max(1, round(total_features * resource_level / FULL_RESOURCE_LEVEL))
    retained = min(retained, total_features)
    return torch.div(
        torch.arange(retained) * total_features,
        retained,
        rounding_mode="floor",
    )


@dataclass(frozen=True)
class ResourceProfileV2:
    """Compact accounting metadata for one layer/resource configuration."""

    layer_type: str
    resource_level: int
    original_input_features: int
    original_output_features: int
    retained_input_features: int
    retained_output_features: int

    @property
    def retained_input_fraction(self) -> float:
        return self.retained_input_features / self.original_input_features

    @property
    def retained_output_fraction(self) -> float:
        return self.retained_output_features / self.original_output_features


def profile_for_module_v2(module: nn.Module, resource_level: int) -> ResourceProfileV2:
    """Describe exactly what V2 retains without constructing a copied model."""
    if isinstance(module, nn.Conv2d):
        retained_output = selected_evenly_spaced_indices(
            module.out_channels, resource_level
        ).numel()
        return ResourceProfileV2(
            layer_type="Conv2d",
            resource_level=resource_level,
            original_input_features=module.in_channels,
            original_output_features=module.out_channels,
            retained_input_features=module.in_channels,
            retained_output_features=retained_output,
        )
    if isinstance(module, nn.Linear):
        retained_input = selected_evenly_spaced_indices(
            module.in_features, resource_level
        ).numel()
        return ResourceProfileV2(
            layer_type="Linear",
            resource_level=resource_level,
            original_input_features=module.in_features,
            original_output_features=module.out_features,
            retained_input_features=retained_input,
            retained_output_features=module.out_features,
        )
    raise TypeError(f"unsupported resource-reduced module: {type(module).__name__}")


class ReducedConv2dV2(nn.Module):
    """Keep selected output channels and zero-fill omitted Conv2d channels."""

    def __init__(self, source: nn.Conv2d, resource_level: int) -> None:
        super().__init__()
        if source.groups != 1 or source.padding_mode != "zeros":
            raise ValueError(
                "ReducedConv2dV2 supports only ungrouped, zero-padded Conv2d layers."
            )
        self.source = source
        self.register_buffer(
            "active_output_indices",
            selected_evenly_spaced_indices(source.out_channels, resource_level),
        )
        self.resource_level = resource_level

    @property
    def retained_input_features(self) -> int:
        return self.source.in_channels

    @property
    def retained_output_features(self) -> int:
        return int(self.active_output_indices.numel())

    @property
    def retained_output_fraction(self) -> float:
        return self.retained_output_features / self.source.out_channels

    def forward(self, inputs: Tensor) -> Tensor:
        weight = self.source.weight.index_select(0, self.active_output_indices)
        bias = (
            None
            if self.source.bias is None
            else self.source.bias.index_select(0, self.active_output_indices)
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
        output_shape = list(active_outputs.shape)
        output_shape[1] = self.source.out_channels
        outputs = active_outputs.new_zeros(output_shape)
        return outputs.index_copy(1, self.active_output_indices, active_outputs)


class ReducedClassifierLinearV2(nn.Module):
    """Reduce classifier input columns while preserving every output class/logit."""

    def __init__(self, source: nn.Linear, resource_level: int) -> None:
        super().__init__()
        self.source = source
        self.register_buffer(
            "active_input_indices",
            selected_evenly_spaced_indices(source.in_features, resource_level),
        )
        self.resource_level = resource_level

    @property
    def retained_input_features(self) -> int:
        return int(self.active_input_indices.numel())

    @property
    def retained_output_features(self) -> int:
        return self.source.out_features

    @property
    def retained_output_fraction(self) -> float:
        return 1.0

    def forward(self, inputs: Tensor) -> Tensor:
        selected_inputs = inputs.index_select(-1, self.active_input_indices)
        selected_weight = self.source.weight.index_select(1, self.active_input_indices)
        # The unmodified bias and all output rows are retained, so the result
        # always has shape [..., out_features] (batch x 10 for SimpleCNN).
        return F.linear(selected_inputs, selected_weight, self.source.bias)


def replace_module_v2(model: nn.Module, name: str, replacement: nn.Module) -> None:
    """Replace one child module in a disposable deep copy of a model."""
    parent = model
    for part in name.split(".")[:-1]:
        parent = getattr(parent, part)
    setattr(parent, name.split(".")[-1], replacement)


def resource_reduced_model_v2(
    baseline_model: nn.Module,
    layer_name: str,
    resource_level: int,
    device: torch.device,
) -> tuple[nn.Module, ResourceProfileV2]:
    """Copy a model and apply the V2 proxy to exactly one monitored layer.

    V2 is deliberately limited to the current architecture: every Conv2d uses
    output-channel reduction and the named final ``classifier`` Linear uses
    input-feature reduction.  A different Linear layer is rejected rather than
    silently applying an unintended rule.
    """
    model = copy.deepcopy(baseline_model).to(device).eval()
    source = dict(model.named_modules()).get(layer_name)
    if source is None:
        raise KeyError(f"layer not found: {layer_name}")
    profile = profile_for_module_v2(source, resource_level)
    if isinstance(source, nn.Conv2d):
        replacement: nn.Module = ReducedConv2dV2(source, resource_level)
    elif isinstance(source, nn.Linear) and layer_name == "classifier":
        replacement = ReducedClassifierLinearV2(source, resource_level)
    elif isinstance(source, nn.Linear):
        raise ValueError(
            "V2 input-feature reduction is defined only for the terminal "
            f"classifier, not Linear layer {layer_name!r}."
        )
    else:
        raise TypeError(f"unsupported resource-reduced module: {type(source).__name__}")
    replace_module_v2(model, layer_name, replacement)
    return model, profile
