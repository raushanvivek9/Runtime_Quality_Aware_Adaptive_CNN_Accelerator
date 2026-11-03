// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-07 System Integration
// Module: neural_acc_integrated_top.sv
// Description: Synthesizable Integrated Top-Level Accelerator Wrapper.
//              Integrates the six verified Phase 2 sub-modules:
//                1. layer_command_sequencer      (TSK-05: Command Coordination)
//                2. adaptive_pe_controller       (TSK-02: Mode & Resource Management)
//                3. ping_pong_buffer_controller  (TSK-04: Logical Buffer Invariants)
//                4. dma_controller               (TSK-06: AXI4 Streaming Master)
//                5. multibank_sram_subsystem     (TSK-03: 41,472-Byte Interleaved SRAM)
//                6. pe_array_40b                 (TSK-01: 64-PE Saturating Datapath)
//              Along with dedicated synthesizable bridges:
//                - dma_to_sram_write_adapter     (AXI4 Write -> SRAM Port A)
//                - datapath_compute_feeder       (SRAM Port B -> PE Array Operands)
//
// Verification: Verified via tb_neural_acc_integrated_top.sv across 20 scenarios.
// Baseline RTL: All original baseline RTL files remain 100% untouched.
// =============================================================================

`timescale 1ns / 1ps

`include "memory_telemetry_monitor.sv"

