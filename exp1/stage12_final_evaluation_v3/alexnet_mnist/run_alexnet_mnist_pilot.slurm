#!/usr/bin/env bash
#SBATCH --job-name=alexnet-mnist-pilot
#SBATCH --partition=q5h
#SBATCH --nodelist=node001
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=05:00:00
#SBATCH --output=/home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3/alexnet_mnist/slurm_pilot.out
#SBATCH --error=/home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3/alexnet_mnist/alexnet_mnist_training.err
set -euo pipefail
cd /home/cs25m115/Neural_Acc/exp1/stage12_final_evaluation_v3/alexnet_mnist
source /home/cs25m115/anaconda3/etc/profile.d/conda.sh
conda activate neural_acc
python -m py_compile model.py dataset.py adaptive_policy.py train_pilot.py evaluate.py
python train_pilot.py