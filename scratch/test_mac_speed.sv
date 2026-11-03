module test_mac_speed;
    reg clk;
    reg rst_n;
    reg enable;
    reg accum_clear;
    reg signed [15:0] act_data;
    reg signed [15:0] wt_data;
    wire signed [39:0] accum_out;
    wire sat;
    wire skip;

    mac_unit_40b u_mac (
        .clk(clk), .rst_n(rst_n), .enable(enable), .accum_clear(accum_clear),
        .sat_clear(1'b0), .act_data(act_data), .act_mask(1'b1), .weight_data(wt_data),
        .accum_out(accum_out), .sticky_saturation(sat), .cycle_skipped(skip)
    );

    always #5 clk = ~clk;

    integer i;
    initial begin
        clk = 0; rst_n = 0; enable = 0; accum_clear = 0;
        act_data = 16'd5; wt_data = 16'd7;
        #20 rst_n = 1;
        enable = 1;
        $display("Starting 100k cycles...");
        for (i = 0; i < 100000; i = i + 1) begin
            @(posedge clk);
        end
        $display("Finished 100k cycles!");
        $finish;
    end
endmodule

