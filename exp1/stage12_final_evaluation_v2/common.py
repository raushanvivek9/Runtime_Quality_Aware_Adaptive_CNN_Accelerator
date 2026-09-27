#!/usr/bin/env python3
"""Shared local CIFAR loaders and CIFAR-compatible models for Stage 12 v2."""
from __future__ import annotations

import pickle
from pathlib import Path
import numpy as np
import torch
from torch import nn

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT.parent / "stage12_final_evaluation" / "data"
MEAN = (0.4914, 0.4822, 0.4465)
STD = (0.2470, 0.2435, 0.2616)

class CifarDataset(torch.utils.data.Dataset):
    def __init__(self, name: str, train: bool):
        folder = DATA_DIR / ("cifar-10-batches-py" if name == "cifar10" else "cifar-100-python")
        if name == "cifar10":
            files = [f"data_batch_{i}" for i in range(1, 6)] if train else ["test_batch"]
            label_key = b"labels"
        else:
            files = ["train"] if train else ["test"]
            label_key = b"fine_labels"
        images, labels = [], []
        for filename in files:
            with (folder / filename).open("rb") as handle:
                payload = pickle.load(handle, encoding="bytes")
            images.append(np.asarray(payload[b"data"], dtype=np.uint8))
            labels.extend(payload[label_key])
        self.images = np.concatenate(images).reshape(-1, 3, 32, 32)
        self.labels = np.asarray(labels, dtype=np.int64)
        self.mean = torch.tensor(MEAN).view(3, 1, 1)
        self.std = torch.tensor(STD).view(3, 1, 1)

    def __len__(self):
        return len(self.labels)

    def __getitem__(self, index):
        image = torch.from_numpy(self.images[index]).float().div(255.0)
        return (image - self.mean) / self.std, int(self.labels[index])

class BasicBlock(nn.Module):
    def __init__(self, in_channels: int, out_channels: int, stride: int):
        super().__init__()
        self.conv1 = nn.Conv2d(in_channels, out_channels, 3, stride, 1, bias=False)
        self.bn1 = nn.BatchNorm2d(out_channels)
        self.relu1 = nn.ReLU(inplace=False)
        self.conv2 = nn.Conv2d(out_channels, out_channels, 3, 1, 1, bias=False)
        self.bn2 = nn.BatchNorm2d(out_channels)
        self.shortcut = nn.Identity() if stride == 1 and in_channels == out_channels else nn.Sequential(nn.Conv2d(in_channels, out_channels, 1, stride, bias=False), nn.BatchNorm2d(out_channels))
        self.relu2 = nn.ReLU(inplace=False)

    def forward(self, value):
        residual = self.shortcut(value)
        value = self.relu1(self.bn1(self.conv1(value)))
        return self.relu2(self.bn2(self.conv2(value)) + residual)

class CifarResNet18(nn.Module):
    def __init__(self, classes: int):
        super().__init__()
        self.conv1 = nn.Conv2d(3, 64, 3, 1, 1, bias=False)
        self.bn1 = nn.BatchNorm2d(64)
        self.relu = nn.ReLU(inplace=False)
        self.layer1 = self._make_layer(64, 64, 2, 1)
        self.layer2 = self._make_layer(64, 128, 2, 2)
        self.layer3 = self._make_layer(128, 256, 2, 2)
        self.layer4 = self._make_layer(256, 512, 2, 2)
        self.avgpool = nn.AdaptiveAvgPool2d((1, 1))
        self.fc = nn.Linear(512, classes)

    def _make_layer(self, in_channels, out_channels, count, stride):
        return nn.Sequential(BasicBlock(in_channels, out_channels, stride), *(BasicBlock(out_channels, out_channels, 1) for _ in range(count - 1)))

    def forward(self, value):
        value = self.relu(self.bn1(self.conv1(value)))
        value = self.layer4(self.layer3(self.layer2(self.layer1(value))))
        return self.fc(self.avgpool(value).flatten(1))

class CifarVgg16(nn.Module):
    def __init__(self, classes: int):
        super().__init__()
        specification = [64, 64, "M", 128, 128, "M", 256, 256, 256, "M", 512, 512, 512, "M", 512, 512, 512, "M"]
        layers, in_channels = [], 3
        for item in specification:
            if item == "M":
                layers.append(nn.MaxPool2d(2, 2))
            else:
                layers.extend((nn.Conv2d(in_channels, item, 3, 1, 1), nn.ReLU(inplace=False)))
                in_channels = item
        self.features = nn.Sequential(*layers)
        self.avgpool = nn.AdaptiveAvgPool2d((1, 1))
        self.classifier = nn.Linear(512, classes)

    def forward(self, value):
        return self.classifier(self.avgpool(self.features(value)).flatten(1))

def make_model(model: str, classes: int) -> nn.Module:
    return CifarResNet18(classes) if model == "resnet18" else CifarVgg16(classes)

def seed_everything(seed: int) -> None:
    import random
    random.seed(seed); np.random.seed(seed); torch.manual_seed(seed)
    if torch.cuda.is_available(): torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.deterministic = True; torch.backends.cudnn.benchmark = False
