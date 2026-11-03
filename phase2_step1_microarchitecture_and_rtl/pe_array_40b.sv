// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Module: pe_array_40b.sv
// Description: Synthesizable 64-PE Multi-PE Array with Adaptive Allocation
//              Reuses the ratified signed 40-bit saturating MAC unit (mac_unit_40b).
// Organization: 16 Columns x 4 Rows (64 Total Physical PEs)
// Dimensions: ROWS = 4 (rows 0..3), COLS = 16 (cols 0..15)
// Supported Configurations:
//   - Mode 0 (2'b00): 16 Active PEs (Columns 0..3 active; Columns 4..15 gated/clamped)
//   - Mode 1 (2'b01): 32 Active PEs (Columns 0..7 active; Columns 8..15 gated/clamped)
//   - Mode 2 (2'b10): 64 Active PEs (Columns 0..15 all active)
//   - Invalid (2'b11): Safe Quiescence (All columns gated; cfg_invalid asserted)
// Specification: TSK-01, Ratified Amendments AMD-01..05 & Gate 1 Decisions
// =============================================================================

`timescale 1ns / 1ps

module pe_array_40b #(
    parameter int ROWS         = 4,
    parameter int COLS         = 16,
    parameter int ACT_WIDTH    = 16,
    parameter int WEIGHT_WIDTH = 16,
    parameter int ACCUM_WIDTH  = 40
)(
    input  logic                                            clk,
    input  logic                                            rst_n,

    // Runtime PE configuration interface
    input  logic [1:0]                                      cfg_mode,          // 2'b00: 16 PE, 2'b01: 32 PE, 2'b10: 64 PE
    output logic                                            cfg_invalid,       // High if cfg_mode is unsupported (2'b11)
    output logic [6:0]                                      active_pe_count,   // 16, 32, 64, or 0
    output logic [COLS-1:0]                                 col_active,        // Bitmask of active columns

    // Global & per-column execution control
    input  logic                                            enable,            // Master array compute enable
    input  logic [COLS-1:0]                                 col_enable,        // Per-column qualification mask (default '1)
    input  logic                                            accum_clear,       // Clear partial sum accumulators to 0
    input  logic                                            sat_clear,         // Clear sticky saturation flags

    // Operand input interface
    input  logic                                            broadcast_act,     // 1: broadcast act_data_row; 0: use per-PE act_data
    input  logic signed [ACT_WIDTH-1:0]                     act_data_row [0:ROWS-1],
    input  logic                                            act_mask_row [0:ROWS-1],
    input  logic signed [ACT_WIDTH-1:0]                     act_data     [0:ROWS-1][0:COLS-1],
    input  logic                                            act_mask     [0:ROWS-1][0:COLS-1],
    input  logic signed [WEIGHT_WIDTH-1:0]                  weight_data  [0:ROWS-1][0:COLS-1],

    // Output datapath interface (isolated: inactive PEs strictly drive 0)
    output wire  signed [ACCUM_WIDTH-1:0]                  accum_out    [0:ROWS-1][0:COLS-1],
    output wire                                             sticky_saturation [0:ROWS-1][0:COLS-1],
    output wire                                             cycle_skipped     [0:ROWS-1][0:COLS-1],

    // Column & array summary status outputs
    output logic [COLS-1:0]                                 col_sticky_saturation,
    output logic [COLS-1:0]                                 col_cycle_skipped,
    output logic                                            array_sticky_saturation
);

    // Configuration mode definitions
    localparam logic [1:0] MODE_16PE = 2'b00;
    localparam logic [1:0] MODE_32PE = 2'b01;
    localparam logic [1:0] MODE_64PE = 2'b10;

    // -------------------------------------------------------------------------
    // 1. Runtime Mode Decoder & Safe Boundary Enforcement
    // -------------------------------------------------------------------------
    always_comb begin
        case (cfg_mode)
            MODE_16PE: begin
                cfg_invalid     = 1'b0;
                active_pe_count = 7'd16;
                col_active      = 16'h000F; // Columns 0..3 active (4 cols x 4 rows = 16 PEs)
            end
            MODE_32PE: begin
                cfg_invalid     = 1'b0;
                active_pe_count = 7'd32;
                col_active      = 16'h00FF; // Columns 0..7 active (8 cols x 4 rows = 32 PEs)
            end
            MODE_64PE: begin
                cfg_invalid     = 1'b0;
                active_pe_count = 7'd64;
                col_active      = 16'hFFFF; // Columns 0..15 active (16 cols x 4 rows = 64 PEs)
            end
            default: begin
                // Invalid configuration: safely disable all PEs to prevent spurious toggling
                cfg_invalid     = 1'b1;
                active_pe_count = 7'd0;
                col_active      = 16'h0000;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // 2. Physical 16-Column x 4-Row PE Datapath Array Instantiation
    // -------------------------------------------------------------------------
    wire signed [ACCUM_WIDTH-1:0] raw_accum_out     [0:ROWS-1][0:COLS-1];
    wire                          raw_sticky_sat    [0:ROWS-1][0:COLS-1];
    wire                          raw_cycle_skipped [0:ROWS-1][0:COLS-1];

    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : gen_row
            for (c = 0; c < COLS; c = c + 1) begin : gen_col

                // Column qualification & enable gating
                wire pe_is_active;
                wire pe_mac_enable;
                assign pe_is_active  = col_active[c] && (!cfg_invalid);
                assign pe_mac_enable = enable && col_enable[c] && pe_is_active;

                // Operand selection & input clamping:
                // Inactive PEs are clamped to 0 to eliminate multiplier switching power.
                wire signed [ACT_WIDTH-1:0]    pe_act_in;
                wire                           pe_mask_in;
                wire signed [WEIGHT_WIDTH-1:0] pe_weight_in;

                assign pe_act_in    = (!pe_is_active) ? '0 : (broadcast_act ? act_data_row[r] : act_data[r][c]);
                assign pe_mask_in   = (!pe_is_active) ? 1'b0 : (broadcast_act ? act_mask_row[r] : act_mask[r][c]);
                assign pe_weight_in = (!pe_is_active) ? '0 : weight_data[r][c];

                // Verified 40-bit saturating MAC unit instance
                mac_unit_40b #(
                    .ACT_WIDTH(ACT_WIDTH),
                    .WEIGHT_WIDTH(WEIGHT_WIDTH),
                    .ACCUM_WIDTH(ACCUM_WIDTH)
                ) u_pe_mac (
                    .clk(clk),
                    .rst_n(rst_n),
                    .enable(pe_mac_enable),
                    .accum_clear(accum_clear),
                    .sat_clear(sat_clear),
                    .act_data(pe_act_in),
                    .act_mask(pe_mask_in),
                    .weight_data(pe_weight_in),
                    .accum_out(raw_accum_out[r][c]),
                    .sticky_saturation(raw_sticky_sat[r][c]),
                    .cycle_skipped(raw_cycle_skipped[r][c])
                );

                // Output isolation: inactive PEs strictly drive 0
                assign accum_out[r][c]         = pe_is_active ? raw_accum_out[r][c] : '0;
                assign sticky_saturation[r][c] = pe_is_active ? raw_sticky_sat[r][c] : 1'b0;
                assign cycle_skipped[r][c]     = pe_is_active ? raw_cycle_skipped[r][c] : 1'b0;

            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 3. Column-Level and Array-Level Status Aggregation
    // -------------------------------------------------------------------------
    always_comb begin
        for (int col_idx = 0; col_idx < COLS; col_idx = col_idx + 1) begin
            logic col_sat_accum;
            logic col_skip_accum;
            col_sat_accum  = 1'b0;
            col_skip_accum = 1'b1;

            for (int row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                col_sat_accum  = col_sat_accum | sticky_saturation[row_idx][col_idx];
                col_skip_accum = col_skip_accum & cycle_skipped[row_idx][col_idx];
            end

            col_sticky_saturation[col_idx] = col_active[col_idx] ? col_sat_accum : 1'b0;
            // Column skipped is asserted when all active rows in the column were skipped
            col_cycle_skipped[col_idx]     = (col_active[col_idx] && enable && col_enable[col_idx]) ? col_skip_accum : 1'b0;
        end
    end

    // Array-level sticky saturation flag
    assign array_sticky_saturation = |col_sticky_saturation;

endmodule
