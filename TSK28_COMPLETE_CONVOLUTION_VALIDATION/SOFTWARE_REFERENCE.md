# TSK-28 Software Reference Model Report

## 1. Mathematical Formulation

The independent software reference model calculates the 2D spatial convolution for output channel $oc$ at spatial coordinates $(y, x)$ using the standard discrete convolution sum:

$$O[oc, y, x] = \sum_{ky=0}^{K_H-1} \sum_{kx=0}^{K_W-1} \sum_{ic=0}^{C_{in}-1} W[oc, ic, ky, kx] \cdot I_{pad}[ic, y + ky, x + kx]$$

Where:
- $I_{pad}$ is the zero-padded input activation tensor ($p=1$).
- $K_H = 3, K_W = 3, C_{in} = 64$.
- The total reduction count is $K = 3 \times 3 \times 64 = 576$.

---

## 2. Integer Hardware-Accurate Fixed-Point Model

To establish bit-exact verification against the hardware accelerator, the software reference implements identical arithmetic semantics:

```python
def hardware_exact_reference(act_patches_int16, wt_int16):
    """
    act_patches_int16: (16_positions, 9_chunks, 64_channels) in int16
    wt_int16:          (16_channels, 9_chunks, 64_channels) in int16
    Returns:           (16_positions, 16_channels) in int64 (40-bit range)
    """
    TOTAL_POS = 16
    COUT = 16
    TOTAL_CHUNKS = 9
    K_PER_CHUNK = 64

    accum_out = np.zeros((TOTAL_POS, COUT), dtype=np.int64)

    for p in range(TOTAL_POS):
        for oc in range(COUT):
            sum_40 = np.int64(0)
            for c in range(TOTAL_CHUNKS):
                for k in range(K_PER_CHUNK):
                    a = np.int64(act_patches_int16[p, c, k])
                    w = np.int64(wt_int16[oc, c, k])
                    prod = a * w # 32-bit signed product
                    sum_40 += prod # 40-bit accumulator
            accum_out[p, oc] = sum_40

    return accum_out
```

---

## 3. Numerical Comparison: Floating-Point vs. Fixed-Point

The software reference also computes the PyTorch FP32 convolution baseline using full single-precision floating-point arithmetic to quantify the Signal-to-Quantization-Noise Ratio (SQNR):

$$SQNR_{dB} = 10 \cdot \log_{10} \left( \frac{\sum (y_{fp32})^2}{\sum (y_{fp32} - y_{fixed})^2} \right)$$

### Empirical Results
- **Dataset**: First test image from CIFAR-10 test set.
- **Signal Power**: $1.291 \times 10^{-1}$
- **Noise Power**: $2.366 \times 10^{-7}$
- **SQNR**: **57.37 dB**
- **Maximum Absolute Discrepancy**: $6.97 \times 10^{-4}$ (due purely to 12-bit fractional quantization).

---

## 4. Software Reference Predictions Manifest

The complete reference predictions across all 256 output elements are recorded in [`SOFTWARE_REFERENCE_PREDICTIONS.csv`](file:///e:/MTech/LanChain/MTP/TSK28_COMPLETE_CONVOLUTION_VALIDATION/SOFTWARE_REFERENCE_PREDICTIONS.csv):
- `pos_idx`: Spatial tile index $p \in [0, 15]$.
- `y, x`: 2D feature map coordinate $(y \in [0, 3], x \in [0, 3])$.
- `cout_idx`: Output channel index $oc \in [0, 15]$.
- `accum_40b`: Expected bit-exact 40-bit integer accumulator value.
- `requant_int16`: Expected 16-bit requantized value.
- `relu_int16`: Expected post-ReLU value.
- `pyt_float32`: PyTorch reference floating-point value.

