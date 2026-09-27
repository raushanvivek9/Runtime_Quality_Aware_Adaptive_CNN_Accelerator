#!/usr/bin/env python3
from __future__ import annotations
import json, time
from pathlib import Path
import torch
from torch import nn
import yaml
from common import CifarDataset, make_model, seed_everything

ROOT = Path(__file__).resolve().parent; config = yaml.safe_load((ROOT / "CONFIG.yaml").read_text()); device = torch.device("cuda:0")
seed_everything(config["seed"])
train_dataset = CifarDataset("cifar10", True, augment=True); val_dataset = CifarDataset("cifar10", True, augment=False)
train_loader = torch.utils.data.DataLoader(torch.utils.data.Subset(train_dataset, range(5000, 50000)), batch_size=128, shuffle=True, num_workers=0)
val_loader = torch.utils.data.DataLoader(torch.utils.data.Subset(val_dataset, range(5000)), batch_size=128, shuffle=False, num_workers=0)
model = make_model("resnet18", 10).to(device); optimizer = torch.optim.SGD(model.parameters(), lr=0.1, momentum=0.9, weight_decay=5e-4); loss_fn = nn.CrossEntropyLoss(); model.train(); started = time.time(); loss_sum = correct = total = 0
for images, labels in train_loader:
    images, labels = images.to(device), labels.to(device); optimizer.zero_grad(set_to_none=True); logits = model(images); loss = loss_fn(logits, labels); loss.backward(); optimizer.step(); loss_sum += float(loss.detach()) * labels.numel(); correct += int((logits.argmax(1) == labels).sum()); total += labels.numel()
model.eval(); val_loss_sum = val_correct = val_total = 0
with torch.no_grad():
    for images, labels in val_loader:
        labels = labels.to(device); logits = model(images.to(device)); val_loss_sum += float(loss_fn(logits, labels)) * labels.numel(); val_correct += int((logits.argmax(1) == labels).sum()); val_total += labels.numel()
torch.cuda.synchronize(); elapsed = time.time() - started
result = {"model": "resnet18", "dataset": "cifar10", "training_samples": total, "validation_samples": val_total, "batch_size": 128, "epoch_seconds": elapsed, "train_loss": loss_sum / total, "train_accuracy": correct / total, "validation_loss": val_loss_sum / val_total, "validation_accuracy": val_correct / val_total, "device": str(device), "gpu": torch.cuda.get_device_name(0)}
print(json.dumps(result, indent=2))
print(f"estimated_50_epochs_hours={elapsed * 50 / 3600:.4f}")
print(f"estimated_100_epochs_hours={elapsed * 100 / 3600:.4f}")
print(f"estimated_150_epochs_hours={elapsed * 150 / 3600:.4f}")
