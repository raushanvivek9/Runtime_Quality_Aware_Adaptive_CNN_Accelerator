#!/usr/bin/env python3
"""Run the repository's SCALE-Sim API without generating optional trace files."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--layout", type=Path, required=True)
    parser.add_argument("--topology", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.root / "SCALE-Sim-v3-energy"))
    from scalesim.scale_sim import scalesim

    simulator = scalesim(
        save_disk_space=True,
        verbose=False,
        config=str(args.config),
        topology=str(args.topology),
        layout=str(args.layout),
        input_type_gemm=False,
    )
    simulator.run_scale(top_path=str(args.output))


if __name__ == "__main__":
    main()
