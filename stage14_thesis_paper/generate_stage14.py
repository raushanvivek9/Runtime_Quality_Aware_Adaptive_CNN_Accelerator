#!/usr/bin/env python3
from __future__ import annotations

import csv
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path('/home/cs25m115/Neural_Acc')
STAGE13 = ROOT / 'stage13_final_freeze'
OUT = ROOT / 'stage14_thesis_paper'
RESULTS = STAGE13 / 'tables' / 'STAGE13_FINAL_RESULTS.csv'
POLICY = STAGE13 / 'tables' / 'PAPER_RESOURCE_POLICY_TABLE.csv'
FIGURES = STAGE13 / 'figures'


def read_csv(path):
    with path.open(newline='') as handle:
        return list(csv.DictReader(handle))


def write_csv(path, rows, fields):
    with path.open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows({field: row.get(field, '') for field in fields} for row in rows)


def ensure_dirs():
    for path in ('thesis', 'paper', 'paper/tables', 'paper/figures', 'references', 'reports'):
        (OUT / path).mkdir(parents=True, exist_ok=True)


def copy_figures():
    for name in (
        'accuracy_dense_sparse.png', 'per_layer_sparsity.png', 'macs_dense_useful.png',
        'cycles_fixed64.png', 'cycles_fixed64_vs_adaptive.png', 'active_pe_allocation.png',
        'training_validation_accuracy.png', 'training_validation_loss.png',
    ):
        source = FIGURES / name
        if source.exists():
            shutil.copy2(source, OUT / 'paper' / 'figures' / name)


def generate_tables(results, policy):
    fields = ['Model', 'Dataset', 'Best Epoch', 'Best Validation Accuracy', 'Test Accuracy', 'Activation Sparsity', 'MAC Reduction', 'Dense Cycles', 'Sparse Cycles', 'Adaptive Cycles', 'Average PE', 'Prediction Mismatch', 'Status']
    rows = [{
        'Model': row['model'], 'Dataset': row['dataset'], 'Best Epoch': row['best_epoch'],
        'Best Validation Accuracy': row['best_validation_accuracy'], 'Test Accuracy': row['test_accuracy'],
        'Activation Sparsity': row['activation_sparsity'], 'MAC Reduction': row['MAC_reduction'],
        'Dense Cycles': row['fixed64_dense_cycles'], 'Sparse Cycles': row['fixed64_sparse_cycles'],
        'Adaptive Cycles': row['adaptive_cycles_epsilon0'], 'Average PE': row['average_PE_epsilon0'],
        'Prediction Mismatch': row['prediction_mismatch_count'], 'Status': row['status'],
    } for row in results]
    write_csv(OUT / 'paper/tables/final_results_table.csv', rows, fields)
    with (OUT / 'paper/tables/final_results_table.md').open('w') as handle:
        handle.write('| ' + ' | '.join(fields) + ' |\n')
        handle.write('|' + '|'.join(['---'] * len(fields)) + '|\n')
        for row in rows:
            handle.write('| ' + ' | '.join(str(row[field]) for field in fields) + ' |\n')
    policy_fields = ['Model', 'Dataset', 'Epsilon', 'Average Active PE', 'PE Reduction', 'Fixed64 Sparse Cycles', 'Adaptive Cycles', 'Cycle Change', 'Status']
    policy_rows = [{
        'Model': row['model'], 'Dataset': row['dataset'], 'Epsilon': row['epsilon'],
        'Average Active PE': row['average_active_PE'], 'PE Reduction': row['PE_reduction'],
        'Fixed64 Sparse Cycles': row['fixed64_sparse_cycles'], 'Adaptive Cycles': row['adaptive_cycles'],
        'Cycle Change': row['cycle_change'], 'Status': row['status'],
    } for row in policy]
    write_csv(OUT / 'paper/tables/adaptive_resource_table.csv', policy_rows, policy_fields)
    with (OUT / 'paper/tables/adaptive_resource_table.md').open('w') as handle:
        handle.write('| ' + ' | '.join(policy_fields) + ' |\n')
        handle.write('|' + '|'.join(['---'] * len(policy_fields)) + '|\n')
        for row in policy_rows:
            handle.write('| ' + ' | '.join(str(row[field]) for field in policy_fields) + ' |\n')


