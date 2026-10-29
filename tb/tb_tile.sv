`timescale 1ns/1ps
// Model-driven test: one 4x4 tile through skew + pe_array, vectors from model/gemm_model.py.
// With M = N = 4 the SPM images are exactly the words the skew feeders take:
//   a.hex word k = A[0..3][k],  b.hex word k = B[k][0..3],  c_exp.hex = 16 results row-major.
// Run: make sim-tile K=37 MODE=random
`default_nettype none
module tb_tile;
  initial begin $dumpfile("build/tb_tile.vcd"); $dumpvars(0, tb_tile); end

  localparam int R = 4, C = 4, KMAX = 256;
  localparam string VEC = "build/vec/";

  logic clk = 0, rst = 1, clear = 0;
  always #5 clk = ~clk;

  logic              v = 0;
  logic [R*8-1:0]    a_word = 0, a_sk;
  logic [C*8-1:0]    b_word = 0, b_sk;
  logic [R*C*32-1:0] acc;

  skew #(.LANES(R)) u_skew_a (.clk, .rst, .in_valid(v), .in_data(a_word), .out_data(a_sk));
  skew #(.LANES(C)) u_skew_b (.clk, .rst, .in_valid(v), .in_data(b_word), .out_data(b_sk));
  pe_array #(.ROWS(R), .COLS(C)) dut (.clk, .rst, .clear, .a_in(a_sk), .b_in(b_sk), .acc);

  logic [31:0] dims [3];
  logic [31:0] a_mem [KMAX], b_mem [KMAX], c_exp [R*C];
  int K, errors = 0;

  initial begin
    $readmemh({VEC, "dims.hex"}, dims);
    if (dims[0] != R || dims[1] != C) begin
      $display("TEST FAILED: tb_tile needs M=%0d N=%0d vectors, got M=%0d N=%0d", R, C, dims[0], dims[1]);
      $finish;
    end
    K = dims[2];
    $readmemh({VEC, "a.hex"}, a_mem, 0, K-1);
    $readmemh({VEC, "b.hex"}, b_mem, 0, K-1);
    $readmemh({VEC, "c_exp.hex"}, c_exp);

    repeat (2) @(posedge clk);
    @(negedge clk); rst = 0; clear = 1;
    @(negedge clk); clear = 0;

    // K valid words, then zeros until the last PE is done (K + R + C - 2 cycles in total)
    for (int t = 0; t < K + R + C - 1; t++) begin
      v      = t < K;
      a_word = v ? a_mem[t] : '0;
      b_word = v ? b_mem[t] : '0;
      @(negedge clk);
    end

    for (int i = 0; i < R*C; i++)
      if (acc[i*32 +: 32] !== c_exp[i]) begin
        errors++;
        $display("ERROR C[%0d][%0d]: got %0d exp %0d", i / C, i % C, $signed(acc[i*32 +: 32]), $signed(c_exp[i]));
      end

    if (errors == 0) $display("TEST PASSED (K=%0d)", K);
    else             $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
