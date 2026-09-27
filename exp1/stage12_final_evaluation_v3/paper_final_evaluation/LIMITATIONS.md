# Limitations

1. Analytical cycles are not measured hardware latency.
2. Full ResNet18/VGG16 RTL correlation is not performed unless an explicitly compatible implementation exists.
3. Stage 8-11 reduced-workload RTL results must remain separate.
4. No physical FPGA/ASIC timing claims.
5. No physical power claims.
6. No physical energy claims.
7. No arbitrary conversion of Accelergy units to joules.
8. Sparse computation uses exact-zero activation operands.
9. Adaptive PE allocation is evaluated analytically.
10. Test data is not used for policy selection.
11. Results are limited to the tested models/datasets and declared methodology.
12. The final paper evaluation is complete for the four tested model/dataset pairs. RTL correlation and physical energy measurement remain outside this package and are explicitly marked NOT RUN.
