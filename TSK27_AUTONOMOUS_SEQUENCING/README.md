# TSK-27A: Autonomous Spatial Sequencing & Accumulator Preservation

This directory contains the RTL design, verification testbench, empirical results, architectural specifications, and engineering audits for milestone **TSK-27A** and **TSK-27B** of the **Neural_Acc** accelerator project.

---

## Deliverables Directory Map

```
TSK27_AUTONOMOUS_SEQUENCING/
├── README.md                           # Directory guide and execution instructions
├── IMPLEMENTATION_PLAN.md              # Engineering roadmap and safety constraints
├── ARCHITECTURE.md                     # Microarchitecture specification and FSM diagrams
├── spatial_tile_sequencer.sv           # Synthesizable autonomous spatial tile sequencer
├── tb_spatial_tile_sequencer.sv        # Exhaustive verification testbench (12 scenarios)
├── SEQUENCING_RESULTS.csv              # Empirical testbench results (30 checks evaluated)
├── ACCUMULATOR_PRESERVATION_AUDIT.md   # RTL audit of accumulator clearing & multi-pass proposal
├── INTEGRATION_STATUS.md               # Hardware integration roadmap and interface mapping
├── LIMITATIONS.md                      # Technical limitations and boundary analysis
└── FINAL_AUDIT_REPORT.md               # Comprehensive milestone engineering report
```

---

## Reproducible Simulation Instructions

To compile and execute the standalone spatial tile sequencer testbench in WSL2 Linux:

```bash
cd /mnt/e/MTech/LanChain/MTP/TSK27_AUTONOMOUS_SEQUENCING
iverilog -g2012 -o sim_seq tb_spatial_tile_sequencer.sv spatial_tile_sequencer.sv
vvp ./sim_seq
```

Expected output:
```
==================================================================
 TSK-27A SEQUENCER TEST SUMMARY: 30 Passed, 0 Failed
==================================================================
[SUCCESS] All TSK-27A Spatial Tile Sequencer Tests PASSED!
```
The testbench automatically outputs [`SEQUENCING_RESULTS.csv`](file:///e:/MTech/LanChain/MTP/TSK27_AUTONOMOUS_SEQUENCING/SEQUENCING_RESULTS.csv).

