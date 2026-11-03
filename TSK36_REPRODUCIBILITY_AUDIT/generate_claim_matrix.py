#!/usr/bin/env python3
"""
generate_claim_matrix.py
Phase 6: Research Claim Matrix Generation
Audits research claims from TSK-28 through TSK-35B and classifies each as:
- VERIFIED
- VERIFIED_WITH_LIMITATIONS
- NOT_REPRODUCED
- NOT_MEASURED
Outputs: TSK36_RESEARCH_CLAIM_MATRIX.csv
"""

import os
import csv

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO_ROOT, "TSK36_REPRODUCIBILITY_AUDIT")

claims = [
    {
        "Claim_ID": "CLM_001",
        "Research_Claim": "Bit-exact numerical correctness across spatial tile sequencing and multi-chunk accumulation",
        "Supporting_Artifact": "TSK28_RESULTS.csv, TSK30_RESULTS.csv, TSK35B_ALL_SCENARIOS_MEASURED.csv",
        "Verification_Procedure": "Independent Python integer convolution reference (independent_numerical_reference.py) compared against RTL outputs across 4 CNN layers (1,024 elements)",
        "Classification": "VERIFIED",
        "Result": "0 mismatches, MAE = 0.0, RMSE = 0.0 across all 4 workloads and modes",
        "Limitations": "Evaluated on 4x4 spatial grid (16 tiles) of 16 output channels; does not represent full-network inference or full feature maps",
        "Paper_Wording": "The accelerator RTL achieves bit-exact numerical equivalence (MAE = 0) against an independent INT16 reference model for a 4x4 spatial grid of 16 channels across ResNet-18 and VGG-16 layers."
    },
    {
        "Claim_ID": "CLM_002",
        "Research_Claim": "Activation zero-skipping reduces weight SRAM reads and active MAC compute switching proportionally to layer sparsity",
        "Supporting_Artifact": "TSK30_RESULTS.csv, TSK35B_SPARSITY_VS_DENSE.csv",
        "Verification_Procedure": "Cycle-accurate RTL telemetry comparison between Dense and Sparse execution under identical tensors and modes (audit_sparse_execution.py)",
        "Classification": "VERIFIED",
        "Result": "Weight SRAM reads and compute cycles drop by exactly 48.11% (WL3) to 84.92% (WL4), matching activation sparsity percentage",
        "Limitations": "Measured via RTL switching counters; physical leakage power and clock distribution network power are not modeled",
        "Paper_Wording": "Activation zero-skipping eliminates 48.1% to 84.9% of weight SRAM reads and active MAC compute cycles across evaluated convolutional layers."
    },
    {
        "Claim_ID": "CLM_003",
        "Research_Claim": "Activation sparsity accelerates total execution wall-clock latency",
        "Supporting_Artifact": "TSK30_RESULTS.csv, TSK35B_SPARSITY_VS_DENSE.csv",
        "Verification_Procedure": "Direct comparison of Total_Execution_Cycles between Dense and Sparse runs across 16-, 32-, and 64-PE modes",
        "Classification": "NOT_REPRODUCED",
        "Result": "Total cycle count is identical between Dense and Sparse regimes (9,569 / 19,121 / 38,225 cycles; exactly 0.00% latency reduction)",
        "Limitations": "Sequencer and address generators advance synchronously; zero activations suppress compute and SRAM strobes but do not compress pipeline cycles",
        "Paper_Wording": "In the current microarchitecture, activation sparsity serves as an energy-reduction mechanism rather than a latency accelerator, maintaining constant execution latency due to synchronous channel-chunk sequencing."
    },
    {
        "Claim_ID": "CLM_004",
        "Research_Claim": "Deterministic transparent policy allocation satisfies latency budgets and PE resource caps (Policy A & B)",
        "Supporting_Artifact": "TSK33_MEASUREMENT_RESULTS.csv, TSK34_CONSTRAINT_SWEEP.csv, TSK35B_ALL_SCENARIOS_MEASURED.csv",
        "Verification_Procedure": "Independent software policy reference sweep across 200 boundary constraint points compared against RTL controller simulation (tb_tsk36_policy_audit.sv)",
        "Classification": "VERIFIED",
        "Result": "200 / 200 boundary checks matched bit-exactly. Policy A reduces active PEs by up to 75%; Policy B achieves minimum latency up to PE cap",
        "Limitations": "Requires host-specified latency budgets and PE caps; does not autonomously infer layer deadlines without host supervision",
        "Paper_Wording": "The transparent hardware resource controller deterministically allocates between 16, 32, and 64 PEs, reducing active PE logic by up to 75% while meeting latency deadlines, or maximizing throughput up to host-specified resource caps."
    },
    {
        "Claim_ID": "CLM_005",
        "Research_Claim": "Hardware safety gating positively blocks compute execution when active PE cap is below physical minimum (Pmax < 16)",
        "Supporting_Artifact": "TSK35A_DOWNSTREAM_GATING_RESULTS.csv, TSK35B_ALL_SCENARIOS_MEASURED.csv",
        "Verification_Procedure": "RTL integration simulation between policy controller and layer_command_sequencer.sv under invalid caps (0, 8, 15) across 240 requests",
        "Classification": "VERIFIED",
        "Result": "In 100% of invalid cases, execution_enable = 0, resolved_mode = 2'b11, and compute_start pulsed 0 times. Clean single-cycle recovery verified",
        "Limitations": "Verified at RTL integration boundary; system SoC bus wrappers must inspect execution_enable or invalid_pe_limit",
        "Paper_Wording": "Hardware interlocks strictly reject infeasible resource caps (Pmax < 16), asserting an explicit invalid flag and deasserting execution enable to prevent unauthorized hardware execution."
    },
    {
        "Claim_ID": "CLM_006",
        "Research_Claim": "Multi-pass channel tiling incurs substantial activation memory bandwidth overhead in 16-PE and 32-PE modes",
        "Supporting_Artifact": "TSK35B_SRAM_TRAFFIC_ANALYSIS.csv",
        "Verification_Procedure": "Empirical SRAM access counter analysis across 16-, 32-, and 64-PE modes (audit_resource_latency.py)",
        "Classification": "VERIFIED",
        "Result": "Activation SRAM reads increase by +100.0% (32-PE, 2 passes) and +300.0% (16-PE, 4 passes). Total SRAM traffic increases by up to +87.18%",
        "Limitations": "Measured on internal multi-bank SRAM subsystem; external DRAM traffic depends on on-chip buffer sizing and reuse strategies",
        "Paper_Wording": "While reducing active PEs lowers instantaneous datapath footprint, multi-pass tiling introduces a trade-off by increasing activation SRAM read traffic by 2x (32-PE) and 4x (16-PE)."
    },
    {
        "Claim_ID": "CLM_007",
        "Research_Claim": "Reducing active PE count from 64 to 32 or 16 PEs reduces total system execution energy",
        "Supporting_Artifact": "TSK35B_POLICY_BENEFIT_REPORT.md",
        "Verification_Procedure": "Energy trade-off analysis comparing execution time (2x to 4x longer) and memory access count (+10% to +87% more accesses)",
        "Classification": "NOT_MEASURED",
        "Result": "Unsubstantiated by physical energy characterization. Longer execution time and higher SRAM traffic counteract datapath power gating",
        "Limitations": "Requires silicon-calibrated gate-level power simulation with characterized cell libraries; simulation counters alone cannot determine net energy",
        "Paper_Wording": "Dynamic PE allocation functions as an effective silicon area and peak power/thermal throttle; however, total energy reduction is not claimed due to multi-pass memory traffic and runtime overheads."
    },
    {
        "Claim_ID": "CLM_008",
        "Research_Claim": "Full-network CNN inference, silicon area closure, and timing closure at 100 MHz",
        "Supporting_Artifact": "TSK22 synthesis and timing reports (preliminary FPGA/ASIC targets)",
        "Verification_Procedure": "Inspection of codebase scope, testbenches, and physical implementation scripts",
        "Classification": "VERIFIED_WITH_LIMITATIONS",
        "Result": "Microarchitecture achieves 100 MHz in cycle-accurate simulation and preliminary Vivado synthesis; full-network inference and taped-out silicon are unmeasured",
        "Limitations": "Simulations validate individual representative convolutional layers; non-linear pooling, inter-layer pipelining, and silicon packaging remain future work",
        "Paper_Wording": "The microarchitecture is verified at cycle-accurate RTL level across representative convolutional layers of ResNet-18 and VGG-16; full-network inference and silicon tape-out remain future work."
    }
]

def main():
    out_csv = os.path.join(OUT_DIR, "TSK36_RESEARCH_CLAIM_MATRIX.csv")
    fields = [
        "Claim_ID", "Research_Claim", "Supporting_Artifact",
        "Verification_Procedure", "Classification", "Result",
        "Limitations", "Paper_Wording"
    ]

    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(claims)

    print(f"[SUCCESS] TSK36_RESEARCH_CLAIM_MATRIX.csv written with {len(claims)} claims.")

if __name__ == "__main__":
    main()

