# TSK-34: Resource and Energy Claim Audit

## 1. Executive Summary & Objective

A central finding of recent Neural_Acc evaluations is that architectural changes in processing element (PE) allocation—specifically throttling from 64-PE mode down to 32-PE or 16-PE mode—produce significant reductions in active arithmetic datapath multipliers. In marketing literature or high-level architectural proposals, such reductions are frequently conflated with equivalent percentage reductions in total system power or energy consumption (e.g. "a 75% reduction in active PEs yields a 75% energy savings").

The objective of this audit is to establish a rigorous, disciplined distinction between:
- **Directly Measured Microarchitectural Metrics** (cycle counts, SRAM reads, active multipliers)
- **Derived Analytical Proxies** (estimated switching capacitance, theoretical dynamic power)
- **True Physical Characterization** (post-layout power analysis, silicon measurement)

This audit proves why active PE count **cannot** be converted directly into total accelerator energy reduction, analyzes the memory-subsystem energy penalty incurred by multi-pass channel tiling, and establishes clear reporting boundaries for the Neural_Acc project.

---

## 2. Definitive Metric Classification Taxonomy

To ensure scientific integrity and prevent unsubstantiated claims, the project adopts the following 7-level metric classification taxonomy:

```mermaid
flowchart TD
    M1["1. Active PE Count<br>(Microarchitectural State)"] -->|Architectural Multiplier Count| E2["2. Estimated Switching Capacitance<br>(C_eff = alpha * C_PE)"]
    E2 -->|Analytical Model| E4["4. Estimated Dynamic Power<br>(P_dyn = 0.5 * C_eff * V^2 * f)"]
    E4 -->|Multiplied by Latency| E6["6. Estimated Energy per Inference<br>(E = P_dyn * T_exec)"]
    
    RTL["Cycle-Accurate RTL Simulation<br>(VCD / SAIF Toggling)"] --> M3["3. Measured Switching Activity<br>(Toggle Count & Static Probabilities)"]
    M3 -->|Post-Layout Sign-off Tool<br>(PrimeTime PX / Joules / Voltus)| M5["5. Measured Power<br>(P_dyn + P_leakage from .lib/.spef)"]
    M5 -->|Silicon Test / Sign-off Integration| M7["7. Measured Energy per Inference<br>(Integrated Joules per Inference)"]
    
    style M1 fill:#d4edda,stroke:#28a745
    style M3 fill:#d4edda,stroke:#28a745
    style E2 fill:#fff3cd,stroke:#ffc107
    style E4 fill:#fff3cd,stroke:#ffc107
    style E6 fill:#fff3cd,stroke:#ffc107
    style M5 fill:#f8d7da,stroke:#dc3545
    style M7 fill:#f8d7da,stroke:#dc3545
```

### Classification Breakdown:

| Metric Category | Level | Measurement Source | Hardware Grounding | Status in Neural_Acc RTL |
| :--- | :---: | :--- | :--- | :---: |
| **Active PE Count** | 1 | Microarchitectural register state (`active_pe_count`) | Exactly 16, 32, or 64 physical MAC columns enabled. | **Directly Measured** |
| **Estimated Switching Capacitance** | 2 | Analytical gate-count proxy ($C_{\text{eff}} \approx \alpha \cdot N_{\text{PE}} \cdot C_{\text{mac}}$) | Assumes linear capacitive scaling per active PE. | **Analytical Proxy** |
| **Measured Switching Activity** | 3 | Simulation dump (`.vcd` or `.saif` toggle capture) | Net-by-net toggle rates and signal probabilities in RTL. | **Measured in RTL** |
| **Estimated Dynamic Power** | 4 | Theoretical equation ($P_{\text{dyn}} = \frac{1}{2} C_{\text{eff}} V^2 f$) | Neglects clock tree, SRAM macros, and interconnect wires. | **Analytical Proxy** |
| **Measured Power** | 5 | Post-synthesis / post-layout tool (e.g. Synopsys PrimeTime PX) | Requires target foundry standard cell library and extracted parasitics (`.spef`). | **Requires PDK Synthesis** |
| **Estimated Energy per Inference** | 6 | Product of analytical power and cycle latency ($E = P_{\text{est}} \cdot T$) | Omits leakage integration over extended runtimes. | **Analytical Proxy** |
| **Measured Energy per Inference** | 7 | Integrated physical current $\times$ voltage on silicon or sign-off EDA | True physical Joules dissipated per workload. | **Physical Silicon Required** |

---

## 3. Why Active PE Throttling Does NOT Scale Linearly to Energy Reduction

### 3.1 The Energy Decomposition Formula
The total energy dissipated during the execution of a convolution layer on the Neural_Acc accelerator is rigorously expressed as:

$$E_{\text{total}} = E_{\text{compute}} + E_{\text{memory}} + E_{\text{leakage}} + E_{\text{clock}}$$

