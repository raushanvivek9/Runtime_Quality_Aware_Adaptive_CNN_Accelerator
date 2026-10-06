# Experiment 3: End-to-End SCALE-Sim Validation

Experiment 3 validates the frozen Stage 13.1 layer-wise PE allocation using actual executions of the repository's `SCALE-Sim-v3-energy` simulator. It is isolated under `exp_3_scalesim_validation/` and does not modify Stage 13, Stage 13.1, checkpoints, or prior results.

## Scientific scope

Stage 13.1 remains the analytical controller. Experiment 3 executes each real convolution layer shape with SCALE-Sim using:

- dense baseline: an 8x8 array, 64 PEs;
- adaptive run: the exact `selected_pe` value read from `exp1/stage13_1_baseline_preserving_pe/results/layerwise_results.csv`;
- candidate array geometries: 4x4 for 16 PE, 4x8 for 32 PE, and 8x8 for 64 PE.

The model definitions, preprocessing, checkpoints, and layer names are taken from Stage 12 V3. Real layer dimensions are observed from the frozen model with the first real test image; no synthetic CNN input is used.

The installed SCALE-Sim configuration reports `SparsitySupport=false`. Therefore this experiment is **SCALE-Sim PE allocation/mapping validation**, not sparse execution validation. SCALE-Sim cycles are genuine simulator results for dense mappings. Stage 13.1 `MAC_useful`, `MAC_skipped`, and analytical cycles are retained as separate comparison values. No energy result is reported because the current invocation does not provide a defensible energy model.

## Reproduce

```bash
cd /home/cs25m115/Neural_Acc
source /home/cs25m115/anaconda3/etc/profile.d/conda.sh
conda activate neural_acc
python exp_3_scalesim_validation/run_exp3.py
```

Run one workload during development:

```bash
python exp_3_scalesim_validation/run_exp3.py --workload resnet18/cifar10
```

The runner first performs a mandatory smoke test. It then executes every convolution layer in fresh dense64 and adaptive subprocesses. Each layer has a 300-second timeout; timeout and failure rows are preserved, and incomplete ResNet18/CIFAR10 execution prevents the remaining workloads from starting.

## SCALE-Sim invocation

Each generated layer run invokes an Experiment 3 helper which calls the repository's SCALE-Sim Python API:

```text
python exp_3_scalesim_validation/scripts/run_scalesim_once.py \
  --config <generated config> --layout <generated layout> \
  --topology <generated convolution topology> \
  --output <exp_3_scalesim_validation/runs/...>
```

The helper uses `scalesim(..., save_disk_space=True)` from the installed repository version. This is the same simulator execution path with optional trace generation disabled; native cycle and access reports remain enabled.

SCALE-Sim writes its native `COMPUTE_REPORT.csv`, `BANDWIDTH_REPORT.csv`, and `DETAILED_ACCESS_REPORT.csv` below the run directory. Cycles are parsed from `Total Cycles (incl. prefetch)` and memory fields are retained only when present in the native report.

Layers are executed sequentially as independent simulator runs, so the per-image network cycle total is the sum of successful per-layer cycles. Incomplete workloads do not receive aggregate cycle or percentage results.

## Outputs

- `results/single_layer_validation.csv`
- `results/scalesim_layerwise_results.csv`
- `results/scalesim_dense_baseline.csv`
- `results/scalesim_adaptive_layerwise.csv`
- `results/exp3_comparison.csv`
- `results/analytical_vs_scalesim.csv`
- `results/exp3_report.txt`
- `results/run_metadata.json`
- `results/pe_allocation_exp3.png`
- `results/scalesim_cycles_comparison.png`
- `results/analytical_vs_scalesim.png`

Generated topologies and configs are under `workloads/` and `configs/`; all simulator reports are under `runs/`.

## Validation rules

The runner checks that every Stage 13.1 layer exists in the frozen model, layer ordering and names match, selected PEs are in `{16, 32, 64}`, dense runs use 64 PE, adaptive runs use the authoritative selected PE, every successful simulator process has a native compute report and cycle value, and timeouts remain explicit.

Inherited Stage 13.1 accuracy results remain inherited evidence and are not remeasured or relabeled as Experiment 3 results. Experiment 3 produces simulator cycle and mapping evidence only.

## Limitations

SCALE-Sim is a simulator, not physical hardware. With the current repository configuration it does not execute Stage 13.1 exact-zero activation skipping, and the experiment makes no sparse speedup, physical latency, or energy claim. Energy is unavailable from the current simulator configuration.
