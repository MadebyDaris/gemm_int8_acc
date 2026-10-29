`timescale 1ns/1ps
`default_nettype none

// ROWS x COLS output-stationary systolic array.
// A flows left -> right, B flows top -> bottom; inputs must already be skewed.
module pe_array #(
    parameter int ROWS   = 4,
    parameter int COLS   = 4,
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       clear,
    input  logic [ROWS*DATA_W-1:0]     a_in,  // lane r -> left edge of row r
    input  logic [COLS*DATA_W-1:0]     b_in,  // lane c -> top edge of column c
    output logic [ROWS*COLS*ACC_W-1:0] acc    // lane r*COLS+c = PE(r,c)
);

    // a_h[r][c] enters PE(r,c) from the left, b_v[r][c] enters it from above.
    // The extra column / row is driven by the last PEs and never read.
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [DATA_W-1:0] a_h [ROWS][COLS+1];
    logic signed [DATA_W-1:0] b_v [ROWS+1][COLS];
    /* verilator lint_on UNUSEDSIGNAL */

    for (genvar r = 0; r < ROWS; r++) begin : gen_a_edge
        assign a_h[r][0] = a_in[r*DATA_W +: DATA_W];
    end

    for (genvar c = 0; c < COLS; c++) begin : gen_b_edge
        assign b_v[0][c] = b_in[c*DATA_W +: DATA_W];
    end

    for (genvar r = 0; r < ROWS; r++) begin : gen_row
        for (genvar c = 0; c < COLS; c++) begin : gen_col
            pe #(
                .DATA_W (DATA_W),
                .ACC_W  (ACC_W)
            ) u_pe (
                .clk   (clk),
                .rst   (rst),
                .clear (clear),
                .a_in  (a_h[r][c]),
                .b_in  (b_v[r][c]),
                .a_out (a_h[r][c+1]),
                .b_out (b_v[r+1][c]),
                .acc   (acc[(r*COLS+c)*ACC_W +: ACC_W])
            );
        end
    end

endmodule

`default_nettype wire
