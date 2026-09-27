#!/usr/bin/env python3
from __future__ import annotations
import csv, json, os, platform, shutil, time
import argparse
from pathlib import Path
import torch
from torch import nn
import yaml
from common import CifarDataset, make_model, seed_everything

ROOT = Path(__file__).resolve().parent; CONFIG = yaml.safe_load((ROOT / "CONFIG.yaml").read_text()); CHECKPOINTS = ROOT / "checkpoints"; LOGS = ROOT / "logs"; RESULTS = ROOT / "results"
for path in (CHECKPOINTS, LOGS, RESULTS): path.mkdir(exist_ok=True)
DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

def loader(dataset, indices, batch_size, shuffle): return torch.utils.data.DataLoader(torch.utils.data.Subset(dataset, indices), batch_size=batch_size, shuffle=shuffle, num_workers=0)

def validate(model, data_loader):
    model.eval(); loss_fn = nn.CrossEntropyLoss(); loss_sum = correct = total = 0
    with torch.no_grad():
        for images, labels in data_loader:
            labels = labels.to(DEVICE); logits = model(images.to(DEVICE)); loss_sum += float(loss_fn(logits, labels)) * labels.numel(); correct += int((logits.argmax(1) == labels).sum()); total += labels.numel()
    return loss_sum / max(total, 1), correct / max(total, 1)

def environment():
    memory = shutil.disk_usage(ROOT)
    return {"python": platform.python_version(), "torch": torch.__version__, "device": str(DEVICE), "cuda_available": torch.cuda.is_available(), "gpu_name": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None, "cpu_count": os.cpu_count(), "torch_threads": torch.get_num_threads(), "disk_available_bytes": memory.free, "ram_note": "see host free -h; CPU-only run" if not torch.cuda.is_available() else "CUDA run"}

def pilot():
    rows = []; batches = int(os.environ.get("V3_PILOT_BATCHES", "5")); seed_everything(CONFIG["seed"])
    for model_name in CONFIG["models"]:
        for dataset_name in CONFIG["datasets"]:
            dataset = CifarDataset(dataset_name, True, augment=True); model = make_model(model_name, CONFIG["classes"][dataset_name]).to(DEVICE); model.train(); optimizer = torch.optim.SGD(model.parameters(), lr=CONFIG["learning_rate"], momentum=CONFIG["momentum"], weight_decay=CONFIG["weight_decay"]); loss_fn = nn.CrossEntropyLoss(); data_loader = loader(dataset, range(CONFIG["validation_samples"], CONFIG["validation_samples"] + CONFIG["train_samples"]), CONFIG["batch_size"], True); started = time.time(); seen = 0
            for images, labels in data_loader:
                optimizer.zero_grad(set_to_none=True); logits = model(images.to(DEVICE)); loss = loss_fn(logits, labels.to(DEVICE)); loss.backward(); optimizer.step(); seen += 1
                if seen >= batches: break
            seconds = time.time() - started; epoch_estimate = seconds * max(len(data_loader), 1) / max(seen, 1); rows.append({"model": model_name, "dataset": dataset_name, "pilot_batches": seen, "pilot_seconds": seconds, "estimated_epoch_seconds": epoch_estimate, "estimated_50_epoch_hours": epoch_estimate * 50 / 3600}); print(rows[-1], flush=True)
    (RESULTS / "pilot_runtime.json").write_text(json.dumps(rows, indent=2) + "\n")

