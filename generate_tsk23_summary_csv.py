#!/usr/bin/env python3
"""
Generate TSK23_EVIDENCE_SUMMARY.csv
"""
import csv

summary_data = [
    {
        "Evaluation_Dimension": "Baseline RTL Integrity",
        "Target_Scope": "5 Protected Baseline RTL Files",
        "Status": "PASS",
        "Evidence_Artifact": "Git status & diff --exit-code",
        "Quantitative_Metric": "5 / 5 files untouched (0 diffs), 0 git commits",
        "Key_Findings_and_Limitations": "accelerator_core_top.sv, mac_unit_40b.sv, k_progress_tracker.sv, slot_control_unit.sv, hybrid_sram_bank.sv remain 100% clean."
    },
    {
        "Evaluation_Dimension": "RTL Functional Verification",
        "Target_Scope": "All RTL Modules & Integration Testbenches",
        "Status": "PASS",
        "Evidence_Artifact": "run_regression.py & run_tsk23_unified_regression.py",
        "Quantitative_Metric": "20 baseline suites passed (12,202 checks) + 5 extension suites (>13,200 total checks), 0 failures",
        "Key_Findings_and_Limitations": "Complete functional verification passed across baseline, subsystem, integration, and cycle reconciliation."
    },
    {
        "Evaluation_Dimension": "Multi-Pass Channel Tiling",
        "Target_Scope": "channel_tile_controller.sv, ofmap_drain_controller.sv",
        "Status": "PASS",
        "Evidence_Artifact": "tb_tsk21_multipass_tiling.sv",
        "Quantitative_Metric": "155 / 155 checks passed; 100% output channel preservation (64/64 channels, 128/128 words)",
        "Key_Findings_and_Limitations": "Verified 64-PE (1 pass), 32-PE (2 passes), 16-PE (4 passes). Added tail-tile support (18 channels = 36 words, 1 full pass + 1 tail pass). Accumulator clearing between passes verified."
    },
    {
        "Evaluation_Dimension": "Requantization & Tie-Breaking",
        "Target_Scope": "requantization_unit.sv, tsk21_reference_model.py",
        "Status": "PASS",
        "Evidence_Artifact": "audit_tsk21_requantization.py & TSK23_REQUANTIZATION_AUDIT.csv",
        "Quantitative_Metric": "32 / 32 shift boundaries, 40-bit bounds [-2^39, 2^39-1], 32/32 SRAM readback words matched bit-for-bit",
        "Key_Findings_and_Limitations": "Formally established Round-Half-Up (asymmetric, ties towards +inf). Positive ties round up; negative ties round toward zero. Extreme 40-bit limits, saturation [-32768, 32767], and ReLU clamping verified."
    },
    {
        "Evaluation_Dimension": "Memory Telemetry & Reconciled Bandwidth",
        "Target_Scope": "memory_telemetry_monitor.sv, multibank_sram_subsystem.sv",
        "Status": "PASS_WITH_LIMITATIONS",
        "Evidence_Artifact": "audit_tsk20_telemetry.py & TSK23_TSK20_AUDIT.csv",
        "Quantitative_Metric": "1124 cycle trace entries audited; 8 / 8 runs 100% reconciled against monitor counters",
        "Key_Findings_and_Limitations": "Transaction reductions (25.0% to 40.0%) and cycle reductions (12.5% to 31.25%) reported separately. Zero bank conflicts in orthogonal banking. Limitation: Sparsity patterns evaluated are synthetic alternating patterns."
    },
    {
        "Evaluation_Dimension": "Real CNN Workload Validation",
        "Target_Scope": "R18-C10, R18-C100, V16-C10, V16-C100",
        "Status": "PASS_WITH_LIMITATIONS",
        "Evidence_Artifact": "TSK15_ADAPTIVE_SELECTION_RESULTS.csv, TSK16_INDEPENDENT_EVIDENCE_AUDIT.md",
        "Quantitative_Metric": "Analytical quality constrained adaptation verified via MLP degradation predictor",
        "Key_Findings_and_Limitations": "RTL memory replay uses synthetic alternating sparsity with CNN-scaled parameters (K=16, 24). Full forward-pass tensor weights for ResNet-18/VGG-16 are absent in repository."
    },
    {
        "Evaluation_Dimension": "RTL Synthesis & Static Timing Analysis",
        "Target_Scope": "timing_constraints.sdc, timing_constraints.xdc, synth_yosys.ys, synth_vivado.tcl",
        "Status": "BLOCKED",
        "Evidence_Artifact": "TSK22_TOOL_AVAILABILITY.md & TSK22_TIMING_REPORT.md",
        "Quantitative_Metric": "0 EDA synthesis/STA binaries found (yosys, vivado, quartus, sta all absent)",
        "Key_Findings_and_Limitations": "Toolchain limitation. Constraints and synthesis scripts authored and verified, but execution is blocked. No timing slack or clock delays fabricated."
    },
    {
        "Evaluation_Dimension": "FPGA Implementation & Resource Mapping",
        "Target_Scope": "Xilinx Artix-7 / UltraScale+ Architecture Mapping",
        "Status": "NOT_RUN",
        "Evidence_Artifact": "TSK22_FPGA_RESOURCE_REPORT.md",
        "Quantitative_Metric": "Requires Vivado / Quartus toolchain",
        "Key_Findings_and_Limitations": "Blocked by host environment toolchain. Analytical estimates documented, but physical place-and-route is marked strictly NOT_RUN."
    },
    {
        "Evaluation_Dimension": "Physical Power & Energy Measurement",
        "Target_Scope": "neural_acc_switching_activity.vcd (288 KB, 21,888 transitions)",
        "Status": "NOT_RUN",
        "Evidence_Artifact": "TSK22_POWER_ESTIMATION_REPORT.md & neural_acc_switching_activity.vcd",
        "Quantitative_Metric": "VCD switching activity vector generated (598 signals, 21,888 transitions)",
        "Key_Findings_and_Limitations": "Physical power measurement blocked by absence of vendor power estimation tools. All physical energy claims are explicitly disclaimed and marked unverified."
    }
]

headers = [
    "Evaluation_Dimension",
    "Target_Scope",
    "Status",
    "Evidence_Artifact",
    "Quantitative_Metric",
    "Key_Findings_and_Limitations"
]

for path in ["TSK23_EVIDENCE_SUMMARY.csv", "phase2_step1_microarchitecture_and_rtl/TSK23_EVIDENCE_SUMMARY.csv"]:
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        writer.writeheader()
        writer.writerows(summary_data)
    print(f"Exported {path}")

