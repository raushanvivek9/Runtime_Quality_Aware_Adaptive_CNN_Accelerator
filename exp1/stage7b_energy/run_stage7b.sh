#!/usr/bin/env bash
set -euo pipefail

PROJECT=/home/cs25m115/Neural_Acc
STAGE=$PROJECT/exp1/stage7b_energy
SOURCE=$STAGE/source/SCALE-Sim-v3-energy
TOPOLOGY=$STAGE/project_inputs/cnn_v2.csv
REPORTS=$STAGE/reports

run_one() {
    local resource=$1
    local config=$2
    local run=$STAGE/runs/$resource
    local log=$run/stage7b_${resource}.log

    rm -rf "$run"
    mkdir -p "$run/scale_logs" "$run/accelergy"

    {
        echo "resource=$resource"
        echo "config=$config"
        echo "topology=$TOPOLOGY"
        echo "input_type=conv"
        echo
        cd "$SOURCE/rundir-accelergy"
        rm -f accelergy_input/*.yaml
        rm -rf accelergy_output
        python3 preprocess.py -c "$config" -t "$TOPOLOGY" -p "$run/scale_logs" -o "$run"
        cd "$SOURCE"
        python3 scale.py -c "$config" -t "$TOPOLOGY" -p "$run/scale_logs" -i conv
        cd "$SOURCE/rundir-accelergy"
        ./create_action_count.sh
        ./run_accelergy.sh
    } > >(tee "$log") 2>&1
}

run_one 16pe "$STAGE/project_inputs/config_16pe_v2.cfg"
run_one 32pe "$STAGE/project_inputs/config_32pe_v2.cfg"
run_one 64pe "$STAGE/project_inputs/config_64pe_v2.cfg"