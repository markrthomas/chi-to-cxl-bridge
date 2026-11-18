# Random-regression cocotb/Verilator build (driven by rr.py / root `make rr-build`).
# Reuses the pyuvm env + scoreboard (verification/pyuvm) unchanged; only the stimulus
# (rr_test.py) lives here. Per-job env: RR_SEED, RR_PROFILE, RR_N, RR_BP, RR_GAP.
TOPLEVEL_LANG ?= verilog
SIM           ?= verilator
RR   := $(abspath .)
ROOT := $(abspath ../..)
SRC  := $(ROOT)/src
VERILOG_SOURCES := $(addprefix $(ROOT)/,$(shell grep -vE '^[[:space:]]*(\#|$$)' $(ROOT)/rtl.f))
TOPLEVEL ?= chi_to_cxl_bridge
MODULE   ?= rr_test
SIM_BUILD ?= $(RR)/build/sim_build
export PYTHONPATH := $(RR):$(ROOT)/verification/pyuvm:$(ROOT)/verification/common/models:$(PYTHONPATH)
EXTRA_ARGS   += --timing
COMPILE_ARGS += -I$(SRC) -Wno-fatal
include $(shell cocotb-config --makefiles)/Makefile.sim
