#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# STAGE 7B
# Actual SimpleCNN -> SCALE-Sim -> Accelergy Energy Evaluation
# ============================================================

PROJECT="/home/cs25m115/Neural_Acc"
EXP1="$PROJECT/exp1"

# Official SCALE-Sim v3 checkout validated in Stage 7A
SCALE="$PROJECT/SCALE-Sim-v3-energy"

# Existing verified CNN topology/config directory
SCALE_EXP="$EXP1/scalesim"

# New isolated Stage 7B directory
OUT="$EXP1/stage7b_energy"

mkdir -p "$OUT"

echo "============================================================"
echo "STAGE 7B - ACTUAL CNN ENERGY EVALUATION"
echo "============================================================"
echo "Project       : $PROJECT"
echo "SCALE-Sim v3  : $SCALE"
echo "Output        : $OUT"
echo

# ------------------------------------------------------------
# 0. Environment
# ------------------------------------------------------------

if [[ "${CONDA_DEFAULT_ENV:-}" != "neural_acc" ]]; then
    echo "[ERROR] Activate neural_acc first:"
    echo "        conda activate neural_acc"
    exit 1
fi

echo "[1] Environment"
python --version
python - <<'PY'
import numpy
print("NumPy:", numpy.__version__)
PY

echo
echo "[2] Tool availability"

command -v accelergy
accelergy -h >/dev/null

echo "Accelergy: OK"
echo "SCALE-Sim directory: $SCALE"

if [[ ! -d "$SCALE" ]]; then
    echo "[ERROR] SCALE-Sim v3 directory not found."
    exit 1
fi

# ------------------------------------------------------------
# 3. Verify official energy integration
# ------------------------------------------------------------

echo
echo "[3] Checking SCALE-Sim energy integration"

test -f "$SCALE/README_accelergy.md"
test -f "$SCALE/rundir-accelergy/run_accelergy.sh"
test -f "$SCALE/architecture.yaml"

echo "README_accelergy.md       : OK"
echo "run_accelergy.sh          : OK"
echo "architecture.yaml        : OK"

# ------------------------------------------------------------
# 4. Locate existing topology
# ------------------------------------------------------------

echo
echo "[4] Searching for existing SCALE-Sim topology/config"

find "$SCALE_EXP" \
    -maxdepth 3 \
    -type f \
    \( -name "*.csv" -o -name "*.cfg" -o -name "*.ini" \) \
    -print | tee "$OUT/existing_scalesim_files.txt"

# ------------------------------------------------------------
# 5. Configuration
# ------------------------------------------------------------
#
# IMPORTANT:
# Replace these paths if your existing Stage 5 topology/config
# filenames are different.
#
# The script intentionally does NOT modify your old files.
# ------------------------------------------------------------

TOPOLOGY="$SCALE_EXP/topology.csv"

CONFIG_16="$SCALE_EXP/config_4x4.cfg"
CONFIG_32="$SCALE_EXP/config_4x8.cfg"
CONFIG_64="$SCALE_EXP/config_8x8.cfg"

for f in "$TOPOLOGY" "$CONFIG_16" "$CONFIG_32" "$CONFIG_64"; do
    if [[ ! -f "$f" ]]; then
        echo
        echo "[ERROR] Required file not found:"
        echo "$f"
        echo
        echo "Look at:"
        echo "$OUT/existing_scalesim_files.txt"
        echo
        echo "Then change the TOPOLOGY/CONFIG paths in this script."
        exit 1
    fi
done

echo "Topology: $TOPOLOGY"
echo "16 PE config: $CONFIG_16"
echo "32 PE config: $CONFIG_32"
echo "64 PE config: $CONFIG_64"

# ------------------------------------------------------------
# 6. Function to run SCALE-Sim
# ------------------------------------------------------------

run_scalesim()
{
    local NAME="$1"
    local CONFIG="$2"
    local RUN_DIR="$OUT/scalesim_${NAME}"

    echo
    echo "============================================================"
    echo "Running SCALE-Sim: $NAME"
    echo "============================================================"

    rm -rf "$RUN_DIR"
    mkdir -p "$RUN_DIR"

    cd "$SCALE"

    python -m scalesim.scale \
        -c "$CONFIG" \
        -t "$TOPOLOGY" \
        -p "$RUN_DIR" \
        2>&1 | tee "$RUN_DIR/scalesim.log"

    echo
    echo "SCALE-Sim finished: $NAME"

    # Required activity report
    if [[ ! -f "$RUN_DIR/DETAILED_ACCESS_REPORT.csv" ]]; then
        echo "[ERROR] DETAILED_ACCESS_REPORT.csv missing for $NAME"
        exit 1
    fi

    echo "DETAILED_ACCESS_REPORT.csv: OK"
}

# ------------------------------------------------------------
# 7. Run all three PE configurations
# ------------------------------------------------------------

