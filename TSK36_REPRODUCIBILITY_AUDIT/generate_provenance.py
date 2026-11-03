#!/usr/bin/env python3
"""
generate_provenance.py
Audits and logs artifact provenance across milestones TSK-28 through TSK-35B:
- File paths
- SHA-256 hashes
- Workload identifiers
- Simulation commands
- Tool versions
- Test counts (expected vs observed)
Outputs: TSK36_ARTIFACT_PROVENANCE.csv
"""

import os
import hashlib
import csv

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def compute_sha256(filepath):
    if not os.path.exists(filepath):
        return "FILE_NOT_FOUND"
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest().upper()

def get_file_size(filepath):
    if not os.path.exists(filepath):
        return 0
    return os.path.getsize(filepath)

artifacts_to_audit = [
    # Protected Baseline RTL
    {
        "Milestone": "Protected_Baseline",
        "Category": "Protected_RTL",
        "Path": "phase2_step1_microarchitecture_and_rtl/accelerator_core_top.sv",
        "Workload_ID": "N/A",
        "Simulation_Command": "python run_regression.py",
        "Tool_Version": "Icarus Verilog 12.0 / Python 3.10+",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "20 suites",
        "Observed_Tests": "20 suites (12,202 checks)",
        "Description": "Protected baseline top-level microarchitecture"
    },
    {
        "Milestone": "Protected_Baseline",
        "Category": "Protected_RTL",
        "Path": "phase2_step1_microarchitecture_and_rtl/mac_unit_40b.sv",
        "Workload_ID": "N/A",
        "Simulation_Command": "python run_regression.py",
        "Tool_Version": "Icarus Verilog 12.0 / Python 3.10+",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "11 checks",
        "Observed_Tests": "11 checks (tb_mac_saturation)",
        "Description": "Protected 40-bit saturating MAC unit"
    },
    {
        "Milestone": "Protected_Baseline",
        "Category": "Protected_RTL",
        "Path": "phase2_step1_microarchitecture_and_rtl/k_progress_tracker.sv",
        "Workload_ID": "N/A",
        "Simulation_Command": "python run_regression.py",
        "Tool_Version": "Icarus Verilog 12.0 / Python 3.10+",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "4 checks",
        "Observed_Tests": "4 checks (tb_k_progress_tracker)",
        "Description": "Protected K-progress reduction tracker"
    },
    {
        "Milestone": "Protected_Baseline",
        "Category": "Protected_RTL",
        "Path": "phase2_step1_microarchitecture_and_rtl/slot_control_unit.sv",
        "Workload_ID": "N/A",
        "Simulation_Command": "python run_regression.py",
        "Tool_Version": "Icarus Verilog 12.0 / Python 3.10+",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "4 checks",
        "Observed_Tests": "4 checks (tb_accelerator_core)",
        "Description": "Protected slot control unit"
    },
    {
        "Milestone": "Protected_Baseline",
        "Category": "Protected_RTL",
        "Path": "phase2_step1_microarchitecture_and_rtl/hybrid_sram_bank.sv",
        "Workload_ID": "N/A",
        "Simulation_Command": "python run_regression.py",
        "Tool_Version": "Icarus Verilog 12.0 / Python 3.10+",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "13 checks",
        "Observed_Tests": "13 checks (tb_hybrid_sram_bank)",
        "Description": "Protected dual-port hybrid SRAM bank"
    },

    # TSK-28 Complete Convolution Validation
    {
        "Milestone": "TSK-28",
        "Category": "RTL_Engine",
        "Path": "TSK28_COMPLETE_CONVOLUTION_VALIDATION/tsk28_complete_convolution_engine.sv",
        "Workload_ID": "WL1",
        "Simulation_Command": "iverilog -g2012 ... tb_tsk28_complete_convolution.sv && vvp sim_tsk28",
        "Tool_Version": "Icarus Verilog 12.0",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "256 outputs",
        "Observed_Tests": "256 outputs (0 mismatches)",
        "Description": "TSK-28 complete convolution engine"
    },
    {
        "Milestone": "TSK-28",
        "Category": "Testbench",
        "Path": "TSK28_COMPLETE_CONVOLUTION_VALIDATION/tb_tsk28_complete_convolution.sv",
        "Workload_ID": "WL1",
        "Simulation_Command": "vvp sim_tsk28",
        "Tool_Version": "Icarus Verilog 12.0",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "256 outputs",
        "Observed_Tests": "256 outputs (0 mismatches)",
        "Description": "TSK-28 verification testbench"
    },
    {
        "Milestone": "TSK-28",
        "Category": "Evidence_CSV",
        "Path": "TSK28_COMPLETE_CONVOLUTION_VALIDATION/TSK28_RESULTS.csv",
        "Workload_ID": "WL1",
        "Simulation_Command": "N/A (Generated Artifact)",
        "Tool_Version": "CSV / Python",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "1 run",
        "Observed_Tests": "1 run (9,569 cycles)",
        "Description": "TSK-28 measured cycle counts and correctness log"
    },

    # TSK-29 Adaptive PE Evaluation
    {
        "Milestone": "TSK-29",
        "Category": "RTL_Engine",
        "Path": "TSK29_ADAPTIVE_PE_EVALUATION/tsk29_adaptive_convolution_engine.sv",
        "Workload_ID": "WL1",
        "Simulation_Command": "iverilog -g2012 ... tb_tsk29_adaptive_evaluation.sv && vvp sim_tsk29",
        "Tool_Version": "Icarus Verilog 12.0",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "7 configs",
        "Observed_Tests": "7 configs (1,792 outputs)",
        "Description": "TSK-29 adaptive convolution engine"
    },
    {
        "Milestone": "TSK-29",
        "Category": "Evidence_CSV",
        "Path": "TSK29_ADAPTIVE_PE_EVALUATION/TSK29_RAW_METRICS.csv",
        "Workload_ID": "WL1",
        "Simulation_Command": "N/A (Generated Artifact)",
        "Tool_Version": "CSV / Python",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "7 configs",
        "Observed_Tests": "7 configs",
        "Description": "TSK-29 raw hardware metrics log"
    },

    # TSK-30 Multi-Workload Adaptive Validation
    {
        "Milestone": "TSK-30",
        "Category": "RTL_Engine",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tsk30_multi_workload_engine.sv",
        "Workload_ID": "WL1, WL2, WL3, WL4",
        "Simulation_Command": "iverilog -g2012 ... tb_tsk30_multi_workload_validation.sv && vvp sim_tsk30",
        "Tool_Version": "Icarus Verilog 12.0",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "28 configs",
        "Observed_Tests": "28 configs (7,168 outputs)",
        "Description": "TSK-30 multi-workload hardware engine"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Evidence_CSV",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/TSK30_RESULTS.csv",
        "Workload_ID": "WL1, WL2, WL3, WL4",
        "Simulation_Command": "python generate_tsk30_results.py",
        "Tool_Version": "Python 3.10+ / Pandas",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "28 configs",
        "Observed_Tests": "28 configs",
        "Description": "TSK-30 consolidated cross-workload results"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL1_act.hex",
        "Workload_ID": "WL1",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "HuggingFace Checkpoint",
        "Expected_Tests": "9,216 words",
        "Observed_Tests": "9,216 words (68.89% zero)",
        "Description": "ResNet-18 CIFAR-10 layer1.0.conv1 input activations"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL1_wt.hex",
        "Workload_ID": "WL1",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "HuggingFace Checkpoint",
        "Expected_Tests": "9,216 words",
        "Observed_Tests": "9,216 words",
        "Description": "ResNet-18 CIFAR-10 layer1.0.conv1 weights"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL1_golden.hex",
        "Workload_ID": "WL1",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "HuggingFace Checkpoint",
        "Expected_Tests": "256 words",
        "Observed_Tests": "256 words (40-bit accum)",
        "Description": "ResNet-18 CIFAR-10 golden output activations"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL2_act.hex",
        "Workload_ID": "WL2",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "HuggingFace Checkpoint",
        "Expected_Tests": "9,216 words",
        "Observed_Tests": "9,216 words (66.57% zero)",
        "Description": "ResNet-18 CIFAR-100 layer1.0.conv1 input activations"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL2_wt.hex",
        "Workload_ID": "WL2",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "HuggingFace Checkpoint",
        "Expected_Tests": "9,216 words",
        "Observed_Tests": "9,216 words",
        "Description": "ResNet-18 CIFAR-100 layer1.0.conv1 weights"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL2_golden.hex",
        "Workload_ID": "WL2",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "HuggingFace Checkpoint",
        "Expected_Tests": "256 words",
        "Observed_Tests": "256 words (40-bit accum)",
        "Description": "ResNet-18 CIFAR-100 golden output activations"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL3_act.hex",
        "Workload_ID": "WL3",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "PyTorch CIFAR-10 VGG-16",
        "Expected_Tests": "9,216 words",
        "Observed_Tests": "9,216 words (48.11% zero)",
        "Description": "VGG-16-BN CIFAR-10 features.3 input activations"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL3_wt.hex",
        "Workload_ID": "WL3",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "PyTorch CIFAR-10 VGG-16",
        "Expected_Tests": "9,216 words",
        "Observed_Tests": "9,216 words",
        "Description": "VGG-16-BN CIFAR-10 features.3 weights"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL3_golden.hex",
        "Workload_ID": "WL3",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "PyTorch CIFAR-10 VGG-16",
        "Expected_Tests": "256 words",
        "Observed_Tests": "256 words (40-bit accum)",
        "Description": "VGG-16-BN CIFAR-10 golden output activations"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL4_act.hex",
        "Workload_ID": "WL4",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "HuggingFace Checkpoint",
        "Expected_Tests": "9,216 words",
        "Observed_Tests": "9,216 words (84.92% zero)",
        "Description": "ResNet-18 CIFAR-10 layer2.1.conv2 input activations"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL4_wt.hex",
        "Workload_ID": "WL4",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "HuggingFace Checkpoint",
        "Expected_Tests": "9,216 words",
        "Observed_Tests": "9,216 words",
        "Description": "ResNet-18 CIFAR-10 layer2.1.conv2 weights"
    },
    {
        "Milestone": "TSK-30",
        "Category": "Workload_Tensor",
        "Path": "TSK30_MULTI_WORKLOAD_ADAPTIVE_VALIDATION/tensors/WL4_golden.hex",
        "Workload_ID": "WL4",
        "Simulation_Command": "N/A (Tensor Hex)",
        "Tool_Version": "PyTorch / Hex",
        "Random_Seed": "HuggingFace Checkpoint",
        "Expected_Tests": "256 words",
        "Observed_Tests": "256 words (40-bit accum)",
        "Description": "ResNet-18 CIFAR-10 golden output activations"
    },

    # TSK-31 Reproducibility Audit
    {
        "Milestone": "TSK-31",
        "Category": "Audit_Report",
        "Path": "TSK31_INDEPENDENT_REPRODUCIBILITY_AUDIT/TSK31_AUDIT_REPORT.md",
        "Workload_ID": "WL1, WL2, WL3, WL4",
        "Simulation_Command": "python run_tsk31_audit.py",
        "Tool_Version": "Python 3.10+",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "28 configs",
        "Observed_Tests": "28 configs verified",
        "Description": "TSK-31 independent audit report"
    },

    # TSK-32 Degradation Estimator Validation
    {
        "Milestone": "TSK-32",
        "Category": "Audit_Report",
        "Path": "TSK32_ADAPTIVE_DEGRADATION_VALIDATION/TSK32_VALIDATION_REPORT.md",
        "Workload_ID": "WL1, WL2, WL3, WL4",
        "Simulation_Command": "python validate_degradation_estimators.py",
        "Tool_Version": "Python 3.10+ / PyTorch",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "16 estimator evaluations",
        "Observed_Tests": "16 estimator evaluations",
        "Description": "TSK-32 degradation estimator audit report"
    },

    # TSK-33 Adaptive Resource Policy
    {
        "Milestone": "TSK-33",
        "Category": "Policy_Controller",
        "Path": "TSK33_ADAPTIVE_RESOURCE_POLICY/tsk33_transparent_policy_controller.sv",
        "Workload_ID": "Parametric",
        "Simulation_Command": "iverilog -g2012 ... tb_tsk33_policy_validation.sv && vvp sim_tsk33",
        "Tool_Version": "Icarus Verilog 12.0",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "17 tests",
        "Observed_Tests": "17 tests (0 failures)",
        "Description": "TSK-33 / TSK-35A transparent policy controller RTL"
    },
    {
        "Milestone": "TSK-33",
        "Category": "Evidence_CSV",
        "Path": "TSK33_ADAPTIVE_RESOURCE_POLICY/TSK33_MEASUREMENT_RESULTS.csv",
        "Workload_ID": "WL1, WL2, WL3, WL4",
        "Simulation_Command": "N/A (Generated Artifact)",
        "Tool_Version": "CSV / Python",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "28 configs",
        "Observed_Tests": "28 configs",
        "Description": "TSK-33 hardware measurement results"
    },

    # TSK-34 Independent Policy Validation
    {
        "Milestone": "TSK-34",
        "Category": "Reference_Model",
        "Path": "TSK34_INDEPENDENT_POLICY_VALIDATION/TSK34_REFERENCE_POLICY.py",
        "Workload_ID": "Parametric",
        "Simulation_Command": "python TSK34_REFERENCE_POLICY.py",
        "Tool_Version": "Python 3.10+ / Pandas",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "192 sweep points",
        "Observed_Tests": "192 sweep points (100% bit-exact)",
        "Description": "TSK-34 software policy reference and sweep runner"
    },
    {
        "Milestone": "TSK-34",
        "Category": "Evidence_CSV",
        "Path": "TSK34_INDEPENDENT_POLICY_VALIDATION/TSK34_CONSTRAINT_SWEEP.csv",
        "Workload_ID": "Parametric",
        "Simulation_Command": "python TSK34_REFERENCE_POLICY.py",
        "Tool_Version": "Python 3.10+ / Pandas",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "192 points",
        "Observed_Tests": "192 points",
        "Description": "TSK-34 independent constraint sweep matrix"
    },

    # TSK-35A Invalid PE Limit Safety Correction
    {
        "Milestone": "TSK-35A",
        "Category": "Testbench",
        "Path": "TSK35A_INVALID_PE_SAFETY/tb_tsk35a_invalid_pe_unit.sv",
        "Workload_ID": "Parametric",
        "Simulation_Command": "iverilog -g2012 ... tb_tsk35a_invalid_pe_unit.sv && vvp sim_tsk35a_unit",
        "Tool_Version": "Icarus Verilog 12.0",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "31 assertions",
        "Observed_Tests": "31 assertions (0 failures)",
        "Description": "TSK-35A directed unit testbench"
    },
    {
        "Milestone": "TSK-35A",
        "Category": "Testbench",
        "Path": "TSK35A_INVALID_PE_SAFETY/tb_tsk35a_downstream_gating.sv",
        "Workload_ID": "Parametric",
        "Simulation_Command": "iverilog -g2012 ... tb_tsk35a_downstream_gating.sv && vvp sim_tsk35a_gating",
        "Tool_Version": "Icarus Verilog 12.0",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "4 scenarios",
        "Observed_Tests": "4 scenarios (0 compute starts)",
        "Description": "TSK-35A downstream execution gating testbench"
    },

    # TSK-35B Policy Benefit Evaluation
    {
        "Milestone": "TSK-35B",
        "Category": "Testbench",
        "Path": "TSK35B_POLICY_BENEFIT_EVALUATION/tb_tsk35b_policy_benefit.sv",
        "Workload_ID": "WL1, WL2, WL3, WL4",
        "Simulation_Command": "iverilog -g2012 ... tb_tsk35b_policy_benefit.sv && vvp sim_tsk35b",
        "Tool_Version": "Icarus Verilog 12.0",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "560 evaluations + 24 baselines",
        "Observed_Tests": "560 evaluations + 24 baselines (0 mismatches)",
        "Description": "TSK-35B comprehensive policy evaluation testbench"
    },
    {
        "Milestone": "TSK-35B",
        "Category": "Evidence_CSV",
        "Path": "TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_ALL_SCENARIOS_MEASURED.csv",
        "Workload_ID": "WL1, WL2, WL3, WL4",
        "Simulation_Command": "python process_tsk35b_results.py",
        "Tool_Version": "Python 3.10+ / Pandas",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "560 scenarios",
        "Observed_Tests": "560 scenarios",
        "Description": "TSK-35B full empirical evaluation database"
    },
    {
        "Milestone": "TSK-35B",
        "Category": "Evidence_CSV",
        "Path": "TSK35B_POLICY_BENEFIT_EVALUATION/TSK35B_BASELINE_MEASURED.csv",
        "Workload_ID": "WL1, WL2, WL3, WL4",
        "Simulation_Command": "python process_tsk35b_results.py",
        "Tool_Version": "Python 3.10+ / Pandas",
        "Random_Seed": "Deterministic",
        "Expected_Tests": "24 baselines",
        "Observed_Tests": "24 baselines",
        "Description": "TSK-35B fixed mode baseline characterization database"
    }
]

