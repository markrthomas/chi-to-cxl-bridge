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
COV_DIR := build/coverage
# Minimum line-coverage floor enforced by `make coverage` (DV_STANDARDS.md).
COV_MIN ?= 80

.PHONY: help lint verible-lint verible-format sim regress stress vcd gtkwave waves wave coverage sva formal formal-fullwidth synth ci cocotb pyuvm fcov uvm uvm-lint trace-check trace-golden clean

# Verible style-lint / format target the synthesizable RTL (the rtl.f source list).
VERIBLE_SRCS  := $(BRIDGE_SRCS)
VERIBLE_LINT  ?= verible-verilog-lint
VERIBLE_FMT   ?= verible-verilog-format
# Ruleset: disables the documented, intentional house-style deviations (dense
# FORMAL/defs lines, proven byte-identical infra); every other rule stays a gate.
VERIBLE_RULES := verification/verible_lint.rules

help:
	@echo "chi_to_cxl_bridge — common targets"
	@echo ""
	@echo "  make lint      — Verilator --lint-only on all RTL modules"
	@echo "  make verible-lint   — Verible SystemVerilog style-lint (gate; ruleset waives house-style)"
	@echo "  make verible-format — Verible auto-format the RTL in place (opt-in, local)"
	@echo "  make sim       — Icarus directed simulation (smoke + scoreboard)"
	@echo "  make stress    — Icarus simulation with heavy backpressure stress"
	@echo "  make vcd       — Icarus sim dumping a VCD (verification/directed/build/waves.vcd)"
	@echo "  make gtkwave   — make vcd, then open the VCD in GTKWave"
	@echo "  make regress   — lint + sim (fast CI gate)"
	@echo "  make pyuvm     — PyUVM-on-cocotb functional tier (round-trip + random, scoreboard)"
	@echo "  make fcov      — functional + backpressure coverage (cocotb_coverage, 100%-gated)"
	@echo "  make coverage  — Verilator --coverage-line on the pyuvm run (fails below COV_MIN=$(COV_MIN)% lines)"
	@echo "  make sva       — bound SVA checked under the pyuvm run (Verilator --assert)"
	@echo "  make uvm-lint  — elaborate the SV-UVM env (needs UVM_HOME; verification/uvm/vlt)"
	@echo "  make waves     — FST waveform of a pyuvm run (build/waves/<MODULE>.fst)"
	@echo "  make formal    — SymbiYosys BMC + cover (credit_counter, reset_drain, async_fifo, bridge top)"
	@echo "  make synth     — Yosys synthesis smoke (catch latches, area stats)"
	@echo "  make cocotb    — alias for 'make pyuvm'"
	@echo "  make ci        — regress + pyuvm + fcov + coverage + sva + formal + synth (comprehensive)"
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
	$(VERIBLE_LINT) --rules_config $(VERIBLE_RULES) $(VERIBLE_SRCS); \
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

# ---- PyUVM-on-cocotb tier (verification/pyuvm) ------------------------------
# Aligned with ../ucie2-pipe7-bridge/dv/pyuvm. The functional gate, RTL line
# coverage, bound SVA, and waveforms all ride the same cocotb+Verilator build;
# only the tier flags differ (RTL_COVERAGE / ASSERT / WAVES).
PYUVM_DIR := verification/pyuvm
PYTHON    ?= python3
RTL_DIR   ?= src

# pyuvm: the functional gate — directed CHI<->CXL round-trip + randomized mix,
# both cross-checked against the Python gold model by the scoreboard.
pyuvm:
	$(MAKE) -C $(PYUVM_DIR) MODULE=test_roundtrip
	$(MAKE) -C $(PYUVM_DIR) MODULE=test_random
	$(MAKE) -C $(PYUVM_DIR) MODULE=test_multibeat
	$(MAKE) -C $(PYUVM_DIR) MODULE=test_multibeat_stress

# cocotb: back-compat alias for the pyuvm functional tier.
cocotb: pyuvm

# fcov: independent functional coverage (cocotb_coverage). Each test asserts 100%
# of its bin set. test_fcov = REQ/MemOpcode/RSP/CompData; test_backpressure =
# the stall / near-full / FIFO-occupancy covergroup. Runs on Icarus in CI.
FCOV_SIM ?= verilator
fcov:
	$(MAKE) -C $(PYUVM_DIR) MODULE=test_fcov SIM=$(FCOV_SIM)
	$(MAKE) -C $(PYUVM_DIR) MODULE=test_backpressure SIM=$(FCOV_SIM)
	$(MAKE) -C $(PYUVM_DIR) MODULE=test_snoop SIM=$(FCOV_SIM)