run_scalesim "16pe_4x4" "$CONFIG_16"
run_scalesim "32pe_4x8" "$CONFIG_32"
run_scalesim "64pe_8x8" "$CONFIG_64"

# ------------------------------------------------------------
# 8. Run Accelergy
# ------------------------------------------------------------

run_accelergy()
{
    local NAME="$1"
    local SCALE_OUT="$OUT/scalesim_${NAME}"
    local ENERGY_OUT="$OUT/accelergy_${NAME}"

    echo
    echo "============================================================"
    echo "Running Accelergy: $NAME"
    echo "============================================================"

    rm -rf "$ENERGY_OUT"
    mkdir -p "$ENERGY_OUT"

    # --------------------------------------------------------
    # Copy the official validated architecture/component model
    # into this isolated run directory.
    # --------------------------------------------------------

    cp "$SCALE/architecture.yaml" "$ENERGY_OUT/"

    cp -r "$SCALE/rundir-accelergy/accelergy_input" \
          "$ENERGY_OUT/"

    # --------------------------------------------------------
    # Look for action-count output produced by SCALE-Sim.
    # --------------------------------------------------------

    ACTION_FILE=""

    if [[ -f "$SCALE_OUT/action_count.yaml" ]]; then
        ACTION_FILE="$SCALE_OUT/action_count.yaml"
    elif [[ -f "$SCALE_OUT/action_counts.yaml" ]]; then
        ACTION_FILE="$SCALE_OUT/action_counts.yaml"
    fi

    if [[ -z "$ACTION_FILE" ]]; then
        echo
        echo "[ERROR] No action-count YAML found for $NAME."
        echo
        echo "Files generated by SCALE-Sim:"
        find "$SCALE_OUT" -maxdepth 2 -type f -print
        exit 1
    fi

    echo "Action counts:"
    echo "$ACTION_FILE"

    cp "$ACTION_FILE" "$ENERGY_OUT/action_count.yaml"

    # --------------------------------------------------------
    # Run official Accelergy.
    #
    # First use the same architecture/component model that
    # passed Stage 7A.
    # --------------------------------------------------------

    cd "$ENERGY_OUT"

    accelergy \
        architecture.yaml \
        action_count.yaml \
        -o "$ENERGY_OUT" \
        2>&1 | tee "$ENERGY_OUT/accelergy.log"

    # --------------------------------------------------------
    # Validate energy output
    # --------------------------------------------------------

    if [[ ! -f "$ENERGY_OUT/energy_estimation.yaml" ]]; then
        echo
        echo "[ERROR] energy_estimation.yaml was not generated."
        echo
        find "$ENERGY_OUT" -maxdepth 3 -type f -print
        exit 1
    fi

    echo
    echo "ENERGY ESTIMATION GENERATED:"
    echo "$ENERGY_OUT/energy_estimation.yaml"

    # --------------------------------------------------------
    # Extract useful summary information
    # --------------------------------------------------------

    grep -i -E \
        "energy|total|power|cycle|mac|buffer|sram|dram" \
        "$ENERGY_OUT/energy_estimation.yaml" \
        > "$ENERGY_OUT/energy_summary.txt" || true
}

# ------------------------------------------------------------
# 9. Accelergy for all configurations
# ------------------------------------------------------------

run_accelergy "16pe_4x4"
run_accelergy "32pe_4x8"
run_accelergy "64pe_8x8"

# ------------------------------------------------------------
# 10. Final validation
# ------------------------------------------------------------

echo
echo "============================================================"
echo "STAGE 7B VALIDATION"
echo "============================================================"

for NAME in 16pe_4x4 32pe_4x8 64pe_8x8; do

    echo
    echo "----- $NAME -----"

    SCALE_OUT="$OUT/scalesim_${NAME}"
    ENERGY_OUT="$OUT/accelergy_${NAME}"

    echo "SCALE-Sim:"
    test -f "$SCALE_OUT/DETAILED_ACCESS_REPORT.csv" \
        && echo "  DETAILED_ACCESS_REPORT.csv: PASS"

    echo "Accelergy:"
    test -f "$ENERGY_OUT/action_count.yaml" \
        && echo "  action_count.yaml: PASS"

    test -f "$ENERGY_OUT/energy_estimation.yaml" \
        && echo "  energy_estimation.yaml: PASS"

done

# ------------------------------------------------------------
# 11. Save environment information
# ------------------------------------------------------------

{
    echo "Stage 7B environment"
    echo "===================="
    date
    echo
    python --version
    echo
    pip show accelergy || true
    echo
    git -C "$SCALE" rev-parse HEAD
} > "$OUT/environment.txt"

echo
echo "============================================================"
echo "STAGE 7B COMPLETED"
echo "============================================================"
echo
echo "Results:"
echo "$OUT"
echo
echo "Next:"
echo "  Compare total energy across 16/32/64 PE configurations."
echo