def result_lines(results):
    return '\n'.join(
        f"- {row['model']} / {row['dataset']}: test accuracy {row['test_accuracy']}, activation sparsity {row['activation_sparsity']}%, MAC reduction {row['MAC_reduction']}%, dense/sparse mismatches {row['prediction_mismatch_count']}, analytical sparse cycles {row['fixed64_sparse_cycles']}."
        for row in results
    )


def generate_docs(results, policy):
    (OUT / 'SOURCE_AUDIT.md').write_text(f'''# Stage 14 Source Audit

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
{result_lines(results)}

## Limitations carried forward
Analytical cycles are not physical hardware latency. Full-model ResNet18/VGG16 RTL correlation, physical FPGA/ASIC timing, physical power, and physical energy were not measured. Exact-zero activation operands are the sparse mechanism, adaptive PE allocation is analytical, and the scope is limited to the evaluated checkpoints, models, datasets, and methodology.

## Information not available from project evidence
The project does not provide verified external literature metadata, full-model RTL synthesis results, physical latency, power, or energy measurements. These are not supplied by assumption.

## External literature required
Background claims concerning accelerator history, sparse acceleration prior art, runtime monitoring prior art, adaptive resource allocation, quality-aware computing, and SAMURAI-related work require external literature verification. See `references/REQUIRED_LITERATURE_SEARCH.md`.
''')
    (OUT / 'thesis/THESIS_OUTLINE.md').write_text('''# Thesis Outline

## Chapter 1 — Introduction
1.1 Background; 1.2 Motivation; 1.3 Problem Statement; 1.4 Research Objectives; 1.5 Research Questions; 1.6 Contributions; 1.7 Scope; 1.8 Thesis Organization.

## Chapter 2 — Background and Related Work
2.1 Neural Network Accelerators; 2.2 Processing Elements; 2.3 Activation Sparsity; 2.4 Sparse Acceleration; 2.5 Runtime Monitoring; 2.6 Adaptive Resource Allocation; 2.7 Quality-Aware Computing; 2.8 SAMURAI and related monitoring concepts; 2.9 Research Gap; 2.10 Summary.

## Chapter 3 — Proposed Approach
3.1 Overview; 3.2 System Architecture; 3.3 Runtime Activation Monitoring; 3.4 Activation Statistics; 3.5 Quality/Degradation Estimation; 3.6 Resource Allocation Policy; 3.7 PE Configurations; 3.8 Exact-Zero Sparse Execution; 3.9 Analytical Computation Model; 3.10 Overall Algorithm; 3.11 Summary.

## Chapter 4 — Accelerator Architecture and Prototype
4.1 PE Architecture; 4.2 MAC Array; 4.3 Runtime Monitor; 4.4 Controller; 4.5 Dataflow; 4.6 Sparse Execution; 4.7 RTL Implementation; 4.8 Reduced-Workload RTL Validation; 4.9 Analytical-to-RTL Correlation; 4.10 Summary.

## Chapter 5 — Experimental Methodology
5.1 Objectives; 5.2 Datasets; 5.3 Splits; 5.4 Models; 5.5 Training; 5.6 Checkpoint Selection; 5.7 Dense Inference; 5.8 Sparse Inference; 5.9 Sparsity Metric; 5.10 MAC Calculation; 5.11 Cycle Calculation; 5.12 Adaptive Policy; 5.13 Metrics; 5.14 Reproducibility; 5.15 Summary.

## Chapter 6 — Experimental Results
6.1 Overall Results; 6.2 Accuracy; 6.3 Dense/Sparse Agreement; 6.4 Sparsity; 6.5 MAC Reduction; 6.6 Cycles; 6.7 Adaptive PE Allocation; 6.8 Per-Layer Analysis; 6.9 RTL Supporting Evidence; 6.10 Summary.

## Chapter 7 — Discussion
7.1 Main Findings; 7.2 Architecture; 7.3 Dataset; 7.4 Computation; 7.5 Prediction Preservation; 7.6 Resource Allocation; 7.7 No PE Reduction; 7.8 Sparsity vs Resource Allocation; 7.9 RTL Scope; 7.10 Implications; 7.11 Summary.

## Chapter 8 — Limitations
8.1 Analytical vs Physical Performance; 8.2 Full-Model RTL Scope; 8.3 Exact-Zero Assumption; 8.4 Policy Constraints; 8.5 Model/Dataset Scope; 8.6 Energy Scope; 8.7 Generalization; 8.8 Summary.

## Chapter 9 — Conclusion and Future Work
9.1 Conclusion; 9.2 Contributions; 9.3 Future Work.
''')
    (OUT / 'thesis/RESEARCH_QUESTIONS.md').write_text('''# Research Questions

- **RQ1:** How much exact-zero activation sparsity is observed across the evaluated CNN architectures and datasets?
- **RQ2:** How much analytical MAC reduction is obtained by skipping computation associated with exact-zero activation operands?
- **RQ3:** Does exact-zero sparse execution preserve dense-model predictions on the evaluated test sets?
- **RQ4:** Can runtime activation information support adaptive PE/resource allocation?
- **RQ5:** Under the evaluated analytical cycle constraint, does adaptive PE allocation reduce PE usage for the tested full-network workloads?
''')
    (OUT / 'thesis/CONTRIBUTIONS.md').write_text('''# Contributions

## A. Methodological contribution
The work defines an evidence-based evaluation flow for exact-zero activation sparsity, analytical useful-MAC reduction, and dense/sparse prediction comparison.

## B. Runtime monitoring contribution
The project measures activation zero counts and related per-layer statistics during inference. The Stage 13 evidence supports characterization, not a claim of physical runtime implementation for the full networks.

## C. Sparse computation contribution
The experiments evaluate skipping exact-zero convolution input operands with unchanged checkpoint weights.

## D. Resource-policy evaluation
The existing analytical policy is evaluated at four epsilon values and selects 64 PEs for all four final workloads. This is an evaluated result, not a claim of adaptive improvement.

## E. Accelerator/RTL prototype contribution
Earlier Stage 8–11 artifacts provide reduced-workload RTL/prototype evidence. Full ResNet18/VGG16 RTL validation is outside the demonstrated scope.

## F. Experimental contribution
The final matrix covers ResNet18 and VGG16 on CIFAR10 and CIFAR100 with complete test-set dense/sparse comparisons.

Novelty and state-of-the-art claims require literature verification and are intentionally not made here.
''')
    (OUT / 'thesis/APPENDIX_PLAN.md').write_text('''# Appendix Plan

- **Appendix A:** Training configurations and checkpoint metadata.
- **Appendix B:** Complete final results tables.
- **Appendix C:** Per-layer sparsity and layer0 labeling.
- **Appendix D:** Adaptive resource-policy rows for all epsilon values.
- **Appendix E:** Reduced-workload RTL evidence from Stages 8–11, clearly separated from full-model analytical results.
- **Appendix F:** Reproducibility manifest, software versions, paths, and hashes.
''')
    (OUT / 'thesis/REPRODUCIBILITY.md').write_text('''# Reproducibility

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
''')
    (OUT / 'references/REQUIRED_LITERATURE_SEARCH.md').write_text('''# Required Literature Search

No verified bibliography was found in the project source audit. The following claims require external, traceable sources before submission:

1. Neural-network accelerator architecture and processing-element arrays.
2. Activation sparsity and zero-skipping acceleration.
3. Runtime activation monitoring and hardware monitoring mechanisms.
4. Adaptive resource allocation and dynamic PE configuration.
5. Quality-aware or approximate neural-network acceleration.
6. SAMURAI or monitoring-inspired related work.
7. General claims about computational cost, energy, latency, or prior-art gaps.

Required metadata for each selected source: title, authors, venue, year, DOI or official URL, and relevance. No citation is asserted by this draft.
''')
    (OUT / 'references/bibliography.md').write_text('''# Bibliography

No external references are asserted in this Stage 14 draft because the source audit found no verified project bibliography. See `REQUIRED_LITERATURE_SEARCH.md` before publication.

[REFERENCE REQUIRED]
''')
    (OUT / 'paper/FIGURE_CAPTIONS.md').write_text('''# Figure Captions

1. **Accuracy dense vs sparse.** Dense and exact-zero sparse test accuracy for the four model/dataset pairs; the x-axis identifies the workload and the y-axis reports test accuracy. The bars coincide because no prediction mismatches were observed.
2. **Per-layer sparsity.** Exact-zero activation sparsity by convolution-layer index; layer0 denotes the first measured convolution. The y-axis reports percentage sparsity.
3. **Dense and useful MACs.** Analytical dense MACs and useful MACs for each workload. The y-axis reports MAC count; useful MACs are lower because exact-zero operands are skipped.
4. **Fixed64 cycles.** Analytical dense and sparse cycles using 64 PEs. The y-axis reports analytical cycles, not physical latency.
5. **Fixed64 versus adaptive cycles.** Fixed64 sparse cycles and adaptive cycles at the evaluated epsilon-0 constraint. Coincident bars reflect the selected 64-PE policy result.
6. **Active PE allocation.** Average active PE selection for the four workloads. The y-axis reports selected PEs; all final workloads select 64.
7. **Training and validation accuracy.** Available training and validation accuracy histories from the Stage 13 source plots. These plots are descriptive training evidence, not new experiments.
8. **Training and validation loss.** Available training and validation loss histories from the Stage 13 source plots.
''')
    (OUT / 'reports/STAGE14_CONTENT_VALIDATION.md').write_text('''# Stage 14 Content Validation

- **PASS** Stage 13 source audited.
- **PASS** All numerical tables are generated from Stage 13 machine-readable tables.
- **PASS** All required figures are copied from Stage 13 without data edits.
- **PASS** The old VGG16/CIFAR100 result is excluded from final tables and narrative.
- **PASS** No new experimental values were fabricated.
- **REVIEW_REQUIRED** External literature and bibliography require verification.
- **PASS** No unsupported physical speedup, energy, power, or full-model RTL claim is made.
- **PASS** Analytical cycles are labeled as analytical.
- **PASS** Exact-zero sparsity is defined.
- **PASS** The adaptive policy result of 64 PEs for all workloads is reported.
- **PASS** Limitations are included.
''')


