# Thesis Outline

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
