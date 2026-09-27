from torch import nn


class AlexNetMNIST(nn.Module):
    """MNIST-compatible AlexNet-style CNN for 1x28x28 inputs."""

    def __init__(self):
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(1, 64, kernel_size=3, stride=1, padding=1),
            nn.ReLU(),
            nn.MaxPool2d(kernel_size=2, stride=2),
            nn.Conv2d(64, 192, kernel_size=3, stride=1, padding=1),
            nn.ReLU(),
            nn.MaxPool2d(kernel_size=2, stride=2),
            nn.Conv2d(192, 384, kernel_size=3, stride=1, padding=1),
            nn.ReLU(),
            nn.Conv2d(384, 256, kernel_size=3, stride=1, padding=1),
            nn.ReLU(),
            nn.Conv2d(256, 256, kernel_size=3, stride=1, padding=1),
            nn.ReLU(),
        )
        self.avgpool = nn.AdaptiveAvgPool2d((1, 1))
        self.classifier = nn.Linear(256, 10)

    def forward(self, inputs):
        features = self.features(inputs)
        pooled = self.avgpool(features)
        return self.classifier(pooled.flatten(1))


def convolution_layers(model):
    return [(name, layer) for name, layer in model.named_modules() if isinstance(layer, nn.Conv2d)]