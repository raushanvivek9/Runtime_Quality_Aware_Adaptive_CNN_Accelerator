`timescale 1ns/1ps

module tb_runtime_controller;
    localparam integer CLK_PERIOD = 10;
    localparam logic [31:0] D_MAX = 32'd3277;  // 0.05 in Q16.16 (truncated)

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic layer_start = 1'b0;
    logic layer_end = 1'b0;
    logic sample_valid = 1'b0;
    logic signed [15:0] sample_data = '0;
    logic [1:0] layer_id = '0;
    logic stats_valid, features_valid, estimate_valid, decision_valid;
    logic [31:0] element_count, zero_count;
    logic signed [47:0] sum;
    logic [63:0] sum_square;
    logic [31:0] sparsity, variance;
    logic signed [31:0] mean;
    logic [31:0] degradation_hat_16, degradation_hat_32, degradation_hat_64;
    logic [1:0] resource_cfg, decision_layer_id;
    logic fallback_to_64;

    // Independent estimator/controller path used to exercise Tests 9-12.
    logic controller_features_valid = 1'b0;
    logic [1:0] controller_features_layer_id = 2'd0;
    logic [31:0] controller_sparsity = '0;
    logic signed [31:0] controller_mean = '0;
    logic [31:0] controller_variance = '0;
    logic controller_estimate_valid;
    logic [1:0] controller_estimate_layer_id;
    logic [31:0] controller_d16, controller_d32, controller_d64;
    logic adaptive_decision_valid, fixed64_decision_valid;
    logic [1:0] adaptive_decision_layer_id, fixed64_decision_layer_id;
    logic [1:0] adaptive_resource_cfg, fixed64_resource_cfg;
    logic adaptive_fallback_to_64, fixed64_fallback_to_64;

    time stats_time;
    time decision_time;
    integer measured_latency_cycles;

    always #(CLK_PERIOD / 2) clk = ~clk;

    // layer_end is sampled on the edge that raises stats_valid. The decision is
    // registered two rising clock edges later.
    always @(posedge stats_valid) stats_time = $time;
    always @(posedge decision_valid) begin
        decision_time = $time;
        measured_latency_cycles = (decision_time - stats_time) / CLK_PERIOD;
    end

    runtime_controller_top #(.DATA_W(16)) dut (
        .clk(clk), .rst_n(rst_n), .layer_start(layer_start), .layer_end(layer_end),
        .sample_valid(sample_valid), .sample_data(sample_data), .layer_id(layer_id),
        .stats_valid(stats_valid), .features_valid(features_valid),
        .estimate_valid(estimate_valid), .decision_valid(decision_valid),
        .element_count(element_count), .zero_count(zero_count), .sum(sum),
        .sum_square(sum_square), .sparsity(sparsity), .mean(mean), .variance(variance),
        .degradation_hat_16(degradation_hat_16),
        .degradation_hat_32(degradation_hat_32),
        .degradation_hat_64(degradation_hat_64), .resource_cfg(resource_cfg),
        .fallback_to_64(fallback_to_64), .decision_layer_id(decision_layer_id)
    );

    quality_estimator controller_estimator_i (
        .clk(clk), .rst_n(rst_n), .features_valid(controller_features_valid),
        .features_layer_id(controller_features_layer_id),
        .sparsity(controller_sparsity), .mean(controller_mean),
        .variance(controller_variance), .estimate_valid(controller_estimate_valid),
        .estimate_layer_id(controller_estimate_layer_id),
        .degradation_hat_16(controller_d16), .degradation_hat_32(controller_d32),
        .degradation_hat_64(controller_d64)
    );

    resource_controller #(.D_MAX(D_MAX)) adaptive_controller_i (
        .clk(clk), .rst_n(rst_n), .estimate_valid(controller_estimate_valid),
        .estimate_layer_id(controller_estimate_layer_id),
        .degradation_hat_16(controller_d16), .degradation_hat_32(controller_d32),
        .degradation_hat_64(controller_d64), .decision_valid(adaptive_decision_valid),
        .decision_layer_id(adaptive_decision_layer_id),
        .resource_cfg(adaptive_resource_cfg), .fallback_to_64(adaptive_fallback_to_64)
    );

    resource_controller #(.D_MAX(D_MAX), .USE_FIXED64(1)) fixed64_controller_i (
        .clk(clk), .rst_n(rst_n), .estimate_valid(controller_estimate_valid),
        .estimate_layer_id(controller_estimate_layer_id),
        .degradation_hat_16(controller_d16), .degradation_hat_32(controller_d32),
        .degradation_hat_64(controller_d64), .decision_valid(fixed64_decision_valid),
        .decision_layer_id(fixed64_decision_layer_id),
        .resource_cfg(fixed64_resource_cfg), .fallback_to_64(fixed64_fallback_to_64)
    );

    task automatic begin_layer(input logic [1:0] test_layer_id);
        begin
            @(negedge clk);
            layer_id = test_layer_id;
            layer_start = 1'b1;
            @(negedge clk);
            layer_start = 1'b0;
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

    task automatic end_layer_and_check(
        input logic [1:0] expected_layer_id,
        input integer expected_count,
        input integer expected_zero_count,
        input integer signed expected_sum,
        input logic [63:0] expected_sum_square,
        input logic [31:0] expected_sparsity,
        input integer signed expected_mean,
        input logic [31:0] expected_variance,
        input [8*28-1:0] test_name
    );
        begin
            @(negedge clk);
            layer_end = 1'b1;
            @(negedge clk);
            layer_end = 1'b0;
            // One edge for the estimator and one for the resource controller.
            repeat (2) @(negedge clk);

            if (element_count !== expected_count)
                $fatal(1, "%0s: element_count got %0d expected %0d", test_name,
                       element_count, expected_count);
            if (zero_count !== expected_zero_count)
                $fatal(1, "%0s: zero_count got %0d expected %0d", test_name,
                       zero_count, expected_zero_count);
            if ($signed(sum) !== expected_sum)
                $fatal(1, "%0s: sum got %0d expected %0d", test_name, sum, expected_sum);
            if (sum_square !== expected_sum_square)
                $fatal(1, "%0s: sum_square got %0d expected %0d", test_name,
                       sum_square, expected_sum_square);
            if (sparsity !== expected_sparsity)
                $fatal(1, "%0s: sparsity got %0d expected %0d", test_name,
                       sparsity, expected_sparsity);
            if ($signed(mean) !== expected_mean)
                $fatal(1, "%0s: mean got %0d expected %0d", test_name, mean, expected_mean);
            if (variance !== expected_variance)
                $fatal(1, "%0s: variance got %0d expected %0d", test_name,
                       variance, expected_variance);
            if (!decision_valid)
                $fatal(1, "%0s: resource decision was not emitted", test_name);
            if (decision_layer_id !== expected_layer_id)
                $fatal(1, "%0s: decision layer_id got %0d expected %0d", test_name,
                       decision_layer_id, expected_layer_id);
            if (resource_cfg > 2'b10)
                $fatal(1, "%0s: invalid resource encoding %b", test_name, resource_cfg);
            if (measured_latency_cycles !== 2)
                $fatal(1, "%0s: measured latency got %0d expected 2 cycles", test_name,
                       measured_latency_cycles);
            $display("PASS %-28s N=%0d zero=%0d sum=%0d sumsq=%0d sp=%0d mean=%0d var=%0d cfg=%0d",
                     test_name, element_count, zero_count, sum, sum_square, sparsity,
                     mean, variance, resource_cfg);
        end
    endtask

    task automatic controller_feature_case(
        input logic [1:0] case_layer_id,
        input logic [31:0] case_sparsity,
        input integer signed case_mean,
        input logic [31:0] case_variance,
        input logic [1:0] expected_adaptive_cfg,
        input logic expected_fallback,
        input [8*28-1:0] test_name
    );
        begin
            @(negedge clk);
            controller_features_layer_id = case_layer_id;
            controller_sparsity = case_sparsity;
            controller_mean = case_mean;
            controller_variance = case_variance;
            controller_features_valid = 1'b1;
            @(negedge clk);
            controller_features_valid = 1'b0;
            @(negedge clk);

            if (!adaptive_decision_valid || !fixed64_decision_valid)
                $fatal(1, "%0s: controller decision was not emitted", test_name);
            if (adaptive_resource_cfg !== expected_adaptive_cfg)
                $fatal(1, "%0s: adaptive cfg got %0d expected %0d", test_name,
                       adaptive_resource_cfg, expected_adaptive_cfg);
            if (adaptive_fallback_to_64 !== expected_fallback)
                $fatal(1, "%0s: adaptive fallback got %0b expected %0b", test_name,
                       adaptive_fallback_to_64, expected_fallback);
            if (adaptive_decision_layer_id !== case_layer_id)
                $fatal(1, "%0s: adaptive layer_id mismatch", test_name);
            if (fixed64_resource_cfg !== 2'b10)
                $fatal(1, "%0s: USE_FIXED64 did not select 64 PE", test_name);
            if (fixed64_fallback_to_64 !== 1'b0)
                $fatal(1, "%0s: fixed64 is not an adaptive fallback", test_name);
            $display("PASS %-28s d16=%0d d32=%0d adaptive=%0d fixed64=%0d",
                     test_name, controller_d16, controller_d32, adaptive_resource_cfg,
                     fixed64_resource_cfg);
        end
    endtask

    initial begin
        measured_latency_cycles = -1;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;

        // Tests 1, 2, and 3 are three consecutive layers (Test 7), proving
        // that statistics do not leak across conv1, conv2, and conv3.
        begin_layer(2'd0);  // Test 1: all nonzero [1, 2, 3, 4]
        send_sample(1); send_sample(2); send_sample(3); send_sample(4);
        end_layer_and_check(2'd0, 4, 0, 10, 64'd30, 32'd0, 163840, 32'd81920,
                            "test1_all_nonzero_conv1");

        begin_layer(2'd1);  // Test 2: all zero
        send_sample(0); send_sample(0); send_sample(0); send_sample(0);
        end_layer_and_check(2'd1, 4, 4, 0, 64'd0, 32'd65536, 0, 32'd0,
                            "test2_all_zero_conv2");

        begin_layer(2'd2);  // Test 3: signed values [0, 2, 0, -2]
        send_sample(0); send_sample(2); send_sample(0); send_sample(-2);
        end_layer_and_check(2'd2, 4, 2, 0, 64'd8, 32'd32768, 0, 32'd131072,
                            "test3_signed_conv3");

        begin_layer(2'd0);  // Test 4: alternating signed values
        send_sample(1); send_sample(-1); send_sample(1); send_sample(-1);
        end_layer_and_check(2'd0, 4, 0, 0, 64'd4, 32'd0, 0, 32'd65536,
                            "test4_alternating_signed");

        begin_layer(2'd1);  // Test 5: negative values
        send_sample(-4); send_sample(-3); send_sample(-2); send_sample(-1);
        end_layer_and_check(2'd1, 4, 0, -10, 64'd30, 32'd0, -163840, 32'd81920,
                            "test5_negative_values");

        begin_layer(2'd2);  // Test 6: wider square product / saturated Q16.16 var
        send_sample(1000); send_sample(-1000); send_sample(1000); send_sample(-1000);
        end_layer_and_check(2'd2, 4, 0, 0, 64'd4000000, 32'd0, 0, 32'hffff_ffff,
                            "test6_large_values");

        begin_layer(2'd0);  // Test 8: zero-length layer, no sample_valid cycle
        end_layer_and_check(2'd0, 0, 0, 0, 64'd0, 32'd0, 0, 32'd0,
                            "test8_zero_length");

        // Tests 9-11 drive Q16.16 feature vectors through the actual prototype
        // estimator and adaptive controller. Variance 5 selects 32 PE; variance
        // 10 makes both 16 and 32 exceed D_MAX and forces conservative 64 PE.
        controller_feature_case(2'd0, 32'd0, 0, 32'd0, 2'b00, 1'b0,
                                "test9_controller_low");
        controller_feature_case(2'd1, 32'd0, 0, 32'd327680, 2'b01, 1'b0,
                                "test10_controller_medium");
        controller_feature_case(2'd2, 32'd0, 0, 32'd655360, 2'b10, 1'b1,
                                "test11_controller_high");

        // Test 12 repeats a low-degradation vector. The adaptive controller
        // selects 16 PE, while the parallel USE_FIXED64 instance must stay 64 PE.
        controller_feature_case(2'd0, 32'd0, 0, 32'd0, 2'b00, 1'b0,
                                "test12_fixed64");

        $display("Stage 8A RTL self-check PASS: layer_end-to-decision latency=%0d cycles",
                 measured_latency_cycles);
        $finish;
    end
endmodule
