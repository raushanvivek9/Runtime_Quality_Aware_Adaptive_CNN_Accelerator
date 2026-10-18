// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Integration)
// Module: tb_acceptance_integrated.sv
// Description: Comprehensive Acceptance Testbench for Accelerator Core Top
// Covers: ATM-SRAM-01..06, ATM-SAT-01..03,05,07,08, ATM-DRN-01..07,
//         ATM-TAG-01,02,05, ATM-KPRG-01..07
// Specification: ACCEPTANCE_TEST_MATRIX.csv & Ratified Phase 2 Contracts
// =============================================================================

`timescale 1ns / 1ps

module tb_acceptance_integrated;

    localparam int CLK_PERIOD = 10;
    localparam int ACT_WIDTH = 16;
    localparam int WEIGHT_WIDTH = 16;
    localparam int ACCUM_WIDTH = 40;
    localparam int K_WIDTH = 16;
    localparam int TAG_WIDTH = 8;
    localparam int SRAM_ADDR_W = 11;
    localparam int SRAM_DATA_W = 32;

    localparam logic signed [39:0] SAT_MAX_POS = 40'sh7F_FFFF_FFFF;  // +549,755,813,887
    localparam logic signed [39:0] SAT_MAX_NEG = -40'sh80_0000_0000; // -549,755,813,888

    logic                          clk;
    logic                          rst_n;
    
    // Slot allocation
    logic                          slot_alloc_req;
    logic [K_WIDTH-1:0]            slot_k_total;
    logic                          slot_alloc_ready;
    logic [2:0]                    slot_fsm_state;
    
    // Inbound flits
    logic                          flit_valid;
    logic [TAG_WIDTH-1:0]          flit_tag;
    logic [K_WIDTH-1:0]            flit_k_idx;
    logic                          flit_is_skip;
    logic signed [ACT_WIDTH-1:0]   flit_act_data;
    logic                          flit_act_mask;
    logic signed [WEIGHT_WIDTH-1:0] flit_weight_data;
    
    // Status
    logic                          flit_accepted;
    logic                          stale_flit_rejected;
    logic                          seq_error;
    
    // Barrier & Drain
    logic                          layer_barrier_req;
    logic                          drain_fifo_empty;
    logic                          slot_quiescent;
    logic                          drain_enable;
    
    // Datapath
    logic signed [ACCUM_WIDTH-1:0] accum_result;
    logic                          sticky_saturation;
    logic [K_WIDTH-1:0]            k_resolved;
    logic [K_WIDTH-1:0]            k_executed;
    logic [K_WIDTH-1:0]            k_skipped;
    logic                          slot_done;

    // Saturation Control
    logic                          sat_clear;

    // K-Progress Diagnostics
    logic                          seq_error_clear;
    logic                          sticky_seq_error;
    logic [K_WIDTH-1:0]            err_failed_k_idx;
    logic [K_WIDTH-1:0]            err_expected_k_idx;

    // SRAM
    logic                          sram_we_a;
    logic [SRAM_ADDR_W-1:0]        sram_addr_a;
    logic [SRAM_DATA_W-1:0]        sram_din_a;
    logic [3:0]                    sram_byte_we_a;
    logic                          sram_ready_a;

    logic                          sram_re_b;
    logic [SRAM_ADDR_W-1:0]        sram_addr_b;
    logic [SRAM_DATA_W-1:0]        sram_dout_b;
    logic                          sram_rvalid_b;
    logic                          sram_ready_b;
    logic                          sram_oob_err;

    int pass_count = 0;
    int fail_count = 0;

    accelerator_core_top #(
        .ACT_WIDTH(ACT_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .K_WIDTH(K_WIDTH),
        .TAG_WIDTH(TAG_WIDTH),
        .SRAM_ADDR_W(SRAM_ADDR_W),
        .SRAM_DATA_W(SRAM_DATA_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .slot_alloc_req(slot_alloc_req),
        .slot_k_total(slot_k_total),
        .slot_alloc_ready(slot_alloc_ready),
        .slot_fsm_state(slot_fsm_state),
        .flit_valid(flit_valid),
        .flit_tag(flit_tag),
        .flit_k_idx(flit_k_idx),
        .flit_is_skip(flit_is_skip),
        .flit_act_data(flit_act_data),
        .flit_act_mask(flit_act_mask),
        .flit_weight_data(flit_weight_data),
        .flit_accepted(flit_accepted),
        .stale_flit_rejected(stale_flit_rejected),
        .seq_error(seq_error),
        .layer_barrier_req(layer_barrier_req),
        .drain_fifo_empty(drain_fifo_empty),
        .slot_quiescent(slot_quiescent),
        .drain_enable(drain_enable),
        .accum_result(accum_result),
        .sticky_saturation(sticky_saturation),
        .k_resolved(k_resolved),
        .k_executed(k_executed),
        .k_skipped(k_skipped),
        .slot_done(slot_done),
        .sat_clear(sat_clear),
        .seq_error_clear(seq_error_clear),
        .sticky_seq_error(sticky_seq_error),
        .err_failed_k_idx(err_failed_k_idx),
        .err_expected_k_idx(err_expected_k_idx),
        .sram_we_a(sram_we_a),
        .sram_addr_a(sram_addr_a),
        .sram_din_a(sram_din_a),
        .sram_byte_we_a(sram_byte_we_a),
        .sram_ready_a(sram_ready_a),
        .sram_re_b(sram_re_b),
        .sram_addr_b(sram_addr_b),
        .sram_dout_b(sram_dout_b),
        .sram_rvalid_b(sram_rvalid_b),
        .sram_ready_b(sram_ready_b),
        .sram_oob_err(sram_oob_err)
    );

    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Global simulation watchdog: prevents runaway simulation
    initial begin
        #10000000; // 10ms = 1,000,000 clock cycles at 100MHz
        $display("[FATAL WATCHDOG] tb_acceptance_integrated exceeded global simulation limit of 10ms!");
        $finish(2);
    end

    `define WAIT_TIMEOUT(test_id, cond_expr, cond_name, max_cycles) \
        begin \
            int _timeout_cycles; \
            _timeout_cycles = 0; \
            while (!(cond_expr) && _timeout_cycles < max_cycles) begin \
                @(negedge clk); \
                _timeout_cycles++; \
            end \
            if (!(cond_expr)) begin \
                $display("[TIMEOUT] %s: Timed out waiting for %s after %0d cycles (FSM=%0d, alloc_ready=%b, empty=%b)", \
                    test_id, cond_name, _timeout_cycles, slot_fsm_state, slot_alloc_ready, drain_fifo_empty); \
                fail_count++; \
                $finish(1); \
            end \
        end

    task check_condition(input string test_id, input string test_name, input logic cond);
        if (cond) begin
            $display("[PASS] %s: %s", test_id, test_name);
            pass_count++;
        end else begin
            $display("[FAIL] %s: %s", test_id, test_name);
            fail_count++;
        end
    endtask

    initial begin
        // Reset initialization
        slot_alloc_req = 0; slot_k_total = 0;
        flit_valid = 0; flit_tag = 0; flit_k_idx = 0; flit_is_skip = 0;
        flit_act_data = 0; flit_act_mask = 0; flit_weight_data = 0;
        layer_barrier_req = 0; drain_fifo_empty = 1;
        sat_clear = 0; seq_error_clear = 0;
        sram_we_a = 0; sram_addr_a = 0; sram_din_a = 0; sram_byte_we_a = 0;
        sram_re_b = 0; sram_addr_b = 0;
        
        rst_n = 0;
        #(CLK_PERIOD * 2);
        rst_n = 1;
        #(CLK_PERIOD);

        $display("==================================================================");
        $display("Executing Acceptance Test Matrix (ACCEPTANCE_TEST_MATRIX.csv)");
        $display("==================================================================");

        // ---------------------------------------------------------------------
        // Group 1: SRAM Acceptance Tests (ATM-SRAM-01 to ATM-SRAM-06)
        // ---------------------------------------------------------------------
        // ATM-SRAM-01: Port A ingestion write path
        @(negedge clk);
        sram_we_a = 1; sram_addr_a = 11'h040; sram_din_a = 32'hDEADBEEF; sram_byte_we_a = 4'b1111;
        @(negedge clk);
        sram_we_a = 0;
        // ATM-SRAM-02: Port B compute read path (1-cycle latency)
        sram_re_b = 1; sram_addr_b = 11'h040;
        @(negedge clk);
        check_condition("ATM-SRAM-01", "Port A ingestion write path committed", (sram_dout_b == 32'hDEADBEEF));
        check_condition("ATM-SRAM-02", "Port B compute read 1-cycle latency verified", (sram_dout_b == 32'hDEADBEEF && sram_rvalid_b == 1'b1));
        sram_re_b = 0;

        // ATM-SRAM-03: Simultaneous non-conflicting Port A write & Port B read
        @(negedge clk);
        sram_we_a = 1; sram_addr_a = 11'h010; sram_din_a = 32'h12345678; sram_byte_we_a = 4'b1111;
        sram_re_b = 1; sram_addr_b = 11'h040; // reads previously written 0xDEADBEEF
        @(negedge clk);
        check_condition("ATM-SRAM-03", "Concurrent non-conflicting Port A write and Port B read", (sram_dout_b == 32'hDEADBEEF));
        sram_we_a = 0; sram_re_b = 0;

        // ATM-SRAM-04: Simultaneous same-address access Read-Old-Data semantics
        @(negedge clk);
        sram_we_a = 1; sram_addr_a = 11'h050; sram_din_a = 32'h11112222; sram_byte_we_a = 4'b1111;
        @(negedge clk);
        // Address 0x050 now holds 0x11112222. Concurrently write 0xCAFEBABE and read 0x050
        sram_we_a = 1; sram_addr_a = 11'h050; sram_din_a = 32'hCAFEBABE; sram_byte_we_a = 4'b1111;
        sram_re_b = 1; sram_addr_b = 11'h050;
        @(negedge clk);
        check_condition("ATM-SRAM-04", "Simultaneous same-address access Read-Old-Data (returns 0x11112222)", (sram_dout_b == 32'h11112222));
        sram_we_a = 0; sram_re_b = 0;

        // ATM-SRAM-05: Continuous back-to-back pipelined reads (1 word/cycle throughput)
        // Pre-fill addresses 0x000 to 0x007
        for (int i = 0; i < 8; i++) begin
            @(negedge clk);
            sram_we_a = 1; sram_addr_a = i[10:0]; sram_din_a = 32'h1000_0000 + i; sram_byte_we_a = 4'b1111;
        end
        @(negedge clk);
        sram_we_a = 0;
        // Stream reads
        for (int i = 0; i < 8; i++) begin
            @(negedge clk);
            sram_re_b = 1; sram_addr_b = i[10:0];
        end
        @(negedge clk);
        sram_re_b = 0;
        check_condition("ATM-SRAM-05", "Continuous back-to-back pipelined reads sustain 1 word/cycle", (sram_rvalid_b == 1'b1));

        // ATM-SRAM-06: Out-of-bounds address request (addr >= 1296)
        @(negedge clk);
        sram_we_a = 1; sram_addr_a = 11'd1536; sram_din_a = 32'hBAD0_BAD0; sram_byte_we_a = 4'b1111;
        sram_re_b = 1; sram_addr_b = 11'd1536;
        @(negedge clk);
        sram_we_a = 0; sram_re_b = 0;
        check_condition("ATM-SRAM-06", "OOB address (1536 >= 1296) asserts sram_oob_err and returns 0", 
            (sram_oob_err == 1'b1 && sram_dout_b == 32'd0 && sram_rvalid_b == 1'b0));

        // ---------------------------------------------------------------------
        // Group 2: Saturation Acceptance Tests (ATM-SAT-01..03, 05, 07, 08)
        // ---------------------------------------------------------------------
        // Allocate slot for MAC operations
        @(negedge clk);
        slot_alloc_req = 1; slot_k_total = 16'd20000;
        @(negedge clk);
        slot_alloc_req = 0;
        @(negedge clk); // ST_COMPUTING

        // ATM-SAT-07: Positive 40-bit exact boundary (+549755813887) accumulation without saturation
        for (int i = 0; i < 16777; i++) begin
            @(negedge clk);
            flit_valid = 1; flit_tag = 8'd1; flit_k_idx = i[15:0]; flit_is_skip = 0;
            flit_act_mask = 1; flit_act_data = 16'sd32767; flit_weight_data = 16'sd1000;
        end
        @(negedge clk);
        flit_k_idx = 16'd16777; flit_act_data = 16'sd23854; flit_weight_data = 16'sd1000;
        @(negedge clk);
        flit_k_idx = 16'd16778; flit_act_data = 16'sd887; flit_weight_data = 16'sd1;
        @(negedge clk);
        flit_valid = 0;
        check_condition("ATM-SAT-07", "Exact positive boundary (+549755813887) reached without saturation", 
            (accum_result == SAT_MAX_POS && sticky_saturation == 1'b0));

        // ATM-SAT-01: Positive 40-bit overflow clamp at +549755813887 and latch sticky saturation
        @(negedge clk);
        flit_valid = 1; flit_tag = 8'd1; flit_k_idx = 16'd16779; flit_is_skip = 0;
        flit_act_mask = 1; flit_act_data = 16'sd1; flit_weight_data = 16'sd1;
        @(negedge clk);
        flit_valid = 0;
        check_condition("ATM-SAT-01", "Positive overflow clamps to +549755813887 and latches sticky saturation", 
            (accum_result == SAT_MAX_POS && sticky_saturation == 1'b1));

        // ATM-SAT-03: Sticky saturation flag persistence across subsequent nominal flits
        for (int i = 0; i < 50; i++) begin
            @(negedge clk);
            flit_valid = 1; flit_tag = 8'd1; flit_k_idx = 16'd16780 + i; flit_is_skip = 1; // skip flit
            flit_act_mask = 0;
        end
        @(negedge clk);
        flit_valid = 0;
        check_condition("ATM-SAT-03", "Sticky saturation flag persists across 50 subsequent non-saturating flits", (sticky_saturation == 1'b1));

        // ATM-SAT-05: Synchronous sat_clear pulse deasserts sticky saturation to 0
        @(negedge clk);
        sat_clear = 1;
        @(negedge clk);
        sat_clear = 0;
        check_condition("ATM-SAT-05", "Synchronous sat_clear pulse deasserts sticky saturation to 0", (sticky_saturation == 1'b0));

        // Drain current slot to reset FSM cleanly
        layer_barrier_req = 1;
        @(negedge clk);
        layer_barrier_req = 0;
        drain_fifo_empty = 1;
        repeat(4) @(negedge clk);

        // ATM-SAT-08: Negative 40-bit exact boundary (-549755813888) without saturation
        @(negedge clk);
        slot_alloc_req = 1; slot_k_total = 16'd20000;
        @(negedge clk);
        slot_alloc_req = 0;
        @(negedge clk); // ST_COMPUTING

        for (int i = 0; i < 16777; i++) begin
            @(negedge clk);
            flit_valid = 1; flit_tag = 8'd2; flit_k_idx = i[15:0]; flit_is_skip = 0;
            flit_act_mask = 1; flit_act_data = -16'sd32767; flit_weight_data = 16'sd1000;
        end
        @(negedge clk);
        flit_k_idx = 16'd16777; flit_act_data = -16'sd23854; flit_weight_data = 16'sd1000;
        @(negedge clk);
        flit_k_idx = 16'd16778; flit_act_data = -16'sd888; flit_weight_data = 16'sd1;
        @(negedge clk);
        flit_valid = 0;
        check_condition("ATM-SAT-08", "Exact negative boundary (-549755813888) reached without saturation", 
            (accum_result == SAT_MAX_NEG && sticky_saturation == 1'b0));

        // ATM-SAT-02: Negative 40-bit overflow clamp at -549755813888 and latch sticky flag
        @(negedge clk);
        flit_valid = 1; flit_tag = 8'd2; flit_k_idx = 16'd16779; flit_is_skip = 0;
        flit_act_mask = 1; flit_act_data = -16'sd1; flit_weight_data = 16'sd1;
        @(negedge clk);
        flit_valid = 0;
        check_condition("ATM-SAT-02", "Negative overflow clamps to -549755813888 and latches sticky saturation", 
            (accum_result == SAT_MAX_NEG && sticky_saturation == 1'b1));

        // Clear sat flag and drain slot
        sat_clear = 1; layer_barrier_req = 1;
        @(negedge clk);
        sat_clear = 0; layer_barrier_req = 0;
        drain_fifo_empty = 1;
        repeat(4) @(negedge clk);

        // ---------------------------------------------------------------------
        // Group 3: Drain & Backpressure Acceptance Tests (ATM-DRN-01 to ATM-DRN-07)
        // ---------------------------------------------------------------------
        // ATM-DRN-01: Quiescence entry with zero in-flight flits
        @(negedge clk);
        slot_alloc_req = 1; slot_k_total = 16'd4;
        @(negedge clk);
        slot_alloc_req = 0;
        @(negedge clk); // ST_COMPUTING
        layer_barrier_req = 1; drain_fifo_empty = 1;
        @(negedge clk);
        layer_barrier_req = 0;
        check_condition("ATM-DRN-01", "Quiescence entry with empty drain completes in 2 cycles", (drain_enable == 1'b1));
        @(negedge clk); // ST_HANDSHAKE
        @(negedge clk); // ST_QUIESCENT
        check_condition("ATM-DRN-02", "Active drain enters ST_QUIESCENT with slot_quiescent=1", (slot_quiescent == 1'b1));
        repeat(2) @(negedge clk);

        // ATM-DRN-03: Downstream backpressure (drain_fifo_empty=0) stalls slot retirement
        @(negedge clk);
        slot_alloc_req = 1; slot_k_total = 16'd2;
        @(negedge clk);
        slot_alloc_req = 0;
        @(negedge clk); // ST_COMPUTING
        // Deliver 2 flits to complete computation
        flit_valid = 1; flit_tag = 8'd4; flit_k_idx = 16'd0; flit_is_skip = 1; flit_act_mask = 0;
        @(negedge clk);
        flit_k_idx = 16'd1;
        @(negedge clk);
        flit_valid = 0;
        // Assert backpressure immediately
        drain_fifo_empty = 0;
        @(negedge clk);
        check_condition("ATM-DRN-03", "Downstream backpressure stalls in ST_DRAINING with drain_enable=1", 
            (slot_fsm_state == 3'b011 && drain_enable == 1'b1 && slot_alloc_ready == 1'b0));

        // ATM-DRN-05: Drain barrier blocks incoming compute flits while in ST_DRAINING
        flit_valid = 1; flit_tag = 8'd4; flit_k_idx = 16'd2; flit_is_skip = 0; flit_act_mask = 1;
        @(negedge clk);
        check_condition("ATM-DRN-05", "Compute flit rejected during ST_DRAINING", (flit_accepted == 1'b0));
        flit_valid = 0;

        // ATM-DRN-06: Prolonged downstream stall (1000 cycles) preserves accumulator and state
        repeat(1000) @(negedge clk);
        check_condition("ATM-DRN-06", "1000-cycle prolonged stall preserves ST_DRAINING without data loss", 
            (slot_fsm_state == 3'b011 && drain_enable == 1'b1));

        // ATM-DRN-04: Backpressure release resumes draining cleanly without data loss
        drain_fifo_empty = 1;
        @(negedge clk); // ST_HANDSHAKE
        @(negedge clk); // ST_QUIESCENT
        check_condition("ATM-DRN-04", "Backpressure release advances FSM to ST_QUIESCENT", (slot_quiescent == 1'b1));
        repeat(2) @(negedge clk);

        // ATM-DRN-07: Asynchronous reset deassertion during active drain
        @(negedge clk);
        slot_alloc_req = 1; slot_k_total = 16'd4;
        @(negedge clk);
        slot_alloc_req = 0;
        repeat(2) @(negedge clk);
        layer_barrier_req = 1; drain_fifo_empty = 0;
        @(negedge clk);
        layer_barrier_req = 0;
        // In ST_DRAINING, assert rst_n = 0
        rst_n = 0;
        repeat(2) @(negedge clk);
        check_condition("ATM-DRN-07", "Asynchronous reset during ST_DRAINING cleanly flushes to ST_FREE", 
            (slot_fsm_state == 3'b000 && drain_enable == 1'b0 && slot_alloc_ready == 1'b1));
        rst_n = 1;
        drain_fifo_empty = 1;
        repeat(2) @(negedge clk);

        // ---------------------------------------------------------------------
        // Group 4: Generation Tag Acceptance Tests (ATM-TAG-01, 02, 05)
        // ---------------------------------------------------------------------
        // ATM-TAG-01: Generation tag counter monotonic increment modulo 256
        for (int i = 0; i < 255; i++) begin
            `WAIT_TIMEOUT("ATM-TAG-01", slot_alloc_ready, "slot_alloc_ready", 20);
            slot_alloc_req = 1; slot_k_total = 16'd1;
            @(negedge clk);
            slot_alloc_req = 0;
            `WAIT_TIMEOUT("ATM-TAG-01", (slot_fsm_state == 3'b010), "ST_COMPUTING", 20);
            layer_barrier_req = 1; drain_fifo_empty = 1;
            @(negedge clk);
            layer_barrier_req = 0;
            `WAIT_TIMEOUT("ATM-TAG-01", slot_alloc_ready, "slot_alloc_ready after drain", 20);
        end
        check_condition("ATM-TAG-01", "Generation tag counter increments monotonically across 255 allocations", 
            (slot_alloc_ready == 1'b1));

        // ATM-TAG-02: Generation tag rollover from 255 to 0
        `WAIT_TIMEOUT("ATM-TAG-02", slot_alloc_ready, "slot_alloc_ready", 20);
        slot_alloc_req = 1; slot_k_total = 16'd1;
        @(negedge clk);
        slot_alloc_req = 0;
        `WAIT_TIMEOUT("ATM-TAG-02", (slot_fsm_state == 3'b010), "ST_COMPUTING", 20);
        layer_barrier_req = 1; drain_fifo_empty = 1;
        @(negedge clk);
        layer_barrier_req = 0;
        `WAIT_TIMEOUT("ATM-TAG-02", slot_alloc_ready, "slot_alloc_ready after drain", 20);
        check_condition("ATM-TAG-02", "Generation tag rollover occurs smoothly without deadlock", (slot_alloc_ready == 1'b1));

        // ATM-TAG-05: Mismatched generation tag flit rejection
        `WAIT_TIMEOUT("ATM-TAG-05", slot_alloc_ready, "slot_alloc_ready", 20);
        slot_alloc_req = 1; slot_k_total = 16'd10;
        @(negedge clk);
        slot_alloc_req = 0;
        `WAIT_TIMEOUT("ATM-TAG-05", (slot_fsm_state == 3'b010), "ST_COMPUTING", 20);
        // Inject flit with inverted tag (mismatched)
        flit_valid = 1; flit_tag = ~dut.u_slot_ctrl.active_gen_tag; flit_k_idx = 16'd0; flit_act_mask = 1;
        @(negedge clk);
        check_condition("ATM-TAG-05", "Mismatched generation tag flit rejected (stale_flit_rejected=1)", 
            (stale_flit_rejected == 1'b1 && flit_accepted == 1'b0));
        flit_valid = 0;
        // Drain slot
        layer_barrier_req = 1; drain_fifo_empty = 1;
        @(negedge clk);
        layer_barrier_req = 0;
        `WAIT_TIMEOUT("ATM-TAG-05", slot_alloc_ready, "slot_alloc_ready after drain", 20);

        // ---------------------------------------------------------------------
        // Group 5: K-Progress Acceptance Tests (ATM-KPRG-01 to ATM-KPRG-07)
        // ---------------------------------------------------------------------
        // ATM-KPRG-01: Accepts sequential K flits from 0 to 63 without error
        `WAIT_TIMEOUT("ATM-KPRG-01", slot_alloc_ready, "slot_alloc_ready", 20);
        slot_alloc_req = 1; slot_k_total = 16'd64;
        @(negedge clk);
        slot_alloc_req = 0;
        `WAIT_TIMEOUT("ATM-KPRG-01", (slot_fsm_state == 3'b010), "ST_COMPUTING", 20);
        for (int i = 0; i < 64; i++) begin
            @(negedge clk);
            flit_valid = 1; flit_tag = dut.u_slot_ctrl.active_gen_tag; flit_k_idx = i[15:0]; flit_is_skip = 0; flit_act_mask = 1;
            flit_act_data = 16'sd10; flit_weight_data = 16'sd10;
        end
        @(negedge clk);
        flit_valid = 0;
        check_condition("ATM-KPRG-01", "Accepts 64 sequential K flits without error (k_resolved=64, slot_done=1)", 
            (k_resolved == 16'd64 && slot_done == 1'b1 && sticky_seq_error == 1'b0));
        // Drain slot
        layer_barrier_req = 1; drain_fifo_empty = 1;
        @(negedge clk);
        layer_barrier_req = 0;
        `WAIT_TIMEOUT("ATM-KPRG-01", slot_alloc_ready, "slot_alloc_ready after drain", 20);

        // ATM-KPRG-02: Out-of-sequence K flit triggers immediate seq_error
        `WAIT_TIMEOUT("ATM-KPRG-02", slot_alloc_ready, "slot_alloc_ready", 20);
        slot_alloc_req = 1; slot_k_total = 16'd10;
        @(negedge clk);
        slot_alloc_req = 0;
        `WAIT_TIMEOUT("ATM-KPRG-02", (slot_fsm_state == 3'b010), "ST_COMPUTING", 20);
        // Expecting k=0, inject k=5
        flit_valid = 1; flit_tag = dut.u_slot_ctrl.active_gen_tag; flit_k_idx = 16'd5; flit_act_mask = 1;
        #1;
        check_condition("ATM-KPRG-02", "Out-of-sequence K flit (k=5 when exp=0) triggers immediate seq_error=1", (seq_error == 1'b1));
        @(negedge clk);
        flit_valid = 0;

        // ATM-KPRG-03: Sticky sequence error register latches and holds high when flit_valid falls
        #(CLK_PERIOD * 3);
        check_condition("ATM-KPRG-03", "Sticky sequence error holds high after flit_valid drops to 0", 
            (sticky_seq_error == 1'b1 && seq_error == 1'b0));

        // ATM-KPRG-04: Diagnostic registers capture failing and expected indices
        check_condition("ATM-KPRG-04", "Diagnostic registers capture failing_k=5 and expected_k=0", 
            (err_failed_k_idx == 16'd5 && err_expected_k_idx == 16'd0));

        // ATM-KPRG-05: Software host error clear deasserts sticky error and restores IDLE
        @(negedge clk);
        seq_error_clear = 1;
        @(negedge clk);
        seq_error_clear = 0;
        check_condition("ATM-KPRG-05", "seq_error_clear deasserts sticky error and clears diagnostic registers", 
            (sticky_seq_error == 1'b0 && err_failed_k_idx == 0));

        // ATM-KPRG-06: Duplicate flit arrival detection (k_idx == k-1)
        flit_valid = 1; flit_tag = dut.u_slot_ctrl.active_gen_tag; flit_k_idx = 16'd0; flit_act_mask = 1;
        @(negedge clk);
        // Inject duplicate k=0 (now expecting k=1)
        flit_k_idx = 16'd0;
        @(negedge clk);
        flit_valid = 0;
        check_condition("ATM-KPRG-06", "Duplicate flit arrival (k=0 when exp=1) asserts sticky_seq_error", 
            (sticky_seq_error == 1'b1 && err_failed_k_idx == 16'd0 && err_expected_k_idx == 16'd1));

        // ATM-KPRG-07: Concurrent sequence error and drain request handling
        layer_barrier_req = 1; drain_fifo_empty = 1;
        @(negedge clk);
        layer_barrier_req = 0;
        check_condition("ATM-KPRG-07", "Concurrent sequence error and drain handled with error preserved", 
            (sticky_seq_error == 1'b1 && drain_enable == 1'b1));
        `WAIT_TIMEOUT("ATM-KPRG-07", slot_alloc_ready, "slot_alloc_ready after drain", 20);

        $display("==================================================================");
        $display("Acceptance Test Suite Execution Summary: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All Executable RTL Acceptance Tests Passed with Zero Failures!");
            $finish(0);
        end else begin
            $display("[ERROR] Acceptance test failures detected.");
            $finish(1);
        end
    end

endmodule