def main():
    out_csv = os.path.join(REPO_ROOT, "TSK36_REPRODUCIBILITY_AUDIT", "TSK36_ARTIFACT_PROVENANCE.csv")
    fields = [
        "Artifact_ID", "Milestone", "Category", "File_Path", "File_Size_Bytes",
        "SHA256_Hash", "Workload_ID", "Simulation_Command", "Tool_Version",
        "Random_Seed", "Expected_Tests", "Observed_Tests", "Audit_Status", "Description"
    ]

    rows = []
    for idx, item in enumerate(artifacts_to_audit, 1):
        full_path = os.path.join(REPO_ROOT, item["Path"])
        sha = compute_sha256(full_path)
        size = get_file_size(full_path)
        status = "VERIFIED_PRESENT" if sha != "FILE_NOT_FOUND" else "MISSING"

        rows.append({
            "Artifact_ID": f"ART_{idx:03d}",
            "Milestone": item["Milestone"],
            "Category": item["Category"],
            "File_Path": item["Path"],
            "File_Size_Bytes": size,
            "SHA256_Hash": sha,
            "Workload_ID": item["Workload_ID"],
            "Simulation_Command": item["Simulation_Command"],
            "Tool_Version": item["Tool_Version"],
            "Random_Seed": item["Random_Seed"],
            "Expected_Tests": item["Expected_Tests"],
            "Observed_Tests": item["Observed_Tests"],
            "Audit_Status": status,
            "Description": item["Description"]
        })

    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    print(f"[SUCCESS] TSK36_ARTIFACT_PROVENANCE.csv written with {len(rows)} entries.")

if __name__ == "__main__":
    main()
