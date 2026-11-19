`timescale 1ns/1ps
`default_nettype none

// GEMM accelerator top: AXI4-Lite slave + register file around gemm_core.
// Register map: docs/SPECS.md. The SoC decoder strips the base address,
// so this module only sees the 16-bit offset inside its 64 KB window.
//
//   addr[15:14]  region      addr[13:2]  word index (SPM) / register offset
//   00           registers
//   01           SPM A
//   10           SPM B
//   11           SPM C (read-only)
module gemm_top #(
    parameter int MAX_M = 64,
    parameter int MAX_N = 64,
    parameter int MAX_K = 256
) (
    input  logic        clk,
    input  logic        rst,             // active high

    // AW: write address (master -> slave)
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [15:0] s_axil_awaddr,

    // W: write data (master -> slave)
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,

    // B: write response (slave -> master)
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    output logic [1:0]  s_axil_bresp,    // 2'b00 OKAY, 2'b10 SLVERR

    // AR: read address (master -> slave)
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    input  logic [15:0] s_axil_araddr,

    // R: read data (slave -> master)
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,
    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,

    output logic        irq
);

    localparam int MN_W   = $clog2((MAX_M > MAX_N ? MAX_M : MAX_N) + 1);
    localparam int K_W    = $clog2(MAX_K + 1);
    localparam int ADDR_W = 12;

    // Regions (addr[15:14])
    localparam logic [1:0] RGN_REG = 2'd0;
    localparam logic [1:0] RGN_A   = 2'd1;
    localparam logic [1:0] RGN_B   = 2'd2;
    localparam logic [1:0] RGN_C   = 2'd3;

    // Register offsets (addr[15:0] with region 00)
    localparam logic [15:0] OFF_CTRL   = 16'h0000;
    localparam logic [15:0] OFF_STATUS = 16'h0004;
    localparam logic [15:0] OFF_DIM_M  = 16'h0008;
    localparam logic [15:0] OFF_DIM_N  = 16'h000C;
    localparam logic [15:0] OFF_DIM_K  = 16'h0010;
    localparam logic [15:0] OFF_CYCLES = 16'h0014;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    // ------------------------------------------------------------------
    // Bus FSM: one transaction at a time (also keeps the single host port
    // of gemm_core from being used by a read and a write in the same cycle)
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,     // wait for (AW and W) or AR
        S_WRESP,    // bvalid = 1 until bready
        S_RADDR,    // drive host_en for an SPM read
        S_RDATA,    // SPM data ready: capture into rdata_q
        S_RRESP     // rvalid = 1 until rready
    } state_t;
    state_t state;

    logic        wr_fire;      // AW and W handshake this cycle
    logic        rd_fire;      // AR handshake this cycle
    logic [15:0] raddr_q;      // latched read address
    logic [31:0] rdata_q;      // read data held for the R channel
    logic [1:0]  bresp_q, rresp_q;

    // ------------------------------------------------------------------
    // Register file
    // ------------------------------------------------------------------
    logic        irq_en_q;
    logic [31:0] dim_m_q, dim_n_q, dim_k_q;   // full width: validate before narrowing
    logic        done_q;                     // sticky, cleared on START
    logic        err_q;
    logic [31:0] cycles_q;

    logic        start_pulse;                // 1 cycle, to gemm_core.start
    logic        soft_rst_pulse;
    logic        dims_ok;

    // gemm_core
    logic              core_rst;
    logic              core_done, core_busy;
    logic              host_en, host_we;
    logic [1:0]        host_sel;
    logic [ADDR_W-1:0] host_addr;
    logic [31:0]       host_wdata, host_rdata;

    gemm_core #(
        .MAX_M  (MAX_M),
        .MAX_N  (MAX_N),
        .MAX_K  (MAX_K),
        .ADDR_W (ADDR_W)
    ) u_core (
        .clk        (clk),
        .rst        (core_rst),
        .start      (start_pulse),
        .m          (dim_m_q[MN_W-1:0]),
        .n          (dim_n_q[MN_W-1:0]),
        .k          (dim_k_q[K_W-1:0]),
        .done       (core_done),
        .busy       (core_busy),
        .host_en    (host_en),
        .host_we    (host_we),
        .host_sel   (host_sel),
        .host_addr  (host_addr),
        .host_wdata (host_wdata),
        .host_rdata (host_rdata)
    );

    assign core_rst = rst | soft_rst_pulse;

    logic [1:0] wr_rgn, rd_rgn;                  // address region (see header)
    assign wr_rgn = s_axil_awaddr[15:14];
    assign rd_rgn = raddr_q[15:14];

    // Handshakes: accept AW and W together; writes win over reads
    always_comb begin
        s_axil_awready = (state == S_IDLE) && s_axil_awvalid && s_axil_wvalid;
        s_axil_wready  = s_axil_awready;
        wr_fire        = s_axil_awready;         // awready already implies awvalid

        s_axil_arready = (state == S_IDLE) && s_axil_arvalid && !wr_fire;
        rd_fire        = s_axil_arready;
    end

    // bus FSM (always_ff): state, raddr_q, rdata_q, bresp_q, rresp_q
    logic [31:0] reg_rdata_mux;
    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            raddr_q <= '0;
            rdata_q <= '0;
            bresp_q <= RESP_OKAY;
            rresp_q <= RESP_OKAY;
        end else begin
            case (state)
                S_IDLE: begin
                    if (wr_fire) begin
                        if (wr_rgn == RGN_C || (wr_rgn != RGN_REG && core_busy))
                            bresp_q <= RESP_SLVERR;
                        else
                            bresp_q <= RESP_OKAY;
                        state <= S_WRESP;
                    end else if (rd_fire) begin
                        raddr_q <= s_axil_araddr;
                        state   <= S_RADDR;
                    end
                end

                // Write response: bvalid = 1 here; leave when the master takes it
                S_WRESP: begin
                    if (s_axil_bready)
                        state <= S_IDLE;
                end

                S_RADDR: begin
                    state <= S_RDATA;
                end

                // SPM answered (1-cycle latency): capture the data once
                S_RDATA: begin
                    if (rd_rgn == RGN_REG)
                        rdata_q <= reg_rdata_mux;
                    else
                        rdata_q <= host_rdata;

                    if (rd_rgn != RGN_REG && core_busy)
                        rresp_q <= RESP_SLVERR;
                    else
                        rresp_q <= RESP_OKAY;
                    state <= S_RRESP;
                end

                // Read response: rvalid = 1 here; leave when the master takes it
                S_RRESP: begin
                    if (s_axil_rready)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // Response channels come straight from the FSM state and the _q registers,
    // so they cannot change while the master is not ready (AXI rule).
    assign s_axil_bvalid = (state == S_WRESP);
    assign s_axil_bresp  = bresp_q;
    assign s_axil_rvalid = (state == S_RRESP);
    assign s_axil_rdata  = rdata_q;
    assign s_axil_rresp  = rresp_q;


endmodule

`default_nettype wire
