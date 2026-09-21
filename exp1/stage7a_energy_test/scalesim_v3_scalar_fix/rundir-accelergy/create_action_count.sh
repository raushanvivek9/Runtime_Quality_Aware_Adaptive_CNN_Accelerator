#!/bin/bash

python3 create_action_count.py --saved_folder /home/cs25m115/Neural_Acc/exp1/stage7a_energy_test/scalar_fix_scale_logs --run_name scale_example_run_32x32_ws --arch_name systolic_array --SRAM_row_size 2 --DRAM_row_size 2 --config /home/cs25m115/Neural_Acc/exp1/stage7a_energy_test/scalesim_v3_scalar_fix/configs/scale.cfg

cp /home/cs25m115/Neural_Acc/exp1/stage7a_energy_test/scalar_fix_scale_logs/scale_example_run_32x32_ws/action_count.yaml ./accelergy_input/action_count.yaml

mv /home/cs25m115/Neural_Acc/exp1/stage7a_energy_test/scalar_fix_scale_logs/scale_example_run_32x32_ws  /home/cs25m115/Neural_Acc/exp1/stage7a_energy_test/scalar_fix_output/scale_sim_output_scale_example_run_32x32_ws

