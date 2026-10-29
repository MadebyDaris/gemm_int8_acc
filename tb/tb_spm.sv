`timescale 1ns/1ps
// Unit test: random read/write vs a model, 1-cycle latency, hold, INIT_FILE.
`default_nettype none
module tb_spm;
  initial begin $dumpfile("build/tb_spm.vcd"); $dumpvars(0, tb_spm); end
  logic clk = 0, en = 0, we = 0; always #5 clk = ~clk;
  logic [7:0] addr = 0; logic [31:0] wdata = 0, rdata, ri;
  spm #(.DEPTH(256)) dut(.clk, .en, .we, .addr, .wdata, .rdata);
  spm #(.DEPTH(4), .INIT_FILE("tb/data/spm_init.hex")) dut_i(.clk, .en(1'b1), .we(1'b0), .addr(addr[1:0]), .wdata('0), .rdata(ri));
  logic [31:0] model [256], exp; int errors = 0;
  initial begin
    for (int i = 0; i < 256; i++) begin
      @(negedge clk); en = 1; we = 1; addr = i; wdata = $urandom; model[i] = wdata;
    end
    for (int n = 0; n < 3000; n++) begin
      @(negedge clk);
      en = $urandom % 2; we = $urandom % 4 == 0; addr = $urandom; wdata = $urandom;
      if (en && we) model[addr] = wdata;
      if (en && !we) begin
        exp = model[addr];
        @(posedge clk); #1;
        if (rdata !== exp) begin errors++; $display("ERR rd %h got %h exp %h", addr, rdata, exp); end
        // hold while idle
        @(negedge clk); en = 0; @(posedge clk); #1;
        if (rdata !== exp) begin errors++; $display("ERR hold"); end
      end
    end
    // latency: new address must not appear same cycle
    @(negedge clk); en = 1; we = 0; addr = 1; @(posedge clk); @(negedge clk); addr = 2; #1;
    if (rdata !== model[1]) begin errors++; $display("ERR latency"); end
    // init file
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); addr = i; @(posedge clk); #1;
      if (ri !== 32'h1111_1111 * (i + 1)) begin errors++; $display("ERR init %0d %h", i, ri); end
    end
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
