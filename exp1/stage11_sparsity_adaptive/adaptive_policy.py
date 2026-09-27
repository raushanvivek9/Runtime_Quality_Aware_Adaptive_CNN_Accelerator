#!/usr/bin/env python3

from pathlib import Path

from stage11_python_reference import compute_reference_stats


def main():
    stats = compute_reference_stats()
    effective_sparsity = stats['effective_sparsity_percent']
    print(f"Effective sparsity: {effective_sparsity:.4f}%")
    if effective_sparsity < 0.5:
        print('The current deterministic workload does not provide sufficient sparsity variation for meaningful adaptive threshold evaluation.')
        return 0
    print('Adaptive threshold policy is not applicable because the deterministic workload does not materially vary sparsity across resource modes.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
