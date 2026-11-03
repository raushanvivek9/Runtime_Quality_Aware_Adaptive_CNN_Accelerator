#!/usr/bin/env python3
import timm
print("Testing timm models...")
try:
    m_c10 = timm.create_model("hf-hub:edadaltocg/resnet18_cifar10", pretrained=True)
    print("[SUCCESS] Loaded edadaltocg/resnet18_cifar10!")
    print("  Conv1:", m_c10.conv1)
    print("  FC:", m_c10.fc)
except Exception as e:
    print(f"[ERROR C10] {e}")

try:
    m_c100 = timm.create_model("hf-hub:edadaltocg/resnet18_cifar100", pretrained=True)
    print("[SUCCESS] Loaded edadaltocg/resnet18_cifar100!")
    print("  Conv1:", m_c100.conv1)
    print("  FC:", m_c100.fc)
except Exception as e:
    print(f"[ERROR C100] {e}")

