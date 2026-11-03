// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-09 Parallel PE Operand Delivery
// Module: datapath_compute_feeder.sv
// Description: Synthesizable Autonomous SRAM Buffer Compute Feeder supporting
//              both legacy single-MAC broadcast and full 4x16 parallel operand
//              delivery (4 independent row activations and 16 independent
//              column weights) via multibank_sram_subsystem 8 read ports.
// =============================================================================

`timescale 1ns / 1ps

module datapath_compute_feeder #(
    parameter int SRAM_ADDR_W           = 14,
    parameter int DATA_WIDTH            = 32,
    parameter int ACT_WIDTH             = 16,
    parameter int WEIGHT_WIDTH          = 16,
    parameter int ROWS                  = 4,
    parameter int COLS                  = 16,
    parameter int K_WIDTH               = 16,
    parameter int NUM_BANKS             = 8,
    parameter bit [13:0] BUF_A_BASE     = 14'h0000,
    parameter bit [13:0] BUF_B_BASE     = 14'h1000,
    parameter bit PARALLEL_OPERAND_MODE = 1'b0,
    parameter bit SPARSE_OPERAND_MODE   = 1'b0
)(
    input  logic                                clk,
    input  logic                                rst_n,

    // Runtime mode configuration (forces parallel mode when high)
    input  logic                                cfg_parallel_en,
    input  logic [1:0]                          cfg_mode,
    input  logic                                cfg_sparse_en,

    // -------------------------------------------------------------------------
    // Sequencer Handshake Interface (layer_command_sequencer)
    // -------------------------------------------------------------------------
    input  logic                                compute_start,
    input  logic [K_WIDTH-1:0]                  compute_k_total,
    input  logic                                buf_consumer_buf_id, // 0: Buffer A, 1: Buffer B
    input  logic                                pe_layer_quiescent,  // From adaptive_pe_controller
    output logic                                compute_done,
    output logic                                drain_done,
    output logic                                feeder_busy,

    // -------------------------------------------------------------------------
    // Adaptive PE Controller Handshake (adaptive_pe_controller)
    // -------------------------------------------------------------------------
    output logic                                compute_enable_in,

    // -------------------------------------------------------------------------
    // Multi-Bank SRAM Read Channels (multibank_sram_subsystem Port B0..B7)
    // -------------------------------------------------------------------------
    output logic [NUM_BANKS-1:0]                sram_rd_req_bus,
    output logic [SRAM_ADDR_W-1:0]              sram_rd_addr_bus [0:NUM_BANKS-1],
    input  logic [NUM_BANKS-1:0]                sram_rd_ready_bus,
    input  logic [NUM_BANKS-1:0]                sram_rd_rvalid_bus,
    input  logic [DATA_WIDTH-1:0]               sram_rd_dout_bus [0:NUM_BANKS-1],

    // -------------------------------------------------------------------------
    // Backward-Compatible Scalar Datapath Operands
    // -------------------------------------------------------------------------
    output logic                                broadcast_act,
    output wire signed [ACT_WIDTH-1:0]          act_sample,
    output wire                                 act_mask_sample,
    output wire signed [WEIGHT_WIDTH-1:0]       weight_sample,

    // -------------------------------------------------------------------------
    // Parallel Vector Datapath Operands (pe_array_40b)
    // -------------------------------------------------------------------------
    output logic signed [ACT_WIDTH-1:0]         act_data_row    [0:ROWS-1],
    output logic                                act_mask_row    [0:ROWS-1],
    output logic signed [WEIGHT_WIDTH-1:0]      weight_data_col [0:COLS-1],

    output logic [K_WIDTH-1:0]                  k_executed_count
);

    // Active operating mode
    wire is_parallel = (PARALLEL_OPERAND_MODE == 1'b1) || (cfg_parallel_en === 1'b1);
    wire is_sparse   = is_parallel && ((SPARSE_OPERAND_MODE == 1'b1) || (cfg_sparse_en === 1'b1));

    // Safe mode resolution: fallback to 64-PE (2'b10) if unconnected (2'bz), unknown (2'bx), or 2'b11
    wire [1:0] effective_mode_in = (cfg_mode === 2'b00) ? 2'b00 :
                                   (cfg_mode === 2'b01) ? 2'b01 :
                                   2'b10;

    // Backward-compatible signal probes for testbench hierarchical access
    wire                  sram_rd_rvalid = sram_rd_rvalid_bus[0];
    wire [DATA_WIDTH-1:0] sram_rd_dout   = sram_rd_dout_bus[0];
    wire                  sram_rd_ready  = sram_rd_ready_bus[0];
    wire                  sram_rd_req    = sram_rd_req_bus[0];
    wire [SRAM_ADDR_W-1:0] sram_rd_addr  = sram_rd_addr_bus[0];

    // State machine encoding
    typedef enum logic [3:0] {
        ST_IDLE          = 4'd0,
        ST_FETCH         = 4'd1, // Legacy scalar fetch
        ST_PAR_REQ_W     = 4'd2, // Dense: Request mode-dependent weight words
        ST_PAR_REQ_A     = 4'd3, // Dense: Request 2 activation words (latch weights)
        ST_PAR_COMPUTE   = 4'd4, // Dense: Deliver operands & pulse compute_enable
        ST_COMP_DONE     = 4'd5,
        ST_DRAIN         = 4'd6,
        ST_SPARSE_REQ_A  = 4'd7, // Sparse: Request 2 activation words
        ST_SPARSE_WAIT_A = 4'd8, // Sparse: Evaluate activations & skip or request weights
        ST_SPARSE_REQ_W  = 4'd9, // Sparse: Request weights (if backpressured)
        ST_SPARSE_COMP   = 4'd10 // Sparse: Latch weights and execute compute
    } feeder_state_t;

    feeder_state_t state_q, state_d;

    // Latched control registers
    logic [1:0]               cfg_mode_q,   cfg_mode_d;
    logic [K_WIDTH-1:0]       k_total_q,    k_total_d;
    logic                     active_buf_q, active_buf_d;
    logic [K_WIDTH-1:0]       req_cnt_q,    req_cnt_d;
    logic [K_WIDTH-1:0]       exec_cnt_q,   exec_cnt_d;

    // Active base address
    wire [SRAM_ADDR_W-1:0]    active_base = (active_buf_q == 1'b0) ? BUF_A_BASE : BUF_B_BASE;

    // -------------------------------------------------------------------------
    // Parallel Mode Staging Registers & Continuous Slices
    // -------------------------------------------------------------------------
    logic signed [WEIGHT_WIDTH-1:0] weight_stage_q [0:COLS-1], weight_stage_d [0:COLS-1];
    logic signed [ACT_WIDTH-1:0]    act_stage_q    [0:ROWS-1], act_stage_d    [0:ROWS-1];
    logic                           act_mask_stage_q [0:ROWS-1], act_mask_stage_d [0:ROWS-1];

    // Combinational activation wire from SRAM read data
    wire signed [ACT_WIDTH-1:0] act_wire [0:ROWS-1];
    assign act_wire[0] = sram_rd_dout_bus[0][15:0];
    assign act_wire[1] = sram_rd_dout_bus[0][31:16];
    assign act_wire[2] = sram_rd_dout_bus[1][15:0];
    assign act_wire[3] = sram_rd_dout_bus[1][31:16];

    // Zero-activation detection
    wire act_zero_0 = (act_wire[0] == 16'd0);
    wire act_zero_1 = (act_wire[1] == 16'd0);
    wire act_zero_2 = (act_wire[2] == 16'd0);
    wire act_zero_3 = (act_wire[3] == 16'd0);
    wire all_acts_zero = act_zero_0 && act_zero_1 && act_zero_2 && act_zero_3;

    // Continuous weight slices from each bank's read data
    wire signed [WEIGHT_WIDTH-1:0] sram_wt_lo [0:NUM_BANKS-1];
    wire signed [WEIGHT_WIDTH-1:0] sram_wt_hi [0:NUM_BANKS-1];
    genvar g_b;
    generate
        for (g_b = 0; g_b < NUM_BANKS; g_b = g_b + 1) begin : gen_wt_slice
            assign sram_wt_lo[g_b] = sram_rd_dout_bus[g_b][15:0];
            assign sram_wt_hi[g_b] = sram_rd_dout_bus[g_b][31:16];
        end
    endgenerate

    // Mode-dependent ready and rvalid reductions (avoids constant part-selects in always_comb)
    wire ready_16   = sram_rd_ready_bus[0] & sram_rd_ready_bus[1];
    wire ready_32   = sram_rd_ready_bus[0] & sram_rd_ready_bus[1] & sram_rd_ready_bus[2] & sram_rd_ready_bus[3];
    wire ready_64   = &sram_rd_ready_bus;

    wire rvalid_16  = sram_rd_rvalid_bus[0] & sram_rd_rvalid_bus[1];
    wire rvalid_32  = sram_rd_rvalid_bus[0] & sram_rd_rvalid_bus[1] & sram_rd_rvalid_bus[2] & sram_rd_rvalid_bus[3];
    wire rvalid_64  = &sram_rd_rvalid_bus;

    wire act_ready  = sram_rd_ready_bus[0] & sram_rd_ready_bus[1];
    wire act_rvalid = sram_rd_rvalid_bus[0] & sram_rd_rvalid_bus[1];

    wire wt_rvalid_mode = (cfg_mode_q == 2'b00) ? rvalid_16 :
                          (cfg_mode_q == 2'b01) ? rvalid_32 :
                          rvalid_64;

    // -------------------------------------------------------------------------
    // Legacy Scalar Slices from Port 0
    // -------------------------------------------------------------------------
    wire [ACT_WIDTH-1:0]      sram_act_sample    = sram_rd_dout_bus[0][ACT_WIDTH-1:0];
    wire [WEIGHT_WIDTH-1:0]   sram_weight_sample = sram_rd_dout_bus[0][DATA_WIDTH-1:ACT_WIDTH];

    assign broadcast_act    = 1'b1;
    assign feeder_busy      = (state_q != ST_IDLE);
    assign k_executed_count = exec_cnt_q;

    // Scalar sample outputs
    assign act_sample       = (sram_rd_rvalid_bus[0] && (state_q == ST_FETCH)) ? sram_act_sample : '0;
    assign act_mask_sample  = (sram_rd_rvalid_bus[0] && (state_q == ST_FETCH));
    assign weight_sample    = (sram_rd_rvalid_bus[0] && (state_q == ST_FETCH)) ? sram_weight_sample : '0;

    // -------------------------------------------------------------------------
    // Combinational Sparse Mode Weight Decode
    // -------------------------------------------------------------------------
    logic signed [WEIGHT_WIDTH-1:0] weight_sparse_comb [0:COLS-1];
    always_comb begin
        for (int c = 0; c < COLS; c = c + 1) begin
            weight_sparse_comb[c] = '0;
        end
        if (cfg_mode_q == 2'b00) begin
            weight_sparse_comb[0] = sram_wt_lo[0];
            weight_sparse_comb[1] = sram_wt_hi[0];
            weight_sparse_comb[2] = sram_wt_lo[1];
            weight_sparse_comb[3] = sram_wt_hi[1];
        end else if (cfg_mode_q == 2'b01) begin
            weight_sparse_comb[0] = sram_wt_lo[0];
            weight_sparse_comb[1] = sram_wt_hi[0];
            weight_sparse_comb[2] = sram_wt_lo[1];
            weight_sparse_comb[3] = sram_wt_hi[1];
            weight_sparse_comb[4] = sram_wt_lo[2];
            weight_sparse_comb[5] = sram_wt_hi[2];
            weight_sparse_comb[6] = sram_wt_lo[3];
            weight_sparse_comb[7] = sram_wt_hi[3];
        end else begin
            for (int w_i = 0; w_i < 8; w_i = w_i + 1) begin
                weight_sparse_comb[w_i*2]     = sram_wt_lo[w_i];
                weight_sparse_comb[w_i*2 + 1] = sram_wt_hi[w_i];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Vector Operands Output Multiplexing
    // -------------------------------------------------------------------------
    always_comb begin
        if (is_parallel) begin
            for (int r = 0; r < ROWS; r = r + 1) begin
                act_data_row[r] = (state_q == ST_PAR_COMPUTE) ? act_wire[r] :
                                  (state_q == ST_SPARSE_COMP)  ? act_stage_q[r] : '0;
                act_mask_row[r] = (state_q == ST_PAR_COMPUTE) ? act_rvalid :
                                  (state_q == ST_SPARSE_COMP)  ? act_mask_stage_q[r] : 1'b0;
            end
            for (int c = 0; c < COLS; c = c + 1) begin
                weight_data_col[c] = (state_q == ST_SPARSE_COMP) ? weight_sparse_comb[c] : weight_stage_q[c];
            end
        end else begin
            for (int r = 0; r < ROWS; r = r + 1) begin
                act_data_row[r] = act_sample;
                act_mask_row[r] = act_mask_sample;
            end
            for (int c = 0; c < COLS; c = c + 1) begin
                weight_data_col[c] = weight_sample;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Combinational Next-State & SRAM Request Generation
    // -------------------------------------------------------------------------
    always_comb begin
        state_d           = state_q;
        k_total_d         = k_total_q;
        active_buf_d      = active_buf_q;
        cfg_mode_d        = cfg_mode_q;
        req_cnt_d         = req_cnt_q;
        exec_cnt_d        = exec_cnt_q;

        for (int c = 0; c < COLS; c = c + 1) begin
            weight_stage_d[c] = weight_stage_q[c];
        end

        for (int r = 0; r < ROWS; r = r + 1) begin
            act_stage_d[r]      = act_stage_q[r];
            act_mask_stage_d[r] = act_mask_stage_q[r];
        end

        compute_done      = 1'b0;
        drain_done        = 1'b0;
        compute_enable_in = 1'b0;

        // Default: SRAM read ports idle
        sram_rd_req_bus   = '0;
        for (int p = 0; p < NUM_BANKS; p = p + 1) begin
            sram_rd_addr_bus[p] = '0;
        end

        case (state_q)
            ST_IDLE: begin
                if (compute_start) begin
                    k_total_d    = compute_k_total;
                    active_buf_d = buf_consumer_buf_id;
                    cfg_mode_d   = effective_mode_in;
                    req_cnt_d    = '0;
                    exec_cnt_d   = '0;
                    if (is_sparse) begin
                        state_d = ST_SPARSE_REQ_A;
                    end else if (is_parallel) begin
                        state_d = ST_PAR_REQ_W;
                    end else begin
                        state_d = ST_FETCH;
                    end
                end
            end

            // =================================================================
            // 1. Legacy Scalar Mode Fetch
            // =================================================================
            ST_FETCH: begin
                sram_rd_req_bus     = ((req_cnt_q < k_total_q) && sram_rd_ready_bus[0]) ? 8'b0000_0001 : 8'b0000_0000;
                sram_rd_addr_bus[0] = active_base + req_cnt_q;

                if (sram_rd_req_bus[0] && sram_rd_ready_bus[0]) begin
                    req_cnt_d = req_cnt_q + 1'b1;
                end

                if (sram_rd_rvalid_bus[0]) begin
                    compute_enable_in = 1'b1;
                    exec_cnt_d        = exec_cnt_q + 1'b1;
                    if (exec_cnt_q + 1'b1 == k_total_q) begin
                        state_d = ST_COMP_DONE;
                    end
                end
            end

            // =================================================================
            // 2. Parallel 4x16 Mode: Phase A - Request Mode-Dependent Weight Words
            // =================================================================
            ST_PAR_REQ_W: begin
                if (cfg_mode_q == 2'b00) begin
                    // 16-PE Mode: Fetch only Words 0 and 1 (Columns 0..3)
                    sram_rd_req_bus     = 8'b0000_0011;
                    sram_rd_addr_bus[0] = active_base + (req_cnt_q * 10) + 0;
                    sram_rd_addr_bus[1] = active_base + (req_cnt_q * 10) + 1;

                    if (ready_16) begin
                        state_d = ST_PAR_REQ_A;
                    end
                end else if (cfg_mode_q == 2'b01) begin
                    // 32-PE Mode: Fetch only Words 0..3 (Columns 0..7)
                    sram_rd_req_bus     = 8'b0000_1111;
                    for (int b_i = 0; b_i < 4; b_i = b_i + 1) begin
                        sram_rd_addr_bus[b_i] = active_base + (req_cnt_q * 10) + b_i;
                    end

                    if (ready_32) begin
                        state_d = ST_PAR_REQ_A;
                    end
                end else begin
                    // 64-PE Mode (or fallback): Fetch all 8 weight words
                    sram_rd_req_bus     = 8'b1111_1111;
                    for (int b_i = 0; b_i < NUM_BANKS; b_i = b_i + 1) begin
                        sram_rd_addr_bus[b_i] = active_base + (req_cnt_q * 10) + b_i;
                    end

                    if (ready_64) begin
                        state_d = ST_PAR_REQ_A;
                    end
                end
            end

            // =================================================================
            // 2. Parallel 4x16 Mode: Phase B - Request 2 Activation Words
            //    (Simultaneously latch returning mode-dependent weight words)
            // =================================================================
            ST_PAR_REQ_A: begin
                sram_rd_req_bus     = 8'b0000_0011;
                sram_rd_addr_bus[0] = active_base + (req_cnt_q * 10) + 8;
                sram_rd_addr_bus[1] = active_base + (req_cnt_q * 10) + 9;

                if (cfg_mode_q == 2'b00) begin
                    // 16-PE Mode: Latch weights for Columns 0..3; clamp 4..15 to 0
                    if (rvalid_16) begin
                        weight_stage_d[0] = sram_wt_lo[0];
                        weight_stage_d[1] = sram_wt_hi[0];
                        weight_stage_d[2] = sram_wt_lo[1];
                        weight_stage_d[3] = sram_wt_hi[1];
                        for (int c = 4; c < COLS; c = c + 1) begin
                            weight_stage_d[c] = '0;
                        end
                    end
                end else if (cfg_mode_q == 2'b01) begin
                    // 32-PE Mode: Latch weights for Columns 0..7; clamp 8..15 to 0
                    if (rvalid_32) begin
                        weight_stage_d[0] = sram_wt_lo[0];
                        weight_stage_d[1] = sram_wt_hi[0];
                        weight_stage_d[2] = sram_wt_lo[1];
                        weight_stage_d[3] = sram_wt_hi[1];
                        weight_stage_d[4] = sram_wt_lo[2];
                        weight_stage_d[5] = sram_wt_hi[2];
                        weight_stage_d[6] = sram_wt_lo[3];
                        weight_stage_d[7] = sram_wt_hi[3];
                        for (int c = 8; c < COLS; c = c + 1) begin
                            weight_stage_d[c] = '0;
                        end
                    end
                end else begin
                    // 64-PE Mode: Latch weights for all 16 columns
                    if (rvalid_64) begin
                        weight_stage_d[0]  = sram_wt_lo[0];
                        weight_stage_d[1]  = sram_wt_hi[0];
                        weight_stage_d[2]  = sram_wt_lo[1];
                        weight_stage_d[3]  = sram_wt_hi[1];
                        weight_stage_d[4]  = sram_wt_lo[2];
                        weight_stage_d[5]  = sram_wt_hi[2];
                        weight_stage_d[6]  = sram_wt_lo[3];
                        weight_stage_d[7]  = sram_wt_hi[3];
                        weight_stage_d[8]  = sram_wt_lo[4];
                        weight_stage_d[9]  = sram_wt_hi[4];
                        weight_stage_d[10] = sram_wt_lo[5];
                        weight_stage_d[11] = sram_wt_hi[5];
                        weight_stage_d[12] = sram_wt_lo[6];
                        weight_stage_d[13] = sram_wt_hi[6];
                        weight_stage_d[14] = sram_wt_lo[7];
                        weight_stage_d[15] = sram_wt_hi[7];
                    end
                end

                if (act_ready) begin
                    state_d = ST_PAR_COMPUTE;
                end
            end

            // =================================================================
            // 2. Parallel 4x16 Mode: Phase C - Deliver Activations & Compute
            // =================================================================
            ST_PAR_COMPUTE: begin
                if (act_rvalid) begin
                    compute_enable_in = 1'b1;
                    exec_cnt_d        = exec_cnt_q + 1'b1;
                    req_cnt_d         = req_cnt_q + 1'b1;

                    if (exec_cnt_q + 1'b1 == k_total_q) begin
                        state_d = ST_COMP_DONE;
                    end else begin
                        state_d = ST_PAR_REQ_W;
                    end
                end
            end

            // =================================================================
            // 3. Sparse Parallel 4x16 Mode: Activation-First Scheduling
            // =================================================================
            ST_SPARSE_REQ_A: begin
                sram_rd_req_bus     = 8'b0000_0011;
                sram_rd_addr_bus[0] = active_base + (req_cnt_q * 10) + 8;
                sram_rd_addr_bus[1] = active_base + (req_cnt_q * 10) + 9;

                if (act_ready) begin
                    state_d = ST_SPARSE_WAIT_A;
                end
            end

            ST_SPARSE_WAIT_A: begin
                if (act_rvalid) begin
                    if (all_acts_zero) begin
                        // Exact-zero step: all 4 rows are 0. Skip weights and compute!
                        exec_cnt_d = exec_cnt_q + 1'b1;
                        req_cnt_d  = req_cnt_q + 1'b1;

                        if (exec_cnt_q + 1'b1 == k_total_q) begin
                            state_d = ST_COMP_DONE;
                        end else begin
                            // Stream next activation request
                            sram_rd_req_bus     = 8'b0000_0011;
                            sram_rd_addr_bus[0] = active_base + ((req_cnt_q + 1'b1) * 10) + 8;
                            sram_rd_addr_bus[1] = active_base + ((req_cnt_q + 1'b1) * 10) + 9;
                            if (act_ready) begin
                                state_d = ST_SPARSE_WAIT_A;
                            end else begin
                                state_d = ST_SPARSE_REQ_A;
                            end
                        end
                    end else begin
                        // At least one row has non-zero activation: latch activations & request weights
                        act_stage_d[0]      = act_wire[0];
                        act_stage_d[1]      = act_wire[1];
                        act_stage_d[2]      = act_wire[2];
                        act_stage_d[3]      = act_wire[3];
                        act_mask_stage_d[0] = 1'b1;
                        act_mask_stage_d[1] = 1'b1;
                        act_mask_stage_d[2] = 1'b1;
                        act_mask_stage_d[3] = 1'b1;

                        if (cfg_mode_q == 2'b00) begin
                            sram_rd_req_bus     = 8'b0000_0011;
                            sram_rd_addr_bus[0] = active_base + (req_cnt_q * 10) + 0;
                            sram_rd_addr_bus[1] = active_base + (req_cnt_q * 10) + 1;
                            if (ready_16) begin
                                state_d = ST_SPARSE_COMP;
                            end else begin
                                state_d = ST_SPARSE_REQ_W;
                            end
                        end else if (cfg_mode_q == 2'b01) begin
                            sram_rd_req_bus     = 8'b0000_1111;
                            for (int b_i = 0; b_i < 4; b_i = b_i + 1) begin
                                sram_rd_addr_bus[b_i] = active_base + (req_cnt_q * 10) + b_i;
                            end
                            if (ready_32) begin
                                state_d = ST_SPARSE_COMP;
                            end else begin
                                state_d = ST_SPARSE_REQ_W;
                            end
                        end else begin
                            sram_rd_req_bus     = 8'b1111_1111;
                            for (int b_i = 0; b_i < NUM_BANKS; b_i = b_i + 1) begin
                                sram_rd_addr_bus[b_i] = active_base + (req_cnt_q * 10) + b_i;
                            end
                            if (ready_64) begin
                                state_d = ST_SPARSE_COMP;
                            end else begin
                                state_d = ST_SPARSE_REQ_W;
                            end
                        end
                    end
                end
            end

            ST_SPARSE_REQ_W: begin
                // Hold weight read request until SRAM is ready
                if (cfg_mode_q == 2'b00) begin
                    sram_rd_req_bus     = 8'b0000_0011;
                    sram_rd_addr_bus[0] = active_base + (req_cnt_q * 10) + 0;
                    sram_rd_addr_bus[1] = active_base + (req_cnt_q * 10) + 1;
                    if (ready_16) state_d = ST_SPARSE_COMP;
                end else if (cfg_mode_q == 2'b01) begin
                    sram_rd_req_bus     = 8'b0000_1111;
                    for (int b_i = 0; b_i < 4; b_i = b_i + 1) begin
                        sram_rd_addr_bus[b_i] = active_base + (req_cnt_q * 10) + b_i;
                    end
                    if (ready_32) state_d = ST_SPARSE_COMP;
                end else begin
                    sram_rd_req_bus     = 8'b1111_1111;
                    for (int b_i = 0; b_i < NUM_BANKS; b_i = b_i + 1) begin
                        sram_rd_addr_bus[b_i] = active_base + (req_cnt_q * 10) + b_i;
                    end
                    if (ready_64) state_d = ST_SPARSE_COMP;
                end
            end

            ST_SPARSE_COMP: begin
                if (wt_rvalid_mode) begin
                    compute_enable_in = 1'b1;
                    exec_cnt_d        = exec_cnt_q + 1'b1;
                    req_cnt_d         = req_cnt_q + 1'b1;

                    for (int c = 0; c < COLS; c = c + 1) begin
                        weight_stage_d[c] = weight_sparse_comb[c];
                    end

                    if (exec_cnt_q + 1'b1 == k_total_q) begin
                        state_d = ST_COMP_DONE;
                    end else begin
                        sram_rd_req_bus     = 8'b0000_0011;
                        sram_rd_addr_bus[0] = active_base + ((req_cnt_q + 1'b1) * 10) + 8;
                        sram_rd_addr_bus[1] = active_base + ((req_cnt_q + 1'b1) * 10) + 9;
                        if (act_ready) begin
                            state_d = ST_SPARSE_WAIT_A;
                        end else begin
                            state_d = ST_SPARSE_REQ_A;
                        end
                    end
                end
            end

            // =================================================================
            // Completion & Barrier Handshake
            // =================================================================
            ST_COMP_DONE: begin
                compute_done = 1'b1;
                state_d      = ST_DRAIN;
            end

            ST_DRAIN: begin
                drain_done = 1'b1;
                if (pe_layer_quiescent) begin
                    state_d = ST_IDLE;
                end
            end

            default: state_d = ST_IDLE;
        endcase
    end

    // Sequential registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q        <= ST_IDLE;
            k_total_q      <= '0;
            active_buf_q   <= 1'b0;
            cfg_mode_q     <= 2'b10;
            req_cnt_q      <= '0;
            exec_cnt_q     <= '0;
            for (int c = 0; c < COLS; c = c + 1) begin
                weight_stage_q[c] <= '0;
            end
            for (int r = 0; r < ROWS; r = r + 1) begin
                act_stage_q[r]      <= '0;
                act_mask_stage_q[r] <= 1'b0;
            end
        end else begin
            state_q        <= state_d;
            k_total_q      <= k_total_d;
            active_buf_q   <= active_buf_d;
            cfg_mode_q     <= cfg_mode_d;
            req_cnt_q      <= req_cnt_d;
            exec_cnt_q     <= exec_cnt_d;
            for (int c = 0; c < COLS; c = c + 1) begin
                weight_stage_q[c] <= weight_stage_d[c];
            end
            for (int r = 0; r < ROWS; r = r + 1) begin
                act_stage_q[r]      <= act_stage_d[r];
                act_mask_stage_q[r] <= act_mask_stage_d[r];
            end
        end
    end

endmodule
