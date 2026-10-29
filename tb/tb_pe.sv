`timescale 1ns/1ps
// Unit test: PE MAC, clear and pass-through, against a running sum.
`default_nettype none
module tb_pe;
  initial begin $dumpfile("build/tb_pe.vcd"); $dumpvars(0, tb_pe); end
  logic clk = 0, rst = 1, clear = 0; always #5 clk = ~clk;
  logic signed [7:0] a, b, ao, bo; logic signed [31:0] acc;
  pe dut(.clk, .rst, .clear, .a_in(a), .b_in(b), .a_out(ao), .b_out(bo), .acc);
  int errors = 0; longint ref_acc = 0;
  logic signed [7:0] pa, pb;
  task automatic step(input logic signed [7:0] x, y, input logic clr);
    a <= x; b <= y; clear <= clr; pa = x; pb = y;
    @(posedge clk); #1;
    ref_acc = clr ? 0 : ref_acc + pa * pb;
    if (acc !== ref_acc[31:0]) begin errors++; $display("ERR acc %0d exp %0d (a=%0d b=%0d)", acc, ref_acc, pa, pb); end
    if (ao !== pa || bo !== pb) begin errors++; $display("ERR passthru"); end
  endtask
  initial begin
    a = 0; b = 0; repeat (2) @(posedge clk); rst <= 0; @(posedge clk); #1;
    step(-128, -128, 0); step(127, -128, 0); step(-1, -1, 0); step(-1, 1, 0); step(0, 99, 0);
    step(5, 5, 1);                         // clear wins
    step(-128, -128, 0); step(-128, -128, 0);
    for (int i = 0; i < 5000; i++) step($urandom, $urandom, ($urandom % 300) == 0);
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
