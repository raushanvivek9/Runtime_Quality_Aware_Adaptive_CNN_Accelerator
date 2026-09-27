`timescale 1ns/1ps

module tb_stage9b_dataflow;
    localparam integer DATA_WIDTH = 16;
    localparam integer ACC_WIDTH = 48;
    localparam integer INPUT_H = 8;
    localparam integer INPUT_W = 8;
    localparam integer INPUT_C = 3;
    localparam integer OUTPUT_C = 16;
    localparam integer PE_COUNT = 64;
    localparam integer INPUT_ELEMENTS = 192;
    localparam integer WEIGHT_ELEMENTS = 432;
    localparam integer OUTPUT_ELEMENTS = 1024;
    localparam integer CLK_PERIOD = 10;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic workload_start = 1'b0;
    logic load_valid = 1'b0;
    logic load_ready;
    logic signed [DATA_WIDTH-1:0] load_data = '0;
    logic [1:0] load_type = '0;
    logic [9:0] load_index = '0;
    logic load_done;
    logic [1:0] layer_id = '0;
    logic override_enable = 1'b0;
    logic [1:0] resource_override_cfg = 2'b10;
    logic output_stream_valid;
    logic output_stream_ready = 1'b1;
    logic signed [ACC_WIDTH-1:0] output_stream_data;
    logic [9:0] output_stream_index;
    logic output_stream_last, output_stream_done;
    logic input_loaded, weight_loaded;
    logic stats_valid, features_valid, estimate_valid, decision_valid;
    logic [31:0] element_count, zero_count;
    logic signed [47:0] sum;
    logic [63:0] sum_square;
    logic [31:0] sparsity, variance;
    logic signed [31:0] mean;
    logic [31:0] degradation_hat_16, degradation_hat_32, degradation_hat_64;
    logic [1:0] stage8a_resource_cfg, decision_layer_id;
    logic fallback_to_64, resource_capture_valid;
    logic [1:0] stage8a_resource_at_capture, captured_resource_cfg, selected_resource_cfg;
    logic [6:0] active_pe_count;
    logic [PE_COUNT-1:0] pe_enable_mask, pe_valid_debug;
    logic signed [ACC_WIDTH-1:0] pe_accum_debug [0:PE_COUNT-1];
    logic compute_start, compute_busy, compute_done;
    logic [31:0] schedule_cycle_count, mac_cycle_count, active_pe_mac_count;
    logic output_write_valid;
    logic [9:0] output_write_index;
    logic signed [ACC_WIDTH-1:0] output_write_data;
    logic [3:0] controller_state;
    logic [31:0] input_load_cycles, weight_load_cycles, monitor_cycles, decision_wait_cycles;
    logic [31:0] compute_cycles, output_stream_cycles, total_cycles;
    logic [31:0] input_buffer_reads, input_buffer_writes, weight_buffer_reads, weight_buffer_writes;
    logic [31:0] output_buffer_writes, output_stream_reads;

    logic signed [ACC_WIDTH-1:0] golden_output [0:OUTPUT_ELEMENTS-1];
    logic signed [ACC_WIDTH-1:0] output_16 [0:OUTPUT_ELEMENTS-1];
    logic signed [ACC_WIDTH-1:0] output_32 [0:OUTPUT_ELEMENTS-1];
    logic signed [ACC_WIDTH-1:0] disabled_snapshot [0:PE_COUNT-1];
    integer stream_index_seen [0:OUTPUT_ELEMENTS-1];
    integer tests_passed;
    integer cycle_counter;
    integer stream_seen_count;
    integer stream_cycles_observed;
    logic stream_check_enable;
    integer saved_schedule_cycles [0:3];
    integer saved_mac_cycles [0:3];
    integer saved_total_cycles [0:3];
    integer saved_compute_cycles [0:3];
    integer saved_decision_cycles [0:3];
    integer saved_stream_cycles [0:3];
    integer i;

    always #(CLK_PERIOD/2) clk = ~clk;

    conv_dataflow_top dut (
        .clk(clk), .rst_n(rst_n), .workload_start(workload_start),
        .load_valid(load_valid), .load_ready(load_ready), .load_data(load_data),
        .load_type(load_type), .load_index(load_index), .load_done(load_done), .layer_id(layer_id),
        .override_enable(override_enable), .resource_override_cfg(resource_override_cfg),
        .output_stream_valid(output_stream_valid), .output_stream_ready(output_stream_ready),
        .output_stream_data(output_stream_data), .output_stream_index(output_stream_index),
        .output_stream_last(output_stream_last), .output_stream_done(output_stream_done),
        .input_loaded(input_loaded), .weight_loaded(weight_loaded), .stats_valid(stats_valid),
        .features_valid(features_valid), .estimate_valid(estimate_valid), .decision_valid(decision_valid),
        .element_count(element_count), .zero_count(zero_count), .sum(sum), .sum_square(sum_square),
        .sparsity(sparsity), .mean(mean), .variance(variance),
        .degradation_hat_16(degradation_hat_16), .degradation_hat_32(degradation_hat_32),
        .degradation_hat_64(degradation_hat_64), .stage8a_resource_cfg(stage8a_resource_cfg),
        .fallback_to_64(fallback_to_64), .decision_layer_id(decision_layer_id),
        .resource_capture_valid(resource_capture_valid),
        .stage8a_resource_at_capture(stage8a_resource_at_capture),
        .captured_resource_cfg(captured_resource_cfg), .selected_resource_cfg(selected_resource_cfg),
        .active_pe_count(active_pe_count), .pe_enable_mask(pe_enable_mask),
        .pe_valid_debug(pe_valid_debug), .pe_accum_debug(pe_accum_debug),
        .compute_start(compute_start), .compute_busy(compute_busy), .compute_done(compute_done),
        .schedule_cycle_count(schedule_cycle_count), .mac_cycle_count(mac_cycle_count),
        .active_pe_mac_count(active_pe_mac_count), .output_write_valid(output_write_valid),
        .output_write_index(output_write_index), .output_write_data(output_write_data),
        .controller_state(controller_state), .input_load_cycles(input_load_cycles),
        .weight_load_cycles(weight_load_cycles), .monitor_cycles(monitor_cycles),
        .decision_wait_cycles(decision_wait_cycles), .compute_cycles(compute_cycles),
        .output_stream_cycles(output_stream_cycles), .total_cycles(total_cycles),
        .input_buffer_reads(input_buffer_reads), .input_buffer_writes(input_buffer_writes),
        .weight_buffer_reads(weight_buffer_reads), .weight_buffer_writes(weight_buffer_writes),
        .output_buffer_writes(output_buffer_writes), .output_stream_reads(output_stream_reads)
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

    function automatic integer active_count(input logic [1:0] cfg);
        case (cfg)
            2'b00: active_count = 16;
            2'b01: active_count = 32;
            default: active_count = 64;
        endcase
    endfunction

    task automatic pass_test(input [8*48-1:0] name);
        begin
            tests_passed = tests_passed + 1;
            $display("PASS TEST %0d: %0s", tests_passed, name);
        end
    endtask

    task automatic send_load(
        input logic [1:0] tensor_type,
        input logic [9:0] tensor_index,
        input logic signed [DATA_WIDTH-1:0] tensor_data
    );
        begin
            // Present the type/index with valid low first, then wait until the
            // combinational ready value has settled.  Holding valid high while
            // probing ready would otherwise duplicate the first word after a
            // tensor-type transition.
            load_valid = 1'b0;
            load_type = tensor_type;
            load_index = tensor_index;
            load_data = tensor_data;
            #1;
            while (!load_ready)
                @(negedge clk);
            load_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            load_valid = 1'b0;
        end
    endtask

    task automatic load_tensors;
        integer ic, h, w, oc, kh, kw;
        begin
            for (ic = 0; ic < INPUT_C; ic = ic + 1)
                for (h = 0; h < INPUT_H; h = h + 1)
                    for (w = 0; w < INPUT_W; w = w + 1)
                        send_load(2'b00, ic*INPUT_H*INPUT_W + h*INPUT_W + w,
                                  input_value(ic, h, w));
            for (oc = 0; oc < OUTPUT_C; oc = oc + 1)
                for (ic = 0; ic < INPUT_C; ic = ic + 1)
                    for (kh = 0; kh < 3; kh = kh + 1)
                        for (kw = 0; kw < 3; kw = kw + 1)
                            send_load(2'b01, oc*INPUT_C*3*3 + ic*3*3 + kh*3 + kw,
                                      weight_value(oc, ic, kh, kw));
            load_valid = 1'b0;
        end
    endtask

    task automatic check_loaded_tensors;
        integer index, ic, h, w, oc, kh, kw;
        begin
            if (!load_done || !input_loaded || !weight_loaded)
                $fatal(1, "load_done or buffer completion flags did not assert");
            if (input_buffer_writes !== INPUT_ELEMENTS || weight_buffer_writes !== WEIGHT_ELEMENTS)
                $fatal(1, "unexpected write counts input=%0d weight=%0d",
                       input_buffer_writes, weight_buffer_writes);
            for (ic = 0; ic < INPUT_C; ic = ic + 1)
                for (h = 0; h < INPUT_H; h = h + 1)
                    for (w = 0; w < INPUT_W; w = w + 1) begin
                        index = ic*INPUT_H*INPUT_W + h*INPUT_W + w;
                        if ($signed(dut.input_buffer_i.mem[index]) !== input_value(ic, h, w))
                            $fatal(1, "input buffer mismatch at %0d", index);
                    end
            for (oc = 0; oc < OUTPUT_C; oc = oc + 1)
                for (ic = 0; ic < INPUT_C; ic = ic + 1)
                    for (kh = 0; kh < 3; kh = kh + 1)
                        for (kw = 0; kw < 3; kw = kw + 1) begin
                            index = oc*INPUT_C*3*3 + ic*3*3 + kh*3 + kw;
                            if ($signed(dut.weight_buffer_i.mem[index]) !== weight_value(oc, ic, kh, kw))
                                $fatal(1, "weight buffer mismatch at %0d", index);
                        end
        end
    endtask

    task automatic check_pe_config(input logic [1:0] expected_cfg);
        integer expected_count;
        begin
            expected_count = active_count(expected_cfg);
            if (active_pe_count !== expected_count)
                $fatal(1, "active PE count got %0d expected %0d", active_pe_count, expected_count);
            for (i = 0; i < PE_COUNT; i = i + 1) begin
                if (pe_enable_mask[i] !== (i < expected_count))
                    $fatal(1, "PE mask mismatch at PE %0d", i);
            end
        end
    endtask

    task automatic check_disabled_pes(input logic [1:0] expected_cfg);
        integer expected_count;
        begin
            expected_count = active_count(expected_cfg);
            for (i = expected_count; i < PE_COUNT; i = i + 1) begin
                if (pe_valid_debug[i] !== 1'b0)
                    $fatal(1, "disabled PE %0d received a valid MAC", i);
                if ($signed(pe_accum_debug[i]) !== $signed(disabled_snapshot[i]))
                    $fatal(1, "disabled PE %0d changed accumulator", i);
            end
        end
    endtask

    task automatic check_output_buffer;
        begin
            if (output_buffer_writes !== OUTPUT_ELEMENTS)
                $fatal(1, "output buffer writes got %0d expected 1024", output_buffer_writes);
            for (i = 0; i < OUTPUT_ELEMENTS; i = i + 1) begin
                if ($signed(dut.output_buffer_i.mem[i]) !== $signed(golden_output[i]))
                    $fatal(1, "output[%0d] got %0d expected %0d", i,
                           dut.output_buffer_i.mem[i], golden_output[i]);
            end
            if ($signed(dut.output_buffer_i.mem[0]) !== 2 ||
                $signed(dut.output_buffer_i.mem[1]) !== 5 ||
                $signed(dut.output_buffer_i.mem[1*64 + 3*8 + 3]) !== 0 ||
                $signed(dut.output_buffer_i.mem[15*64 + 7*8 + 7]) !== 14)
                $fatal(1, "explicit padded-convolution checkpoints failed");
        end
    endtask

    task automatic capture_output(input integer run_id);
        begin
            for (i = 0; i < OUTPUT_ELEMENTS; i = i + 1) begin
                if (run_id == 0)
                    output_16[i] = dut.output_buffer_i.mem[i];
                else if (run_id == 1) begin
                    output_32[i] = dut.output_buffer_i.mem[i];
                    if ($signed(output_32[i]) !== $signed(output_16[i]))
                        $fatal(1, "32 PE differs from 16 PE at %0d", i);
                end else if (run_id == 2) begin
                    if (($signed(dut.output_buffer_i.mem[i]) !== $signed(output_16[i])) ||
                        ($signed(dut.output_buffer_i.mem[i]) !== $signed(output_32[i])))
                        $fatal(1, "64 PE differs from prior PE modes at %0d", i);
                end
            end
        end
    endtask

    task automatic verify_output_stream;
        begin
            stream_seen_count = 0;
            stream_cycles_observed = 0;
            for (i = 0; i < OUTPUT_ELEMENTS; i = i + 1)
                stream_index_seen[i] = 0;
            stream_check_enable = 1'b1;
            while (!output_stream_done)
                @(posedge clk);
            stream_check_enable = 1'b0;
            if (stream_seen_count !== OUTPUT_ELEMENTS || output_stream_reads !== OUTPUT_ELEMENTS)
                $fatal(1, "stream count got seen=%0d actions=%0d", stream_seen_count, output_stream_reads);
            if (stream_cycles_observed !== OUTPUT_ELEMENTS)
                $fatal(1, "stream required %0d handshake cycles", stream_cycles_observed);
            for (i = 0; i < OUTPUT_ELEMENTS; i = i + 1)
                if (stream_index_seen[i] != 1)
                    $fatal(1, "stream index %0d count was %0d", i, stream_index_seen[i]);
        end
    endtask

    task automatic run_workload(
        input logic use_override,
        input logic [1:0] requested_cfg,
        input logic [1:0] test_layer_id,
        input integer run_id
    );
        logic [1:0] expected_cfg;
        logic [1:0] changed_live_cfg;
        begin
            @(negedge clk);
            override_enable = use_override;
            resource_override_cfg = requested_cfg;
            layer_id = test_layer_id;
            workload_start = 1'b1;
            @(negedge clk);
            workload_start = 1'b0;
            load_tensors;
            while (!load_done)
                @(negedge clk);
            check_loaded_tensors;

            if (run_id == 0) begin
                pass_test("input loading through tensor loader");
                pass_test("weight loading through tensor loader");
                pass_test("load completion flags and counts");
            end

            @(posedge resource_capture_valid);
            #1;
            if (element_count !== INPUT_ELEMENTS || decision_layer_id !== test_layer_id)
                $fatal(1, "Stage 8A monitor saw count=%0d layer=%0d", element_count, decision_layer_id);
            if (stage8a_resource_at_capture !== stage8a_resource_cfg)
                $fatal(1, "Stage 8A decision was not faithfully captured");
            expected_cfg = use_override ? requested_cfg : stage8a_resource_cfg;
            if (captured_resource_cfg !== expected_cfg || selected_resource_cfg !== expected_cfg)
                $fatal(1, "captured cfg=%b expected=%b", captured_resource_cfg, expected_cfg);
            if (run_id == 0) begin
                pass_test("Stage 8A input-buffer monitoring");
                pass_test("resource decision capture");
            end

            @(posedge compute_busy);
            #1;
            check_pe_config(expected_cfg);
            for (i = 0; i < PE_COUNT; i = i + 1)
                if (i >= active_count(expected_cfg))
                    disabled_snapshot[i] = pe_accum_debug[i];

            changed_live_cfg = (expected_cfg == 2'b00) ? 2'b10 : 2'b00;
            @(negedge clk);
            override_enable = 1'b1;
            resource_override_cfg = changed_live_cfg;
            repeat (4) @(negedge clk);
            if (captured_resource_cfg !== expected_cfg || selected_resource_cfg !== expected_cfg)
                $fatal(1, "live resource candidate changed captured configuration");
            check_pe_config(expected_cfg);
            check_disabled_pes(expected_cfg);

            @(posedge compute_done);
            #1;
            if (active_pe_mac_count !== 27648)
                $fatal(1, "MAC count got %0d expected 27648", active_pe_mac_count);
            check_output_buffer;
            check_disabled_pes(expected_cfg);
            capture_output(run_id);

            saved_schedule_cycles[run_id] = schedule_cycle_count;
            saved_mac_cycles[run_id] = mac_cycle_count;
            saved_compute_cycles[run_id] = compute_cycles;
            saved_decision_cycles[run_id] = decision_wait_cycles;
            if (run_id == 0) begin
                pass_test("16-PE override and full 1024-output correctness");
                pass_test("output-buffer write accounting");
                pass_test("padding checkpoints");
                pass_test("disabled-PE gating");
                pass_test("configuration stability during compute");
            end else if (run_id == 1) begin
                pass_test("32-PE override with output equality");
            end else if (run_id == 2) begin
                pass_test("64-PE override with output equality");
            end

            verify_output_stream;
            saved_stream_cycles[run_id] = output_stream_cycles;
            @(posedge clk);
            saved_total_cycles[run_id] = total_cycles;
            if (run_id == 0)
                pass_test("ordered output streaming without duplicates");
            if (!use_override)
                pass_test("real Stage 8A end-to-end integration");

            $display("WORKLOAD %0d cfg=%0d load=%0d+%0d monitor=%0d decision_wait=%0d schedule=%0d mac_cycles=%0d controller_compute=%0d stream=%0d total=%0d",
                     run_id, active_count(expected_cfg), input_load_cycles, weight_load_cycles,
                     monitor_cycles, decision_wait_cycles, schedule_cycle_count, mac_cycle_count,
                     compute_cycles, output_stream_cycles, total_cycles);
        end
    endtask

    always @(posedge clk) begin
        cycle_counter = cycle_counter + 1;
        if (stream_check_enable && output_stream_valid && output_stream_ready) begin
            if (output_stream_index >= OUTPUT_ELEMENTS)
                $fatal(1, "out-of-range stream index %0d", output_stream_index);
            if (stream_index_seen[output_stream_index] != 0)
                $fatal(1, "duplicate stream index %0d", output_stream_index);
            if ($signed(output_stream_data) !== $signed(golden_output[output_stream_index]))
                $fatal(1, "stream data mismatch at %0d", output_stream_index);
            if (output_stream_last !== (output_stream_index == OUTPUT_ELEMENTS-1))
                $fatal(1, "stream last mismatch at %0d", output_stream_index);
            stream_index_seen[output_stream_index] = stream_index_seen[output_stream_index] + 1;
            stream_seen_count = stream_seen_count + 1;
            stream_cycles_observed = stream_cycles_observed + 1;
        end
    end

    initial begin
        tests_passed = 0;
        cycle_counter = 0;
        stream_check_enable = 1'b0;
        $dumpfile("stage9b_wave.vcd");
        $dumpvars(1, tb_stage9b_dataflow);
        $readmemh("golden_output.mem", golden_output);

        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        if (controller_state !== 0 || input_buffer_writes !== 0 || weight_buffer_writes !== 0 ||
            output_buffer_writes !== 0 || active_pe_mac_count !== 0 ||
            $signed(dut.input_buffer_i.mem[0]) !== 0 || $signed(dut.weight_buffer_i.mem[0]) !== 0 ||
            $signed(dut.output_buffer_i.mem[0]) !== 0)
            $fatal(1, "reset did not clear controller, buffers, or counters");
        pass_test("reset clears FSM, behavioral buffers, counters, and PE state");

        run_workload(1'b1, 2'b00, 2'd0, 0);
        run_workload(1'b1, 2'b01, 2'd1, 1);
        run_workload(1'b1, 2'b10, 2'd2, 2);
        pass_test("reconfiguration across 16/32/64 workloads without reset");
        run_workload(1'b0, 2'b10, 2'd0, 3);

        if (input_buffer_reads !== 23424 || weight_buffer_reads !== 27648 ||
            input_buffer_writes !== 192 || weight_buffer_writes !== 432 ||
            output_buffer_writes !== 1024 || output_stream_reads !== 1024)
            $fatal(1, "action counters mismatch in final run inR=%0d wR=%0d inW=%0d wW=%0d outW=%0d outR=%0d",
                   input_buffer_reads, weight_buffer_reads, input_buffer_writes, weight_buffer_writes,
                   output_buffer_writes, output_stream_reads);
        pass_test("functional buffer action counters and 27,648 MAC count");

        $display("STAGE9B ALL TESTS PASSED: %0d deterministic tests", tests_passed);
        $display("CYCLE SUMMARY 16PE schedule=%0d mac=%0d controller_compute=%0d total=%0d stream=%0d",
                 saved_schedule_cycles[0], saved_mac_cycles[0], saved_compute_cycles[0],
                 saved_total_cycles[0], saved_stream_cycles[0]);
        $display("CYCLE SUMMARY 32PE schedule=%0d mac=%0d controller_compute=%0d total=%0d stream=%0d",
                 saved_schedule_cycles[1], saved_mac_cycles[1], saved_compute_cycles[1],
                 saved_total_cycles[1], saved_stream_cycles[1]);
        $display("CYCLE SUMMARY 64PE schedule=%0d mac=%0d controller_compute=%0d total=%0d stream=%0d",
                 saved_schedule_cycles[2], saved_mac_cycles[2], saved_compute_cycles[2],
                 saved_total_cycles[2], saved_stream_cycles[2]);
        $finish;
    end
endmodule
