# Reproducibility

- Project root: `/home/cs25m115/Neural_Acc`
- Stage 12: `/home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3`
- Stage 13: `/home/cs25m115/Neural_Acc/stage13_final_freeze`
- Stage 14: `/home/cs25m115/Neural_Acc/stage14_thesis_paper`
- Seed: 42
- Split: 45,000 train / 5,000 validation / 10,000 test
- Datasets: CIFAR10 and CIFAR100, local pickle data
- PE candidates: 16, 32, 64
- Epsilon values: 0%, 5%, 10%, 20%
- Sparse execution: exact-zero activation operands only
- Authoritative manifest: `stage13_final_freeze/provenance/STAGE13_MANIFEST.md`
- Authoritative validation command: `python stage13_final_freeze/validation/run_stage13_validation.py`
