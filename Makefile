# Root Makefile — chi_to_cxl_bridge
# Standard DV gate targets consistent with other RTL repos in this workspace
# (see ../DV_STANDARDS.md). Delegates to verification/directed/ (Icarus sim) and
# verification/formal/ (SymbiYosys); coverage / sva run Verilator from the root.

SBY       ?= sby
VERILATOR ?= verilator

VERILATOR_ROOT := $(shell v=$$(command -v verilator 2>/dev/null); [ -n "$$v" ] && realpath "$$(dirname "$$v")/../share/verilator")
VERILATOR_INC  := $(VERILATOR_ROOT)/include
VERILATOR_CPP  := $(VERILATOR_INC)/verilated.cpp $(VERILATOR_INC)/verilated_cov.cpp \
                  $(VERILATOR_INC)/verilated_threads.cpp

# Core RTL source list — single source of truth (see rtl.f). Verilator runs from
# the repo root, so the root-relative paths in rtl.f are used verbatim.
BRIDGE_SRCS := $(shell grep -vE '^[[:space:]]*(#|$$)' rtl.f)
COV_DIR := sim/obj_dir_cov
# Minimum line-coverage floor enforced by `make coverage` (DV_STANDARDS.md).
COV_MIN ?= 80

.PHONY: help lint verible-lint verible-format sim regress stress vcd gtkwave vlt-vcd vlt-gtkwave coverage sva formal synth ci cocotb uvm clean

# Verible style-lint / format target the synthesizable RTL (the rtl.f source list).
VERIBLE_SRCS  := $(BRIDGE_SRCS)
VERIBLE_LINT  ?= verible-verilog-lint
VERIBLE_FMT   ?= verible-verilog-format

help:
	@echo "chi_to_cxl_bridge — common targets"
	@echo ""
	@echo "  make lint      — Verilator --lint-only on all RTL modules"
	@echo "  make verible-lint   — Verible SystemVerilog style-lint (advisory)"
	@echo "  make verible-format — Verible auto-format the RTL in place (opt-in, local)"
	@echo "  make sim       — Icarus directed simulation (smoke + scoreboard)"
	@echo "  make stress    — Icarus simulation with heavy backpressure stress"
	@echo "  make vcd       — Icarus sim dumping a VCD (verification/directed/build/waves.vcd)"
	@echo "  make gtkwave   — make vcd, then open the VCD in GTKWave"
	@echo "  make vlt-vcd   — Verilator --trace build of sim/sim_main.cpp -> sim/obj_dir_vcd/waves.vcd"
	@echo "  make vlt-gtkwave — make vlt-vcd, then open the Verilator VCD in GTKWave"
	@echo "  make regress   — lint + sim (fast CI gate)"
	@echo "  make coverage  — Verilator C++ coverage -> sim/coverage.info (fails below COV_MIN=$(COV_MIN)% lines)"
	@echo "  make sva       — Verilator --assert: interface SVA on all 4 valid/ready ports"
	@echo "  make formal    — SymbiYosys BMC + cover (credit_counter, reset_drain, async_fifo, bridge top)"
	@echo "  make synth     — Yosys synthesis smoke (catch latches, area stats)"
	@echo "  make cocotb    — cocotb OSS UVM-equivalent tests (Icarus VPI)"
	@echo "  make ci        — regress + coverage + sva + formal + synth (comprehensive)"
	@echo "  make clean     — remove simulation build artifacts"
	@echo ""
	@echo "  Subdirectory targets:"
	@echo "    make -C verification/directed [sim|stress|vcd|gtkwave|lint|clean]"
	@echo "    make -C verification/formal   [all|credit_counter|reset_drain|async_fifo|chi_to_cxl_bridge|clean]"

# Verilator RTL lint (delegates to directed/, which runs verilator from repo root).
lint:
	$(MAKE) -C verification/directed lint

