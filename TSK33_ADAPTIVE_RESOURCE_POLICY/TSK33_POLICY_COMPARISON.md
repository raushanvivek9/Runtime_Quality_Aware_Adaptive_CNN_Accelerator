# TSK-33: Adaptive Policy Comparative Evaluation

## 1. Experimental Overview and Scenarios

To evaluate the operational performance, predictability, and efficiency of the redesigned policies against the legacy TSK-30 adaptive controller, we benchmarked all three controllers across four representative real-world CNN workloads extracted from trained PyTorch checkpoints and four realistic deployment scenarios.

### Workload Characteristics ($3 \times 3$ Convolutions, 196 Spatial Positions, $K=576$):
- **WL1: ResNet-18 CIFAR-10 `layer1.0.conv1`** ($C_{\text{in}}=64, C_{\text{out}}=64$, Baseline Sparsity $\approx 0.00\%$)
- **WL2: ResNet-18 CIFAR-100 `layer1.0.conv1`** ($C_{\text{in}}=64, C_{\text{out}}=64$, Intermediate Sparsity $\approx 47.7\%$)
- **WL3: VGG-16-BN CIFAR-10 `features.3`** ($C_{\text{in}}=64, C_{\text{out}}=64$, High Sparsity $\approx 73.1\%$, Legacy Pruning Proxy Degradation $> 80\%$)
- **WL4: ResNet-18 CIFAR-10 `layer2.1.conv2`** ($C_{\text{in}}=64, C_{\text{out}}=64$, Sub-sampled Channel Slice, Sparsity $\approx 51.5\%$)

### Deployment Scenarios:
1. **Scenario 1 (Tight Real-Time Latency):** $L_{\text{max}} = 10,000\text{ cycles}, P_{\text{max}} = 64$. (e.g. 100+ FPS autonomous robotics or high-speed visual inspection).
2. **Scenario 2 (Moderate Latency Budget):** $L_{\text{max}} = 20,000\text{ cycles}, P_{\text{max}} = 64$. (e.g. 50 FPS real-time edge video analytics).
3. **Scenario 3 (Relaxed Latency Budget):** $L_{\text{max}} = 40,000\text{ cycles}, P_{\text{max}} = 64$. (e.g. 25 FPS battery-powered smart camera or IoT surveillance).
4. **Scenario 4 (Resource-Capped Deployment):** $L_{\text{max}} = 25,000\text{ cycles}, P_{\text{max}} = 32$. (e.g. thermally throttled wearable or multi-core coprocessor slice).

---

## 2. Quantitative Policy Decision Matrix

The following table details the decisions rendered by the **Legacy Controller (TSK-30)**, **Policy A (Min-Resource)**, and **Policy B (Min-Latency)** across all 16 scenario-workload pairs:

