# GEMM INT8 Accelerator: Specification & Architecture

## Scope

Computes `C[M×N] = A[M×K] · B[K×N]` with signed INT8 inputs and INT32 outputs.
The accelerator is a memory-mapped peripheral of an RV32IM SoC.

**In scope (v1)**

- Signed INT8 × INT8 multiply, INT32 accumulate
- 4×4 output-stationary systolic array
- Programmable M, N, K
- On-chip scratchpads for A, B, C
- AXI4-Lite slave for control registers and buffer access (the CPU fills buffers over MMIO)

**Out of scope**

- Floating point, convolution, requantization / activation functions
- Partial tiles: M and N must be multiples of 4 (software zero-pads)


| Parameter      | Value                                            |
|----------------|--------------------------------------------------|
| Array          | 4×4 PEs, output-stationary                       |
| Operands       | INT8, two's complement (−128 … 127)              |
| Accumulator    | INT32                                            |
| M, N           | 4 … 64, multiple of 4                            |
| K              | 1 … 256                                          |
| Clock          | 100 MHz                                          |
| Peak throughput| 16 MAC/cycle = 1.6 GMAC/s (3.2 GOPS)             |
| Host bus       | 32-bit AXI4-Lite slave                           |
| CPU            | RV32IM                                           |

**Overflow:** the largest product is (−128)·(−128) = 2^14, so for K ≤ 256 the
sum is bounded by 2^22. INT32 cannot overflow within the supported range.

## Block Diagram

```
            AXI4-Lite (32-bit)
                  │
        ┌─────────▼──────────┐
        │  AXI4-Lite slave   │
        │  + register file   │──── IRQ
        └──┬──────┬──────┬───┘
           │      │      │   (CPU access to buffers when idle)
      ┌────▼─┐ ┌──▼───┐ ┌▼─────┐
      │ SPM A│ │ SPM B│ │ SPM C│
      │ 16 KB│ │ 16 KB│ │ 16 KB│
      └──┬───┘ └──┬───┘ └▲─────┘
         │        │      │
      ┌──▼────────▼──┐   │
      │ Skew feeders │   │        ┌────────────┐
      └──┬────────┬──┘   │        │ Controller │
         │ A rows │ B cols        │    FSM     │── drives all blocks
      ┌──▼────────▼──┐   │        └────────────┘
      │  4×4 PE array├───┘ drain (16 × INT32)
      └──────────────┘
```

| Block            | Role                                                              |
|------------------|-------------------------------------------------------------------|
| AXI4-Lite slave  | Decodes register and buffer windows                               |
| Register file    | Control, status, dimensions, cycle counter                        |
| SPM A / B / C    | Single-port, 32-bit wide SRAMs                                    |
| Controller FSM   | Loops over 4×4 output tiles, sequences feed / flush / drain        |
| Skew feeders     | Delay row `r` of A by `r` cycles and column `c` of B by `c` cycles |
| PE array         | 16 MAC units, each owns one C accumulator                         |
| Drain            | Writes the 16 accumulators of a finished tile into SPM C          |

## Dataflow

**Output-stationary:** each PE(r,c) accumulates one element `C[i0+r][j0+c]`.
A values move left → right, B values move top → bottom, one PE per cycle.

```
            B[k][j0] B[k][j0+1] B[k][j0+2] B[k][j0+3]
               ↓         ↓          ↓          ↓
A[i0  ][k] → PE00  →  PE01   →   PE02   →   PE03
A[i0+1][k] → PE10  →  PE11   →   PE12   →   PE13
A[i0+2][k] → PE20  →  PE21   →   PE22   →   PE23
A[i0+3][k] → PE30  →  PE31   →   PE32   →   PE33
```

**Processing Element**

```
         b_in (8)
            │
a_in (8) ─►[×]─►[+ acc (32)]
            │        
   a_out ◄──┘  b_out  (both registered)
```

- `acc += a_in * b_in` every cycle (feeders inject 0 when idle)
- `clear` resets `acc` at the start of a tile
- `a_out`, `b_out` are `a_in`, `b_in` delayed by one cycle

**Tile schedule** (controller):

```
for i0 in 0..M step 4:
  for j0 in 0..N step 4:
    clear accumulators          # 1 cycle
    for k in 0..K-1:            # 1 word from SPM A + 1 word from SPM B per cycle
      feed A[i0:i0+4][k], B[k][j0:j0+4]
    flush                       # 7 cycles (1 SPM latency + 6 skew/array)
    drain 16 results to SPM C   # 16 cycles
```

Cycles per tile = `K + 24`. Full 64×64×256 GEMM = 256 tiles × 280 ≈ 71.7k cycles (~91 % of the 65.5k ideal).

## Memory Layout

Each SPM is 32 bits wide so that one read delivers 4 INT8 values, one per array row/column.

| Buffer | Content | Layout                       | Size              |
|--------|---------|------------------------------|-------------------|
| A      | INT8    | **column-major** (stored as Aᵀ, K×M) | 64·256 B = 16 KB |
| B      | INT8    | row-major (K×N)              | 256·64 B = 16 KB  |
| C      | INT32   | row-major (M×N)              | 64·64·4 B = 16 KB |

- A is stored transposed so `A[i0..i0+3][k]` is one aligned 32-bit word.
- B row-major means `B[k][j0..j0+3]` is one aligned 32-bit word.
- Byte 0 of a word = lowest index (little-endian, matches RV32).

## Register Map

Base address is set by the SoC. Accelerator window is 64 KB.

| Offset            | Name     | Access | Description                                         |
|-------------------|----------|--------|-----------------------------------------------------|
| `0x0000`          | CTRL     | W      | bit0 `START`, bit1 `SOFT_RST`, bit2 `IRQ_EN`        |
| `0x0004`          | STATUS   | R      | bit0 `BUSY`, bit1 `DONE` (cleared on START), bit2 `ERR` |
| `0x0008`          | DIM_M    | RW     | M                                                   |
| `0x000C`          | DIM_N    | RW     | N                                                   |
| `0x0010`          | DIM_K    | RW     | K                                                   |
| `0x0014`          | CYCLES   | R      | Cycles from START to DONE                           |
| `0x4000 – 0x7FFF` | SPM A    | RW     | A buffer window                                     |
| `0x8000 – 0xBFFF` | SPM B    | RW     | B buffer window                                     |
| `0xC000 – 0xFFFF` | SPM C    | R      | C buffer window                                     |

- `ERR` is set (and the job is not started) if M or N is not a multiple of 4, or any dimension is 0 or above its maximum.
- Buffer access while `BUSY` is undefined; software must wait for `DONE`.

## References

- H. T. Kung, *Why Systolic Architectures?*, IEEE Computer 15(1), 1982
- N. Jouppi et al., *In-Datacenter Performance Analysis of a Tensor Processing Unit*, ISCA 2017, [arXiv:1704.04760](https://arxiv.org/abs/1704.04760)
- B. Jacob et al., *Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only Inference*, CVPR 2018, [arXiv:1712.05877](https://arxiv.org/abs/1712.05877)
