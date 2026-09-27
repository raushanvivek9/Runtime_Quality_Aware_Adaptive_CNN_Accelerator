# Stage 14 Source Audit

## Stage 13 status
Stage 13 is frozen with PASS status, 48 checks passed, zero failed, and zero review-required checks. Stage 13 is the sole authority for numerical experimental evidence.

## Authoritative result files
- `stage13_final_freeze/tables/STAGE13_FINAL_RESULTS.json`
- `stage13_final_freeze/tables/STAGE13_FINAL_RESULTS.csv`
- `stage13_final_freeze/tables/PAPER_FINAL_RESULTS_TABLE.csv`
- `stage13_final_freeze/tables/PAPER_RESOURCE_POLICY_TABLE.csv`
- `stage13_final_freeze/validation/STAGE13_VALIDATION_REPORT.json`

## Authoritative methodology and scope files
- `stage13_final_freeze/reports/FINAL_METHODOLOGY.md`
- `stage13_final_freeze/reports/FINAL_LIMITATIONS.md`
- `stage13_final_freeze/provenance/STAGE13_MANIFEST.md`
- `stage13_final_freeze/reports/PAPER_FINAL_REPORT_STAGE13.md`

## Authoritative figures
The eight PNG figures in `stage13_final_freeze/figures/` are copied without modification into `stage14_thesis_paper/paper/figures/`.

## Final model/dataset matrix
- ResNet18 / CIFAR10: test accuracy 0.9513, activation sparsity 62.51186579895019%, MAC reduction 72.24934835338311%, dense/sparse mismatches 0, analytical sparse cycles 24083125525.
- ResNet18 / CIFAR100: test accuracy 0.7697, activation sparsity 57.68464033508301%, MAC reduction 68.28395165353061%, dense/sparse mismatches 0, analytical sparse cycles 27524455397.
- VGG16 / CIFAR10: test accuracy 0.8846, activation sparsity 83.45374636136567%, MAC reduction 89.59230678816175%, dense/sparse mismatches 0, analytical sparse cycles 5093208664.
- VGG16 / CIFAR100: test accuracy 0.6557, activation sparsity 53.85006880540114%, MAC reduction 69.98297529719868%, dense/sparse mismatches 0, analytical sparse cycles 14689419372.

## Limitations carried forward
Analytical cycles are not physical hardware latency. Full-model ResNet18/VGG16 RTL correlation, physical FPGA/ASIC timing, physical power, and physical energy were not measured. Exact-zero activation operands are the sparse mechanism, adaptive PE allocation is analytical, and the scope is limited to the evaluated checkpoints, models, datasets, and methodology.

## Information not available from project evidence
The project does not provide verified external literature metadata, full-model RTL synthesis results, physical latency, power, or energy measurements. These are not supplied by assumption.

## External literature required
Background claims concerning accelerator history, sparse acceleration prior art, runtime monitoring prior art, adaptive resource allocation, quality-aware computing, and SAMURAI-related work require external literature verification. See `references/REQUIRED_LITERATURE_SEARCH.md`.