def generate_drafts(results):
    result_block = result_lines(results)
    thesis = f'''# Thesis Draft: Runtime Activation Monitoring and Sparse Resource Evaluation for Neural Network Accelerators

## Chapter 1 — Introduction
Deep neural networks perform repeated convolutional operations over intermediate activations. The project studies whether exact-zero activation information can characterize computation and support analytical sparse execution. The objective is to measure activation behavior, estimate useful computation, compare dense and sparse predictions, and evaluate an analytical PE policy without making a physical hardware performance claim.

The final evaluation covers four workloads: ResNet18/CIFAR10, ResNet18/CIFAR100, VGG16/CIFAR10, and VGG16/CIFAR100. The scope is limited to the frozen Stage 13 evidence.

## Chapter 2 — Background and Related Work
Neural accelerators, processing-element arrays, sparse execution, runtime monitoring, and adaptive allocation require external literature support. Citation placeholders are recorded in `references/REQUIRED_LITERATURE_SEARCH.md`; no unsupported prior-art or novelty claim is made here.

## Chapter 3 — Proposed Approach
The conceptual flow is: neural network, intermediate activation monitoring, zero-count and statistical summaries, quality/degradation estimation, analytical resource policy, PE configuration, and exact-zero sparse computation. In this project, the final full-network evidence measures exact-zero operands and analytical consequences. It does not establish full-network RTL timing or physical power.

## Chapter 4 — Accelerator Architecture and Prototype
The project includes reduced-workload RTL/prototype evidence from earlier stages. That evidence remains separate from the Stage 13 full-network analytical evaluation. The thesis must not imply that complete ResNet18 or VGG16 networks were synthesized or physically benchmarked.

## Chapter 5 — Experimental Methodology
CIFAR10 and CIFAR100 use 45,000 training images, 5,000 validation images, and 10,000 test images with seed 42. Best checkpoints are selected by validation accuracy. Dense and sparse inference use the same weights and complete test set. Sparse execution skips only exactly zero convolution input operands. MAC reduction is based on dense, useful, and skipped MACs. Analytical cycles use ceil(MACs/active_PEs), PE candidates 16, 32, and 64, and epsilon values 0%, 5%, 10%, and 20%.

## Chapter 6 — Experimental Results
{result_block}

All four workloads preserve predictions under exact-zero sparse execution: dense and sparse accuracies are equal and mismatch counts are zero. VGG16/CIFAR10 has the highest measured aggregate activation sparsity. The adaptive policy selects 64 PEs for every workload and epsilon value.

## Chapter 7 — Discussion
The results separate two effects. Exact-zero activation sparsity reduces useful MACs and analytical cycles. The evaluated latency-constrained PE policy does not reduce the selected PE count for these full-network workloads. This is a neutral result that indicates computation sparsity and PE-count adaptation are distinct opportunities.

## Chapter 8 — Limitations
Analytical cycles are not measured hardware latency. Full-model RTL, physical timing, power, and energy are not validated. Earlier reduced-workload RTL results remain supporting evidence with a different scope. Results are limited to four workloads and exact-zero activation sparsity.

## Chapter 9 — Conclusion and Future Work
The evidence demonstrates measurable activation sparsity, substantial analytical useful-MAC reduction, and exact dense/sparse prediction agreement on the evaluated test sets. Future work includes broader models and datasets, hardware-aware policies, full-network RTL, FPGA implementation, and physical latency/power/energy measurements.

## Appendices
Appendices should include the complete tables, per-layer sparsity, policy rows, RTL scope, and reproducibility manifest.
'''
    (OUT / 'thesis/THESIS_DRAFT.md').write_text(thesis)
    paper = f'''# Runtime Activation Monitoring and Sparse Resource Evaluation for Neural Network Accelerators

## Abstract
This work evaluates exact-zero activation sparsity in CIFAR-compatible ResNet18 and VGG16 models across CIFAR10 and CIFAR100. Using frozen best-validation checkpoints, the study compares dense and exact-zero sparse inference on the complete 10,000-image test sets, measures activation sparsity, computes analytical useful-MAC and cycle reductions, and evaluates an existing PE policy. The four workloads show MAC reductions from 68.28395165353061% to 89.59230678816175%. Dense and sparse predictions agree exactly with zero mismatches in every evaluated case. The policy selects 64 PEs for all workloads at all tested epsilon values. These results are analytical; full-network RTL, physical latency, power, and energy are outside the evidence scope.

## 1. Introduction
Accelerator computation is dominated by repeated operations over intermediate activations. Runtime activation information can expose exact-zero operands and provide a basis for sparse computation analysis. This paper evaluates that idea without claiming physical speedup or energy reduction. Prior-art and research-gap statements require the external literature search identified in `references/REQUIRED_LITERATURE_SEARCH.md`.

## 2. Related Work
The related-work section must be completed from verified sources covering neural accelerators, activation sparsity, zero skipping, runtime monitoring, adaptive allocation, quality-aware computing, and SAMURAI-related work. No citations are fabricated in this draft.

## 3. Proposed Method
The method monitors intermediate activations, records exact-zero statistics, estimates useful convolution MACs, compares dense and sparse inference, and evaluates a PE policy over 16, 32, and 64 candidates. Sparse execution changes neither weights nor nonzero values. Analytical cycles are computed as ceil(useful_MACs/active_PEs).

## 4. Accelerator Architecture
Earlier project stages provide reduced-workload RTL/prototype validation. The present full-network results are software and analytical evaluations. Complete ResNet18/VGG16 RTL validation and physical hardware measurements are not claimed.

## 5. Experimental Methodology
The four workloads use 45,000/5,000/10,000 train/validation/test splits, seed 42, frozen best checkpoints, exact-zero activation sparsity, complete test-set evaluation, and epsilon values 0%, 5%, 10%, and 20%.

## 6. Results
{result_block}

Dense and sparse accuracies agree for all four workloads with zero prediction mismatches. The policy selects 64 PEs for all workloads, so PE-count reduction is not observed under the evaluated constraint.

## 7. Discussion
The results demonstrate substantial analytical computation reduction while preserving predictions. VGG16/CIFAR10 has the highest measured aggregate activation sparsity. Sparse computation reduction and adaptive PE-count reduction should be treated as separate optimization effects.

## 8. Limitations
Analytical cycles are not hardware latency. Full-model RTL, physical FPGA/ASIC timing, physical power, and physical energy were not measured. Accelergy units are not converted into joules. The scope is limited to the four evaluated workloads and exact-zero mechanism.

## 9. Conclusion
Within the evaluated scope, exact-zero sparse execution reduces useful computation and analytical cycles while preserving predictions. The PE policy selected 64 PEs for every final workload. Broader hardware and literature validation remain future work.

## References
[REFERENCE REQUIRED — complete from verified external sources before submission]
'''
    (OUT / 'paper/PAPER_DRAFT.md').write_text(paper)


