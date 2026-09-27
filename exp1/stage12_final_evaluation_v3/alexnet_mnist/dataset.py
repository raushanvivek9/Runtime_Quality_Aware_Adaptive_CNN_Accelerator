from pathlib import Path

import torch
from torch.utils.data import DataLoader, Subset
from torchvision import datasets, transforms


SEED = 42
DATA_ROOT = Path(__file__).resolve().parent / "data"
NORMALIZE = transforms.Normalize((0.1307,), (0.3081,))
REQUIRED_FILES = (
    "train-images-idx3-ubyte.gz",
    "train-labels-idx1-ubyte.gz",
    "t10k-images-idx3-ubyte.gz",
    "t10k-labels-idx1-ubyte.gz",
)


def verify_local_dataset(root=DATA_ROOT):
    raw_root = Path(root) / "MNIST" / "raw"
    for filename in REQUIRED_FILES:
        path = raw_root / filename
        if not path.is_file():
            raise FileNotFoundError(f"MNIST file missing: {path}")
    return raw_root


def make_datasets():
    transform = transforms.Compose([transforms.ToTensor(), NORMALIZE])
    verify_local_dataset()
    training = datasets.MNIST(DATA_ROOT, train=True, download=False, transform=transform)
    test = datasets.MNIST(DATA_ROOT, train=False, download=False, transform=transform)
    generator = torch.Generator().manual_seed(SEED)
    permutation = torch.randperm(len(training), generator=generator).tolist()
    train_indices = permutation[:55000]
    validation_indices = permutation[55000:]
    return Subset(training, train_indices), Subset(training, validation_indices), test


def make_loaders(batch_size=128):
    train_set, validation_set, test_set = make_datasets()
    train_loader = DataLoader(train_set, batch_size=batch_size, shuffle=True, generator=torch.Generator().manual_seed(SEED), num_workers=0)
    validation_loader = DataLoader(validation_set, batch_size=batch_size, shuffle=False, num_workers=0)
    test_loader = DataLoader(test_set, batch_size=batch_size, shuffle=False, num_workers=0)
    return train_loader, validation_loader, test_loader