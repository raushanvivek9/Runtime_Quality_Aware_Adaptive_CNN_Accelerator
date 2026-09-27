#!/usr/bin/env bash
#SBATCH --job-name=v3-vgg-eval
#SBATCH --partition=q15d
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=1-00:00:00
#SBATCH --output=logs/slurm_validated_vgg_eval_%j.out
#SBATCH --error=logs/slurm_validated_vgg_eval_%j.err
set -euo pipefail
cd /home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3
source /home/cs25m115/anaconda3/etc/profile.d/conda.sh
conda activate neural_acc
python run_validated_vgg_post_evaluation.py | tee "logs/run_validated_vgg_eval_${SLURM_JOB_ID}.log"