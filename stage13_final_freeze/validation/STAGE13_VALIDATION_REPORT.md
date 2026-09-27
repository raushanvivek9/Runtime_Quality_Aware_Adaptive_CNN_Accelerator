# Stage 13 Validation Report

Overall status: **PASS**

Passed: 48  
Failed: 0  
Review required: 0

- **PASS** checkpoints verified: ResNet18/CIFAR10: exists=True loads=True epoch=144; ResNet18/CIFAR100: exists=True loads=True epoch=134; VGG16/CIFAR10: exists=True loads=True epoch=127; VGG16/CIFAR100: exists=True loads=True epoch=139
- **PASS** dataset split verified: CONFIG.yaml and common.py present
- **PASS** model dataset names consistent: four expected pairs present
- **PASS** ResNet18/CIFAR10 best epoch: 144
- **PASS** ResNet18/CIFAR10 test accuracy: 0.9513
- **PASS** ResNet18/CIFAR10 dense sparse accuracy: 0.9513 == 0.9513
- **PASS** ResNet18/CIFAR10 mismatch count: 0
- **PASS** ResNet18/CIFAR10 sparsity valid: 62.51186579895019
- **PASS** ResNet18/CIFAR10 MAC relationship: skipped=dense-useful
- **PASS** ResNet18/CIFAR10 MAC formula: 72.24934835338311
- **PASS** ResNet18/CIFAR10 cycle formula: 24083125525
- **PASS** ResNet18/CIFAR10 PE valid: 64.0
- **PASS** ResNet18/CIFAR100 best epoch: 134
- **PASS** ResNet18/CIFAR100 test accuracy: 0.7697
- **PASS** ResNet18/CIFAR100 dense sparse accuracy: 0.7697 == 0.7697
- **PASS** ResNet18/CIFAR100 mismatch count: 0
- **PASS** ResNet18/CIFAR100 sparsity valid: 57.68464033508301
- **PASS** ResNet18/CIFAR100 MAC relationship: skipped=dense-useful
- **PASS** ResNet18/CIFAR100 MAC formula: 68.28395165353061
- **PASS** ResNet18/CIFAR100 cycle formula: 27524455397
- **PASS** ResNet18/CIFAR100 PE valid: 64.0
- **PASS** VGG16/CIFAR10 best epoch: 127
- **PASS** VGG16/CIFAR10 test accuracy: 0.8846
- **PASS** VGG16/CIFAR10 dense sparse accuracy: 0.8846 == 0.8846
- **PASS** VGG16/CIFAR10 mismatch count: 0
- **PASS** VGG16/CIFAR10 sparsity valid: 83.45374636136567
- **PASS** VGG16/CIFAR10 MAC relationship: skipped=dense-useful
- **PASS** VGG16/CIFAR10 MAC formula: 89.59230678816175
- **PASS** VGG16/CIFAR10 cycle formula: 5093208664
- **PASS** VGG16/CIFAR10 PE valid: 64.0
- **PASS** VGG16/CIFAR100 best epoch: 139
- **PASS** VGG16/CIFAR100 test accuracy: 0.6557
- **PASS** VGG16/CIFAR100 dense sparse accuracy: 0.6557 == 0.6557
- **PASS** VGG16/CIFAR100 mismatch count: 0
- **PASS** VGG16/CIFAR100 sparsity valid: 53.85006880540114
- **PASS** VGG16/CIFAR100 MAC relationship: skipped=dense-useful
- **PASS** VGG16/CIFAR100 MAC formula: 69.98297529719868
- **PASS** VGG16/CIFAR100 cycle formula: 14689419372
- **PASS** VGG16/CIFAR100 PE valid: 64.0
- **PASS** epsilon values valid: 0%, 5%, 10%, 20%
- **PASS** adaptive policy complete: 16 PASS rows
- **PASS** adaptive PE values valid: PE values in 16/32/64
- **PASS** no contradictory VGG100 final status: no stale VGG100 final metadata
- **PASS** no unsupported hardware speedup claims: analytical terminology only
- **PASS** no physical energy claims: physical energy/power are explicitly unmeasured and unclaimed
- **PASS** full model RTL not claimed: RTL scope documented as not run
- **PASS** final tables agree: JSON and CSV pair ordering agrees
- **PASS** all final statuses PASS: four PASS rows
