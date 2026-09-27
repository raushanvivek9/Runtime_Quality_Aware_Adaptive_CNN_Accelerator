"""Small adapter boundary between Exp2 decisions and SCALE-Sim runs."""

from __future__ import annotations

import configparser
import math
from dataclasses import dataclass
from pathlib import Path

RESOURCE_LEVELS = (16, 32, 64)


def _array_dims_for_resource(resource_level: int) -> tuple[int, int]:
    """Map a PE count to a square-ish array geometry with the same total count."""
    if resource_level <= 0:
        raise ValueError("resource_level must be positive")
    root = int(math.isqrt(resource_level))
    for height in range(root, 0, -1):
        if resource_level % height == 0:
            width = resource_level // height
            return height, width
    return resource_level, 1


@dataclass(frozen=True)
class ScaleSimRun:
    resource_level: int
    config_path: Path
    topology_path: Path
    output_dir: Path

    def command(self, scalesim_script: Path | None = None) -> list[str]:
        """Build, but do not execute, the reproducible SCALE-Sim command."""
        runner = scalesim_script or Path("SCALE-Sim-v3-energy/scalesim/scale.py")
        return [
            "python",
            str(runner),
            "-c",
            str(self.config_path),
            "-t",
            str(self.topology_path),
            "-p",
            str(self.output_dir),
            "-i",
            "conv",
        ]


class ScaleSimAdapter:
    """Translate a controller PE decision into a simulator run description."""

    def __init__(self, configs: dict[int, Path] | None, topology_path: Path, output_root: Path):
        if configs is None:
            configs = {}
        if set(configs) != set(RESOURCE_LEVELS):
            raise ValueError("configs must provide exactly 16, 32, and 64 PE entries")
        self.configs = configs
        self.topology_path = topology_path
        self.output_root = output_root

    @classmethod
    def write_generated_config(
        cls,
        resource_level: int,
        template_path: Path,
        output_path: Path,
        run_name: str | None = None,
    ) -> Path:
        if resource_level not in RESOURCE_LEVELS:
            raise ValueError(f"unsupported resource level: {resource_level}")
        parser = configparser.ConfigParser()
        parser.read(template_path, encoding="utf-8")
        height, width = _array_dims_for_resource(resource_level)
        parser["general"]["run_name"] = run_name or f"exp2_{resource_level}pe"
        parser["architecture_presets"]["ArrayHeight"] = str(height)
        parser["architecture_presets"]["ArrayWidth"] = str(width)
        parser["architecture_presets"]["Bandwidth"] = str(max(10, resource_level))
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with output_path.open("w", encoding="utf-8") as stream:
            parser.write(stream)
        return output_path

    def prepare(self, resource_level: int, model_signature: str) -> ScaleSimRun:
        if resource_level not in RESOURCE_LEVELS:
            raise ValueError(f"unsupported resource level: {resource_level}")
        output_dir = self.output_root / model_signature / f"{resource_level}pe"
        config_path = self.configs[resource_level]
        return ScaleSimRun(
            resource_level=resource_level,
            config_path=config_path,
            topology_path=self.topology_path,
            output_dir=output_dir,
        )
