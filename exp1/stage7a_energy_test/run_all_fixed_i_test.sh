#!/bin/bash

set -u

repo_root="/home/cs25m115/Neural_Acc/SCALE-Sim-v3-energy"
run_dir="$repo_root/rundir-accelergy"
config_file="$repo_root/configs/scale.cfg"
topology_file="$repo_root/topologies/conv_nets/test.csv"
scale_log_dir="/home/cs25m115/Neural_Acc/exp1/stage7a_energy_test/fixed_i_test_scale_logs"
output_dir="/home/cs25m115/Neural_Acc/exp1/stage7a_energy_test/fixed_i_test_output"

rm -rf "$scale_log_dir" "$output_dir"
mkdir -p "$scale_log_dir" "$output_dir"

cd "$run_dir" || exit 1
python3 preprocess.py -c "$config_file" -t "$topology_file" -p "$scale_log_dir" -o "$output_dir"

cd "$repo_root" || exit 1
python3 scale.py -c "$config_file" -t "$topology_file" -p "$scale_log_dir" -i conv

cd "$run_dir" || exit 1
./create_action_count.sh
./run_accelergy.sh