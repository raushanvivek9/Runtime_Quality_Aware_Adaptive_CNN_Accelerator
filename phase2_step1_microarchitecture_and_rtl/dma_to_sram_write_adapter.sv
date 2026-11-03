// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-07 System Integration
// Module: dma_to_sram_write_adapter.sv
// Description: Synthesizable Bridge Adapter translating AXI4 Master Write
//              transactions (AW, W, B) from dma_controller into single-cycle
//              native SRAM Port A write requests for multibank_sram_subsystem.
// Protocol Translation:
//   - AXI4 Write Address (AW) + Write Data (W) -> SRAM wr_req, wr_addr, wr_din
//   - Byte address [15:2] mapped to 14-bit SRAM word address
//   - SRAM wr_ack / wr_ready acknowledgment -> AXI4 Write Response (B: OKAY)
// =============================================================================

`timescale 1ns / 1ps

module dma_to_sram_write_adapter #(
    parameter int ADDR_WIDTH  = 32,
    parameter int DATA_WIDTH  = 32,
    parameter int SRAM_ADDR_W = 14
)(
    input  logic                     clk,
    input  logic                     rst_n,

    // -------------------------------------------------------------------------
    // Upstream AXI4 Slave Write Interface (Driven by dma_controller Master Write)
    // -------------------------------------------------------------------------
    input  logic [ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  logic [7:0]               s_axi_awlen,
    input  logic [2:0]               s_axi_awsize,
    input  logic [1:0]               s_axi_awburst,
    input  logic                     s_axi_awvalid,
    output logic                     s_axi_awready,

    input  logic [DATA_WIDTH-1:0]    s_axi_wdata,
    input  logic [(DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  logic                     s_axi_wlast,
    input  logic                     s_axi_wvalid,
    output logic                     s_axi_wready,

    output logic [1:0]               s_axi_bresp,
    output logic                     s_axi_bvalid,
    input  logic                     s_axi_bready,

    // -------------------------------------------------------------------------
    // Downstream Native SRAM Port A Interface (Drives multibank_sram_subsystem)
    // -------------------------------------------------------------------------
    output logic                     sram_wr_req,
    output logic [SRAM_ADDR_W-1:0]   sram_wr_addr,
    output logic [DATA_WIDTH-1:0]    sram_wr_din,
    output logic [(DATA_WIDTH/8)-1:0] sram_wr_byte_we,
    input  logic                     sram_wr_ready,
    input  logic                     sram_wr_ack
);

    // Internal tracking registers
    logic                     aw_latched_q, aw_latched_d;
    logic [SRAM_ADDR_W-1:0]   latched_addr_q, latched_addr_d;
    logic                     bvalid_q, bvalid_d;

    // Address selection: use already-latched address or active incoming awaddr
    wire [SRAM_ADDR_W-1:0] incoming_word_addr = s_axi_awaddr[SRAM_ADDR_W+1:2];
    wire [SRAM_ADDR_W-1:0] active_word_addr   = (aw_latched_q) ? latched_addr_q : incoming_word_addr;
    wire                   addr_available     = aw_latched_q || s_axi_awvalid;

    // Combinational SRAM requests
    assign sram_wr_req     = s_axi_wvalid && addr_available && (!bvalid_q);
    assign sram_wr_addr    = active_word_addr;
    assign sram_wr_din     = s_axi_wdata;
    assign sram_wr_byte_we = s_axi_wstrb;

    // AXI handshakes
    assign s_axi_awready   = (!aw_latched_q) && (!bvalid_q);
    assign s_axi_wready    = sram_wr_ready && addr_available && (!bvalid_q);
    assign s_axi_bvalid    = bvalid_q;
    assign s_axi_bresp     = 2'b00; // OKAY

    // Next-state logic
    always_comb begin
        aw_latched_d   = aw_latched_q;
        latched_addr_d = latched_addr_q;
        bvalid_d       = bvalid_q;

        // Address Latching
        if (s_axi_awvalid && s_axi_awready) begin
            latched_addr_d = incoming_word_addr;
            aw_latched_d   = 1'b1;
        end

        // Data Committal to SRAM
        if (s_axi_wvalid && s_axi_wready) begin
            aw_latched_d = 1'b0; // Consumed for this beat
            bvalid_d     = 1'b1; // Raise write response on subsequent cycle
        end

        // Write Response Handshake
        if (s_axi_bvalid && s_axi_bready) begin
            bvalid_d = 1'b0;
        end
    end

    // Sequential registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_latched_q   <= 1'b0;
            latched_addr_q <= '0;
            bvalid_q       <= 1'b0;
        end else begin
            aw_latched_q   <= aw_latched_d;
            latched_addr_q <= latched_addr_d;
            bvalid_q       <= bvalid_d;
        end
    end

endmodule

