module test_speed;
    logic clk;
    int count;
    initial clk = 0;
    always #5 clk = ~clk;
    initial begin
        for (count = 0; count < 1000000; count++) begin
            @(posedge clk);
        end
        \(" DONE 1M CYCLES\);