| Scenario | Workload | Metric / Dimension | Legacy TSK-30 Controller | Policy A (Min-Resource) | Policy B (Min-Latency) |
| :--- | :--- | :--- | :---: | :---: | :---: |
| **S1: Tight**<br>($L \le 10\text{k}, P \le 64$) | **WL1** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 32-PE / 19,121<br>**MISSED** (+9,121 cyc)<br>32 PEs / 55,296 reads | **64-PE / 9,569**<br>**MET** (-431 cyc)<br>64 PEs / 46,080 reads | **64-PE / 9,569**<br>**MET** (-431 cyc)<br>64 PEs / 46,080 reads |
| | **WL2** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 32-PE / 19,121<br>**MISSED** (+9,121 cyc)<br>32 PEs / 55,296 reads | **64-PE / 9,569**<br>**MET** (-431 cyc)<br>64 PEs / 46,080 reads | **64-PE / 9,569**<br>**MET** (-431 cyc)<br>64 PEs / 46,080 reads |
| | **WL3** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 64-PE / 9,569<br>**MET** (-431 cyc)<br>64 PEs / 46,080 reads | **64-PE / 9,569**<br>**MET** (-431 cyc)<br>64 PEs / 46,080 reads | **64-PE / 9,569**<br>**MET** (-431 cyc)<br>64 PEs / 46,080 reads |
| | **WL4** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 16-PE / 38,225<br>**MISSED** (+28,225 cyc)<br>16 PEs / 73,728 reads | **64-PE / 9,569**<br>**MET** (-431 cyc)<br>64 PEs / 46,080 reads | **64-PE / 9,569**<br>**MET** (-431 cyc)<br>64 PEs / 46,080 reads |
| **S2: Moderate**<br>($L \le 20\text{k}, P \le 64$) | **WL1** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 32-PE / 19,121<br>**MET** (-879 cyc)<br>32 PEs / 55,296 reads | **32-PE / 19,121**<br>**MET** (-879 cyc)<br>32 PEs / 55,296 reads | **64-PE / 9,569**<br>**MET** (-10,431 cyc)<br>64 PEs / 46,080 reads |
| | **WL2** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 32-PE / 19,121<br>**MET** (-879 cyc)<br>32 PEs / 55,296 reads | **32-PE / 19,121**<br>**MET** (-879 cyc)<br>32 PEs / 55,296 reads | **64-PE / 9,569**<br>**MET** (-10,431 cyc)<br>64 PEs / 46,080 reads |
| | **WL3** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 64-PE / 9,569<br>**MET** (Over-allocated)<br>64 PEs / 46,080 reads | **32-PE / 19,121**<br>**MET** (-879 cyc)<br>32 PEs / 55,296 reads | **64-PE / 9,569**<br>**MET** (-10,431 cyc)<br>64 PEs / 46,080 reads |
| | **WL4** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 16-PE / 38,225<br>**MISSED** (+18,225 cyc)<br>16 PEs / 73,728 reads | **32-PE / 19,121**<br>**MET** (-879 cyc)<br>32 PEs / 55,296 reads | **64-PE / 9,569**<br>**MET** (-10,431 cyc)<br>64 PEs / 46,080 reads |
| **S3: Relaxed**<br>($L \le 40\text{k}, P \le 64$) | **WL1** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 32-PE / 19,121<br>**MET** (Sub-optimal)<br>32 PEs / 55,296 reads | **16-PE / 38,225**<br>**MET** (-1,775 cyc)<br>16 PEs / 73,728 reads | **64-PE / 9,569**<br>**MET** (-30,431 cyc)<br>64 PEs / 46,080 reads |
| | **WL2** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 32-PE / 19,121<br>**MET** (Sub-optimal)<br>32 PEs / 55,296 reads | **16-PE / 38,225**<br>**MET** (-1,775 cyc)<br>16 PEs / 73,728 reads | **64-PE / 9,569**<br>**MET** (-30,431 cyc)<br>64 PEs / 46,080 reads |
| | **WL3** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 64-PE / 9,569<br>**MET** (Over-allocated)<br>64 PEs / 46,080 reads | **16-PE / 38,225**<br>**MET** (-1,775 cyc)<br>16 PEs / 73,728 reads | **64-PE / 9,569**<br>**MET** (-30,431 cyc)<br>64 PEs / 46,080 reads |
| | **WL4** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 16-PE / 38,225<br>**MET** (-1,775 cyc)<br>16 PEs / 73,728 reads | **16-PE / 38,225**<br>**MET** (-1,775 cyc)<br>16 PEs / 73,728 reads | **64-PE / 9,569**<br>**MET** (-30,431 cyc)<br>64 PEs / 46,080 reads |
| **S4: Capped**<br>($L \le 25\text{k}, P \le 32$) | **WL1** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 32-PE / 19,121<br>**MET** (-5,879 cyc)<br>32 PEs / 55,296 reads | **32-PE / 19,121**<br>**MET** (-5,879 cyc)<br>32 PEs / 55,296 reads | **32-PE / 19,121**<br>**MET** (-5,879 cyc)<br>32 PEs / 55,296 reads |
| | **WL2** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 32-PE / 19,121<br>**MET** (-5,879 cyc)<br>32 PEs / 55,296 reads | **32-PE / 19,121**<br>**MET** (-5,879 cyc)<br>32 PEs / 55,296 reads | **32-PE / 19,121**<br>**MET** (-5,879 cyc)<br>32 PEs / 55,296 reads |
| | **WL3** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | **64-PE / 9,569**<br>**CAP VIOLATED!** (64 > 32)<br>64 PEs / 46,080 reads | **32-PE / 19,121**<br>**MET** (-5,879 cyc)<br>32 PEs / 55,296 reads | **32-PE / 19,121**<br>**MET** (-5,879 cyc)<br>32 PEs / 55,296 reads |
| | **WL4** | Selected Mode / Cycles<br>Deadline Met?<br>Active PEs / SRAM Reads | 16-PE / 38,225<br>**MISSED** (+13,225 cyc)<br>16 PEs / 73,728 reads | **32-PE / 19,121**<br>**MET** (-5,879 cyc)<br>32 PEs / 55,296 reads | **32-PE / 19,121**<br>**MET** (-5,879 cyc)<br>32 PEs / 55,296 reads |

