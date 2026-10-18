// =============================================================================
// Project: Neural_Acc (Phase 2 Step 1 Completion Closure Verification)
// Module: tb_golden_closed_loop_handshake.sv
// Description: Closed-loop Golden Regression Testbench with Active Completion
//              Handshake Monitoring on actual modified accelerator_core_top.
// Features:
// - Explicitly binds and monitors completion_valid and drives completion_ready.
// - Counts acceptance strictly on (completion_valid && completion_ready) at posedge clk.
// - Injects periodic consumer backpressure stalls (every 100 dot products).
// - Validates numerical results, sticky saturation, and resolved counts.
// - Checks that every operation achieves exactly 1 accepted completion.
// - Fails immediately on missing, duplicate, or mismatched completions.
// =============================================================================

`timescale 1ns / 1ps

module tb_golden_closed_loop_handshake;

    localparam int CLK_PERIOD   = 10;
    localparam int ACT_WIDTH    = 16;
    localparam int WEIGHT_WIDTH = 16;
    localparam int ACCUM_WIDTH  = 40;
    localparam int K_WIDTH      = 16;
    localparam int TAG_WIDTH    = 8;

    logic                          clk;
    logic                          rst_n;
    
    logic                          slot_alloc_req;
    logic [K_WIDTH-1:0]            slot_k_total;
    logic                          slot_alloc_ready;
    logic [2:0]                    slot_fsm_state;
    
    logic                          flit_valid;
    logic [TAG_WIDTH-1:0]          flit_tag;
    logic [K_WIDTH-1:0]            flit_k_idx;
    logic                          flit_is_skip;
    logic signed [ACT_WIDTH-1:0]   flit_act_data;
    logic                          flit_act_mask;
    logic signed [WEIGHT_WIDTH-1:0] flit_weight_data;
    
    logic                          flit_accepted;
    logic                          stale_flit_rejected;
    logic                          seq_error;
    logic                          layer_barrier_req;
    logic                          drain_fifo_empty;
    logic                          slot_quiescent;
    logic                          drain_enable;
    
    logic signed [ACCUM_WIDTH-1:0] accum_result;
    logic                          sticky_saturation;
    logic [K_WIDTH-1:0]            k_resolved;
    logic [K_WIDTH-1:0]            k_executed;
    logic [K_WIDTH-1:0]            k_skipped;
    logic                          slot_done;
    logic                          sat_clear;
    logic                          seq_error_clear;

    logic                          completion_valid;
    logic                          completion_ready;

    // Instantiate modified accelerator_core_top
    accelerator_core_top #(
        .ACT_WIDTH(ACT_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .K_WIDTH(K_WIDTH),
        .TAG_WIDTH(TAG_WIDTH)
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
        .completion_valid(completion_valid),
        .completion_ready(completion_ready),
        .sat_clear(sat_clear),
        .seq_error_clear(seq_error_clear)
    );

    // Clock generator
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Global simulation watchdog (180 seconds maximum)
    initial begin
        #180000000;
        $display("[FATAL WATCHDOG] tb_golden_closed_loop_handshake simulation timeout reached (180s)!");
        $fflush();
        $finish(2);
    end

    // Independent Handshake Acceptance Monitor
    longint total_handshake_events = 0;
    int current_op_handshakes = 0;

    always @(posedge clk) begin
        if (rst_n && completion_valid && completion_ready) begin
            total_handshake_events++;
            current_op_handshakes++;
        end
    end

    // File handles and variables
    int file;
    string cmd_type;
    int k_len_in;
    int k_idx_in;
    int mask_in;
    int skip_in;
    int act_in;
    int wt_in;
    logic signed [39:0] exp_accum;
    int exp_sat;
    int exp_resolved;
    int exp_executed;
    int exp_skipped;

    int dp_count = 0;
    int pass_count = 0;
    int fail_count = 0;
    int timeout_count = 0;
    int missing_completions = 0;
    int duplicate_completions = 0;
    int mismatched_completions = 0;
    int backpressure_cycles_tested = 0;

    initial begin
        $display("==================================================================");
        $display("Starting Closed-Loop Golden Regression Suite (10,000 Dot Products)");
        $display("==================================================================");
        $fflush();

        slot_alloc_req = 0;
        slot_k_total = 0;
        flit_valid = 0;
        flit_tag = 0;
        flit_k_idx = 0;
        flit_is_skip = 0;
        flit_act_data = 0;
        flit_act_mask = 0;
        flit_weight_data = 0;
        layer_barrier_req = 0;
        drain_fifo_empty = 1;
        sat_clear = 0;
        seq_error_clear = 0;
        completion_ready = 1;
        
        rst_n = 0;
        repeat(4) @(negedge clk);
        rst_n = 1;
        repeat(2) @(negedge clk);

        file = $fopen("/home/cs25m115/Neural_Acc/phase2_step1_integration_evidence/technical_closure_20261017_022707/build/stimulus_10k_sat.txt", "r");
        if (file == 0) begin
            $display("[FATAL] Could not open stimulus file!");
            $finish(1);
        end

        while (!$feof(file)) begin
            if ($fscanf(file, "%s", cmd_type) != 1) break;

            if (cmd_type == "A") begin
                int unused_a;
                unused_a = $fscanf(file, "%d\n", k_len_in);
                if (sticky_saturation) begin
                    sat_clear = 1;
                    @(negedge clk);
                    sat_clear = 0;
                end
                
                // Wait for slot_alloc_ready (ST_FREE)
                timeout_count = 0;
                while (!slot_alloc_ready && timeout_count < 20) begin
                    @(negedge clk);
                    timeout_count++;
                end

                if (!slot_alloc_ready) begin
                    $display("[FATAL] DP #%0d alloc timeout: slot not ready! (state=%0d)", dp_count, slot_fsm_state);
                    fail_count++;
                    $finish(1);
                end

                current_op_handshakes = 0;

                // Allocate slot
                @(negedge clk);
                slot_alloc_req = 1;
                slot_k_total   = k_len_in[15:0];
                @(negedge clk);
                slot_alloc_req = 0;

                timeout_count = 0;
                while (slot_fsm_state != 3'b010 && timeout_count < 20) begin
                    @(negedge clk);
                    timeout_count++;
                end
                
            end else if (cmd_type == "F") begin
                int unused_f;
                unused_f = $fscanf(file, "%d %d %d %d %d\n", k_idx_in, mask_in, skip_in, act_in, wt_in);
                
                @(negedge clk);
                flit_valid       = 1;
                flit_tag         = dut.u_slot_ctrl.active_gen_tag;
                flit_k_idx       = k_idx_in[15:0];
                flit_is_skip     = skip_in[0];
                flit_act_mask    = mask_in[0];
                flit_act_data    = act_in[15:0];
                flit_weight_data = wt_in[15:0];
                
            end else if (cmd_type == "C") begin
                int unused_c;
                int wait_cnt;
                bit is_backpressure_test;
                unused_c = $fscanf(file, "%d %d %d %d %d\n", exp_accum, exp_sat, exp_resolved, exp_executed, exp_skipped);
                
                @(negedge clk);
                flit_valid = 0;

                // Determine if this operation undergoes consumer backpressure stall
                // Every 100th operation holds completion_ready=0 for 3 cycles
                is_backpressure_test = ((dp_count % 100) == 0);
                if (is_backpressure_test) begin
                    completion_ready = 0;
                end else begin
                    completion_ready = 1;
                end

                // 1. Wait for completion_valid to assert from actual DUT
                wait_cnt = 0;
                while (!completion_valid && wait_cnt < 30) begin
                    @(negedge clk);
                    wait_cnt++;
                end

                if (!completion_valid) begin
                    $display("[FAIL] DP #%0d MISSING COMPLETION: completion_valid never asserted! (state=%0d, done=%b)",
                        dp_count, slot_fsm_state, slot_done);
                    missing_completions++;
                    fail_count++;
                end else begin
                    // 2. Under backpressure test, verify that core holds in ST_HANDSHAKE
                    if (is_backpressure_test) begin
                        for (int stall = 0; stall < 3; stall++) begin
                            @(negedge clk);
                            backpressure_cycles_tested++;
                            if (!completion_valid || slot_fsm_state != 3'b110) begin
                                $display("[FAIL] DP #%0d backpressure violation: dropped valid or mutated state!", dp_count);
                                fail_count++;
                            end
                        end
                        // Release backpressure
                        completion_ready = 1;
                    end

                    // Handshake acceptance occurs on the next posedge clk where valid && ready
                    @(negedge clk);

                    // 3. Verify exactly 1 handshake transfer occurred for this operation
                    if (current_op_handshakes == 0) begin
                        $display("[FAIL] DP #%0d ZERO COMPLETION ACCEPTED! (valid=%b, ready=%b, state=%0d)",
                            dp_count, completion_valid, completion_ready, slot_fsm_state);
                        missing_completions++;
                        fail_count++;
                    end else if (current_op_handshakes > 1) begin
                        $display("[FAIL] DP #%0d DUPLICATE COMPLETIONS DETECTED! (count=%0d)",
                            dp_count, current_op_handshakes);
                        duplicate_completions++;
                        fail_count++;
                    end

                    // 4. Verify numerical results and metadata against golden reference
                    if (accum_result !== exp_accum ||
                        sticky_saturation !== exp_sat[0] ||
                        k_resolved !== exp_resolved[15:0] ||
                        k_executed !== exp_executed[15:0] ||
                        k_skipped  !== exp_skipped[15:0]) begin
                        $display("[FAIL] DP #%0d NUMERICAL MISMATCH! Exp: Acc=%0d Sat=%0d Res=%0d | Got: Acc=%0d Sat=%0d Res=%0d",
                                 dp_count, exp_accum, exp_sat, exp_resolved,
                                 accum_result, sticky_saturation, k_resolved);
                        mismatched_completions++;
                        fail_count++;
                    end else begin
                        pass_count++;
                    end
                end

                dp_count++;
                if (dp_count % 1000 == 0) begin
                    $display("[PROGRESS] Completed %0d / 10000 (Passed: %0d, Failed: %0d, Handshakes: %0d)", 
                             dp_count, pass_count, fail_count, total_handshake_events);
                    $fflush();
                end

                // Drain and return to ST_FREE for next operation
                layer_barrier_req = 1;
                drain_fifo_empty  = 1;
                @(negedge clk);
                layer_barrier_req = 0;
                timeout_count = 0;
                while (!slot_alloc_ready && timeout_count < 20) begin
                    @(negedge clk);
                    timeout_count++;
                end

                // Verify that in ST_FREE, completion_valid is strictly 0
                if (completion_valid !== 1'b0) begin
                    $display("[FAIL] DP #%0d completion_valid remained high in ST_FREE!", dp_count-1);
                    fail_count++;
                end
            end
        end

        $fclose(file);
        
        $display("==================================================================");
        $display("Closed-Loop Golden Handshake Regression Summary");
        $display("Dot Products Executed:     %0d", dp_count);
        $display("Successful Pass Count:     %0d", pass_count);
        $display("Total Handshake Events:    %0d", total_handshake_events);
        $display("Missing Completions:       %0d", missing_completions);
        $display("Duplicate Completions:     %0d", duplicate_completions);
        $display("Mismatched Completions:    %0d", mismatched_completions);
        $display("Backpressure Cycles Run:   %0d", backpressure_cycles_tested);
        $display("Total Failures:            %0d", fail_count);
        $display("==================================================================");
        $fflush();

        if (fail_count == 0 && dp_count == 10000 && total_handshake_events == 10000) begin
            $display("[SUCCESS] All 10,000 Operations Completed with Exactly-Once Closed-Loop Handshakes!");
            $finish(0);
        end else begin
            $display("[ERROR] Failures detected in Closed-Loop Golden Regression!");
            $finish(1);
        end
    end

endmodule
