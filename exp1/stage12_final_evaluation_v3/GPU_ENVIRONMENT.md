# GPU Environment Validation

Validation was performed inside a Slurm allocation on `node005.cluster`, not on the login node.

Hardware reported by the compute node:

- Allocated GPUs: 3 logical GPUs
- GPU model: Tesla P100-PCIE-12GB
- GPU memory: 12,288 MiB each
- Slurm node inventory: node005 provides 8 GPUs total
- Driver: 570.181
- System CUDA reported by `nvidia-smi`: 12.8

Software:

- Python: 3.11.16
- PyTorch: 2.5.1+cu118
- PyTorch CUDA runtime: 11.8
- CUDA available: True
- GPU count: 3
- torchvision: 0.20.1+cu118

Validation:

- GPU 0 matrix multiplication: PASS
- GPU 1 matrix multiplication: PASS
- GPU 2 matrix multiplication: PASS
- GPU memory query: PASS
- CIFAR-compatible ResNet-18 CUDA forward pass: PASS
- Training launched: NO

## One-epoch GPU pilot

- Model/dataset: ResNet-18/CIFAR-10
- Training samples: 45,000
- Validation samples: 5,000
- Batch size: 128
- Epoch wall time: 222.37 seconds
- Train loss: 1.845406
- Train accuracy: 33.5533%
- Validation loss: 1.494628
- Validation accuracy: 43.40%
- GPU utilization/memory monitoring: recorded in `results/one_epoch_gpu_monitor.csv`

Estimated runtime from the measured pilot:

- 50 epochs: 3.09 hours per model
- 100 epochs: 6.18 hours per model
- 150 epochs: 9.27 hours per model

The proposed final target is **150 epochs**, declared before final training,
because the q15d partition provides a 15-day limit. Four sequential runs are
approximately 37.1 hours before validation/checkpoint overhead. Final training
was deliberately not launched by this validation task.

The compute node GPU hardware is Tesla P100, not the GTX 1080 Ti hardware visible on the login node. The existing `neural_acc` environment already contains a compatible CUDA-enabled PyTorch build, so no package installation or environment modification was performed.

Raw records are in `results/slurm_gpu_inventory.txt`, `results/slurm_gpu_environment.txt`, and `results/gpu_validation.txt`.