---

## 3. Detailed Comparative Analysis

### 3.1 Failure Modes of the Legacy Controller

1. **Deadlock on Real-Time Deadlines (Scenario 1):**
   - In Scenario 1, the system requires completion within 10,000 cycles.
   - The legacy controller had **no input port for execution latency**. Instead, it selected modes based strictly on whether the historical channel-pruning degradation vector $\hat{D}_{mode}$ exceeded $\tau = 5\%$.
   - For WL1 and WL2, $\hat{D}_{32}$ was recorded as $\approx 3.2\% \le 5\%$, so the controller picked 32-PE. This caused execution to require 19,121 cycles, **missing the real-time deadline by 9,121 cycles (a 91.2% overrun)**!
   - For WL4, $\hat{D}_{16}$ was recorded as $\approx 1.8\% \le 5\%$, so the controller picked 16-PE. This required 38,225 cycles, **missing the deadline by 28,225 cycles (a 282% overrun)**!
   - Out of 4 workloads, the legacy controller **violated real-time deadlines on 3 of them (75% failure rate)**.
   - In contrast, both Policy A and Policy B correctly detected that only 64-PE (9,569 cycles) could meet the 10,000-cycle threshold, achieving a **100% deadline satisfaction rate**.

2. **Violation of Physical Power / Thermal Caps (Scenario 4):**
   - In Scenario 4, the system imposes a strict hardware ceiling of $P_{\text{max}} = 32$ active PEs due to thermal dissipation limits.
   - For WL3, the legacy controller observed an extreme degradation proxy ($\hat{D} > 80\%$) and forced a fallback to **64-PE**.
   - Because the legacy controller lacked a resource-limit input, it **exceeded the physical silicon power cap by 100%**, risking thermal runaway or power brownout.
   - Policy A and Policy B clamped active allocation to 32-PE, completing within 19,121 cycles and safely satisfying both the 25,000-cycle budget and the 32-PE limit.

3. **Compute Over-Allocation in Energy-Sensitive Modes (Scenario 3):**
   - In Scenario 3, where latency is relaxed ($L_{\text{max}} = 40,000$ cycles), the objective is to minimize active compute hardware.
   - For WL1 and WL2, the legacy controller picked 32-PE (running 32 PEs when 16 PEs would easily meet the 40k budget).
   - For WL3, the legacy controller picked 64-PE, burning $4\times$ more active compute silicon than necessary.
   - Policy A consistently selected **16-PE** across all four workloads, reducing active compute elements by 50% to 75%.

---

## 4. Compute vs. Memory Trade-Off Quantification

A key architectural insight revealed by the RTL measurements is the inverse relationship between active PE parallelism and SRAM activation read volume:

```
PE Mode       Active PEs       Channel Passes       Execution Cycles       Act SRAM Reads       Total SRAM Reads
----------------------------------------------------------------------------------------------------------------
16-PE             16                 4                   38,225                36,864               73,728
32-PE             32                 2                   19,121                18,432               55,296
64-PE             64                 1                    9,569                 9,216               46,080
```

- **Active Compute Silicon Reduction:** 16-PE mode disables 48 of the 64 MAC units (75% reduction in active datapath multipliers and accumulators).
- **Activation Read Amplification:** Because the on-chip activation buffer must be re-scanned across 4 sequential channel passes, activation reads increase by $4.0\times$ (from 9,216 to 36,864 words).
- **Total SRAM Read Overhead:** Total SRAM accesses (activations + weights) increase from 46,080 words (64-PE) to 73,728 words (16-PE), a $1.60\times$ increase.

**System Design Guideline:**
Policy A is ideal for compute-bound, thermal-capped scenarios where datapath switching power dominates over local SRAM read energy. If SRAM read energy dominates (or external DRAM bandwidth is constrained), Policy B or 32-PE mode provides a more balanced Pareto operating point.

