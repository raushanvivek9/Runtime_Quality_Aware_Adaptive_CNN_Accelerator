#!/usr/bin/env python3
import torch
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from common import CifarVgg16Canonical


def check_dataset(name: str, classes: int):
    model = CifarVgg16Canonical(classes)
    x = torch.randn(4, 3, 32, 32)
    y = model(x)
    feat = model.features(x)
    print(f"[{name}] output shape: {tuple(y.shape)}")
    print(f"[{name}] parameter count: {sum(p.numel() for p in model.parameters())}")
    print(f"[{name}] trainable parameter count: {sum(p.numel() for p in model.parameters() if p.requires_grad)}")
    print(f"[{name}] feature output shape: {tuple(feat.shape)}")
    print(f"[{name}] logits mean/std/min/max: {y.mean().item():.6f} / {y.std().item():.6f} / {y.min().item():.6f} / {y.max().item():.6f}")
    assert y.shape == (4, classes)
    assert torch.isfinite(y).all()
    print(f"[{name}] architecture:")
    print(model)
    print()


if __name__ == "__main__":
    check_dataset("cifar10", 10)
    check_dataset("cifar100", 100)
