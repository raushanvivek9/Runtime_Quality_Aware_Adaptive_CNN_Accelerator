#!/usr/bin/env bash
#SBATCH --job-name=v3-r18-c100
#SBATCH --partition=q15d
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=15-00:00:00
#SBATCH --output=logs/slurm_resnet18_cifar100_%j.out
#SBATCH --error=logs/slurm_resnet18_cifar100_%j.err
set -euo pipefail
cd /home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3
source /home/cs25m115/anaconda3/etc/profile.d/conda.sh
conda activate neural_acc
printf 'SLURM_JOB_ID=%s\nSLURM_JOB_NODELIST=%s\nSLURM_JOB_PARTITION=%s\nCUDA_VISIBLE_DEVICES=%s\n' "$SLURM_JOB_ID" "$SLURM_JOB_NODELIST" "$SLURM_JOB_PARTITION" "${CUDA_VISIBLE_DEVICES:-}" > "logs/environment_resnet18_cifar100_${SLURM_JOB_ID}.txt"
nvidia-smi >> "logs/environment_resnet18_cifar100_${SLURM_JOB_ID}.txt"
nvidia-smi --query-gpu=timestamp,index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits -l 60 > "logs/gpu_resnet18_cifar100_${SLURM_JOB_ID}.csv" 2>&1 & monitor_pid=$!
trap 'kill "$monitor_pid" 2>/dev/null || true' EXIT
python train_models.py --model resnet18 --dataset cifar100 | tee "logs/run_resnet18_cifar100_${SLURM_JOB_ID}.log"
