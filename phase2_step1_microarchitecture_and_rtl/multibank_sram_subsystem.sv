// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-03 Multi-bank SRAM Subsystem
// Module: multibank_sram_subsystem.sv
// Description: Parameterized Multi-Bank SRAM Subsystem with Low-Order Bank
//              Interleaving, Dual-Port Concurrent Access, Conflict Arbitration,
//              and 1-Cycle Latency Read Response Crossbar.
// Specification: DEC-P2-01 Option B / Ratified Decision D-11 (Option 11-A)
// =============================================================================

`timescale 1ns / 1ps

module multibank_sram_subsystem #(
    parameter int NUM_BANKS       = 8,
    parameter int BYTES_PER_BANK  = 5184,
    parameter int DATA_WIDTH      = 32,
    parameter int BANK_ADDR_W     = 11,
    parameter int NUM_READ_PORTS  = 8,
    parameter int NUM_WRITE_PORTS = 8
)(
    input  logic                                            clk,
    input  logic                                            rst_n,
    input  logic [NUM_BANKS-1:0]                            bank_enable,

    // Port A Write Channels (Ingestion / Writeback)
    input  logic [NUM_WRITE_PORTS-1:0]                      wr_req,
    input  logic [BANK_ADDR_W+$clog2(NUM_BANKS)-1:0]        wr_addr [0:NUM_WRITE_PORTS-1],
    input  logic [DATA_WIDTH-1:0]                           wr_din  [0:NUM_WRITE_PORTS-1],
    input  logic [DATA_WIDTH/8-1:0]                         wr_byte_we [0:NUM_WRITE_PORTS-1],
    output logic [NUM_WRITE_PORTS-1:0]                      wr_ready,
    output logic [NUM_WRITE_PORTS-1:0]                      wr_ack,
    output logic [NUM_WRITE_PORTS-1:0]                      wr_conflict_stall,

    // Port B Read Channels (Datapath Compute Feeder)
    input  logic [NUM_READ_PORTS-1:0]                       rd_req,
    input  logic [BANK_ADDR_W+$clog2(NUM_BANKS)-1:0]        rd_addr [0:NUM_READ_PORTS-1],
    output logic [NUM_READ_PORTS-1:0]                       rd_ready,
    output logic [NUM_READ_PORTS-1:0]                       rd_rvalid,
    output wire  [DATA_WIDTH-1:0]                           rd_dout [0:NUM_READ_PORTS-1],
    output logic [NUM_READ_PORTS-1:0]                       rd_conflict_stall,

    // Diagnostics & Performance Monitoring
    output logic [NUM_BANKS-1:0]                            bank_conflict_flags,
    output logic [NUM_BANKS-1:0]                            bank_oob_err,
    output logic                                            oob_error_any,
    output logic [31:0]                                     total_conflicts_count,
    output logic [31:0]                                     total_read_accesses,
    output logic [31:0]                                     total_write_accesses
);

    localparam int BANK_SEL_BITS = $clog2(NUM_BANKS);
    localparam int GLOBAL_ADDR_W = BANK_ADDR_W + BANK_SEL_BITS;
    localparam int RD_PORT_ID_W  = (NUM_READ_PORTS > 1) ? $clog2(NUM_READ_PORTS) : 1;
    localparam int WR_PORT_ID_W  = (NUM_WRITE_PORTS > 1) ? $clog2(NUM_WRITE_PORTS) : 1;

    // Address Decoding (Low-Order Interleaving to avoid slice warnings in always_comb)
    wire [BANK_SEL_BITS-1:0] wr_bank_sel  [0:NUM_WRITE_PORTS-1];
    wire [BANK_ADDR_W-1:0]   wr_bank_addr [0:NUM_WRITE_PORTS-1];

    genvar w_gen;
    generate
        for (w_gen = 0; w_gen < NUM_WRITE_PORTS; w_gen = w_gen + 1) begin : gen_wr_decode
            assign wr_bank_sel[w_gen]  = wr_addr[w_gen][BANK_SEL_BITS-1:0];
            assign wr_bank_addr[w_gen] = wr_addr[w_gen][GLOBAL_ADDR_W-1:BANK_SEL_BITS];
        end
    endgenerate

    wire [BANK_SEL_BITS-1:0] rd_bank_sel  [0:NUM_READ_PORTS-1];
    wire [BANK_ADDR_W-1:0]   rd_bank_addr [0:NUM_READ_PORTS-1];

    genvar r_gen;
    generate
        for (r_gen = 0; r_gen < NUM_READ_PORTS; r_gen = r_gen + 1) begin : gen_rd_decode
            assign rd_bank_sel[r_gen]  = rd_addr[r_gen][BANK_SEL_BITS-1:0];
            assign rd_bank_addr[r_gen] = rd_addr[r_gen][GLOBAL_ADDR_W-1:BANK_SEL_BITS];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Physical Bank Instantiations
    // -------------------------------------------------------------------------
    logic                   bank_we_a      [0:NUM_BANKS-1];
    logic [BANK_ADDR_W-1:0] bank_addr_a    [0:NUM_BANKS-1];
    logic [DATA_WIDTH-1:0]  bank_din_a      [0:NUM_BANKS-1];
    logic [3:0]             bank_byte_we_a [0:NUM_BANKS-1];
    wire                    bank_ready_a   [0:NUM_BANKS-1];

    logic                   bank_re_b      [0:NUM_BANKS-1];
    logic [BANK_ADDR_W-1:0] bank_addr_b    [0:NUM_BANKS-1];
    wire  [DATA_WIDTH-1:0]  bank_dout_b    [0:NUM_BANKS-1];
    wire                    bank_rvalid_b  [0:NUM_BANKS-1];
    wire                    bank_ready_b   [0:NUM_BANKS-1];
    wire                    bank_oob_raw   [0:NUM_BANKS-1];

    genvar b;
    generate
        for (b = 0; b < NUM_BANKS; b = b + 1) begin : gen_bank
            hybrid_sram_bank #(
                .TOTAL_BYTES(BYTES_PER_BANK),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(BANK_ADDR_W)
            ) u_sram_bank (
                .clk(clk),
                .rst_n(rst_n && bank_enable[b]),
                .we_a(bank_we_a[b]),
                .addr_a(bank_addr_a[b]),
                .din_a(bank_din_a[b]),
                .byte_we_a(bank_byte_we_a[b]),
                .sram_ready_a(bank_ready_a[b]),
                .re_b(bank_re_b[b]),
                .addr_b(bank_addr_b[b]),
                .dout_b(bank_dout_b[b]),
                .sram_rvalid_b(bank_rvalid_b[b]),
                .sram_ready_b(bank_ready_b[b]),
                .sram_oob_err(bank_oob_raw[b])
            );
            assign bank_oob_err[b] = bank_oob_raw[b];
        end
    endgenerate

    assign oob_error_any = |bank_oob_err;

    // -------------------------------------------------------------------------
    // 1. Write Routing & Conflict Arbitration (Port A)
    // -------------------------------------------------------------------------
    logic [WR_PORT_ID_W-1:0] granted_wr_port [0:NUM_BANKS-1];
    logic bank_wr_active       [0:NUM_BANKS-1];
    logic wr_conflict_detected [0:NUM_BANKS-1];

    always_comb begin
        // Reset per-bank write control
        for (int b_idx = 0; b_idx < NUM_BANKS; b_idx = b_idx + 1) begin
            granted_wr_port[b_idx]      = '0;
            bank_wr_active[b_idx]       = 1'b0;
            wr_conflict_detected[b_idx] = 1'b0;
            bank_we_a[b_idx]            = 1'b0;
            bank_addr_a[b_idx]          = '0;
            bank_din_a[b_idx]           = '0;
            bank_byte_we_a[b_idx]       = '0;

            for (int w_idx = 0; w_idx < NUM_WRITE_PORTS; w_idx = w_idx + 1) begin
                if (wr_req[w_idx] && bank_enable[b_idx] &&
                    (wr_bank_sel[w_idx] == b_idx)) begin
                    if (!bank_wr_active[b_idx]) begin
                        // Grant highest priority (lowest port index)
                        granted_wr_port[b_idx] = w_idx;
                        bank_wr_active[b_idx]  = 1'b1;
                    end else begin
                        // Subsequent write requesters suffer conflict stall
                        wr_conflict_detected[b_idx] = 1'b1;
                    end
                end
            end

            // Drive physical bank signals
            if (bank_wr_active[b_idx]) begin
                bank_we_a[b_idx]      = 1'b1;
                bank_addr_a[b_idx]    = wr_bank_addr[granted_wr_port[b_idx]];
                bank_din_a[b_idx]     = wr_din[granted_wr_port[b_idx]];
                bank_byte_we_a[b_idx] = wr_byte_we[granted_wr_port[b_idx]];
            end
        end

        // Set status per write port
        for (int w_idx = 0; w_idx < NUM_WRITE_PORTS; w_idx = w_idx + 1) begin
            int target_bank;
            target_bank = wr_bank_sel[w_idx];
            if (wr_req[w_idx]) begin
                if (bank_enable[target_bank] && bank_wr_active[target_bank] && (granted_wr_port[target_bank] == w_idx)) begin
                    wr_ready[w_idx]          = 1'b1;
                    wr_ack[w_idx]            = 1'b1;
                    wr_conflict_stall[w_idx] = 1'b0;
                end else begin
                    wr_ready[w_idx]          = 1'b0;
                    wr_ack[w_idx]            = 1'b0;
                    wr_conflict_stall[w_idx] = 1'b1;
                end
            end else begin
                wr_ready[w_idx]          = 1'b1;
                wr_ack[w_idx]            = 1'b0;
                wr_conflict_stall[w_idx] = 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 2. Read Routing & Conflict Arbitration (Port B)
    // -------------------------------------------------------------------------
    logic [RD_PORT_ID_W-1:0] granted_rd_port [0:NUM_BANKS-1];
    logic bank_rd_active       [0:NUM_BANKS-1];
    logic rd_conflict_detected [0:NUM_BANKS-1];

    always_comb begin
        for (int b_idx = 0; b_idx < NUM_BANKS; b_idx = b_idx + 1) begin
            granted_rd_port[b_idx]      = '0;
            bank_rd_active[b_idx]       = 1'b0;
            rd_conflict_detected[b_idx] = 1'b0;
            bank_re_b[b_idx]            = 1'b0;
            bank_addr_b[b_idx]          = '0;

            for (int p_idx = 0; p_idx < NUM_READ_PORTS; p_idx = p_idx + 1) begin
                if (rd_req[p_idx] && bank_enable[b_idx] &&
                    (rd_bank_sel[p_idx] == b_idx)) begin
                    if (!bank_rd_active[b_idx]) begin
                        // Grant highest priority (lowest port index)
                        granted_rd_port[b_idx] = p_idx;
                        bank_rd_active[b_idx]  = 1'b1;
                    end else begin
                        // Subsequent read requesters suffer conflict stall
                        rd_conflict_detected[b_idx] = 1'b1;
                    end
                end
            end

            // Drive physical bank signals
            if (bank_rd_active[b_idx]) begin
                bank_re_b[b_idx]   = 1'b1;
                bank_addr_b[b_idx] = rd_bank_addr[granted_rd_port[b_idx]];
            end
        end

        // Set status per read port
        for (int p_idx = 0; p_idx < NUM_READ_PORTS; p_idx = p_idx + 1) begin
            int target_bank;
            target_bank = rd_bank_sel[p_idx];
            if (rd_req[p_idx]) begin
                if (bank_enable[target_bank] && bank_rd_active[target_bank] && (granted_rd_port[target_bank] == p_idx)) begin
                    rd_ready[p_idx]          = 1'b1;
                    rd_conflict_stall[p_idx] = 1'b0;
                end else begin
                    rd_ready[p_idx]          = 1'b0;
                    rd_conflict_stall[p_idx] = 1'b1;
                end
            end else begin
                rd_ready[p_idx]          = 1'b1;
                rd_conflict_stall[p_idx] = 1'b0;
            end
        end
    end

    // Composite bank conflict flags
    always_comb begin
        for (int b_idx = 0; b_idx < NUM_BANKS; b_idx = b_idx + 1) begin
            bank_conflict_flags[b_idx] = wr_conflict_detected[b_idx] | rd_conflict_detected[b_idx];
        end
    end

    // -------------------------------------------------------------------------
    // 3. Registered Read Response Crossbar (1-Cycle Latency Tracking)
    // -------------------------------------------------------------------------
    logic [RD_PORT_ID_W-1:0] bank_resp_owner_q [0:NUM_BANKS-1];
    logic                    bank_resp_valid_q [0:NUM_BANKS-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int b_idx = 0; b_idx < NUM_BANKS; b_idx = b_idx + 1) begin
                bank_resp_owner_q[b_idx] <= '0;
                bank_resp_valid_q[b_idx] <= 1'b0;
            end
        end else begin
            for (int b_idx = 0; b_idx < NUM_BANKS; b_idx = b_idx + 1) begin
                if (bank_rd_active[b_idx]) begin
                    bank_resp_owner_q[b_idx] <= granted_rd_port[b_idx];
                    bank_resp_valid_q[b_idx] <= 1'b1;
                end else begin
                    bank_resp_valid_q[b_idx] <= 1'b0;
                end
            end
        end
    end

    // Crossbar routing: direct 1-cycle delayed bank output data back to requesting port
    logic [DATA_WIDTH-1:0] rd_dout_mux   [0:NUM_READ_PORTS-1];
    logic                  rd_rvalid_mux [0:NUM_READ_PORTS-1];

    always_comb begin
        for (int p = 0; p < NUM_READ_PORTS; p = p + 1) begin
            rd_dout_mux[p]   = '0;
            rd_rvalid_mux[p] = 1'b0;
            for (int b_idx = 0; b_idx < NUM_BANKS; b_idx = b_idx + 1) begin
                if (bank_resp_valid_q[b_idx] && (bank_resp_owner_q[b_idx] == p)) begin
                    rd_dout_mux[p]   = bank_dout_b[b_idx];
                    rd_rvalid_mux[p] = bank_rvalid_b[b_idx];
                end
            end
        end
    end

    genvar p_gen;
    generate
        for (p_gen = 0; p_gen < NUM_READ_PORTS; p_gen = p_gen + 1) begin : gen_rd_out
            assign rd_dout[p_gen]   = rd_dout_mux[p_gen];
            assign rd_rvalid[p_gen] = rd_rvalid_mux[p_gen];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 4. Diagnostic & Performance Metric Counters
    // -------------------------------------------------------------------------
    int unsigned num_conflicts_cycle;
    int unsigned num_reads_cycle;
    int unsigned num_writes_cycle;

    always_comb begin
        num_conflicts_cycle = 0;
        num_reads_cycle     = 0;
        num_writes_cycle    = 0;
        for (int b_idx = 0; b_idx < NUM_BANKS; b_idx = b_idx + 1) begin
            if (bank_conflict_flags[b_idx]) num_conflicts_cycle = num_conflicts_cycle + 1;
            if (bank_rd_active[b_idx])      num_reads_cycle     = num_reads_cycle + 1;
            if (bank_wr_active[b_idx])      num_writes_cycle    = num_writes_cycle + 1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_conflicts_count <= '0;
            total_read_accesses   <= '0;
            total_write_accesses  <= '0;
        end else begin
            total_conflicts_count <= total_conflicts_count + num_conflicts_cycle;
            total_read_accesses   <= total_read_accesses   + num_reads_cycle;
            total_write_accesses  <= total_write_accesses  + num_writes_cycle;
        end
    end

endmodule
