#!/usr/bin/env python3
from __future__ import annotations
import csv, json, math
from pathlib import Path
import torch
import yaml
from common import make_model

ROOT = Path(__file__).resolve().parent; CONFIG = yaml.safe_load((ROOT / "CONFIG.yaml").read_text()); CHECKPOINTS = ROOT / "checkpoints"; LOGS = ROOT / "logs"; RESULTS = ROOT / "results"

def main():
    rows = []; failures = []
    for model_name in CONFIG["models"]:
        for dataset_name in CONFIG["datasets"]:
            checkpoint = CHECKPOINTS / f"{model_name}_{dataset_name}_best.pt"; log = LOGS / f"{model_name}_{dataset_name}.csv"; row = {"model": model_name, "dataset": dataset_name, "checkpoint": str(checkpoint), "status": "PASS"}
            try:
                if not checkpoint.exists(): raise RuntimeError("best checkpoint missing")
                payload = torch.load(checkpoint, map_location="cpu"); required = {"model_state_dict", "optimizer_state_dict", "scheduler_state_dict", "epoch", "best_validation_accuracy", "configuration", "seed"}; missing = required - set(payload)
                if missing: raise RuntimeError(f"missing checkpoint keys: {sorted(missing)}")
                if int(payload["epoch"]) != int(CONFIG["epochs"]): raise RuntimeError(f"best checkpoint epoch={payload['epoch']} expected={CONFIG['epochs']}")
                if not math.isfinite(float(payload["best_validation_accuracy"])): raise RuntimeError("non-finite validation accuracy")
                model = make_model(model_name, CONFIG["classes"][dataset_name]); model.load_state_dict(payload["model_state_dict"], strict=True)
                if not log.exists(): raise RuntimeError("training log missing")
                with log.open(newline="") as handle: log_rows = list(csv.DictReader(handle))
                if len(log_rows) != CONFIG["epochs"]: raise RuntimeError(f"log epochs={len(log_rows)} expected={CONFIG['epochs']}")
                for log_row in log_rows:
                    if not all(math.isfinite(float(log_row[key])) for key in ("train_loss", "train_accuracy", "val_loss", "val_accuracy", "learning_rate", "seconds")): raise RuntimeError("non-finite training metric")
                row.update({"epochs_completed": len(log_rows), "best_epoch": payload["epoch"], "best_validation_accuracy": payload["best_validation_accuracy"], "final_training_accuracy": log_rows[-1]["train_accuracy"], "gpu": log_rows[-1].get("gpu", ""), "slurm_job_id": log_rows[-1].get("slurm_job_id", "")})
            except Exception as exc:
                row["status"] = "FAIL"; row["reason"] = repr(exc); failures.append(row)
            rows.append(row)
    RESULTS.mkdir(exist_ok=True)
    with (RESULTS / "training_summary.csv").open("w", newline="") as handle:
        fields = sorted({key for item in rows for key in item}); writer = csv.DictWriter(handle, fieldnames=fields); writer.writeheader(); writer.writerows(rows)
    status = "PASS" if not failures and len(rows) == 4 else "INCOMPLETE"; (RESULTS / "checkpoint_validation.json").write_text(json.dumps({"status": status, "rows": rows}, indent=2) + "\n"); print(json.dumps({"status": status, "rows": rows}, indent=2)); raise SystemExit(0 if status == "PASS" else 1)

if __name__ == "__main__": main()
