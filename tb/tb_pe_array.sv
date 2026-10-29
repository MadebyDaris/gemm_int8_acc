`timescale 1ns/1ps
// Unit test: pe_array with skew applied in the TB, and with the real skew modules.
// Reference is computed in the TB. Override size with -Ptb_pe_array.R=2 -Ptb_pe_array.C=2.
`default_nettype none
module tb_pe_array;
  initial begin $dumpfile("build/tb_pe_array.vcd"); $dumpvars(0, tb_pe_array); end
  parameter int R = 4, C = 4;
  localparam int KMAX = 256;
  logic clk = 0, rst = 1, clear = 0; always #5 clk = ~clk;
  logic [R*8-1:0] a_in = 0; logic [C*8-1:0] b_in = 0; logic [R*C*32-1:0] acc, acc_s;
  pe_array #(.ROWS(R), .COLS(C)) dut(.clk, .rst, .clear, .a_in, .b_in, .acc);
  // second copy fed through the real skew modules with unskewed words
  logic v = 0; logic [R*8-1:0] aw = 0, a_sk; logic [C*8-1:0] bw = 0, b_sk;
  skew #(.LANES(R)) sa(.clk, .rst, .in_valid(v), .in_data(aw), .out_data(a_sk));
  skew #(.LANES(C)) sb(.clk, .rst, .in_valid(v), .in_data(bw), .out_data(b_sk));
  pe_array #(.ROWS(R), .COLS(C)) dut_s(.clk, .rst, .clear, .a_in(a_sk), .b_in(b_sk), .acc(acc_s));

  logic signed [7:0] A [R][KMAX], B [KMAX][C];
  int errors = 0, Kr;

  task automatic run_tile(input int K, input string name);
    int t;
    longint exp;
    @(negedge clk); clear = 1; a_in = 0; b_in = 0; v = 0;
    @(negedge clk); clear = 0;
    for (t = 0; t < K + R + C; t++) begin
      for (int r = 0; r < R; r++) a_in[r*8 +: 8] = (t - r >= 0 && t - r < K) ? A[r][t-r] : 8'sd0;
      for (int c = 0; c < C; c++) b_in[c*8 +: 8] = (t - c >= 0 && t - c < K) ? B[t-c][c] : 8'sd0;
      v = t < K;
      for (int r = 0; r < R; r++) aw[r*8 +: 8] = t < K ? A[r][t] : $urandom;  // garbage when !v
      for (int c = 0; c < C; c++) bw[c*8 +: 8] = t < K ? B[t][c] : $urandom;
      @(negedge clk);
    end
    for (int r = 0; r < R; r++) for (int c = 0; c < C; c++) begin
      exp = 0;
      for (int k = 0; k < K; k++) exp += A[r][k] * B[k][c];
      if ($signed(acc[(r*C+c)*32 +: 32]) != exp || $signed(acc_s[(r*C+c)*32 +: 32]) != exp) begin
        errors++;
        if (errors < 10) $display("ERR %s K=%0d PE(%0d,%0d) got %0d / %0d(skew) exp %0d", name, K, r, c,
                                  $signed(acc[(r*C+c)*32 +: 32]), $signed(acc_s[(r*C+c)*32 +: 32]), exp);
      end
    end
  endtask

  task automatic fill(input int mode, input int K);
    for (int k = 0; k < K; k++) begin
      for (int r = 0; r < R; r++) A[r][k] = mode == 0 ? $urandom : mode == 1 ? -128 : mode == 2 ? 127 : -128;
      for (int c = 0; c < C; c++) B[k][c] = mode == 0 ? $urandom : mode == 1 ? -128 : mode == 2 ? 127 : 127;
    end
  endtask

  initial begin
    repeat (2) @(posedge clk); rst <= 0;
    if (R == 2 && C == 2) begin
      A[0][0] = 1; A[0][1] = 2; A[1][0] = 3; A[1][1] = 4;
      B[0][0] = 5; B[0][1] = 6; B[1][0] = 7; B[1][1] = 8;
      run_tile(2, "worked-example");
      $display("worked example: %0d %0d %0d %0d", $signed(acc[31:0]), $signed(acc[63:32]), $signed(acc[95:64]), $signed(acc[127:96]));
    end
    fill(1, KMAX); run_tile(KMAX, "all -128");
    fill(2, KMAX); run_tile(KMAX, "all 127");
    fill(3, KMAX); run_tile(KMAX, "-128 x 127");
    fill(0, 1);    run_tile(1, "K=1");
    for (int n = 0; n < 50; n++) begin
      Kr = 1 + $urandom % KMAX;
      fill(0, Kr); run_tile(Kr, "random");     // back to back, clear between tiles
    end
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
