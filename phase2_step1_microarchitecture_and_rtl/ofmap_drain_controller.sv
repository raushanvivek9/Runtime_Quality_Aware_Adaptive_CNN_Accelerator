// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-11 Phase 2A Standalone OFMAP Drain Controller
// Module: ofmap_drain_controller.sv
// Description: Synthesizable Output Feature Map (OFMAP) Drain Controller.
//              Serializes 64 signed 40-bit accumulator outputs from the 4x16 PE array
//              into 128 32-bit words written to the multi-bank SRAM subsystem.
//
// Protocol & Specification:
//   - Input: 64 signed 40-bit accumulators arranged as 4 rows x 16 columns.
//   - Capture: Latches inputs into internal shadow registers at drain_start.
//   - Output Serialization: Row-major order (Row 0..3, Col 0..15).
//     * For each PE coordinate (r, c):
//       - Word 2i   = accum[31:0] (Lower 32-bit word)
//       - Word 2i+1 = {{24{accum[39]}}, accum[39:32]} (Sign-extended upper word)
//   - Total Words: 128 words (512 bytes).
//   - Handshake: Advances word index only upon confirmed write acceptance
//     (sram_wr_req && sram_wr_ready).
//   - Backpressure & Stalls: Holds request, address, data, and byte enables
//     strictly stable while stalled.
//   - Completion: Asserts a 1-cycle drain_done pulse after word 127 is accepted.
//   - Parameter Validation: Validates that base_addr + 128 does not exceed
//     physical SRAM macro capacity (10,368 words). Rejects out-of-bounds start.
// =============================================================================