def train_pair(model_name, dataset_name):
    checkpoint = CHECKPOINTS / f"{model_name}_{dataset_name}_best.pt"; dataset = CifarDataset(dataset_name, True, augment=True); validation = CifarDataset(dataset_name, True, augment=False); train_indices = range(CONFIG["validation_samples"], CONFIG["validation_samples"] + CONFIG["train_samples"]); val_indices = range(CONFIG["validation_samples"]); train_loader = loader(dataset, train_indices, CONFIG["batch_size"], True); val_loader = loader(validation, val_indices, CONFIG["batch_size"], False); model = make_model(model_name, CONFIG["classes"][dataset_name]).to(DEVICE); optimizer = torch.optim.SGD(model.parameters(), lr=CONFIG["learning_rate"], momentum=CONFIG["momentum"], weight_decay=CONFIG["weight_decay"]); scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=CONFIG["epochs"]); loss_fn = nn.CrossEntropyLoss(); best_accuracy = -1.0; best_epoch = 0; rows = []; started_total = time.time()
    for epoch in range(1, CONFIG["epochs"] + 1):
        model.train(); loss_sum = correct = total = 0; started = time.time()
        for images, labels in train_loader:
            images, labels = images.to(DEVICE), labels.to(DEVICE); optimizer.zero_grad(set_to_none=True); logits = model(images); loss = loss_fn(logits, labels); loss.backward(); optimizer.step(); loss_sum += float(loss.detach()) * labels.numel(); correct += int((logits.argmax(1) == labels).sum()); total += labels.numel()
        scheduler.step(); val_loss, val_accuracy = validate(model, val_loader); row = {"epoch": epoch, "train_loss": loss_sum / max(total, 1), "train_accuracy": correct / max(total, 1), "val_loss": val_loss, "val_accuracy": val_accuracy, "learning_rate": optimizer.param_groups[0]["lr"], "seconds": time.time() - started, "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else "CPU", "slurm_job_id": os.environ.get("SLURM_JOB_ID", "local")}; rows.append(row); print(model_name, dataset_name, row, flush=True)
        if val_accuracy > best_accuracy:
            best_accuracy, best_epoch = val_accuracy, epoch; torch.save({"model_state_dict": model.state_dict(), "optimizer_state_dict": optimizer.state_dict(), "scheduler_state_dict": scheduler.state_dict(), "epoch": epoch, "best_validation_accuracy": best_accuracy, "configuration": CONFIG, "seed": CONFIG["seed"]}, checkpoint)
    final_checkpoint = CHECKPOINTS / f"{model_name}_{dataset_name}_final.pt"
    torch.save({"model_state_dict": model.state_dict(), "optimizer_state_dict": optimizer.state_dict(), "scheduler_state_dict": scheduler.state_dict(), "epoch": len(rows), "best_validation_accuracy": best_accuracy, "configuration": CONFIG, "seed": CONFIG["seed"]}, final_checkpoint)
    with (LOGS / f"{model_name}_{dataset_name}.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys()); writer.writeheader(); writer.writerows(rows)
    return {"model": model_name, "dataset": dataset_name, "epochs_completed": len(rows), "best_epoch": best_epoch, "best_validation_accuracy": best_accuracy, "final_training_accuracy": rows[-1]["train_accuracy"], "status": "PASS" if len(rows) >= CONFIG["epochs"] else "TRAINING_INCOMPLETE", "duration_seconds": time.time() - started_total, "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else "CPU", "slurm_job_id": os.environ.get("SLURM_JOB_ID", "local")}

def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--model", choices=CONFIG["models"]); parser.add_argument("--dataset", choices=CONFIG["datasets"]); args = parser.parse_args()
    seed_everything(CONFIG["seed"]); (RESULTS / "training_environment.json").write_text(json.dumps(environment(), indent=2) + "\n"); (RESULTS / "split_config.json").write_text(json.dumps({"seed": CONFIG["seed"], "validation_indices": "range(0, 5000)", "training_indices": "range(5000, 50000)", "training_count": 45000, "validation_count": 5000}, indent=2) + "\n")
    architecture = []
    for model_name in CONFIG["models"]:
        for dataset_name in CONFIG["datasets"]:
            model = make_model(model_name, CONFIG["classes"][dataset_name]); architecture.append(f"{model_name}/{dataset_name}: parameters={sum(p.numel() for p in model.parameters())}, trainable={sum(p.numel() for p in model.parameters() if p.requires_grad)}, conv_layers={sum(isinstance(m, nn.Conv2d) for m in model.modules())}, linear_layers={sum(isinstance(m, nn.Linear) for m in model.modules())}")
    (RESULTS / "model_architectures.txt").write_text("\n".join(architecture) + "\n")
    if os.environ.get("V3_PILOT") == "1": pilot(); return
    if os.environ.get("V3_SKIP_LONG_TRAINING") == "1":
        statuses = [{"model": model_name, "dataset": dataset_name, "epochs_completed": 0, "best_epoch": 0, "best_validation_accuracy": "", "final_training_accuracy": "", "status": "NOT RUN", "reason": "Pilot estimated approximately 15 CPU-hours for the four 50-epoch runs; declared one-hour execution budget prevents an incomplete final-accuracy claim."} for model_name in CONFIG["models"] for dataset_name in CONFIG["datasets"]]
        with (RESULTS / "training_summary.csv").open("w", newline="") as handle:
            fields = sorted({key for row in statuses for key in row}); writer = csv.DictWriter(handle, fieldnames=fields); writer.writeheader(); writer.writerows(statuses)
        print(json.dumps(statuses, indent=2)); return
    statuses = []
    pairs = [(args.model, args.dataset)] if args.model and args.dataset else [(model_name, dataset_name) for model_name in CONFIG["models"] for dataset_name in CONFIG["datasets"]]
    for model_name, dataset_name in pairs:
            try: statuses.append(train_pair(model_name, dataset_name))
            except Exception as exc: statuses.append({"model": model_name, "dataset": dataset_name, "epochs_completed": 0, "best_epoch": 0, "best_validation_accuracy": "", "final_training_accuracy": "", "status": "NOT RUN", "reason": repr(exc)})
    summary_path = RESULTS / (f"training_summary_{args.model}_{args.dataset}.csv" if args.model and args.dataset else "training_summary.csv")
    with summary_path.open("w", newline="") as handle:
        fields = sorted({key for row in statuses for key in row}); writer = csv.DictWriter(handle, fieldnames=fields); writer.writeheader(); writer.writerows(statuses)
    print(json.dumps(statuses, indent=2))

if __name__ == "__main__": main()
