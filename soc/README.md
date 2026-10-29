# SoC

A minimal simulation SoC: PicoRV32 (RV32IM) + RAM + the accelerator on one AXI4-Lite bus.
PicoRV32 is a git submodule in `soc/picorv32` (clone with `git clone --recursive`, or run
`git submodule update --init` after cloning).

This core was chosen because it is small, simple, and has a permissive license. It is also has access tot the AXI4-Lite bus, which is needed to control the accelerator. The core is not intended for production use.
You can read more about PicoRV32 at [https://github.com/yosyshq/picorv32](PicoRV32 GitHub). 

## CPU configuration

Use the `picorv32_axi` wrapper from `picorv32/picorv32.v` with:

| Parameter         | Value              | Why                                   |
|-------------------|--------------------|---------------------------------------|
| `ENABLE_MUL`      | 1                  | RV32**M** (multiply)                  |
| `ENABLE_DIV`      | 1                  | RV32**M** (divide)                    |
| `ENABLE_COUNTERS` | 1 (default)        | enables support for`rdcycle` to benchmark|
| `PROGADDR_RESET`  | `32'h0000_0000`    | Boot from the start of RAM            |
| `STACKADDR`       | `32'h0002_0000`    | Top of RAM                            |
| `ENABLE_IRQ`      | 0 for now          | Poll `STATUS.DONE` first, IRQ later   |

Reset is active-low (`resetn`). `trap` goes high on an illegal instruction or bus error, so
end the simulation with an error when it rises.

## Memory map

| Base          | Size   | Slave       | Content                                       |
|---------------|--------|-------------|-----------------------------------------------|
| `0x0000_0000` | 128 KB | `axil_ram`  | Code, stack, and A/B/C for the software baseline |
| `0x1000_0000` | 64 KB  | `gemm_top`  | Accelerator (register map in docs/SPECS.md)   |
| `0x2000_0000` | 16 B   | `sim_ctrl`  | `+0x0` write: print char, `+0x4` write: exit with code |

RAM size: a 64×256 A, a 256×64 B and a 64×64 INT32 C are 16 KB each, so the baseline needs
48 KB of data plus code and stack.

## TODO TO WRITE THE SOC BINDINGS