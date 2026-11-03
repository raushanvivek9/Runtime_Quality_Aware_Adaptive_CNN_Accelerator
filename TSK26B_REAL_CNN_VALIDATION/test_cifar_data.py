#!/usr/bin/env python3
import sys

print("Checking available dataset packages...")
try:
    import datasets
    print("HuggingFace datasets is installed!")
except ImportError:
    print("HuggingFace datasets is NOT installed.")

# Let's check torchvision mirrors or direct fetch
import torchvision
print(f"torchvision version: {torchvision.__version__}")

