#!/usr/bin/env python3
"""Local CIFAR pickle loader and CIFAR-compatible models for Stage 12 v3."""
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
    def __init__(self, name: str, train: bool, augment: bool = False):
        folder = DATA_DIR / ("cifar-10-batches-py" if name == "cifar10" else "cifar-100-python")
        files = [f"data_batch_{i}" for i in range(1, 6)] if name == "cifar10" and train else (["test_batch"] if name == "cifar10" else (["train"] if train else ["test"]))
        label_key = b"labels" if name == "cifar10" else b"fine_labels"
        images, labels = [], []
        for filename in files:
            with (folder / filename).open("rb") as handle:
                payload = pickle.load(handle, encoding="bytes")
            images.append(np.asarray(payload[b"data"], dtype=np.uint8)); labels.extend(payload[label_key])
        self.images = np.concatenate(images).reshape(-1, 3, 32, 32); self.labels = np.asarray(labels, dtype=np.int64); self.augment = augment
        self.mean = torch.tensor(MEAN).view(3, 1, 1); self.std = torch.tensor(STD).view(3, 1, 1)

    def __len__(self): return len(self.labels)

    def __getitem__(self, index):
        image = torch.from_numpy(self.images[index]).float().div(255.0)
        if self.augment:
            padded = torch.nn.functional.pad(image, (4, 4, 4, 4), mode="reflect")
            top = int(torch.randint(0, 9, ()).item()); left = int(torch.randint(0, 9, ()).item()); image = padded[:, top:top + 32, left:left + 32]
            if bool(torch.randint(0, 2, ()).item()): image = torch.flip(image, dims=(2,))
        return (image - self.mean) / self.std, int(self.labels[index])

class BasicBlock(nn.Module):
    def __init__(self, in_channels, out_channels, stride):
        super().__init__(); self.conv1 = nn.Conv2d(in_channels, out_channels, 3, stride, 1, bias=False); self.bn1 = nn.BatchNorm2d(out_channels); self.relu1 = nn.ReLU(False); self.conv2 = nn.Conv2d(out_channels, out_channels, 3, 1, 1, bias=False); self.bn2 = nn.BatchNorm2d(out_channels); self.shortcut = nn.Identity() if stride == 1 and in_channels == out_channels else nn.Sequential(nn.Conv2d(in_channels, out_channels, 1, stride, bias=False), nn.BatchNorm2d(out_channels)); self.relu2 = nn.ReLU(False)
    def forward(self, value):
        residual = self.shortcut(value); value = self.relu1(self.bn1(self.conv1(value))); return self.relu2(self.bn2(self.conv2(value)) + residual)

class CifarResNet18(nn.Module):
    def __init__(self, classes):
        super().__init__(); self.conv1 = nn.Conv2d(3, 64, 3, 1, 1, bias=False); self.bn1 = nn.BatchNorm2d(64); self.relu = nn.ReLU(False); self.layer1 = self._layer(64, 64, 2, 1); self.layer2 = self._layer(64, 128, 2, 2); self.layer3 = self._layer(128, 256, 2, 2); self.layer4 = self._layer(256, 512, 2, 2); self.avgpool = nn.AdaptiveAvgPool2d((1, 1)); self.fc = nn.Linear(512, classes)
    def _layer(self, in_channels, out_channels, blocks, stride): return nn.Sequential(BasicBlock(in_channels, out_channels, stride), *(BasicBlock(out_channels, out_channels, 1) for _ in range(blocks - 1)))
    def forward(self, value):
        value = self.relu(self.bn1(self.conv1(value))); value = self.layer4(self.layer3(self.layer2(self.layer1(value)))); return self.fc(self.avgpool(value).flatten(1))

class CifarVgg16(nn.Module):
    def __init__(self, classes):
        super().__init__(); spec = [64, 64, "M", 128, 128, "M", 256, 256, 256, "M", 512, 512, 512, "M", 512, 512, 512, "M"]; layers = []; in_channels = 3
        for item in spec:
            if item == "M": layers.append(nn.MaxPool2d(2, 2))
            else: layers.extend((nn.Conv2d(in_channels, item, 3, 1, 1), nn.ReLU(False))); in_channels = item
        self.features = nn.Sequential(*layers); self.avgpool = nn.AdaptiveAvgPool2d((1, 1)); self.classifier = nn.Linear(512, classes)
    def forward(self, value): return self.classifier(self.avgpool(self.features(value)).flatten(1))

class CifarVgg16Canonical(nn.Module):
    """Canonical CIFAR-compatible VGG-16 implementation for Stage 12 v3.

    This matches the standard VGG-16 block layout (64,64;128,128;256,256,256;512,512,512;512,512,512)
    with 3x3 convs, ReLU(inplace=True), and 2x2 max-pooling while correctly handling 32x32 CIFAR inputs.
    """
    def __init__(self, classes, batch_norm=False):
        super().__init__()
        self.batch_norm = batch_norm
        def conv_block(in_channels, out_channels):
            layers = [nn.Conv2d(in_channels, out_channels, kernel_size=3, stride=1, padding=1)]
            if batch_norm:
                layers.append(nn.BatchNorm2d(out_channels))
            layers.append(nn.ReLU(inplace=True))
            return layers
        self.features = nn.Sequential(
            *conv_block(3, 64), *conv_block(64, 64),
            nn.MaxPool2d(kernel_size=2, stride=2),
            *conv_block(64, 128), *conv_block(128, 128),
            nn.MaxPool2d(kernel_size=2, stride=2),
            *conv_block(128, 256), *conv_block(256, 256), *conv_block(256, 256),
            nn.MaxPool2d(kernel_size=2, stride=2),
            *conv_block(256, 512), *conv_block(512, 512), *conv_block(512, 512),
            nn.MaxPool2d(kernel_size=2, stride=2),
            *conv_block(512, 512), *conv_block(512, 512), *conv_block(512, 512),
            nn.MaxPool2d(kernel_size=2, stride=2),
        )
        self.avgpool = nn.AdaptiveAvgPool2d((1, 1))
        self.classifier = nn.Sequential(
            nn.Linear(512, 4096), nn.ReLU(inplace=True), nn.Dropout(p=0.5),
            nn.Linear(4096, 4096), nn.ReLU(inplace=True), nn.Dropout(p=0.5),
            nn.Linear(4096, classes),
        )

    def forward(self, value):
        value = self.features(value)
        value = self.avgpool(value)
        value = torch.flatten(value, 1)
        return self.classifier(value)


def make_model(name, classes):
    if name == "resnet18":
        return CifarResNet18(classes)
    if name == "vgg16":
        # CIFAR100 needs BatchNorm to avoid the verified no-learning failure of the
        # original unnormalized canonical VGG path; CIFAR10 keeps its validated model.
        return CifarVgg16Canonical(classes, batch_norm=classes == 100)
    return CifarVgg16(classes)

def seed_everything(seed):
    import random
    random.seed(seed); np.random.seed(seed); torch.manual_seed(seed)
    if torch.cuda.is_available(): torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.deterministic = True; torch.backends.cudnn.benchmark = False