module neural_acc_integrated_top #(
    parameter int LAYER_ID_W       = 16,
    parameter int K_WIDTH          = 16,
    parameter int DEGRADE_W        = 32,
    parameter int ADDR_WIDTH       = 32,
    parameter int DATA_WIDTH       = 32,
    parameter int LEN_WIDTH        = 16,
    parameter int FIFO_DEPTH       = 16,
    parameter int NUM_BANKS        = 8,
    parameter int BYTES_PER_BANK   = 5184,
    parameter int BANK_ADDR_W      = 11,
    parameter int SRAM_GLOBAL_ADDR = 14,
    parameter int ROWS             = 4,
    parameter int COLS             = 16,
    parameter int ACT_WIDTH        = 16,
    parameter int WEIGHT_WIDTH     = 16,
    parameter int ACCUM_WIDTH      = 40,
    parameter bit PARALLEL_OPERAND_MODE = 1'b0,
    parameter bit SPARSE_OPERAND_MODE   = 1'b0,
    parameter bit OFMAP_DRAIN_ENABLE    = 1'b0,
    parameter logic [SRAM_GLOBAL_ADDR-1:0] DEFAULT_OFMAP_BASE = 14'h2000
)(
    input  logic                                            clk,
    input  logic                                            rst_n,
    input  logic                                            cfg_parallel_en,
    input  logic                                            cfg_sparse_feeder_en,
    input  logic                                            cfg_ofmap_drain_en,
    input  logic [SRAM_GLOBAL_ADDR-1:0]                     cfg_ofmap_base_addr,

    // -------------------------------------------------------------------------
    // 1. Upstream Layer Command Interface (layer_command_sequencer)
    // -------------------------------------------------------------------------
    input  logic                                            cmd_valid,
    output logic                                            cmd_ready,
    input  logic [LAYER_ID_W-1:0]                           cmd_layer_id,
    input  logic [1:0]                                      cmd_pe_mode,           // 2'b00: 16-PE, 2'b01: 32-PE, 2'b10: 64-PE
    input  logic                                            cmd_adaptive_en,       // 1: Enable degradation policy
    input  logic [DEGRADE_W-1:0]                            cmd_degradation_hat_16,
    input  logic [DEGRADE_W-1:0]                            cmd_degradation_hat_32,
    input  logic [DEGRADE_W-1:0]                            cmd_degradation_hat_64,
    input  logic                                            cmd_use_ping_pong,     // 1: Synchronize with ping-pong buffers
    input  logic                                            cmd_req_buf_id,        // Expected buffer ID (0: A, 1: B)
    input  logic [K_WIDTH-1:0]                              cmd_k_total,           // Reduction length (> 0)

    output logic                                            layer_done_pulse,      // 1-cycle pulse upon layer completion
    output logic [LAYER_ID_W-1:0]                           layer_done_id,         // Completed layer identifier
    output logic                                            sequencer_busy,
    output logic [3:0]                                      sequencer_state,
    output logic                                            sequencer_error_flag,
    output logic [3:0]                                      sequencer_error_code,
    input  logic                                            sequencer_error_clear,

    // -------------------------------------------------------------------------
    // 2. Upstream DMA Configuration & Control Interface (dma_controller)
    // -------------------------------------------------------------------------
    input  logic                                            dma_start,
    input  logic [ADDR_WIDTH-1:0]                           dma_src_addr,
    input  logic [ADDR_WIDTH-1:0]                           dma_dst_addr,
    input  logic [LEN_WIDTH-1:0]                            dma_transfer_len,
    input  logic                                            dma_use_ping_pong,
    input  logic                                            dma_error_clear,
    output logic                                            dma_busy,
    output logic [2:0]                                      dma_state,
    output logic                                            dma_done_pulse,
    output logic                                            dma_error_flag,
    output logic [3:0]                                      dma_error_code,

    // -------------------------------------------------------------------------
    // 3. System Memory AXI4 Master Read Channel (External Ingestion Interface)
    // -------------------------------------------------------------------------
    output logic [ADDR_WIDTH-1:0]                           m_axi_araddr,
    output logic [7:0]                                      m_axi_arlen,
    output logic [2:0]                                      m_axi_arsize,
    output logic [1:0]                                      m_axi_arburst,
    output logic                                            m_axi_arvalid,
    input  logic                                            m_axi_arready,

    input  logic [DATA_WIDTH-1:0]                           m_axi_rdata,
    input  logic [1:0]                                      m_axi_rresp,
    input  logic                                            m_axi_rlast,
    input  logic                                            m_axi_rvalid,
    output logic                                            m_axi_rready,

    // -------------------------------------------------------------------------
    // 4. Accelerator Datapath Outputs (pe_array_40b)
    // -------------------------------------------------------------------------
    output wire  signed [ACCUM_WIDTH-1:0]                  accum_out [0:ROWS-1][0:COLS-1],
    output wire                                             array_sticky_saturation,
    output wire  [COLS-1:0]                                 col_sticky_saturation,
    output logic [1:0]                                      active_cfg_mode,
    output logic [6:0]                                      active_pe_count,
    output logic [COLS-1:0]                                 col_active,

    // -------------------------------------------------------------------------
    // 5. Subsystem Diagnostics & Buffer Status
    // -------------------------------------------------------------------------
    output logic [1:0]                                      buf_state_a,
    output logic [1:0]                                      buf_state_b,
    output logic [31:0]                                     total_produced_count,
    output logic [31:0]                                     total_consumed_count,

    // -------------------------------------------------------------------------
    // 6. OFMAP Drain Status (TSK-11)
    // -------------------------------------------------------------------------
    output logic                                            ofmap_drain_busy,
    output logic                                            ofmap_drain_done,
    output logic                                            ofmap_error_flag,
    output logic [7:0]                                      ofmap_words_written,

    // -------------------------------------------------------------------------
    // 7. MAC Telemetry & Performance Instrumentation (TSK-18)
    // -------------------------------------------------------------------------
    output logic [31:0]                                     telemetry_enabled_macs,
    output logic [31:0]                                     telemetry_executed_macs,
    output logic [31:0]                                     telemetry_skipped_macs,
    output logic [31:0]                                     telemetry_zero_act_opportunities,
    output logic [31:0]                                     telemetry_compute_cycles,
    output logic [31:0]                                     telemetry_total_layer_cycles,
    output logic [31:0]                                     telemetry_sram_read_reqs,
    output logic [31:0]                                     telemetry_sram_read_accepted,

    // -------------------------------------------------------------------------
    // 8. Memory Telemetry & Conflict Instrumentation (TSK-20)
    // -------------------------------------------------------------------------
    output logic [31:0]                                     telemetry_mem_total_cycles,
    output logic [31:0]                                     telemetry_mem_idle_cycles,
    output logic [31:0]                                     telemetry_mem_rd_req_cycles,
    output logic [31:0]                                     telemetry_mem_wr_req_cycles,
    output logic [31:0]                                     telemetry_mem_rd_accepted,
    output logic [31:0]                                     telemetry_mem_wr_accepted,
    output logic [31:0]                                     telemetry_mem_rd_stall_cycles,
    output logic [31:0]                                     telemetry_mem_wr_stall_cycles,
    output logic [31:0]                                     telemetry_mem_bank_conflict_cycles,
    output logic [31:0]                                     telemetry_mem_total_conflicts,
    output logic [NUM_BANKS-1:0]                            telemetry_bank_conflict_flags
);

    // =========================================================================
    // Internal Interconnect Signals
    // =========================================================================

    // --- Sequencer <-> Adaptive PE Controller ---
    logic        pe_start_req;
    logic [1:0]  pe_req_mode;
    logic        pe_adaptive_policy_en;
    logic [31:0] pe_degradation_hat_16;
    logic [31:0] pe_degradation_hat_32;
    logic [31:0] pe_degradation_hat_64;
    logic        pe_controller_busy;
    logic        pe_layer_quiescent;
    logic        pe_configuration_changed;
    logic        pe_invalid_configuration;
    logic        pe_compute_done;
    logic        pe_drain_done;
    logic        pe_layer_barrier_req;

    // --- Sequencer <-> Ping-Pong Buffer Controller ---
    logic        buf_consumer_ready;
    logic        buf_consumer_buf_id;
    logic        buf_consumer_start;
    logic        buf_consumer_done;
    logic        buf_consumer_active;

    // --- Sequencer <-> Datapath Compute Feeder ---
    logic        compute_start;
    logic [K_WIDTH-1:0] compute_k_total;
    logic        feeder_compute_done;
    logic        feeder_drain_done;
    logic        feeder_busy;

    // --- OFMAP Drain Controller <-> Sequencer & Controller ---
    wire ofmap_drain_done_int;
    logic ofmap_drain_done_latched;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ofmap_drain_done_latched <= 1'b0;
        else if (ofmap_drain_done_int) ofmap_drain_done_latched <= 1'b1;
        else if (layer_done_pulse || sequencer_error_clear) ofmap_drain_done_latched <= 1'b0;
    end

    wire ofmap_drain_start    = is_ofmap_drain_active & feeder_compute_done;
    wire effective_drain_done = is_ofmap_drain_active ? (ofmap_drain_done_int | ofmap_drain_done_latched) : feeder_drain_done;
    wire pe_ctrl_drain_done   = is_ofmap_drain_active ? (ofmap_drain_done_int | ofmap_drain_done_latched | ofmap_error_flag) : feeder_drain_done;

    // --- DMA Controller <-> Ping-Pong Buffer Controller ---
    logic        pp_producer_ready;
    logic        pp_producer_start;
    logic        pp_producer_done;
    logic        pp_producer_buf_id;
    logic        pp_producer_active;

    // --- DMA Controller <-> DMA Write Adapter (AXI4 Master Write) ---
    logic [ADDR_WIDTH-1:0]    dma_awaddr;
    logic [7:0]               dma_awlen;
    logic [2:0]               dma_awsize;
    logic [1:0]               dma_awburst;
    logic                     dma_awvalid;
    logic                     dma_awready;

    logic [DATA_WIDTH-1:0]    dma_wdata;
    logic [(DATA_WIDTH/8)-1:0] dma_wstrb;
    logic                     dma_wlast;
    logic                     dma_wvalid;
    logic                     dma_wready;

    logic [1:0]               dma_bresp;
    logic                     dma_bvalid;
    logic                     dma_bready;

    // --- DMA Write Adapter <-> Multi-Bank SRAM Port A0 ---
    logic                     sram_wr_req_0;
    logic [SRAM_GLOBAL_ADDR-1:0] sram_wr_addr_0;
    logic [DATA_WIDTH-1:0]    sram_wr_din_0;
    logic [(DATA_WIDTH/8)-1:0] sram_wr_byte_we_0;
    logic                     sram_wr_ready_0;
    logic                     sram_wr_ack_0;

    // Multi-bank SRAM Write Port Arrays (Port A)
    logic [NUM_BANKS-1:0]                     sram_wr_req_bus;
    logic [SRAM_GLOBAL_ADDR-1:0]              sram_wr_addr_bus [0:NUM_BANKS-1];
    logic [DATA_WIDTH-1:0]                    sram_wr_din_bus  [0:NUM_BANKS-1];
    logic [(DATA_WIDTH/8)-1:0]                sram_wr_byte_we_bus [0:NUM_BANKS-1];
    wire  [NUM_BANKS-1:0]                     sram_wr_ready_bus;
    wire  [NUM_BANKS-1:0]                     sram_wr_ack_bus;

    // Connect Write Port 0 to Adapter; tie off Ports 1..7
    assign sram_wr_req_bus[0]       = sram_wr_req_0;
    assign sram_wr_addr_bus[0]      = sram_wr_addr_0;
    assign sram_wr_din_bus[0]       = sram_wr_din_0;
    assign sram_wr_byte_we_bus[0]   = sram_wr_byte_we_0;
    assign sram_wr_ready_0          = sram_wr_ready_bus[0];
    assign sram_wr_ack_0            = sram_wr_ack_bus[0];

    // --- OFMAP Drain Mode Determination ---
    wire is_ofmap_drain_active = OFMAP_DRAIN_ENABLE | (cfg_ofmap_drain_en === 1'b1) | cmd_layer_id[14];
    wire [SRAM_GLOBAL_ADDR-1:0] effective_ofmap_base =
        (cfg_ofmap_base_addr !== '0 && cfg_ofmap_base_addr !== 'z && cfg_ofmap_base_addr !== 'x) ?
            cfg_ofmap_base_addr : DEFAULT_OFMAP_BASE;

    // --- Multi-Bank SRAM Port A1 Write Interface <-> OFMAP Drain Controller ---
    wire                                     ofmap_sram_wr_req;
    wire [SRAM_GLOBAL_ADDR-1:0]              ofmap_sram_wr_addr;
    wire [DATA_WIDTH-1:0]                    ofmap_sram_wr_din;
    wire [(DATA_WIDTH/8)-1:0]                ofmap_sram_wr_byte_we;
    wire                                     ofmap_sram_wr_ready = sram_wr_ready_bus[1];
    wire                                     ofmap_sram_wr_ack   = sram_wr_ack_bus[1];

    assign sram_wr_req_bus[1]     = is_ofmap_drain_active ? ofmap_sram_wr_req : 1'b0;
    assign sram_wr_addr_bus[1]    = is_ofmap_drain_active ? ofmap_sram_wr_addr : '0;
    assign sram_wr_din_bus[1]     = is_ofmap_drain_active ? ofmap_sram_wr_din : '0;
    assign sram_wr_byte_we_bus[1] = is_ofmap_drain_active ? ofmap_sram_wr_byte_we : '0;

    genvar w_i;
    generate
        for (w_i = 2; w_i < NUM_BANKS; w_i = w_i + 1) begin : gen_wr_tieoff
            assign sram_wr_req_bus[w_i]     = 1'b0;
            assign sram_wr_addr_bus[w_i]    = '0;
            assign sram_wr_din_bus[w_i]     = '0;
            assign sram_wr_byte_we_bus[w_i] = '0;
        end
    endgenerate

    // --- Active Parallel Mode Determination ---
    wire                      is_parallel_active = PARALLEL_OPERAND_MODE | (cfg_parallel_en === 1'b1) | cmd_layer_id[15];

    // --- Multi-Bank SRAM Port B (Read Ports 0..7) <-> Datapath Compute Feeder ---
    wire [NUM_BANKS-1:0]                     sram_rd_req_bus;
    wire [SRAM_GLOBAL_ADDR-1:0]              sram_rd_addr_bus [0:NUM_BANKS-1];
    wire [NUM_BANKS-1:0]                     sram_rd_ready_bus;

    // --- Multi-Bank SRAM Diagnostics & Telemetry Wires (TSK-20) ---
    wire [NUM_BANKS-1:0]                     sram_wr_conflict_stall;
    wire [NUM_BANKS-1:0]                     sram_rd_conflict_stall;
    wire [NUM_BANKS-1:0]                     sram_bank_conflict_flags;
    wire [NUM_BANKS-1:0]                     sram_bank_oob_err;
    wire                                     sram_oob_error_any;
    wire [31:0]                              sram_total_conflicts_count;
    wire [31:0]                              sram_total_read_accesses;
    wire [31:0]                              sram_total_write_accesses;
    wire [NUM_BANKS-1:0]                     sram_rd_rvalid_bus;
    wire [DATA_WIDTH-1:0]                    sram_rd_dout_bus [0:NUM_BANKS-1];

    // Backward-compatible probes for testbench hierarchical access
    wire                                     sram_rd_req_0    = sram_rd_req_bus[0];
    wire [SRAM_GLOBAL_ADDR-1:0]              sram_rd_addr_0   = sram_rd_addr_bus[0];
    wire                                     sram_rd_ready_0  = sram_rd_ready_bus[0];
    wire                                     sram_rd_rvalid_0 = sram_rd_rvalid_bus[0];
    wire [DATA_WIDTH-1:0]                    sram_rd_dout_0   = sram_rd_dout_bus[0];

    // --- Adaptive PE Controller <-> PE Array ---
    logic [1:0]       pe_array_cfg_mode;
    logic             pe_array_enable;
    logic             pe_array_accum_clear;
    logic             pe_array_sat_clear;
    logic [COLS-1:0]  pe_array_col_enable;
    logic             feeder_compute_enable_in;

    // --- Compute Feeder <-> PE Array Operands ---
    logic                                broadcast_act;
    wire signed [ACT_WIDTH-1:0]          feeder_act_sample;
    wire                                 feeder_act_mask;
    wire signed [WEIGHT_WIDTH-1:0]       feeder_weight_sample;
    wire signed [ACT_WIDTH-1:0]          feeder_act_data_row [0:ROWS-1];
    wire                                 feeder_act_mask_row [0:ROWS-1];
    wire signed [WEIGHT_WIDTH-1:0]       feeder_weight_data_col [0:COLS-1];
    logic [K_WIDTH-1:0]                  feeder_k_executed;

    wire signed [ACT_WIDTH-1:0]          act_data_row [0:ROWS-1];
    wire                                 act_mask_row [0:ROWS-1];
    wire signed [WEIGHT_WIDTH-1:0]       weight_data  [0:ROWS-1][0:COLS-1];

    genvar dr_pe, dc_pe;
    generate
        for (dr_pe = 0; dr_pe < ROWS; dr_pe = dr_pe + 1) begin : gen_pe_act_broadcast
            assign act_data_row[dr_pe] = is_parallel_active ? feeder_act_data_row[dr_pe] : feeder_act_sample;
            assign act_mask_row[dr_pe] = is_parallel_active ? feeder_act_mask_row[dr_pe] : feeder_act_mask;
            for (dc_pe = 0; dc_pe < COLS; dc_pe = dc_pe + 1) begin : gen_pe_w_broadcast
                assign weight_data[dr_pe][dc_pe] = is_parallel_active ? feeder_weight_data_col[dc_pe] : feeder_weight_sample;
            end
        end
    endgenerate

    // Dummy per-PE unbroadcast inputs (not used in broadcast mode)
    logic signed [ACT_WIDTH-1:0]         dummy_act_data [0:ROWS-1][0:COLS-1];
    logic                                dummy_act_mask [0:ROWS-1][0:COLS-1];

    genvar dr, dc;
    generate
        for (dr = 0; dr < ROWS; dr = dr + 1) begin : gen_dummy_r
            for (dc = 0; dc < COLS; dc = dc + 1) begin : gen_dummy_c
                assign dummy_act_data[dr][dc] = '0;
                assign dummy_act_mask[dr][dc] = 1'b0;
            end
        end
    endgenerate

    assign active_cfg_mode = pe_array_cfg_mode;

    // =========================================================================
    // 1. Layer Command Sequencer (TSK-05)
    // =========================================================================
    layer_command_sequencer #(
        .LAYER_ID_W (LAYER_ID_W),
        .K_WIDTH    (K_WIDTH),
        .DEGRADE_W  (DEGRADE_W)
    ) u_sequencer (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .cmd_valid                (cmd_valid),
        .cmd_ready                (cmd_ready),
        .cmd_layer_id             (cmd_layer_id),
        .cmd_pe_mode              (cmd_pe_mode),
        .cmd_adaptive_en          (cmd_adaptive_en),
        .cmd_degradation_hat_16   (cmd_degradation_hat_16),
        .cmd_degradation_hat_32   (cmd_degradation_hat_32),
        .cmd_degradation_hat_64   (cmd_degradation_hat_64),
        .cmd_use_ping_pong        (cmd_use_ping_pong),
        .cmd_req_buf_id           (cmd_req_buf_id),
        .cmd_k_total              (cmd_k_total),
        .pe_start_req             (pe_start_req),
        .pe_req_mode              (pe_req_mode),
        .pe_adaptive_policy_en    (pe_adaptive_policy_en),
        .pe_degradation_hat_16    (pe_degradation_hat_16),
        .pe_degradation_hat_32    (pe_degradation_hat_32),
        .pe_degradation_hat_64    (pe_degradation_hat_64),
        .pe_controller_busy       (pe_controller_busy),
        .pe_layer_quiescent       (pe_layer_quiescent),
        .pe_configuration_changed (pe_configuration_changed),
        .pe_invalid_configuration (pe_invalid_configuration),
        .pe_compute_done          (pe_compute_done),
        .pe_drain_done            (pe_drain_done),
        .pe_layer_barrier_req     (pe_layer_barrier_req),
        .buf_consumer_ready       (buf_consumer_ready),
        .buf_consumer_buf_id      (buf_consumer_buf_id),
        .buf_consumer_start       (buf_consumer_start),
        .buf_consumer_done        (buf_consumer_done),
        .buf_consumer_active      (buf_consumer_active),
        .compute_start            (compute_start),
        .compute_k_total          (compute_k_total),
        .compute_done             (feeder_compute_done),
        .drain_done               (effective_drain_done),
        .drain_error              (ofmap_error_flag),
        .layer_done_pulse         (layer_done_pulse),
        .layer_done_id            (layer_done_id),
        .sequencer_busy           (sequencer_busy),
        .sequencer_state          (sequencer_state),
        .error_flag               (sequencer_error_flag),
        .error_code               (sequencer_error_code),
        .error_clear              (sequencer_error_clear)
    );

    // =========================================================================
    // 2. Adaptive PE Controller (TSK-02)
    // =========================================================================
    adaptive_pe_controller #(
        .COLS       (COLS)
    ) u_pe_controller (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .start_req             (pe_start_req),
        .req_mode              (pe_req_mode),
        .adaptive_policy_en    (pe_adaptive_policy_en),
        .degradation_hat_16    (pe_degradation_hat_16),
        .degradation_hat_32    (pe_degradation_hat_32),
        .degradation_hat_64    (pe_degradation_hat_64),
        .compute_enable_in     (feeder_compute_enable_in),
        .compute_done          (feeder_compute_done),
        .layer_barrier_req     (pe_layer_barrier_req),
        .drain_done            (pe_ctrl_drain_done),
        .col_mask_in           (16'hFFFF),
        .cfg_mode              (pe_array_cfg_mode),
        .enable                (pe_array_enable),
        .accum_clear           (pe_array_accum_clear),
        .sat_clear             (pe_array_sat_clear),
        .col_enable            (pe_array_col_enable),
        .controller_busy       (pe_controller_busy),
        .layer_quiescent       (pe_layer_quiescent),
        .configuration_changed (pe_configuration_changed),
        .fallback_to_64        (),
        .invalid_configuration (pe_invalid_configuration),
        .busy_reject           (),
        .controller_state      ()
    );

    // =========================================================================
    // 3. Ping-Pong Buffer Controller (TSK-04)
    // =========================================================================
    ping_pong_buffer_controller u_ping_pong (
        .clk                  (clk),
        .rst_n                (rst_n),
        .producer_ready       (pp_producer_ready),
        .producer_start       (pp_producer_start),
        .producer_done        (pp_producer_done),
        .producer_buf_id      (pp_producer_buf_id),
        .producer_active      (pp_producer_active),
        .producer_stall       (),
        .producer_err_start   (),
        .consumer_ready       (buf_consumer_ready),
        .consumer_start       (buf_consumer_start),
        .consumer_done        (buf_consumer_done),
        .consumer_buf_id      (buf_consumer_buf_id),
        .consumer_active      (buf_consumer_active),
        .consumer_stall       (),
        .consumer_err_start   (),
        .buf_state_a          (buf_state_a),
        .buf_state_b          (buf_state_b),
        .buf_a_empty          (),
        .buf_a_producing      (),
        .buf_a_ready          (),
        .buf_a_consuming      (),
        .buf_b_empty          (),
        .buf_b_producing      (),
        .buf_b_ready          (),
        .buf_b_consuming      (),
        .switch_event_pulse   (),
        .invariant_violation  (),
        .total_produced_count (total_produced_count),
        .total_consumed_count (total_consumed_count)
    );

    // =========================================================================
    // 4. DMA Controller (TSK-06)
    // =========================================================================
    dma_controller #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .LEN_WIDTH  (LEN_WIDTH),
        .FIFO_DEPTH (FIFO_DEPTH)
    ) u_dma (
        .clk               (clk),
        .rst_n             (rst_n),
        .dma_start         (dma_start),
        .dma_src_addr      (dma_src_addr),
        .dma_dst_addr      (dma_dst_addr),
        .dma_transfer_len  (dma_transfer_len),
        .dma_use_ping_pong (dma_use_ping_pong),
        .dma_error_clear   (dma_error_clear),
        .dma_busy          (dma_busy),
        .dma_state         (dma_state),
        .dma_done_pulse    (dma_done_pulse),
        .dma_error_flag    (dma_error_flag),
        .dma_error_code    (dma_error_code),
        .pp_producer_ready (pp_producer_ready),
        .pp_producer_start (pp_producer_start),
        .pp_producer_done  (pp_producer_done),
        .m_axi_araddr      (m_axi_araddr),
        .m_axi_arlen       (m_axi_arlen),
        .m_axi_arsize      (m_axi_arsize),
        .m_axi_arburst     (m_axi_arburst),
        .m_axi_arvalid     (m_axi_arvalid),
        .m_axi_arready     (m_axi_arready),
        .m_axi_rdata       (m_axi_rdata),
        .m_axi_rresp       (m_axi_rresp),
        .m_axi_rlast       (m_axi_rlast),
        .m_axi_rvalid      (m_axi_rvalid),
        .m_axi_rready      (m_axi_rready),
        .m_axi_awaddr      (dma_awaddr),
        .m_axi_awlen       (dma_awlen),
        .m_axi_awsize      (dma_awsize),
        .m_axi_awburst     (dma_awburst),
        .m_axi_awvalid     (dma_awvalid),
        .m_axi_awready     (dma_awready),
        .m_axi_wdata       (dma_wdata),
        .m_axi_wstrb       (dma_wstrb),
        .m_axi_wlast       (dma_wlast),
        .m_axi_wvalid      (dma_wvalid),
        .m_axi_wready      (dma_wready),
        .m_axi_bresp       (dma_bresp),
        .m_axi_bvalid      (dma_bvalid),
        .m_axi_bready      (dma_bready)
    );

    // =========================================================================
    // 5. DMA-to-SRAM Write Adapter (AXI4 Write Master -> SRAM Port A0 Write)
    // =========================================================================
    dma_to_sram_write_adapter #(
        .ADDR_WIDTH  (ADDR_WIDTH),
        .DATA_WIDTH  (DATA_WIDTH),
        .SRAM_ADDR_W (SRAM_GLOBAL_ADDR)
    ) u_dma_sram_adpt (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_axi_awaddr    (dma_awaddr),
        .s_axi_awlen     (dma_awlen),
        .s_axi_awsize    (dma_awsize),
        .s_axi_awburst   (dma_awburst),
        .s_axi_awvalid   (dma_awvalid),
        .s_axi_awready   (dma_awready),
        .s_axi_wdata     (dma_wdata),
        .s_axi_wstrb     (dma_wstrb),
        .s_axi_wlast     (dma_wlast),
        .s_axi_wvalid    (dma_wvalid),
        .s_axi_wready    (dma_wready),
        .s_axi_bresp     (dma_bresp),
        .s_axi_bvalid    (dma_bvalid),
        .s_axi_bready    (dma_bready),
        .sram_wr_req     (sram_wr_req_0),
        .sram_wr_addr    (sram_wr_addr_0),
        .sram_wr_din     (sram_wr_din_0),
        .sram_wr_byte_we (sram_wr_byte_we_0),
        .sram_wr_ready   (sram_wr_ready_0),
        .sram_wr_ack     (sram_wr_ack_0)
    );

    // =========================================================================
    // 6. Multi-Bank SRAM Subsystem (TSK-03: 41,472 Bytes across 8 Banks)
    // =========================================================================
    multibank_sram_subsystem #(
        .NUM_BANKS       (NUM_BANKS),
        .BYTES_PER_BANK  (BYTES_PER_BANK),
        .DATA_WIDTH      (DATA_WIDTH),
        .BANK_ADDR_W     (BANK_ADDR_W),
        .NUM_READ_PORTS  (NUM_BANKS),
        .NUM_WRITE_PORTS (NUM_BANKS)
    ) u_sram_subsystem (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .bank_enable           (8'hFF),
        .wr_req                (sram_wr_req_bus),
        .wr_addr               (sram_wr_addr_bus),
        .wr_din                (sram_wr_din_bus),
        .wr_byte_we            (sram_wr_byte_we_bus),
        .wr_ready              (sram_wr_ready_bus),
        .wr_ack                (sram_wr_ack_bus),
        .wr_conflict_stall     (sram_wr_conflict_stall),
        .rd_req                (sram_rd_req_bus),
        .rd_addr               (sram_rd_addr_bus),
        .rd_ready              (sram_rd_ready_bus),
        .rd_rvalid             (sram_rd_rvalid_bus),
        .rd_dout               (sram_rd_dout_bus),
        .rd_conflict_stall     (sram_rd_conflict_stall),
        .bank_conflict_flags   (sram_bank_conflict_flags),
        .bank_oob_err          (sram_bank_oob_err),
        .oob_error_any         (sram_oob_error_any),
        .total_conflicts_count (sram_total_conflicts_count),
        .total_read_accesses   (sram_total_read_accesses),
        .total_write_accesses  (sram_total_write_accesses)
    );

    // =========================================================================
    // 6b. Memory Telemetry Monitor (TSK-20)
    // =========================================================================
    memory_telemetry_monitor #(
        .NUM_BANKS       (NUM_BANKS),
        .BANK_ADDR_W     (BANK_ADDR_W),
        .NUM_READ_PORTS  (NUM_BANKS),
        .NUM_WRITE_PORTS (NUM_BANKS),
        .DATA_WIDTH      (DATA_WIDTH)
    ) u_mem_telemetry (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .telemetry_clear          (sequencer_error_clear | (cmd_valid && cmd_ready)),
        .wr_req                   (sram_wr_req_bus),
        .wr_addr                  (sram_wr_addr_bus),
        .wr_ready                 (sram_wr_ready_bus),
        .wr_ack                   (sram_wr_ack_bus),
        .wr_conflict_stall        (sram_wr_conflict_stall),
        .rd_req                   (sram_rd_req_bus),
        .rd_addr                  (sram_rd_addr_bus),
        .rd_ready                 (sram_rd_ready_bus),
        .rd_rvalid                (sram_rd_rvalid_bus),
        .rd_conflict_stall        (sram_rd_conflict_stall),
        .bank_conflict_flags      (sram_bank_conflict_flags),
        .mon_total_cycles         (telemetry_mem_total_cycles),
        .mon_idle_cycles          (telemetry_mem_idle_cycles),
        .mon_rd_req_cycles        (telemetry_mem_rd_req_cycles),
        .mon_wr_req_cycles        (telemetry_mem_wr_req_cycles),
        .mon_rd_accepted_trans    (telemetry_mem_rd_accepted),
        .mon_wr_accepted_trans    (telemetry_mem_wr_accepted),
        .mon_rd_stall_cycles      (telemetry_mem_rd_stall_cycles),
        .mon_wr_stall_cycles      (telemetry_mem_wr_stall_cycles),
        .mon_bank_conflict_cycles (telemetry_mem_bank_conflict_cycles),
        .mon_total_bank_conflicts (telemetry_mem_total_conflicts),
        .mon_bank_rd_trans        (),
        .mon_bank_wr_trans        (),
        .mon_bank_conflicts       (),
        .mon_peak_rd_per_cycle    (),
        .mon_peak_wr_per_cycle    ()
    );

    assign telemetry_bank_conflict_flags = sram_bank_conflict_flags;

    // =========================================================================
    // 7. Datapath Compute Feeder (SRAM Port B0 Read -> PE Array Operands)
    // =========================================================================
    datapath_compute_feeder #(
        .SRAM_ADDR_W           (SRAM_GLOBAL_ADDR),
        .DATA_WIDTH            (DATA_WIDTH),
        .ACT_WIDTH             (ACT_WIDTH),
        .WEIGHT_WIDTH          (WEIGHT_WIDTH),
        .ROWS                  (ROWS),
        .COLS                  (COLS),
        .K_WIDTH               (K_WIDTH),
        .NUM_BANKS             (NUM_BANKS),
        .BUF_A_BASE            (14'h0000),
        .BUF_B_BASE            (14'h1000),
        .PARALLEL_OPERAND_MODE (PARALLEL_OPERAND_MODE),
        .SPARSE_OPERAND_MODE   (SPARSE_OPERAND_MODE)
    ) u_feeder (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .cfg_parallel_en       (is_parallel_active),
        .cfg_mode              (pe_array_cfg_mode),
        .cfg_sparse_en         (cfg_sparse_feeder_en),
        .compute_start         (compute_start),
        .compute_k_total       (compute_k_total),
        .buf_consumer_buf_id   (buf_consumer_buf_id),
        .pe_layer_quiescent    (pe_layer_quiescent),
        .compute_done          (feeder_compute_done),
        .drain_done            (feeder_drain_done),
        .feeder_busy           (feeder_busy),
        .compute_enable_in     (feeder_compute_enable_in),
        .sram_rd_req_bus       (sram_rd_req_bus),
        .sram_rd_addr_bus      (sram_rd_addr_bus),
        .sram_rd_ready_bus     (sram_rd_ready_bus),
        .sram_rd_rvalid_bus    (sram_rd_rvalid_bus),
        .sram_rd_dout_bus      (sram_rd_dout_bus),
        .broadcast_act         (broadcast_act),
        .act_sample            (feeder_act_sample),
        .act_mask_sample       (feeder_act_mask),
        .weight_sample         (feeder_weight_sample),
        .act_data_row          (feeder_act_data_row),
        .act_mask_row          (feeder_act_mask_row),
        .weight_data_col       (feeder_weight_data_col),
        .k_executed_count      (feeder_k_executed)
    );

    // =========================================================================
    // 8. Multi-PE Array (TSK-01: 64 PEs, 4 Rows x 16 Cols)
    // =========================================================================
    wire pe_cycle_skipped_matrix [0:ROWS-1][0:COLS-1];
    wire [COLS-1:0] pe_col_cycle_skipped;

    pe_array_40b #(
        .ROWS         (ROWS),
        .COLS         (COLS),
        .ACT_WIDTH    (ACT_WIDTH),
        .WEIGHT_WIDTH (WEIGHT_WIDTH),
        .ACCUM_WIDTH  (ACCUM_WIDTH)
    ) u_pe_array (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .cfg_mode                (pe_array_cfg_mode),
        .cfg_invalid             (),
        .active_pe_count         (active_pe_count),
        .col_active              (col_active),
        .enable                  (pe_array_enable),
        .col_enable              (pe_array_col_enable),
        .accum_clear             (pe_array_accum_clear),
        .sat_clear               (pe_array_sat_clear),
        .broadcast_act           (broadcast_act),
        .act_data_row            (act_data_row),
        .act_mask_row            (act_mask_row),
        .act_data                (dummy_act_data),
        .act_mask                (dummy_act_mask),
        .weight_data             (weight_data),
        .accum_out               (accum_out),
        .sticky_saturation       (),
        .cycle_skipped           (pe_cycle_skipped_matrix),
        .col_sticky_saturation   (col_sticky_saturation),
        .col_cycle_skipped       (pe_col_cycle_skipped),
        .array_sticky_saturation (array_sticky_saturation)
    );

    // =========================================================================
    // 9. OFMAP Drain Controller (TSK-11: 64-PE to 128-word SRAM Port A1 Writer)
    // =========================================================================
    ofmap_drain_controller #(
        .ROWS              (ROWS),
        .COLS              (COLS),
        .ACCUM_WIDTH       (ACCUM_WIDTH),
        .SRAM_ADDR_W       (SRAM_GLOBAL_ADDR),
        .DATA_WIDTH        (DATA_WIDTH),
        .DEFAULT_BASE_ADDR (DEFAULT_OFMAP_BASE)
    ) u_ofmap_drain (
        .clk                 (clk),
        .rst_n               (rst_n),
        .cfg_mode            (pe_array_cfg_mode),
        .drain_start         (ofmap_drain_start),
        .base_addr           (effective_ofmap_base),
        .drain_busy          (ofmap_drain_busy),
        .drain_done          (ofmap_drain_done_int),
        .drain_error_flag    (ofmap_error_flag),
        .error_clear         (sequencer_error_clear),
        .busy_reject_pulse   (),
        .words_written_count (ofmap_words_written),
        .accum_out           (accum_out),
        .sram_wr_req         (ofmap_sram_wr_req),
        .sram_wr_addr        (ofmap_sram_wr_addr),
        .sram_wr_din         (ofmap_sram_wr_din),
        .sram_wr_byte_we     (ofmap_sram_wr_byte_we),
        .sram_wr_ready       (ofmap_sram_wr_ready),
        .sram_wr_ack         (ofmap_sram_wr_ack)
    );

    assign ofmap_drain_done = ofmap_drain_done_int;

    // =========================================================================
    // 10. Integrated MAC Telemetry & Performance Instrumentation (TSK-18)
    // =========================================================================
    logic [6:0] skipped_pe_cnt_comb;
    always_comb begin
        skipped_pe_cnt_comb = '0;
        for (int c = 0; c < COLS; c = c + 1) begin
            if (col_active[c]) begin
                for (int r = 0; r < ROWS; r = r + 1) begin
                    if (pe_cycle_skipped_matrix[r][c]) begin
                        skipped_pe_cnt_comb = skipped_pe_cnt_comb + 1'b1;
                    end
                end
            end
        end
    end

    logic [3:0] rd_reqs_cnt_comb;
    logic [3:0] rd_acc_cnt_comb;
    always_comb begin
        rd_reqs_cnt_comb = '0;
        rd_acc_cnt_comb  = '0;
        for (int b = 0; b < NUM_BANKS; b = b + 1) begin
            if (sram_rd_req_bus[b]) begin
                rd_reqs_cnt_comb = rd_reqs_cnt_comb + 1'b1;
                if (sram_rd_ready_bus[b]) begin
                    rd_acc_cnt_comb = rd_acc_cnt_comb + 1'b1;
                end
            end
        end
    end

    logic layer_active_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            layer_active_q                     <= 1'b0;
            telemetry_enabled_macs             <= 32'd0;
            telemetry_executed_macs            <= 32'd0;
            telemetry_skipped_macs             <= 32'd0;
            telemetry_zero_act_opportunities   <= 32'd0;
            telemetry_compute_cycles           <= 32'd0;
            telemetry_total_layer_cycles       <= 32'd0;
            telemetry_sram_read_reqs           <= 32'd0;
            telemetry_sram_read_accepted       <= 32'd0;
        end else begin
            // Reset per-layer counters upon new command/compute initiation
            if (compute_start || (cmd_valid && cmd_ready)) begin
                layer_active_q                     <= 1'b1;
                telemetry_enabled_macs             <= 32'd0;
                telemetry_executed_macs            <= 32'd0;
                telemetry_skipped_macs             <= 32'd0;
                telemetry_zero_act_opportunities   <= 32'd0;
                telemetry_compute_cycles           <= 32'd0;
                telemetry_total_layer_cycles       <= 32'd0;
                telemetry_sram_read_reqs           <= 32'd0;
                telemetry_sram_read_accepted       <= 32'd0;
            end else if (layer_done_pulse) begin
                layer_active_q <= 1'b0;
            end

            // Accumulate metrics while layer is active
            if (layer_active_q) begin
                telemetry_total_layer_cycles <= telemetry_total_layer_cycles + 1'b1;

                if (feeder_busy) begin
                    telemetry_sram_read_reqs     <= telemetry_sram_read_reqs + rd_reqs_cnt_comb;
                    telemetry_sram_read_accepted <= telemetry_sram_read_accepted + rd_acc_cnt_comb;
                end

                if (pe_array_enable) begin
                    telemetry_compute_cycles         <= telemetry_compute_cycles + 1'b1;
                    telemetry_enabled_macs           <= telemetry_enabled_macs + active_pe_count;
                    telemetry_skipped_macs           <= telemetry_skipped_macs + skipped_pe_cnt_comb;
                    telemetry_executed_macs          <= telemetry_executed_macs + (active_pe_count - skipped_pe_cnt_comb);
                    telemetry_zero_act_opportunities <= telemetry_zero_act_opportunities + skipped_pe_cnt_comb;
                end
            end
        end
    end

endmodule