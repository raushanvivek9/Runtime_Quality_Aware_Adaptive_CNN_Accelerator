#!/usr/bin/env bash

set -u

PROJECT="/home/cs25m115/Neural_Acc"
EXP="${PROJECT}/exp1"
STAGE7A="${EXP}/stage7a_energy_test"

ACCELERGY_DIR="${PROJECT}/Accelergy"
SCALESIM_V3_DIR="${PROJECT}/SCALE-Sim-v3-energy"

REPORT="${STAGE7A}/stage7a_report.txt"
ENV_REPORT="${STAGE7A}/stage7a_environment_summary.txt"
INSTALL_LOG="${STAGE7A}/stage7a_accelergy_installation.txt"
REPO_REPORT="${STAGE7A}/stage7a_scalesim_accelergy_mapping.txt"
SMOKE_REPORT="${STAGE7A}/stage7a_accelergy_smoke_test.txt"

mkdir -p "${STAGE7A}"

echo "==================================================" | tee "${REPORT}"
echo "Stage 7A - Energy Toolchain Setup & Validation" | tee -a "${REPORT}"
echo "==================================================" | tee -a "${REPORT}"
echo "Date: $(date)" | tee -a "${REPORT}"
echo "Project: ${PROJECT}" | tee -a "${REPORT}"
echo "" | tee -a "${REPORT}"


# --------------------------------------------------
# 1. Check conda environment
# --------------------------------------------------

echo "[1] Checking Python environment..." | tee -a "${REPORT}"

echo "Python:" | tee -a "${ENV_REPORT}"
which python | tee -a "${ENV_REPORT}"
python --version | tee -a "${ENV_REPORT}"

echo "" | tee -a "${ENV_REPORT}"

if command -v conda >/dev/null 2>&1; then
    echo "Conda environment:" | tee -a "${ENV_REPORT}"
    conda info --envs | tee -a "${ENV_REPORT}"
fi

echo "" | tee -a "${REPORT}"


# --------------------------------------------------
# 2. Check existing tools
# --------------------------------------------------

echo "[2] Checking existing energy tools..." | tee -a "${REPORT}"

TOOLS=(
    accelergy
    gem5
    ngspice
    vcd2saif
)

for tool in "${TOOLS[@]}"; do
    if command -v "${tool}" >/dev/null 2>&1; then
        echo "${tool}: FOUND -> $(command -v ${tool})" | tee -a "${REPORT}"
        "${tool}" --version 2>&1 | head -n 3 | tee -a "${ENV_REPORT}" || true
    else
        echo "${tool}: NOT_FOUND" | tee -a "${REPORT}"
    fi
done

echo "" | tee -a "${REPORT}"


# --------------------------------------------------
# 3. Check existing SCALE-Sim
# --------------------------------------------------

echo "[3] Inspecting existing SCALE-Sim..." | tee -a "${REPORT}"

if [ -d "${PROJECT}/SCALE-Sim/.git" ]; then

    echo "Existing SCALE-Sim:" | tee -a "${REPO_REPORT}"

    cd "${PROJECT}/SCALE-Sim"

    echo "Path: $(pwd)" | tee -a "${REPO_REPORT}"
    echo "Git HEAD:" | tee -a "${REPO_REPORT}"
    git rev-parse HEAD | tee -a "${REPO_REPORT}"

    echo "Git branch:" | tee -a "${REPO_REPORT}"
    git branch --show-current | tee -a "${REPO_REPORT}"

    echo "Recent commit:" | tee -a "${REPO_REPORT}"
    git log -1 --oneline | tee -a "${REPO_REPORT}"

    echo "" | tee -a "${REPO_REPORT}"

    echo "Accelergy-related files:" | tee -a "${REPO_REPORT}"

    find . -iname "*accelergy*" -o \
           -iname "*energy*" -o \
           -iname "*power*" \
           | head -100 | tee -a "${REPO_REPORT}"

else
    echo "Existing SCALE-Sim repository not found." | tee -a "${REPO_REPORT}"
fi

echo "" | tee -a "${REPORT}"


# --------------------------------------------------
# 4. Clone official Accelergy repository
# --------------------------------------------------

echo "[4] Preparing Accelergy..." | tee -a "${REPORT}"

if [ -d "${ACCELERGY_DIR}/.git" ]; then

    echo "Accelergy repository already exists." | tee -a "${INSTALL_LOG}"

    cd "${ACCELERGY_DIR}"

    git remote -v | head -n 2 | tee -a "${INSTALL_LOG}"
    git rev-parse HEAD | tee -a "${INSTALL_LOG}"