where:
1. $E_{\text{compute}} = N_{\text{mac\_ops}} \cdot E_{\text{mac}}$ (dynamic energy of 16-bit multiplications and 40-bit accumulations).
2. $E_{\text{memory}} = N_{\text{act\_reads}} \cdot E_{\text{sram\_read}} + N_{\text{wt\_reads}} \cdot E_{\text{sram\_read}} + N_{\text{writes}} \cdot E_{\text{sram\_write}}$.
3. $E_{\text{leakage}} = P_{\text{leak\_total}} \cdot T_{\text{total}} \cdot \tau_{\text{clk}}$ (static leakage integrated over total execution time).
4. $E_{\text{clock}} = P_{\text{clk\_tree}} \cdot T_{\text{total}} \cdot \tau_{\text{clk}}$ (clock network switching capacitance integrated over time).

### 3.2 The Multi-Pass Memory Penalty
In 16-PE mode, only 16 output channels can be processed concurrently. Because the complete workload has $C_{\text{out}} = 64$, the accelerator must perform **4 sequential channel passes** over the spatial feature map:

```
PE Mode       Active PEs       Channel Passes       Execution Latency       Activation SRAM Reads       Weight SRAM Reads
-------------------------------------------------------------------------------------------------------------------------
64-PE             64                 1                 9,569 cycles               9,216 words              147,456 words
32-PE             32                 2                19,121 cycles              18,432 words              147,456 words
16-PE             16                 4                38,225 cycles              36,864 words              147,456 words
```

- **Activation Reload Amplification:** 16-PE mode requires **$4.0\times$ more SRAM activation reads** (36,864 vs. 9,216 words) because the activation buffer must be re-traversed for each 16-channel slice.
- **Total SRAM Read Growth:** Total SRAM read operations increase from 156,672 words (in 64-PE) to 184,320 words (in 16-PE), an increase of **$+17.65\%$**.

### 3.3 The Extended Leakage Penalty
- 16-PE mode requires **38,225 cycles**, which is **$3.995\times$ longer** than 64-PE mode (9,569 cycles).
- Unless unselected PE columns are disconnected via dedicated **fine-grained power gating (MTCMOS sleep transistors)**, all 64 MAC columns continue to draw static sub-threshold and gate oxide leakage current for the entirety of the 38,225 cycles.
- Consequently, static leakage energy dissipation increases by **$\approx 4.0\times$**:
  $$E_{\text{leakage}}(16\text{-PE}) \approx 4.0 \times E_{\text{leakage}}(64\text{-PE})$$

### 3.4 Quantitative Energy Comparison Model

Assuming representative 28nm CMOS standard cell and SRAM macro energy values:
- $E_{\text{mac}} \approx 0.50\text{ pJ/MAC}$
- $E_{\text{sram\_read}} \approx 2.50\text{ pJ/word}$
- $E_{\text{sram\_write}} \approx 3.00\text{ pJ/word}$
- $P_{\text{leak}} \approx 1.50\text{ mW}$ at 100 MHz ($\tau_{\text{clk}} = 10\text{ ns}$)

```
Energy Component                   64-PE Mode (9,569 cyc)        16-PE Mode (38,225 cyc)        Ratio (16-PE / 64-PE)
----------------------------------------------------------------------------------------------------------------------
E_compute (147,456 MACs @ 0.5 pJ)        73.73 nJ                      73.73 nJ                         1.00x
E_sram_act (reads @ 2.5 pJ)              23.04 nJ                      92.16 nJ                         4.00x
E_sram_wt (147,456 reads @ 2.5 pJ)      368.64 nJ                     368.64 nJ                         1.00x
E_sram_write (256 writes @ 3.0 pJ)        0.77 nJ                       0.77 nJ                         1.00x
E_leakage (1.5 mW * latency)            143.54 nJ                     573.38 nJ                         3.99x
----------------------------------------------------------------------------------------------------------------------
TOTAL ESTIMATED ENERGY                  609.72 nJ                     1108.68 nJ                        1.82x (+81.8%)
```

> [!WARNING]
> **Key Architectural Takeaway:**  
> In architectures where SRAM read energy and static leakage dominate over arithmetic multiplier switching, **16-PE mode actually INCREASES total energy per inference by up to 81.8%**!  
> Throttling to 16-PE mode **reduces instantaneous peak power and active switching capacitance**, but **does not reduce total energy**. Claims of energy reduction without physical silicon characterization are scientifically invalid.

---

## 4. Policy Role & Reporting Protocol

1. **Policy A Justification:** Policy A is valid and beneficial specifically for **peak-power capping**, **thermal throttling** (e.g. keeping chip temperature below $85^\circ\text{C}$ in passively cooled enclosures), and **avoiding supply voltage droop (Ldi/dt noise)**. It must be described as an *instantaneous compute resource minimization policy*, not an energy minimization policy.
2. **Policy B Justification:** Policy B maximizes throughput ($64\text{ MACs/cycle}$), minimizing execution time ($9,569\text{ cycles}$) and thereby minimizing static leakage energy integration. For unconstrained thermal environments, Policy B is actually the **energy-optimal** policy!
3. **Mandatory Reporting Rule:** All future Neural_Acc publications, reports, and documentation must strictly present cycle counts, active PEs, and SRAM accesses as microarchitectural metrics, and explicitly forbid claiming dynamic power or energy reductions without gate-level netlist power extraction with a commercial PDK.

