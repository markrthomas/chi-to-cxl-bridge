# =============================================================================
# SV UVM-on-Verilator flow for chi_to_cxl_bridge (PLAN Phase 4).
#
# Aligned with ../ucie2-pipe7-bridge/dv/uvm/vlt. Requires the Accellera UVM
# 2020.3.1 library — the apt/OSS-CAD-Suite Verilator is NOT bundled with it. Set
# UVM_HOME to the dir holding uvm_pkg_all_v2020_3_1_dpi.svh, e.g. a Verilator
# source tree's test_regress/t/uvm:
#
#   git clone --depth 1 --filter=blob:none --sparse https://github.com/verilator/verilator
#   ( cd verilator && git sparse-checkout set test_regress/t )
#   make lint UVM_HOME=$PWD/verilator/test_regress/t/uvm
#
#   make lint    elaborate-only (RAM-safe, seconds)   -> runs locally + CI
#   make run     full --binary build + run            -> big CI runner only
#   make ci      lint then run
#
# NOTE: `run` builds the UVM precompiled header and can exceed ~6-8 GB RAM; do it
# on a large CI runner, not a small local host. `lint` is the local gate.
# =============================================================================

VERILATOR ?= verilator
UVM_HOME  ?=

UVM_HDR := $(UVM_HOME)/uvm_pkg_all_v2020_3_1_dpi.svh
UVM_DPI := $(UVM_HOME)/v2020_3_1/dpi/uvm_dpi.cc

VLT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SV      := $(abspath $(VLT_DIR)/../sv)
SRC     := $(abspath $(VLT_DIR)/../../../src)
ROOT    := $(abspath $(VLT_DIR)/../../..)
OBJ     := $(VLT_DIR)/obj
TOP     := tb_chi_to_cxl

# +incdir for the SV env, the bridge defs header (src/), the monolithic UVM
# header, and the uvm_macros.svh stub (this dir).
INCS := +incdir+$(SV) +incdir+$(SRC) +incdir+$(UVM_HOME) +incdir+$(VLT_DIR)

# RTL from the shared repo-root filelist, then the bound SVA, the interface, the
# UVM env package, and the tb top (dependency order).
RTL_SRCS := $(addprefix $(ROOT)/,$(shell grep -vE '^[[:space:]]*(#|$$)' $(ROOT)/rtl.f))
SRCS := $(RTL_SRCS) \
        $(SV)/chi_to_cxl_sva.sv \
        $(SV)/chi_to_cxl_if.sv \
        $(SV)/chi_to_cxl_uvm_pkg.sv \
        $(SV)/tb_chi_to_cxl.sv

LINTFLAGS ?= --lint-only --timing --assert -Wno-fatal -Wno-TIMESCALEMOD
VFLAGS    ?= --binary --timing --vpi --assert -j 1 --build-jobs 1 \
             -Wno-fatal -Wno-TIMESCALEMOD --CFLAGS "-O0"

.PHONY: lint run ci clean _require-uvm-home

_require-uvm-home:
	@if [ -z "$(UVM_HOME)" ]; then \
	  echo "Set UVM_HOME to the UVM fixture dir (see the header of this Makefile)" >&2; \
	  exit 1; fi

# Elaborate-only: the RAM-safe gate that runs on the local host + CI.
lint: _require-uvm-home
	$(VERILATOR) $(LINTFLAGS) --top-module $(TOP) $(INCS) $(UVM_HDR) $(SRCS)
	@echo "[lint-uvm] chi_to_cxl SV UVM env elaborates OK"

# Full build + run — big CI runner only. Fails on UVM_ERROR/UVM_FATAL or a bound
# SVA failure ([SVA] lines from chi_to_cxl_sva.sv under --assert).
run: _require-uvm-home
	rm -rf $(OBJ) && mkdir -p $(OBJ)
	$(VERILATOR) $(VFLAGS) --top-module $(TOP) --Mdir $(OBJ) $(INCS) \
	  $(UVM_HDR) $(UVM_DPI) $(SRCS)
	$(OBJ)/V$(TOP) +UVM_NO_RELNOTES 2>&1 | tee $(OBJ)/run.log
	@echo "----- UVM report counts -----"
	@grep -E "UVM_(INFO|WARNING|ERROR|FATAL) :" $(OBJ)/run.log || true
	@if grep -qE "UVM_(ERROR|FATAL) :[[:space:]]*[1-9]" $(OBJ)/run.log; then \
	  echo "FAIL: reported UVM_ERROR/UVM_FATAL"; exit 1; \
	elif grep -qF "[SVA]" $(OBJ)/run.log; then \
	  echo "FAIL: bound SVA assertion failure"; exit 1; \
	elif ! grep -qE "UVM_INFO :" $(OBJ)/run.log; then \
	  echo "FAIL: no UVM report (crash before report_phase?)"; exit 1; \
	else echo "PASS: clean UVM report (0 errors, 0 fatals)"; fi

ci: lint run

clean:
	rm -rf $(OBJ)