def generate_status(results):
    (OUT / 'STAGE14_STATUS.md').write_text('''# Stage 14 Status

Overall status: **REVIEW_REQUIRED**

- [x] Stage 13 source audited
- [x] thesis outline created
- [x] research questions created
- [x] contributions documented
- [x] thesis draft created
- [x] paper draft created
- [x] final tables included
- [x] final figures included
- [x] methodology documented
- [x] results documented
- [x] discussion documented
- [x] limitations documented
- [ ] references verified
- [x] no fabricated references
- [x] no fabricated results
- [x] no unsupported hardware claims
- [x] Stage 13 numbers preserved
- [x] old VGG100 result excluded
- [x] adaptive PE result correctly reported
- [x] content validation completed

Stage 14 is REVIEW_REQUIRED only because external literature references remain to be verified. Experimental evidence is frozen and internally consistent.
''')


def main():
    ensure_dirs()
    results = read_csv(RESULTS)
    policy = read_csv(POLICY)
    assert len(results) == 4 and all(row['status'] == 'PASS' for row in results)
    assert len(policy) == 16 and all(row['status'] == 'PASS' for row in policy)
    copy_figures()
    generate_tables(results, policy)
    generate_docs(results, policy)
    generate_drafts(results)
    generate_status(results)
    print(json.dumps({
        'stage14': str(OUT), 'results': len(results), 'policy_rows': len(policy),
        'figures': len(list((OUT / 'paper/figures').glob('*.png'))),
        'literature_items_requiring_verification': 7,
        'status': 'REVIEW_REQUIRED',
    }, indent=2))


if __name__ == '__main__':
    main()
