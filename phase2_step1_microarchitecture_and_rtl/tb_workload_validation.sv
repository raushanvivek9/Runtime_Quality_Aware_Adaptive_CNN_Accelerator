// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-08 Functional Workload Validation and Baseline Comparison
// Module: tb_workload_validation.sv
// Description: Comprehensive testbench validating deterministic computational
//              workloads, SRAM-to-PE dataflow, 10 arithmetic categories,
//              fixed vs. adaptive PE configuration comparisons, and adaptive policy.
// =============================================================================

`timescale 1ns / 1ps

module tb_workload_validation;

    // -------------------------------------------------------------------------
    // System Parameters
    // -------------------------------------------------------------------------
    localparam time CLK_PERIOD          = 10ns;
    localparam int  LAYER_ID_W          = 16;
    localparam int  K_WIDTH             = 16;
    localparam int  DEGRADE_W           = 32;
    localparam int  ADDR_WIDTH          = 32;
    localparam int  DATA_WIDTH          = 32;
    localparam int  LEN_WIDTH           = 16;
    localparam int  FIFO_DEPTH          = 8;
    localparam int  NUM_BANKS           = 8;
    localparam int  BYTES_PER_BANK      = 5184;
    localparam int  BANK_ADDR_W         = 11;
    localparam int  SRAM_GLOBAL_ADDR    = 14;
    localparam int  ROWS                = 4;
    localparam int  COLS                = 16;
    localparam int  ACT_WIDTH           = 16;
    localparam int  WEIGHT_WIDTH        = 16;
    localparam int  ACCUM_WIDTH         = 40;

    localparam logic signed [39:0] SAT_MAX_POS = 40'sh7F_FFFF_FFFF;
    localparam logic signed [39:0] SAT_MAX_NEG = -40'sh80_0000_0000;
    localparam int D_MAX_Q16                   = 3277;

    // Clock and Reset
    logic                      clk;
    logic                      rst_n;

    // Command Interface
    logic                      cmd_valid;
    wire                       cmd_ready;
    logic [LAYER_ID_W-1:0]     cmd_layer_id;
    logic [1:0]                cmd_pe_mode;
    logic                      cmd_adaptive_en;
    logic [DEGRADE_W-1:0]      cmd_degradation_hat_16;
    logic [DEGRADE_W-1:0]      cmd_degradation_hat_32;
    logic [DEGRADE_W-1:0]      cmd_degradation_hat_64;
    logic                      cmd_use_ping_pong;
    logic                      cmd_req_buf_id;
    logic [K_WIDTH-1:0]        cmd_k_total;

    wire                       layer_done_pulse;
    wire  [LAYER_ID_W-1:0]     layer_done_id;
    wire                       sequencer_busy;
    wire  [3:0]                sequencer_state;
    wire                       sequencer_error_flag;
    wire  [3:0]                sequencer_error_code;
    logic                      sequencer_error_clear;

    // DMA Interface
    logic                      dma_start;
    logic [ADDR_WIDTH-1:0]     dma_src_addr;
    logic [ADDR_WIDTH-1:0]     dma_dst_addr;
    logic [LEN_WIDTH-1:0]      dma_transfer_len;
    logic                      dma_use_ping_pong;
    logic                      dma_error_clear;
    wire                       dma_busy;
    wire  [2:0]                dma_state;
    wire                       dma_done_pulse;
    wire                       dma_error_flag;
    wire  [3:0]                dma_error_code;

    // AXI Master Read Bus
    wire  [ADDR_WIDTH-1:0]     m_axi_araddr;
    wire  [7:0]                m_axi_arlen;
    wire  [2:0]                m_axi_arsize;
    wire  [1:0]                m_axi_arburst;
    wire                       m_axi_arvalid;
    logic                      m_axi_arready;

    logic [DATA_WIDTH-1:0]     m_axi_rdata;
    logic [1:0]                m_axi_rresp;
    logic                      m_axi_rlast;
    logic                      m_axi_rvalid;
    wire                       m_axi_rready;

    // Top-Level Datapath Outputs
    wire  signed [ACCUM_WIDTH-1:0] accum_out [0:ROWS-1][0:COLS-1];
    wire                       array_sticky_saturation;
    wire  [COLS-1:0]           col_sticky_saturation;
    wire  [1:0]                active_cfg_mode;
    wire  [6:0]                active_pe_count;
    wire  [COLS-1:0]           col_active;

    // Diagnostics
    wire  [1:0]                buf_state_a;
    wire  [1:0]                buf_state_b;
    wire  [31:0]               total_produced_count;
    wire  [31:0]               total_consumed_count;

    // -------------------------------------------------------------------------
    // Top-Level Accelerator Core Under Test
    // -------------------------------------------------------------------------
    neural_acc_integrated_top #(
        .LAYER_ID_W       (LAYER_ID_W),
        .K_WIDTH          (K_WIDTH),
        .DEGRADE_W        (DEGRADE_W),
        .ADDR_WIDTH       (ADDR_WIDTH),
        .DATA_WIDTH       (DATA_WIDTH),
        .LEN_WIDTH        (LEN_WIDTH),
        .FIFO_DEPTH       (FIFO_DEPTH),
        .NUM_BANKS        (NUM_BANKS),
        .BYTES_PER_BANK   (BYTES_PER_BANK),
        .BANK_ADDR_W      (BANK_ADDR_W),
        .SRAM_GLOBAL_ADDR (SRAM_GLOBAL_ADDR),
        .ROWS             (ROWS),
        .COLS             (COLS),
        .ACT_WIDTH        (ACT_WIDTH),
        .WEIGHT_WIDTH     (WEIGHT_WIDTH),
        .ACCUM_WIDTH      (ACCUM_WIDTH)
    ) dut (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .cmd_valid                (cmd_valid),
        .cmd_ready                (cmd_ready),
        .cmd_layer_id             (cmd_layer_id),
        .cmd_pe_mode              (cmd_pe_mode),
        .cmd_adaptive_en          (cmd_adaptive_en),
        .cmd_degradation_hat_16   (cmd_degradation_hat_16),
        .cmd_degradation_hat_32   (cmd_degradation_hat_32),
        .cmd_degradation_hat_64   (cmd_degradation_hat_64),
        .cmd_use_ping_pong        (cmd_use_ping_pong),
        .cmd_req_buf_id           (cmd_req_buf_id),
        .cmd_k_total              (cmd_k_total),
        .layer_done_pulse         (layer_done_pulse),
        .layer_done_id            (layer_done_id),
        .sequencer_busy           (sequencer_busy),
        .sequencer_state          (sequencer_state),
        .sequencer_error_flag     (sequencer_error_flag),
        .sequencer_error_code     (sequencer_error_code),
        .sequencer_error_clear    (sequencer_error_clear),
        .dma_start                (dma_start),
        .dma_src_addr             (dma_src_addr),
        .dma_dst_addr             (dma_dst_addr),
        .dma_transfer_len         (dma_transfer_len),
        .dma_use_ping_pong        (dma_use_ping_pong),
        .dma_error_clear          (dma_error_clear),
        .dma_busy                 (dma_busy),
        .dma_state                (dma_state),
        .dma_done_pulse           (dma_done_pulse),
        .dma_error_flag           (dma_error_flag),
        .dma_error_code           (dma_error_code),
        .m_axi_araddr             (m_axi_araddr),
        .m_axi_arlen              (m_axi_arlen),
        .m_axi_arsize             (m_axi_arsize),
        .m_axi_arburst            (m_axi_arburst),
        .m_axi_arvalid            (m_axi_arvalid),
        .m_axi_arready            (m_axi_arready),
        .m_axi_rdata              (m_axi_rdata),
        .m_axi_rresp              (m_axi_rresp),
        .m_axi_rlast              (m_axi_rlast),
        .m_axi_rvalid             (m_axi_rvalid),
        .m_axi_rready             (m_axi_rready),
        .accum_out                (accum_out),
        .array_sticky_saturation  (array_sticky_saturation),
        .col_sticky_saturation    (col_sticky_saturation),
        .active_cfg_mode          (active_cfg_mode),
        .active_pe_count          (active_pe_count),
        .col_active               (col_active),
        .buf_state_a              (buf_state_a),
        .buf_state_b              (buf_state_b),
        .total_produced_count     (total_produced_count),
        .total_consumed_count     (total_consumed_count)
    );

    // -------------------------------------------------------------------------
    // Standalone PE Array Instance (for Category 6/7 Distinct Unbroadcast Verification)
    // -------------------------------------------------------------------------
    logic [1:0]                   sa_cfg_mode;
    wire                          sa_cfg_invalid;
    wire  [6:0]                   sa_active_pe_count;
    wire  [COLS-1:0]              sa_col_active;
    logic                         sa_enable;
    logic [COLS-1:0]              sa_col_enable;
    logic                         sa_accum_clear;
    logic                         sa_sat_clear;
    logic                         sa_broadcast_act;
    logic signed [ACT_WIDTH-1:0]  sa_act_data_row [0:ROWS-1];
    logic                         sa_act_mask_row [0:ROWS-1];
    logic signed [ACT_WIDTH-1:0]  sa_act_data     [0:ROWS-1][0:COLS-1];
    logic                         sa_act_mask     [0:ROWS-1][0:COLS-1];
    logic signed [WEIGHT_WIDTH-1:0] sa_weight_data [0:ROWS-1][0:COLS-1];
    wire  signed [ACCUM_WIDTH-1:0] sa_accum_out   [0:ROWS-1][0:COLS-1];
    wire                          sa_sticky_saturation [0:ROWS-1][0:COLS-1];
    wire                          sa_cycle_skipped     [0:ROWS-1][0:COLS-1];
    wire  [COLS-1:0]              sa_col_sticky_saturation;
    wire  [COLS-1:0]              sa_col_cycle_skipped;
    wire                          sa_array_sticky_saturation;

    pe_array_40b #(
        .ROWS         (ROWS),
        .COLS         (COLS),
        .ACT_WIDTH    (ACT_WIDTH),
        .WEIGHT_WIDTH (WEIGHT_WIDTH),
        .ACCUM_WIDTH  (ACCUM_WIDTH)
    ) u_standalone_pe_array (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .cfg_mode                (sa_cfg_mode),
        .cfg_invalid             (sa_cfg_invalid),
        .active_pe_count         (sa_active_pe_count),
        .col_active              (sa_col_active),
        .enable                  (sa_enable),
        .col_enable              (sa_col_enable),
        .accum_clear             (sa_accum_clear),
        .sat_clear               (sa_sat_clear),
        .broadcast_act           (sa_broadcast_act),
        .act_data_row            (sa_act_data_row),
        .act_mask_row            (sa_act_mask_row),
        .act_data                (sa_act_data),
        .act_mask                (sa_act_mask),
        .weight_data             (sa_weight_data),
        .accum_out               (sa_accum_out),
        .sticky_saturation       (sa_sticky_saturation),
        .cycle_skipped           (sa_cycle_skipped),
        .col_sticky_saturation   (sa_col_sticky_saturation),
        .col_cycle_skipped       (sa_col_cycle_skipped),
        .array_sticky_saturation (sa_array_sticky_saturation)
    );

    // -------------------------------------------------------------------------
    // Emulation Memory & AXI Responder
    // -------------------------------------------------------------------------
    logic [31:0] sys_memory [0:4095];
    logic [31:0] ar_fifo_addr [0:63];
    int          ar_fifo_delay [0:63];
    int          ar_wr_ptr, ar_rd_ptr;
    int          cfg_ar_delay;
    int          cfg_r_delay;
    int          ar_wait_cnt;

    // Simulation & Measurement Registers
    int          test_count;
    int          pass_count;
    int          fail_count;
    int          idx, loop_i, timeout_cnt;

    // Cycle & Performance Metrics Tracking
    int          cycle_counter;
    int          meas_start_cycle;
    int          meas_total_cycles;
    int          meas_compute_cycles;
    int          meas_pe_active_cycles;
    int          meas_sram_rd_trans;
    int          meas_sram_wr_trans;
    int          meas_config_changes;
    int          meas_pipeline_stalls;

    // Clock Generation
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Cycle tracking
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_counter <= 0;
        end else begin
            cycle_counter <= cycle_counter + 1;
        end
    end

    // AXI Slave Memory responder
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_arready <= 1'b0;
            m_axi_rvalid  <= 1'b0;
            m_axi_rdata   <= '0;
            m_axi_rresp   <= 2'b00;
            m_axi_rlast   <= 1'b0;
            ar_wait_cnt   <= 0;
            ar_wr_ptr     <= 0;
            ar_rd_ptr     <= 0;
        end else begin
            if (m_axi_arvalid) begin
                if (ar_wait_cnt < cfg_ar_delay) begin
                    m_axi_arready <= 1'b0;
                    ar_wait_cnt   <= ar_wait_cnt + 1;
                end else begin
                    m_axi_arready <= 1'b1;
                    ar_wait_cnt   <= 0;
                end
            end else begin
                m_axi_arready <= 1'b0;
                ar_wait_cnt   <= 0;
            end

            if (m_axi_arvalid && m_axi_arready) begin
                ar_fifo_addr[ar_wr_ptr]  <= m_axi_araddr;
                ar_fifo_delay[ar_wr_ptr] <= cfg_r_delay;
                ar_wr_ptr                <= ar_wr_ptr + 1;
            end

            if (m_axi_rvalid && m_axi_rready) begin
                ar_rd_ptr    <= ar_rd_ptr + 1;
                m_axi_rvalid <= 1'b0;
            end else if (ar_rd_ptr != ar_wr_ptr) begin
                if (ar_fifo_delay[ar_rd_ptr] > 0) begin
                    ar_fifo_delay[ar_rd_ptr] <= ar_fifo_delay[ar_rd_ptr] - 1;
                    m_axi_rvalid             <= 1'b0;
                end else begin
                    m_axi_rvalid <= 1'b1;
                    m_axi_rdata  <= sys_memory[(ar_fifo_addr[ar_rd_ptr] >> 2) & 12'hFFF];
                    m_axi_rresp  <= 2'b00;
                    m_axi_rlast  <= 1'b1;
                end
            end else begin
                m_axi_rvalid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Verification Assertion Tasks
    // -------------------------------------------------------------------------
    task automatic check_val(input string tag, input logic [31:0] actual, input logic [31:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=0x%08X (dec %0d), expected=0x%08X (dec %0d)",
                     tag, actual, actual, expected, expected);
        end
    endtask

    task automatic check_val40(input string tag, input logic signed [39:0] actual, input logic signed [39:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%0d, expected=%0d", tag, actual, expected);
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

    // System Reset
    task automatic apply_reset();
        rst_n                  = 1'b0;
        cmd_valid              = 1'b0;
        cmd_layer_id           = '0;
        cmd_pe_mode            = 2'b00;
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

        cfg_ar_delay           = 0;
        cfg_r_delay            = 0;
        ar_wait_cnt            = 0;
        ar_wr_ptr              = 0;
        ar_rd_ptr              = 0;

        // Reset standalone PE array
        sa_cfg_mode            = 2'b10;
        sa_enable              = 1'b0;
        sa_col_enable          = '1;
        sa_accum_clear         = 1'b0;
        sa_sat_clear           = 1'b0;
        sa_broadcast_act       = 1'b0;
        for (int r = 0; r < ROWS; r++) begin
            sa_act_data_row[r] = '0;
            sa_act_mask_row[r] = 1'b0;
            for (int c = 0; c < COLS; c++) begin
                sa_act_data[r][c]    = '0;
                sa_act_mask[r][c]    = 1'b0;
                sa_weight_data[r][c] = '0;
            end
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // Command Dispatch Task with Degradation Configuration
    task automatic issue_cmd_full(
        input logic [15:0] id,
        input logic [1:0]  mode,
        input logic        adapt_en,
        input logic [31:0] deg16,
        input logic [31:0] deg32,
        input logic [31:0] deg64,
        input logic        use_pp,
        input logic        buf_id,
        input logic [15:0] k_tot
    );
        @(negedge clk);
        cmd_valid              = 1'b1;
        cmd_layer_id           = id;
        cmd_pe_mode            = mode;
        cmd_adaptive_en        = adapt_en;
        cmd_degradation_hat_16 = deg16;
        cmd_degradation_hat_32 = deg32;
        cmd_degradation_hat_64 = deg64;
        cmd_use_ping_pong      = use_pp;
        cmd_req_buf_id         = buf_id;
        cmd_k_total            = k_tot;
        @(negedge clk);
        cmd_valid              = 1'b0;
    endtask

    // DMA Dispatch Task
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

    // Wait tasks
    task automatic wait_layer_done(input int max_cycles);
        timeout_cnt = 0;
        while (!layer_done_pulse && (timeout_cnt < max_cycles)) begin
            @(posedge clk);
            timeout_cnt++;
        end
        if (timeout_cnt >= max_cycles) begin
            $display("[ERROR] Timeout waiting for layer_done_pulse!");
        end
    endtask

    task automatic wait_dma_done(input int max_cycles);
        timeout_cnt = 0;
        while (!dma_done_pulse && (timeout_cnt < max_cycles)) begin
            @(posedge clk);
            timeout_cnt++;
        end
        if (timeout_cnt >= max_cycles) begin
            $display("[ERROR] Timeout waiting for dma_done_pulse!");
        end
    endtask

    // Monitored Layer Execution for Cycle Measurement
    task automatic run_measured_workload(
        input  logic [15:0] id,
        input  logic [1:0]  mode,
        input  logic        adapt_en,
        input  logic [31:0] deg16,
        input  logic [31:0] deg32,
        input  logic [31:0] deg64,
        input  logic        buf_id,
        input  logic [15:0] k_tot,
        output int          total_cyc,
        output int          comp_cyc,
        output int          pe_act_cyc,
        output int          sram_reads,
        output int          cfg_switches
    );
        int start_c;
        int active_pes;
        total_cyc    = 0;
        comp_cyc     = 0;
        pe_act_cyc   = 0;
        sram_reads   = 0;
        cfg_switches = 0;

        @(posedge clk);
        start_c = cycle_counter;

        issue_cmd_full(id, mode, adapt_en, deg16, deg32, deg64, 1'b1, buf_id, k_tot);

        while (!layer_done_pulse) begin
            @(posedge clk);
            if (dut.u_feeder.state_q == 3'd1) begin // ST_FETCH
                comp_cyc++;
                case (active_cfg_mode)
                    2'b00:   active_pes = 16;
                    2'b01:   active_pes = 32;
                    2'b10:   active_pes = 64;
                    default: active_pes = 0;
                endcase
                pe_act_cyc += active_pes;
            end
            if (dut.sram_rd_req_0 && dut.sram_rd_ready_0) begin
                sram_reads++;
            end
            if (dut.pe_configuration_changed) begin
                cfg_switches++;
            end
        end
        total_cyc = cycle_counter - start_c;
        @(posedge clk);
    endtask

    // =========================================================================
    // MAIN VERIFICATION PROCEDURE
    // =========================================================================
    initial begin
        $display("==================================================================");
        $display("TSK-08: Functional Workload Validation & Baseline Comparison");
        $display("==================================================================");
        test_count = 0;
        pass_count = 0;
        fail_count = 0;

        apply_reset();

        // =====================================================================
        // SECTION 1: 10 ARITHMETIC TEST CATEGORIES
        // =====================================================================

        // --- Category 1: Positive Operands ---
        $display("\n--- CATEGORY 1: Positive Operands ---");
        // A = [15, 20, 100, 45], W = [10, 30, 5, 2]
        // Products: 150 + 600 + 500 + 90 = 1340
        apply_reset();
        sys_memory[0] = {16'sd10, 16'sd15};
        sys_memory[1] = {16'sd30, 16'sd20};
        sys_memory[2] = {16'sd5,  16'sd100};
        sys_memory[3] = {16'sd2,  16'sd45};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd4, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd101, 2'b10, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b0, 16'd4);
        wait_layer_done(50);
        check_val("CAT1.1: Layer 101 ID confirmed", layer_done_id, 16'd101);
        check_val40("CAT1.2: PE[0][0] positive accum equals 1340", accum_out[0][0], 40'sd1340);
        check_val40("CAT1.3: PE[3][15] positive accum equals 1340", accum_out[3][15], 40'sd1340);
        check_bool("CAT1.4: Saturation flag strictly 0", array_sticky_saturation, 1'b0);

        // --- Category 2: Negative Operands ---
        $display("\n--- CATEGORY 2: Negative Operands ---");
        // Negative x Positive yielding -1340:
        // A = [-15, -20, -100, -45], W = [10, 30, 5, 2]
        // Products: -150 + -600 + -500 + -90 = -1340
        apply_reset();
        sys_memory[0] = {16'sd10, -16'sd15};
        sys_memory[1] = {16'sd30, -16'sd20};
        sys_memory[2] = {16'sd5,  -16'sd100};
        sys_memory[3] = {16'sd2,  -16'sd45};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd4, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd102, 2'b10, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b0, 16'd4);
        wait_layer_done(50);
        check_val("CAT2.1: Layer 102 ID confirmed", layer_done_id, 16'd102);
        check_val40("CAT2.2: PE[0][0] negative accum equals -1340", accum_out[0][0], -40'sd1340);
        check_val40("CAT2.3: PE[3][15] negative accum equals -1340", accum_out[3][15], -40'sd1340);
        check_bool("CAT2.4: Saturation flag strictly 0", array_sticky_saturation, 1'b0);

        // Negative x Negative yielding +1340:
        apply_reset();
        sys_memory[0] = {-16'sd10, -16'sd15};
        sys_memory[1] = {-16'sd30, -16'sd20};
        sys_memory[2] = {-16'sd5,  -16'sd100};
        sys_memory[3] = {-16'sd2,  -16'sd45};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd4, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd103, 2'b10, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b0, 16'd4);
        wait_layer_done(50);
        check_val40("CAT2.5: Neg x Neg equals +1340", accum_out[0][0], 40'sd1340);

        // --- Category 3: Mixed-Sign Operands ---
        $display("\n--- CATEGORY 3: Mixed-Sign Operands ---");
        // A = [12, -4, 25, -15], W = [8, 10, -6, 14]
        // Sum = 96 - 40 - 150 - 210 = -304
        apply_reset();
        sys_memory[0] = {16'sd8,   16'sd12};
        sys_memory[1] = {16'sd10, -16'sd4};
        sys_memory[2] = {-16'sd6,  16'sd25};
        sys_memory[3] = {16'sd14, -16'sd15};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd4, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd104, 2'b10, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b0, 16'd4);
        wait_layer_done(50);
        check_val40("CAT3.1: Mixed-sign accumulation equals -304", accum_out[0][0], -40'sd304);

        // --- Category 4: Exact-Zero Operands & Zero-Skipping ---
        $display("\n--- CATEGORY 4: Exact-Zero Operands & Zero-Skipping ---");
        // k=0: A=10, W=20 -> 200
        // k=1: A=0,  W=50 -> skip
        // k=2: A=30, W=0  -> prod=0
        // k=3: A=8,  W=9  -> 72
        // Total = 272
        apply_reset();
        sys_memory[0] = {16'sd20, 16'sd10};
        sys_memory[1] = {16'sd50, 16'sd0};
        sys_memory[2] = {16'sd0,  16'sd30};
        sys_memory[3] = {16'sd9,  16'sd8};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd4, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd105, 2'b10, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b0, 16'd4);
        wait_layer_done(50);
        check_val40("CAT4.1: Zero-skip accumulation equals 272", accum_out[0][0], 40'sd272);

        // --- Category 5: Min/Max Representable Limits ---
        $display("\n--- CATEGORY 5: Min/Max Representable Limits ---");
        // Step 0: +32767 * +32767 = +1,073,676,289
        // Step 1: -32768 * +32767 = -1,073,709,056
        // Step 2: -32768 * -32768 = +1,073,741,824
        // Expected sum = 1,073,709,057
        apply_reset();
        sys_memory[0] = {16'sd32767,  16'sd32767};
        sys_memory[1] = {16'sd32767, -16'sd32768};
        sys_memory[2] = {-16'sd32768, -16'sd32768};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd3, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd106, 2'b10, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b0, 16'd3);
        wait_layer_done(50);
        check_val40("CAT5.1: Extreme min/max sum equals 1,073,709,057", accum_out[0][0], 40'sd1073709057);

        // --- Category 6: Saturation Clamping Behavior ---
        $display("\n--- CATEGORY 6: Saturation Behavior (Clamping & Sticky Flags) ---");
        // Verify on standalone PE array to rapidly evaluate > 512 saturation cycles
        @(negedge clk);
        sa_accum_clear = 1'b1;
        sa_sat_clear   = 1'b1;
        sa_enable      = 1'b1;
        sa_cfg_mode    = 2'b10;
        @(negedge clk);
        sa_accum_clear = 1'b0;
        sa_sat_clear   = 1'b0;

        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                sa_act_data[r][c]    = 16'sd32767;
                sa_act_mask[r][c]    = 1'b1;
                sa_weight_data[r][c] = 16'sd32767;
            end
        end

        // 515 cycles * 1,073,676,289 = 552,943,288,835 > SAT_MAX_POS
        repeat (515) @(negedge clk);
        sa_enable = 1'b0;
        check_val40("CAT6.1: Positive overflow clamped at SAT_MAX_POS", sa_accum_out[0][0], SAT_MAX_POS);
        check_bool("CAT6.2: Sticky saturation asserted", sa_array_sticky_saturation, 1'b1);

        // Clear sat flag while preserving clamped accumulator
        @(negedge clk);
        sa_sat_clear = 1'b1;
        @(negedge clk);
        sa_sat_clear = 1'b0;
        check_bool("CAT6.3: sat_clear deasserts sticky flag", sa_array_sticky_saturation, 1'b0);
        check_val40("CAT6.4: Clamped accumulator value preserved after sat_clear", sa_accum_out[0][0], SAT_MAX_POS);

        // Negative overflow test: 515 cycles * -1,073,709,056 < SAT_MAX_NEG
        @(negedge clk);
        sa_accum_clear = 1'b1;
        sa_sat_clear   = 1'b1;
        sa_enable      = 1'b1;
        @(negedge clk);
        sa_accum_clear = 1'b0;
        sa_sat_clear   = 1'b0;

        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                sa_act_data[r][c]    = -16'sd32768;
                sa_weight_data[r][c] = 16'sd32767;
            end
        end
        repeat (515) @(negedge clk);
        sa_enable = 1'b0;
        check_val40("CAT6.5: Negative overflow clamped at SAT_MAX_NEG", sa_accum_out[0][0], SAT_MAX_NEG);
        check_bool("CAT6.6: Sticky saturation asserted for negative overflow", sa_array_sticky_saturation, 1'b1);

        // --- Category 7: Distinct Sequences Across Multiple PEs ---
        $display("\n--- CATEGORY 7: Distinct Sequences Across Multiple PEs ---");
        @(negedge clk);
        sa_accum_clear = 1'b1;
        sa_enable      = 1'b1;
        sa_cfg_mode    = 2'b10; // 64-PE mode
        @(negedge clk);
        sa_accum_clear = 1'b0;

        // Apply distinct inputs per PE over K=4 steps:
        // Act[r][c] = (r+1)*(k+1), Weight[r][c] = (c+1)
        for (int k = 0; k < 4; k++) begin
            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    sa_act_data[r][c]    = (r + 1) * (k + 1);
                    sa_act_mask[r][c]    = 1'b1;
                    sa_weight_data[r][c] = (c + 1);
                end
            end
            @(negedge clk);
        end
        sa_enable = 1'b0;

        // Expected golden for PE[0][0]: (1*1 + 2*1 + 3*1 + 4*1)*1 = 10
        check_val40("CAT7.1: PE[0][0] distinct sum equals 10", sa_accum_out[0][0], 40'sd10);
        // Expected golden for PE[3][15]: (4*1 + 8*1 + 12*1 + 16*1)*16 = 40 * 16 = 640
        check_val40("CAT7.2: PE[3][15] distinct sum equals 640", sa_accum_out[3][15], 40'sd640);

        // In 16-PE mode, verify columns 4..15 output strictly 0
        @(negedge clk);
        sa_cfg_mode = 2'b00; // 16-PE mode
        @(posedge clk);
        check_val40("CAT7.3: Mode 0 col 0 active", sa_accum_out[0][0], 40'sd10);
        check_val40("CAT7.4: Mode 0 col 4 strictly isolated to 0", sa_accum_out[0][4], 40'sd0);
        check_val40("CAT7.5: Mode 0 col 15 strictly isolated to 0", sa_accum_out[3][15], 40'sd0);

        // --- Category 8: Multiple K Reductions ---
        $display("\n--- CATEGORY 8: Multiple Reduction Iterations across K ---");
        // Test K=1, K=2, K=8, K=16 on top-level integrated accelerator
        // K=1: 10 * 3 = 30
        apply_reset();
        sys_memory[0] = {16'sd3, 16'sd10};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd108, 2'b00, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b0, 16'd1);
        wait_layer_done(50);
        check_val40("CAT8.1: K=1 reduction equals 30", accum_out[0][0], 40'sd30);

        // K=8: 8 beats of 10 * 3 = 240
        apply_reset();
        for (int i = 0; i < 8; i++) sys_memory[i] = {16'sd3, 16'sd10};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd8, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd109, 2'b00, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b0, 16'd8);
        wait_layer_done(50);
        check_val40("CAT8.2: K=8 reduction equals 240", accum_out[0][0], 40'sd240);

        // K=16: 16 beats of 10 * 3 = 480
        apply_reset();
        for (int i = 0; i < 16; i++) sys_memory[i] = {16'sd3, 16'sd10};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd16, 1'b1);
        wait_dma_done(60);
        @(posedge clk);
        issue_cmd_full(16'd110, 2'b00, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b0, 16'd16);
        wait_layer_done(60);
        check_val40("CAT8.3: K=16 reduction equals 480", accum_out[0][0], 40'sd480);

        // --- Category 9: Repeated Consecutive Layer Executions ---
        $display("\n--- CATEGORY 9: Repeated Consecutive Layer Executions ---");
        // Layer 201 on Buffer A (K=2: 5 * 4 * 2 = 40)
        apply_reset();
        sys_memory[0] = {16'sd4, 16'sd5};
        sys_memory[1] = {16'sd4, 16'sd5};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd2, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd201, 2'b00, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b0, 16'd2);
        wait_layer_done(50);
        check_val("CAT9.1: Layer 201 ID confirmed", layer_done_id, 16'd201);
        check_val40("CAT9.2: Layer 201 output equals 40", accum_out[0][0], 40'sd40);

        // Layer 202 on Buffer B without reset (K=2: 7 * -3 * 2 = -42)
        sys_memory[10] = {-16'sd3, 16'sd7};
        sys_memory[11] = {-16'sd3, 16'sd7};
        start_dma(32'h0000_0028, 32'h0000_4000, 16'd2, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd202, 2'b00, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b1, 16'd2);
        wait_layer_done(50);
        check_val("CAT9.3: Layer 202 ID confirmed", layer_done_id, 16'd202);
        check_val40("CAT9.4: Layer 202 output equals -42", accum_out[0][0], -40'sd42);

        // --- Category 10: Mid-Flight Reset & Reconfiguration ---
        $display("\n--- CATEGORY 10: Mid-Flight Reset & Reconfiguration ---");
        apply_reset();
        sys_memory[0] = {16'sd10, 16'sd10};
        sys_memory[1] = {16'sd10, 16'sd10};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd8, 1'b0);
        repeat (3) @(posedge clk);
        check_bool("CAT10.1: DMA busy before reset", dma_busy, 1'b1);
        @(negedge clk);
        rst_n = 1'b0;
        @(negedge clk);
        check_bool("CAT10.2: Reset forces DMA busy low immediately", dma_busy, 1'b0);
        check_val("CAT10.3: Reset restores safe default 64-PE mode", active_pe_count, 7'd64);
        rst_n = 1'b1;
        @(posedge clk);
        check_val("CAT10.4: Post-reset idle state confirmed", sequencer_state, 4'd0);


        // =====================================================================
        // SECTION 2: PHASE 3 SRAM-TO-PE DATAFLOW VERIFICATION
        // =====================================================================
        $display("\n==================================================================");
        $display("PHASE 3: SRAM-to-PE Dataflow Verification");
        $display("==================================================================");

        // Validate Buffer A and Buffer B addressing progression and non-constant data
        // K=4 non-constant sequence:
        // k=0: {W=2, A=3}   -> 6
        // k=1: {W=4, A=5}   -> 20
        // k=2: {W=6, A=7}   -> 42
        // k=3: {W=8, A=9}   -> 72
        // Total expected: 6 + 20 + 42 + 72 = 140
        apply_reset();
        sys_memory[0] = {16'sd2, 16'sd3};
        sys_memory[1] = {16'sd4, 16'sd5};
        sys_memory[2] = {16'sd6, 16'sd7};
        sys_memory[3] = {16'sd8, 16'sd9};

        // Transfer to Buffer A (base 0x0000)
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd4, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        check_val("DF.1: Buffer A marked READY", buf_state_a, 2'b10);

        // Execute on Buffer A
        issue_cmd_full(16'd301, 2'b00, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b0, 16'd4);
        wait_layer_done(50);
        check_val40("DF.2: Buffer A sequential addressing correctly sums to 140", accum_out[0][0], 40'sd140);
        check_val("DF.3: Buffer A returned to EMPTY", buf_state_a, 2'b00);

        // Transfer to Buffer B (base 0x4000 byte addr / 0x1000 word addr)
        start_dma(32'h0000_0000, 32'h0000_4000, 16'd4, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        check_val("DF.4: Buffer B marked READY", buf_state_b, 2'b10);

        // Execute on Buffer B
        issue_cmd_full(16'd302, 2'b00, 1'b0, 32'd0, 32'd0, 32'd0, 1'b1, 1'b1, 16'd4);
        wait_layer_done(50);
        check_val40("DF.5: Buffer B sequential addressing correctly sums to 140", accum_out[0][0], 40'sd140);
        check_val("DF.6: Buffer B returned to EMPTY", buf_state_b, 2'b00);


        // =====================================================================
        // SECTION 3: PHASE 4 PE CONFIGURATION COMPARISON (STANDARDIZED WORKLOAD)
        // =====================================================================
        $display("\n==================================================================");
        $display("PHASE 4: PE Configuration Comparison (Standardized K=16 Workload)");
        $display("==================================================================");

        // Standardized Workload Definition:
        // K=16 sequential beats of identical data: A=10, W=5 -> 50 per beat.
        // Golden dot product sum = 16 * 50 = 800.
        for (int i = 0; i < 16; i++) begin
            sys_memory[i] = {16'sd5, 16'sd10};
        end

        // Run across all 4 modes under equivalent data and computational demand:
        begin
            int c_total_16,  c_comp_16,  c_pe_16,  sram_rd_16,  cfg_sw_16;
            int c_total_32,  c_comp_32,  c_pe_32,  sram_rd_32,  cfg_sw_32;
            int c_total_64,  c_comp_64,  c_pe_64,  sram_rd_64,  cfg_sw_64;
            int c_total_adp, c_comp_adp, c_pe_adp, sram_rd_adp, cfg_sw_adp;

            // 1. Fixed 16-PE Mode
            apply_reset();
            start_dma(32'h0000_0000, 32'h0000_0000, 16'd16, 1'b1);
            wait_dma_done(60);
            @(posedge clk);
            run_measured_workload(16'd401, 2'b00, 1'b0, 32'd0, 32'd0, 32'd0, 1'b0, 16'd16,
                                 c_total_16, c_comp_16, c_pe_16, sram_rd_16, cfg_sw_16);
            check_val40("CFG.1A: 16-PE Mode active column 0 equals 800", accum_out[0][0], 40'sd800);
            check_val40("CFG.1B: 16-PE Mode inactive column 4 equals 0", accum_out[0][4], 40'sd0);
            check_val("CFG.1C: 16-PE Mode active PE count is 16", active_pe_count, 7'd16);

            // 2. Fixed 32-PE Mode
            apply_reset();
            start_dma(32'h0000_0000, 32'h0000_0000, 16'd16, 1'b1);
            wait_dma_done(60);
            @(posedge clk);
            run_measured_workload(16'd402, 2'b01, 1'b0, 32'd0, 32'd0, 32'd0, 1'b0, 16'd16,
                                 c_total_32, c_comp_32, c_pe_32, sram_rd_32, cfg_sw_32);
            check_val40("CFG.2A: 32-PE Mode active column 7 equals 800", accum_out[0][7], 40'sd800);
            check_val40("CFG.2B: 32-PE Mode inactive column 8 equals 0", accum_out[0][8], 40'sd0);
            check_val("CFG.2C: 32-PE Mode active PE count is 32", active_pe_count, 7'd32);

            // 3. Fixed 64-PE Mode
            apply_reset();
            start_dma(32'h0000_0000, 32'h0000_0000, 16'd16, 1'b1);
            wait_dma_done(60);
            @(posedge clk);
            run_measured_workload(16'd403, 2'b10, 1'b0, 32'd0, 32'd0, 32'd0, 1'b0, 16'd16,
                                 c_total_64, c_comp_64, c_pe_64, sram_rd_64, cfg_sw_64);
            check_val40("CFG.3A: 64-PE Mode active column 15 equals 800", accum_out[0][15], 40'sd800);
            check_val("CFG.3B: 64-PE Mode active PE count is 64", active_pe_count, 7'd64);

            // 4. Adaptive PE Mode (evaluating low degradation -> selects 16-PE)
            apply_reset();
            start_dma(32'h0000_0000, 32'h0000_0000, 16'd16, 1'b1);
            wait_dma_done(60);
            @(posedge clk);
            run_measured_workload(16'd404, 2'b00, 1'b1, 32'd1000, 32'd2000, 32'd3000, 1'b0, 16'd16,
                                 c_total_adp, c_comp_adp, c_pe_adp, sram_rd_adp, cfg_sw_adp);
            check_val40("CFG.4A: Adaptive Mode output equals 800", accum_out[0][0], 40'sd800);
            check_val("CFG.4B: Adaptive Mode correctly resolved to 16 PEs", active_pe_count, 7'd16);

            $display("\n--- WORKLOAD COMPARISON TABLE (Measured Simulation Cycles for K=16) ---");
            $display("| Configuration | Total Cyc | Comp Cyc | Active PEs | PE-Active Cyc | SRAM Reads | Config Sw |");
            $display("| :---          | :---:     | :---:    | :---:      | :---:         | :---:      | :---:     |");
            $display("| Fixed 16-PE   | %5d     | %5d    |    16      | %7d       | %6d     | %5d     |",
                     c_total_16, c_comp_16, c_pe_16, sram_rd_16, cfg_sw_16);
            $display("| Fixed 32-PE   | %5d     | %5d    |    32      | %7d       | %6d     | %5d     |",
                     c_total_32, c_comp_32, c_pe_32, sram_rd_32, cfg_sw_32);
            $display("| Fixed 64-PE   | %5d     | %5d    |    64      | %7d       | %6d     | %5d     |",
                     c_total_64, c_comp_64, c_pe_64, sram_rd_64, cfg_sw_64);
            $display("| Adaptive (Low)| %5d     | %5d    |    16      | %7d       | %6d     | %5d     |",
                     c_total_adp, c_comp_adp, c_pe_adp, sram_rd_adp, cfg_sw_adp);
        end


        // =====================================================================
        // SECTION 4: PHASE 5 ADAPTIVE POLICY BEHAVIOR EVALUATION
        // =====================================================================
        $display("\n==================================================================");
        $display("PHASE 5: Adaptive Policy Behavior Evaluation");
        $display("==================================================================");

        // Case A: Low degradation (deg16 <= 3277) -> 16-PE mode
        apply_reset();
        sys_memory[0] = {16'sd1, 16'sd1};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd501, 2'b10, 1'b1, 32'd2500, 32'd3000, 32'd4000, 1'b1, 1'b0, 16'd1);
        wait_layer_done(50);
        check_val("ADP.1: Low degradation selects 16-PE mode", active_cfg_mode, 2'b00);
        check_val("ADP.2: 16-PE active count confirmed", active_pe_count, 7'd16);

        // Case B: Moderate degradation (deg16 > 3277, deg32 <= 3277) -> 32-PE mode
        apply_reset();
        sys_memory[0] = {16'sd1, 16'sd1};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd502, 2'b00, 1'b1, 32'd4000, 32'd3000, 32'd4000, 1'b1, 1'b0, 16'd1);
        wait_layer_done(50);
        check_val("ADP.3: Moderate degradation selects 32-PE mode", active_cfg_mode, 2'b01);
        check_val("ADP.4: 32-PE active count confirmed", active_pe_count, 7'd32);

        // Case C: High degradation (deg16 > 3277, deg32 > 3277) -> 64-PE mode with fallback
        apply_reset();
        sys_memory[0] = {16'sd1, 16'sd1};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd503, 2'b00, 1'b1, 32'd5000, 32'd6000, 32'd2000, 1'b1, 1'b0, 16'd1);
        wait_layer_done(50);
        check_val("ADP.5: High degradation triggers 64-PE fallback", active_cfg_mode, 2'b10);
        check_val("ADP.6: 64-PE active count confirmed", active_pe_count, 7'd64);

        // Case D: Boundary condition at exact D_MAX (3277):
        // deg16 == 3277 -> strictly accepted into 16-PE mode
        apply_reset();
        sys_memory[0] = {16'sd1, 16'sd1};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd504, 2'b10, 1'b1, 32'd3277, 32'd5000, 32'd5000, 1'b1, 1'b0, 16'd1);
        wait_layer_done(50);
        check_val("ADP.7: Exact threshold 3277 accepted into 16-PE", active_cfg_mode, 2'b00);

        // Case E: Boundary condition at D_MAX + 1 (3278):
        // deg16 == 3278 -> rejected, moves to 32-PE
        apply_reset();
        sys_memory[0] = {16'sd1, 16'sd1};
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd_full(16'd505, 2'b10, 1'b1, 32'd3278, 32'd3277, 32'd5000, 1'b1, 1'b0, 16'd1);
        wait_layer_done(50);
        check_val("ADP.8: Threshold + 1 (3278) rejected, moves to 32-PE", active_cfg_mode, 2'b01);


        // =====================================================================
        // FINAL SUMMARY & VERDICT
        // =====================================================================
        $display("\n==================================================================");
        $display("TSK-08 Validation Test Summary: Total=%0d, Passed=%0d, Failed=%0d",
                 test_count, pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-08 Functional Workload Tests Passed!");
            $finish(0);
        end else begin
            $display("[FAILURE] %0d tests failed during TSK-08 execution!", fail_count);
            $finish(1);
        end
    end

endmodule
