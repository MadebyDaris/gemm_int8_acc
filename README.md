# GEMM INT8 Accelerator

A 4×4 systolic-array accelerator for INT8 matrix multiplication
(`C = A · B`, INT8 in, INT32 out), attached to an RV32IM SoC over AXI4-Lite,
and benchmarked against a software implementation (cycles, area, Fmax, energy).

- [docs/SPECS.md](docs/SPECS.md): specification and architecture
- [soc/README.md](soc/README.md): SoC around PicoRV32, memory map, firmware

## Layout

```
docs/    specification and architecture
model/   Python golden model and test-vector generator
rtl/     hardware sources
tb/      testbenches
soc/     SoC integration and firmware (PicoRV32 submodule in soc/picorv32)
syn/     synthesis scripts and reports
```

## Quick start

```
git clone --recursive github.com/madebydaris/gemm_int8_acc     # or: git submodule update --init
make test                        # model self-test + all testbenches
make sim-tile K=64 MODE=random   # one model-driven test
make vectors M=8 N=8 K=32        # generate SPM images in build/vec/
```

Requires `iverilog`, `verilator`, `yosys`, `python3` + `numpy`.
