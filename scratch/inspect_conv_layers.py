import os
import torch
import torch.nn as nn
import torchvision.models as models

sample = torch.randn(1, 3, 32, 32)

# ResNet-18
r18 = models.resnet18(num_classes=10)
r18.conv1 = nn.Conv2d(3, 64, kernel_size=3, stride=1, padding=1, bias=False)
r18.maxpool = nn.Identity()

print("=== RESNET-18 CIFAR-10 CONV LAYERS ===")
def register_hooks(model):
    shapes = {}
    for name, mod in model.named_modules():
        if isinstance(mod, nn.Conv2d):
            def get_hook(n):
                def hook(m, inp, outp):
                    shapes[n] = (inp[0].shape, m.weight.shape, outp.shape, m.stride, m.padding)
                return hook
            mod.register_forward_hook(get_hook(name))
    _ = model(sample)
    for n, s in shapes.items():
        print(f"{n}: in={s[0]}, wt={s[1]}, out={s[2]}, stride={s[3]}, pad={s[4]}")

register_hooks(r18)

print("\n=== VGG-16-BN CIFAR-10 CONV LAYERS ===")
vgg = torch.hub.load("chenyaofo/pytorch-cifar-models", "cifar10_vgg16_bn", pretrained=False)
register_hooks(vgg)

