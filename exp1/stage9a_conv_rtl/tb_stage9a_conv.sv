`timescale 1ns/1ps

module tb_stage9a_conv;
    localparam integer DATA_WIDTH   = 16;
    localparam integer WEIGHT_WIDTH = 16;
    localparam integer ACC_WIDTH    = 48;
    localparam integer INPUT_H      = 8;
    localparam integer INPUT_W      = 8;
    localparam integer INPUT_C      = 3;
    localparam integer OUTPUT_C     = 16;
    localparam integer PE_COUNT     = 64;
    localparam integer INPUT_ELEMENTS  = INPUT_C * INPUT_H * INPUT_W;
    localparam integer WEIGHT_ELEMENTS = OUTPUT_C * INPUT_C * 3 * 3;
    localparam integer OUTPUT_ELEMENTS = OUTPUT_C * INPUT_H * INPUT_W;
    localparam integer CLK_PERIOD      = 10;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic layer_start = 1'b0;
    logic layer_end = 1'b0;
    logic sample_valid = 1'b0;
    logic signed [DATA_WIDTH-1:0] sample_data = '0;
    logic [1:0] layer_id = '0;
    logic override_enable = 1'b0;
    logic [1:0] resource_override_cfg = 2'b10;
    logic signed [DATA_WIDTH-1:0] input_mem [0:INPUT_ELEMENTS-1];
    logic signed [WEIGHT_WIDTH-1:0] weight_mem [0:WEIGHT_ELEMENTS-1];

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
    logic [1:0] selected_resource_cfg;
    logic conv_start, conv_busy, conv_done, output_valid, output_write_valid;
    logic [31:0] conv_cycle_count;
    logic [9:0] output_index_debug;
    logic [6:0] active_pe_count;
    logic [PE_COUNT-1:0] pe_enable_mask, pe_valid_debug;
    logic signed [ACC_WIDTH-1:0] pe_accum_debug [0:PE_COUNT-1];
    logic signed [ACC_WIDTH-1:0] output_mem [0:OUTPUT_ELEMENTS-1];

    logic signed [ACC_WIDTH-1:0] golden_output [0:OUTPUT_ELEMENTS-1];
    logic signed [ACC_WIDTH-1:0] output_16 [0:OUTPUT_ELEMENTS-1];
    logic signed [ACC_WIDTH-1:0] output_32 [0:OUTPUT_ELEMENTS-1];
    logic signed [ACC_WIDTH-1:0] disabled_pe_snapshot [0:PE_COUNT-1];
    logic decision_seen;
    logic busy_seen;
    logic [1:0] busy_resource_cfg;
    integer capture_events;
    integer input_index;
    integer weight_index;
    integer output_index;
    integer pe_index;
    integer measured_cycles [0:5];
    integer decision_latency [0:5];
    integer launch_latency [0:5];
    integer compute_latency [0:5];
    integer total_latency [0:5];
    time layer_end_clock_time;
    time decision_time;
    time conv_start_time;
    time conv_done_time;

    always #(CLK_PERIOD / 2) clk = ~clk;

    conv_runtime_top #(
        .DATA_WIDTH(DATA_WIDTH), .WEIGHT_WIDTH(WEIGHT_WIDTH), .ACC_WIDTH(ACC_WIDTH),
        .INPUT_H(INPUT_H), .INPUT_W(INPUT_W), .INPUT_C(INPUT_C), .OUTPUT_C(OUTPUT_C),
        .PE_COUNT(PE_COUNT)
    ) dut (
        .clk(clk), .rst_n(rst_n), .layer_start(layer_start), .layer_end(layer_end),
        .sample_valid(sample_valid), .sample_data(sample_data), .layer_id(layer_id),
        .override_enable(override_enable), .resource_override_cfg(resource_override_cfg),
        .input_mem(input_mem), .weight_mem(weight_mem), .stats_valid(stats_valid),
        .features_valid(features_valid), .estimate_valid(estimate_valid),
        .decision_valid(decision_valid), .element_count(element_count),
        .zero_count(zero_count), .sum(sum), .sum_square(sum_square),
        .sparsity(sparsity), .mean(mean), .variance(variance),
        .degradation_hat_16(degradation_hat_16),
        .degradation_hat_32(degradation_hat_32), .degradation_hat_64(degradation_hat_64),
        .stage8a_resource_cfg(stage8a_resource_cfg), .fallback_to_64(fallback_to_64),
        .decision_layer_id(decision_layer_id), .resource_capture_valid(resource_capture_valid),
        .stage8a_resource_at_capture(stage8a_resource_at_capture),
        .captured_resource_cfg(captured_resource_cfg),
        .selected_resource_cfg(selected_resource_cfg), .conv_start(conv_start),
        .conv_busy(conv_busy), .conv_done(conv_done), .conv_cycle_count(conv_cycle_count),
        .output_valid(output_valid), .output_write_valid(output_write_valid),
        .output_index_debug(output_index_debug), .active_pe_count(active_pe_count),
        .pe_enable_mask(pe_enable_mask), .pe_valid_debug(pe_valid_debug),
        .pe_accum_debug(pe_accum_debug), .output_mem(output_mem)
    );

    function automatic integer signed input_value(
        input integer channel, input integer row, input integer col
    );
        input_value = ((channel + row + col) % 5) - 2;
    endfunction

    function automatic integer signed weight_value(
        input integer output_channel, input integer input_channel,
        input integer kernel_row, input integer kernel_col
    );
        weight_value = ((output_channel + input_channel + kernel_row + kernel_col) % 3) - 1;
    endfunction

    function automatic logic [1:0] expected_real_cfg(input logic [1:0] test_layer_id);
        case (test_layer_id)
            2'd0: expected_real_cfg = 2'b00;
            2'd1: expected_real_cfg = 2'b01;
            default: expected_real_cfg = 2'b10;
        endcase
    endfunction

    function automatic integer expected_active_count(input logic [1:0] cfg);
        case (cfg)
            2'b00: expected_active_count = 16;
            2'b01: expected_active_count = 32;
            default: expected_active_count = 64;
        endcase
    endfunction

    task automatic load_convolution_memories;
        integer channel_index;
        integer row_index;
        integer col_index;
        integer output_channel_index;
        integer kernel_row_index;
        integer kernel_col_index;
        begin
            for (channel_index = 0; channel_index < INPUT_C; channel_index = channel_index + 1) begin
                for (row_index = 0; row_index < INPUT_H; row_index = row_index + 1) begin
                    for (col_index = 0; col_index < INPUT_W; col_index = col_index + 1) begin
                        input_mem[channel_index*INPUT_H*INPUT_W + row_index*INPUT_W + col_index] =
                            input_value(channel_index, row_index, col_index);
                    end
                end
            end
            for (output_channel_index = 0; output_channel_index < OUTPUT_C;
                 output_channel_index = output_channel_index + 1) begin
                for (channel_index = 0; channel_index < INPUT_C;
                     channel_index = channel_index + 1) begin
                    for (kernel_row_index = 0; kernel_row_index < 3;
                         kernel_row_index = kernel_row_index + 1) begin
                        for (kernel_col_index = 0; kernel_col_index < 3;
                             kernel_col_index = kernel_col_index + 1) begin
                            weight_mem[output_channel_index*INPUT_C*3*3 + channel_index*3*3 +
                                       kernel_row_index*3 + kernel_col_index] =
                                weight_value(output_channel_index, channel_index,
                                             kernel_row_index, kernel_col_index);
                        end
                    end
                end
            end
            $readmemh("golden_output.mem", golden_output);
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

    task automatic issue_monitor_stream(input logic [1:0] test_layer_id);
        begin
            @(negedge clk);
            layer_id = test_layer_id;
            layer_start = 1'b1;
            @(negedge clk);
            layer_start = 1'b0;
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

    task automatic verify_stage8a_monitor(input logic [1:0] test_layer_id);
        begin
            if (element_count !== 32'd4 || decision_layer_id !== test_layer_id)
                $fatal(1, "layer %0d: Stage 8A count or decision layer mismatch", test_layer_id);
            case (test_layer_id)
                2'd0: begin
                    if (zero_count !== 2 || $signed(sum) !== 2 || sum_square !== 2 ||
                        sparsity !== 32768 || $signed(mean) !== 32768 || variance !== 16384 ||
                        degradation_hat_16 !== 950 || degradation_hat_32 !== 475 ||
                        stage8a_resource_cfg !== 2'b00)
                        $fatal(1, "conv1 monitoring reference mismatch");
                end
                2'd1: begin
                    if (zero_count !== 2 || $signed(sum) !== 0 || sum_square !== 18 ||
                        sparsity !== 32768 || $signed(mean) !== 0 || variance !== 294912 ||
                        degradation_hat_16 !== 4200 || degradation_hat_32 !== 2100 ||
                        stage8a_resource_cfg !== 2'b01)
                        $fatal(1, "conv2 monitoring reference mismatch");
                end
                default: begin
                    if (zero_count !== 2 || $signed(sum) !== 0 || sum_square !== 32 ||
                        sparsity !== 32768 || $signed(mean) !== 0 || variance !== 524288 ||
                        degradation_hat_16 !== 7000 || degradation_hat_32 !== 3500 ||
                        stage8a_resource_cfg !== 2'b10 || fallback_to_64 !== 1'b1)
                        $fatal(1, "conv3 monitoring reference mismatch");
                end
            endcase
        end
    endtask

    task automatic verify_pe_configuration(
        input logic [1:0] expected_cfg,
        input [8*32-1:0] test_name
    );
        integer expected_count;
        begin
            expected_count = expected_active_count(expected_cfg);
            if (active_pe_count !== expected_count)
                $fatal(1, "%0s: active PE count got %0d expected %0d", test_name,
                       active_pe_count, expected_count);
            for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
                if (pe_index < expected_count) begin
                    if (pe_enable_mask[pe_index] !== 1'b1)
                        $fatal(1, "%0s: PE %0d should be enabled", test_name, pe_index);
                end else if (pe_enable_mask[pe_index] !== 1'b0) begin
                    $fatal(1, "%0s: PE %0d should be disabled", test_name, pe_index);
                end
            end
        end
    endtask

    task automatic verify_output_against_python(input [8*32-1:0] test_name);
        begin
            if (output_valid !== 1'b1)
                $fatal(1, "%0s: output_valid was not asserted", test_name);
            for (output_index = 0; output_index < OUTPUT_ELEMENTS;
                 output_index = output_index + 1) begin
                if ($signed(output_mem[output_index]) !== $signed(golden_output[output_index]))
                    $fatal(1, "%0s: output[%0d] got %0d expected Python %0d", test_name,
                           output_index, output_mem[output_index], golden_output[output_index]);
            end
            // Explicit padding/boundary and multiple-output-channel checkpoints.
            if ($signed(output_mem[0]) !== $signed(golden_output[0]) ||
                $signed(output_mem[1]) !== $signed(golden_output[1]) ||
                $signed(output_mem[1*64 + 3*8 + 3]) !== $signed(golden_output[1*64 + 3*8 + 3]) ||
                $signed(output_mem[15*64 + 7*8 + 7]) !==
                    $signed(golden_output[15*64 + 7*8 + 7]))
                $fatal(1, "%0s: explicit boundary or channel checkpoint mismatch", test_name);
        end
    endtask

    task automatic verify_disabled_pes(input logic [1:0] expected_cfg,
                                       input [8*32-1:0] test_name);
        integer expected_count;
        begin
            expected_count = expected_active_count(expected_cfg);
            for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
                if (pe_index >= expected_count) begin
                    if (pe_valid_debug[pe_index] !== 1'b0)
                        $fatal(1, "%0s: disabled PE %0d received a valid MAC", test_name, pe_index);
                    if ($signed(pe_accum_debug[pe_index]) !== $signed(disabled_pe_snapshot[pe_index]))
                        $fatal(1, "%0s: disabled PE %0d accumulator changed", test_name, pe_index);
                end
            end
        end
    endtask

    task automatic run_workload(
        input logic [1:0] monitor_layer_id,
        input logic use_override,
        input logic [1:0] requested_cfg,
        input integer run_index,
        input [8*32-1:0] test_name
    );
        logic [1:0] expected_cfg;
        logic [1:0] changed_live_cfg;
        begin
            if (use_override)
                expected_cfg = requested_cfg;
            else
                expected_cfg = expected_real_cfg(monitor_layer_id);
            override_enable = use_override;
            resource_override_cfg = requested_cfg;
            issue_monitor_stream(monitor_layer_id);

            @(posedge decision_valid);
            #1;
            verify_stage8a_monitor(monitor_layer_id);
            if (conv_start !== 1'b0 || conv_busy !== 1'b0)
                $fatal(1, "%0s: convolution began before decision capture", test_name);

            @(posedge resource_capture_valid);
            #1;
            if (stage8a_resource_at_capture !== stage8a_resource_cfg)
                $fatal(1, "%0s: Stage 8A resource was not captured faithfully", test_name);
            if (captured_resource_cfg !== expected_cfg || selected_resource_cfg !== expected_cfg)
                $fatal(1, "%0s: captured resource got %b expected %b", test_name,
                       captured_resource_cfg, expected_cfg);
            if (capture_events !== (run_index + 1))
                $fatal(1, "%0s: unexpected capture count %0d", test_name, capture_events);

            @(posedge conv_busy);
            #1;
            verify_pe_configuration(expected_cfg, test_name);
            for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
                if (pe_index >= expected_active_count(expected_cfg))
                    disabled_pe_snapshot[pe_index] = pe_accum_debug[pe_index];
            end

            // Alter the live candidate during the convolution. It is no longer
            // eligible for capture and must not affect this physical workload.
            if (expected_cfg == 2'b00)
                changed_live_cfg = 2'b10;
            else
                changed_live_cfg = 2'b00;
            @(negedge clk);
            override_enable = 1'b1;
            resource_override_cfg = changed_live_cfg;
            repeat (4) @(negedge clk);
            if (conv_busy !== 1'b1 || captured_resource_cfg !== expected_cfg ||
                selected_resource_cfg !== expected_cfg)
                $fatal(1, "%0s: captured configuration changed while busy", test_name);
            verify_pe_configuration(expected_cfg, "stable configuration");
            verify_disabled_pes(expected_cfg, "in-flight disabled PE gating");

            @(posedge conv_done);
            #1;
            measured_cycles[run_index] = conv_cycle_count;
            decision_latency[run_index] = (decision_time - layer_end_clock_time) / CLK_PERIOD;
            launch_latency[run_index] = (conv_start_time - decision_time) / CLK_PERIOD;
            compute_latency[run_index] = (conv_done_time - conv_start_time) / CLK_PERIOD;
            total_latency[run_index] = (conv_done_time - layer_end_clock_time) / CLK_PERIOD;
            verify_output_against_python(test_name);
            verify_disabled_pes(expected_cfg, "completed disabled PE gating");

            if (run_index == 0) begin
                for (output_index = 0; output_index < OUTPUT_ELEMENTS;
                     output_index = output_index + 1)
                    output_16[output_index] = output_mem[output_index];
            end else if (run_index == 1) begin
                for (output_index = 0; output_index < OUTPUT_ELEMENTS;
                     output_index = output_index + 1) begin
                    output_32[output_index] = output_mem[output_index];
                    if ($signed(output_mem[output_index]) !== $signed(output_16[output_index]))
                        $fatal(1, "override 32 PE differs from override 16 PE at output %0d", output_index);
                end
            end else if (run_index == 2) begin
                for (output_index = 0; output_index < OUTPUT_ELEMENTS;
                     output_index = output_index + 1) begin
                    if ($signed(output_mem[output_index]) !== $signed(output_16[output_index]) ||
                        $signed(output_mem[output_index]) !== $signed(output_32[output_index]))
                        $fatal(1, "override 64 PE output equality failed at output %0d", output_index);
                end
            end

            $display("PASS %-32s cfg=%0d active=%0d scheduler_cycles=%0d total_cycles=%0d",
                     test_name, expected_active_count(expected_cfg), active_pe_count,
                     conv_cycle_count, compute_latency[run_index]);
            @(negedge clk);
            override_enable = 1'b0;
        end
    endtask

    // End-to-end ordering and captured-config stability assertions.
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
            if (conv_start && !decision_seen)
                $fatal(1, "ASSERTION: conv_start occurred before decision_valid");
            if (conv_busy) begin
                if (!busy_seen) begin
                    busy_seen = 1'b1;
                    busy_resource_cfg = captured_resource_cfg;
                end else if (captured_resource_cfg !== busy_resource_cfg) begin
                    $fatal(1, "ASSERTION: captured configuration changed while convolution was busy");
                end
            end else begin
                busy_seen = 1'b0;
            end
        end
    end

    always @(posedge decision_valid) decision_time = $time;
    always @(posedge conv_start) conv_start_time = $time;
    always @(posedge conv_done) conv_done_time = $time;
    always @(posedge resource_capture_valid) capture_events = capture_events + 1;

    initial begin
        $dumpfile("stage9a_wave.vcd");
        $dumpvars(1, tb_stage9a_conv);
        capture_events = 0;
        decision_time = 0;
        conv_start_time = 0;
        conv_done_time = 0;
        load_convolution_memories();

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        if (conv_busy !== 1'b0 || conv_done !== 1'b0 || output_valid !== 1'b0 ||
            conv_cycle_count !== 0 || active_pe_count !== 64)
            $fatal(1, "reset: control state was not cleared or default configuration was not 64 PE");
        for (output_index = 0; output_index < OUTPUT_ELEMENTS; output_index = output_index + 1) begin
            if (output_mem[output_index] !== 0)
                $fatal(1, "reset: output %0d was not zero", output_index);
        end
        for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
            if (pe_accum_debug[pe_index] !== 0)
                $fatal(1, "reset: PE %0d accumulator was not zero", pe_index);
        end
        $display("PASS reset behavior");

        // RESOURCE_OVERRIDE mode establishes functional equality for all PE modes
        // and demonstrates 16 -> 32 -> 64 reconfiguration without reset.
        run_workload(2'd0, 1'b1, 2'b00, 0, "override_16pe_convolution");
        run_workload(2'd0, 1'b1, 2'b01, 1, "override_32pe_convolution");
        run_workload(2'd0, 1'b1, 2'b10, 2, "override_64pe_convolution");

        // REAL_STAGE8A mode uses the unmodified controller's actual decisions.
        run_workload(2'd0, 1'b0, 2'b10, 3, "real_stage8a_conv1");
        run_workload(2'd1, 1'b0, 2'b10, 4, "real_stage8a_conv2");
        run_workload(2'd2, 1'b0, 2'b10, 5, "real_stage8a_conv3");

        $display("Configuration | Active PE | Scheduler cycles | Start-to-done cycles | Output");
        $display("--------------------------------------------------------------------------");
        $display("16 PE         | %9d | %16d | %20d | PASS", 16, measured_cycles[0], compute_latency[0]);
        $display("32 PE         | %9d | %16d | %20d | PASS", 32, measured_cycles[1], compute_latency[1]);
        $display("64 PE         | %9d | %16d | %20d | PASS", 64, measured_cycles[2], compute_latency[2]);
        $display("Override 16 latency: end->decision=%0d decision->start=%0d start->done=%0d end->done=%0d",
                 decision_latency[0], launch_latency[0], compute_latency[0], total_latency[0]);
        $display("Override 32 latency: end->decision=%0d decision->start=%0d start->done=%0d end->done=%0d",
                 decision_latency[1], launch_latency[1], compute_latency[1], total_latency[1]);
        $display("Override 64 latency: end->decision=%0d decision->start=%0d start->done=%0d end->done=%0d",
                 decision_latency[2], launch_latency[2], compute_latency[2], total_latency[2]);
        $display("Real Stage 8A latency: conv1=%0d conv2=%0d conv3=%0d total cycles",
                 total_latency[3], total_latency[4], total_latency[5]);
        $display("Stage 9A RTL self-check PASS: 6 convolution workloads, 1024 outputs each, 27648 MACs each.");
        $finish;
    end
endmodule