# coverage: Verilator --coverage-line on the round-trip run, scored by
# tools/coverage_report.py (fails below COV_MIN=$(COV_MIN)% RTL lines).
coverage:
	@command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[COVERAGE] verilator not on PATH; skipping"; exit 0; }
	rm -f $(PYUVM_DIR)/coverage.dat $(PYUVM_DIR)/cov_build/coverage.dat
	$(MAKE) -C $(PYUVM_DIR) RTL_COVERAGE=1 SIM=verilator MODULE=test_roundtrip
	@mkdir -p $(COV_DIR)
	@if   [ -f $(PYUVM_DIR)/coverage.dat ];           then mv -f $(PYUVM_DIR)/coverage.dat           $(COV_DIR)/coverage.dat; \
	 elif [ -f $(PYUVM_DIR)/cov_build/coverage.dat ]; then mv -f $(PYUVM_DIR)/cov_build/coverage.dat $(COV_DIR)/coverage.dat; \
	 else echo "[COVERAGE] ERROR: the instrumented run produced no coverage.dat"; exit 1; fi
	$(PYTHON) tools/coverage_report.py $(COV_DIR)/coverage.dat \
		--rtl-dir $(RTL_DIR) --report $(COV_DIR)/coverage.txt --min $(COV_MIN)

# uvm-lint: elaborate the SV-UVM env (verification/uvm/vlt) — RAM-safe gate.
# Needs UVM_HOME (Accellera UVM fixture); see verification/uvm/vlt/Makefile.
# The heavier --binary run is `make -C verification/uvm/vlt run` (big runner).
uvm-lint:
	$(MAKE) -C verification/uvm/vlt lint

# sva: bind verification/uvm/sv/chi_to_cxl_sva.sv and check it under the
# round-trip run (Verilator --assert). A failed property aborts the run.
sva:
	$(MAKE) -C $(PYUVM_DIR) ASSERT=1 SIM=verilator MODULE=test_roundtrip
	$(MAKE) -C $(PYUVM_DIR) ASSERT=1 SIM=verilator MODULE=test_snoop
	@echo "[SVA] bound-checker properties held during the round-trip + snoop runs"

# waves: FST waveform of a pyuvm run (Verilator --trace-fst, WAVES=1 build).
# Opt-in and out of the gate; writes build/waves/<MODULE>.fst.
WAVE_MODULE ?= test_roundtrip
WAVE_FST    := build/waves/$(WAVE_MODULE).fst
waves:
	$(MAKE) -C $(PYUVM_DIR) WAVES=1 SIM=verilator MODULE=$(WAVE_MODULE)
	@[ -s $(WAVE_FST) ] && echo "[WAVES] wrote $(WAVE_FST)" || { echo "[WAVES] ERROR: no FST at $(WAVE_FST)"; exit 1; }

wave: waves
	gtkwave $(WAVE_FST)

# trace-check: regenerate the canonical smoke trace under Verilator and diff it
# against the committed golden (verification/pyuvm/golden/bridge.trace), catching
# any unintended change to the observable per-cycle boundary behaviour
# (tools/trace_compare.py). Regenerate the golden with `make trace-golden`.
GOLDEN_TRACE := $(PYUVM_DIR)/golden/bridge.trace
trace-check:
	$(MAKE) -C $(PYUVM_DIR) SIM=verilator MODULE=test_smoke >/dev/null
	$(PYTHON) tools/trace_compare.py \
		--a $(GOLDEN_TRACE)           --a-label golden \
		--b $(PYUVM_DIR)/build/bridge.trace --b-label verilator

trace-golden:
	$(MAKE) -C $(PYUVM_DIR) SIM=verilator MODULE=test_smoke >/dev/null
	cp $(PYUVM_DIR)/build/bridge.trace $(GOLDEN_TRACE)
	@echo "[TRACE] golden updated: $(GOLDEN_TRACE)"

# SymbiYosys formal verification (requires OSS CAD Suite or standalone sby).
formal:
	$(MAKE) -C verification/formal

# Full 512-bit-width re-run of the bridge-top proof (no data abstraction), via
# bitwuzla (keeps the wide FIFO memories as SMT arrays). Separate from `formal`.
formal-fullwidth:
	$(MAKE) -C verification/formal chi_to_cxl_bridge_fullwidth

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
ci: regress pyuvm fcov coverage sva formal synth
	@echo "[CI] regress + pyuvm + fcov + coverage + sva + formal + synth PASSED"

clean:
	$(MAKE) -C verification/directed clean
	-$(MAKE) -C verification/formal clean
	-$(MAKE) -C $(PYUVM_DIR) clean
	rm -rf $(COV_DIR) build/waves sim/coverage.info sim/synth.log
