# Figure Captions

1. **Proposed runtime activation monitoring architecture.** Conceptual data path showing exact-zero activation detection, dense or sparse execution, PE selection, output reuse across layers, and the separate analytical path used to compute useful MACs and analytical cycles. The diagram does not imply full-network RTL or physical latency measurements.
2. **Accuracy dense vs sparse.** Dense and exact-zero sparse test accuracy for the four model/dataset pairs; the x-axis identifies the workload and the y-axis reports test accuracy. The bars coincide because no prediction mismatches were observed.
3. **Per-layer sparsity.** Exact-zero activation sparsity by convolution-layer index; layer0 denotes the first measured convolution. The y-axis reports percentage sparsity.
4. **Dense and useful MACs.** Analytical dense MACs and useful MACs for each workload. The y-axis reports MAC count; useful MACs are lower because exact-zero operands are skipped.
5. **Fixed64 cycles.** Analytical dense and sparse cycles using 64 PEs. The y-axis reports analytical cycles, not physical latency.
6. **Fixed64 versus adaptive cycles.** Fixed64 sparse cycles and adaptive cycles at the evaluated epsilon-0 constraint. Coincident bars reflect the selected 64-PE policy result.
7. **Active PE allocation.** Average active PE selection for the four workloads. The y-axis reports selected PEs; all final workloads select 64.
8. **Training and validation accuracy.** Available training and validation accuracy histories from the Stage 13 source plots. These plots are descriptive training evidence, not new experiments.
9. **Training and validation loss.** Available training and validation loss histories from the Stage 13 source plots.
