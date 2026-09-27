`timescale 1ns/1ps

module tb_stage9c_multilayer;
    localparam int DATA_W      = 16;
    localparam int WEIGHT_W    = 16;
    localparam int ACC_W       = 48;
    localparam int INPUT_C     = 3;
    localparam int INPUT_H     = 8;
    localparam int INPUT_W     = 8;
    localparam int OUTPUT_C    = 16;
    localparam int KERNEL      = 3;
    localparam int PAD         = 1;
    localparam int PE_COUNT    = 64;
    localparam int CLK_PERIOD  = 10;

    logic clk;
    logic rst_n;
    logic start;
    logic override_enable;
    logic [1:0] layer_id;
    logic [1:0] resource_override_cfg;

    logic signed [DATA_W-1:0] layer_in [0:INPUT_C*INPUT_H*INPUT_W-1];
    logic signed [WEIGHT_W-1:0] layer_w [0:OUTPUT_C*INPUT_C*KERNEL*KERNEL-1];
    logic signed [ACC_W-1:0] layer_out [0:OUTPUT_C*INPUT_H*INPUT_W-1];

    logic decision_valid;
    logic [1:0] resource_cfg;
    logic [1:0] captured_cfg;
    logic [1:0] decision_layer_id;
    logic conv_start, conv_busy, conv_done, output_valid;
    logic [PE_COUNT-1:0] pe_enable_mask;
    logic [6:0] active_pe_count;
    logic [31:0] cycle_count;
    logic layer_monitor_done;

    int pass_count;
    int fail_count;

    task automatic fill_layer_inputs();
        int i;
        for (i = 0; i < INPUT_C*INPUT_H*INPUT_W; i++) begin
            layer_in[i] = $signed(((i % 11) - 5) * 3 + ((i / 11) % 7) - 3);
        end
    endtask

    task automatic fill_layer_weights();
        int i;
        for (i = 0; i < OUTPUT_C*INPUT_C*KERNEL*KERNEL; i++) begin
            layer_w[i] = $signed(((i * 7) % 19) - 9);
        end
    endtask

    task automatic run_layer(input logic [1:0] id, input logic [1:0] cfg);
        int i;
        fill_layer_inputs();
        fill_layer_weights();
        @(negedge clk);
        override_enable = 1'b1;
        resource_override_cfg = cfg;
        layer_id = id;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        for (i = 0; i < 5000; i++) begin
            @(posedge clk);
            if (conv_done) begin
                if (output_valid !== 1'b1) begin
                    $error("Layer %0d did not assert output_valid at completion", id);
                    fail_count++;
                end else begin
                    pass_count++;
                end
                break;
            end
        end
        if (!conv_done) begin
            $error("Layer %0d never completed within watchdog window", id);
            fail_count++;
            return;
        end

        if (active_pe_count != 7'd16 && active_pe_count != 7'd32 && active_pe_count != 7'd64) begin
            $error("Layer %0d active_pe_count invalid: %0d", id, active_pe_count);
            fail_count++;
        end else begin
            pass_count++;
        end

        if (captured_cfg !== cfg) begin
            $error("Layer %0d override mismatch: got %b expected %b", id, captured_cfg, cfg);
            fail_count++;
        end else begin
            pass_count++;
        end

        for (i = 0; i < OUTPUT_C*INPUT_H*INPUT_W; i++) begin
            if (layer_out[i] === 'x || layer_out[i] === 'z) begin
                $error("Layer %0d output index %0d is invalid", id, i);
                fail_count++;
                break;
            end
        end
    endtask

    initial begin
        $dumpfile("stage9c_wave.vcd");
        $dumpvars(0, tb_stage9c_multilayer);

        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        override_enable = 1'b0;
        layer_id = 2'b00;
        resource_override_cfg = 2'b10;
        pass_count = 0;
        fail_count = 0;

        #(CLK_PERIOD * 2);
        rst_n = 1'b1;
        #(CLK_PERIOD * 2);

        run_layer(2'b00, 2'b00);
        run_layer(2'b01, 2'b01);
        run_layer(2'b10, 2'b10);

        @(negedge clk);
        override_enable = 1'b1;
        resource_override_cfg = 2'b01;
        layer_id = 2'b00;
        start = 1'b1;
        @(negedge clk); start = 1'b0;
        for (int i = 0; i < 5000; i++) begin
            @(posedge clk);
            if (conv_done) begin
                if (output_valid !== 1'b1) begin
                    $error("Mixed mode did not assert output_valid at completion");
                    fail_count++;
                end else begin
                    pass_count++;
                end
                break;
            end
        end
        if (!conv_done) begin
            $error("Mixed mode never completed within watchdog window");
            fail_count++;
        end
        if (captured_cfg !== 2'b01) begin
            $error("Mixed mode cfg capture mismatch: got %b expected 01", captured_cfg);
            fail_count++;
        end else begin
            pass_count++;
        end

        $display("Stage 9C validation: %0d pass checks, %0d fail checks", pass_count, fail_count);
        if (fail_count == 0)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end

    always #5 clk = ~clk;

    conv_layer_wrapper #(
        .DATA_W(DATA_W),
        .WEIGHT_W(WEIGHT_W),
        .ACC_W(ACC_W),
        .INPUT_C(INPUT_C),
        .INPUT_H(INPUT_H),
        .INPUT_W(INPUT_W),
        .OUTPUT_C(OUTPUT_C),
        .KERNEL(KERNEL),
        .PAD(PAD),
        .SCALE_BITS(32),
        .PE_COUNT(PE_COUNT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .layer_id(layer_id),
        .override_enable(override_enable),
        .resource_override_cfg(resource_override_cfg),
        .input_tensor(layer_in),
        .weight_tensor(layer_w),
        .decision_valid(decision_valid),
        .resource_cfg(resource_cfg),
        .captured_resource_cfg(captured_cfg),
        .decision_layer_id(decision_layer_id),
        .conv_start(conv_start),
        .conv_busy(conv_busy),
        .conv_done(conv_done),
        .output_valid(output_valid),
        .pe_enable_mask(pe_enable_mask),
        .active_pe_count(active_pe_count),
        .output_mem(layer_out),
        .cycle_count(cycle_count),
        .layer_monitor_done(layer_monitor_done)
    );
endmodule
