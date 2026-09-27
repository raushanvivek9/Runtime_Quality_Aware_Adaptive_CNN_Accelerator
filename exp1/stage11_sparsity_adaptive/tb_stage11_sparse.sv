`timescale 1ns/1ps

module tb_stage11_sparse;
    localparam integer DATA_WIDTH   = 16;
    localparam integer WEIGHT_WIDTH = 16;
    localparam integer ACC_WIDTH    = 48;
    localparam integer INPUT_H      = 8;
    localparam integer INPUT_W      = 8;
    localparam integer INPUT_C      = 3;
    localparam integer OUTPUT_C     = 16;
    localparam integer PE_COUNT     = 64;
    localparam integer CLK_PERIOD   = 10;
    localparam integer INPUT_ELEMENTS  = INPUT_C * INPUT_H * INPUT_W;
    localparam integer WEIGHT_ELEMENTS = OUTPUT_C * INPUT_C * 3 * 3;
    localparam integer OUTPUT_ELEMENTS = OUTPUT_C * INPUT_H * INPUT_W;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic [6:0] active_pe_count;
    logic signed [DATA_WIDTH-1:0] input_mem [0:INPUT_ELEMENTS-1];
    logic signed [WEIGHT_WIDTH-1:0] weight_mem [0:WEIGHT_ELEMENTS-1];
    logic output_valid;
    logic [31:0] useful_mac_count;
    logic [31:0] skipped_mac_count;
    logic [31:0] cycle_count;
    logic signed [ACC_WIDTH-1:0] output_mem [0:OUTPUT_ELEMENTS-1];

    logic signed [ACC_WIDTH-1:0] dense_ref [0:OUTPUT_ELEMENTS-1];
    integer i, oc, row, col, ic, ky, kx, yy, xx;
    integer dense_mac_count;
    integer useful_ref_count;
    integer skipped_ref_count;
    integer fail_count;

    always #(CLK_PERIOD / 2) clk = ~clk;

    function automatic integer signed input_value(input integer channel, input integer r, input integer c);
        input_value = ((channel + r + c) % 5) - 2;
    endfunction

    function automatic integer signed weight_value(input integer oc, input integer ic, input integer kr, input integer kc);
        weight_value = ((oc + ic + kr + kc) % 3) - 1;
    endfunction

    task automatic load_reference();
        begin
            dense_mac_count = 0;
            useful_ref_count = 0;
            skipped_ref_count = 0;
            for (ic = 0; ic < INPUT_C; ic = ic + 1) begin
                for (row = 0; row < INPUT_H; row = row + 1) begin
                    for (col = 0; col < INPUT_W; col = col + 1) begin
                        input_mem[ic * INPUT_H * INPUT_W + row * INPUT_W + col] = input_value(ic, row, col);
                    end
                end
            end
            for (oc = 0; oc < OUTPUT_C; oc = oc + 1) begin
                for (ic = 0; ic < INPUT_C; ic = ic + 1) begin
                    for (ky = 0; ky < 3; ky = ky + 1) begin
                        for (kx = 0; kx < 3; kx = kx + 1) begin
                            weight_mem[oc * INPUT_C * 3 * 3 + ic * 3 * 3 + ky * 3 + kx] = weight_value(oc, ic, ky, kx);
                        end
                    end
                end
            end
            for (oc = 0; oc < OUTPUT_C; oc = oc + 1) begin
                for (row = 0; row < INPUT_H; row = row + 1) begin
                    for (col = 0; col < INPUT_W; col = col + 1) begin
                        dense_ref[oc * INPUT_H * INPUT_W + row * INPUT_W + col] = '0;
                        for (ic = 0; ic < INPUT_C; ic = ic + 1) begin
                            for (ky = 0; ky < 3; ky = ky + 1) begin
                                for (kx = 0; kx < 3; kx = kx + 1) begin
                                    yy = row + ky - 1;
                                    xx = col + kx - 1;
                                    if ((yy >= 0) && (yy < INPUT_H) && (xx >= 0) && (xx < INPUT_W)) begin
                                        dense_ref[oc * INPUT_H * INPUT_W + row * INPUT_W + col] = 
                                            dense_ref[oc * INPUT_H * INPUT_W + row * INPUT_W + col] +
                                            $signed(input_mem[ic * INPUT_H * INPUT_W + yy * INPUT_W + xx]) *
                                            $signed(weight_mem[oc * INPUT_C * 3 * 3 + ic * 3 * 3 + ky * 3 + kx]);
                                        dense_mac_count = dense_mac_count + 1;
                                        if (input_mem[ic * INPUT_H * INPUT_W + yy * INPUT_W + xx] != 0) begin
                                            useful_ref_count = useful_ref_count + 1;
                                        end else begin
                                            skipped_ref_count = skipped_ref_count + 1;
                                        end
                                    end else begin
                                        dense_mac_count = dense_mac_count + 1;
                                        skipped_ref_count = skipped_ref_count + 1;
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    endtask

    task automatic check_run(input integer pe_value);
        integer mismatch_count;
        integer flat_index;
        integer ref_useful;
        integer ref_skipped;
        begin
            active_pe_count = pe_value;
            load_reference();
            rst = 1'b1;
            repeat (2) @(posedge clk);
            rst = 1'b0;
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            wait (output_valid);
            mismatch_count = 0;
            for (flat_index = 0; flat_index < OUTPUT_ELEMENTS; flat_index = flat_index + 1) begin
                if (output_mem[flat_index] !== dense_ref[flat_index]) begin
                    mismatch_count = mismatch_count + 1;
                    $error("output mismatch idx=%0d got=%0d expected=%0d", flat_index, output_mem[flat_index], dense_ref[flat_index]);
                end
            end
            ref_useful = useful_ref_count;
            ref_skipped = skipped_ref_count;
            if ((mismatch_count != 0) || (useful_mac_count !== ref_useful) || (skipped_mac_count !== ref_skipped)) begin
                $error("pe=%0d output mismatch=%0d useful=%0d/%0d skipped=%0d/%0d", pe_value, mismatch_count, useful_mac_count, ref_useful, skipped_mac_count, ref_skipped);
                $fatal(1, "sparse RTL validation failed");
            end
            $display("RESULT resource=%0d active_pes=%0d useful_mac_count=%0d skipped_mac_count=%0d dense_cycles=%0d sparse_cycles=%0d output_match=%0d mac_count_match=%0d",
                     pe_value, active_pe_count, useful_mac_count, skipped_mac_count, (dense_mac_count + active_pe_count - 1) / active_pe_count, cycle_count, (mismatch_count == 0), ((useful_mac_count == ref_useful) && (skipped_mac_count == ref_skipped)));
        end
    endtask

    sparse_conv_scheduler #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .INPUT_H(INPUT_H),
        .INPUT_W(INPUT_W),
        .INPUT_C(INPUT_C),
        .KERNEL_H(3),
        .KERNEL_W(3),
        .OUTPUT_C(OUTPUT_C),
        .PE_COUNT(PE_COUNT)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .active_pe_count(active_pe_count),
        .input_mem(input_mem),
        .weight_mem(weight_mem),
        .output_valid(output_valid),
        .useful_mac_count(useful_mac_count),
        .skipped_mac_count(skipped_mac_count),
        .cycle_count(cycle_count),
        .output_mem(output_mem)
    );

    initial begin
        $timeformat(-9, 0, "ns", 10);
        fail_count = 0;
        check_run(16);
        check_run(32);
        check_run(64);
        $display("Stage 11 sparse RTL validation: PASS");
        $finish;
    end
endmodule
