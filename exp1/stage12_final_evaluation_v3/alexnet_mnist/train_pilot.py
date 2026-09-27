import csv
import json
import platform
import random
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn

from dataset import make_loaders
from model import AlexNetMNIST


ROOT = Path(__file__).resolve().parent
SEED = 42
BATCH_SIZE = 128
EPOCHS = 5
LEARNING_RATE = 0.1
MOMENTUM = 0.9
WEIGHT_DECAY = 5e-4


def seed_everything():
    random.seed(SEED)
    np.random.seed(SEED)
    torch.manual_seed(SEED)
    torch.cuda.manual_seed_all(SEED)
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False


def write_environment(device):
    lines = [
        f"python_version={platform.python_version()}",
        f"torch_version={torch.__version__}",
    ]
    try:
        import torchvision
        lines.append(f"torchvision_version={torchvision.__version__}")
    except Exception as exc:
        lines.append(f"torchvision_version=ERROR:{exc!r}")
    lines.extend([
        f"cuda_available={torch.cuda.is_available()}",
        f"cuda_version={torch.version.cuda}",
        f"gpu_name={torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'none'}",
        f"gpu_count={torch.cuda.device_count()}",
        f"device={device}",
        f"hostname={platform.node()}",
        f"seed={SEED}",
        f"batch_size={BATCH_SIZE}",
        f"epochs={EPOCHS}",
        f"optimizer=SGD(lr={LEARNING_RATE},momentum={MOMENTUM},weight_decay={WEIGHT_DECAY})",
        "scheduler=CosineAnnealingLR(T_max=5)",
        "normalization=Normalize((0.1307,),(0.3081,))",
        "augmentation=none",
    ])
    (ROOT / "environment.txt").write_text("\n".join(lines) + "\n")


def run_epoch(model, loader, loss_fn, optimizer, device, training):
    model.train(training)
    loss_total = 0.0
    correct = 0
    total = 0
    context = torch.enable_grad() if training else torch.no_grad()
    with context:
        for images, labels in loader:
            images, labels = images.to(device), labels.to(device)
            if training:
                optimizer.zero_grad(set_to_none=True)
            logits = model(images)
            loss = loss_fn(logits, labels)
            if training:
                loss.backward()
                optimizer.step()
            loss_total += float(loss.item()) * labels.numel()
            correct += int((logits.argmax(1) == labels).sum())
            total += labels.numel()
    return loss_total / total, correct / total


def main():
    seed_everything()
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    write_environment(device)
    train_loader, validation_loader, test_loader = make_loaders(BATCH_SIZE)
    model = AlexNetMNIST().to(device)
    sample_images, sample_labels = next(iter(train_loader))
    assert tuple(sample_images.shape[1:]) == (1, 28, 28)
    assert tuple(model(sample_images.to(device)).shape[1:]) == (10,)
    loss_fn = nn.CrossEntropyLoss()
    optimizer = torch.optim.SGD(model.parameters(), lr=LEARNING_RATE, momentum=MOMENTUM, weight_decay=WEIGHT_DECAY)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=EPOCHS)
    rows = []
    log_lines = []
    for epoch in range(1, EPOCHS + 1):
        start = time.perf_counter()
        train_loss, train_accuracy = run_epoch(model, train_loader, loss_fn, optimizer, device, True)
        validation_loss, validation_accuracy = run_epoch(model, validation_loader, loss_fn, optimizer, device, False)
        learning_rate = optimizer.param_groups[0]["lr"]
        scheduler.step()
        elapsed = time.perf_counter() - start
        row = {
            "epoch": epoch,
            "train_loss": train_loss,
            "train_accuracy": train_accuracy,
            "validation_loss": validation_loss,
            "validation_accuracy": validation_accuracy,
            "learning_rate": learning_rate,
            "epoch_time_seconds": elapsed,
        }
        rows.append(row)
        log_lines.append(json.dumps(row))
        print(row, flush=True)
    with (ROOT / "alexnet_mnist_5epoch_pilot.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (ROOT / "alexnet_mnist_training.log").write_text("\n".join(log_lines) + "\n")
    checkpoint = {
        "model_state_dict": {key: value.detach().cpu() for key, value in model.state_dict().items()},
        "epoch": EPOCHS,
        "config": {"seed": SEED, "batch_size": BATCH_SIZE, "optimizer": "SGD", "lr": LEARNING_RATE, "momentum": MOMENTUM, "weight_decay": WEIGHT_DECAY},
    }
    torch.save(checkpoint, ROOT / "alexnet_mnist_5epoch_pilot.pt")
    first, last = rows[0], rows[-1]
    ready = last["train_loss"] < first["train_loss"] and last["validation_accuracy"] > first["validation_accuracy"] and device.type == "cuda"
    status = "READY_FOR_FINAL_TRAINING" if ready else "NEEDS_DIAGNOSTIC"
    report = [
        "# AlexNet-MNIST Pilot Report", "", f"Status: `{status}`", "",
        f"- Training loss: {first['train_loss']:.6f} -> {last['train_loss']:.6f}",
        f"- Validation accuracy: {first['validation_accuracy']:.4f} -> {last['validation_accuracy']:.4f}",
        f"- Best validation accuracy: {max(row['validation_accuracy'] for row in rows):.4f}",
        f"- Device: `{device}`", f"- GPU: `{torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'none'}`", "",
        "The pilot uses the requested fixed architecture, deterministic 55,000/5,000 split, normalization, SGD, and cosine annealing.",
        "No 150-epoch job was launched.",
    ]
    (ROOT / "PILOT_REPORT.md").write_text("\n".join(report) + "\n")
    print("===== ALEXNET-MNIST PILOT =====")
    print("Model: AlexNetMNIST")
    print("Dataset: MNIST")
    print("Train samples: 55000")
    print("Validation samples: 5000")
    print("Test samples: 10000")
    print(f"Device: {device}")
    print(f"GPU: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'none'}")
    print(f"Epochs: {EPOCHS}")
    print(f"Best validation accuracy: {max(row['validation_accuracy'] for row in rows):.6f}")
    print(f"Final validation accuracy: {last['validation_accuracy']:.6f}")
    print(f"Final training accuracy: {last['train_accuracy']:.6f}")
    print(f"Final training loss: {last['train_loss']:.6f}")
    print(f"Status: {status}")
    print(f"Output directory: {ROOT}")


if __name__ == "__main__":
    main()