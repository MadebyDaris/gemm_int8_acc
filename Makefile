RTL := $(wildcard rtl/*.sv)

# Test-vector parameters (make vectors M=8 N=8 K=64 MODE=random SEED=3)
M    ?= 4
N    ?= 4
K    ?= 16
MODE ?= random
SEED ?= 1

.PHONY: vectors model-test test clean

vectors:
	python3 model/gemm_model.py --m $(M) --n $(N) --k $(K) --mode $(MODE) --seed $(SEED) --out build/vec

model-test:
	python3 model/gemm_model.py --selftest

sim-%:                         # make sim-pe   (extra flags: IVFLAGS="-Ptb_pe_array.R=2")
	@mkdir -p build
	iverilog -g2012 -Wall $(IVFLAGS) -o build/tb_$*.vvp tb/tb_$*.sv $(RTL)
	vvp -n build/tb_$*.vvp | tee build/tb_$*.log
	@grep -q "TEST PASSED" build/tb_$*.log

sim-tile sim-gemm_core: vectors   # model-driven tests need fresh vectors

lint-%:                        # make lint-pe
	verilator --lint-only -Wall -Irtl rtl/$*.sv

syn-%:                         # make syn-pe
	yosys -q -p "read_verilog -sv $(RTL); synth -top $*; tee -o /dev/stdout stat"

test: model-test               # full regression
	$(MAKE) sim-pe sim-skew sim-spm sim-pe_array
	$(MAKE) sim-pe_array IVFLAGS="-Ptb_pe_array.R=2 -Ptb_pe_array.C=2"
	$(MAKE) sim-tile K=1
	$(MAKE) sim-tile K=256 MODE=min
	$(MAKE) sim-tile K=256 MODE=minmax
	$(MAKE) sim-tile K=97 SEED=7

clean:
	rm -rf build
