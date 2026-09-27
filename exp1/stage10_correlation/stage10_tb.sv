`timescale 1ns/1ps

module tb_stage10_correlation;
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
    localparam integer CLK_PERIOD = 10;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic layer_start = 1'b0;
    logic layer_end = 1'b0;
    logic sample_valid = 1'b0;
    logic signed [DATA_WIDTH-1:0] sample_data = '0;
    logic [1:0] layer_id = 2'b00;
    logic override_enable = 1'b0;
    logic [1:0] resource_override_cfg = 2'b10;

    logic signed [DATA_WIDTH-1:0] input_mem [0:INPUT_ELEMENTS-1];
    logic signed [WEIGHT_WIDTH-1:0] weight_mem [0:WEIGHT_ELEMENTS-1];
    logic stats_valid, features_valid, estimate_valid, decision_valid;
    logic [1:0] stage8a_resource_cfg, decision_layer_id;
    logic resource_capture_valid;
    logic [1:0] captured_resource_cfg;
    logic [1:0] selected_resource_cfg;
    logic conv_start, conv_busy, conv_done, output_valid;
    logic [31:0] conv_cycle_count;
    logic [6:0] active_pe_count;
    logic [PE_COUNT-1:0] pe_enable_mask;
    logic [PE_COUNT-1:0] pe_valid_debug;
    logic signed [ACC_WIDTH-1:0] pe_accum_debug [0:PE_COUNT-1];
    logic signed [ACC_WIDTH-1:0] output_mem [0:OUTPUT_ELEMENTS-1];

    time conv_start_time;
    time conv_done_time;
    integer i;
    integer fail_count;
    integer pass_count;

    always #(CLK_PERIOD / 2) clk = ~clk;

    function automatic integer signed input_value(input integer channel, row, col);
        input_value = ((channel + row + col) % 5) - 2;
    endfunction

    function automatic integer signed weight_value(input integer output_channel, input integer input_channel,
                                                  input integer kernel_row, input integer kernel_col);
        weight_value = ((output_channel + input_channel + kernel_row + kernel_col) % 3) - 1;
    endfunction

    function automatic integer signed golden_value(input integer output_channel, input integer row, input integer col);
        integer acc;
        integer ic;
        integer kernel_row;
        integer kernel_col;
        integer rr;
        integer cc;
        begin
            acc = 0;
            for (ic = 0; ic < INPUT_C; ic = ic + 1) begin
                for (kernel_row = 0; kernel_row < 3; kernel_row = kernel_row + 1) begin
                    for (kernel_col = 0; kernel_col < 3; kernel_col = kernel_col + 1) begin
                        rr = row + kernel_row - 1;
                        cc = col + kernel_col - 1;
                        if (rr >= 0 && rr < INPUT_H && cc >= 0 && cc < INPUT_W)
                            acc = acc + input_mem[ic*INPUT_H*INPUT_W + rr*INPUT_W + cc] *
                                weight_mem[output_channel*INPUT_C*3*3 + ic*3*3 + kernel_row*3 + kernel_col];
                    end
                end
            end
            golden_value = acc;
        end
    endfunction

    task automatic init_memories();
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
            for (output_channel_index = 0; output_channel_index < OUTPUT_C; output_channel_index = output_channel_index + 1) begin
                for (channel_index = 0; channel_index < INPUT_C; channel_index = channel_index + 1) begin
                    for (kernel_row_index = 0; kernel_row_index < 3; kernel_row_index = kernel_row_index + 1) begin
                        for (kernel_col_index = 0; kernel_col_index < 3; kernel_col_index = kernel_col_index + 1) begin
                            weight_mem[output_channel_index*INPUT_C*3*3 + channel_index*3*3 + kernel_row_index*3 + kernel_col_index] =
                                weight_value(output_channel_index, channel_index, kernel_row_index, kernel_col_index);
                        end
                    end
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

    task automatic issue_monitor_stream();
        begin
            @(negedge clk);
            layer_start = 1'b1;
            @(negedge clk);
            layer_start = 1'b0;
            send_sample(1); send_sample(0); send_sample(1); send_sample(0);
            @(negedge clk);
            layer_end = 1'b1;
            @(negedge clk);
            layer_end = 1'b0;
        end
    endtask

    function automatic logic [1:0] cfg_code_for_active_pe(input integer active_pe);
        case (active_pe)
            16: cfg_code_for_active_pe = 2'b00;
            32: cfg_code_for_active_pe = 2'b01;
            default: cfg_code_for_active_pe = 2'b10;
        endcase
    endfunction

    task automatic run_cfg(input integer cfg_value, input integer expected_active_pe);
        integer flat_index;
        integer oc;
        integer row;
        integer col;
        integer mismatch_count;
        logic output_ok;
        logic [1:0] cfg_code;
        begin
            fail_count = 0;
            pass_count = 0;
            init_memories();
            layer_start = 1'b0;
            layer_end = 1'b0;
            sample_valid = 1'b0;
            sample_data = '0;
            override_enable = 1'b1;
            cfg_code = cfg_code_for_active_pe(cfg_value);
            resource_override_cfg = cfg_code;
            layer_id = 2'b00;

            issue_monitor_stream();
            wait (decision_valid);
            wait (resource_capture_valid);
            if (captured_resource_cfg !== cfg_code) begin
                $error("cfg=%0d captured mismatch got %b expected %b", cfg_value, captured_resource_cfg, cfg_code);
                $fatal(1, "resource capture mismatch");
            end
            if (active_pe_count !== expected_active_pe) begin
                $error("cfg=%0d active_pe_count mismatch got %0d expected %0d", cfg_value, active_pe_count, expected_active_pe);
                $fatal(1, "active pe mismatch");
            end

            wait (conv_start);
            conv_start_time = $time;
            wait (conv_done);
            conv_done_time = $time;
            if (output_valid !== 1'b1) begin
                $error("cfg=%0d output_valid not asserted at conv_done", cfg_value);
                $fatal(1, "output_valid missing");
            end
            if (active_pe_count !== expected_active_pe) begin
                $error("cfg=%0d active_pe_count mismatch got %0d expected %0d", cfg_value, active_pe_count, expected_active_pe);
                $fatal(1, "active pe mismatch after done");
            end

            mismatch_count = 0;
            for (oc = 0; oc < OUTPUT_C; oc = oc + 1) begin
                for (row = 0; row < INPUT_H; row = row + 1) begin
                    for (col = 0; col < INPUT_W; col = col + 1) begin
                        flat_index = oc * INPUT_H * INPUT_W + row * INPUT_W + col;
                        if ($signed(output_mem[flat_index]) !== $signed(golden_value(oc, row, col))) begin
                            mismatch_count = mismatch_count + 1;
                            $error("cfg=%0d output mismatch at oc=%0d row=%0d col=%0d got=%0d expected=%0d",
                                   cfg_value, oc, row, col, output_mem[flat_index], golden_value(oc, row, col));
                        end
                    end
                end
            end
            output_ok = (mismatch_count == 0);
            $display("RESULT resource=%0d active_pes=%0d scheduler_cycles=%0d start_to_done=%0d output_valid=%b output_match=%b active_pe_count=%0d",
                     cfg_value, expected_active_pe, conv_cycle_count,
                     (conv_done_time - conv_start_time) / CLK_PERIOD,
                     output_valid, output_ok, active_pe_count);
            if (!output_ok) $fatal(1, "RTL output mismatch for cfg=%0d", cfg_value);
        end
    endtask

    conv_runtime_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .INPUT_H(INPUT_H),
        .INPUT_W(INPUT_W),
        .INPUT_C(INPUT_C),
        .OUTPUT_C(OUTPUT_C),
        .PE_COUNT(PE_COUNT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .layer_start(layer_start),
        .layer_end(layer_end),
        .sample_valid(sample_valid),
        .sample_data(sample_data),
        .layer_id(layer_id),
        .override_enable(override_enable),
        .resource_override_cfg(resource_override_cfg),
        .input_mem(input_mem),
        .weight_mem(weight_mem),
        .decision_valid(decision_valid),
        .resource_capture_valid(resource_capture_valid),
        .captured_resource_cfg(captured_resource_cfg),
        .selected_resource_cfg(selected_resource_cfg),
        .conv_start(conv_start),
        .conv_busy(conv_busy),
        .conv_done(conv_done),
        .conv_cycle_count(conv_cycle_count),
        .output_valid(output_valid),
        .active_pe_count(active_pe_count),
        .pe_enable_mask(pe_enable_mask),
        .pe_valid_debug(pe_valid_debug),
        .pe_accum_debug(pe_accum_debug),
        .output_mem(output_mem)
    );

    initial begin
        $timeformat(-9, 0, "ns", 10);
        fail_count = 0;
        pass_count = 0;
        #(CLK_PERIOD * 2);
        rst_n = 1'b1;
        #(CLK_PERIOD * 2);

        run_cfg(16, 16);
        run_cfg(32, 32);
        run_cfg(64, 64);

        $display("Stage 10 RTL simulation: PASS");
        $finish;
    end
endmodule
