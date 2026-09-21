#!/usr/bin/env bash
set -euo pipefail

STAGE=/home/cs25m115/Neural_Acc/exp1/stage7c_per_layer_energy
SOURCE=$STAGE/source/SCALE-Sim-v3-energy

run_one() {
    local layer=$1
    local resource=$2
    local config=$STAGE/configs/config_${resource}pe_energy.cfg
    local run=$STAGE/runs/${layer}_${resource}pe
    local topology=$STAGE/inputs/${layer}.csv

    rm -rf "$run"
    mkdir -p "$run"
    {
        echo "layer=$layer"
        echo "resource=${resource} PE"
        echo "config=$config"
        echo "topology=$topology"
        echo "input_type=conv"
        echo
        cd "$SOURCE/rundir-accelergy"
        rm -f accelergy_input/*.yaml
        rm -rf accelergy_output
        python3 preprocess.py -c "$config" -t "$topology" -p "$run/scale_logs" -o "$run"
        cd "$SOURCE"
        python3 scale.py -c "$config" -t "$topology" -p "$run/scale_logs" -i conv
        cd "$SOURCE/rundir-accelergy"
        ./create_action_count.sh
        ./run_accelergy.sh
    } > >(tee "$run/stage7c_${layer}_${resource}pe.log") 2>&1
}

layers=("${1:-conv1}")
for layer in "${layers[@]}"; do
    case "$layer" in
        conv1|conv2|conv3) ;;
        *) echo "Unknown layer: $layer" >&2; exit 2 ;;
    esac
    run_one "$layer" 16
    run_one "$layer" 32
    run_one "$layer" 64
done