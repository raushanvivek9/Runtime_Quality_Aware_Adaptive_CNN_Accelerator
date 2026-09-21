`timescale 1ns/1ps

module tb_adaptive_compute;
    localparam integer DATA_WIDTH = 16;
    localparam integer ACC_WIDTH  = 32;
    localparam integer MATRIX_DIM = 8;
    localparam integer PE_COUNT   = 64;
    localparam integer CLK_PERIOD = 10;

    logic clk = 1'b0;
    logic rst = 1'b0;
    logic start = 1'b0;
    logic [1:0] resource_cfg = 2'b10;
    logic signed [DATA_WIDTH-1:0] matrix_a [0:PE_COUNT-1];
    logic signed [DATA_WIDTH-1:0] matrix_b [0:PE_COUNT-1];
    logic busy, done, result_valid;
    logic [31:0] cycle_count;
    logic signed [ACC_WIDTH-1:0] result_matrix [0:PE_COUNT-1];
    logic [6:0] active_pe_count;
    logic [PE_COUNT-1:0] pe_enable_debug, pe_valid_debug;
    logic signed [ACC_WIDTH-1:0] pe_accum_debug [0:PE_COUNT-1];
    logic [1:0] captured_resource_cfg;
    logic signed [ACC_WIDTH-1:0] golden_matrix [0:PE_COUNT-1];

    integer row_index;
    integer col_index;
    integer k_index;
    integer matrix_index;
    integer signed golden_sum;

    always #(CLK_PERIOD / 2) clk = ~clk;

    adaptive_compute_top #(
        .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH),
        .MATRIX_DIM(MATRIX_DIM), .PE_COUNT(PE_COUNT)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .resource_cfg(resource_cfg),
        .matrix_a(matrix_a), .matrix_b(matrix_b), .busy(busy), .done(done),
        .cycle_count(cycle_count), .result_valid(result_valid),
        .result_matrix(result_matrix), .active_pe_count(active_pe_count),
        .pe_enable_debug(pe_enable_debug), .pe_valid_debug(pe_valid_debug),
        .pe_accum_debug(pe_accum_debug),
        .captured_resource_cfg(captured_resource_cfg)
    );

    function automatic integer signed a_value(input integer row, input integer col);
        // Values 2..16: deterministic, signed, and chosen so every C element
        // is nonzero. This makes PE accumulator-update checks unambiguous.
        a_value = row + col + 2;
    endfunction

    function automatic integer signed b_value(input integer row, input integer col);
        // Values 1..15, where row is GEMM k and col is GEMM j.
        b_value = col - row + 8;
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

    task automatic reset_and_check;
        begin
            @(negedge clk);
            rst = 1'b1;
            start = 1'b0;
            resource_cfg = 2'b10;
            repeat (2) @(posedge clk);
            @(negedge clk);
            if (busy !== 1'b0 || done !== 1'b0 || result_valid !== 1'b0 || cycle_count !== 0)
                $fatal(1, "reset: control outputs were not cleared");
            for (matrix_index = 0; matrix_index < PE_COUNT; matrix_index = matrix_index + 1) begin
                if (result_matrix[matrix_index] !== 0)
                    $fatal(1, "reset: result[%0d] was not zero", matrix_index);
                if (pe_accum_debug[matrix_index] !== 0)
                    $fatal(1, "reset: PE accumulator[%0d] was not zero", matrix_index);
            end
            rst = 1'b0;
            $display("PASS reset behavior");
        end
    endtask

    task automatic verify_enable_mask(
        input integer expected_active,
        input [8*36-1:0] test_name
    );
        begin
            if (active_pe_count !== expected_active)
                $fatal(1, "%0s: active_pe_count got %0d expected %0d", test_name,
                       active_pe_count, expected_active);
            for (matrix_index = 0; matrix_index < PE_COUNT; matrix_index = matrix_index + 1) begin
                if (matrix_index < expected_active) begin
                    if (pe_enable_debug[matrix_index] !== 1'b1)
                        $fatal(1, "%0s: PE %0d should be enabled", test_name, matrix_index);
                end else begin
                    if (pe_enable_debug[matrix_index] !== 1'b0)
                        $fatal(1, "%0s: PE %0d should be disabled", test_name, matrix_index);
                end
            end
        end
    endtask

    task automatic verify_result_matrix(input [8*36-1:0] test_name);
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

    task automatic verify_disabled_accumulators(
        input integer expected_active,
        input [8*36-1:0] test_name
    );
        begin
            for (matrix_index = 0; matrix_index < PE_COUNT; matrix_index = matrix_index + 1) begin
                if (matrix_index < expected_active) begin
                    if (pe_accum_debug[matrix_index] === 0)
                        $fatal(1, "%0s: active PE %0d did not update", test_name, matrix_index);
                end else begin
                    if (pe_accum_debug[matrix_index] !== 0)
                        $fatal(1, "%0s: disabled PE %0d changed accumulator to %0d", test_name,
                               matrix_index, pe_accum_debug[matrix_index]);
                end
            end
        end
    endtask

    task automatic run_workload(
        input logic [1:0] initial_cfg,
        input integer expected_active,
        input integer expected_cycles,
        input logic [1:0] changed_cfg_while_busy,
        input logic check_disabled_state,
        input [8*36-1:0] test_name
    );
        begin
            @(negedge clk);
            resource_cfg = initial_cfg;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            if (busy !== 1'b1)
                $fatal(1, "%0s: busy did not assert after start", test_name);
            if (captured_resource_cfg !== initial_cfg)
                $fatal(1, "%0s: resource_cfg was not captured at start", test_name);
            verify_enable_mask(expected_active, test_name);

            // Change the input while busy. The captured configuration, enable
            // mask, and active count must stay on the initial workload setting.
            resource_cfg = changed_cfg_while_busy;
            repeat (3) @(negedge clk);
            if (busy !== 1'b1)
                $fatal(1, "%0s: computation ended too early", test_name);
            if (captured_resource_cfg !== initial_cfg)
                $fatal(1, "%0s: captured configuration changed while busy", test_name);
            verify_enable_mask(expected_active, test_name);
            for (matrix_index = 0; matrix_index < PE_COUNT; matrix_index = matrix_index + 1) begin
                if (matrix_index < expected_active) begin
                    if (pe_valid_debug[matrix_index] !== 1'b1)
                        $fatal(1, "%0s: active PE %0d was not receiving MAC work", test_name,
                               matrix_index);
                end else if (pe_valid_debug[matrix_index] !== 1'b0) begin
                    $fatal(1, "%0s: disabled PE %0d received MAC work", test_name, matrix_index);
                end
            end

            @(posedge done);
            #1;
            if (cycle_count !== expected_cycles)
                $fatal(1, "%0s: cycle_count got %0d expected %0d", test_name,
                       cycle_count, expected_cycles);
            verify_result_matrix(test_name);
            if (check_disabled_state)
                verify_disabled_accumulators(expected_active, test_name);

            $display("PASS %-36s cfg=%b active=%0d cycles=%0d", test_name,
                     initial_cfg, active_pe_count, cycle_count);
        end
    endtask

    initial begin
        $dumpfile("stage8b_wave.vcd");
        $dumpvars(0, tb_adaptive_compute);
        load_matrices_and_golden();

        // First pass: each mode starts from reset, checks result/cycles, and
        // proves disabled PE accumulators never update.
        reset_and_check();
        run_workload(2'b00, 16, 32, 2'b10, 1'b1, "test1_16pe_result_and_gating");

        reset_and_check();
        load_matrices_and_golden();
        run_workload(2'b01, 32, 16, 2'b00, 1'b1, "test2_32pe_result_and_gating");

        reset_and_check();
        load_matrices_and_golden();
        run_workload(2'b10, 64, 8, 2'b01, 1'b1, "test3_64pe_result_and_gating");

        // Second pass: layer/workload-boundary reconfiguration without reset.
        // Each new start captures its new configuration; input changes during
        // busy have already been checked inside run_workload.
        reset_and_check();
        load_matrices_and_golden();
        run_workload(2'b00, 16, 32, 2'b10, 1'b0, "test6_boundary_reconfig_16");
        run_workload(2'b01, 32, 16, 2'b00, 1'b0, "test6_boundary_reconfig_32");
        run_workload(2'b10, 64, 8, 2'b01, 1'b0, "test6_boundary_reconfig_64");

        $display("Stage 8B RTL self-check PASS: 16PE=32 cycles, 32PE=16 cycles, 64PE=8 cycles");
        $finish;
    end
endmodule
