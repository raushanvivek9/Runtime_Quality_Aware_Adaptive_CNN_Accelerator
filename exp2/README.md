# Experiment 2: Learned Adaptive PE Selection with SCALE-Sim

## 1. Idea

Experiment 2 connects the previously separate components into one end-to-end flow:

```text
Full CNN inference
    -> activation monitoring
    -> feature extraction
    -> Linear Regression / MLP / Random Forest
    -> PE selection
    -> SCALE-Sim execution
    -> cycles, memory traffic, and energy results
```

The objective is to determine whether a learned controller can select fewer processing elements (PEs) while keeping prediction degradation below an allowed threshold.

This is a new experiment. It must not overwrite or silently replace the frozen Stage 13 full-network results.

## 2. Research Question

Can activation statistics from a full ResNet18 or VGG16 inference be used to select an appropriate PE configuration for SCALE-Sim while preserving accuracy and reducing accelerator cost?

The candidate PE configurations are:

```text
PE options = {16, 32, 64}
```

The evaluated workloads are:

- ResNet18 on CIFAR10
- ResNet18 on CIFAR100
- VGG16 on CIFAR10
- VGG16 on CIFAR100

## 3. Main Difference from Experiment 1

Experiment 1 trained quality estimators using a small `SimpleCNN` and a software resource-reduction proxy. Experiment 2 must use full-network CNN measurements and connect the selected resource to SCALE-Sim.

| Component | Experiment 1 | Experiment 2 |
|---|---|---|
| CNN | Small SimpleCNN | Full ResNet18 and VGG16 |
| Features | Synthetic/software-proxy statistics | Full-network activation statistics |
| Resource labels | Software proxy | SCALE-Sim results |
| Controller | Offline RF/MLP/linear models | Learned controller evaluated with SCALE-Sim |
| PE result | Resource abstraction | Configured simulator resource |
| Hardware evidence | Not cycle accurate | SCALE-Sim cycle/memory/energy estimates |

SCALE-Sim remains a simulator. It is not a physical FPGA or ASIC measurement.

## 4. End-to-End Flow

### Stage 1 - Freeze the CNN checkpoint

Load the verified best-validation checkpoint for one of the four workloads. Do not retrain the model during controller evaluation.

Record:

- model name
- dataset name
- checkpoint path and hash
- validation accuracy
- dense test accuracy
- random seed

The dense accuracy is the reference:

$$
A_{dense} = \frac{N_{correct,dense}}{N_{test}}.
$$

### Stage 2 - Run dense inference and monitor activations

Run the complete test set through the CNN. For every monitored convolution layer, collect features such as:

```text
sparsity
mean activation
activation variance
layer position
input/output tensor dimensions
number of dense MACs
```

For a monitored activation tensor:

$$
S_l = \frac{Z_l}{T_l},
$$

where $Z_l$ is the number of exact-zero values in layer $l$ and $T_l$ is the total number of activation values.

The activation variance is calculated as:

$$
Var_l = E[x_l^2] - E[x_l]^2.
$$

These features describe the current workload before selecting a PE configuration.

### Stage 3 - Build a full-network controller dataset

For each sample, layer, and candidate PE count, create one dataset record. The input features are:

$$
X = [S_l, \mu_l, Var_l, position_l, PE].
$$

The target must come from the same full-network workload and should not come from the old `SimpleCNN` proxy.

Possible targets are:

1. Accuracy or loss degradation
2. SCALE-Sim cycle count
3. Energy estimate
4. A combined cost subject to an accuracy constraint

For accuracy preservation, define degradation as:

$$
D_{PE} = Loss_{PE} - Loss_{64}.
$$

If classification results are available, also record:

$$
D_{acc,PE} = A_{64} - A_{PE}.
$$

### Stage 4 - Generate SCALE-Sim measurements

For each workload and PE option, create the corresponding SCALE-Sim configuration and run the CNN topology.

SCALE-Sim should produce or expose:

- total cycles
- compute cycles
- SRAM reads and writes
- DRAM reads and writes
- bandwidth information
- energy estimate when the Accelergy path is enabled

For a layer with dense MAC count $MAC_l$ and PE count $P$:

$$
C_{compute,l}(P) \approx \left\lceil \frac{MAC_l}{P} \right\rceil.
$$

The actual SCALE-Sim cycle result must be treated as authoritative for simulator-based reporting because memory stalls and dataflow can make it differ from the simple analytical estimate.

### Stage 5 - Train and compare the learned controllers

Train the three candidate regressors using group-safe splits by sample ID:

- Linear Regression
- Small MLP
- Random Forest Regressor

The split must prevent records from the same input sample appearing in both training and test sets.

For a degradation estimator, report:

$$
MAE = \frac{1}{n}\sum_{i=1}^{n}|y_i-\hat{y}_i|
$$

$$
RMSE = \sqrt{\frac{1}{n}\sum_{i=1}^{n}(y_i-\hat{y}_i)^2}
$$

$$
R^2 = 1 - \frac{\sum_i(y_i-\hat{y}_i)^2}
{\sum_i(y_i-\bar{y})^2}.
$$

The best model must be selected using validation data only. Test data must be used once for final reporting.

### Stage 6 - Select the PE configuration

For a maximum acceptable degradation $D_{max}$, select the smallest predicted-safe PE count:

$$
PE^* =
\min_{P \in \{16,32,64\}}
\left\{
P : \hat{D}_P \leq D_{max}
\right\}.
$$

If no candidate satisfies the constraint, select 64 PEs:

