// =============================================================================
// File: tb_tsk11_ofmap_integration.sv
// Description: Comprehensive End-to-End OFMAP Drain Integration Testbench (TSK-11 Phase 2B/2C)
//              Verifies complete integration of ofmap_drain_controller into
//              neural_acc_integrated_top across 11 required scenarios:
//              1. Basic compute + complete drain & layer completion handshake
//              2. Positive and negative accumulator outputs
//              3. Boundary values and lossless 40-bit sign extension
//              4. Exactly 128 accepted OFMAP writes
//              5. Concurrent DMA ingress & OFMAP write to different banks
//              6. Concurrent DMA ingress & OFMAP write to same bank (arbitration)
//              7. Backpressure during drain & request/data hold stability
//              8. Next-layer command arrival before drain completes (lockout)
//              9. Asynchronous reset during active drain & clean recovery
//              10. Invalid OFMAP base address detection & error handling
//              11. Consecutive layers without partial sum contamination
// =============================================================================

`timescale 1ns/1ps

module tb_tsk11_ofmap_integration;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int ADDR_WIDTH       = 32;
    localparam int DATA_WIDTH       = 32;
    localparam int LEN_WIDTH        = 16;
    localparam int LAYER_ID_W       = 16;
    localparam int DEGRADE_W        = 16;
    localparam int K_WIDTH          = 16;
    localparam int NUM_BANKS        = 8;
    localparam int BANK_ADDR_W      = 11;
    localparam int SRAM_GLOBAL_ADDR = 14;
    localparam int ROWS             = 4;
    localparam int COLS             = 16;
    localparam int ACT_WIDTH        = 16;
    localparam int WEIGHT_WIDTH     = 16;
    localparam int ACCUM_WIDTH      = 40;

    localparam logic [SRAM_GLOBAL_ADDR-1:0] DEFAULT_OFMAP_BASE = 14'h2000;

    // -------------------------------------------------------------------------
    // Clock and Reset Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    // Clock generation (50 MHz / 20ns period: 10ns high, 10ns low)
    initial clk = 1'b0;
    always #10 clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT Interface Signals
    // -------------------------------------------------------------------------
    logic                                 cfg_parallel_en;
    logic                                 cfg_ofmap_drain_en;
    logic [SRAM_GLOBAL_ADDR-1:0]          cfg_ofmap_base_addr;

    logic                                 cmd_valid;
    wire                                  cmd_ready;
    logic [LAYER_ID_W-1:0]                cmd_layer_id;
    logic [1:0]                           cmd_pe_mode;
    logic                                 cmd_adaptive_en;
    logic [DEGRADE_W-1:0]                 cmd_degradation_hat_16;
    logic [DEGRADE_W-1:0]                 cmd_degradation_hat_32;
    logic [DEGRADE_W-1:0]                 cmd_degradation_hat_64;
    logic                                 cmd_use_ping_pong;
    logic                                 cmd_req_buf_id;
    logic [K_WIDTH-1:0]                   cmd_k_total;

    wire                                  layer_done_pulse;
    wire  [LAYER_ID_W-1:0]                layer_done_id;
    wire                                  sequencer_busy;
    wire  [3:0]                           sequencer_state;
    wire                                  sequencer_error_flag;
    wire  [3:0]                           sequencer_error_code;
    logic                                 sequencer_error_clear;

    logic                                 dma_start;
    logic [ADDR_WIDTH-1:0]                dma_src_addr;
    logic [ADDR_WIDTH-1:0]                dma_dst_addr;
    logic [LEN_WIDTH-1:0]                 dma_transfer_len;
    logic                                 dma_use_ping_pong;
    logic                                 dma_error_clear;
    wire                                  dma_busy;
    wire  [2:0]                           dma_state;
    wire                                  dma_done_pulse;
    wire                                  dma_error_flag;
    wire  [3:0]                           dma_error_code;

    wire  [ADDR_WIDTH-1:0]                m_axi_araddr;
    wire  [7:0]                           m_axi_arlen;
    wire  [2:0]                           m_axi_arsize;
    wire  [1:0]                           m_axi_arburst;
    wire                                  m_axi_arvalid;
    logic                                 m_axi_arready;
    logic [DATA_WIDTH-1:0]                m_axi_rdata;
    logic [1:0]                           m_axi_rresp;
    logic                                 m_axi_rlast;
    logic                                 m_axi_rvalid;
    wire                                  m_axi_rready;

    wire  [1:0]                           active_cfg_mode;
    wire  [6:0]                           active_pe_count;
    wire  [COLS-1:0]                      col_active;
    wire  [1:0]                           buf_state_a;
    wire  [1:0]                           buf_state_b;
    wire  [31:0]                          total_produced_count;
    wire  [31:0]                          total_consumed_count;
    wire signed [ACCUM_WIDTH-1:0]         accum_out [0:ROWS-1][0:COLS-1];

    wire                                  ofmap_drain_busy;
    wire                                  ofmap_drain_done;
    wire                                  ofmap_error_flag;
    wire  [7:0]                           ofmap_words_written;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    neural_acc_integrated_top #(
        .ADDR_WIDTH            (ADDR_WIDTH),
        .DATA_WIDTH            (DATA_WIDTH),
        .LEN_WIDTH             (LEN_WIDTH),
        .LAYER_ID_W            (LAYER_ID_W),
        .DEGRADE_W             (DEGRADE_W),
        .K_WIDTH               (K_WIDTH),
        .FIFO_DEPTH            (16),
        .NUM_BANKS             (NUM_BANKS),
        .BYTES_PER_BANK        (5184),
        .BANK_ADDR_W           (BANK_ADDR_W),
        .SRAM_GLOBAL_ADDR      (SRAM_GLOBAL_ADDR),
        .ROWS                  (ROWS),
        .COLS                  (COLS),
        .ACT_WIDTH             (ACT_WIDTH),
        .WEIGHT_WIDTH          (WEIGHT_WIDTH),
        .ACCUM_WIDTH           (ACCUM_WIDTH),
        .PARALLEL_OPERAND_MODE (1'b1),
        .OFMAP_DRAIN_ENABLE    (1'b1),
        .DEFAULT_OFMAP_BASE    (DEFAULT_OFMAP_BASE)
    ) dut (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .cfg_parallel_en           (cfg_parallel_en),
        .cfg_ofmap_drain_en        (cfg_ofmap_drain_en),
        .cfg_ofmap_base_addr       (cfg_ofmap_base_addr),

        .cmd_valid                 (cmd_valid),
        .cmd_ready                 (cmd_ready),
        .cmd_layer_id              (cmd_layer_id),
        .cmd_pe_mode               (cmd_pe_mode),
        .cmd_adaptive_en           (cmd_adaptive_en),
        .cmd_degradation_hat_16    (cmd_degradation_hat_16),
        .cmd_degradation_hat_32    (cmd_degradation_hat_32),
        .cmd_degradation_hat_64    (cmd_degradation_hat_64),
        .cmd_use_ping_pong         (cmd_use_ping_pong),
        .cmd_req_buf_id            (cmd_req_buf_id),
        .cmd_k_total               (cmd_k_total),

        .layer_done_pulse          (layer_done_pulse),
        .layer_done_id             (layer_done_id),
        .sequencer_busy            (sequencer_busy),
        .sequencer_state           (sequencer_state),
        .sequencer_error_flag      (sequencer_error_flag),
        .sequencer_error_code      (sequencer_error_code),
        .sequencer_error_clear     (sequencer_error_clear),

        .dma_start                 (dma_start),
        .dma_src_addr              (dma_src_addr),
        .dma_dst_addr              (dma_dst_addr),
        .dma_transfer_len          (dma_transfer_len),
        .dma_use_ping_pong         (dma_use_ping_pong),
        .dma_error_clear           (dma_error_clear),
        .dma_busy                  (dma_busy),
        .dma_state                 (dma_state),
        .dma_done_pulse            (dma_done_pulse),
        .dma_error_flag            (dma_error_flag),
        .dma_error_code            (dma_error_code),

        .m_axi_araddr              (m_axi_araddr),
        .m_axi_arlen               (m_axi_arlen),
        .m_axi_arsize              (m_axi_arsize),
        .m_axi_arburst             (m_axi_arburst),
        .m_axi_arvalid             (m_axi_arvalid),
        .m_axi_arready             (m_axi_arready),
        .m_axi_rdata               (m_axi_rdata),
        .m_axi_rresp               (m_axi_rresp),
        .m_axi_rlast               (m_axi_rlast),
        .m_axi_rvalid              (m_axi_rvalid),
        .m_axi_rready              (m_axi_rready),

        .active_cfg_mode           (active_cfg_mode),
        .active_pe_count           (active_pe_count),
        .col_active                (col_active),
        .buf_state_a               (buf_state_a),
        .buf_state_b               (buf_state_b),
        .total_produced_count      (total_produced_count),
        .total_consumed_count      (total_consumed_count),
        .accum_out                 (accum_out),

        .ofmap_drain_busy          (ofmap_drain_busy),
        .ofmap_drain_done          (ofmap_drain_done),
        .ofmap_error_flag          (ofmap_error_flag),
        .ofmap_words_written       (ofmap_words_written)
    );

    // -------------------------------------------------------------------------
    // Simulated System Memory Array (AXI4 Backing Store)
    // -------------------------------------------------------------------------
    logic [31:0] sys_memory [0:8191];

    logic [31:0] axi_rd_addr_q;
    logic [7:0]  axi_rd_len_q;
    logic [7:0]  axi_rd_cnt_q;
    logic        axi_rd_active_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_arready   <= 1'b1;
            m_axi_rvalid    <= 1'b0;
            m_axi_rdata     <= '0;
            m_axi_rlast     <= 1'b0;
            m_axi_rresp     <= 2'b00;
            axi_rd_addr_q   <= '0;
            axi_rd_len_q    <= '0;
            axi_rd_cnt_q    <= '0;
            axi_rd_active_q <= 1'b0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                axi_rd_addr_q   <= m_axi_araddr;
                axi_rd_len_q    <= m_axi_arlen;
                axi_rd_cnt_q    <= '0;
                axi_rd_active_q <= 1'b1;
                m_axi_arready   <= 1'b0;
            end

            if (axi_rd_active_q) begin
                if (!m_axi_rvalid || m_axi_rready) begin
                    m_axi_rvalid <= 1'b1;
                    m_axi_rdata  <= sys_memory[(axi_rd_addr_q >> 2) + axi_rd_cnt_q];
                    m_axi_rresp  <= 2'b00;
                    if (axi_rd_cnt_q == axi_rd_len_q) begin
                        m_axi_rlast     <= 1'b1;
                        axi_rd_active_q <= 1'b0;
                        m_axi_arready   <= 1'b1;
                    end else begin
                        m_axi_rlast     <= 1'b0;
                        axi_rd_cnt_q    <= axi_rd_cnt_q + 1'b1;
                    end
                end
            end else if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                m_axi_rlast  <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Verification Tracking & Independent Scoreboard
    // -------------------------------------------------------------------------
    int test_count;
    int pass_count;
    int fail_count;
    int timeout_cnt;

    // Independent 40-bit Golden Reference Tile
    logic signed [ACCUM_WIDTH-1:0] golden_tile [0:ROWS-1][0:COLS-1];

    // Scoreboard tracking for Write Port 1 handshakes
    int scoreboard_write_count;
    int scoreboard_last_write_cycle;
    int current_cycle;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_cycle               <= 0;
            scoreboard_write_count      <= 0;
            scoreboard_last_write_cycle <= -1;
        end else begin
            current_cycle <= current_cycle + 1;
            if (dut.sram_wr_req_bus[1] && dut.sram_wr_ready_bus[1]) begin
                scoreboard_write_count      <= scoreboard_write_count + 1;
                scoreboard_last_write_cycle <= current_cycle;
            end
        end
    end

    // Real-time protocol assertion: layer_done_pulse MUST NEVER fire before 128th accepted write, and NEVER on error
    always @(posedge clk) begin
        if (rst_n && layer_done_pulse) begin
            if (cfg_ofmap_drain_en && scoreboard_write_count < 128) begin
                $fatal(1, "[CRITICAL PROTOCOL VIOLATION] layer_done_pulse fired prematurely or on aborted drain! scoreboard_write_count=%0d (< 128) at cycle %0d",
                         scoreboard_write_count, current_cycle);
            end
            if (sequencer_error_flag || ofmap_error_flag) begin
                $fatal(1, "[CRITICAL PROTOCOL VIOLATION] layer_done_pulse fired while in error state! at cycle %0d", current_cycle);
            end
        end
    end

    // Check helper routines
    task automatic check_val(input string tag, input logic [31:0] actual, input logic [31:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%0d (0x%0h), expected=%0d (0x%0h)", tag, actual, actual, expected, expected);
        end
    endtask

    task automatic check_val40(input string tag, input logic signed [39:0] actual, input logic signed [39:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%0d (0x%0h), expected=%0d (0x%0h)", tag, actual, actual, expected, expected);
        end
    endtask

    task automatic check_bool(input string tag, input logic actual, input logic expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%b, expected=%b", tag, actual, expected);
        end
    endtask

    // Direct Physical SRAM Memory Accessor Functions (mapping to hybrid_sram_bank mem_bank0/mem_bank1)
    function automatic logic [31:0] read_bank_row(input int b_idx, input logic [10:0] r_idx);
        logic [9:0] row_offset;
        row_offset = r_idx[9:0];
        if (!r_idx[10]) begin
            case (b_idx)
                0: return dut.u_sram_subsystem.gen_bank[0].u_sram_bank.mem_bank0[row_offset];
                1: return dut.u_sram_subsystem.gen_bank[1].u_sram_bank.mem_bank0[row_offset];
                2: return dut.u_sram_subsystem.gen_bank[2].u_sram_bank.mem_bank0[row_offset];
                3: return dut.u_sram_subsystem.gen_bank[3].u_sram_bank.mem_bank0[row_offset];
                4: return dut.u_sram_subsystem.gen_bank[4].u_sram_bank.mem_bank0[row_offset];
                5: return dut.u_sram_subsystem.gen_bank[5].u_sram_bank.mem_bank0[row_offset];
                6: return dut.u_sram_subsystem.gen_bank[6].u_sram_bank.mem_bank0[row_offset];
                7: return dut.u_sram_subsystem.gen_bank[7].u_sram_bank.mem_bank0[row_offset];
            endcase
        end else begin
            case (b_idx)
                0: return dut.u_sram_subsystem.gen_bank[0].u_sram_bank.mem_bank1[row_offset];
                1: return dut.u_sram_subsystem.gen_bank[1].u_sram_bank.mem_bank1[row_offset];
                2: return dut.u_sram_subsystem.gen_bank[2].u_sram_bank.mem_bank1[row_offset];
                3: return dut.u_sram_subsystem.gen_bank[3].u_sram_bank.mem_bank1[row_offset];
                4: return dut.u_sram_subsystem.gen_bank[4].u_sram_bank.mem_bank1[row_offset];
                5: return dut.u_sram_subsystem.gen_bank[5].u_sram_bank.mem_bank1[row_offset];
                6: return dut.u_sram_subsystem.gen_bank[6].u_sram_bank.mem_bank1[row_offset];
                7: return dut.u_sram_subsystem.gen_bank[7].u_sram_bank.mem_bank1[row_offset];
            endcase
        end
    endfunction

    function automatic logic [31:0] read_sram_word(input logic [SRAM_GLOBAL_ADDR-1:0] w_addr);
        return read_bank_row(w_addr[2:0], w_addr[13:3]);
    endfunction

    function automatic logic signed [39:0] read_sram_accum(input logic [SRAM_GLOBAL_ADDR-1:0] base, input int coord_idx);
        logic [SRAM_GLOBAL_ADDR-1:0] lo_addr, hi_addr;
        logic [31:0] lo_word, hi_word;
        lo_addr = base + (coord_idx * 2);
        hi_addr = base + (coord_idx * 2) + 1;
        lo_word = read_sram_word(lo_addr);
        hi_word = read_sram_word(hi_addr);
        return {hi_word[7:0], lo_word};
    endfunction

    // Reset Task
    task automatic apply_reset();
        rst_n                  = 1'b0;
        cfg_parallel_en        = 1'b1;
        cfg_ofmap_drain_en     = 1'b1;
        cfg_ofmap_base_addr    = DEFAULT_OFMAP_BASE;
        cmd_valid              = 1'b0;
        cmd_layer_id           = '0;
        cmd_pe_mode            = 2'b10; // 64-PE mode default
        cmd_adaptive_en        = 1'b0;
        cmd_degradation_hat_16 = '0;
        cmd_degradation_hat_32 = '0;
        cmd_degradation_hat_64 = '0;
        cmd_use_ping_pong      = 1'b0;
        cmd_req_buf_id         = 1'b0;
        cmd_k_total            = '0;
        sequencer_error_clear  = 1'b0;
        dma_start              = 1'b0;
        dma_src_addr           = '0;
        dma_dst_addr           = '0;
        dma_transfer_len       = '0;
        dma_use_ping_pong      = 1'b0;
        dma_error_clear        = 1'b0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // Command Dispatch
    task automatic issue_cmd(
        input logic [15:0] id,
        input logic [1:0]  pe_mode,
        input logic        adapt_en,
        input logic        use_pp,
        input logic        buf_id,
        input logic [15:0] k_tot
    );
        @(negedge clk);
        cmd_layer_id      = id;
        cmd_pe_mode       = pe_mode;
        cmd_adaptive_en   = adapt_en;
        cmd_use_ping_pong = use_pp;
        cmd_req_buf_id    = buf_id;
        cmd_k_total       = k_tot;
        cmd_valid         = 1'b1;
        @(negedge clk);
        cmd_valid         = 1'b0;
    endtask

    // DMA Dispatch (dst_addr is byte address in SRAM)
    task automatic start_dma(
        input logic [31:0] src,
        input logic [31:0] dst,
        input logic [15:0] len,
        input logic        use_pp
    );
        @(negedge clk);
        dma_src_addr      = src;
        dma_dst_addr      = dst;
        dma_transfer_len  = len;
        dma_use_ping_pong = use_pp;
        dma_start         = 1'b1;
        @(negedge clk);
        dma_start         = 1'b0;
    endtask

    // Handshake Wait Tasks
    task automatic wait_layer_done(input int max_cycles);
        timeout_cnt = 0;
        while (!layer_done_pulse && (timeout_cnt < max_cycles * 10)) begin
            @(posedge clk);
            timeout_cnt++;
        end
        if (timeout_cnt >= max_cycles * 10) begin
            $display("[ERROR] Timeout waiting for layer_done_pulse!");
            fail_count++;
        end
    endtask

    task automatic wait_dma_done(input int max_cycles);
        timeout_cnt = 0;
        while (!dma_done_pulse && (timeout_cnt < max_cycles * 10)) begin
            @(posedge clk);
            timeout_cnt++;
        end
        if (timeout_cnt >= max_cycles * 10) begin
            $display("[ERROR] Timeout waiting for dma_done_pulse!");
            fail_count++;
        end
    endtask

    // Helper: Pack 10-Word Memory Frame for One K-Step
    task automatic pack_k_step(
        input int word_offset,
        input logic [255:0] w_packed,
        input logic [63:0]  a_packed
    );
        sys_memory[word_offset + 0] = w_packed[31:0];
        sys_memory[word_offset + 1] = w_packed[63:32];
        sys_memory[word_offset + 2] = w_packed[95:64];
        sys_memory[word_offset + 3] = w_packed[127:96];
        sys_memory[word_offset + 4] = w_packed[159:128];
        sys_memory[word_offset + 5] = w_packed[191:160];
        sys_memory[word_offset + 6] = w_packed[223:192];
        sys_memory[word_offset + 7] = w_packed[255:224];
        sys_memory[word_offset + 8] = a_packed[31:0];
        sys_memory[word_offset + 9] = a_packed[63:32];
    endtask

    // Stimulus matrix storage for tests
    logic signed [15:0] t_act [0:ROWS-1][0:31];
    logic signed [15:0] t_wt  [0:COLS-1][0:31];

    // Independent Golden Reference Model Computation
    task automatic compute_golden_and_pack(input int k_len);
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                logic signed [39:0] acc;
                acc = 40'sd0;
                for (int k = 0; k < k_len; k++) begin
                    acc = acc + (t_act[r][k] * t_wt[c][k]);
                end
                golden_tile[r][c] = acc;
            end
        end

        // Pack into sys_memory
        for (int k = 0; k < k_len; k++) begin
            logic [255:0] w_pack;
            logic [63:0]  a_pack;
            for (int c = 0; c < 16; c++) begin
                w_pack[c*16 +: 16] = t_wt[c][k];
            end
            for (int r = 0; r < 4; r++) begin
                a_pack[r*16 +: 16] = t_act[r][k];
            end
            pack_k_step(k * 10, w_pack, a_pack);
        end
    endtask

    // Verify Entire OFMAP Tile from SRAM against Golden Reference
    task automatic verify_sram_ofmap(input string case_name, input logic [SRAM_GLOBAL_ADDR-1:0] base_addr);
        int mismatches;
        mismatches = 0;
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                int coord;
                logic [SRAM_GLOBAL_ADDR-1:0] lo_addr, hi_addr;
                logic [31:0] lo_word, hi_word;
                logic signed [39:0] sram_accum;
                logic signed [39:0] expected_accum;

                coord = (r * 16) + c;
                lo_addr = base_addr + (coord * 2);
                hi_addr = base_addr + (coord * 2) + 1;
                lo_word = read_sram_word(lo_addr);
                hi_word = read_sram_word(hi_addr);
                sram_accum = {hi_word[7:0], lo_word};
                expected_accum = golden_tile[r][c];

                // Verify exact 40-bit signed value
                if (sram_accum !== expected_accum) begin
                    mismatches++;
                    if (mismatches == 1) begin
                        $display("[FIRST MISMATCH] %s at (r=%0d, c=%0d): sram_accum=%0d, expected=%0d",
                                 case_name, r, c, sram_accum, expected_accum);
                    end
                end
                check_val40($sformatf("%s: SRAM accum PE[%0d][%0d]", case_name, r, c), sram_accum, expected_accum);

                // Verify exact lower 32-bit word
                check_val($sformatf("%s: Word0 [31:0] PE[%0d][%0d]", case_name, r, c), lo_word, expected_accum[31:0]);

                // Verify exact sign-extension in upper 24 bits of word 1
                check_val($sformatf("%s: Word1 [31:8] sign-ext PE[%0d][%0d]", case_name, r, c),
                          hi_word[31:8], {24{expected_accum[39]}});

                // Verify upper 8 bits in word 1
                check_val($sformatf("%s: Word1 [7:0] PE[%0d][%0d]", case_name, r, c),
                          hi_word[7:0], expected_accum[39:32]);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Verification Process
    // -------------------------------------------------------------------------
    initial begin
        $display("==================================================================");
        $display("TSK-11 Phase 2B/2C: End-to-End OFMAP Drain Integration Suite");
        $display("==================================================================");
        test_count = 0;
        pass_count = 0;
        fail_count = 0;

        // =====================================================================
        // SCENARIO 1: Basic Compute + Complete Drain & Handshake Sequence
        // =====================================================================
        $display("\n--- SCENARIO 1: Basic Compute + Complete Drain & Handshake Sequence ---");
        apply_reset();
        scoreboard_write_count = 0;

        // Initialize K=1 distinct positive operands
        for (int r = 0; r < ROWS; r++) t_act[r][0] = 16'sd10 + r;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd20 + c;
        compute_golden_and_pack(1);

        // DMA Transfer into Buffer A (40 bytes = 10 words)
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        check_val("S1.1: DMA finished", dma_done_pulse, 1'b1);

        // Issue Layer 101 Command (64-PE mode, Buffer A, K=1)
        issue_cmd(16'd101, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);

        // Wait for layer completion
        wait_layer_done(300);
        check_val("S1.2: Layer 101 completed with pulse", layer_done_pulse, 1'b1);
        check_val("S1.3: Completed layer ID matches 101", layer_done_id, 16'd101);

        // Verify that layer_done_pulse occurred strictly AFTER 128th accepted write
        check_bool("S1.4: 128 writes accepted before completion",
                   (scoreboard_write_count == 128), 1'b1);
        check_val("S1.5: OFMAP words written status is 128", ofmap_words_written, 8'd128);

        // Verify SRAM contents for all 64 coordinates
        verify_sram_ofmap("S1", DEFAULT_OFMAP_BASE);

        // =====================================================================
        // SCENARIO 2: Positive and Negative Accumulator Outputs
        // =====================================================================
        $display("\n--- SCENARIO 2: Positive and Negative Accumulator Outputs ---");
        apply_reset();
        scoreboard_write_count = 0;

        // Initialize K=2 mixed sign operands
        for (int r = 0; r < ROWS; r++) begin
            t_act[r][0] = (r % 2 == 0) ? 16'sd15 : -16'sd25;
            t_act[r][1] = (r % 2 == 0) ? -16'sd8 : 16'sd30;
        end
        for (int c = 0; c < COLS; c++) begin
            t_wt[c][0] = (c % 2 == 0) ? 16'sd12 : -16'sd18;
            t_wt[c][1] = (c % 2 == 0) ? -16'sd14 : 16'sd22;
        end
        compute_golden_and_pack(2);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd80, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd102, 2'b10, 1'b0, 1'b0, 1'b0, 16'd2);
        wait_layer_done(300);

        check_val("S2.1: Layer 102 completed", layer_done_id, 16'd102);
        check_val("S2.2: Exactly 128 accepted writes", scoreboard_write_count, 128);
        verify_sram_ofmap("S2", DEFAULT_OFMAP_BASE);

        // =====================================================================
        // SCENARIO 3: Boundary Values & Sign Extension
        // =====================================================================
        $display("\n--- SCENARIO 3: Boundary Values & Sign Extension ---");
        apply_reset();
        scoreboard_write_count = 0;

        // Test extreme values: max positive, max negative, 0, -1
        for (int r = 0; r < ROWS; r++) begin
            t_act[r][0] = (r == 0) ? 16'sd32767 : ((r == 1) ? -16'sd32768 : ((r == 2) ? 16'sd0 : -16'sd1));
        end
        for (int c = 0; c < COLS; c++) begin
            t_wt[c][0]  = (c % 4 == 0) ? 16'sd32767 : ((c % 4 == 1) ? -16'sd32768 : ((c % 4 == 2) ? 16'sd1 : -16'sd1));
        end
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd103, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);
        wait_layer_done(300);

        check_val("S3.1: Layer 103 completed", layer_done_id, 16'd103);
        check_val("S3.2: Exactly 128 accepted writes", scoreboard_write_count, 128);
        verify_sram_ofmap("S3", DEFAULT_OFMAP_BASE);

        // =====================================================================
        // SCENARIO 4: Exactly 128 Accepted OFMAP Writes (Count Verification)
        // =====================================================================
        $display("\n--- SCENARIO 4: Exactly 128 Accepted OFMAP Writes ---");
        check_val("S4.1: Scoreboard total accepted writes", scoreboard_write_count, 128);
        check_val("S4.2: Controller reported words written", ofmap_words_written, 8'd128);
        // Wait an additional 20 cycles and confirm no extraneous writes occur
        repeat (20) @(posedge clk);
        check_val("S4.3: Write count remains strictly 128", scoreboard_write_count, 128);

        // =====================================================================
        // SCENARIO 5: Concurrent Operations - DMA Ingress & OFMAP Write (Different Banks)
        // =====================================================================
        $display("\n--- SCENARIO 5: Concurrent DMA Ingress & OFMAP Write (Diff Banks) ---");
        apply_reset();
        scoreboard_write_count = 0;

        // Set up compute data for Layer 105 in Buffer A
        for (int r = 0; r < ROWS; r++) t_act[r][0] = 16'sd40 + r;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd50 + c;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd105, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);

        // Wait until compute completes and drain starts
        while (!ofmap_drain_busy) @(posedge clk);

        // Concurrently launch DMA write to Buffer B (Bank 4..7, address 0x4000)
        start_dma(32'h0000_0000, 32'h0000_4000, 16'd40, 1'b0);

        // Wait for both to complete concurrently
        fork
            wait_layer_done(300);
            wait_dma_done(100);
        join

        check_val("S5.1: Layer 105 completed concurrently with DMA", layer_done_id, 16'd105);
        check_val("S5.2: Exactly 128 accepted OFMAP writes", scoreboard_write_count, 128);
        verify_sram_ofmap("S5", DEFAULT_OFMAP_BASE);

        // =====================================================================
        // SCENARIO 6: Concurrent Operations - DMA Ingress & OFMAP Write (Same Bank Arbitration)
        // =====================================================================
        $display("\n--- SCENARIO 6: Concurrent DMA Ingress & OFMAP Write (Same Bank Conflict) ---");
        apply_reset();
        scoreboard_write_count = 0;

        for (int r = 0; r < ROWS; r++) t_act[r][0] = 16'sd12 + r;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd18 + c;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd106, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);

        // Wait until drain is actively writing to Bank 0 (word addresses 0, 8, 16, etc. in OFMAP)
        while (!ofmap_drain_busy) @(posedge clk);

        // Concurrently launch DMA write targeting Bank 0 (byte address 0 in Buffer A)
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);

        fork
            wait_layer_done(300);
            wait_dma_done(100);
        join

        check_val("S6.1: Layer 106 completed despite same-bank arbitration", layer_done_id, 16'd106);
        check_val("S6.2: Exactly 128 accepted OFMAP writes", scoreboard_write_count, 128);
        verify_sram_ofmap("S6", DEFAULT_OFMAP_BASE);

        // =====================================================================
        // SCENARIO 7: Backpressure During Drain & Hold Stability
        // =====================================================================
        $display("\n--- SCENARIO 7: Backpressure During Drain & Hold Stability ---");
        apply_reset();
        scoreboard_write_count = 0;

        for (int r = 0; r < ROWS; r++) t_act[r][0] = 16'sd25;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd14;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd107, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);

        while (!ofmap_drain_busy) @(posedge clk);

        // While drain is running, verify signal hold stability if wr_ready is low
        fork
            begin : monitor_hold
                int hold_checks;
                hold_checks = 0;
                while (ofmap_drain_busy) begin
                    @(posedge clk);
                    if (dut.sram_wr_req_bus[1] && !dut.sram_wr_ready_bus[1]) begin
                        logic [SRAM_GLOBAL_ADDR-1:0] held_addr;
                        logic [DATA_WIDTH-1:0] held_din;
                        held_addr = dut.sram_wr_addr_bus[1];
                        held_din  = dut.sram_wr_din_bus[1];
                        @(posedge clk);
                        if (dut.sram_wr_req_bus[1]) begin
                            check_val("S7.1: Held addr stable under stall", dut.sram_wr_addr_bus[1], held_addr);
                            check_val("S7.2: Held data stable under stall", dut.sram_wr_din_bus[1], held_din);
                            hold_checks++;
                        end
                    end
                end
            end
            begin : wait_done
                wait_layer_done(300);
            end
        join

        check_val("S7.3: Layer 107 completed after stalls", layer_done_id, 16'd107);
        check_val("S7.4: Exactly 128 accepted OFMAP writes", scoreboard_write_count, 128);
        verify_sram_ofmap("S7", DEFAULT_OFMAP_BASE);

        // =====================================================================
        // SCENARIO 8: Next-Layer Command Arrival Before Drain Completes (Lockout)
        // =====================================================================
        $display("\n--- SCENARIO 8: Next-Layer Command Lockout During Drain ---");
        apply_reset();
        scoreboard_write_count = 0;

        for (int r = 0; r < ROWS; r++) t_act[r][0] = 16'sd33;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd44;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd108, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);

        // Wait until compute done and OFMAP drain is active
        while (!ofmap_drain_busy) @(posedge clk);

        // Attempt to issue a new layer command mid-drain
        @(negedge clk);
        cmd_valid    = 1'b1;
        cmd_layer_id = 16'd999;
        @(posedge clk);
        check_bool("S8.1: Sequencer rejects new command during drain", cmd_ready, 1'b0);
        check_bool("S8.2: Controller accum_clear NOT asserted during drain", dut.pe_array_accum_clear, 1'b0);

        @(negedge clk);
        cmd_valid = 1'b0;

        // In-progress drain completes safely
        wait_layer_done(300);
        check_val("S8.3: Layer 108 completed safely", layer_done_id, 16'd108);
        check_val("S8.4: Exactly 128 writes accepted", scoreboard_write_count, 128);
        verify_sram_ofmap("S8", DEFAULT_OFMAP_BASE);

        // =====================================================================
        // SCENARIO 9: Asynchronous Reset During Drain & Recovery
        // =====================================================================
        $display("\n--- SCENARIO 9: Reset During Active Drain & Recovery ---");
        apply_reset();
        scoreboard_write_count = 0;

        for (int r = 0; r < ROWS; r++) t_act[r][0] = 16'sd15;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd25;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd109, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);

        // Wait until drain has written ~40 words
        while (ofmap_words_written < 40) @(posedge clk);

        // Assert reset mid-drain
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        check_bool("S9.1: Drain busy drops immediately on reset", ofmap_drain_busy, 1'b0);
        check_bool("S9.2: SRAM write request dropped on reset", dut.sram_wr_req_bus[1], 1'b0);

        // Deassert reset and verify clean recovery with Layer 110
        @(negedge clk);
        rst_n = 1'b1;
        scoreboard_write_count = 0;
        repeat (5) @(posedge clk);

        for (int r = 0; r < ROWS; r++) t_act[r][0] = 16'sd18;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd22;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd110, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);
        wait_layer_done(300);

        check_val("S9.3: Post-reset Layer 110 completed", layer_done_id, 16'd110);
        check_val("S9.4: Clean 128 accepted writes on recovery", scoreboard_write_count, 128);
        verify_sram_ofmap("S9", DEFAULT_OFMAP_BASE);

        // =====================================================================
        // SCENARIO 10: Invalid OFMAP Base Address Detection & Error Handling (TEST B & TEST C)
        // =====================================================================
        $display("\n--- SCENARIO 10: Invalid OFMAP Base Address Detection & Error Handling (TEST B & TEST C) ---");
        apply_reset();
        scoreboard_write_count = 0;

        // Set illegal base address > 10240 (14'h2840 = 10304)
        cfg_ofmap_base_addr = 14'h2840;

        for (int r = 0; r < ROWS; r++) t_act[r][0] = 16'sd5;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd5;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd111, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);

        // Wait until compute completes and sequencer encounters drain error
        begin
            int err_wait;
            err_wait = 0;
            while (!sequencer_error_flag && (err_wait < 300)) begin
                @(posedge clk);
                err_wait++;
            end
            if (err_wait >= 300) begin
                $fatal(1, "[TEST B FAIL] Timeout waiting for sequencer_error_flag on invalid base address!");
            end
        end

        // TEST B VERIFICATIONS:
        check_bool("Test_B.1: OFMAP error flag asserted on invalid base", ofmap_error_flag, 1'b1);
        check_bool("Test_B.2: Sequencer error flag asserted", sequencer_error_flag, 1'b1);
        check_val("Test_B.3: Sequencer error code is ERR_OFMAP_DRAIN (5)", sequencer_error_code, 4'd5);
        check_val("Test_B.4: Zero SRAM writes issued on invalid address", scoreboard_write_count, 0);
        check_bool("Test_B.5: cmd_ready deasserted while sequencer is in error", cmd_ready, 1'b0);

        // Confirm layer_done_pulse NEVER asserts during error (monitor for 50 cycles)
        for (int w = 0; w < 50; w++) begin
            @(posedge clk);
            if (layer_done_pulse) begin
                $fatal(1, "[TEST B FAIL] layer_done_pulse was asserted for failed command! (Cycle %0d)", w);
            end
        end
        check_bool("Test_B.6: layer_done_pulse strictly NEVER asserted for invalid command", 1'b1, 1'b1);

        // TEST C VERIFICATIONS: Recovery after invalid address without hardware reset
        $display("\n--- SCENARIO 10.1: Recovery After Invalid Address (TEST C) ---");
        // Pulse sequencer_error_clear
        @(negedge clk);
        sequencer_error_clear = 1'b1;
        @(posedge clk);
        #1;
        check_bool("Test_C.1: Sequencer error flag cleared on error_clear pulse", sequencer_error_flag, 1'b0);
        check_val("Test_C.2: Sequencer error code cleared", sequencer_error_code, 4'd0);
        check_bool("Test_C.3: OFMAP error flag cleared on error_clear pulse", ofmap_error_flag, 1'b0);
        check_bool("Test_C.4: cmd_ready restored to 1", cmd_ready, 1'b1);
        check_val("Test_C.5: Sequencer returned to ST_IDLE (0)", sequencer_state, 4'd0);
        @(negedge clk);
        sequencer_error_clear = 1'b0;

        // Restore legal OFMAP base address
        cfg_ofmap_base_addr = DEFAULT_OFMAP_BASE; // 14'h2000
        scoreboard_write_count = 0;

        // Issue valid subsequent command (Layer 112) WITHOUT hardware reset
        for (int r = 0; r < ROWS; r++) t_act[r][0] = 16'sd7;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd9;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd112, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);

        wait_layer_done(300);

        check_val("Test_C.6: Layer 112 completed successfully post-recovery", layer_done_id, 16'd112);
        check_val("Test_C.7: Exactly 128 accepted writes for Layer 112", scoreboard_write_count, 128);
        check_bool("Test_C.8: Sequencer error flag remains clear", sequencer_error_flag, 1'b0);
        check_bool("Test_C.9: OFMAP error flag remains clear", ofmap_error_flag, 1'b0);
        verify_sram_ofmap("Test_C", DEFAULT_OFMAP_BASE);

        // =====================================================================
        // SCENARIO 10B: Error Followed by Multiple Valid Commands (TEST D)
        // =====================================================================
        $display("\n--- SCENARIO 10B: Error Followed by Multiple Valid Commands (TEST D) ---");
        // Issue Layer 113 to non-overlapping base 14'h2100 WITHOUT hardware reset
        scoreboard_write_count = 0;
        cfg_ofmap_base_addr = 14'h2100;
        for (int r = 0; r < ROWS; r++) t_act[r][0] = 16'sd11;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd13;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd113, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);
        wait_layer_done(300);

        check_val("Test_D.1: Layer 113 completed successfully", layer_done_id, 16'd113);
        check_val("Test_D.2: Exactly 128 accepted writes for Layer 113", scoreboard_write_count, 128);
        check_bool("Test_D.3: Zero error flags on Layer 113", sequencer_error_flag | ofmap_error_flag, 1'b0);
        verify_sram_ofmap("Test_D_L113", 14'h2100);

        // Issue Layer 114 to non-overlapping base 14'h2200 WITHOUT hardware reset
        scoreboard_write_count = 0;
        cfg_ofmap_base_addr = 14'h2200;
        for (int r = 0; r < ROWS; r++) t_act[r][0] = -16'sd14;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd6;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd114, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);
        wait_layer_done(300);

        check_val("Test_D.4: Layer 114 completed successfully", layer_done_id, 16'd114);
        check_val("Test_D.5: Exactly 128 accepted writes for Layer 114", scoreboard_write_count, 128);
        check_bool("Test_D.6: Zero error flags on Layer 114", sequencer_error_flag | ofmap_error_flag, 1'b0);
        verify_sram_ofmap("Test_D_L114", 14'h2200);

        cfg_ofmap_base_addr = DEFAULT_OFMAP_BASE;

        // =====================================================================
        // SCENARIO 11: Consecutive Layers Without Partial Sum Contamination
        // =====================================================================
        $display("\n--- SCENARIO 11: Consecutive Layers Without Partial Sum Contamination ---");
        apply_reset();
        scoreboard_write_count = 0;

        // Layer 1: Positive Operands drained to 14'h2000
        cfg_ofmap_base_addr = 14'h2000;
        for (int r = 0; r < ROWS; r++) t_act[r][0] = 16'sd10;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd20;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd201, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);
        wait_layer_done(300);

        check_val("S11.1: Layer 201 completed", layer_done_id, 16'd201);
        check_val("S11.2: Layer 201 accepted writes", scoreboard_write_count, 128);
        verify_sram_ofmap("S11_L1", 14'h2000);

        // Layer 2: Negative Operands drained to 14'h2100 (non-overlapping)
        scoreboard_write_count = 0;
        cfg_ofmap_base_addr = 14'h2100;
        for (int r = 0; r < ROWS; r++) t_act[r][0] = -16'sd15;
        for (int c = 0; c < COLS; c++) t_wt[c][0]  = 16'sd25;
        compute_golden_and_pack(1);

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);
        issue_cmd(16'd202, 2'b10, 1'b0, 1'b0, 1'b0, 16'd1);
        wait_layer_done(300);

        check_val("S11.3: Layer 202 completed", layer_done_id, 16'd202);
        check_val("S11.4: Layer 202 accepted writes", scoreboard_write_count, 128);
        verify_sram_ofmap("S11_L2", 14'h2100);

        // Re-verify Layer 1's memory region to confirm zero corruption by Layer 2
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                int coord;
                coord = (r * 16) + c;
                check_val40($sformatf("S11_L1_Preserved: PE[%0d][%0d]", r, c),
                            read_sram_accum(14'h2000, coord), 40'sd200);
            end
        end

        // =====================================================================
        // Final Summary
        // =====================================================================
        $display("\n==================================================================");
        $display("TSK-11 Phase 2B/2C OFMAP Integration Verification Summary:");
        $display("Total Checks: %0d | Passed: %0d | Failed: %0d", test_count, pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-11 OFMAP Integration Tests Passed with Zero Failures!\n");
            $finish(0);
        end else begin
            $display("[FAILURE] %0d TSK-11 OFMAP Integration Checks FAILED!\n", fail_count);
            $fatal(1, "TSK-11 OFMAP Integration Checks FAILED");
        end
    end

endmodule
