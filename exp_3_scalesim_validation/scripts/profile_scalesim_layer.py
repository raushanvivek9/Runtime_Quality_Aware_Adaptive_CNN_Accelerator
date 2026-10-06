#!/usr/bin/env python3
"""Diagnostic-only timing wrapper for one Experiment 3 SCALE-Sim layer."""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--layout", type=Path, required=True)
    parser.add_argument("--topology", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(args.root / "SCALE-Sim-v3-energy"))
    from scalesim.scale_sim import scalesim

    timing: dict[str, float] = {}
    started = time.perf_counter()
    simulator = scalesim(
        save_disk_space=True,
        verbose=False,
        config=str(args.config),
        topology=str(args.topology),
        layout=str(args.layout),
        input_type_gemm=False,
    )
    timing["api_initialization_and_input_parsing_seconds"] = time.perf_counter() - started
    timing["simulation_run_seconds_start"] = time.perf_counter()
    simulator.run_scale(top_path=str(args.output))
    timing["simulation_run_seconds"] = time.perf_counter() - timing["simulation_run_seconds_start"]
    timing["total_process_api_seconds"] = time.perf_counter() - started
    timing["report_generation_included_in_simulation_run_seconds"] = timing["simulation_run_seconds"]
    (args.output / "profile_timings.json").write_text(json.dumps(timing, indent=2), encoding="utf-8")
    print(json.dumps(timing, indent=2))


if __name__ == "__main__":
    main()
