# SymbiYosys formal targets for chi_to_cxl_bridge.
# Run from this directory: make  (or: make -C verification/formal from repo root)
# Requires: sby (SymbiYosys) from OSS CAD Suite or standalone install.
# The .sby files use relative paths (../../../../src/) that resolve correctly
# from the task subdirectories SymbiYosys creates here.

SBY ?= sby

.PHONY: all credit_counter reset_drain async_fifo chi_to_cxl_bridge clean

all: credit_counter reset_drain async_fifo chi_to_cxl_bridge
	@echo "[FORMAL] All SymbiYosys checks passed."

credit_counter:
	$(SBY) -f credit_counter.sby
	@echo "[FORMAL] credit_counter: PASS (bmc + cover + prove)"

reset_drain:
	$(SBY) -f reset_drain.sby
	@echo "[FORMAL] reset_drain: PASS (bmc + cover + prove)"

async_fifo:
	$(SBY) -f async_fifo.sby
	@echo "[FORMAL] async_fifo: PASS (bmc + cover + unbounded prove)"

chi_to_cxl_bridge:
	$(SBY) -f chi_to_cxl_bridge.sby
	@echo "[FORMAL] chi_to_cxl_bridge: PASS (bmc depth 24 + cover)"

clean:
	rm -rf credit_counter_bmc credit_counter_cover credit_counter_prove \
	       reset_drain_bmc reset_drain_cover reset_drain_prove \
	       async_fifo_bmc async_fifo_cover async_fifo_prove \
	       chi_to_cxl_bridge_bmc chi_to_cxl_bridge_cover chi_to_cxl_bridge_prove \
	       credit_counter_ci.sby reset_drain_ci.sby chi_to_cxl_bridge_ci.sby
