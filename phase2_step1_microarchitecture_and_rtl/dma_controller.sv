// =============================================================================
// File: dma_controller.sv
// Module: dma_controller
// Project: Neural_Acc (Runtime_Quality_Aware_Adaptive_CNN_Accelerator)
// Description: Synthesizable Standalone Direct Memory Access (DMA) Controller.
//              Provides an AXI4 Master streaming engine with independent Read
//              and Write channels, an internal 16-deep decoupling FIFO,
//              comprehensive address/length parameter validation, slave error
//              handling, edge-triggered start protection, and ping-pong buffer
//              handshake coordination.
//
// Protocol Classification:
//   - Bus Master: AXI4-style read (AR, R) and write (AW, W, B) streaming master
//                 utilizing beat-by-beat address progression (arlen=0, awlen=0,
//                 size=2'b010, burst=2'b01) matching single-beat accelerator SRAMs.
//   - Control: Dedicated parallel register interface (dma_start, src/dst addr,
//              transfer_len, status pulses, and error codes) rather than memory-mapped
//              AXI4-Lite slave registers.
//
// Verification: Verified via tb_dma_controller.sv across 18 exhaustive scenarios.
// =============================================================================

`timescale 1ns/1ps

module dma_controller #(
    parameter int ADDR_WIDTH  = 32,
    parameter int DATA_WIDTH  = 32,
    parameter int LEN_WIDTH   = 16,
    parameter int FIFO_DEPTH  = 16
)(
    // Clock and Active-Low Asynchronous Reset
    input  logic                     clk,
    input  logic                     rst_n,

    // -------------------------------------------------------------------------
    // Control & Configuration Interface (Parallel Register Handshake)
    // -------------------------------------------------------------------------
    input  logic                     dma_start,           // Level/pulse start command
    input  logic [ADDR_WIDTH-1:0]    dma_src_addr,        // Source start byte address
    input  logic [ADDR_WIDTH-1:0]    dma_dst_addr,        // Destination start byte address
    input  logic [LEN_WIDTH-1:0]     dma_transfer_len,    // Number of 32-bit words
    input  logic                     dma_use_ping_pong,   // 1: Coordinate with ping-pong buffer
    input  logic                     dma_error_clear,     // Clear latched error status

    output logic                     dma_busy,            // High during transfer execution
    output logic [2:0]               dma_state,           // Current FSM state
    output logic                     dma_done_pulse,      // 1-cycle completion pulse
    output logic                     dma_error_flag,      // Latched error indicator
    output logic [3:0]               dma_error_code,      // Detailed error category code

    // -------------------------------------------------------------------------
    // Ping-Pong Buffer Coordination Interface
    // -------------------------------------------------------------------------
    input  logic                     pp_producer_ready,   // Buffer available for producing
    output logic                     pp_producer_start,   // Pulse/level: lock producing buffer
    output logic                     pp_producer_done,    // Pulse: mark buffer filled / ready

    // -------------------------------------------------------------------------
    // AXI4 Master Read Channel (System Memory / Source)
    // -------------------------------------------------------------------------
    output logic [ADDR_WIDTH-1:0]    m_axi_araddr,
    output logic [7:0]               m_axi_arlen,         // 8'd0: 1 beat per request
    output logic [2:0]               m_axi_arsize,        // 3'b010: 4 bytes (32-bit)
    output logic [1:0]               m_axi_arburst,       // 2'b01: INCR
    output logic                     m_axi_arvalid,
    input  logic                     m_axi_arready,

    input  logic [DATA_WIDTH-1:0]    m_axi_rdata,
    input  logic [1:0]               m_axi_rresp,         // 2'b00: OKAY, 2'b10: SLVERR
    input  logic                     m_axi_rlast,
    input  logic                     m_axi_rvalid,
    output logic                     m_axi_rready,

    // -------------------------------------------------------------------------
    // AXI4 Master Write Channel (Accelerator SRAM / Destination)
    // -------------------------------------------------------------------------
    output logic [ADDR_WIDTH-1:0]    m_axi_awaddr,
    output logic [7:0]               m_axi_awlen,         // 8'd0: 1 beat per request
    output logic [2:0]               m_axi_awsize,        // 3'b010: 4 bytes (32-bit)
    output logic [1:0]               m_axi_awburst,       // 2'b01: INCR
    output logic                     m_axi_awvalid,
    input  logic                     m_axi_awready,

    output logic [DATA_WIDTH-1:0]    m_axi_wdata,
    output logic [(DATA_WIDTH/8)-1:0] m_axi_wstrb,        // 4'b1111: full word write
    output logic                     m_axi_wlast,
    output logic                     m_axi_wvalid,
    input  logic                     m_axi_wready,

    input  logic [1:0]               m_axi_bresp,         // 2'b00: OKAY, 2'b10: SLVERR
    input  logic                     m_axi_bvalid,
    output logic                     m_axi_bready
);

    // -------------------------------------------------------------------------
    // Error Code Definitions
    // -------------------------------------------------------------------------
    localparam logic [3:0] ERR_NONE            = 4'd0;
    localparam logic [3:0] ERR_ZERO_LEN        = 4'd1; // Transfer length is zero
    localparam logic [3:0] ERR_ADDR_OVERFLOW   = 4'd2; // Address + length exceeds 32-bit boundary
    localparam logic [3:0] ERR_UNALIGNED_ADDR  = 4'd3; // Non-word aligned address (bits [1:0] != 0)
    localparam logic [3:0] ERR_SLV_READ_RESP   = 4'd4; // Bus slave error on read response (m_axi_rresp != 0)
    localparam logic [3:0] ERR_SLV_WRITE_RESP  = 4'd5; // Bus slave error on write response (m_axi_bresp != 0)

    // -------------------------------------------------------------------------
    // FSM State Encoding
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        DMA_IDLE      = 3'd0, // Quiescent idle state
        DMA_VALIDATE  = 3'd1, // Parameter validation and ping-pong readiness check
        DMA_STREAM    = 3'd2, // Active read/write streaming via decoupling FIFO
        DMA_WAIT_RESP = 3'd3, // All beats written; await outstanding write responses
        DMA_DONE      = 3'd4, // Assert 1-cycle dma_done_pulse
        DMA_ERROR     = 3'd5  // Hold error state until dma_error_clear
    } dma_fsm_t;

    dma_fsm_t state_q, state_d;

    // -------------------------------------------------------------------------
    // Start Request Edge Detector (Protection against held start signal)
    // -------------------------------------------------------------------------
    logic dma_start_q;
    wire  dma_start_pulse = dma_start && (!dma_start_q);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) dma_start_q <= 1'b0;
        else        dma_start_q <= dma_start;
    end

    // -------------------------------------------------------------------------
    // Latched Configuration Registers
    // -------------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0] src_addr_q,     src_addr_d;
    logic [ADDR_WIDTH-1:0] dst_addr_q,     dst_addr_d;
    logic [LEN_WIDTH-1:0]  transfer_len_q, transfer_len_d;
    logic                  use_pp_q,       use_pp_d;

    // Progress Counters
    logic [LEN_WIDTH-1:0]  rd_req_cnt_q,   rd_req_cnt_d;
    logic [LEN_WIDTH-1:0]  rd_resp_cnt_q,  rd_resp_cnt_d;
    logic [LEN_WIDTH-1:0]  wr_addr_cnt_q,  wr_addr_cnt_d;
    logic [LEN_WIDTH-1:0]  wr_data_cnt_q,  wr_data_cnt_d;
    logic [LEN_WIDTH-1:0]  wr_resp_cnt_q,  wr_resp_cnt_d;

    // Address Progression Registers
    logic [ADDR_WIDTH-1:0] curr_araddr_q,  curr_araddr_d;
    logic [ADDR_WIDTH-1:0] curr_awaddr_q,  curr_awaddr_d;

    // Status & Error Registers
    logic                  done_pulse_q,   done_pulse_d;
    logic                  error_flag_q,   error_flag_d;
    logic [3:0]            error_code_q,   error_code_d;
    logic                  pp_start_q,     pp_start_d;
    logic                  pp_done_q,      pp_done_d;

    // -------------------------------------------------------------------------
    // Internal Decoupling FIFO (Depth 16)
    // -------------------------------------------------------------------------
    localparam int FIFO_ADDR_W = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
    logic [DATA_WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];
    logic [FIFO_ADDR_W-1:0] wr_ptr_q, wr_ptr_d;
    logic [FIFO_ADDR_W-1:0] rd_ptr_q, rd_ptr_d;
    logic [FIFO_ADDR_W:0]   fifo_count_q, fifo_count_d;
    logic                   fifo_push;
    logic                   fifo_pop;

    wire                    fifo_full  = (fifo_count_q == FIFO_DEPTH[FIFO_ADDR_W:0]);
    wire                    fifo_empty = (fifo_count_q == '0);
    wire  [DATA_WIDTH-1:0]  fifo_dout  = fifo_mem[rd_ptr_q];

    // Read throttling: in-flight reads that haven't entered the FIFO yet
    wire [LEN_WIDTH:0] in_flight_reads = rd_req_cnt_q - rd_resp_cnt_q;
    wire [LEN_WIDTH:0] projected_occupancy = fifo_count_q + in_flight_reads;
    wire can_issue_read = (rd_req_cnt_q < transfer_len_q) &&
                          (projected_occupancy < FIFO_DEPTH[LEN_WIDTH:0]);

    // Write address progression gating: address for next beat issues when prior beat data is sent
    wire can_issue_write_addr = (wr_addr_cnt_q < transfer_len_q) &&
                                (wr_addr_cnt_q <= wr_data_cnt_q);

    // Continuous alignment & boundary checks
    wire is_src_unaligned = (src_addr_q[1:0] != 2'b00);
    wire is_dst_unaligned = (dst_addr_q[1:0] != 2'b00);
    wire [32:0] src_end_addr = {1'b0, src_addr_q} + {15'd0, transfer_len_q, 2'b00};
    wire [32:0] dst_end_addr = {1'b0, dst_addr_q} + {15'd0, transfer_len_q, 2'b00};
    wire is_src_overflow  = (src_end_addr > 33'h1_0000_0000);
    wire is_dst_overflow  = (dst_end_addr > 33'h1_0000_0000);

    // -------------------------------------------------------------------------
    // Output Assignments
    // -------------------------------------------------------------------------
    assign dma_busy          = (state_q != DMA_IDLE);
    assign dma_state         = state_q;
    assign dma_done_pulse    = done_pulse_q;
    assign dma_error_flag    = error_flag_q;
    assign dma_error_code    = error_code_q;

    assign pp_producer_start = pp_start_q;
    assign pp_producer_done  = pp_done_q;

    // AXI4 Read Channel Assignments
    assign m_axi_araddr      = curr_araddr_q;
    assign m_axi_arlen       = 8'd0;       // Beat-by-beat progression
    assign m_axi_arsize      = 3'b010;     // 4 bytes (32 bits)
    assign m_axi_arburst     = 2'b01;      // INCR
    assign m_axi_arvalid     = can_issue_read && (state_q == DMA_STREAM);
    assign m_axi_rready      = (!fifo_full) && (state_q == DMA_STREAM);

    // AXI4 Write Channel Assignments
    assign m_axi_awaddr      = curr_awaddr_q;
    assign m_axi_awlen       = 8'd0;       // Beat-by-beat progression
    assign m_axi_awsize      = 3'b010;     // 4 bytes (32 bits)
    assign m_axi_awburst     = 2'b01;      // INCR
    assign m_axi_awvalid     = can_issue_write_addr && (state_q == DMA_STREAM);

    assign m_axi_wdata       = fifo_dout;
    assign m_axi_wstrb       = 4'b1111;    // Full 32-bit word valid
    assign m_axi_wlast       = (wr_data_cnt_q + 1'b1 == transfer_len_q);
    assign m_axi_wvalid      = (!fifo_empty) && (state_q == DMA_STREAM) && (wr_data_cnt_q < wr_addr_cnt_q);
    assign m_axi_bready      = 1'b1;       // Always ready to accept write responses

    // -------------------------------------------------------------------------
    // Combinational Next-State & Data-Path Logic
    // -------------------------------------------------------------------------
    always_comb begin
        // Defaults: retain registered values
        state_d         = state_q;
        src_addr_d      = src_addr_q;
        dst_addr_d      = dst_addr_q;
        transfer_len_d  = transfer_len_q;
        use_pp_d        = use_pp_q;

        rd_req_cnt_d    = rd_req_cnt_q;
        rd_resp_cnt_d   = rd_resp_cnt_q;
        wr_addr_cnt_d   = wr_addr_cnt_q;
        wr_data_cnt_d   = wr_data_cnt_q;
        wr_resp_cnt_d   = wr_resp_cnt_q;

        curr_araddr_d   = curr_araddr_q;
        curr_awaddr_d   = curr_awaddr_q;

        done_pulse_d    = 1'b0;
        error_flag_d    = error_flag_q;
        error_code_d    = error_code_q;

        pp_start_d      = 1'b0;
        pp_done_d       = 1'b0;

        fifo_push       = 1'b0;
        fifo_pop        = 1'b0;

        case (state_q)
            // -----------------------------------------------------------------
            // DMA_IDLE: Await rising-edge start trigger
            // -----------------------------------------------------------------
            DMA_IDLE: begin
                if (dma_start_pulse) begin
                    src_addr_d      = dma_src_addr;
                    dst_addr_d      = dma_dst_addr;
                    transfer_len_d  = dma_transfer_len;
                    use_pp_d        = dma_use_ping_pong;

                    curr_araddr_d   = dma_src_addr;
                    curr_awaddr_d   = dma_dst_addr;

                    rd_req_cnt_d    = '0;
                    rd_resp_cnt_d   = '0;
                    wr_addr_cnt_d   = '0;
                    wr_data_cnt_d   = '0;
                    wr_resp_cnt_d   = '0;

                    error_flag_d    = 1'b0;
                    error_code_d    = ERR_NONE;

                    state_d         = DMA_VALIDATE;
                end
            end

            // -----------------------------------------------------------------
            // DMA_VALIDATE: Validate address bounds, alignment, and length
            // -----------------------------------------------------------------
            DMA_VALIDATE: begin
                // Check 1: Zero length transfer
                if (transfer_len_q == '0) begin
                    error_flag_d = 1'b1;
                    error_code_d = ERR_ZERO_LEN;
                    state_d      = DMA_ERROR;
                // Check 2: Word alignment (bits [1:0] == 0)
                end else if (is_src_unaligned || is_dst_unaligned) begin
                    error_flag_d = 1'b1;
                    error_code_d = ERR_UNALIGNED_ADDR;
                    state_d      = DMA_ERROR;
                // Check 3: 32-bit address overflow check
                end else if (is_src_overflow || is_dst_overflow) begin
                    error_flag_d = 1'b1;
                    error_code_d = ERR_ADDR_OVERFLOW;
                    state_d      = DMA_ERROR;
                // Check 4: Ping-Pong Buffer readiness (if enabled)
                end else if (use_pp_q && (!pp_producer_ready)) begin
                    // Backpressure: wait in DMA_VALIDATE until buffer is free
                    state_d = DMA_VALIDATE;
                end else begin
                    // Configuration valid!
                    if (use_pp_q) begin
                        pp_start_d = 1'b1; // Lock buffer into BUF_PRODUCING
                    end
                    state_d = DMA_STREAM;
                end
            end

            // -----------------------------------------------------------------
            // DMA_STREAM: Stream data from Read channel into Write channel via FIFO
            // -----------------------------------------------------------------
            DMA_STREAM: begin
                // --- 1. Read Address Channel (AR) Handshake ---
                if (m_axi_arvalid && m_axi_arready) begin
                    rd_req_cnt_d  = rd_req_cnt_q + 1'b1;
                    curr_araddr_d = curr_araddr_q + 32'd4; // Progression by 4 bytes
                end

                // --- 2. Read Data Channel (R) Handshake ---
                if (m_axi_rvalid && m_axi_rready) begin
                    if (m_axi_rresp != 2'b00) begin
                        error_flag_d = 1'b1;
                        error_code_d = ERR_SLV_READ_RESP;
                        state_d      = DMA_ERROR;
                    end else begin
                        fifo_push     = 1'b1;
                        rd_resp_cnt_d = rd_resp_cnt_q + 1'b1;
                    end
                end

                // --- 3. Write Address Channel (AW) Handshake ---
                if (m_axi_awvalid && m_axi_awready) begin
                    wr_addr_cnt_d = wr_addr_cnt_q + 1'b1;
                    curr_awaddr_d = curr_awaddr_q + 32'd4; // Progression by 4 bytes
                end

                // --- 4. Write Data Channel (W) Handshake ---
                if (m_axi_wvalid && m_axi_wready) begin
                    fifo_pop      = 1'b1;
                    wr_data_cnt_d = wr_data_cnt_q + 1'b1;
                end

                // --- 5. Write Response Channel (B) Handshake ---
                if (m_axi_bvalid && m_axi_bready) begin
                    if (m_axi_bresp != 2'b00) begin
                        error_flag_d = 1'b1;
                        error_code_d = ERR_SLV_WRITE_RESP;
                        state_d      = DMA_ERROR;
                    end else begin
                        wr_resp_cnt_d = wr_resp_cnt_q + 1'b1;
                    end
                end

                // --- 6. Transition to Response Wait or Done ---
                if (wr_data_cnt_d == transfer_len_q) begin
                    if (wr_resp_cnt_d == transfer_len_q) begin
                        state_d = DMA_DONE;
                    end else begin
                        state_d = DMA_WAIT_RESP;
                    end
                end
            end

            // -----------------------------------------------------------------
            // DMA_WAIT_RESP: All data beats written; await outstanding write responses
            // -----------------------------------------------------------------
            DMA_WAIT_RESP: begin
                if (m_axi_bvalid && m_axi_bready) begin
                    if (m_axi_bresp != 2'b00) begin
                        error_flag_d = 1'b1;
                        error_code_d = ERR_SLV_WRITE_RESP;
                        state_d      = DMA_ERROR;
                    end else begin
                        wr_resp_cnt_d = wr_resp_cnt_q + 1'b1;
                        if (wr_resp_cnt_q + 1'b1 == transfer_len_q) begin
                            state_d = DMA_DONE;
                        end
                    end
                end
            end

            // -----------------------------------------------------------------
            // DMA_DONE: Issue 1-cycle completion pulse
            // -----------------------------------------------------------------
            DMA_DONE: begin
                done_pulse_d = 1'b1;
                if (use_pp_q) begin
                    pp_done_d = 1'b1; // Release buffer into BUF_READY
                end
                state_d = DMA_IDLE;
            end

            // -----------------------------------------------------------------
            // DMA_ERROR: Hold error status until cleared
            // -----------------------------------------------------------------
            DMA_ERROR: begin
                if (dma_error_clear) begin
                    error_flag_d = 1'b0;
                    error_code_d = ERR_NONE;
                    state_d      = DMA_IDLE;
                end
            end

            default: state_d = DMA_IDLE;
        endcase

        // --- FIFO Counter & Pointer Next-State Logic ---
        wr_ptr_d     = wr_ptr_q;
        rd_ptr_d     = rd_ptr_q;
        fifo_count_d = fifo_count_q;

        if (state_q == DMA_IDLE && dma_start_pulse) begin
            wr_ptr_d     = '0;
            rd_ptr_d     = '0;
            fifo_count_d = '0;
        end else begin
            if (fifo_push && !fifo_pop) begin
                wr_ptr_d     = (wr_ptr_q == FIFO_DEPTH-1) ? '0 : (wr_ptr_q + 1'b1);
                fifo_count_d = fifo_count_q + 1'b1;
            end else if (!fifo_push && fifo_pop) begin
                rd_ptr_d     = (rd_ptr_q == FIFO_DEPTH-1) ? '0 : (rd_ptr_q + 1'b1);
                fifo_count_d = fifo_count_q - 1'b1;
            end else if (fifo_push && fifo_pop) begin
                wr_ptr_d     = (wr_ptr_q == FIFO_DEPTH-1) ? '0 : (wr_ptr_q + 1'b1);
                rd_ptr_d     = (rd_ptr_q == FIFO_DEPTH-1) ? '0 : (rd_ptr_q + 1'b1);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Sequential Registers
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q         <= DMA_IDLE;
            src_addr_q      <= '0;
            dst_addr_q      <= '0;
            transfer_len_q  <= '0;
            use_pp_q        <= 1'b0;

            rd_req_cnt_q    <= '0;
            rd_resp_cnt_q   <= '0;
            wr_addr_cnt_q   <= '0;
            wr_data_cnt_q   <= '0;
            wr_resp_cnt_q   <= '0;

            curr_araddr_q   <= '0;
            curr_awaddr_q   <= '0;

            done_pulse_q    <= 1'b0;
            error_flag_q    <= 1'b0;
            error_code_q    <= ERR_NONE;

            pp_start_q      <= 1'b0;
            pp_done_q       <= 1'b0;

            wr_ptr_q        <= '0;
            rd_ptr_q        <= '0;
            fifo_count_q    <= '0;
        end else begin
            state_q         <= state_d;
            src_addr_q      <= src_addr_d;
            dst_addr_q      <= dst_addr_d;
            transfer_len_q  <= transfer_len_d;
            use_pp_q        <= use_pp_d;

            rd_req_cnt_q    <= rd_req_cnt_d;
            rd_resp_cnt_q   <= rd_resp_cnt_d;
            wr_addr_cnt_q   <= wr_addr_cnt_d;
            wr_data_cnt_q   <= wr_data_cnt_d;
            wr_resp_cnt_q   <= wr_resp_cnt_d;

            curr_araddr_q   <= curr_araddr_d;
            curr_awaddr_q   <= curr_awaddr_d;

            done_pulse_q    <= done_pulse_d;
            error_flag_q    <= error_flag_d;
            error_code_q    <= error_code_d;

            pp_start_q      <= pp_start_d;
            pp_done_q       <= pp_done_d;

            wr_ptr_q        <= wr_ptr_d;
            rd_ptr_q        <= rd_ptr_d;
            fifo_count_q    <= fifo_count_d;

            if (fifo_push) begin
                fifo_mem[wr_ptr_q] <= m_axi_rdata;
            end
        end
    end

endmodule
