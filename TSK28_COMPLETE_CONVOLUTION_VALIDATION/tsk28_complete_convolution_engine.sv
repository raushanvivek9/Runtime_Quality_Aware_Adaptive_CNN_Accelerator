// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-28 Complete Convolution Layer Validation
// Module: tsk28_complete_convolution_engine.sv
// Description: Synthesizable Convolution Engine integrating:
//              1. tsk27c_spatial_accumulation_controller (TSK-27C outer/inner sequencer)
//              2. 16 parallel physical mac_unit_40b instances (COUT=16 channels)
//              3. Autonomous compute streaming feeder (k_len cycles per chunk)
//              4. Autonomous OFMAP drain register file & handshake logic
// =============================================================================

`timescale 1ns / 1ps

module tsk28_complete_convolution_engine #(
    parameter int COORD_W      = 16,
    parameter int ADDR_W       = 14,
    parameter int TILE_IDX_W   = 16,
    parameter int CHUNK_IDX_W  = 8,
    parameter int LAYER_ID_W   = 16,
    parameter int COUT_CHANNELS= 16,
    parameter int ACT_MEM_SIZE = 9216,
    parameter int WT_MEM_SIZE  = 9216,
    parameter int OUT_MEM_SIZE = 256
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // High-Level Configuration & Control
    input  logic                          start_req,
    input  logic                          abort_req,
    input  logic                          error_clear,
    input  logic [COORD_W-1:0]            cfg_grid_w,
    input  logic [COORD_W-1:0]            cfg_grid_h,
    input  logic [7:0]                    cfg_step_x,
    input  logic [7:0]                    cfg_step_y,
    input  logic [CHUNK_IDX_W-1:0]        cfg_total_chunks,
    input  logic [15:0]                   cfg_k_per_chunk,
    input  logic [ADDR_W-1:0]             cfg_base_ifmap,
    input  logic [ADDR_W-1:0]             cfg_base_ofmap,
    input  logic [ADDR_W-1:0]             cfg_stride_ifmap_x,
    input  logic [ADDR_W-1:0]             cfg_stride_ifmap_y,
    input  logic [ADDR_W-1:0]             cfg_stride_ifmap_chunk,
    input  logic [ADDR_W-1:0]             cfg_stride_ofmap,
    input  logic [LAYER_ID_W-1:0]         cfg_layer_id,
    input  logic [1:0]                    cfg_pe_mode,

    // Status Telemetry
    output logic                          busy,
    output logic                          done_pulse,
    output logic                          error_flag,
    output logic [3:0]                    error_code,
    output logic                          busy_reject,
    output logic [3:0]                    controller_fsm_state,
    output logic [COORD_W-1:0]            current_x,
    output logic [COORD_W-1:0]            current_y,
    output logic [TILE_IDX_W-1:0]         current_tile_idx,
    output logic [TILE_IDX_W-1:0]         total_tiles_count,
    output logic [CHUNK_IDX_W-1:0]        current_chunk_idx,
    output logic [CHUNK_IDX_W-1:0]        total_chunks_count,
    output logic                          is_first_chunk,
    output logic                          is_last_chunk,
    output logic [31:0]                   total_reductions_executed,

    // Drain & Drained Data Telemetry
    output logic                          drain_valid_pulse,
    output logic [TILE_IDX_W-1:0]         drain_tile_idx,
    output logic signed [39:0]            drained_accum [0:COUT_CHANNELS-1],
    output logic [COUT_CHANNELS-1:0]      mac_sticky_sat_flags,

    // Memory Write/Preload Interface (for Testbench verification)
    input  logic                          mem_act_we,
    input  logic [$clog2(ACT_MEM_SIZE)-1:0] mem_act_addr,
    input  logic signed [15:0]            mem_act_wdata,
    input  logic                          mem_wt_we,
    input  logic [$clog2(WT_MEM_SIZE)-1:0]  mem_wt_addr,
    input  logic signed [15:0]            mem_wt_wdata,

    // Output Memory Read Interface
    input  logic [$clog2(OUT_MEM_SIZE)-1:0] mem_out_raddr,
    output logic signed [39:0]            mem_out_rdata
);

    // -------------------------------------------------------------------------
    // Internal Memories
    // -------------------------------------------------------------------------
    logic signed [15:0] act_ram [0:ACT_MEM_SIZE-1];
    logic signed [15:0] wt_ram  [0:WT_MEM_SIZE-1];
    logic signed [39:0] out_ram [0:OUT_MEM_SIZE-1];

    // Synchronous memory write
    always_ff @(posedge clk) begin
        if (mem_act_we) begin
            act_ram[mem_act_addr] <= mem_act_wdata;
        end
        if (mem_wt_we) begin
            wt_ram[mem_wt_addr] <= mem_wt_wdata;
        end
    end

    // Asynchronous / continuous memory read for testbench scoreboarding
    assign mem_out_rdata = out_ram[mem_out_raddr];

    // -------------------------------------------------------------------------
    // Controller Wires
    // -------------------------------------------------------------------------
    logic        core_accum_clear;
    logic        core_compute_valid;
    logic        core_cmd_ready;
    logic        core_compute_done;
    logic        core_drain_req;
    logic        core_drain_ready;
    logic        core_drain_done;
    logic [ADDR_W-1:0]  core_ifmap_addr;
    logic [ADDR_W-1:0]  core_ofmap_addr;
    logic [15:0]        core_k_len;
    logic [1:0]         core_pe_mode;
    logic [LAYER_ID_W-1:0] core_layer_id;

    // -------------------------------------------------------------------------
    // Instantiate TSK-27C Spatial Accumulation Controller
    // -------------------------------------------------------------------------
    tsk27c_spatial_accumulation_controller #(
        .COORD_W     (COORD_W),
        .ADDR_W      (ADDR_W),
        .TILE_IDX_W  (TILE_IDX_W),
        .CHUNK_IDX_W (CHUNK_IDX_W),
        .LAYER_ID_W  (LAYER_ID_W)
    ) u_controller (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .start_req                 (start_req),
        .abort_req                 (abort_req),
        .error_clear               (error_clear),
        .cfg_grid_w                (cfg_grid_w),
        .cfg_grid_h                (cfg_grid_h),
        .cfg_step_x                (cfg_step_x),
        .cfg_step_y                (cfg_step_y),
        .cfg_total_chunks          (cfg_total_chunks),
        .cfg_k_per_chunk           (cfg_k_per_chunk),
        .cfg_base_ifmap            (cfg_base_ifmap),
        .cfg_base_ofmap            (cfg_base_ofmap),
        .cfg_stride_ifmap_x        (cfg_stride_ifmap_x),
        .cfg_stride_ifmap_y        (cfg_stride_ifmap_y),
        .cfg_stride_ifmap_chunk    (cfg_stride_ifmap_chunk),
        .cfg_stride_ofmap          (cfg_stride_ofmap),
        .cfg_layer_id              (cfg_layer_id),
        .cfg_pe_mode               (cfg_pe_mode),
        .busy                      (busy),
        .done_pulse                (done_pulse),
        .error_flag                (error_flag),
        .error_code                (error_code),
        .busy_reject               (busy_reject),
        .fsm_state                 (controller_fsm_state),
        .current_x                 (current_x),
        .current_y                 (current_y),
        .current_tile_idx          (current_tile_idx),
        .total_tiles_count         (total_tiles_count),
        .current_chunk_idx         (current_chunk_idx),
        .total_chunks_count        (total_chunks_count),
        .is_first_chunk            (is_first_chunk),
        .is_last_chunk             (is_last_chunk),
        .total_reductions_executed (total_reductions_executed),
        .core_accum_clear          (core_accum_clear),
        .core_compute_valid        (core_compute_valid),
        .core_cmd_ready            (core_cmd_ready),
        .core_compute_done         (core_compute_done),
        .core_drain_req            (core_drain_req),
        .core_drain_ready          (core_drain_ready),
        .core_drain_done           (core_drain_done),
        .core_ifmap_addr           (core_ifmap_addr),
        .core_ofmap_addr           (core_ofmap_addr),
        .core_k_len                (core_k_len),
        .core_pe_mode              (core_pe_mode),
        .core_layer_id             (core_layer_id)
    );

    // -------------------------------------------------------------------------
    // MAC Array Signals (16 Parallel Output Channels)
    // -------------------------------------------------------------------------
    logic                          mac_enable;
    logic signed [15:0]            mac_act_data;
    logic signed [15:0]            mac_weight_data   [0:COUT_CHANNELS-1];
    wire  signed [39:0]            mac_accum_out     [0:COUT_CHANNELS-1];
    wire                           mac_sticky_sat    [0:COUT_CHANNELS-1];
    wire                           mac_cycle_skipped [0:COUT_CHANNELS-1];

    // Generate 16 Physical MAC Units
    genvar col;
    generate
        for (col = 0; col < COUT_CHANNELS; col++) begin : gen_mac_array
            mac_unit_40b #(
                .ACT_WIDTH    (16),
                .WEIGHT_WIDTH (16),
                .ACCUM_WIDTH  (40)
            ) u_mac (
                .clk               (clk),
                .rst_n             (rst_n),
                .enable            (mac_enable),
                .accum_clear       (core_accum_clear), // Directly driven by controller!
                .sat_clear         (1'b0),
                .act_data          (mac_act_data),
                .act_mask          (1'b1),
                .weight_data       (mac_weight_data[col]),
                .accum_out         (mac_accum_out[col]),
                .sticky_saturation (mac_sticky_sat[col]),
                .cycle_skipped     (mac_cycle_skipped[col])
            );
            assign mac_sticky_sat_flags[col] = mac_sticky_sat[col];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Autonomous Compute Feeder & Drain Engine FSM
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ENG_IDLE       = 3'd0,
        ENG_COMP_RUN   = 3'd1,
        ENG_COMP_DONE  = 3'd2,
        ENG_DRAIN_RUN  = 3'd3,
        ENG_DRAIN_DONE = 3'd4
    } eng_state_t;

    eng_state_t eng_state;
    logic [15:0] k_counter;
    logic [TILE_IDX_W-1:0]  latched_tile_idx;
    logic [CHUNK_IDX_W-1:0] latched_chunk_idx;
    logic [15:0]            latched_k_len;
    int unsigned            act_addr_wire;
    int unsigned            wt_addr_wire;

    // Drain pulse logic
    logic drain_pulse_r;
    assign drain_valid_pulse = drain_pulse_r;

    // FSM State Register & Execution Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eng_state          <= ENG_IDLE;
            k_counter          <= '0;
            latched_tile_idx   <= '0;
            latched_chunk_idx  <= '0;
            latched_k_len      <= '0;
            core_cmd_ready     <= 1'b0;
            core_compute_done  <= 1'b0;
            core_drain_ready   <= 1'b0;
            core_drain_done    <= 1'b0;
            mac_enable         <= 1'b0;
            mac_act_data       <= '0;
            drain_pulse_r      <= 1'b0;
            drain_tile_idx     <= '0;
            for (int c = 0; c < COUT_CHANNELS; c++) begin
                mac_weight_data[c] <= '0;
                drained_accum[c]   <= '0;
            end
        end else begin
            // Defaults
            core_cmd_ready    <= 1'b0;
            core_compute_done <= 1'b0;
            core_drain_ready  <= 1'b0;
            core_drain_done   <= 1'b0;
            drain_pulse_r     <= 1'b0;

            case (eng_state)
                ENG_IDLE: begin
                    mac_enable <= 1'b0;

                    // Compute Dispatch from Controller
                    if (core_compute_valid) begin
                        core_cmd_ready     <= 1'b1;
                        latched_tile_idx   <= current_tile_idx;
                        latched_chunk_idx  <= current_chunk_idx;
                        latched_k_len      <= core_k_len;
                        k_counter          <= '0;
                        eng_state          <= ENG_COMP_RUN;
                    end
                    // Drain Dispatch from Controller
                    else if (core_drain_req) begin
                        latched_tile_idx   <= current_tile_idx;
                        eng_state          <= ENG_DRAIN_RUN;
                    end
                end

                ENG_COMP_RUN: begin
                    // Assert enable and stream operands
                    mac_enable <= 1'b1;

                    // Address calculation:
                    // act_addr = (tile_idx * 9 + chunk_idx) * 64 + k
                    act_addr_wire = (latched_tile_idx * 9 + latched_chunk_idx) * 64 + k_counter;
                    mac_act_data <= act_ram[act_addr_wire];

                    // wt_addr = (oc * 9 + chunk_idx) * 64 + k
                    for (int c = 0; c < COUT_CHANNELS; c++) begin
                        wt_addr_wire = (c * 9 + latched_chunk_idx) * 64 + k_counter;
                        mac_weight_data[c] <= wt_ram[wt_addr_wire];
                    end

                    // Check reduction completion
                    if (k_counter + 1'b1 >= latched_k_len) begin
                        eng_state <= ENG_COMP_DONE;
                    end else begin
                        k_counter <= k_counter + 1'b1;
                    end
                end

                ENG_COMP_DONE: begin
                    // One final clock cycle to allow the last MAC addition to register
                    mac_enable        <= 1'b0;
                    core_compute_done <= 1'b1;
                    eng_state         <= ENG_IDLE;
                end

                ENG_DRAIN_RUN: begin
                    // Latch all 16 MAC accumulator outputs and store in output RAM
                    for (int c = 0; c < COUT_CHANNELS; c++) begin
                        drained_accum[c] <= mac_accum_out[c];
                        out_ram[latched_tile_idx * COUT_CHANNELS + c] <= mac_accum_out[c];
                    end
                    drain_tile_idx   <= latched_tile_idx;
                    drain_pulse_r    <= 1'b1;
                    core_drain_ready <= 1'b1;
                    eng_state        <= ENG_DRAIN_DONE;
                end

                ENG_DRAIN_DONE: begin
                    core_drain_done <= 1'b1;
                    eng_state       <= ENG_IDLE;
                end

                default: eng_state <= ENG_IDLE;
            endcase
        end
    end

endmodule
