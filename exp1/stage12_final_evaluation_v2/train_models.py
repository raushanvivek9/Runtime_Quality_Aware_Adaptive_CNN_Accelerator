#!/usr/bin/env python3
from __future__ import annotations
import csv, json, platform, time
from pathlib import Path
import torch
from torch import nn
try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"TRAINING_NOT_COMPLETED: PyYAML unavailable: {exc}")
from common import CifarDataset, make_model, seed_everything

ROOT = Path(__file__).resolve().parent
CONFIG = yaml.safe_load((ROOT / "CONFIG.yaml").read_text())
CHECKPOINTS = ROOT / "checkpoints"; RESULTS = ROOT / "results"; LOGS = ROOT / "logs"
CHECKPOINTS.mkdir(exist_ok=True); RESULTS.mkdir(exist_ok=True); LOGS.mkdir(exist_ok=True)
DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

def loader(dataset, indices, batch_size, shuffle):
    subset = torch.utils.data.Subset(dataset, indices)
    return torch.utils.data.DataLoader(subset, batch_size=batch_size, shuffle=shuffle, num_workers=0)

def validate(model, data_loader, device):
    model.eval(); loss_fn = nn.CrossEntropyLoss(); total_loss = correct = total = 0
    with torch.no_grad():
        for images, labels in data_loader:
            logits = model(images.to(device)); labels = labels.to(device)
            total_loss += float(loss_fn(logits, labels)) * labels.numel(); correct += int((logits.argmax(1) == labels).sum()); total += labels.numel()
    return total_loss / max(total, 1), correct / max(total, 1)

def main():
    seed_everything(CONFIG["seed"])
    environment = {"python": platform.python_version(), "torch": torch.__version__, "device": str(DEVICE), "cpu_threads": torch.get_num_threads(), "cuda": torch.cuda.is_available()}
    (RESULTS / "training_environment.json").write_text(json.dumps(environment, indent=2) + "\n")
    architecture_lines = []
    status_rows = []
    for model_name in CONFIG["models"]:
        for dataset_name in CONFIG["datasets"]:
            classes = CONFIG["classes"][dataset_name]
            checkpoint_path = CHECKPOINTS / f"{model_name}_{dataset_name}.pt"
            model = make_model(model_name, classes)
            architecture_lines.append(f"{model_name}/{dataset_name}: parameters={sum(p.numel() for p in model.parameters())}, trainable={sum(p.numel() for p in model.parameters() if p.requires_grad)}, convolution_layers={sum(isinstance(m, nn.Conv2d) for m in model.modules())}, linear_layers={sum(isinstance(m, nn.Linear) for m in model.modules())}")
            if checkpoint_path.exists():
                status_rows.append({"model": model_name, "dataset": dataset_name, "status": "CHECKPOINT_EXISTS", "checkpoint": str(checkpoint_path)})
                continue
            try:
                train_dataset = CifarDataset(dataset_name, train=True)
                val_count = CONFIG["validation_samples"]; train_start = val_count; train_end = min(len(train_dataset), train_start + CONFIG["train_samples"])
                train_loader = loader(train_dataset, range(train_start, train_end), CONFIG["batch_size"], True)
                val_loader = loader(train_dataset, range(val_count), CONFIG["batch_size"], False)
                optimizer = torch.optim.SGD(model.parameters(), lr=CONFIG["learning_rate"], momentum=CONFIG["momentum"], weight_decay=CONFIG["weight_decay"])
                scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=CONFIG["epochs"])
                loss_fn = nn.CrossEntropyLoss(); model.to(DEVICE)
                rows = []
                for epoch in range(1, CONFIG["epochs"] + 1):
                    model.train(); running_loss = correct = total = 0; started = time.time()
                    for images, labels in train_loader:
                        images, labels = images.to(DEVICE), labels.to(DEVICE); optimizer.zero_grad(set_to_none=True)
                        logits = model(images); loss = loss_fn(logits, labels); loss.backward(); optimizer.step()
                        running_loss += float(loss.detach()) * labels.numel(); correct += int((logits.argmax(1) == labels).sum()); total += labels.numel()
                    scheduler.step(); val_loss, val_accuracy = validate(model, val_loader, DEVICE)
                    row = {"model": model_name, "dataset": dataset_name, "epoch": epoch, "train_loss": running_loss / max(total, 1), "train_accuracy": correct / max(total, 1), "validation_loss": val_loss, "validation_accuracy": val_accuracy, "seconds": time.time() - started}
                    rows.append(row); print(row, flush=True)
                best = max(rows, key=lambda row: row["validation_accuracy"])
                payload = {"model_state_dict": model.state_dict(), "optimizer_state_dict": optimizer.state_dict(), "epoch": best["epoch"], "validation_accuracy": best["validation_accuracy"], "configuration": CONFIG, "seed": CONFIG["seed"]}
                torch.save(payload, checkpoint_path)
                with (LOGS / f"{model_name}_{dataset_name}_training.csv").open("w", newline="") as handle:
                    writer = csv.DictWriter(handle, fieldnames=rows[0].keys()); writer.writeheader(); writer.writerows(rows)
                status_rows.append({"model": model_name, "dataset": dataset_name, "status": "PASS", "checkpoint": str(checkpoint_path), "validation_accuracy": best["validation_accuracy"]})
            except Exception as exc:
                status_rows.append({"model": model_name, "dataset": dataset_name, "status": "TRAINING_NOT_COMPLETED", "reason": repr(exc)})
                print(f"TRAINING_NOT_COMPLETED {model_name}/{dataset_name}: {exc}", flush=True)
    (RESULTS / "model_architectures.txt").write_text("\n".join(architecture_lines) + "\n")
    with (RESULTS / "training_status.csv").open("w", newline="") as handle:
        fields = sorted({key for row in status_rows for key in row}); writer = csv.DictWriter(handle, fieldnames=fields); writer.writeheader(); writer.writerows(status_rows)
    print(json.dumps(status_rows, indent=2))

if __name__ == "__main__": main()
