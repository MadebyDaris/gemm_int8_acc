`timescale 1ns/1ps
`default_nettype none

// GEMM controller: walks the 4x4 output tiles and sequences CLEAR / FEED / FLUSH / DRAIN.
// Spec: docs/SPECS.md (tile schedule).
//
// Per tile (cycle 0 = first FEED cycle):
//   CLEAR  1 cycle   clear = 1, load start addresses of the tile
//   FEED   K cycles  read A/B word k = 0 .. K-1 (data arrives one cycle later)
//   FLUSH  7 cycles  last product reaches PE(3,3) at cycle K+6
//   DRAIN 16 cycles  write acc[d] to C[i0 + d/4][j0 + d%4]
module gemm_ctrl #(
    parameter int MAX_M  = 64,
    parameter int MAX_N  = 64,
    parameter int MAX_K  = 256,
    parameter int MN_W   = $clog2((MAX_M > MAX_N ? MAX_M : MAX_N) + 1),
    parameter int K_W    = $clog2(MAX_K+1),
    parameter int ADDR_W = 12
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              start,
    input  logic [MN_W-1:0]   m,
    input  logic [MN_W-1:0]   n,
    input  logic [K_W-1:0]    k,

    output logic              done,
    output logic              busy,
    output logic              a_en,
    output logic              b_en,
    output logic              c_en,

    output logic              feed_valid,
    output logic              clear,
    output logic [3:0]        drain_sel,

    output logic [ADDR_W-1:0] a_addr,
    output logic [ADDR_W-1:0] b_addr,
    output logic [ADDR_W-1:0] c_addr
);

    localparam int FLUSH_CYCLES = 7;   // 1 SPM read latency + 3 skew + 3 array hops

    typedef enum logic [2:0] {
        IDLE,
        CLEAR,
        FEED,
        FLUSH,
        DRAIN,
        DONE
    } state_t;
    state_t state, next_state;

    // Job dimensions, latched on start
    logic [MN_W-1:0] m_q, n_q;
    logic [K_W-1:0]  k_q;

    // Loop counters
    logic [3:0]      ti, tj;         // tile row / column (i0 = 4*ti, j0 = 4*tj)
    logic [K_W-1:0]  k_cnt;          // FEED: current k
    logic [2:0]      flush_cnt;      // FLUSH: 0 .. FLUSH_CYCLES-1
    logic [3:0]      drain_cnt;      // DRAIN: accumulator index d = 4*r + c

    // Address registers (incremented, no multipliers)
    logic [ADDR_W-1:0] a_addr_q;     // k*(M/4) + ti
    logic [ADDR_W-1:0] b_addr_q;     // k*(N/4) + tj
    logic [ADDR_W-1:0] tile_row;     // i0*N: C address of the first row of the tile
    logic [ADDR_W-1:0] drain_row;    // (i0 + r)*N: C address of the row being drained

    // Tiles per dimension
    logic [MN_W-1:0] tiles_m, tiles_n;
    assign tiles_m = m_q >> 2;
    assign tiles_n = n_q >> 2;

    logic last_k, last_flush, last_drain, last_tj, last_tile;
    assign last_k     = (k_cnt == k_q - 1'b1);
    assign last_flush = (flush_cnt == 3'(FLUSH_CYCLES - 1));
    assign last_drain = (drain_cnt == 4'd15);
    assign last_tj    = (MN_W'(tj) == tiles_n - 1'b1);
    assign last_tile  = last_tj && (MN_W'(ti) == tiles_m - 1'b1);

    // ------------------------------------------------------------------
    // 1. State register
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) state <= IDLE;
        else     state <= next_state;
    end

    // ------------------------------------------------------------------
    // 2. Next-state logic
    // ------------------------------------------------------------------
    always_comb begin
        next_state = state;
        case (state)
            IDLE:    if (start)      next_state = CLEAR;
            CLEAR:                   next_state = FEED;
            FEED:    if (last_k)     next_state = FLUSH;
            FLUSH:   if (last_flush) next_state = DRAIN;
            DRAIN:   if (last_drain) begin
                         if (last_tile) next_state = DONE;
                         else           next_state = CLEAR;
                     end
            DONE:                    next_state = IDLE;
            default:                 next_state = IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // 3. Counters and address registers
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            m_q        <= '0;
            n_q        <= '0;
            k_q        <= '0;
            ti         <= '0;
            tj         <= '0;
            k_cnt      <= '0;
            flush_cnt  <= '0;
            drain_cnt  <= '0;
            a_addr_q   <= '0;
            b_addr_q   <= '0;
            tile_row   <= '0;
            drain_row  <= '0;
        end else begin
            case (state)
                IDLE: if (start) begin
                    m_q      <= m;
                    n_q      <= n;
                    k_q      <= k;
                    ti       <= '0;
                    tj       <= '0;
                    tile_row <= '0;
                end

                CLEAR: begin
                    k_cnt     <= '0;
                    flush_cnt <= '0;
                    drain_cnt <= '0;
                    a_addr_q  <= ADDR_W'(ti);
                    b_addr_q  <= ADDR_W'(tj);
                    drain_row <= tile_row;
                end

                FEED: begin
                    k_cnt    <= k_cnt + 1'b1;
                    a_addr_q <= a_addr_q + ADDR_W'(tiles_m);
                    b_addr_q <= b_addr_q + ADDR_W'(tiles_n);
                end

                FLUSH: flush_cnt <= flush_cnt + 1'b1;

                DRAIN: begin
                    drain_cnt <= drain_cnt + 1'b1;
                    // after the 4th value of a row, move down one row of C
                    if (drain_cnt[1:0] == 2'd3)
                        drain_row <= drain_row + ADDR_W'(n_q);
                    // after the last value, move to the next tile
                    if (last_drain && !last_tile) begin
                        if (last_tj) begin
                            tj       <= '0;
                            ti       <= ti + 1'b1;
                            tile_row <= tile_row + (ADDR_W'(n_q) << 2);
                        end else begin
                            tj       <= tj + 1'b1;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

    // feed_valid follows the data, which arrives one cycle after the read
    always_ff @(posedge clk) begin
        if (rst) feed_valid <= 1'b0;
        else     feed_valid <= a_en;
    end

    // ------------------------------------------------------------------
    // 4. Outputs
    // ------------------------------------------------------------------
    assign busy      = (state != IDLE);
    assign done      = (state == DONE);
    assign clear     = (state == CLEAR);
    assign a_en      = (state == FEED);
    assign b_en      = (state == FEED);
    assign a_addr    = a_addr_q;
    assign b_addr    = b_addr_q;
    assign c_en      = (state == DRAIN);
    assign drain_sel = drain_cnt;
    assign c_addr    = drain_row + ADDR_W'({tj, 2'b00}) + ADDR_W'(drain_cnt[1:0]);

endmodule

`default_nettype wire