$$
PE^* = 64 \quad \text{if no candidate is safe}.
$$

For a cycle-constrained policy, use:

$$
PE^* =
\min_{P \in \{16,32,64\}}
\left\{
P : C_{SCALE\text{-}Sim}(P) \leq (1+\epsilon)C_{64}
\right\}.
$$

The policy must record both the predicted decision and the measured SCALE-Sim result.

### Stage 7 - Run the selected configuration end to end

For every test sample or defined workload window:

1. collect activation statistics;
2. predict degradation or cost for 16, 32, and 64 PEs;
3. select $PE^*$;
4. run or look up the matching SCALE-Sim configuration;
5. record cycles, memory traffic, energy, and accuracy impact.

This is the stage that completes the missing controller-to-SCALE-Sim connection.

### Stage 8 - Validate the adaptive system

Compare the learned adaptive policy against a fixed 64-PE baseline.

PE reduction:

$$
R_{PE} = \left(1-\frac{PE_{adaptive}}{64}\right)\times100.
$$

Cycle reduction:

$$
R_{cycles} = \left(1-\frac{C_{adaptive}}{C_{64}}\right)\times100.
$$

Energy reduction:

$$
R_{energy} = \left(1-\frac{E_{adaptive}}{E_{64}}\right)\times100.
$$

Accuracy change:

$$
\Delta A = A_{adaptive} - A_{64}.
$$

A valid adaptive result must report the selected PE, simulator result, and accuracy/degradation result together. A model prediction alone is not sufficient evidence.

## 5. Required Artifacts

The experiment should produce:

```text
exp2/
  README.md
  configs/
    scalesim_16pe.cfg
    scalesim_32pe.cfg
    scalesim_64pe.cfg
  data/
    full_network_features.csv
    scalesim_labels.csv
    controller_dataset.csv
  models/
    linear_regression.pkl
    mlp.pt
    random_forest.pkl
  results/
    model_metrics.json
    adaptive_decisions.csv
    fixed_vs_adaptive.csv
    scalesim_summary.csv
  reports/
    EXP2_METHODOLOGY.md
    EXP2_RESULTS.md
    EXP2_LIMITATIONS.md
```

The files listed above are the planned outputs. They should only be added after the corresponding experiment has actually run.

## 6. Required Comparisons

At minimum, compare:

| Policy | PE selection | SCALE-Sim | Accuracy check |
|---|---|---|---|
| Fixed baseline | 64 for every workload | Yes | Yes |
| Deterministic analytical policy | 16/32/64 candidate rule | Yes | Yes |
| Linear Regression | learned prediction | Yes | Yes |
| MLP | learned prediction | Yes | Yes |
| Random Forest | learned prediction | Yes | Yes |

The primary question is not which model has the lowest regression error. The primary question is which controller produces the best valid accelerator result under the accuracy constraint.

## 7. Success Criteria

Experiment 2 is successful only if all of the following are true:

- The controller uses full ResNet18/VGG16 features.
- The learned model is evaluated on a group-held-out test set.
- The selected PE value is converted into a real SCALE-Sim configuration.
- SCALE-Sim results are collected for the selected decision.
- Accuracy or degradation remains within the declared limit.
- Fixed and adaptive cycles are compared.
- Memory and energy claims are supported by simulator outputs.
- No simulator result is described as physical hardware measurement.
- The final report identifies whether Random Forest, MLP, or linear regression was selected.

## 8. Current Status

The first implementation slice is now present in this folder:

- `adaptive_flow.py` implements per-layer quality state and feed-forward PE selection.
- `model_signature.py` creates a stable architecture signature and detects unseen models.
- `scalesim_adapter.py` maps a selected PE level to a reproducible SCALE-Sim command description.
- `test_exp2.py` provides dependency-light smoke tests for these three behaviors.

The controller carries a normalized quality margin from layer $l$ to layer $l+1$:

$$
q_l = \operatorname{clip}\left(
\frac{D_{max}-\hat{D}_{l,PE_l}}{D_{max}},-1,1
\right).
$$

The next-layer threshold is adjusted using that forwarded state:

$$
D_{max,l+1}=D_{max}(1+\gamma q_l),
$$

where $\gamma$ is the feed-forward gain. A positive margin permits more aggressive resource reduction in the next layer; a negative margin tightens the threshold and favors additional resources. This is a control signal and must be calibrated against measured degradation before it is described as an accuracy signal.

The real ResNet18/VGG16 activation feature collection and a standalone ResNet18 SCALE-Sim run have been exercised. The existing controller summaries are not valid learned-controller evidence: the earlier collector compared dense logits with an unchanged clone, producing zero labels for every PE choice. Feature collection now leaves degradation labels unset, and model training refuses to proceed until measured labels are supplied. Per-PE SCALE-Sim sweeps, joining simulator measurements to features, and physical hardware validation remain pending.

The existing Stage 13 paper results remain separate:

- exact-zero sparse execution is evaluated analytically;
- dense and sparse predictions agree on the four final workloads;
- the deterministic policy selects 64 PEs;
- full-network Random Forest control is not yet reported;
- end-to-end SCALE-Sim adaptive results are not yet reported.

## 9. Run the Current Smoke Tests

From the Experiment 2 directory:

```bash
python -m unittest -v test_exp2.py
```

The smoke tests verify that:

1. a quality signal from one layer can change the next-layer PE decision;
2. a new model signature requests calibration and reconfiguration;
3. a selected PE value maps to the corresponding SCALE-Sim configuration and output directory.