else

    echo "Cloning official Accelergy repository..." | tee -a "${INSTALL_LOG}"

    git clone \
        https://github.com/Accelergy-Project/accelergy.git \
        "${ACCELERGY_DIR}" \
        2>&1 | tee -a "${INSTALL_LOG}"

    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo "ERROR: Accelergy clone failed." | tee -a "${REPORT}"
        echo "STOP: Cannot continue Stage 7A." | tee -a "${REPORT}"
        exit 1
    fi
fi

echo "" | tee -a "${REPORT}"


# --------------------------------------------------
# 5. Install Accelergy
# --------------------------------------------------

echo "[5] Installing Accelergy into current environment..." | tee -a "${REPORT}"

cd "${ACCELERGY_DIR}"

python -m pip install . \
    2>&1 | tee -a "${INSTALL_LOG}"

INSTALL_STATUS=${PIPESTATUS[0]}

if [ "${INSTALL_STATUS}" -ne 0 ]; then
    echo "" | tee -a "${REPORT}"
    echo "ERROR: Accelergy installation failed." | tee -a "${REPORT}"
    echo "See:" | tee -a "${REPORT}"
    echo "${INSTALL_LOG}" | tee -a "${REPORT}"
    echo "" | tee -a "${REPORT}"
    echo "STOP: Do not generate energy numbers." | tee -a "${REPORT}"
    exit 1
fi

echo "Accelergy installation command completed." | tee -a "${REPORT}"
echo "" | tee -a "${REPORT}"


# --------------------------------------------------
# 6. Verify Accelergy executable
# --------------------------------------------------

echo "[6] Verifying Accelergy executable..." | tee -a "${REPORT}"

if command -v accelergy >/dev/null 2>&1; then

    echo "accelergy executable FOUND." | tee -a "${REPORT}"
    echo "Path: $(command -v accelergy)" | tee -a "${REPORT}"

    accelergy -h \
        2>&1 | head -n 30 | tee -a "${SMOKE_REPORT}"

else

    echo "ERROR: accelergy executable still NOT_FOUND." | tee -a "${REPORT}"
    echo "STOP: Installation did not produce a usable executable." | tee -a "${REPORT}"
    exit 1

fi

echo "" | tee -a "${REPORT}"


# --------------------------------------------------
# 7. Record Accelergy version
# --------------------------------------------------

echo "[7] Recording Accelergy version..." | tee -a "${REPORT}"

accelergy --version \
    2>&1 | tee -a "${ENV_REPORT}" || true

python -m pip show accelergy \
    2>&1 | tee -a "${ENV_REPORT}" || true

echo "" | tee -a "${REPORT}"


# --------------------------------------------------
# 8. Search Accelergy for examples
# --------------------------------------------------

echo "[8] Inspecting Accelergy examples..." | tee -a "${REPORT}"

cd "${ACCELERGY_DIR}"

echo "Example/configuration files:" | tee -a "${SMOKE_REPORT}"

find . \
    \( -iname "*.yaml" -o -iname "*.yml" \) \
    | head -100 \
    | tee -a "${SMOKE_REPORT}"

echo "" | tee -a "${SMOKE_REPORT}"

echo "README files:" | tee -a "${SMOKE_REPORT}"

find . \
    \( -iname "README*" -o -iname "*example*" \) \
    | head -100 \
    | tee -a "${SMOKE_REPORT}"

echo "" | tee -a "${REPORT}"


# --------------------------------------------------
# 9. Inspect official SCALE-Sim v3 separately
# --------------------------------------------------

echo "[9] Preparing separate SCALE-Sim v3 energy checkout..." | tee -a "${REPORT}"

if [ -d "${SCALESIM_V3_DIR}/.git" ]; then

    echo "Separate SCALE-Sim-v3-energy already exists." \
        | tee -a "${REPO_REPORT}"

else

    echo "Cloning official SCALE-Sim v3 repository..." \
        | tee -a "${REPO_REPORT}"

    git clone \
        https://github.com/scalesim-project/scale-sim-v3.git \
        "${SCALESIM_V3_DIR}" \
        2>&1 | tee -a "${REPO_REPORT}"

    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo "WARNING: SCALE-Sim v3 clone failed." | tee -a "${REPORT}"
        echo "Existing validated SCALE-Sim is preserved." | tee -a "${REPORT}"
    fi

fi


# --------------------------------------------------
# 10. Inspect SCALE-Sim v3 energy integration
# --------------------------------------------------

