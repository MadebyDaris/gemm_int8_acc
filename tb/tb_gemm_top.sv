`timescale 1ns/1ps
`default_nettype none

// gemm_top over AXI4-Lite. Steps follow the TODOs in rtl/gemm_top.sv; the first
// failing step tells you which part to look at.
//
//   make sim-gemm_top                      (4x4x16 vectors)
//   make sim-gemm_top M=8 N=12 K=33        (any vector set)
//
// Policy checked here (add it to docs/SPECS.md if you agree):
//   every START write clears DONE and ERR; ERR = 1 if that START had bad dims.
module tb_gemm_top;

    localparam string VEC     = "build/vec/";
    localparam int    TIMEOUT = 200;           // cycles per handshake

    localparam logic [15:0] CTRL   = 16'h0000;
    localparam logic [15:0] STATUS = 16'h0004;
    localparam logic [15:0] DIM_M  = 16'h0008;
    localparam logic [15:0] DIM_N  = 16'h000C;
    localparam logic [15:0] DIM_K  = 16'h0010;
    localparam logic [15:0] CYCLES = 16'h0014;
    localparam logic [15:0] SPM_A  = 16'h4000;
    localparam logic [15:0] SPM_B  = 16'h8000;
    localparam logic [15:0] SPM_C  = 16'hC000;

    localparam logic [31:0] START    = 32'h1;
    localparam logic [31:0] SOFT_RST = 32'h2;
    localparam logic [31:0] IRQ_EN   = 32'h4;

    logic        clk = 0, rst = 1;
    logic        s_axil_awvalid = 0, s_axil_awready;  logic [15:0] s_axil_awaddr = 0;
    logic        s_axil_wvalid  = 0, s_axil_wready;   logic [31:0] s_axil_wdata  = 0;
    logic [3:0]  s_axil_wstrb   = 4'hF;
    logic        s_axil_bvalid,  s_axil_bready  = 0;  logic [1:0]  s_axil_bresp;
    logic        s_axil_arvalid = 0, s_axil_arready;  logic [15:0] s_axil_araddr = 0;
    logic        s_axil_rvalid,  s_axil_rready  = 0;  logic [31:0] s_axil_rdata;
    logic [1:0]  s_axil_rresp;
    logic        irq;

    always #5 clk = ~clk;

    gemm_top dut (.*);

    // Test vectors (from model/gemm_model.py)
    logic [31:0] dims  [3];
    logic [31:0] a_mem [4096];
    logic [31:0] b_mem [4096];
    logic [31:0] c_exp [4096];
    int M, N, K, a_words, b_words, c_words, exp_cycles;

    int errors = 0;

    // ------------------------------------------------------------------
    // Helpers. The TB drives with <= just after a clock edge and samples
    // just after the next edge, i.e. the value the DUT saw at that edge.
    // ------------------------------------------------------------------
    task automatic fail(input string msg);
        $display("ERROR: %s", msg);
        $display("TEST FAILED");
        $finish;
    endtask

    task automatic expect_eq(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("ERROR: %s: got %h, expected %h", what, got, exp);
            errors++;
        end
    endtask

    // gap   = cycles AW is shown before W (0 = together)
    // delay = cycles bready stays low after bvalid
    task automatic axil_write(input logic [15:0] addr, input logic [31:0] data,
                              output logic [1:0] resp, input int gap = 0, input int delay = 0);
        int t;
        s_axil_awaddr  <= addr;
        s_axil_awvalid <= 1;
        repeat (gap) begin
            @(posedge clk);
            if (s_axil_awready !== 1'b0) fail("awready high before wvalid (AW and W must be taken together)");
        end
        s_axil_wdata   <= data;
        s_axil_wvalid  <= 1;
        t = 0;
        @(posedge clk);
        while (s_axil_awready !== 1'b1) begin                     // AW + W transfer on this edge
            if (++t > TIMEOUT) fail($sformatf("write %h: awready never came", addr));
            @(posedge clk);
        end
        if (s_axil_wready !== 1'b1) fail("awready without wready");
        s_axil_awvalid <= 0;
        s_axil_wvalid  <= 0;
        t = 0;
        @(posedge clk);
        while (s_axil_bvalid !== 1'b1) begin
            if (++t > TIMEOUT) fail($sformatf("write %h: bvalid never came", addr));
            @(posedge clk);
        end
        resp = s_axil_bresp;
        repeat (delay) begin
            @(posedge clk);
            if (s_axil_bvalid !== 1'b1) fail("bvalid dropped before bready");
        end
        s_axil_bready <= 1;                               // B transfer on next edge
        @(posedge clk);
        s_axil_bready <= 0;
    endtask

    // delay = cycles rready stays low after rvalid (rdata must not change)
    task automatic axil_read(input logic [15:0] addr, output logic [31:0] data,
                             output logic [1:0] resp, input int delay = 0);
        int t;
        s_axil_araddr  <= addr;
        s_axil_arvalid <= 1;
        t = 0;
        @(posedge clk);
        while (s_axil_arready !== 1'b1) begin                     // AR transfer on this edge
            if (++t > TIMEOUT) fail($sformatf("read %h: arready never came", addr));
            @(posedge clk);
        end
        s_axil_arvalid <= 0;
        t = 0;
        @(posedge clk);
        while (s_axil_rvalid !== 1'b1) begin
            if (++t > TIMEOUT) fail($sformatf("read %h: rvalid never came", addr));
            @(posedge clk);
        end
        data = s_axil_rdata;
        resp = s_axil_rresp;
        repeat (delay) begin
            @(posedge clk);
            if (s_axil_rvalid !== 1'b1 || s_axil_rdata !== data)
                fail("rvalid/rdata changed before rready");
        end
        s_axil_rready <= 1;                               // R transfer on next edge
        @(posedge clk);
        s_axil_rready <= 0;
    endtask

    // Short forms that also check for an OKAY response
    task automatic wr(input logic [15:0] addr, input logic [31:0] data);
        logic [1:0] resp;
        axil_write(addr, data, resp);
        expect_eq($sformatf("bresp of write %h", addr), {30'b0, resp}, 0);
    endtask

    task automatic rd(input logic [15:0] addr, output logic [31:0] data);
        logic [1:0] resp;
        axil_read(addr, data, resp);
        expect_eq($sformatf("rresp of read %h", addr), {30'b0, resp}, 0);
    endtask

    task automatic check_rd(input logic [15:0] addr, input logic [31:0] exp);
        logic [31:0] got;
        rd(addr, got);
        expect_eq($sformatf("read %h", addr), got, exp);
    endtask

    // STATUS = {ERR, DONE, BUSY}
    task automatic check_status(input string what, input logic [2:0] exp);
        logic [31:0] got;
        rd(STATUS, got);
        expect_eq({what, ": STATUS {ERR,DONE,BUSY}"}, {29'b0, got[2:0]}, {29'b0, exp});
    endtask

    task automatic wait_done(output int polls);
        logic [31:0] st;
        polls = 0;
        do begin
            rd(STATUS, st);
            if (++polls > exp_cycles) fail("DONE never set");
        end while (!st[1]);
    endtask

    task automatic step(input string name);
        if (errors != 0) begin
            $display("TEST FAILED: %0d errors before step '%s'", errors, name);
            $finish;
        end
        $display("--- %s", name);
    endtask

    // ------------------------------------------------------------------
    initial begin
        logic [31:0] got;
        logic [1:0]  resp;
        int          polls;

        $dumpfile("build/tb_gemm_top.vcd");
        $dumpvars(0, tb_gemm_top);

        $readmemh({VEC, "dims.hex"}, dims);
        M = dims[0];  N = dims[1];  K = dims[2];
        a_words = K * M / 4;
        b_words = K * N / 4;
        c_words = M * N;
        exp_cycles = (M / 4) * (N / 4) * (K + 24) + 1;   // busy cycles of gemm_core
        $readmemh({VEC, "a.hex"}, a_mem, 0, a_words - 1);
        $readmemh({VEC, "b.hex"}, b_mem, 0, b_words - 1);
        $readmemh({VEC, "c_exp.hex"}, c_exp, 0, c_words - 1);
        $display("vectors: M=%0d N=%0d K=%0d", M, N, K);

        repeat (3) @(posedge clk);
        rst <= 0;
        @(posedge clk);

        // TODO 1, 2, 4, 5: handshakes, bus FSM, register writes, read mux
        step("1. register write / read back");
        wr(DIM_M, 8);
        wr(DIM_N, 12);
        wr(DIM_K, 5);
        check_rd(DIM_M, 8);
        check_rd(DIM_N, 12);
        check_rd(DIM_K, 5);
        check_status("after reset", 3'b000);
        check_rd(16'h0020, 0);                            // unused offset reads 0

        step("2. AW before W, slow bready, slow rready");
        axil_write(DIM_K, 77, resp, 3, 2);
        axil_read(DIM_K, got, resp, 3);
        expect_eq("DIM_K after split write", got, 77);

        // TODO 3: host port
        step("3. SPM A / B write / read back");
        wr(SPM_A + 16'h0,    32'h0403_0201);
        wr(SPM_A + 16'h4,    32'hFFFE_FDFC);
        wr(SPM_A + 16'h3FFC, 32'hA5A5_5A5A);              // last word of A
        wr(SPM_B + 16'h0,    32'h1122_3344);
        check_rd(SPM_A + 16'h0,    32'h0403_0201);
        check_rd(SPM_A + 16'h4,    32'hFFFE_FDFC);
        check_rd(SPM_A + 16'h3FFC, 32'hA5A5_5A5A);
        check_rd(SPM_B + 16'h0,    32'h1122_3344);        // B must not alias A
        axil_read(SPM_A + 16'h4, got, resp, 3);           // SPM data held while rready low
        expect_eq("SPM A[1] slow read", got, 32'hFFFE_FDFC);

        // TODO 4, 5: dims_ok, ERR, START pulse
        step("4. bad dimensions set ERR and do not start");
        wr(DIM_M, 6);   wr(DIM_N, 4);  wr(DIM_K, 4);
        wr(CTRL, START);
        check_status("M=6", 3'b100);
        wr(DIM_M, 132);                                   // 132 truncated to 7 bits is 4
        wr(CTRL, START);
        check_status("M=132", 3'b100);
        wr(DIM_M, 4);   wr(DIM_K, 0);
        wr(CTRL, START);
        check_status("K=0", 3'b100);
        wr(DIM_K, 257);
        wr(CTRL, START);
        check_status("K=257", 3'b100);

        step("5. full GEMM over the bus");
        for (int i = 0; i < a_words; i++) wr(SPM_A + 16'(4*i), a_mem[i]);
        for (int i = 0; i < b_words; i++) wr(SPM_B + 16'(4*i), b_mem[i]);
        wr(DIM_M, M);  wr(DIM_N, N);  wr(DIM_K, K);
        wr(CTRL, START | IRQ_EN);
        check_status("just after START", 3'b001);         // ERR cleared, busy
        if (irq !== 1'b0) fail("irq high while busy");
        wait_done(polls);
        check_status("after DONE", 3'b010);
        if (irq !== 1'b1) begin $display("ERROR: irq low with IRQ_EN and DONE"); errors++; end
        rd(CYCLES, got);
        $display("CYCLES = %0d (gemm_core busy for %0d)", got, exp_cycles);
        if (got + 2 < exp_cycles || got > exp_cycles + 2) begin
            $display("ERROR: CYCLES too far from %0d", exp_cycles); errors++;
        end
        for (int i = 0; i < c_words; i++)
            check_rd(SPM_C + 16'(4*i), c_exp[i]);

        step("6. C is read-only, IRQ_EN off, restart clears DONE");
        axil_write(SPM_C, 32'h1234_5678, resp);
        $display("write to C returned bresp=%b", resp);
        check_rd(SPM_C, c_exp[0]);
        wr(CTRL, 0);
        @(posedge clk);
        if (irq !== 1'b0) begin $display("ERROR: irq high with IRQ_EN = 0"); errors++; end
        wr(CTRL, START);
        check_status("restart", 3'b001);
        wait_done(polls);
        check_rd(SPM_C + 16'(4*(c_words-1)), c_exp[c_words-1]);

        step("7. SOFT_RST stops a running job");
        wr(CTRL, START);
        wr(CTRL, SOFT_RST);
        rd(STATUS, got);
        expect_eq("BUSY after SOFT_RST", {31'b0, got[0]}, 0);

        step("done");
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire
