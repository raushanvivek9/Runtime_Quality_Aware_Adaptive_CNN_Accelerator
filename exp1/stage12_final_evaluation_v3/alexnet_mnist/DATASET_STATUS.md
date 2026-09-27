# Dataset Status

status: MNIST_NOT_FOUND_LOCALLY
reason: compute node cannot download MNIST

required files:

- `train-images-idx3-ubyte.gz`
- `train-labels-idx1-ubyte.gz`
- `t10k-images-idx3-ubyte.gz`
- `t10k-labels-idx1-ubyte.gz`

Search locations checked:

- `/home/cs25m115/Neural_Acc`
- `/home/cs25m115/.cache/torch`
- `/home/cs25m115/.cache/torchvision`
- reasonable dataset/cache directories under `/home/cs25m115`

The 5-epoch pilot was not resubmitted. No alternate dataset or uncontrolled download was used.