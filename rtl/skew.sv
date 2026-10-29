`timescale 1ns/1ps
`default_nettype none

// Input skew feeder: lane i of out_data = lane i of in_data from i cycles ago.
// in_valid = 0 pushes zeros, so idle cycles never reach the array as garbage.
module skew #(
    parameter int LANES  = 4,
    parameter int DATA_W = 8
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    in_valid,
    input  logic [LANES*DATA_W-1:0] in_data,
    output logic [LANES*DATA_W-1:0] out_data
);

    for (genvar i = 0; i < LANES; i++) begin : gen_lane
        logic [DATA_W-1:0] lane_in;
        assign lane_in = in_valid ? in_data[i*DATA_W +: DATA_W] : '0;

        if (i == 0) begin : gen_wire
            assign out_data[0 +: DATA_W] = lane_in;
        end else begin : gen_delay
            // sr[0] is the newest value, sr[i-1] the oldest
            logic [DATA_W-1:0] sr [i];

            always_ff @(posedge clk) begin
                if (rst) begin
                    for (int k = 0; k < i; k++) sr[k] <= '0;
                end else begin
                    sr[0] <= lane_in;
                    for (int k = 1; k < i; k++) sr[k] <= sr[k-1];
                end
            end

            assign out_data[i*DATA_W +: DATA_W] = sr[i-1];
        end
    end

endmodule

`default_nettype wire
