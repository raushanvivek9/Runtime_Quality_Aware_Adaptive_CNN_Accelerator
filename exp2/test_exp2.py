"""Dependency-light smoke tests for the Experiment 2 control path."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))

from adaptive_flow import AdaptivePEController, LayerFeatures  # noqa: E402
from model_signature import SignatureRegistry, build_model_signature  # noqa: E402
from scalesim_adapter import ScaleSimAdapter  # noqa: E402

try:
    from full_network_pipeline import build_feature_table, summarize_selection  # noqa: E402
except ImportError:  # allow red test before implementation
    build_feature_table = None  # type: ignore
    summarize_selection = None  # type: ignore


class FakeConv:
    in_channels = 3
    out_channels = 16
    kernel_size = (3, 3)
    stride = (1, 1)


class FakeModel:
    def named_modules(self):
        return [("", self), ("conv1", FakeConv())]


class Exp2Tests(unittest.TestCase):
    def test_feed_forward_signal_changes_next_threshold(self) -> None:
        controller = AdaptivePEController(max_degradation=0.05, feed_forward_gain=0.20)
        layers = [
            LayerFeatures("conv1", 0.5, 0.2, 0.1, 0.3),
            LayerFeatures("conv2", 1.0, 0.4, 0.2, 0.4),
        ]

        def predictor(features: LayerFeatures, resource: int) -> float:
            if features.name == "conv1":
                return {16: 0.20, 32: 0.04, 64: 0.0}[resource]
            return {16: 0.051, 32: 0.02, 64: 0.0}[resource]

        decisions = controller.run(layers, predictor)
        self.assertEqual(decisions[0].selected_resource, 32)
        self.assertEqual(decisions[1].selected_resource, 16)
        self.assertGreater(decisions[0].signal.normalized_margin, 0.0)

    def test_unseen_model_is_registered_for_reconfiguration(self) -> None:
        registry = SignatureRegistry()
        first = registry.observe(FakeModel())
        second = registry.observe(FakeModel())
        self.assertFalse(first.known)
        self.assertTrue(second.known)
        self.assertEqual(first.action, "calibrate_and_reconfigure")
        self.assertEqual(second.action, "reuse_controller")
        self.assertEqual(first.signature.identifier, build_model_signature(FakeModel()).identifier)

    def test_scalesim_adapter_maps_selected_resource(self) -> None:
        adapter = ScaleSimAdapter(
            configs={16: Path("16.cfg"), 32: Path("32.cfg"), 64: Path("64.cfg")},
            topology_path=Path("network.csv"),
            output_root=Path("results/scalesim"),
        )
        run = adapter.prepare(32, "abc123")
        self.assertEqual(run.output_dir, Path("results/scalesim/abc123/32pe"))
        self.assertEqual(run.command(Path("scale.py"))[0], "python")

    def test_full_network_feature_table_and_summary(self) -> None:
        self.assertIsNotNone(build_feature_table)
        self.assertIsNotNone(summarize_selection)
        rows = [
            {
                "sample_id": 0,
                "layer": "conv1",
                "sparsity": 0.10,
                "mean": 0.20,
                "variance": 0.30,
                "layer_position": 0.5,
                "resource_level": 16,
                "degradation": 0.08,
            },
            {
                "sample_id": 0,
                "layer": "conv1",
                "sparsity": 0.10,
                "mean": 0.20,
                "variance": 0.30,
                "layer_position": 0.5,
                "resource_level": 32,
                "degradation": 0.04,
            },
            {
                "sample_id": 0,
                "layer": "conv1",
                "sparsity": 0.10,
                "mean": 0.20,
                "variance": 0.30,
                "layer_position": 0.5,
                "resource_level": 64,
                "degradation": 0.01,
            },
        ]

        table = build_feature_table(rows)
        summary = summarize_selection(table, max_degradation=0.05)
        self.assertEqual(len(table), 3)
        self.assertEqual(summary["selected_resource"], 32)
        self.assertIn("selected_count", summary)

    def test_full_network_feature_collection_uses_real_model_stats(self) -> None:
        from full_network_pipeline import collect_full_network_feature_rows
        import torch
        from torch import nn

        class TinyConvModel(nn.Module):
            def __init__(self):
                super().__init__()
                self.conv1 = nn.Conv2d(3, 4, 3, padding=1)
                self.conv2 = nn.Conv2d(4, 8, 3, padding=1)
                self.pool = nn.AdaptiveAvgPool2d((1, 1))
                self.fc = nn.Linear(8, 10)

            def forward(self, x):
                x = torch.relu(self.conv1(x))
                x = torch.relu(self.conv2(x))
                return self.fc(self.pool(x).flatten(1))

        model = TinyConvModel()
        loader = torch.utils.data.DataLoader(
            torch.utils.data.TensorDataset(
                torch.randn(4, 3, 8, 8),
                torch.randint(0, 10, (4,)),
            ),
            batch_size=2,
            shuffle=False,
        )

        rows = collect_full_network_feature_rows(model, loader, max_samples=4)
        self.assertTrue(rows)
        self.assertEqual(len(rows[0]), 8)
        self.assertIn("resource_level", rows[0])
        self.assertIn("degradation", rows[0])
        unique_samples = {row["sample_id"] for row in rows}
        self.assertEqual(len(unique_samples), 4)

    def test_full_network_collection_does_not_invent_degradation_labels(self) -> None:
        from full_network_pipeline import collect_full_network_feature_rows
        import torch
        from torch import nn

        model = nn.Sequential(nn.Conv2d(1, 1, 1))
        loader = torch.utils.data.DataLoader(
            torch.utils.data.TensorDataset(torch.ones(2, 1, 2, 2), torch.zeros(2)),
            batch_size=2,
        )
        rows = collect_full_network_feature_rows(model, loader, max_samples=2)
        self.assertTrue(rows)
        self.assertTrue(all(row["degradation"] is None for row in rows))


if __name__ == "__main__":
    unittest.main()
