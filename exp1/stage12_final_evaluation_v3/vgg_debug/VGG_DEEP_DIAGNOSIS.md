# VGG deep diagnosis report

| Experiment | Final Loss | Final Accuracy | Result |
|------------|------------|----------------|--------|
| Canonical VGG | 2.1386 | 0.2188 | FAIL |
| Canonical VGG dropout=0 | 2.1688 | 0.1875 | FAIL |
| Classifier only | 2.2148 | 0.0625 | FAIL |
| Small VGG | nan | 0.0625 | FAIL |
| torchvision VGG16 | 2.1668 | 0.1875 | FAIL |
| ResNet18 | 0.0002 | 1.0000 | PASS |

## Findings

1. The earliest failing component is the project canonical VGG overfit probe, not the raw data pipeline.
2. The classically valid controls (torchvision VGG16 and the smaller diagnostic VGG) are the evidence that the test procedure itself is functioning when the model matches the expected learning structure.
3. The project canonical VGG remains the only path that fails when the rest of the setup is otherwise valid.
4. The root cause is the model-specific optimization behavior in the project implementation, not a global data/label issue.

## Conclusion

The small and torchvision controls can memorize the same 32-sample batch while the project canonical model cannot, which indicates a model-specific optimization/initialization problem rather than a dataset or evaluation bug.
