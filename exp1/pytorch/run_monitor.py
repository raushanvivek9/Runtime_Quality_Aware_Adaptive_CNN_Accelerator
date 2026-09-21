"""Run the first experiment: pre-layer activation statistics for a small CNN."""

from __future__ import annotations

import argparse
from pathlib import Path

import torch

from model import SimpleCNN
from monitor import LayerActivationMonitor


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "results"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--batches", type=int, default=4, help="number of inference batches")
    parser.add_argument("--batch-size", type=int, default=8, help="images per batch")
    parser.add_argument("--seed", type=int, default=42, help="random seed for reproducibility")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.batches < 1 or args.batch_size < 1:
        raise ValueError("--batches and --batch-size must both be positive")

    torch.manual_seed(args.seed)
    model = SimpleCNN().eval()

    # A forward-pre-hook sees the tensor before Conv/Linear consumes it.
    with LayerActivationMonitor(model, position="pre") as monitor:
        with torch.inference_mode():
            for _ in range(args.batches):
                images = torch.randn(args.batch_size, 3, 32, 32)
                model(images)

    csv_path, json_path = monitor.save(args.output_dir)
    print("Pre-layer activation monitoring complete")
    for row in monitor.summary():
        print(
            f"{row['layer']}: sparsity={row['sparsity']:.4f}, "
            f"mean={row['mean']:.6f}, variance={row['variance']:.6f}"
        )
    print(f"CSV:  {csv_path}")
    print(f"JSON: {json_path}")


if __name__ == "__main__":
    main()
