`timescale 1ns/1ps

module tb_stage8c_integration;
    localparam integer DATA_W     = 16;
    localparam integer ACC_WIDTH  = 32;
    localparam integer MATRIX_DIM = 8;
    localparam integer PE_COUNT   = 64;
    localparam integer CLK_PERIOD = 10;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic layer_start = 1'b0;
    logic layer_end = 1'b0;
    logic sample_valid = 1'b0;
    logic signed [DATA_W-1:0] sample_data = '0;
    logic [1:0] layer_id = '0;
    logic signed [DATA_W-1:0] matrix_a [0:PE_COUNT-1];
    logic signed [DATA_W-1:0] matrix_b [0:PE_COUNT-1];
    logic force_resource_enable = 1'b0;
    logic [1:0] force_resource_cfg = 2'b10;

    logic stats_valid, features_valid, estimate_valid, decision_valid;
    logic [31:0] element_count, zero_count;
    logic signed [47:0] sum;
    logic [63:0] sum_square;
    logic [31:0] sparsity, variance;
    logic signed [31:0] mean;
    logic [31:0] degradation_hat_16, degradation_hat_32, degradation_hat_64;
    logic [1:0] stage8a_resource_cfg, decision_layer_id;
    logic fallback_to_64;
    logic resource_capture_valid;
    logic [1:0] stage8a_resource_at_capture, captured_resource_cfg;
    logic [1:0] selected_resource_cfg, stage8b_captured_resource_cfg;
    logic compute_start, compute_busy, compute_done, result_valid;
    logic [31:0] compute_cycle_count;
    logic signed [ACC_WIDTH-1:0] result_matrix [0:PE_COUNT-1];
    logic [6:0] active_pe_count;
    logic [PE_COUNT-1:0] pe_enable_debug, pe_valid_debug;
    logic signed [ACC_WIDTH-1:0] pe_accum_debug [0:PE_COUNT-1];

    logic signed [ACC_WIDTH-1:0] golden_matrix [0:PE_COUNT-1];
    logic decision_seen;
    logic busy_seen;
    logic [1:0] busy_resource_cfg;
    integer capture_events;
    integer row_index;
    integer col_index;
    integer k_index;
    integer matrix_index;
    integer signed golden_sum;
    time layer_end_clock_time;
    time decision_time;
    time compute_start_time;
    time compute_done_time;
    integer decision_latency [0:2];
    integer launch_latency [0:2];
    integer compute_latency [0:2];
    integer total_latency [0:2];

    always #(CLK_PERIOD / 2) clk = ~clk;

    integration_top #(
        .DATA_W(DATA_W), .ACC_WIDTH(ACC_WIDTH), .MATRIX_DIM(MATRIX_DIM),
        .PE_COUNT(PE_COUNT)
    ) dut (
        .clk(clk), .rst_n(rst_n), .layer_start(layer_start), .layer_end(layer_end),
        .sample_valid(sample_valid), .sample_data(sample_data), .layer_id(layer_id),
        .matrix_a(matrix_a), .matrix_b(matrix_b),
        .force_resource_enable(force_resource_enable),
        .force_resource_cfg(force_resource_cfg),
        .stats_valid(stats_valid), .features_valid(features_valid),
        .estimate_valid(estimate_valid), .decision_valid(decision_valid),
        .element_count(element_count), .zero_count(zero_count), .sum(sum),
        .sum_square(sum_square), .sparsity(sparsity), .mean(mean), .variance(variance),
        .degradation_hat_16(degradation_hat_16),
        .degradation_hat_32(degradation_hat_32),
        .degradation_hat_64(degradation_hat_64),
        .stage8a_resource_cfg(stage8a_resource_cfg), .fallback_to_64(fallback_to_64),
        .decision_layer_id(decision_layer_id),
        .resource_capture_valid(resource_capture_valid),
        .stage8a_resource_at_capture(stage8a_resource_at_capture),
        .captured_resource_cfg(captured_resource_cfg),
        .selected_resource_cfg(selected_resource_cfg), .compute_start(compute_start),
        .compute_busy(compute_busy), .compute_done(compute_done),
        .compute_cycle_count(compute_cycle_count), .result_valid(result_valid),
        .result_matrix(result_matrix), .active_pe_count(active_pe_count),
        .pe_enable_debug(pe_enable_debug), .pe_valid_debug(pe_valid_debug),
        .pe_accum_debug(pe_accum_debug),
        .stage8b_captured_resource_cfg(stage8b_captured_resource_cfg)
    );

    function automatic integer signed a_value(input integer row, input integer col);
        a_value = row + col + 2;
    endfunction

    function automatic integer signed b_value(input integer row, input integer col);
        b_value = col - row + 8;
    endfunction

    function automatic logic [1:0] expected_cfg(input logic [1:0] test_layer_id);
        case (test_layer_id)
            2'd0: expected_cfg = 2'b00;
            2'd1: expected_cfg = 2'b01;
            default: expected_cfg = 2'b10;
        endcase
    endfunction

    function automatic integer expected_active(input logic [1:0] cfg);
        case (cfg)
            2'b00: expected_active = 16;
            2'b01: expected_active = 32;
            default: expected_active = 64;
        endcase
    endfunction

    function automatic integer expected_scheduler_cycles(input logic [1:0] cfg);
        case (cfg)
            2'b00: expected_scheduler_cycles = 32;
            2'b01: expected_scheduler_cycles = 16;
            default: expected_scheduler_cycles = 8;
        endcase
    endfunction

    task automatic load_matrices_and_golden;
        begin
            for (row_index = 0; row_index < MATRIX_DIM; row_index = row_index + 1) begin
                for (col_index = 0; col_index < MATRIX_DIM; col_index = col_index + 1) begin
                    matrix_a[row_index*MATRIX_DIM + col_index] = a_value(row_index, col_index);
                    matrix_b[row_index*MATRIX_DIM + col_index] = b_value(row_index, col_index);
                end
            end
            for (row_index = 0; row_index < MATRIX_DIM; row_index = row_index + 1) begin
                for (col_index = 0; col_index < MATRIX_DIM; col_index = col_index + 1) begin
                    golden_sum = 0;
                    for (k_index = 0; k_index < MATRIX_DIM; k_index = k_index + 1)
                        golden_sum = golden_sum +
                            a_value(row_index, k_index) * b_value(k_index, col_index);
                    golden_matrix[row_index*MATRIX_DIM + col_index] = golden_sum;
                end
            end
        end
    endtask

    task automatic send_sample(input integer signed value);
        begin
            @(negedge clk);
            sample_valid = 1'b1;
            sample_data = value;
            @(negedge clk);
            sample_valid = 1'b0;
        end
    endtask

    task automatic issue_activation_stream(input logic [1:0] test_layer_id);
        begin
            @(negedge clk);
            layer_id = test_layer_id;
            layer_start = 1'b1;
            @(negedge clk);
            layer_start = 1'b0;

            // These deterministic streams exercise zeros and signed values.
            // Their naturally produced Stage 8A decisions are 16, 32, and 64.
            case (test_layer_id)
                2'd0: begin
                    send_sample(1); send_sample(0); send_sample(1); send_sample(0);
                end
                2'd1: begin
                    send_sample(0); send_sample(3); send_sample(0); send_sample(-3);
                end
                default: begin
                    send_sample(0); send_sample(4); send_sample(0); send_sample(-4);
                end
            endcase

            @(negedge clk);
            layer_end = 1'b1;
            @(negedge clk);
            layer_end = 1'b0;
        end
    endtask

    task automatic verify_stats_and_estimates(input logic [1:0] test_layer_id);
        begin
            if (element_count !== 32'd4)
                $fatal(1, "layer %0d: element_count got %0d expected 4", test_layer_id, element_count);
            case (test_layer_id)
                2'd0: begin
                    if (zero_count !== 32'd2 || $signed(sum) !== 2 || sum_square !== 64'd2 ||
                        sparsity !== 32'd32768 || $signed(mean) !== 32768 || variance !== 32'd16384 ||
                        degradation_hat_16 !== 32'd950 || degradation_hat_32 !== 32'd475 ||
                        degradation_hat_64 !== 0 || fallback_to_64 !== 1'b0)
                        $fatal(1, "conv1: Stage 8A statistics, estimates, or decision metadata mismatch");
                end
                2'd1: begin
                    if (zero_count !== 32'd2 || $signed(sum) !== 0 || sum_square !== 64'd18 ||
                        sparsity !== 32'd32768 || $signed(mean) !== 0 || variance !== 32'd294912 ||
                        degradation_hat_16 !== 32'd4200 || degradation_hat_32 !== 32'd2100 ||
                        degradation_hat_64 !== 0 || fallback_to_64 !== 1'b0)
                        $fatal(1, "conv2: Stage 8A statistics, estimates, or decision metadata mismatch");
                end
                default: begin
                    if (zero_count !== 32'd2 || $signed(sum) !== 0 || sum_square !== 64'd32 ||
                        sparsity !== 32'd32768 || $signed(mean) !== 0 || variance !== 32'd524288 ||
                        degradation_hat_16 !== 32'd7000 || degradation_hat_32 !== 32'd3500 ||
                        degradation_hat_64 !== 0 || fallback_to_64 !== 1'b1)
                        $fatal(1, "conv3: Stage 8A statistics, estimates, or decision metadata mismatch");
                end
            endcase
        end
    endtask

    task automatic verify_active_pe_state(
        input logic [1:0] expected_resource,
        input [8*32-1:0] test_name
    );
        integer expected_count;
        begin
            expected_count = expected_active(expected_resource);
            if (active_pe_count !== expected_count)
                $fatal(1, "%0s: active PE count got %0d expected %0d", test_name,
                       active_pe_count, expected_count);
            if (stage8b_captured_resource_cfg !== expected_resource)
                $fatal(1, "%0s: Stage 8B captured cfg got %b expected %b", test_name,
                       stage8b_captured_resource_cfg, expected_resource);
            for (matrix_index = 0; matrix_index < PE_COUNT; matrix_index = matrix_index + 1) begin
                if (matrix_index < expected_count) begin
                    if (pe_enable_debug[matrix_index] !== 1'b1)
                        $fatal(1, "%0s: PE %0d should be enabled", test_name, matrix_index);
                end else if (pe_enable_debug[matrix_index] !== 1'b0) begin
                    $fatal(1, "%0s: PE %0d should be disabled", test_name, matrix_index);
                end
            end
        end
    endtask

    task automatic verify_gemm_result(input [8*32-1:0] test_name);
        begin
            if (result_valid !== 1'b1)
                $fatal(1, "%0s: result_valid was not asserted", test_name);
            for (matrix_index = 0; matrix_index < PE_COUNT; matrix_index = matrix_index + 1) begin
                if ($signed(result_matrix[matrix_index]) !== $signed(golden_matrix[matrix_index]))
                    $fatal(1, "%0s: C[%0d] got %0d expected %0d", test_name, matrix_index,
                           result_matrix[matrix_index], golden_matrix[matrix_index]);
            end
        end
    endtask

    task automatic run_real_layer(input logic [1:0] test_layer_id);
        logic [1:0] expected_resource;
        logic [1:0] changed_live_resource;
        begin
            expected_resource = expected_cfg(test_layer_id);
            force_resource_enable = 1'b0;
            issue_activation_stream(test_layer_id);

            @(posedge decision_valid);
            #1;
            if (decision_layer_id !== test_layer_id)
                $fatal(1, "layer %0d: decision belongs to layer %0d", test_layer_id,
                       decision_layer_id);
            if (stage8a_resource_cfg !== expected_resource)
                $fatal(1, "layer %0d: Stage 8A resource cfg got %b expected %b", test_layer_id,
                       stage8a_resource_cfg, expected_resource);
            if (compute_start !== 1'b0 || compute_busy !== 1'b0)
                $fatal(1, "layer %0d: compute began before the decision was captured", test_layer_id);
            verify_stats_and_estimates(test_layer_id);

            @(posedge resource_capture_valid);
            #1;
            if (stage8a_resource_at_capture !== stage8a_resource_cfg)
                $fatal(1, "layer %0d: Stage 8A cfg was not captured faithfully", test_layer_id);
            if (captured_resource_cfg !== expected_resource ||
                selected_resource_cfg !== expected_resource)
                $fatal(1, "layer %0d: integration boundary capture mismatch", test_layer_id);
            if (capture_events !== (test_layer_id + 1))
                $fatal(1, "layer %0d: unexpected decision/capture event count %0d", test_layer_id,
                       capture_events);

            @(posedge compute_busy);
            #1;
            verify_active_pe_state(expected_resource, "live Stage 8A resource path");

            // Deliberately perturb the live, test-only candidate while Stage 8B
            // is busy. The registered boundary and physical array must ignore it.
            if (expected_resource == 2'b00)
                changed_live_resource = 2'b10;
            else
                changed_live_resource = 2'b00;
            @(negedge clk);
            force_resource_enable = 1'b1;
            force_resource_cfg = changed_live_resource;
            #1;
            if (selected_resource_cfg !== changed_live_resource)
                $fatal(1, "layer %0d: live resource perturbation was not applied", test_layer_id);
            repeat (3) @(negedge clk);
            if (compute_busy !== 1'b1 || captured_resource_cfg !== expected_resource ||
                stage8b_captured_resource_cfg !== expected_resource)
                $fatal(1, "layer %0d: configuration changed while compute was busy", test_layer_id);
            verify_active_pe_state(expected_resource, "stable captured resource path");

            @(posedge compute_done);
            #1;
            if (compute_cycle_count !== expected_scheduler_cycles(expected_resource))
                $fatal(1, "layer %0d: scheduler cycles got %0d expected %0d", test_layer_id,
                       compute_cycle_count, expected_scheduler_cycles(expected_resource));
            verify_gemm_result("end-to-end GEMM");
            if (captured_resource_cfg !== expected_resource)
                $fatal(1, "layer %0d: capture changed at completion", test_layer_id);

            decision_latency[test_layer_id] =
                (decision_time - layer_end_clock_time) / CLK_PERIOD;
            launch_latency[test_layer_id] =
                (compute_start_time - decision_time) / CLK_PERIOD;
            compute_latency[test_layer_id] =
                (compute_done_time - compute_start_time) / CLK_PERIOD;
            total_latency[test_layer_id] =
                (compute_done_time - layer_end_clock_time) / CLK_PERIOD;

            $display("PASS conv%0d real_stage8a cfg=%0d active=%0d scheduler_cycles=%0d ",
                     test_layer_id + 1, active_pe_count, active_pe_count, compute_cycle_count);
            @(negedge clk);
            force_resource_enable = 1'b0;
        end
    endtask

    // Test 1: Stage 8B cannot start before a real Stage 8A decision. Tests 3,
    // 8, and 9: each accepted decision is captured and remains stable in flight.
    always @(posedge clk) begin
        if (!rst_n) begin
            decision_seen = 1'b0;
            busy_seen = 1'b0;
            busy_resource_cfg = 2'b10;
            layer_end_clock_time = 0;
        end else begin
            if (layer_start)
                decision_seen = 1'b0;
            if (layer_end)
                layer_end_clock_time = $time;
            if (decision_valid)
                decision_seen = 1'b1;
            if (compute_start && !decision_seen)
                $fatal(1, "ASSERTION: compute_start occurred before decision_valid");
            if (compute_busy) begin
                if (!busy_seen) begin
                    busy_seen = 1'b1;
                    busy_resource_cfg = captured_resource_cfg;
                end else if (captured_resource_cfg !== busy_resource_cfg) begin
                    $fatal(1, "ASSERTION: captured resource changed while busy");
                end
            end else begin
                busy_seen = 1'b0;
            end
        end
    end

    always @(posedge decision_valid) decision_time = $time;
    always @(posedge compute_start) compute_start_time = $time;
    always @(posedge compute_done) compute_done_time = $time;
    always @(posedge resource_capture_valid) capture_events = capture_events + 1;

    initial begin
        $dumpfile("stage8c_wave.vcd");
        $dumpvars(0, tb_stage8c_integration);
        capture_events = 0;
        decision_time = 0;
        compute_start_time = 0;
        compute_done_time = 0;
        load_matrices_and_golden();

        // Reset both existing blocks through their native active-low/high ports.
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        if (compute_busy !== 1'b0 || compute_done !== 1'b0 || result_valid !== 1'b0)
            $fatal(1, "reset: Stage 8B control outputs were not cleared");

        // Three sequential real-controller workloads: conv1, conv2, conv3.
        run_real_layer(2'd0);
        run_real_layer(2'd1);
        run_real_layer(2'd2);

        $display("Layer | Resource | Active PEs | Compute cycles | Result");
        $display("-------------------------------------------------------");
        for (matrix_index = 0; matrix_index < 3; matrix_index = matrix_index + 1) begin
            $display("conv%0d | %8s | %10d | %14d | PASS", matrix_index + 1,
                     (matrix_index == 0) ? "16" : ((matrix_index == 1) ? "32" : "64"),
                     (matrix_index == 0) ? 16 : ((matrix_index == 1) ? 32 : 64),
                     (matrix_index == 0) ? 32 : ((matrix_index == 1) ? 16 : 8));
            $display("  latency cycles: layer_end->decision=%0d decision->start=%0d start->done=%0d layer_end->done=%0d",
                     decision_latency[matrix_index], launch_latency[matrix_index],
                     compute_latency[matrix_index], total_latency[matrix_index]);
        end
        $display("Stage 8C RTL integration self-check PASS: three real Stage 8A decisions drove one Stage 8B array.");
        $finish;
    end
endmodule
