# Stage 9B: Tensor Loading and Dataflow RTL Prototype

This directory implements the Stage 9B functional dataflow boundary around the validated Stage 9A convolution engine.

## Stage 9A reference

Stage 9A provides the functional padded convolution engine used as the calculation primitive. It evaluates the same 8x8x3-to-8x8x16 convolution topology with 3x3 kernels and 27 MACs per output element. The arithmetic and output checkpoints remain unchanged.

## Stage 9B objective

Stage 9B adds a deliberate tensor-loading and dataflow boundary between host/testbench data and the compute engine. The design moves from:

- testbench/register-array tensor storage
- tensor loader / stream
- input buffer / weight buffer / output buffer
- runtime monitoring and resource decision
- captured resource configuration
- convolution compute engine
- output buffer and output stream

This is a functional RTL prototype only. The register arrays are behavioral memory models. They are not physical SRAM macros and they do not claim SRAM timing, bandwidth, energy, or silicon area behavior.

## Architecture

Tensor Loader
     |
     v
Input Buffer      Weight Buffer
     |                 |
     +--------+--------+
              v
       Stage 8A Monitor
              v
       Resource Decision
              v
     Captured Resource Config
              v
    Conv Scheduler / PE Array
              v
         Output Buffer
              v
         Output Stream

## Files

- `tensor_loader.sv` — deterministic valid/ready tensor ingress for input and weight words.
- `input_buffer.sv` — 3x8x8 signed 16-bit buffer with explicit load/write and read access.
- `weight_buffer.sv` — 16x3x3x3 signed 16-bit buffer.
- `output_buffer.sv` — 16x8x8 signed 48-bit output store and streaming path.
- `dataflow_controller.sv` — explicit FSM scheduling the load/monitor/decision/compute/output phases.
- `conv_dataflow_top.sv` — integration wrapper for loader, buffers, Stage 8A monitor, capture logic, scheduler, and PE array.
- `tb_stage9b_dataflow.sv` — self-checking RTL testbench with deterministic input generation, output validation, and reconfiguration tests.
- `reference_model.py` — independent Python golden model for the same padded convolution contract.
- `run_sim.sh` — Python + compile + simulation flow using the `neural_acc` conda environment.

## Key constraints

- No direct testbench-to-convolution memory access is permitted.
- The Stage 9A convolution logic is reused, while the input/weight/output paths are buffered and explicit.
- The active PE population changes only via the captured resource configuration.
- The computed output remains mathematically identical for 16/32/64 active-PE modes.
- The final output stream contains exactly 1024 flattened values with unique indices.

## Safety/claiming boundary

This prototype validates:

- explicit tensor loading
- behavioral buffering
- runtime capture of the resource decision
- correct convolution output across PE modes
- output stream semantics

It does not claim:

- SRAM or DMA performance
- power/energy savings
- area savings
- timing closure
- FPGA/ASIC implementation validity
- CNN accuracy improvement
