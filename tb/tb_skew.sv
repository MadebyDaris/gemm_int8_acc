`timescale 1ns/1ps
// Unit test: lane i delayed by i cycles, in_valid=0 pushes zeros, reset.
`default_nettype none
module tb_skew;
  initial begin $dumpfile("build/tb_skew.vcd"); $dumpvars(0, tb_skew); end
  localparam int L = 4;
  logic clk = 0, rst = 1, v = 0; always #5 clk = ~clk;
  logic [L*8-1:0] din = 0, dout;
  skew #(.LANES(L)) dut(.clk, .rst, .in_valid(v), .in_data(din), .out_data(dout));
  logic [L*8-1:0] hist [L];   // hist[j] = effective input j cycles ago
  logic [L*8-1:0] h;
  int errors = 0;
  initial begin
    repeat (2) @(posedge clk); rst <= 0;
    for (int i = 0; i < L; i++) hist[i] = '0;
    for (int n = 0; n < 2000; n++) begin
      @(negedge clk);
      v = ($urandom % 4) != 0; din = $urandom;
      for (int j = L-1; j > 0; j--) hist[j] = hist[j-1];
      hist[0] = v ? din : '0;
      #1;
      for (int i = 0; i < L; i++) begin
        h = hist[i];
        if (dout[i*8 +: 8] !== h[i*8 +: 8]) begin
          errors++; if (errors < 5) $display("ERR n=%0d lane %0d got %h exp %h", n, i, dout[i*8 +: 8], h[i*8 +: 8]);
        end
      end
    end
    // reset mid-stream: all delayed lanes return to 0
    @(negedge clk); rst = 1; v = 0; @(negedge clk); rst = 0;
    if (dout !== '0) begin errors++; $display("ERR after reset %h", dout); end
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
