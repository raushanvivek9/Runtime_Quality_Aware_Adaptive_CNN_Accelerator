#!/usr/bin/env bash
#SBATCH --partition=q15d
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=15-00:00:00
#SBATCH --output=logs/slurm-%j.out
#SBATCH --error=logs/slurm-%j.err

set -euo pipefail
cd /home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3
source /home/cs25m115/anaconda3/etc/profile.d/conda.sh
conda activate neural_acc
{
  echo "SLURM_JOB_ID=$SLURM_JOB_ID"
  echo "SLURM_JOB_NODELIST=$SLURM_JOB_NODELIST"
  echo "SLURM_JOB_PARTITION=$SLURM_JOB_PARTITION"
  echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
  hostname
  nvidia-smi
} > results/slurm_job_environment_${SLURM_JOB_ID}.txt

# Run the one-epoch pilot first. Submit this script only after reviewing GPU validation.
# Full v3 training is intentionally not launched by this validation step.
python gpu_one_epoch_pilot.py | tee results/one_epoch_gpu_pilot_${SLURM_JOB_ID}.txt
