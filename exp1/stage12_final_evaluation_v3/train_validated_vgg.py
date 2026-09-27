#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import platform
import socket
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

import torch
import torchvision
from torch import nn

from common import CifarDataset, CifarVgg16Canonical, seed_everything

ROOT = Path(__file__).resolve().parent
CHECKPOINTS = ROOT / "checkpoints"
LOGS = ROOT / "logs"
DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
EPOCHS = 150
BATCH_SIZE = 128
SEED = 42
LEARNING_RATE = 0.001
WEIGHT_DECAY = 0.0


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def command_output(command: list[str]) -> str:
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unavailable"


def runtime_info(dataset_name: str) -> dict:
    return {
        "hostname": socket.gethostname(),
        "gpu_model": torch.cuda.get_device_name(0) if torch.cuda.is_available() else "CPU",
        "cuda_version": torch.version.cuda or "unavailable",
        "pytorch_version": torch.__version__,
        "torchvision_version": torchvision.__version__,
        "cuda_visible_devices": os.environ.get("CUDA_VISIBLE_DEVICES", ""),
        "slurm_job_id": os.environ.get("SLURM_JOB_ID", "local"),
        "slurm_partition": os.environ.get("SLURM_JOB_PARTITION", ""),
        "dataset": dataset_name,
        "start_time": utc_now(),
        "nvidia_smi": command_output(["nvidia-smi"]),
    }


def configuration(dataset_name: str) -> dict:
    return {
        "model": "CifarVgg16Canonical",
        "architecture_variant": "batch_norm" if dataset_name == "cifar100" else "canonical",
        "dataset": dataset_name,
        "classes": 10 if dataset_name == "cifar10" else 100,
        "optimizer": "Adam",
        "learning_rate": LEARNING_RATE,
        "weight_decay": WEIGHT_DECAY,
        "batch_size": BATCH_SIZE,
        "epochs": EPOCHS,
        "seed": SEED,
        "train_samples": 45000,
        "validation_samples": 5000,
        "normalization_mean": [0.4914, 0.4822, 0.4465],
        "normalization_std": [0.2470, 0.2435, 0.2616],
        "augmentation": {"random_crop_padding": 4, "random_horizontal_flip": True},
        "scheduler": "CosineAnnealingLR(T_max=150)",
    }


