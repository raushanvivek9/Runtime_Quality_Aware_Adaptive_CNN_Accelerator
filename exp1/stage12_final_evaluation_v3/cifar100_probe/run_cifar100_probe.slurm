#!/usr/bin/env bash
#SBATCH --job-name=cifar100-probe
#SBATCH --partition=q15d
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=08:00:00
#SBATCH --output=/home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3/cifar100_probe/slurm_probe.out
#SBATCH --error=/home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3/cifar100_probe/slurm_probe.err
set -euo pipefail
cd /home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3
source /home/cs25m115/anaconda3/etc/profile.d/conda.sh
conda activate neural_acc
python -m py_compile cifar100_probe/run_cifar100_probe.py
PYTHONPATH=/home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3 python cifar100_probe/run_cifar100_probe.py
