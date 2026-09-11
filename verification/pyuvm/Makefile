# PyUVM-on-cocotb tier for chi_to_cxl_bridge.
#
# Aligned with ../ucie2-pipe7-bridge/dv/pyuvm/Makefile: runs under whatever
# cocotb simulator is on PATH (default verilator), pulls the RTL source list from
# the shared repo-root rtl.f, and exposes opt-in RTL line-coverage, bound-SVA, and
# waveform builds that leave the plain functional gate byte-for-byte unchanged.
#
#   make                 # default: directed read/write round-trip (test_roundtrip)
#   make MODULE=test_smoke
#   make SIM=icarus      # pick a simulator (default: verilator)
#   make RTL_COVERAGE=1   # + verilator --coverage-line (root `make coverage`)
#   make ASSERT=1         # + bind the SVA checker and check it (root `make sva`)
#   make WAVES=1          # + FST waveform dump (root `make waves`)

TOPLEVEL_LANG ?= verilog
SIM           ?= verilator

ROOT := $(abspath ../..)
SRC  := $(ROOT)/src

# Core RTL from the shared root filelist (rtl.f is repo-root-relative).
VERILOG_SOURCES := $(addprefix $(ROOT)/,$(shell grep -vE '^[[:space:]]*(#|$$)' $(ROOT)/rtl.f))

TOPLEVEL ?= chi_to_cxl_bridge
MODULE   ?= test_roundtrip

# Shared gold models + trace/coverage contract importable from the tests.
export PYTHONPATH := $(abspath .):$(abspath ../common/models):$(PYTHONPATH)

# Verilator: SV constructs + include path for chi_to_cxl_bridge_defs.vh, and
# --timing so cocotb can drive the clocks/reset.
ifeq ($(SIM),verilator)
    EXTRA_ARGS   += --timing
    COMPILE_ARGS += -I$(SRC) -Wno-fatal
endif
# Icarus (independent engine): SV-2012 + include path. Strip the OSS CAD Suite
# Python env so the pip-installed VPI loads against the Python that has
# cocotb/pyuvm, since OSS CAD Suite's vvp otherwise embeds a mismatched libpython.
ifeq ($(SIM),icarus)
    COMPILE_ARGS   += -g2012 -I$(SRC)
    SIM_CMD_PREFIX := env -u VIRTUAL_ENV -u PYTHONHOME
    export PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)
endif

# ---- Bound-SVA build (root `make sva`) --------------------------------------
# INERT unless ASSERT=1. Adds the bound checker to the source list and turns on
# Verilator assertion checking so the properties fire during the pyuvm run. A
# SEPARATE SIM_BUILD keeps the instrumented objects out of the plain gate.
ifeq ($(ASSERT),1)
    SIM_BUILD       := $(abspath assert_build)
    # Only the bound checker is needed here (it binds straight to the DUT ports);
    # the interface bundle is for the SV-UVM tb, not this cocotb flow.
    VERILOG_SOURCES += $(ROOT)/verification/uvm/sv/chi_to_cxl_sva.sv
    ifeq ($(SIM),verilator)
        COMPILE_ARGS += --assert
    endif
endif

# ---- Line-coverage build (root `make coverage`) -----------------------------
# INERT unless RTL_COVERAGE=1. `--coverage-line` instruments line+branch points;
# cocotb's verilator main writes coverage.dat here at end of sim, which the root
# `coverage` recipe scores with tools/coverage_report.py. A SEPARATE SIM_BUILD
# keeps the instrumented objects out of the plain gate's sim_build.
ifeq ($(RTL_COVERAGE),1)
    SIM_BUILD  := $(abspath cov_build)
    EXTRA_ARGS += --coverage-line
endif

# ---- Waveform dump build (root `make waves`) --------------------------------
# INERT unless WAVES=1. Separate SIM_BUILD, FST tracer compiled + enabled only
# here, so the plain gate never pays for it.
WAVE_DIR  ?= $(abspath ../../build/waves)
WAVE_FILE ?= $(WAVE_DIR)/$(MODULE).fst
ifeq ($(WAVES),1)
    SIM_BUILD    := $(abspath wave_build)
    COMPILE_ARGS += --trace-fst --trace-structs
    SIM_ARGS     += --trace --trace-file $(WAVE_FILE)
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

clean::
	rm -rf sim_build cov_build assert_build wave_build build results.xml \
	       coverage.dat dump.vcd dump.fst __pycache__ \
	       agents/__pycache__ seq_lib/__pycache__
