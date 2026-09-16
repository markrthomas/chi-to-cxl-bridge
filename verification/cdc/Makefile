# Structural CDC check for chi_to_cxl_bridge (PLAN Phase 5.0).
# Run from this directory, or `make -C verification/cdc` from the repo root.
# Requires yosys (OSS CAD Suite) + python3.
#
#   make            # gen netlist + check the real design, then the self-test
#   make cdc        # just the real-design check
#   make selftest   # assert the checker FLAGS a known-bad crossing
#
# The check keeps the sanctioned CDC primitives (async_fifo, cdc_sync,
# reset_sync, credit_pulse_sync) as blackboxes and proves no register's cone
# reaches the other clock domain except through one of them. See tools/cdc_check.py.

YOSYS ?= yosys
PY    ?= python3
CHECK := ../../tools/cdc_check.py
BUILD := build

.PHONY: all cdc selftest clean

all: cdc selftest
	@echo "[CDC] all checks passed."

cdc: $(BUILD)/cdc_net.json
	$(PY) $(CHECK) $(BUILD)/cdc_net.json chi_to_cxl_bridge

$(BUILD)/cdc_net.json: gen_netlist.ys $(wildcard ../../src/*.v)
	@mkdir -p $(BUILD)
	$(YOSYS) -q gen_netlist.ys

# Negative test: the checker MUST return non-zero on the bad fixture, else it has
# gone vacuous. Invert the exit status so a correct FLAG makes the target pass.
selftest: $(BUILD)/bad_net.json
	@if $(PY) $(CHECK) $(BUILD)/bad_net.json bad_cdc_fixture >$(BUILD)/selftest.log 2>&1; then \
	  echo "[CDC] SELFTEST FAIL: checker did NOT flag the known-bad crossing"; \
	  cat $(BUILD)/selftest.log; exit 1; \
	else \
	  echo "[CDC] selftest OK: checker correctly flagged the known-bad crossing"; \
	fi

$(BUILD)/bad_net.json: bad_cdc_fixture.v
	@mkdir -p $(BUILD)
	$(YOSYS) -q -p "read_verilog -sv bad_cdc_fixture.v; hierarchy -top bad_cdc_fixture; proc; flatten; opt -fast; write_json $(BUILD)/bad_net.json"

clean:
	rm -rf $(BUILD)
