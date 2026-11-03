#!/usr/bin/env python3
"""
generate_claim_matrix.py
TSK-37: Research Claim Matrix Generator
Maps every proposed paper claim to:
- Claim ID
- Exact scientific claim
- Supporting experiment
- Source files and logs
- Numerical result
- Evidence category (RTL simulation measurements, Independent software-reference calculations,
  Host-side preprocessing, Analytical or model-derived estimates, Physical measurements)
- Validation status (VERIFIED, VERIFIED_WITH_LIMITATIONS, NOT_REPRODUCED, NOT_MEASURED)
- Known limitations
- Recommended paper wording

Outputs: TSK37_RESEARCH_CLAIM_MATRIX.csv
"""

import os
import csv

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO_ROOT, "TSK37_RESEARCH_READINESS")

claims = [
    {
        "Claim_ID": "CLM_001",
        "Exact_Scientific_Claim": "Bit-exact numerical correctness across spatial tile sequencing and multi-chunk accumulation",
        "Supporting_Experiment": "Independent software convolution vs RTL golden outputs across WL1-WL4",
        "Source_Files_and_Logs": "TSK37_RESEARCH_READINESS/reproduce_numerical_evidence.py, TSK37_NUMERICAL_EVIDENCE.csv, TSK30_RESULTS.csv",
        "Numerical_Result": "0 mismatches, MAE = 0.0, RMSE = 0.0 across 1,024 output elements (4 workloads x 256 elements; 589,824 MACs)",
        "Evidence_Category": "Independent software-reference calculations & RTL simulation measurements",
        "Validation_Status": "VERIFIED",
        "Known_Limitations": "Evaluated on 4x4 spatial grid (16 tiles) of 16 output channels; does not represent full CIFAR image (32x32) or full-network inference",
        "Recommended_Paper_Wording": "The accelerator RTL achieves bit-exact numerical equivalence (MAE = 0.0) against an independent INT16/INT40 reference model for a 4x4 spatial grid of 16 channels across ResNet-18 and VGG-16 layers."
    },
    {
        "Claim_ID": "CLM_002",
        "Exact_Scientific_Claim": "Activation zero-skipping eliminates weight SRAM reads and active MAC compute switching proportionally to layer sparsity",
        "Supporting_Experiment": "Dense vs Sparse cycle-accurate RTL execution across 12 workload-mode configurations",
        "Source_Files_and_Logs": "TSK37_RESEARCH_READINESS/reproduce_sparse_evidence.py, TSK37_SPARSE_EXECUTION_RESULTS.csv, TSK30_RESULTS.csv",
        "Numerical_Result": "Weight SRAM reads and compute cycles drop by exactly 48.11% (WL3), 66.57% (WL2), 68.89% (WL1), and 84.92% (WL4), matching activation sparsity percentage",
        "Evidence_Category": "RTL simulation measurements",
        "Validation_Status": "VERIFIED",
        "Known_Limitations": "Measured via cycle-accurate RTL switching counters; physical clock-tree power, static leakage, and SRAM macro peripheral power are unmodeled",
        "Recommended_Paper_Wording": "Activation zero-skipping eliminates 48.1% to 84.9% of weight SRAM reads and active MAC compute cycles across evaluated convolutional layers."
    },
    {
        "Claim_ID": "CLM_003",
        "Exact_Scientific_Claim": "Activation sparsity accelerates total execution wall-clock latency",
        "Supporting_Experiment": "Total_Execution_Cycles comparison between Dense and Sparse regimes across 16-, 32-, and 64-PE modes",
        "Source_Files_and_Logs": "TSK37_RESEARCH_READINESS/reproduce_sparse_evidence.py, TSK37_SPARSE_EXECUTION_RESULTS.csv",
        "Numerical_Result": "Total cycle count is identical between Dense and Sparse regimes (9,569 / 19,121 / 38,225 cycles; exactly 0.00% latency reduction)",
        "Evidence_Category": "RTL simulation measurements",
        "Validation_Status": "NOT_REPRODUCED",
        "Known_Limitations": "Sequencer and address generators advance synchronously; zero activations suppress compute and SRAM strobes but do not compress pipeline cycles",
        "Recommended_Paper_Wording": "In the current microarchitecture, activation sparsity functions as an energy/switching-reduction mechanism rather than a latency accelerator, maintaining constant execution latency due to synchronous channel-chunk stepping."
    },
    {
        "Claim_ID": "CLM_004",
        "Exact_Scientific_Claim": "Deterministic transparent hardware resource allocation satisfies latency budgets and PE resource caps (Policy A & B)",
        "Supporting_Experiment": "Boundary sweep across 200 constraint points (10 PE caps x 10 latency budgets x 2 policies) in RTL simulation",
        "Source_Files_and_Logs": "TSK37_RESEARCH_READINESS/tb_tsk37_policy_audit.sv, TSK37_ADAPTIVE_POLICY_RESULTS.csv, TSK33_MEASUREMENT_RESULTS.csv",
        "Numerical_Result": "201 / 201 boundary checks matched bit-exactly. Policy A reduces active PEs by up to 75%; Policy B achieves minimum latency up to PE cap",
        "Evidence_Category": "RTL simulation measurements & Independent software-reference calculations",
        "Validation_Status": "VERIFIED",
        "Known_Limitations": "Requires host-specified latency budgets and PE caps; does not autonomously infer layer deadlines without host supervision",
        "Recommended_Paper_Wording": "The transparent hardware resource controller deterministically allocates between 16, 32, and 64 PEs, reducing active PE logic by up to 75% while meeting latency deadlines, or maximizing throughput up to host-specified resource caps."
    },
    {
        "Claim_ID": "CLM_005",
        "Exact_Scientific_Claim": "Hardware safety gating positively blocks compute execution when active PE cap is below physical minimum (Pmax < 16)",
        "Supporting_Experiment": "RTL boundary simulation under invalid caps (0, 8, 15) and recovery validation",
        "Source_Files_and_Logs": "TSK37_RESEARCH_READINESS/tb_tsk37_policy_audit.sv, TSK37_ADAPTIVE_POLICY_RESULTS.csv, TSK35A_DOWNSTREAM_GATING_RESULTS.csv",
        "Numerical_Result": "In 100% of invalid cases, execution_enable = 0, invalid_pe_limit = 1, resolved_mode = 2'b11, and compute_start pulsed 0 times. Clean single-cycle recovery verified",
        "Evidence_Category": "RTL simulation measurements",
        "Validation_Status": "VERIFIED",
        "Known_Limitations": "Verified at RTL integration boundary; host driver must inspect execution_enable or invalid_pe_limit flags",
        "Recommended_Paper_Wording": "Hardware interlocks strictly reject infeasible resource caps (Pmax < 16), asserting an explicit invalid flag and deasserting execution enable to prevent unauthorized hardware execution."
    },
    {
        "Claim_ID": "CLM_006",
        "Exact_Scientific_Claim": "Multi-pass channel tiling incurs substantial activation memory bandwidth overhead in 16-PE and 32-PE modes",
        "Supporting_Experiment": "Empirical SRAM access counter analysis across 16-, 32-, and 64-PE modes",
        "Source_Files_and_Logs": "TSK37_RESEARCH_READINESS/reproduce_sparse_evidence.py, TSK35B_SRAM_TRAFFIC_ANALYSIS.csv",
        "Numerical_Result": "Activation SRAM reads increase by +100.0% (32-PE, 2 passes) and +300.0% (16-PE, 4 passes). Total SRAM traffic increases by up to +87.18%",
        "Evidence_Category": "RTL simulation measurements",
        "Validation_Status": "VERIFIED",
        "Known_Limitations": "Measured on internal multi-bank SRAM subsystem; external DRAM traffic depends on on-chip buffer sizing and reuse strategies",
        "Recommended_Paper_Wording": "While reducing active PEs lowers instantaneous datapath footprint, multi-pass tiling introduces a trade-off by increasing activation SRAM read traffic by 2x (32-PE) and 4x (16-PE)."
    },
    {
        "Claim_ID": "CLM_007",
        "Exact_Scientific_Claim": "Reducing active PE count from 64 to 32 or 16 PEs reduces total system execution energy",
        "Supporting_Experiment": "Energy trade-off analysis comparing execution time and memory access counts",
        "Source_Files_and_Logs": "TSK35B_POLICY_BENEFIT_REPORT.md, TSK36_RESOURCE_LATENCY_AUDIT.csv",
        "Numerical_Result": "Unsubstantiated by physical energy characterization. Longer execution time (2x to 4x) and higher SRAM traffic (+10% to +87% more accesses) counteract datapath power gating",
        "Evidence_Category": "Physical measurements (Unmeasured) & Analytical or model-derived estimates",
        "Validation_Status": "NOT_MEASURED",
        "Known_Limitations": "Requires silicon-calibrated gate-level power simulation with characterized cell libraries; simulation counters alone cannot determine net energy",
        "Recommended_Paper_Wording": "Dynamic PE allocation functions as an effective silicon area and peak power/thermal throttle; however, total energy reduction is not claimed due to multi-pass memory traffic and runtime overheads."
    },
    {
        "Claim_ID": "CLM_008",
        "Exact_Scientific_Claim": "Full-network CNN inference, silicon area closure, and physical timing closure at 100 MHz",
        "Supporting_Experiment": "Inspection of codebase scope, testbenches, and physical implementation scripts",
        "Source_Files_and_Logs": "phase2_step1_microarchitecture_and_rtl/run_regression.py, TSK22 synthesis reports",
        "Numerical_Result": "Microarchitecture achieves 100 MHz in cycle-accurate RTL simulation and preliminary Vivado synthesis; full-network inference and taped-out silicon are unmeasured",
        "Evidence_Category": "Physical measurements (Unmeasured) & RTL simulation measurements",
        "Validation_Status": "VERIFIED_WITH_LIMITATIONS",
        "Known_Limitations": "Simulations validate individual representative convolutional layers; non-linear pooling, inter-layer pipelining, and silicon packaging remain future work",
        "Recommended_Paper_Wording": "The microarchitecture is verified at cycle-accurate RTL level across representative convolutional layers of ResNet-18 and VGG-16; full-network inference and silicon tape-out remain future work."
    },
    {
        "Claim_ID": "CLM_009",
        "Exact_Scientific_Claim": "Fixed-point symmetric Q4.12 quantization maintains numerical fidelity for integer datapath",
        "Supporting_Experiment": "Off-line quantization of PyTorch pretrained float32 tensors into INT16 Q4.12 hex formats",
        "Source_Files_and_Logs": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/, TSK37_NUMERICAL_EVIDENCE.csv",
        "Numerical_Result": "Weights and activations converted to signed INT16 with zero saturation overflow across 147,456 operations per workload",
        "Evidence_Category": "Host-side preprocessing & Independent software-reference calculations",
        "Validation_Status": "VERIFIED",
        "Known_Limitations": "Quantization scale factors are computed offline per layer; dynamic per-tensor scaling or activation re-quantization between layers is managed by host",
        "Recommended_Paper_Wording": "Off-line symmetric Q4.12 fixed-point quantization provides stable integer scaling across evaluated ResNet-18 and VGG-16 layers, preventing dynamic overflow in the 40-bit accumulator."
    },
    {
        "Claim_ID": "CLM_010",
        "Exact_Scientific_Claim": "Multi-bank hybrid SRAM architecture provides parallel conflict-free operand delivery to PE array",
        "Supporting_Experiment": "Master regression testbench suites tb_multibank_sram_subsystem and tb_parallel_pe_operand_delivery",
        "Source_Files_and_Logs": "phase2_step1_microarchitecture_and_rtl/tb_multibank_sram_subsystem.sv, tb_parallel_pe_operand_delivery.sv, regression log",
        "Numerical_Result": "137 SRAM checks and 226 operand delivery checks pass without backpressure stalls during active compute phases",
        "Evidence_Category": "RTL simulation measurements",
        "Validation_Status": "VERIFIED",
        "Known_Limitations": "Validated for 16-, 32-, and 64-word broadcast patterns in internal scratchpads; external memory bus latency is abstracted in core testbenches",
        "Recommended_Paper_Wording": "The hybrid multibank SRAM subsystem sustains full-throughput parallel operand delivery to up to 64 PEs simultaneously without bank conflicts during compute phases."
    }
]

def main():
    out_csv = os.path.join(OUT_DIR, "TSK37_RESEARCH_CLAIM_MATRIX.csv")
    fields = [
        "Claim_ID", "Exact_Scientific_Claim", "Supporting_Experiment",
        "Source_Files_and_Logs", "Numerical_Result", "Evidence_Category",
        "Validation_Status", "Known_Limitations", "Recommended_Paper_Wording"
    ]

    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(claims)

    print(f"[SUCCESS] TSK37_RESEARCH_CLAIM_MATRIX.csv written with {len(claims)} scientific claims.")

if __name__ == "__main__":
    main()

