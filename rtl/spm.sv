`timescale 1ns/1ps
`default_nettype none

// Single-port scratchpad, synchronous read (1-cycle latency).
// Coded in the style synthesis maps to block RAM: no reset on contents.
module spm #(
    parameter int DATA_W    = 32,
    parameter int DEPTH     = 4096,
    parameter int ADDR_W    = $clog2(DEPTH),  // derived, don't override
    parameter     INIT_FILE = ""              // optional $readmemh file (simulation)
) (
    input  logic              clk,
    input  logic              en,
    input  logic              we,
    input  logic [ADDR_W-1:0] addr,   // word address
    input  logic [DATA_W-1:0] wdata,
    output logic [DATA_W-1:0] rdata   // valid the cycle after a read, held otherwise
);

    logic [DATA_W-1:0] mem [DEPTH];

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always_ff @(posedge clk) begin
        if (en) begin
            if (we) mem[addr] <= wdata;
            else    rdata     <= mem[addr];
        end
    end

endmodule

`default_nettype wire