# Verible SystemVerilog style-lint (advisory house-style check).
verible-lint:
	@set -e; \
	command -v $(VERIBLE_LINT) >/dev/null 2>&1 || { echo "[VERIBLE] $(VERIBLE_LINT) not on PATH; skipping (install from chipsalliance/verible)"; exit 0; }; \
	$(VERIBLE_LINT) $(VERIBLE_SRCS); \
	echo "[VERIBLE] style-lint clean ($(words $(VERIBLE_SRCS)) files)"

# Verible auto-format, rewriting the RTL in place. OPT-IN / LOCAL ONLY.
verible-format:
	@set -e; \
	command -v $(VERIBLE_FMT) >/dev/null 2>&1 || { echo "[VERIBLE] $(VERIBLE_FMT) not on PATH; skipping"; exit 0; }; \
	$(VERIBLE_FMT) --inplace $(VERIBLE_SRCS); \
	echo "[VERIBLE] formatted $(words $(VERIBLE_SRCS)) files in place (review the diff)"

# Icarus directed simulation.
sim:
	$(MAKE) -C verification/directed sim

# Icarus simulation with heavy backpressure stress.
stress:
	$(MAKE) -C verification/directed stress

# Dump a VCD waveform of the directed sim (verification/directed/build/waves.vcd).
vcd:
	$(MAKE) -C verification/directed vcd

gtkwave:
	$(MAKE) -C verification/directed gtkwave

# fast CI gate.
regress: lint sim
	@echo "[REGRESS] lint + directed sim PASSED"

# cocotb OSS UVM-equivalent tests (Icarus VPI).
cocotb:
	$(MAKE) -C verification/cocotb

# coverage: Verilator --coverage build + run; emits sim/coverage.info (lcov format).
coverage:
	@set -e; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[COVERAGE] verilator not on PATH; skipping"; exit 0; }; \
	if [ ! -f sim/sim_main.cpp ]; then \
		echo "[COVERAGE] sim/sim_main.cpp not present — Verilator C++ coverage harness TODO; skipping"; \
		exit 0; \
	fi; \
	rm -rf $(COV_DIR); \
	$(VERILATOR) --coverage -cc $(BRIDGE_SRCS) --top-module chi_to_cxl_bridge \
		--Mdir $(COV_DIR) -Isrc -Wno-DECLFILENAME -Wno-WIDTH -Wno-fatal; \
	$(MAKE) -C $(COV_DIR) -f Vchi_to_cxl_bridge.mk; \
	g++ -DVM_COVERAGE=1 -o $(COV_DIR)/sim_cov \
		sim/sim_main.cpp $(COV_DIR)/Vchi_to_cxl_bridge__ALL.a \
		-I$(COV_DIR) -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP) -pthread -lm; \
	( cd $(COV_DIR) && ./sim_cov ); \
	if command -v verilator_coverage >/dev/null 2>&1; then \
		verilator_coverage --write-info sim/coverage.info $(COV_DIR)/coverage.dat; \
		echo "[COVERAGE] sim/coverage.info written"; \
		pct=$$(awk -F: '/^DA:/{split($$2,a,","); f++; if(a[2]+0>0) h++} END{printf "%.1f", (f? 100*h/f : 0)}' sim/coverage.info); \
		echo "[COVERAGE] line coverage: $$pct% (floor $(COV_MIN)%)"; \
		awk -v p="$$pct" -v m="$(COV_MIN)" 'BEGIN{exit !(p+0 >= m+0)}' || { \
			echo "[COVERAGE] FAIL: line coverage $$pct% below the $(COV_MIN)% floor"; exit 1; }; \
		echo "[COVERAGE] PASS: meets the $(COV_MIN)% floor"; \
	else \
		echo "[COVERAGE] coverage.dat in $(COV_DIR) (install verilator for lcov export)"; \
	fi

