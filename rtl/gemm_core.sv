`timescale 1ns/1ps
`default_nettype none

// GEMM core: 3 scratchpads + 2 skew feeders + 4x4 PE array + controller.
module gemm_core #(
    parameter int MAX_M  = 64,
    parameter int MAX_N  = 64,
    parameter int MAX_K  = 256,
    parameter int MN_W   = $clog2((MAX_M > MAX_N ? MAX_M : MAX_N) + 1),
    parameter int K_W    = $clog2(MAX_K+1),
    parameter int ADDR_W = 12
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              start,
    input  logic [MN_W-1:0]   m,
    input  logic [MN_W-1:0]   n,
    input  logic [K_W-1:0]    k,

    output logic              done,
    output logic              busy,

    input  logic              host_en,
    input  logic              host_we,
    input  logic [1:0]        host_sel,    // 0 = A, 1 = B, 2 = C
    input  logic [ADDR_W-1:0] host_addr,
    input  logic [31:0]       host_wdata,
    output logic [31:0]       host_rdata   // valid 1 cycle after a host read
);

    localparam int ROWS   = 4;
    localparam int COLS   = 4;
    localparam int DATA_W = 8;
    localparam int ACC_W  = 32;
    localparam int DEPTH  = 1 << ADDR_W;

    localparam logic [1:0] SEL_A = 2'd0;
    localparam logic [1:0] SEL_B = 2'd1;
    localparam logic [1:0] SEL_C = 2'd2;

    // Controller outputs
    logic              ctrl_a_en, ctrl_b_en, ctrl_c_en;
    logic [ADDR_W-1:0] ctrl_a_addr, ctrl_b_addr, ctrl_c_addr;
    logic              feed_valid;
    logic              clear;
    logic [3:0]        drain_sel;

    // SPM ports (each driven only by its port mux below)
    logic              spm_a_en, spm_a_we;
    logic [ADDR_W-1:0] spm_a_addr;
    logic [31:0]       spm_a_wdata, spm_a_rdata;

    logic              spm_b_en, spm_b_we;
    logic [ADDR_W-1:0] spm_b_addr;
    logic [31:0]       spm_b_wdata, spm_b_rdata;

    logic              spm_c_en, spm_c_we;
    logic [ADDR_W-1:0] spm_c_addr;
    logic [31:0]       spm_c_wdata, spm_c_rdata;

    // Datapath
    logic [ROWS*DATA_W-1:0]     a_skewed;
    logic [COLS*DATA_W-1:0]     b_skewed;
    logic [ROWS*COLS*ACC_W-1:0] acc;
    logic [ACC_W-1:0]           drain_data;

    // Host read select, delayed to line up with the SPM read latency
    logic [1:0] sel_q;

    // Instances
    spm #(
        .DATA_W (32),
        .DEPTH  (DEPTH)
    ) a_spm (
        .clk   (clk),
        .en    (spm_a_en),
        .we    (spm_a_we),
        .addr  (spm_a_addr),
        .wdata (spm_a_wdata),
        .rdata (spm_a_rdata)
    );

    spm #(
        .DATA_W (32),
        .DEPTH  (DEPTH)
    ) b_spm (
        .clk   (clk),
        .en    (spm_b_en),
        .we    (spm_b_we),
        .addr  (spm_b_addr),
        .wdata (spm_b_wdata),
        .rdata (spm_b_rdata)
    );

    spm #(
        .DATA_W (32),
        .DEPTH  (DEPTH)
    ) c_spm (
        .clk   (clk),
        .en    (spm_c_en),
        .we    (spm_c_we),
        .addr  (spm_c_addr),
        .wdata (spm_c_wdata),
        .rdata (spm_c_rdata)
    );

    skew #(
        .LANES  (ROWS),
        .DATA_W (DATA_W)
    ) a_skew (
        .clk      (clk),
        .rst      (rst),
        .in_valid (feed_valid),
        .in_data  (spm_a_rdata),
        .out_data (a_skewed)
    );

    skew #(
        .LANES  (COLS),
        .DATA_W (DATA_W)
    ) b_skew (
        .clk      (clk),
        .rst      (rst),
        .in_valid (feed_valid),
        .in_data  (spm_b_rdata),
        .out_data (b_skewed)
    );

    pe_array #(
        .ROWS   (ROWS),
        .COLS   (COLS),
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W)
    ) pe_array_inst (
        .clk   (clk),
        .rst   (rst),
        .clear (clear),
        .a_in  (a_skewed),
        .b_in  (b_skewed),
        .acc   (acc)
    );

    gemm_ctrl #(
        .MAX_M  (MAX_M),
        .MAX_N  (MAX_N),
        .MAX_K  (MAX_K),
        .ADDR_W (ADDR_W)
    ) gemm_ctrl_inst (
        .clk        (clk),
        .rst        (rst),
        .start      (start),
        .m          (m),
        .n          (n),
        .k          (k),
        .done       (done),
        .busy       (busy),
        .a_en       (ctrl_a_en),
        .b_en       (ctrl_b_en),
        .c_en       (ctrl_c_en),
        .feed_valid (feed_valid),
        .clear      (clear),
        .drain_sel  (drain_sel),
        .a_addr     (ctrl_a_addr),
        .b_addr     (ctrl_b_addr),
        .c_addr     (ctrl_c_addr)
    );

    // SPM port muxes: controller while busy, host otherwise.
    // Every output gets a default first, so no latches.

    always_comb begin
        spm_a_en    = 1'b0;
        spm_a_we    = 1'b0;
        spm_a_addr  = '0;
        spm_a_wdata = '0;
        if (busy) begin
            spm_a_en    = ctrl_a_en;
            spm_a_addr  = ctrl_a_addr;
        end else if (host_en && host_sel == SEL_A) begin
            spm_a_en    = 1'b1;
            spm_a_we    = host_we;
            spm_a_addr  = host_addr;
            spm_a_wdata = host_wdata;
        end
    end

    always_comb begin
        spm_b_en    = 1'b0;
        spm_b_we    = 1'b0;
        spm_b_addr  = '0;
        spm_b_wdata = '0;
        if (busy) begin
            spm_b_en    = ctrl_b_en;
            spm_b_addr  = ctrl_b_addr;
        end else if (host_en && host_sel == SEL_B) begin
            spm_b_en    = 1'b1;
            spm_b_we    = host_we;
            spm_b_addr  = host_addr;
            spm_b_wdata = host_wdata;
        end
    end

    always_comb begin
        spm_c_en    = 1'b0;
        spm_c_we    = 1'b0;
        spm_c_addr  = '0;
        spm_c_wdata = '0;
        if (busy) begin
            spm_c_en    = ctrl_c_en;
            spm_c_we    = 1'b1;
            spm_c_addr  = ctrl_c_addr;
            spm_c_wdata = drain_data;
        end else if (host_en && !host_we && host_sel == SEL_C) begin
            spm_c_en    = 1'b1;
            spm_c_addr  = host_addr;
        end
    end

    assign drain_data = acc[drain_sel*ACC_W +: ACC_W];

    // The SPM answers one cycle after the read, so remember which one was read
    always_ff @(posedge clk) begin
        if (rst)
            sel_q <= SEL_A;
        else if (host_en && !host_we && !busy)
            sel_q <= host_sel;
    end

    always_comb begin
        case (sel_q)
            SEL_A:   host_rdata = spm_a_rdata;
            SEL_B:   host_rdata = spm_b_rdata;
            SEL_C:   host_rdata = spm_c_rdata;
            default: host_rdata = '0;
        endcase
    end

endmodule

`default_nettype wire