def save_checkpoint(path: Path, payload: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    torch.save(payload, temporary)
    temporary.replace(path)


def validate(model: nn.Module, loader: torch.utils.data.DataLoader) -> tuple[float, float]:
    model.eval()
    loss_fn = nn.CrossEntropyLoss()
    loss_total = 0.0
    correct = 0
    total = 0
    with torch.no_grad():
        for images, labels in loader:
            images, labels = images.to(DEVICE), labels.to(DEVICE)
            logits = model(images)
            loss_total += float(loss_fn(logits, labels)) * labels.numel()
            correct += int((logits.argmax(1) == labels).sum())
            total += labels.numel()
    return loss_total / max(total, 1), correct / max(total, 1)


def train(dataset_name: str) -> int:
    CHECKPOINTS.mkdir(exist_ok=True)
    LOGS.mkdir(exist_ok=True)
    best_path = CHECKPOINTS / f"vgg16_{dataset_name}_best.pt"
    final_path = CHECKPOINTS / f"vgg16_{dataset_name}_final.pt"
    log_path = LOGS / f"vgg16_{dataset_name}_training.csv"
    summary_path = LOGS / f"vgg16_{dataset_name}_training_summary.json"
    failed_path = LOGS / f"vgg16_{dataset_name}_failure.json"
    config = configuration(dataset_name)
    runtime = runtime_info(dataset_name)
    seed_everything(SEED)

    train_dataset = CifarDataset(dataset_name, train=True, augment=True)
    validation_dataset = CifarDataset(dataset_name, train=True, augment=False)
    train_loader = torch.utils.data.DataLoader(torch.utils.data.Subset(train_dataset, range(5000, 50000)), batch_size=BATCH_SIZE, shuffle=True, num_workers=0)
    validation_loader = torch.utils.data.DataLoader(torch.utils.data.Subset(validation_dataset, range(5000)), batch_size=BATCH_SIZE, shuffle=False, num_workers=0)
    model = CifarVgg16Canonical(config["classes"], batch_norm=dataset_name == "cifar100").to(DEVICE)
    optimizer = torch.optim.Adam(model.parameters(), lr=LEARNING_RATE, weight_decay=WEIGHT_DECAY)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=EPOCHS)
    loss_fn = nn.CrossEntropyLoss()
    rows: list[dict] = []
    best_accuracy = -1.0
    best_epoch = 0
    start_epoch = 1
    resumed_from = None

    if final_path.exists():
        payload = torch.load(final_path, map_location=DEVICE)
        if payload.get("configuration") == config and int(payload.get("epoch", 0)) < EPOCHS:
            model.load_state_dict(payload["model_state_dict"], strict=True)
            optimizer.load_state_dict(payload["optimizer_state_dict"])
            scheduler.load_state_dict(payload["scheduler_state_dict"])
            start_epoch = int(payload["epoch"]) + 1
            best_accuracy = float(payload.get("best_validation_accuracy", -1.0))
            best_epoch = int(payload.get("best_epoch", payload["epoch"]))
            resumed_from = int(payload["epoch"])
            if log_path.exists():
                with log_path.open(newline="") as handle:
                    rows = list(csv.DictReader(handle))

    fields = ["epoch", "train_loss", "train_accuracy", "validation_loss", "validation_accuracy", "learning_rate", "epoch_time", "best_validation_accuracy"]
    if not log_path.exists() or not rows:
        with log_path.open("w", newline="") as handle:
            csv.DictWriter(handle, fieldnames=fields).writeheader()

    runtime["resumed_from_epoch"] = resumed_from
    runtime["actual_start_epoch"] = start_epoch
    started_total = time.time()
    status = "PASS"
    failure = None
    try:
        for epoch in range(start_epoch, EPOCHS + 1):
            epoch_started = time.time()
            model.train()
            train_loss = 0.0
            train_correct = 0
            train_total = 0
            for images, labels in train_loader:
                images, labels = images.to(DEVICE), labels.to(DEVICE)
                optimizer.zero_grad()
                logits = model(images)
                loss = loss_fn(logits, labels)
                if not torch.isfinite(loss):
                    raise FloatingPointError(f"non-finite training loss at epoch {epoch}")
                loss.backward()
                optimizer.step()
                train_loss += float(loss.detach()) * labels.numel()
                train_correct += int((logits.argmax(1) == labels).sum())
                train_total += labels.numel()
            validation_loss, validation_accuracy = validate(model, validation_loader)
            if not math.isfinite(validation_loss) or not math.isfinite(validation_accuracy):
                raise FloatingPointError(f"non-finite validation metric at epoch {epoch}")
            scheduler.step()
            if validation_accuracy > best_accuracy:
                best_accuracy = validation_accuracy
                best_epoch = epoch
                save_checkpoint(best_path, {
                    "model_state_dict": model.state_dict(),
                    "optimizer_state_dict": optimizer.state_dict(),
                    "scheduler_state_dict": scheduler.state_dict(),
                    "epoch": epoch,
                    "best_epoch": best_epoch,
                    "best_validation_accuracy": best_accuracy,
                    "validation_loss": validation_loss,
                    "configuration": config,
                    "seed": SEED,
                })
            row = {
                "epoch": epoch,
                "train_loss": train_loss / train_total,
                "train_accuracy": train_correct / train_total,
                "validation_loss": validation_loss,
                "validation_accuracy": validation_accuracy,
                "learning_rate": optimizer.param_groups[0]["lr"],
                "epoch_time": time.time() - epoch_started,
                "best_validation_accuracy": best_accuracy,
            }
            rows.append(row)
            with log_path.open("a", newline="") as handle:
                csv.DictWriter(handle, fieldnames=fields).writerow(row)
            save_checkpoint(final_path, {
                "model_state_dict": model.state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
                "scheduler_state_dict": scheduler.state_dict(),
                "epoch": epoch,
                "best_epoch": best_epoch,
                "best_validation_accuracy": best_accuracy,
                "validation_loss": validation_loss,
                "configuration": config,
                "seed": SEED,
            })
            print({"dataset": dataset_name, **row}, flush=True)
    except Exception as exc:
        status = "FAILED"
        failure = {"error": repr(exc), "epoch": rows[-1]["epoch"] if rows else 0, "time": utc_now()}
        failed_path.write_text(json.dumps(failure, indent=2) + "\n")
        print(json.dumps(failure), flush=True)

    runtime["end_time"] = utc_now()
    runtime["total_duration_seconds"] = time.time() - started_total
    runtime["status"] = status
    summary = {
        "status": status,
        "dataset": dataset_name,
        "best_epoch": best_epoch,
        "best_validation_accuracy": best_accuracy,
        "final_epoch": int(rows[-1]["epoch"]) if rows else 0,
        "final_training_accuracy": float(rows[-1]["train_accuracy"]) if rows else None,
        "final_validation_accuracy": float(rows[-1]["validation_accuracy"]) if rows else None,
        "final_validation_loss": float(rows[-1]["validation_loss"]) if rows else None,
        "total_duration_seconds": runtime["total_duration_seconds"],
        "configuration": config,
        "seed": SEED,
        "runtime": runtime,
        "failure": failure,
    }
    summary_path.write_text(json.dumps(summary, indent=2) + "\n")
    return 0 if status == "PASS" and rows and int(rows[-1]["epoch"]) == EPOCHS else 1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", choices=("cifar10", "cifar100"), required=True)
    args = parser.parse_args()
    raise SystemExit(train(args.dataset))


if __name__ == "__main__":
    main()