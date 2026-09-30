IVERILOG ?= iverilog
RTL   := rtl/regfile.sv rtl/alu.sv rtl/mdu.sv rtl/branch_predictor.sv rtl/core.sv rtl/soc_top.sv
TESTS := basic sort

.PHONY: all test bp_compare wave clean
all: test

build/sim: $(RTL) tb/tb_core.sv rtl/rv_defs.vh
	@mkdir -p build
	$(IVERILOG) -g2012 -Irtl -o $@ tb/tb_core.sv $(RTL)

build/sim_nobp: $(RTL) tb/tb_core.sv rtl/rv_defs.vh
	@mkdir -p build
	$(IVERILOG) -g2012 -Irtl -DNO_BP -o $@ tb/tb_core.sv $(RTL)

build/%.hex: sw/tests/%.s sw/asm.py
	@mkdir -p build
	python3 sw/asm.py $< -o $@ -l > build/$*.lst

test: build/sim $(TESTS:%=build/%.hex)
	@rc=0; for t in $(TESTS); do \
	  echo "=== $$t"; vvp -n build/sim +hex=build/$$t.hex | tee build/$$t.log; \
	  grep -q "RESULT: PASS" build/$$t.log || rc=1; \
	done; exit $$rc

bp_compare: build/sim build/sim_nobp build/sort.hex
	@echo "--- with 2-bit predictor ---";   vvp -n build/sim      +hex=build/sort.hex | tail -3
	@echo "--- static not-taken ---";       vvp -n build/sim_nobp +hex=build/sort.hex | tail -3

wave: build/sim build/basic.hex
	vvp -n build/sim +hex=build/basic.hex +vcd
	@echo "open build/sim.vcd in GTKWave"

clean:
	rm -rf build
