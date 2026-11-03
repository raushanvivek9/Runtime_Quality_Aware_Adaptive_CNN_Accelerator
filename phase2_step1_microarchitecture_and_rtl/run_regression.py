#!/usr/bin/env python3
import subprocess
import sys
import re
import os

suites = [
    ("tb_accelerator_core", "iverilog -g2012 -o /tmp/sim_b1 accelerator_core_top.sv mac_unit_40b.sv hybrid_sram_bank.sv slot_control_unit.sv k_progress_tracker.sv tb_accelerator_core.sv && vvp /tmp/sim_b1; rm -f /tmp/sim_b1"),
    ("tb_mac_saturation", "iverilog -g2012 -o /tmp/sim_b2 mac_unit_40b.sv tb_mac_saturation.sv && vvp /tmp/sim_b2; rm -f /tmp/sim_b2"),
    ("tb_k_progress_tracker", "iverilog -g2012 -o /tmp/sim_b3 k_progress_tracker.sv tb_k_progress_tracker.sv && vvp /tmp/sim_b3; rm -f /tmp/sim_b3"),
    ("tb_hybrid_sram_bank", "iverilog -g2012 -o /tmp/sim_b4 hybrid_sram_bank.sv tb_hybrid_sram_bank.sv && vvp /tmp/sim_b4; rm -f /tmp/sim_b4"),
    ("tb_drain_backpressure", "iverilog -g2012 -o /tmp/sim_b5 slot_control_unit.sv tb_drain_backpressure.sv && vvp /tmp/sim_b5; rm -f /tmp/sim_b5"),
    ("tb_acceptance_integrated", "iverilog -g2012 -o /tmp/sim_b6 accelerator_core_top.sv mac_unit_40b.sv hybrid_sram_bank.sv slot_control_unit.sv k_progress_tracker.sv tb_acceptance_integrated.sv && vvp /tmp/sim_b6; rm -f /tmp/sim_b6"),
    ("tb_pe_array_40b", "iverilog -g2012 -o /tmp/sim_s1 mac_unit_40b.sv pe_array_40b.sv tb_pe_array_40b.sv && vvp /tmp/sim_s1; rm -f /tmp/sim_s1"),
    ("tb_adaptive_pe_controller", "iverilog -g2012 -o /tmp/sim_s2 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv tb_adaptive_pe_controller.sv && vvp /tmp/sim_s2; rm -f /tmp/sim_s2"),
    ("tb_multibank_sram_subsystem", "iverilog -g2012 -o /tmp/sim_s3 hybrid_sram_bank.sv multibank_sram_subsystem.sv tb_multibank_sram_subsystem.sv && vvp /tmp/sim_s3; rm -f /tmp/sim_s3"),
    ("tb_ping_pong_buffer_controller", "iverilog -g2012 -o /tmp/sim_s4 ping_pong_buffer_controller.sv tb_ping_pong_buffer_controller.sv && vvp /tmp/sim_s4; rm -f /tmp/sim_s4"),
    ("tb_layer_command_sequencer", "iverilog -g2012 -o /tmp/sim_s5 layer_command_sequencer.sv tb_layer_command_sequencer.sv && vvp /tmp/sim_s5; rm -f /tmp/sim_s5"),
    ("tb_dma_controller", "iverilog -g2012 -o /tmp/sim_s6 dma_controller.sv tb_dma_controller.sv && vvp /tmp/sim_s6; rm -f /tmp/sim_s6"),
    ("tb_ofmap_drain_controller", "iverilog -g2012 -o /tmp/sim_s11 ofmap_drain_controller.sv tb_ofmap_drain_controller.sv && vvp /tmp/sim_s11; rm -f /tmp/sim_s11"),
    ("tb_neural_acc_integrated_top", "iverilog -g2012 -o /tmp/sim_s7 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv ping_pong_buffer_controller.sv hybrid_sram_bank.sv multibank_sram_subsystem.sv dma_controller.sv layer_command_sequencer.sv dma_to_sram_write_adapter.sv datapath_compute_feeder.sv ofmap_drain_controller.sv neural_acc_integrated_top.sv tb_neural_acc_integrated_top.sv && vvp /tmp/sim_s7; rm -f /tmp/sim_s7"),
    ("tb_workload_validation", "iverilog -g2012 -o /tmp/sim_s8 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv ping_pong_buffer_controller.sv hybrid_sram_bank.sv multibank_sram_subsystem.sv dma_controller.sv layer_command_sequencer.sv dma_to_sram_write_adapter.sv datapath_compute_feeder.sv ofmap_drain_controller.sv neural_acc_integrated_top.sv tb_workload_validation.sv && vvp /tmp/sim_s8; rm -f /tmp/sim_s8"),
    ("tb_parallel_pe_operand_delivery", "iverilog -g2012 -o /tmp/sim_s9 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv ping_pong_buffer_controller.sv hybrid_sram_bank.sv multibank_sram_subsystem.sv dma_controller.sv layer_command_sequencer.sv dma_to_sram_write_adapter.sv datapath_compute_feeder.sv ofmap_drain_controller.sv neural_acc_integrated_top.sv tb_parallel_pe_operand_delivery.sv && vvp /tmp/sim_s9; rm -f /tmp/sim_s9"),
    ("tb_tsk10_cnn_workload", "iverilog -g2012 -o /tmp/sim_s10 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv ping_pong_buffer_controller.sv hybrid_sram_bank.sv multibank_sram_subsystem.sv dma_controller.sv layer_command_sequencer.sv dma_to_sram_write_adapter.sv datapath_compute_feeder.sv ofmap_drain_controller.sv neural_acc_integrated_top.sv tb_tsk10_cnn_workload.sv && vvp /tmp/sim_s10; rm -f /tmp/sim_s10"),
    ("tb_tsk11_ofmap_integration", "iverilog -g2012 -o /tmp/sim_s12 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv ping_pong_buffer_controller.sv hybrid_sram_bank.sv multibank_sram_subsystem.sv dma_controller.sv layer_command_sequencer.sv dma_to_sram_write_adapter.sv datapath_compute_feeder.sv ofmap_drain_controller.sv neural_acc_integrated_top.sv tb_tsk11_ofmap_integration.sv && vvp /tmp/sim_s12; rm -f /tmp/sim_s12"),
    ("tb_tsk12_adaptive_experiment", "iverilog -g2012 -o /tmp/sim_s13 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv ping_pong_buffer_controller.sv hybrid_sram_bank.sv multibank_sram_subsystem.sv dma_controller.sv layer_command_sequencer.sv dma_to_sram_write_adapter.sv datapath_compute_feeder.sv ofmap_drain_controller.sv neural_acc_integrated_top.sv tb_tsk12_adaptive_experiment.sv && vvp /tmp/sim_s13; rm -f /tmp/sim_s13"),
    ("tb_tsk18_sparse_feeder", "iverilog -g2012 -o /tmp/sim_s14 mac_unit_40b.sv pe_array_40b.sv adaptive_pe_controller.sv ping_pong_buffer_controller.sv hybrid_sram_bank.sv multibank_sram_subsystem.sv dma_controller.sv layer_command_sequencer.sv dma_to_sram_write_adapter.sv datapath_compute_feeder.sv ofmap_drain_controller.sv neural_acc_integrated_top.sv tb_tsk18_sparse_feeder.sv && vvp /tmp/sim_s14; rm -f /tmp/sim_s14")
]

