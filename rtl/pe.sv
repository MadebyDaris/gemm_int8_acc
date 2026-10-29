`timescale 1ns/1ps
`default_nettype none

// Processing element: one MAC + two pass-through registers.
// Owns one C element: acc <= acc + a_in * b_in every cycle.
module pe #(
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32
) (
    input  logic                     clk,
    input  logic                     rst,
    input  logic                     clear,  // start of a new tile: acc <= 0
    input  logic signed [DATA_W-1:0] a_in,   // from the left
    input  logic signed [DATA_W-1:0] b_in,   // from above
    output logic signed [DATA_W-1:0] a_out,  // to the right, 1 cycle later
    output logic signed [DATA_W-1:0] b_out,  // downward, 1 cycle later
    output logic signed [ACC_W-1:0]  acc
);

    // Full-precision product, sign-extended explicitly before the add.
    logic signed [2*DATA_W-1:0] prod;
    assign prod = a_in * b_in;

    always_ff @(posedge clk) begin
        if (rst) begin
            a_out <= '0;
            b_out <= '0;
            acc   <= '0;
        end else begin
            a_out <= a_in;
            b_out <= b_in;
            if (clear) acc <= '0;
            else       acc <= acc + ACC_W'(prod);
        end
    end

endmodule

`default_nettype wire