`timescale 1ns / 1ps

module ofmap_drain_controller #(
    parameter int ROWS              = 4,
    parameter int COLS              = 16,
    parameter int ACCUM_WIDTH       = 40,
    parameter int SRAM_ADDR_W       = 14,
    parameter int DATA_WIDTH        = 32,
    parameter logic [SRAM_ADDR_W-1:0] DEFAULT_BASE_ADDR = 14'h2000
)(
    input  logic                                            clk,
    input  logic                                            rst_n,

    // -------------------------------------------------------------------------
    // Control and Status Interface
    // -------------------------------------------------------------------------
    input  logic [1:0]                                      cfg_mode,
    input  logic                                            drain_start,
    input  logic [SRAM_ADDR_W-1:0]                         base_addr,
    output logic                                            drain_busy,
    output logic                                            drain_done,
    output logic                                            drain_error_flag,
    input  logic                                            error_clear,
    output logic                                            busy_reject_pulse,
    output logic [7:0]                                      words_written_count,

    // -------------------------------------------------------------------------
    // 64 Signed 40-bit Accumulator Inputs (pe_array_40b)
    // -------------------------------------------------------------------------
    input  logic signed [ACCUM_WIDTH-1:0]                  accum_out [0:ROWS-1][0:COLS-1],

    // -------------------------------------------------------------------------
    // Native Multi-Bank SRAM Port A Write Interface (multibank_sram_subsystem)
    // -------------------------------------------------------------------------
    output logic                                            sram_wr_req,
    output logic [SRAM_ADDR_W-1:0]                         sram_wr_addr,
    output logic [DATA_WIDTH-1:0]                          sram_wr_din,
    output logic [(DATA_WIDTH/8)-1:0]                      sram_wr_byte_we,
    input  logic                                            sram_wr_ready,
    input  logic                                            sram_wr_ack
);

    localparam int TOTAL_PES        = ROWS * COLS;        // 64
    localparam int TOTAL_WORDS      = TOTAL_PES * 2;      // 128
    localparam int MAX_LEGAL_WORDS  = 10368;              // 8 banks x 1296 words/bank

    // Safe mode resolution: fallback to 64-PE (2'b10) if unconnected (2'bz), unknown (2'bx), or 2'b11
    wire [1:0] effective_mode_in = (cfg_mode === 2'b00) ? 2'b00 :
                                   (cfg_mode === 2'b01) ? 2'b01 :
                                   2'b10;

    // FSM State Encoding
    typedef enum logic [1:0] {
        ST_IDLE  = 2'b00,
        ST_WRITE = 2'b01,
        ST_DONE  = 2'b10
    } state_t;

    state_t state_q, state_d;

    // Registers
    logic [1:0]                             cfg_mode_q, cfg_mode_d;
    logic [SRAM_ADDR_W-1:0]                 base_addr_q, base_addr_d;
    logic [6:0]                             word_idx_q, word_idx_d;       // 0 to 127
    logic [7:0]                             words_cnt_q, words_cnt_d;     // 0 to 128
    logic signed [ACCUM_WIDTH-1:0]          accum_shadow_q [0:ROWS-1][0:COLS-1];
    logic signed [ACCUM_WIDTH-1:0]          accum_shadow_d [0:ROWS-1][0:COLS-1];
    logic                                   busy_reject_d;
    logic                                   error_flag_q, error_flag_d;

    // Mode-dependent word counts
    wire [7:0] mode_total_words_active = (cfg_mode_q == 2'b00) ? 8'd32 :
                                         (cfg_mode_q == 2'b01) ? 8'd64 :
                                         8'd128;
    wire [6:0] mode_last_word_idx      = mode_total_words_active[6:0] - 1'b1;

    // Word unpacking logic
    wire [5:0] pe_idx  = word_idx_q[6:1];    // 0 to 63
    wire [1:0] row_idx_16 = pe_idx[3:2];
    wire [3:0] col_idx_16 = {2'b00, pe_idx[1:0]};
    wire [1:0] row_idx_32 = pe_idx[4:3];
    wire [3:0] col_idx_32 = {1'b0, pe_idx[2:0]};
    wire [1:0] row_idx_64 = pe_idx[5:4];
    wire [3:0] col_idx_64 = pe_idx[3:0];

    wire [1:0] row_idx = (cfg_mode_q == 2'b00) ? row_idx_16 :
                         (cfg_mode_q == 2'b01) ? row_idx_32 :
                         row_idx_64;

    wire [3:0] col_idx = (cfg_mode_q == 2'b00) ? col_idx_16 :
                         (cfg_mode_q == 2'b01) ? col_idx_32 :
                         col_idx_64;

    wire       is_hi   = word_idx_q[0];      // 0: low word, 1: high word

    logic signed [ACCUM_WIDTH-1:0] cur_accum;
    assign cur_accum = accum_shadow_q[row_idx][col_idx];

    wire [DATA_WIDTH-1:0] cur_data = (!is_hi) ? cur_accum[31:0] : {{24{cur_accum[39]}}, cur_accum[39:32]};

    // Address validity check for start command
    wire [SRAM_ADDR_W:0] start_mode_total_words = (effective_mode_in == 2'b00) ? 15'd32 :
                                                  (effective_mode_in == 2'b01) ? 15'd64 :
                                                  15'd128;
    wire [SRAM_ADDR_W:0] target_end_addr = {1'b0, base_addr_d} + start_mode_total_words;
    wire is_addr_oob = (target_end_addr > 15'd10368);

    // Status assignments
    assign drain_busy          = (state_q != ST_IDLE);
    assign drain_done          = (state_q == ST_DONE);
    assign drain_error_flag    = error_flag_q;
    assign words_written_count = words_cnt_q;

    // Combinational Next-State and Output Logic
    always_comb begin
        state_d         = state_q;
        cfg_mode_d      = cfg_mode_q;
        base_addr_d     = base_addr_q;
        word_idx_d      = word_idx_q;
        words_cnt_d     = words_cnt_q;
        busy_reject_d   = 1'b0;
        error_flag_d    = error_flag_q;

        if (error_clear) begin
            error_flag_d = 1'b0;
        end

        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                accum_shadow_d[r][c] = accum_shadow_q[r][c];
            end
        end

        // Default SRAM write bus outputs
        sram_wr_req     = 1'b0;
        sram_wr_addr    = '0;
        sram_wr_din     = '0;
        sram_wr_byte_we = '0;

        case (state_q)
            // -----------------------------------------------------------------
            // ST_IDLE: Awaiting drain_start command
            // -----------------------------------------------------------------
            ST_IDLE: begin
                if (drain_start) begin
                    // Latch configured base address (or default if zero)
                    base_addr_d = (base_addr != '0) ? base_addr : DEFAULT_BASE_ADDR;
                    cfg_mode_d  = effective_mode_in;

                    // Validate that base address + mode words fits inside physical SRAM
                    if (is_addr_oob) begin
                        // Out-of-bounds base address: flag error and remain in IDLE
                        error_flag_d = 1'b1;
                        state_d      = ST_IDLE;
                    end else begin
                        error_flag_d = 1'b0;
                        // Latch all 64 accumulator inputs into shadow registers
                        for (int r = 0; r < ROWS; r = r + 1) begin
                            for (int c = 0; c < COLS; c = c + 1) begin
                                accum_shadow_d[r][c] = accum_out[r][c];
                            end
                        end
                        word_idx_d  = 7'd0;
                        words_cnt_d = 8'd0;
                        state_d     = ST_WRITE;
                    end
                end
            end

            // -----------------------------------------------------------------
            // ST_WRITE: Serializing mode-dependent words to SRAM Port A
            // -----------------------------------------------------------------
            ST_WRITE: begin
                // Reject/flag any spurious start requests while actively draining
                if (drain_start) begin
                    busy_reject_d = 1'b1;
                end

                // Assert SRAM Port A write request
                sram_wr_req     = 1'b1;
                sram_wr_addr    = base_addr_q + {7'd0, word_idx_q};
                sram_wr_din     = cur_data;
                sram_wr_byte_we = 4'b1111; // Full 32-bit word write

                // Write Acceptance Handshake: accepted on posedge clk when sram_wr_ready is high
                if (sram_wr_ready) begin
                    words_cnt_d = words_cnt_q + 1'b1;
                    if (word_idx_q == mode_last_word_idx) begin
                        // All required words accepted! Complete the drain.
                        state_d = ST_DONE;
                    end else begin
                        word_idx_d = word_idx_q + 1'b1;
                    end
                end
                // If sram_wr_ready is low: hold address, data, and word_idx_q unchanged.
            end

            // -----------------------------------------------------------------
            // ST_DONE: 1-cycle completion pulse signaling tile commit
            // -----------------------------------------------------------------
            ST_DONE: begin
                if (drain_start) begin
                    busy_reject_d = 1'b1;
                end
                state_d = ST_IDLE;
            end

            default: state_d = ST_IDLE;
        endcase
    end

    // Sequential Registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q           <= ST_IDLE;
            cfg_mode_q        <= 2'b10;
            base_addr_q       <= DEFAULT_BASE_ADDR;
            word_idx_q        <= 7'd0;
            words_cnt_q       <= 8'd0;
            busy_reject_pulse <= 1'b0;
            error_flag_q      <= 1'b0;
            for (int r = 0; r < ROWS; r = r + 1) begin
                for (int c = 0; c < COLS; c = c + 1) begin
                    accum_shadow_q[r][c] <= '0;
                end
            end
        end else begin
            state_q           <= state_d;
            cfg_mode_q        <= cfg_mode_d;
            base_addr_q       <= base_addr_d;
            word_idx_q        <= word_idx_d;
            words_cnt_q       <= words_cnt_d;
            busy_reject_pulse <= busy_reject_d;
            error_flag_q      <= error_flag_d;
            for (int r = 0; r < ROWS; r = r + 1) begin
                for (int c = 0; c < COLS; c = c + 1) begin
                    accum_shadow_q[r][c] <= accum_shadow_d[r][c];
                end
            end
        end
    end

endmodule