if [ -d "${SCALESIM_V3_DIR}" ]; then

    cd "${SCALESIM_V3_DIR}"

    echo "" | tee -a "${REPO_REPORT}"
    echo "SCALE-Sim v3 HEAD:" | tee -a "${REPO_REPORT}"

    git rev-parse HEAD \
        2>&1 | tee -a "${REPO_REPORT}"

    echo "" | tee -a "${REPO_REPORT}"

    echo "Accelergy-related files:" | tee -a "${REPO_REPORT}"

    find . \
        \( -iname "*accelergy*" \
        -o -iname "*energy*" \
        -o -iname "*power*" \) \
        | head -200 \
        | tee -a "${REPO_REPORT}"

    echo "" | tee -a "${REPO_REPORT}"

    echo "YAML architecture/component files:" | tee -a "${REPO_REPORT}"

    find . \
        \( -iname "*.yaml" -o -iname "*.yml" \) \
        | head -200 \
        | tee -a "${REPO_REPORT}"

    echo "" | tee -a "${REPO_REPORT}"

    echo "README energy references:" | tee -a "${REPO_REPORT}"

    grep -Rni \
        "accelergy\|energy estimation\|energy\|power" \
        README* 2>/dev/null \
        | head -100 \
        | tee -a "${REPO_REPORT}" || true

fi


# --------------------------------------------------
# 11. Install SCALE-Sim v3 separately
# --------------------------------------------------

echo "[10] Installing SCALE-Sim v3 into current environment..." \
    | tee -a "${REPORT}"

if [ -f "${SCALESIM_V3_DIR}/setup.py" ] || \
   [ -f "${SCALESIM_V3_DIR}/pyproject.toml" ]; then

    cd "${SCALESIM_V3_DIR}"

    python -m pip install -e . \
        2>&1 | tee -a "${INSTALL_LOG}"

    SCALE_STATUS=${PIPESTATUS[0]}

    if [ "${SCALE_STATUS}" -ne 0 ]; then
        echo "WARNING: SCALE-Sim v3 installation failed." \
            | tee -a "${REPORT}"
        echo "Existing SCALE-Sim installation remains untouched." \
            | tee -a "${REPORT}"
    else
        echo "SCALE-Sim v3 installation completed." \
            | tee -a "${REPORT}"
    fi

else

    echo "WARNING: No setup.py or pyproject.toml found in SCALE-Sim v3." \
        | tee -a "${REPORT}"

fi


# --------------------------------------------------
# 12. Final tool verification
# --------------------------------------------------

echo "" | tee -a "${REPORT}"
echo "[11] Final tool availability check..." | tee -a "${REPORT}"

for tool in accelergy scalesim; do

    if command -v "${tool}" >/dev/null 2>&1; then
        echo "${tool}: FOUND -> $(command -v ${tool})" \
            | tee -a "${REPORT}"
    else
        echo "${tool}: NOT_FOUND" \
            | tee -a "${REPORT}"
    fi

done


# --------------------------------------------------
# 13. Generate final status
# --------------------------------------------------

echo "" | tee -a "${REPORT}"
echo "==================================================" | tee -a "${REPORT}"
echo "Stage 7A preliminary status" | tee -a "${REPORT}"
echo "==================================================" | tee -a "${REPORT}"

if command -v accelergy >/dev/null 2>&1; then

    echo "Accelergy installation: PASS" | tee -a "${REPORT}"

    echo "" | tee -a "${REPORT}"
    echo "IMPORTANT:" | tee -a "${REPORT}"
    echo "Accelergy executable availability does NOT yet validate" \
         | tee -a "${REPORT}"
    echo "the complete SCALE-Sim -> activity -> Accelergy -> energy flow." \
         | tee -a "${REPORT}"

    echo "" | tee -a "${REPORT}"
    echo "Next step: identify and execute the official Accelergy" \
         | tee -a "${REPORT}"
    echo "architecture/component example and then establish the" \
         | tee -a "${REPORT}"
    echo "SCALE-Sim workload-to-energy mapping." | tee -a "${REPORT}"

else

    echo "Accelergy installation: FAIL" | tee -a "${REPORT}"
    echo "Stage 7A remains BLOCKED." | tee -a "${REPORT}"

fi


echo "" | tee -a "${REPORT}"
echo "Generated files:" | tee -a "${REPORT}"
echo "  ${REPORT}" | tee -a "${REPORT}"
echo "  ${ENV_REPORT}" | tee -a "${REPORT}"
echo "  ${INSTALL_LOG}" | tee -a "${REPORT}"
echo "  ${REPO_REPORT}" | tee -a "${REPORT}"
echo "  ${SMOKE_REPORT}" | tee -a "${REPORT}"

echo "" | tee -a "${REPORT}"
echo "Stage 7A setup script completed." | tee -a "${REPORT}"