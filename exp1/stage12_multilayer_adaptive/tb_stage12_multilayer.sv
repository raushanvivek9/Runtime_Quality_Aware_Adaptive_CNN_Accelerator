`timescale 1ns/1ps

module tb_stage12_multilayer;
    localparam integer DATA_WIDTH   = 16;
    localparam integer WEIGHT_WIDTH = 16;
    localparam integer ACC_WIDTH    = 48;
    localparam integer INPUT_H      = 8;
    localparam integer INPUT_W      = 8;
    localparam integer CLK_PERIOD   = 10;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic [1:0] case_id;
    logic [1:0] layer_id;
    logic [6:0] active_pe_count;

    logic signed [DATA_WIDTH-1:0] layer1_input [0:3*8*8-1];
    logic signed [DATA_WIDTH-1:0] layer2_input [0:16*8*8-1];
    logic signed [DATA_WIDTH-1:0] layer3_input [0:32*8*8-1];
    logic signed [WEIGHT_WIDTH-1:0] layer1_weight [0:16*3*3*3-1];
    logic signed [WEIGHT_WIDTH-1:0] layer2_weight [0:32*16*3*3-1];
    logic signed [WEIGHT_WIDTH-1:0] layer3_weight [0:16*32*3*3-1];

    logic output_valid;
    logic [31:0] total_activation_elements;
    logic [31:0] zero_activation_elements;
    logic [31:0] useful_mac_count;
    logic [31:0] skipped_mac_count;
    logic [31:0] cycle_count;
    logic [15:0] sparsity_q;
    logic signed [ACC_WIDTH-1:0] output_mem [0:32*8*8-1];

    logic signed [ACC_WIDTH-1:0] layer1_ref [0:16*8*8-1];
    logic signed [ACC_WIDTH-1:0] layer2_ref [0:32*8*8-1];
    logic signed [ACC_WIDTH-1:0] layer3_ref [0:16*8*8-1];

    integer case_idx, layer_idx;
    integer mismatch_count, zero_count, useful_ref, skipped_ref, selected_pe;
    real sparsity_percent;

    always #(CLK_PERIOD / 2) clk = ~clk;

    function automatic integer signed activation_value(input integer case_id_i, input integer layer_index, input integer ic, input integer row, input integer col);
        integer v;
        integer seed;
        seed = (case_id_i == 0) ? 1 : (case_id_i == 1) ? 3 : 7;
        v = ((ic + 3 * row + 5 * col + seed + 7 * (layer_index + 1)) % 13) - 6;
        if (case_id_i == 0) begin
            if ((ic + 2 * row + 3 * col + layer_index + seed) % 19 == 0) v = 0;
        end else if (case_id_i == 1) begin
            if ((ic + 3 * row + 5 * col + layer_index + seed) % 7 == 0) v = 0;
        end else begin
            if ((ic + 2 * row + 4 * col + layer_index + seed) % 3 == 0) v = 0;
        end
        activation_value = v;
    endfunction

    function automatic integer signed weight_value(input integer layer_index, input integer oc, input integer ic, input integer ky, input integer kx);
        integer w;
        w = ((oc + ic + ky + kx + layer_index + 1) % 7) - 3;
        weight_value = w;
    endfunction

    function automatic integer resource_for_sparsity(input real s);
        if (s < 20.0) resource_for_sparsity = 64;
        else if (s < 40.0) resource_for_sparsity = 32;
        else resource_for_sparsity = 16;
    endfunction

    task automatic fill_case_layer(input integer case_id_i, input integer layer_index, input integer layer_sel);
        integer ic, row, col, oc, ky, kx, idx;
        begin
            if (layer_sel == 0) begin
                for (ic = 0; ic < 3; ic = ic + 1) begin
                    for (row = 0; row < 8; row = row + 1) begin
                        for (col = 0; col < 8; col = col + 1) begin
                            layer1_input[ic * 8 * 8 + row * 8 + col] = activation_value(case_id_i, layer_index, ic, row, col);
                        end
                    end
                end
                for (oc = 0; oc < 16; oc = oc + 1) begin
                    for (ic = 0; ic < 3; ic = ic + 1) begin
                        for (ky = 0; ky < 3; ky = ky + 1) begin
                            for (kx = 0; kx < 3; kx = kx + 1) begin
                                layer1_weight[oc * 3 * 3 * 3 + ic * 3 * 3 + ky * 3 + kx] = weight_value(layer_index, oc, ic, ky, kx);
                            end
                        end
                    end
                end
            end else if (layer_sel == 1) begin
                for (ic = 0; ic < 16; ic = ic + 1) begin
                    for (row = 0; row < 8; row = row + 1) begin
                        for (col = 0; col < 8; col = col + 1) begin
                            layer2_input[ic * 8 * 8 + row * 8 + col] = layer1_ref[ic * 8 * 8 + row * 8 + col];
                        end
                    end
                end
                for (oc = 0; oc < 32; oc = oc + 1) begin
                    for (ic = 0; ic < 16; ic = ic + 1) begin
                        for (ky = 0; ky < 3; ky = ky + 1) begin
                            for (kx = 0; kx < 3; kx = kx + 1) begin
                                layer2_weight[oc * 16 * 3 * 3 + ic * 3 * 3 + ky * 3 + kx] = weight_value(layer_index, oc, ic, ky, kx);
                            end
                        end
                    end
                end
            end else begin
                for (ic = 0; ic < 32; ic = ic + 1) begin
                    for (row = 0; row < 8; row = row + 1) begin
                        for (col = 0; col < 8; col = col + 1) begin
                            layer3_input[ic * 8 * 8 + row * 8 + col] = layer2_ref[ic * 8 * 8 + row * 8 + col];
                        end
                    end
                end
                for (oc = 0; oc < 16; oc = oc + 1) begin
                    for (ic = 0; ic < 32; ic = ic + 1) begin
                        for (ky = 0; ky < 3; ky = ky + 1) begin
                            for (kx = 0; kx < 3; kx = kx + 1) begin
                                layer3_weight[oc * 32 * 3 * 3 + ic * 3 * 3 + ky * 3 + kx] = weight_value(layer_index, oc, ic, ky, kx);
                            end
                        end
                    end
                end
            end
        end
    endtask

    task automatic compute_reference_by_layer(input integer case_id_i, input integer layer_index, input integer data_c, input integer out_c, output integer useful_total, output integer skipped_total, output integer zero_total);
        integer ic, oc, row, col, ky, kx, yy, xx;
        integer idx;
        integer in_index;
        begin
            useful_total = 0;
            skipped_total = 0;
            zero_total = 0;
            if (layer_index == 0) begin
                for (idx = 0; idx < 16 * 8 * 8; idx = idx + 1) begin
                    layer1_ref[idx] = '0;
                end
                for (oc = 0; oc < out_c; oc = oc + 1) begin
                    for (row = 0; row < 8; row = row + 1) begin
                        for (col = 0; col < 8; col = col + 1) begin
                            layer1_ref[oc * 8 * 8 + row * 8 + col] = '0;
                            for (ic = 0; ic < data_c; ic = ic + 1) begin
                                for (ky = 0; ky < 3; ky = ky + 1) begin
                                    for (kx = 0; kx < 3; kx = kx + 1) begin
                                        yy = row + ky - 1;
                                        xx = col + kx - 1;
                                        if ((yy >= 0) && (yy < 8) && (xx >= 0) && (xx < 8)) begin
                                            in_index = ic * 8 * 8 + yy * 8 + xx;
                                            if (layer1_input[in_index] == 0) begin
                                                skipped_total = skipped_total + 1;
                                                zero_total = zero_total + 1;
                                            end else begin
                                                useful_total = useful_total + 1;
                                            end
                                            layer1_ref[oc * 8 * 8 + row * 8 + col] = layer1_ref[oc * 8 * 8 + row * 8 + col] +
                                                $signed(layer1_input[in_index]) *
                                                $signed(weight_value(layer_index, oc, ic, ky, kx));
                                        end else begin
                                            skipped_total = skipped_total + 1;
                                            zero_total = zero_total + 1;
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end else if (layer_index == 1) begin
                for (idx = 0; idx < 32 * 8 * 8; idx = idx + 1) begin
                    layer2_ref[idx] = '0;
                end
                for (oc = 0; oc < out_c; oc = oc + 1) begin
                    for (row = 0; row < 8; row = row + 1) begin
                        for (col = 0; col < 8; col = col + 1) begin
                            layer2_ref[oc * 8 * 8 + row * 8 + col] = '0;
                            for (ic = 0; ic < data_c; ic = ic + 1) begin
                                for (ky = 0; ky < 3; ky = ky + 1) begin
                                    for (kx = 0; kx < 3; kx = kx + 1) begin
                                        yy = row + ky - 1;
                                        xx = col + kx - 1;
                                        if ((yy >= 0) && (yy < 8) && (xx >= 0) && (xx < 8)) begin
                                            in_index = ic * 8 * 8 + yy * 8 + xx;
                                            if (layer2_input[in_index] == 0) begin
                                                skipped_total = skipped_total + 1;
                                                zero_total = zero_total + 1;
                                            end else begin
                                                useful_total = useful_total + 1;
                                            end
                                            layer2_ref[oc * 8 * 8 + row * 8 + col] = layer2_ref[oc * 8 * 8 + row * 8 + col] +
                                                $signed(layer2_input[in_index]) *
                                                $signed(weight_value(layer_index, oc, ic, ky, kx));
                                        end else begin
                                            skipped_total = skipped_total + 1;
                                            zero_total = zero_total + 1;
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end else begin
                for (idx = 0; idx < 16 * 8 * 8; idx = idx + 1) begin
                    layer3_ref[idx] = '0;
                end
                for (oc = 0; oc < out_c; oc = oc + 1) begin
                    for (row = 0; row < 8; row = row + 1) begin
                        for (col = 0; col < 8; col = col + 1) begin
                            layer3_ref[oc * 8 * 8 + row * 8 + col] = '0;
                            for (ic = 0; ic < data_c; ic = ic + 1) begin
                                for (ky = 0; ky < 3; ky = ky + 1) begin
                                    for (kx = 0; kx < 3; kx = kx + 1) begin
                                        yy = row + ky - 1;
                                        xx = col + kx - 1;
                                        if ((yy >= 0) && (yy < 8) && (xx >= 0) && (xx < 8)) begin
                                            in_index = ic * 8 * 8 + yy * 8 + xx;
                                            if (layer3_input[in_index] == 0) begin
                                                skipped_total = skipped_total + 1;
                                                zero_total = zero_total + 1;
                                            end else begin
                                                useful_total = useful_total + 1;
                                            end
                                            layer3_ref[oc * 8 * 8 + row * 8 + col] = layer3_ref[oc * 8 * 8 + row * 8 + col] +
                                                $signed(layer3_input[in_index]) *
                                                $signed(weight_value(layer_index, oc, ic, ky, kx));
                                        end else begin
                                            skipped_total = skipped_total + 1;
                                            zero_total = zero_total + 1;
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    endtask

    task automatic run_layer_case(input integer case_id_i, input integer layer_index, input integer selected_pe, input integer data_c, input integer out_c);
        integer i;
        integer useful_total_ref;
        integer skipped_total_ref;
        integer zero_total_ref;
        real layer_sparsity;
        begin
            active_pe_count = selected_pe;
            case_id = case_id_i;
            layer_id = layer_index;
            fill_case_layer(case_id_i, layer_index, layer_index);

            if (layer_index == 0) begin
                compute_reference_by_layer(case_id_i, layer_index, 3, 16, useful_total_ref, skipped_total_ref, zero_total_ref);
            end else if (layer_index == 1) begin
                compute_reference_by_layer(case_id_i, layer_index, 16, 32, useful_total_ref, skipped_total_ref, zero_total_ref);
            end else begin
                compute_reference_by_layer(case_id_i, layer_index, 32, 16, useful_total_ref, skipped_total_ref, zero_total_ref);
            end

            layer_sparsity = real'(zero_total_ref) / real'(data_c * 8 * 8) * 100.0;
            rst = 1'b1;
            repeat (2) @(posedge clk);
            rst = 1'b0;
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            wait (output_valid);

            mismatch_count = 0;
            if (layer_index == 0) begin
                for (i = 0; i < 16 * 8 * 8; i = i + 1) begin
                    if (output_mem[i] !== layer1_ref[i]) mismatch_count = mismatch_count + 1;
                end
            end else if (layer_index == 1) begin
                for (i = 0; i < 32 * 8 * 8; i = i + 1) begin
                    if (output_mem[i] !== layer2_ref[i]) mismatch_count = mismatch_count + 1;
                end
            end else begin
                for (i = 0; i < 16 * 8 * 8; i = i + 1) begin
                    if (output_mem[i] !== layer3_ref[i]) mismatch_count = mismatch_count + 1;
                end
            end

            if ((mismatch_count != 0) || (useful_mac_count != useful_total_ref) || (skipped_mac_count != skipped_total_ref)) begin
                $error("case=%0d layer=%0d mismatch_count=%0d useful=%0d/%0d skipped=%0d/%0d", case_id_i, layer_index, mismatch_count, useful_mac_count, useful_total_ref, skipped_mac_count, skipped_total_ref);
                $fatal(1, "Stage 12 layer mismatch");
            end
            $display("RESULT case=%s layer=layer%0d sparsity=%0.4f selected_pe=%0d useful_mac_count=%0d skipped_mac_count=%0d analytical_cycles=%0d rtl_cycles=%0d output_match=%0d mac_count_match=%0d",
                     (case_id_i == 0) ? "A" : (case_id_i == 1) ? "B" : "C",
                     layer_index + 1,
                     layer_sparsity,
                     active_pe_count,
                     useful_mac_count,
                     skipped_mac_count,
                     (useful_total_ref + active_pe_count - 1) / active_pe_count,
                     cycle_count,
                     (mismatch_count == 0),
                     ((useful_mac_count == useful_total_ref) && (skipped_mac_count == skipped_total_ref)));
        end
    endtask

    stage12_multilayer_top top (
        .clk(clk),
        .rst(rst),
        .start(start),
        .case_id(case_id),
        .layer_id(layer_id),
        .active_pe_count(active_pe_count),
        .layer1_input(layer1_input),
        .layer2_input(layer2_input),
        .layer3_input(layer3_input),
        .layer1_weight(layer1_weight),
        .layer2_weight(layer2_weight),
        .layer3_weight(layer3_weight),
        .output_valid(output_valid),
        .total_activation_elements(total_activation_elements),
        .zero_activation_elements(zero_activation_elements),
        .useful_mac_count(useful_mac_count),
        .skipped_mac_count(skipped_mac_count),
        .cycle_count(cycle_count),
        .sparsity_q(sparsity_q),
        .output_mem(output_mem)
    );

    initial begin
        $timeformat(-9, 0, "ns", 10);
        for (case_idx = 0; case_idx < 3; case_idx = case_idx + 1) begin
            for (layer_idx = 0; layer_idx < 3; layer_idx = layer_idx + 1) begin
                if (case_idx == 0) begin
                    if (layer_idx == 0) selected_pe = 64;
                    else selected_pe = 64;
                end else if (case_idx == 1) begin
                    if (layer_idx == 0) selected_pe = 32;
                    else selected_pe = 64;
                end else begin
                    if (layer_idx == 0) selected_pe = 32;
                    else selected_pe = 64;
                end
                run_layer_case(case_idx, layer_idx, selected_pe, 3, 16);
            end
        end
        $display("Stage 12 RTL validation: PASS");
        $finish;
    end
endmodule
