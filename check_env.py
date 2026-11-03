import sys
try:
    import torch
    print("Torch:", torch.__version__)
except ImportError:
    print("Torch: NOT INSTALLED")

try:
    import torchvision
    print("Torchvision:", torchvision.__version__)
except ImportError:
    print("Torchvision: NOT INSTALLED")

try:
    import numpy as np
    print("NumPy:", np.__version__)
except ImportError:
    print("NumPy: NOT INSTALLED")