print(f"{'#':<3} | {'Testbench Suite':<32} | {'Category':<12} | {'Checks':<8} | {'Status':<6} | {'Summary Output'}")
print("-" * 110)

total_checks = 0
total_passed = 0
total_failed = 0

passed_suites = []
failed_suites = []

for idx, (name, cmd) in enumerate(suites, 1):
    category = "Baseline" if idx <= 6 else ("Subsystem" if idx <= 13 else "Integration")
    
    # Deconstruct compound command into compilation, simulation, and cleanup to explicitly verify exit statuses
    if "&&" in cmd:
        compile_cmd = cmd.split("&&")[0].strip()
        rest = cmd.split("&&")[1].strip()
        if ";" in rest:
            sim_cmd = rest.split(";")[0].strip()
            clean_cmd = rest.split(";")[1].strip()
        else:
            sim_cmd = rest
            clean_cmd = ""
    else:
        compile_cmd = cmd
        sim_cmd = None
        clean_cmd = ""

    # 1. Compilation Stage
    p_comp = subprocess.run(compile_cmd, shell=True, capture_output=True, text=True)
    comp_rc = p_comp.returncode
    comp_err = p_comp.stderr.strip()
    comp_out = p_comp.stdout.strip()

    status = "PASS"
    out = ""
    summary = ""

    if comp_rc != 0:
        status = "FAIL"
        failed_suites.append((name, f"Compilation failed (exit code {comp_rc})"))
        summary = f"[ERROR] Compilation failed: {comp_err.splitlines()[-1] if comp_err else 'Unknown error'}"
        if clean_cmd:
            subprocess.run(clean_cmd, shell=True, capture_output=True, text=True)
    else:
        # 2. Simulation Stage
        if sim_cmd:
            p_sim = subprocess.run(sim_cmd, shell=True, capture_output=True, text=True)
            sim_rc = p_sim.returncode
            out = p_sim.stdout.strip()
            err = p_sim.stderr.strip()
            if clean_cmd:
                subprocess.run(clean_cmd, shell=True, capture_output=True, text=True)
        else:
            sim_rc = 0
            out = comp_out
            err = comp_err

        # Check simulation status and output content
        if sim_rc != 0:
            status = "FAIL"
            failed_suites.append((name, f"Simulation execution failed (exit code {sim_rc})"))
            summary_lines = [l for l in out.splitlines() if any(k in l for k in ["Summary", "SUMMARY", "SUCCESS", "RESULT", "ERROR", "FAIL"])]
            summary = summary_lines[-1] if summary_lines else (err.splitlines()[-1] if err else f"Simulation exit {sim_rc}")
        elif "FAIL" in out or "error" in err.lower():
            status = "FAIL"
            failed_suites.append((name, "Test assertions reported failure"))
            summary_lines = [l for l in out.splitlines() if any(k in l for k in ["Summary", "SUMMARY", "SUCCESS", "RESULT", "ERROR", "FAIL"])]
            summary = summary_lines[-1] if summary_lines else "Checks failed"
        else:
            status = "PASS"
            passed_suites.append(name)
            summary_lines = [l for l in out.splitlines() if any(k in l for k in ["Summary", "SUMMARY", "SUCCESS", "RESULT"])]
            summary = summary_lines[-1] if summary_lines else (out.splitlines()[-1] if out.splitlines() else "Clean")

    # Parse check count from Summary line
    m_tot = re.search(r"(?:Total(?:\s+Checks)?\s*[:=]\s*)(\d+)", out, re.IGNORECASE)
    if not m_tot:
        m_tot = re.search(r"(?:Summary|SUMMARY)[^\n]*?(?:Total\s*=\s*|:\s*)(\d+)\s*(?:Passed)?", out)
    if not m_tot:
        m_tot = re.search(r"(\d+)\s+Passed", out)
    if not m_tot:
        m_tot = re.search(r"Passed:\s*(\d+)", out)

    if m_tot:
        checks = int(m_tot.group(1))
    else:
        checks = 0

    total_checks += checks
    if status == "PASS":
        total_passed += checks
    else:
        total_failed += checks

    print(f"{idx:<3} | {name:<32} | {category:<12} | {checks:<8} | {status:<6} | {summary}")

print("-" * 110)
print(f"GRAND TOTAL ACROSS ALL {len(suites)} SUITES: {total_checks} Checks Evaluated | {total_passed} Passed | {total_failed} Failed | {'ALL PASS' if not failed_suites else 'FAIL'}")
print("=" * 110)
print("REGRESSION EXECUTION SUMMARY:")
print(f"  Total Testbenches : {len(suites)}")
print(f"  Passed Testbenches: {len(passed_suites)}")
print(f"  Failed Testbenches: {len(failed_suites)}")
print(f"  Checks Evaluated  : {total_checks}")
print(f"  Checks Passed     : {total_passed}")
print(f"  Checks Failed     : {total_failed}")

if failed_suites:
    print("\nFAILED TESTBENCHES DETAIL:")
    for f_name, f_reason in failed_suites:
        print(f"  [X] {f_name:<32}: {f_reason}")
    print("\nFINAL STATUS: REGRESSION FAILED (Exit Code 1)")
    print("=" * 110)
    sys.exit(1)
else:
    print("\nFINAL STATUS: REGRESSION PASSED (Exit Code 0)")
    print("=" * 110)
    sys.exit(0)