# sva: bind verification/chi_to_cxl_bridge_sva.sv and run the sim/sim_main.cpp
# stimulus under Verilator --assert, so the concurrent interface SVA is checked
# at runtime. A failed property aborts the run. Degrades to a stub if absent.
SVA_DIR := sim/obj_dir_sva
sva:
	@set -e; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[SVA] verilator not on PATH; skipping"; exit 0; }; \
	rm -rf $(SVA_DIR); \
	$(VERILATOR) --assert --coverage -cc $(BRIDGE_SRCS) verification/chi_to_cxl_bridge_sva.sv \
		--top-module chi_to_cxl_bridge --Mdir $(SVA_DIR) -Isrc \
		-Wno-DECLFILENAME -Wno-WIDTH -Wno-fatal; \
	$(MAKE) -C $(SVA_DIR) -f Vchi_to_cxl_bridge.mk; \
	g++ -DVM_COVERAGE=1 -o $(SVA_DIR)/sim_sva \
		sim/sim_main.cpp $(SVA_DIR)/Vchi_to_cxl_bridge__ALL.a \
		-I$(SVA_DIR) -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP) -pthread -lm; \
	( cd $(SVA_DIR) && ./sim_sva ); \
	echo "[SVA] interface assertions passed (Verilator --assert, 4 valid/ready ports)"

# vlt-vcd: Verilator --trace build of the sim/sim_main.cpp stimulus.
VCD_DIR := sim/obj_dir_vcd
VLT_VCD := $(VCD_DIR)/waves.vcd
vlt-vcd:
	@set -e; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[VLT-VCD] verilator not on PATH; skipping"; exit 0; }; \
	if [ ! -f sim/sim_main.cpp ]; then \
		echo "[VLT-VCD] sim/sim_main.cpp not present; skipping"; \
		exit 0; \
	fi; \
	rm -rf $(VCD_DIR); \
	$(VERILATOR) --trace --coverage -cc $(BRIDGE_SRCS) --top-module chi_to_cxl_bridge \
		--Mdir $(VCD_DIR) -Isrc -Wno-DECLFILENAME -Wno-WIDTH -Wno-fatal; \
	$(MAKE) -C $(VCD_DIR) -f Vchi_to_cxl_bridge.mk; \
	g++ -DVM_TRACE=1 -DVM_COVERAGE=1 -o $(VCD_DIR)/sim_vcd \
		sim/sim_main.cpp $(VCD_DIR)/Vchi_to_cxl_bridge__ALL.a \
		-I$(VCD_DIR) -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP) $(VERILATOR_INC)/verilated_vcd_c.cpp -pthread -lm; \
	( cd $(VCD_DIR) && ./sim_vcd ); \
	echo "[VLT-VCD] $(VLT_VCD) written"

vlt-gtkwave: vlt-vcd
	gtkwave $(VLT_VCD)

# SymbiYosys formal verification (requires OSS CAD Suite or standalone sby).
formal:
	$(MAKE) -C verification/formal

# synth: Yosys synthesis smoke test. Checks for inferred latches and tracks area.
synth:
	@set -e; \
	command -v yosys >/dev/null 2>&1 || { echo "[SYNTH] yosys not on PATH; skipping"; exit 0; }; \
	echo "[SYNTH] starting Yosys smoke synthesis..."; \
	mkdir -p sim; \
	yosys -p "read_verilog -sv -Isrc $(BRIDGE_SRCS); synth -top chi_to_cxl_bridge; stat" > sim/synth.log 2>&1; \
	grep -E "(wires|cells|memories|processes)$$" sim/synth.log; \
	if grep -i "Latch inferred" sim/synth.log | grep -v "No latch inferred" > /dev/null; then \
		echo "[SYNTH] FAIL: inferred latches detected!"; exit 1; \
	fi; \
	echo "[SYNTH] PASS: no latches, stat written to sim/synth.log"

# Comprehensive local run.
ci: regress coverage sva formal synth
	@echo "[CI] regress + coverage + sva + formal + synth PASSED"

clean:
	$(MAKE) -C verification/directed clean
	-$(MAKE) -C verification/formal clean
	rm -rf $(COV_DIR) $(SVA_DIR) $(VCD_DIR) sim/coverage.info sim/synth.log
