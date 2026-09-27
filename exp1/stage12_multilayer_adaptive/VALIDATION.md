# Stage 12 Validation

Python reference: PASS
Dense output: PASS
Adaptive policy: PASS

Case A:
  layer1: output=PASS, selected_pe=64, useful_macs=20368, skipped_macs=7280, analytical_cycles=319, rtl_cycles=319
  layer2: output=PASS, selected_pe=64, useful_macs=245888, skipped_macs=49024, analytical_cycles=3842, rtl_cycles=3842
  layer3: output=PASS, selected_pe=64, useful_macs=247808, skipped_macs=47104, analytical_cycles=3872, rtl_cycles=3872

Case B:
  layer1: output=PASS, selected_pe=32, useful_macs=18112, skipped_macs=9536, analytical_cycles=566, rtl_cycles=566
  layer2: output=PASS, selected_pe=64, useful_macs=242144, skipped_macs=52768, analytical_cycles=3784, rtl_cycles=3784
  layer3: output=PASS, selected_pe=64, useful_macs=247808, skipped_macs=47104, analytical_cycles=3872, rtl_cycles=3872

Case C:
  layer1: output=PASS, selected_pe=32, useful_macs=14128, skipped_macs=13520, analytical_cycles=442, rtl_cycles=442
  layer2: output=PASS, selected_pe=64, useful_macs=243680, skipped_macs=51232, analytical_cycles=3808, rtl_cycles=3808
  layer3: output=PASS, selected_pe=64, useful_macs=247808, skipped_macs=47104, analytical_cycles=3872, rtl_cycles=3872

Overall: PASS
