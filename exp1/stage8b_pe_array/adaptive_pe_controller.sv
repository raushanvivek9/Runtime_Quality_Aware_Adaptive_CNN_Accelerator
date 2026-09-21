`timescale 1ns/1ps

// Stateless resource decoder. The top level supplies a configuration captured
// at workload start, so these outputs remain stable while the array is busy.
module adaptive_pe_controller #(
    parameter integer PE_COUNT = 64
) (
    input  logic [1:0]              resource_cfg,
    output logic [6:0]              active_pe_count,
    output logic [PE_COUNT-1:0]     pe_enable
);
    integer pe_index;

    always_comb begin
        case (resource_cfg)
            2'b00: active_pe_count = 7'd16;
            2'b01: active_pe_count = 7'd32;
            2'b10: active_pe_count = 7'd64;
            default: active_pe_count = 7'd64;  // conservative unsupported-code fallback
        endcase

        pe_enable = '0;
        for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
            if (pe_index < active_pe_count)
                pe_enable[pe_index] = 1'b1;
        end
    end
endmodule
