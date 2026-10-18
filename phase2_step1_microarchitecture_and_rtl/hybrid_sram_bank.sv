// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Module: hybrid_sram_bank.sv
// Description: Dual-Ported 5,184-Byte Parameterized Hybrid SRAM Memory Model
// Specification: Ratified Decision D-11 (Option 11-A)
// =============================================================================

`timescale 1ns / 1ps

module hybrid_sram_bank #(
    parameter int TOTAL_BYTES = 5184,
    parameter int DATA_WIDTH  = 32,
    parameter int ADDR_WIDTH  = 11     // 2048 words x 4 bytes = 8192 B physical capacity range
)(
    input  logic                  clk,
    input  logic                  rst_n,
    
    // Port A: Ingestion & Writeback (Write)
    input  logic                  we_a,
    input  logic [ADDR_WIDTH-1:0] addr_a,
    input  logic [DATA_WIDTH-1:0] din_a,
    input  logic [3:0]            byte_we_a,
    output logic                  sram_ready_a,
    
    // Port B: Datapath Compute (Read)
    input  logic                  re_b,
    input  logic [ADDR_WIDTH-1:0] addr_b,
    output logic [DATA_WIDTH-1:0] dout_b,
    output logic                  sram_rvalid_b,
    output logic                  sram_ready_b,

    // Error & Status
    output logic                  sram_oob_err
);

    // Number of 32-bit words for 5,184 bytes = 1296 words
    localparam int NUM_LOGICAL_WORDS = TOTAL_BYTES / 4; // 1296
    localparam int BANK_WORDS        = 1024;

    // Physical Memory Implementation (DEC-P2-01 Option B):
    // Two standard 1024x32b macros.
    // Bank 0: addresses 0..1023
    // Bank 1: addresses 1024..1295 (active), 1296..2047 (power-gated / inactive)
    logic [DATA_WIDTH-1:0] mem_bank0 [0:BANK_WORDS-1];
    logic [DATA_WIDTH-1:0] mem_bank1 [0:BANK_WORDS-1];

    // Address decode & gating
    wire a_oob = (addr_a >= NUM_LOGICAL_WORDS);
    wire b_oob = (addr_b >= NUM_LOGICAL_WORDS);

    // Flow control readiness
    assign sram_ready_a = rst_n;
    assign sram_ready_b = rst_n;

    // Port A Write Logic (byte-masked, address gated)
    always_ff @(posedge clk) begin
        if (we_a && !a_oob) begin
            if (!addr_a[10]) begin
                // Bank 0 (addr 0..1023)
                if (byte_we_a[0]) mem_bank0[addr_a[9:0]][7:0]   <= din_a[7:0];
                if (byte_we_a[1]) mem_bank0[addr_a[9:0]][15:8]  <= din_a[15:8];
                if (byte_we_a[2]) mem_bank0[addr_a[9:0]][23:16] <= din_a[23:16];
                if (byte_we_a[3]) mem_bank0[addr_a[9:0]][31:24] <= din_a[31:24];
            end else begin
                // Bank 1 (addr 1024..1295)
                if (byte_we_a[0]) mem_bank1[addr_a[9:0]][7:0]   <= din_a[7:0];
                if (byte_we_a[1]) mem_bank1[addr_a[9:0]][15:8]  <= din_a[15:8];
                if (byte_we_a[2]) mem_bank1[addr_a[9:0]][23:16] <= din_a[23:16];
                if (byte_we_a[3]) mem_bank1[addr_a[9:0]][31:24] <= din_a[31:24];
            end
        end
    end

    // Port B Synchronous Read Logic (1-cycle latency, Read-Old-Data semantics)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_b        <= '0;
            sram_rvalid_b <= 1'b0;
        end else if (re_b) begin
            sram_rvalid_b <= !b_oob;
            if (b_oob) begin
                dout_b <= '0;
            end else if (!addr_b[10]) begin
                dout_b <= mem_bank0[addr_b[9:0]];
            end else begin
                dout_b <= mem_bank1[addr_b[9:0]];
            end
        end else begin
            sram_rvalid_b <= 1'b0;
        end
    end

    // Out-of-bounds error latching
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_oob_err <= 1'b0;
        end else if ((we_a && a_oob) || (re_b && b_oob)) begin
            sram_oob_err <= 1'b1;
        end
    end

endmodule

