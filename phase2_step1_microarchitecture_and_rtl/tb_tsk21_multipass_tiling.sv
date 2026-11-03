// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-21 / TSK-23 Multi-Pass Channel Tiling & Requantization Verification
// Module: tb_tsk21_multipass_tiling.sv
// Description: Comprehensive verification testbench for channel_tile_controller.sv,
//              requantization_unit.sv, tail tiles, and SRAM inter-layer chaining.
//              Verifies:
//              1. Multi-pass channel tiling (64-PE, 32-PE, 16-PE)
//              2. Tail tiles & channel counts not multiples of PE width
//              3. Accumulator clearing between passes and drain completion
//              4. Bit-exact requantization, Round-Half-Up tie-breaking policy,
//                 shift boundaries S in [0..31], extreme 40-bit limits, saturation
//              5. SRAM readback of every single requantized word against software golden
//              6. Inter-layer handoff via actual RTL interfaces (Port A / Port B)
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk21_multipass_tiling;

    localparam int CLK_PERIOD      = 10;
    localparam int SRAM_ADDR_W     = 14;
    localparam int DATA_WIDTH      = 32;
    localparam int ACCUM_WIDTH     = 40;
    localparam int ACT_WIDTH       = 16;
    localparam int NUM_BANKS       = 8;
    localparam int BANK_ADDR_W     = 11;
    localparam int BYTES_PER_BANK  = 8192;

    logic clk;
    logic rst_n;

    // -------------------------------------------------------------------------
    // 1. Channel Tile Controller Signals
    // -------------------------------------------------------------------------
    logic                        tile_layer_start;
    logic [1:0]                  tile_cfg_pe_mode;
    logic [SRAM_ADDR_W-1:0]      tile_cfg_base_ofmap_addr;
    logic [2:0]                  tile_cfg_custom_passes;
    logic [7:0]                  tile_cfg_custom_words;
    logic [7:0]                  tile_cfg_tail_words;

    logic                        tile_feeder_compute_done;
    logic                        tile_ofmap_drain_done;

    wire                         tile_start_feeder;
    wire                         tile_start_drain;
    wire [SRAM_ADDR_W-1:0]       tile_current_ofmap_addr;
    wire                         tile_accum_clear;
    wire [2:0]                   tile_current_pass;
    wire [2:0]                   tile_total_passes;
    wire [7:0]                   tile_words_per_tile;
    wire                         layer_all_tiles_done;
    wire                         tile_controller_busy;
    wire [2:0]                   tile_controller_state;

    // -------------------------------------------------------------------------
    // 2. Requantization Unit Signals
    // -------------------------------------------------------------------------
    logic [4:0]                  rq_scale_shift;
    logic                        rq_round_en;
    logic                        rq_relu_en;
    logic signed [ACT_WIDTH-1:0] rq_clip_min;
    logic signed [ACT_WIDTH-1:0] rq_clip_max;

    logic                        rq_in_valid;
    wire                         rq_in_ready;
    logic signed [ACCUM_WIDTH-1:0] rq_in_accum;

    wire                         rq_out_act_valid;
    logic                        rq_out_act_ready;
    wire signed [ACT_WIDTH-1:0]  rq_out_act;

    wire                         rq_out_word_valid;
    logic                        rq_out_word_ready;
    wire [DATA_WIDTH-1:0]        rq_out_word;

    wire [31:0]                  rq_stat_inputs;
    wire [31:0]                  rq_stat_words;
    wire [31:0]                  rq_stat_clips_min;
    wire [31:0]                  rq_stat_clips_max;
    wire [31:0]                  rq_stat_relu_zeros;

    // -------------------------------------------------------------------------
    // 3. Multi-Bank SRAM Subsystem (for Chaining Verification)
    // -------------------------------------------------------------------------
    logic [NUM_BANKS-1:0]        sram_wr_req;
    logic [SRAM_ADDR_W-1:0]      sram_wr_addr [0:NUM_BANKS-1];
    logic [DATA_WIDTH-1:0]       sram_wr_din  [0:NUM_BANKS-1];
    logic [DATA_WIDTH/8-1:0]     sram_wr_byte_we [0:NUM_BANKS-1];
    wire  [NUM_BANKS-1:0]        sram_wr_ready;
    wire  [NUM_BANKS-1:0]        sram_wr_ack;
    wire  [NUM_BANKS-1:0]        sram_wr_conflict_stall;

    logic [NUM_BANKS-1:0]        sram_rd_req;
    logic [SRAM_ADDR_W-1:0]      sram_rd_addr [0:NUM_BANKS-1];
    wire  [NUM_BANKS-1:0]        sram_rd_ready;
    wire  [NUM_BANKS-1:0]        sram_rd_rvalid;
    wire  [DATA_WIDTH-1:0]       sram_rd_dout [0:NUM_BANKS-1];
    wire  [NUM_BANKS-1:0]        sram_rd_conflict_stall;

    // Verification Bookkeeping
    int total_checks  = 0;
    int passed_checks = 0;
    int failed_checks = 0;

    task automatic check(input string desc, input bit cond);
        total_checks++;
        if (cond) begin
            passed_checks++;
        end else begin
            failed_checks++;
            $display("[FAIL] %s", desc);
        end
    endtask

    // Clock generator
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Device Under Test Instantiations
    // -------------------------------------------------------------------------
    channel_tile_controller #(
        .SRAM_ADDR_W        (SRAM_ADDR_W),
        .TOTAL_OUTPUT_WORDS (128)
    ) dut_tile_ctrl (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .layer_start               (tile_layer_start),
        .cfg_pe_mode               (tile_cfg_pe_mode),
        .cfg_base_ofmap_addr       (tile_cfg_base_ofmap_addr),
        .cfg_custom_passes         (tile_cfg_custom_passes),
        .cfg_custom_words_per_tile (tile_cfg_custom_words),
        .cfg_tail_words            (tile_cfg_tail_words),
        .feeder_compute_done       (tile_feeder_compute_done),
        .ofmap_drain_done          (tile_ofmap_drain_done),
        .tile_start_feeder         (tile_start_feeder),
        .tile_start_drain          (tile_start_drain),
        .current_ofmap_addr        (tile_current_ofmap_addr),
        .tile_accum_clear          (tile_accum_clear),
        .current_tile_pass         (tile_current_pass),
        .total_tile_passes         (tile_total_passes),
        .words_per_tile            (tile_words_per_tile),
        .layer_all_tiles_done      (layer_all_tiles_done),
        .controller_busy           (tile_controller_busy),
        .controller_state          (tile_controller_state)
    );

    requantization_unit #(
        .ACCUM_WIDTH (ACCUM_WIDTH),
        .ACT_WIDTH   (ACT_WIDTH),
        .DATA_WIDTH  (DATA_WIDTH)
    ) dut_requant (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .cfg_scale_shift       (rq_scale_shift),
        .cfg_round_en          (rq_round_en),
        .cfg_relu_en           (rq_relu_en),
        .cfg_clip_min          (rq_clip_min),
        .cfg_clip_max          (rq_clip_max),
        .in_valid              (rq_in_valid),
        .in_ready              (rq_in_ready),
        .in_accum              (rq_in_accum),
        .out_act_valid         (rq_out_act_valid),
        .out_act_ready         (rq_out_act_ready),
        .out_act               (rq_out_act),
        .out_word_valid        (rq_out_word_valid),
        .out_word_ready        (rq_out_word_ready),
        .out_word              (rq_out_word),
        .stat_inputs_processed (rq_stat_inputs),
        .stat_words_packed     (rq_stat_words),
        .stat_clips_min        (rq_stat_clips_min),
        .stat_clips_max        (rq_stat_clips_max),
        .stat_relu_zeros       (rq_stat_relu_zeros)
    );

    multibank_sram_subsystem #(
        .NUM_BANKS       (NUM_BANKS),
        .BYTES_PER_BANK  (BYTES_PER_BANK),
        .DATA_WIDTH      (DATA_WIDTH),
        .BANK_ADDR_W     (BANK_ADDR_W),
        .NUM_READ_PORTS  (NUM_BANKS),
        .NUM_WRITE_PORTS (NUM_BANKS)
    ) dut_sram (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .bank_enable           (8'hFF),
        .wr_req                (sram_wr_req),
        .wr_addr               (sram_wr_addr),
        .wr_din                (sram_wr_din),
        .wr_byte_we            (sram_wr_byte_we),
        .wr_ready              (sram_wr_ready),
        .wr_ack                (sram_wr_ack),
        .wr_conflict_stall     (sram_wr_conflict_stall),
        .rd_req                (sram_rd_req),
        .rd_addr               (sram_rd_addr),
        .rd_ready              (sram_rd_ready),
        .rd_rvalid             (sram_rd_rvalid),
        .rd_dout               (sram_rd_dout),
        .rd_conflict_stall     (sram_rd_conflict_stall),
        .bank_conflict_flags   ()
    );

    // Reset task
    task automatic apply_reset();
        rst_n                    = 1'b0;
        tile_layer_start         = 1'b0;
        tile_cfg_pe_mode         = 2'b10;
        tile_cfg_base_ofmap_addr = 14'h2000;
        tile_cfg_custom_passes   = 3'd0;
        tile_cfg_custom_words    = 8'd0;
        tile_cfg_tail_words      = 8'd0;
        tile_feeder_compute_done = 1'b0;
        tile_ofmap_drain_done    = 1'b0;

        rq_scale_shift           = 5'd4;
        rq_round_en              = 1'b1;
        rq_relu_en               = 1'b0;
        rq_clip_min              = -16'sd32768;
        rq_clip_max              = 16'sd32767;
        rq_in_valid              = 1'b0;
        rq_in_accum              = '0;
        rq_out_act_ready         = 1'b1;
        rq_out_word_ready        = 1'b1;

        sram_wr_req              = '0;
        sram_rd_req              = '0;
        for (int i = 0; i < NUM_BANKS; i++) begin
            sram_wr_addr[i]    = '0;
            sram_wr_din[i]     = '0;
            sram_wr_byte_we[i] = 4'hF;
            sram_rd_addr[i]    = '0;
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
    endtask

    // Golden Reference Model in SystemVerilog for verification checking
    function automatic logic signed [15:0] golden_requant(
        input logic signed [39:0] acc,
        input int s,
        input bit r_en,
        input bit relu
    );
        logic signed [40:0] val_round;
        logic signed [40:0] shifted;
        logic signed [15:0] sat;
        logic signed [40:0] offset;
        offset = (r_en && s > 0) ? (41'sd1 <<< (s - 1)) : 41'sd0;
        val_round = acc + offset;
        shifted = val_round >>> s;
        if (shifted > 41'sd32767) sat = 16'sd32767;
        else if (shifted < -41'sd32768) sat = -16'sd32768;
        else sat = shifted[15:0];
        if (relu && sat < 16'sd0) sat = 16'sd0;
        return sat;
    endfunction

    // -------------------------------------------------------------------------
    // Main Verification Process
    // -------------------------------------------------------------------------
    initial begin
        $display("================================================================================");
        $display("Starting TSK-21 Multi-Pass Channel Tiling & Requantization Verification");
        $display("================================================================================");

        apply_reset();

        // ---------------------------------------------------------------------
        // PART 1: CHANNEL TILE CONTROLLER MULTI-PASS VERIFICATION
        // ---------------------------------------------------------------------

        // Test 1.1: 64-PE Mode (Single Pass: 1 pass x 128 words)
        $display("\n--- Test 1.1: Channel Tile Controller in 64-PE Mode (1 Pass) ---");
        tile_cfg_pe_mode         = 2'b10;
        tile_cfg_base_ofmap_addr = 14'h2000;
        @(negedge clk);
        tile_layer_start = 1'b1;
        @(posedge clk);
        tile_layer_start = 1'b0;
        #1;
        check("T1.1: Total passes == 1", tile_total_passes == 3'd1);
        check("T1.1: Words per tile == 128", tile_words_per_tile == 8'd128);
        check("T1.1: Current pass == 0", tile_current_pass == 3'd0);
        check("T1.1: Initial ofmap addr == 14'h2000", tile_current_ofmap_addr == 14'h2000);

        @(posedge clk); // ST_CLEAR_ACCUM -> ST_FEEDER_RUN
        #1;
        check("T1.1: Feeder start pulsed", tile_start_feeder == 1'b1);

        tile_feeder_compute_done = 1'b1;
        @(posedge clk); // ST_FEEDER_RUN -> ST_DRAIN_RUN
        tile_feeder_compute_done = 1'b0;
        #1;
        check("T1.1: Drain start pulsed after compute", tile_start_drain == 1'b1);

        tile_ofmap_drain_done = 1'b1;
        @(posedge clk); // ST_DRAIN_RUN -> ST_CHECK_TILES (asserts layer_all_tiles_done)
        tile_ofmap_drain_done = 1'b0;
        #1;
        check("T1.1: All tiles done pulsed", layer_all_tiles_done == 1'b1);

        @(posedge clk); // ST_CHECK_TILES -> ST_IDLE
        #1;
        check("T1.1: Controller back to ST_IDLE", tile_controller_state == 3'd0);

        // Test 1.2: 32-PE Mode (2 Passes: 2 x 64 words = 128 words)
        $display("\n--- Test 1.2: Channel Tile Controller in 32-PE Mode (2 Passes) ---");
        tile_cfg_pe_mode         = 2'b01;
        tile_cfg_base_ofmap_addr = 14'h2000;
        @(negedge clk);
        tile_layer_start = 1'b1;
        @(posedge clk);
        tile_layer_start = 1'b0;
        #1;
        check("T1.2: Total passes == 2", tile_total_passes == 3'd2);
        check("T1.2: Words per tile == 64", tile_words_per_tile == 8'd64);

        // Pass 0
        @(posedge clk); // ST_CLEAR_ACCUM -> ST_FEEDER_RUN
        #1;
        check("T1.2 Pass 0: Index == 0", tile_current_pass == 3'd0);
        check("T1.2 Pass 0: Addr == 14'h2000", tile_current_ofmap_addr == 14'h2000);

        tile_feeder_compute_done = 1'b1;
        @(posedge clk); // ST_FEEDER_RUN -> ST_DRAIN_RUN
        tile_feeder_compute_done = 1'b0;

        tile_ofmap_drain_done = 1'b1;
        @(posedge clk); // ST_DRAIN_RUN -> ST_CHECK_TILES
        tile_ofmap_drain_done = 1'b0;
        #1;
        check("T1.2 Pass 0: Not done yet", layer_all_tiles_done == 1'b0);

        // Pass 1
        @(posedge clk); // ST_CHECK_TILES -> ST_CLEAR_ACCUM (pass_idx becomes 1)
        #1;
        check("T1.2 Pass 1: Accum clear asserted", tile_accum_clear == 1'b1);
        @(posedge clk); // ST_CLEAR_ACCUM -> ST_FEEDER_RUN
        #1;
        check("T1.2 Pass 1: Index == 1", tile_current_pass == 3'd1);
        check("T1.2 Pass 1: Addr == 14'h2040 (2000 + 64)", tile_current_ofmap_addr == 14'h2040);

        tile_feeder_compute_done = 1'b1;
        @(posedge clk); // ST_FEEDER_RUN -> ST_DRAIN_RUN
        tile_feeder_compute_done = 1'b0;

        tile_ofmap_drain_done = 1'b1;
        @(posedge clk); // ST_DRAIN_RUN -> ST_CHECK_TILES
        tile_ofmap_drain_done = 1'b0;
        #1;
        check("T1.2 Pass 1: Done asserted after 2 passes", layer_all_tiles_done == 1'b1);

        // Test 1.3: 16-PE Mode (4 Passes: 4 x 32 words = 128 words)
        $display("\n--- Test 1.3: Channel Tile Controller in 16-PE Mode (4 Passes) ---");
        apply_reset();
        tile_cfg_pe_mode         = 2'b00;
        tile_cfg_base_ofmap_addr = 14'h3000;
        @(negedge clk);
        tile_layer_start = 1'b1;
        @(posedge clk);
        tile_layer_start = 1'b0;
        #1;
        check("T1.3: Total passes == 4", tile_total_passes == 3'd4);
        check("T1.3: Words per tile == 32", tile_words_per_tile == 8'd32);

        for (int p = 0; p < 4; p++) begin
            if (p > 0) @(posedge clk); // ST_CHECK_TILES -> ST_CLEAR_ACCUM
            @(posedge clk); // ST_CLEAR_ACCUM -> ST_FEEDER_RUN
            #1;
            check($sformatf("T1.3 Pass %0d: Current pass == %0d", p, p), tile_current_pass == p);
            check($sformatf("T1.3 Pass %0d: Addr == 14'h%04X", p, 14'h3000 + (p * 32)),
                  tile_current_ofmap_addr == 14'h3000 + (p * 32));

            tile_feeder_compute_done = 1'b1;
            @(posedge clk); // ST_FEEDER_RUN -> ST_DRAIN_RUN
            tile_feeder_compute_done = 1'b0;

            tile_ofmap_drain_done = 1'b1;
            @(posedge clk); // ST_DRAIN_RUN -> ST_CHECK_TILES
            tile_ofmap_drain_done = 1'b0;
        end

        #1;
        check("T1.3: All 4 passes done asserted", layer_all_tiles_done == 1'b1);

        // Test 1.4: Tail Tiles and Non-Multiple Channel Counts
        // Workload with 18 output channels = 36 words (2 words/channel)
        // 16-PE mode: Pass 0 has 16 channels (32 words), Pass 1 (tail) has 2 channels (4 words)
        $display("\n--- Test 1.4: Channel Tile Controller Tail Tile (18 Channels = 36 Words) ---");
        apply_reset();
        tile_cfg_custom_passes = 3'd2;
        tile_cfg_custom_words  = 8'd32;
        tile_cfg_tail_words    = 8'd4;
        tile_cfg_base_ofmap_addr = 14'h0500;
        @(negedge clk);
        tile_layer_start = 1'b1;
        @(posedge clk);
        tile_layer_start = 1'b0;
        #1;
        check("T1.4: Custom passes configured == 2", tile_total_passes == 3'd2);
        check("T1.4 Pass 0: Words == 32", tile_words_per_tile == 8'd32);
        check("T1.4 Pass 0: Addr == 14'h0500", tile_current_ofmap_addr == 14'h0500);

        @(posedge clk); // ST_CLEAR_ACCUM -> ST_FEEDER_RUN
        tile_feeder_compute_done = 1'b1;
        @(posedge clk); // ST_FEEDER_RUN -> ST_DRAIN_RUN
        tile_feeder_compute_done = 1'b0;

        tile_ofmap_drain_done = 1'b1;
        @(posedge clk); // ST_DRAIN_RUN -> ST_CHECK_TILES
        tile_ofmap_drain_done = 1'b0;

        // Pass 1: Tail Pass
        @(posedge clk); // ST_CHECK_TILES -> ST_CLEAR_ACCUM
        #1;
        check("T1.4 Pass 1 (Tail): Current pass == 1", tile_current_pass == 3'd1);
        check("T1.4 Pass 1 (Tail): Addr == 14'h0520 (0500 + 32)", tile_current_ofmap_addr == 14'h0520);
        check("T1.4 Pass 1 (Tail): Tail words == 4", tile_words_per_tile == 8'd4);
        check("T1.4 Pass 1: Accum clear asserted", tile_accum_clear == 1'b1);

        @(posedge clk); // ST_CLEAR_ACCUM -> ST_FEEDER_RUN
        tile_feeder_compute_done = 1'b1;
        @(posedge clk); // ST_FEEDER_RUN -> ST_DRAIN_RUN
        tile_feeder_compute_done = 1'b0;

        tile_ofmap_drain_done = 1'b1;
        @(posedge clk); // ST_DRAIN_RUN -> ST_CHECK_TILES
        tile_ofmap_drain_done = 1'b0;
        #1;
        check("T1.4: Tail pass completed and layer_all_tiles_done asserted", layer_all_tiles_done == 1'b1);

        // ---------------------------------------------------------------------
        // PART 2: REQUANTIZATION UNIT FUNCTIONAL & ARITHMETIC TESTS
        // ---------------------------------------------------------------------
        $display("\n--- Part 2: Requantization Unit Arithmetic & Packing Tests ---");
        apply_reset();

        // Test 2.1: Simple Shift & Rounding (shift=4, round_en=1)
        // input = 160 -> round_offset = 8 -> val = 168 -> 168 >> 4 = 10
        rq_scale_shift = 5'd4;
        rq_round_en    = 1'b1;
        rq_relu_en     = 1'b0;
        rq_in_accum    = 40'sd160;
        rq_in_valid    = 1'b1;
        @(posedge clk);
        #1;
        check("T2.1: Ingested 1st act", rq_out_act == 16'sd10);
        check("T2.1: Act valid asserted", rq_out_act_valid == 1'b1);
        check("T2.1: Word valid not yet asserted (1 of 2)", rq_out_word_valid == 1'b0);

        // Input 2: input = 320 -> round_offset = 8 -> val = 328 -> 328 >> 4 = 20
        rq_in_accum = 40'sd320;
        @(posedge clk);
        #1;
        check("T2.2: Ingested 2nd act", rq_out_act == 16'sd20);
        check("T2.2: Word valid asserted (2 of 2)", rq_out_word_valid == 1'b1);
        check("T2.2: Packed word == {20, 10}", rq_out_word == {16'sd20, 16'sd10});

        rq_in_valid = 1'b0;
        @(posedge clk);

        // Test 2.3: ReLU Activation Clamping
        // input = -400 -> shifted < 0 -> ReLU should clamp to 0
        rq_relu_en  = 1'b1;
        rq_in_accum = -40'sd400;
        rq_in_valid = 1'b1;
        @(posedge clk);
        #1;
        check("T2.3: ReLU clamped negative to 0", rq_out_act == 16'sd0);
        check("T2.3: ReLU zero count incremented", rq_stat_relu_zeros == 1);

        // Test 2.4: Positive Saturation (Clamping to +32767)
        rq_in_accum = 40'sd1000000; // 1,000,000 >> 4 = 62,500 > 32767
        @(posedge clk);
        #1;
        check("T2.4: Positive saturation to 32767", rq_out_act == 16'sd32767);
        check("T2.4: Stat clip max incremented", rq_stat_clips_max == 1);

        // Test 2.5: Negative Saturation (Clamping to -32768)
        rq_relu_en  = 1'b0; // disable relu to test min clip
        rq_in_accum = -40'sd1000000; // -1,000,000 >> 4 = -62,500 < -32768
        @(posedge clk);
        #1;
        check("T2.5: Negative saturation to -32768", rq_out_act == -16'sd32768);
        check("T2.5: Stat clip min incremented", rq_stat_clips_min == 1);

        rq_in_valid = 1'b0;
        repeat (2) @(posedge clk);

        // Test 2.6: Half-Way Tie-Breaking Policy (Round-Half-Up / Asymmetric)
        $display("\n--- Test 2.6: Half-Way Tie-Breaking Policy (Round-Half-Up) ---");
        rq_scale_shift = 5'd1;
        rq_round_en    = 1'b1;
        rq_relu_en     = 1'b0;

        // Positive half-way: +0.5 (accum = 1) -> (1+1) >> 1 = 1
        rq_in_accum = 40'sd1;
        rq_in_valid = 1'b1;
        @(posedge clk);
        #1;
        check("T2.6: Pos Half +0.5 rounds to +1", rq_out_act == 16'sd1);

        // Positive half-way: +1.5 (accum = 3) -> (3+1) >> 1 = 2
        rq_in_accum = 40'sd3;
        @(posedge clk);
        #1;
        check("T2.6: Pos Half +1.5 rounds to +2", rq_out_act == 16'sd2);

        // Negative half-way: -0.5 (accum = -1) -> (-1+1) >> 1 = 0 (rounds up towards +inf)
        rq_in_accum = -40'sd1;
        @(posedge clk);
        #1;
        check("T2.6: Neg Half -0.5 rounds to 0 (ties towards +inf)", rq_out_act == 16'sd0);

        // Negative half-way: -1.5 (accum = -3) -> (-3+1) >> 1 = -1 (rounds up towards +inf)
        rq_in_accum = -40'sd3;
        @(posedge clk);
        #1;
        check("T2.6: Neg Half -1.5 rounds to -1 (ties towards +inf)", rq_out_act == -16'sd1);

        rq_in_valid = 1'b0;
        repeat (2) @(posedge clk);

        // Test 2.7: Extreme 40-Bit Accumulator Boundaries and All Shifts
        $display("\n--- Test 2.7: Extreme 40-Bit Limits & Shift Boundaries ---");
        // Max positive 40-bit: 2^39 - 1 = 549,755,813,887
        rq_scale_shift = 5'd0;
        rq_round_en    = 1'b0;
        rq_in_accum    = 40'sh7F_FFFF_FFFF;
        rq_in_valid    = 1'b1;
        @(posedge clk);
        #1;
        check("T2.7: Max Pos 40-bit saturates to 32767", rq_out_act == 16'sd32767);

        // Max negative 40-bit: -2^39 = -549,755,813,888
        rq_in_accum = -40'sh80_0000_0000;
        @(posedge clk);
        #1;
        check("T2.7: Max Neg 40-bit saturates to -32768", rq_out_act == -16'sd32768);

        // Shift 31 boundary
        rq_scale_shift = 5'd31;
        rq_round_en    = 1'b1;
        rq_in_accum    = 40'sh7F_FFFF_FFFF;
        @(posedge clk);
        #1;
        // (549755813887 + 2^30) >> 31 = 256
        check("T2.7: Max Pos 40-bit at Shift 31 == 256", rq_out_act == 16'sd256);

        rq_in_accum = -40'sh80_0000_0000;
        @(posedge clk);
        #1;
        // (-549755813888 + 2^30) >> 31 = -256
        check("T2.7: Max Neg 40-bit at Shift 31 == -256", rq_out_act == -16'sd256);

        rq_in_valid = 1'b0;
        repeat (2) @(posedge clk);

        // ---------------------------------------------------------------------
        // PART 3: END-TO-END INTER-LAYER CHAINING & BUFFER HANDOFF
        // ---------------------------------------------------------------------
        $display("\n--- Part 3: End-to-End Inter-Layer Chaining & Buffer Handoff ---");
        // Stream 64 accumulators into requantizer and write 32 packed 32-bit words
        // into Ping-Pong Buffer B (starting at address 14'h1000)
        apply_reset();
        rq_scale_shift    = 5'd5; // shift 5
        rq_round_en       = 1'b1;
        rq_relu_en        = 1'b1; // ReLU enabled
        rq_out_word_ready = 1'b1;

        begin : blk_chaining
            int word_addr;
            logic [31:0] golden_words [0:31];

            // Pre-calculate expected golden words using exact software model
            for (int w = 0; w < 32; w++) begin
                logic signed [15:0] a_lo, a_hi;
                a_lo = golden_requant((w*2 - 20) * 1000, 5, 1'b1, 1'b1);
                a_hi = golden_requant((w*2 + 1 - 20) * 1000, 5, 1'b1, 1'b1);
                golden_words[w] = {a_hi, a_lo};
            end

            word_addr = 14'h1000; // Buffer B base

            for (int i = 0; i < 64; i++) begin
                logic signed [39:0] test_val;
                test_val = (i - 20) * 1000; // spans negative and positive values

                rq_in_accum = test_val;
                rq_in_valid = 1'b1;
                @(posedge clk);

                // If a word is packed, write it to SRAM Port A0
                if (rq_out_word_valid && rq_out_word_ready) begin
                    sram_wr_req[0]     = 1'b1;
                    sram_wr_addr[0]    = word_addr;
                    sram_wr_din[0]     = rq_out_word;
                    sram_wr_byte_we[0] = 4'hF;
                    word_addr++;
                end else begin
                    sram_wr_req[0]     = 1'b0;
                end
            end

            // Flush final packed word if present
            rq_in_valid = 1'b0;
            @(posedge clk);
            if (rq_out_word_valid && rq_out_word_ready) begin
                sram_wr_req[0]     = 1'b1;
                sram_wr_addr[0]    = word_addr;
                sram_wr_din[0]     = rq_out_word;
                sram_wr_byte_we[0] = 4'hF;
                word_addr++;
                @(posedge clk);
            end
            sram_wr_req[0] = 1'b0;

            #1;
            check("T3.1: Exactly 64 accumulators processed", rq_stat_inputs == 64);
            check("T3.1: Exactly 32 packed words assembled", rq_stat_words == 32);
            check("T3.1: Exactly 32 words written to Buffer B", word_addr == 14'h1020);

            // Read back and verify EVERY single requantized word against the software reference
            for (int w = 0; w < 32; w++) begin
                sram_rd_req[0]  = 1'b1;
                sram_rd_addr[0] = 14'h1000 + w;
                @(posedge clk); // bank accepts request
                @(negedge clk); // read response arrives on next cycle
                check($sformatf("T3.2 Readback Word %0d ready", w), sram_rd_ready[0] == 1'b1);
                check($sformatf("T3.2 Readback Word %0d valid", w), sram_rd_rvalid[0] == 1'b1);
                check($sformatf("T3.2 Word %0d bit-exact match (0x%08X == 0x%08X)", w, sram_rd_dout[0], golden_words[w]),
                      sram_rd_dout[0] == golden_words[w]);
            end
            sram_rd_req[0] = 1'b0;
            @(posedge clk);
        end

        // ---------------------------------------------------------------------
        // Final Summary
        // ---------------------------------------------------------------------
        $display("================================================================================");
        $display("TSK-21 Multi-Pass Channel Tiling & Requantization Verification Summary:");
        $display("  Total Checks : %0d", total_checks);
        $display("  Passed Checks: %0d", passed_checks);
        $display("  Failed Checks: %0d", failed_checks);
        if (failed_checks == 0) begin
            $display("  FINAL STATUS : [RESULT: SUCCESS] All TSK-21 tests passed with zero defects!");
        end else begin
            $display("  FINAL STATUS : [RESULT: FAILURE] %0d TSK-21 checks failed!", failed_checks);
        end
        $display("================================================================================");

        $finish;
    end

endmodule
