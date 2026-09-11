"""Bring-up smoke for chi_to_cxl_bridge (aligned with ../ucie2-pipe7-bridge
dv/pyuvm/test_smoke.py).

Drives the two clock domains + async reset, brings the link up, runs a handful of
cycles, and writes the canonical per-cycle trace (build/bridge.trace) using the
shared trace_format contract. Establishes the flow and trace format the
cycle-accurate cross-check (tools/trace_compare.py) depends on.
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

import trace_format as tf

N_CYCLES = 64


def _i(handle):
    """Read a signal as int, tolerating x/z during reset."""
    try:
        return int(handle.value)
    except Exception:
        return 0


@cocotb.test()
async def smoke(dut):
    # CHI-side clk and CXL link-side cxl_clk (independent domains; the DUT has a CDC).
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    cocotb.start_soon(Clock(dut.cxl_clk, 3, units="ns").start())

    # Tie inputs to a defined idle, assert the async reset, then release.
    for name in ("chi_req_valid", "chi_req_data", "chi_wr_data_valid", "chi_wr_data",
                 "cxl_tx_req_ready", "cxl_tx_rwd_ready", "cxl_rx_ndr_valid",
                 "cxl_rx_ndr_data", "cxl_rx_drs_valid", "cxl_rx_drs_data",
                 "chi_rsp_ready", "chi_comp_data_ready", "link_up", "err_inj_en"):
        if hasattr(dut, name):
            getattr(dut, name).value = 0
    dut.rst_n.value = 0
    await Timer(10, units="ns")
    dut.rst_n.value = 1
    dut.link_up.value = 1

    os.makedirs("build", exist_ok=True)
    with open("build/bridge.trace", "w") as f:
        f.write(tf.TRACE_HEADER + "\n")
        for cyc in range(N_CYCLES):
            await RisingEdge(dut.clk)
            row = {c: _i(getattr(dut, c)) for c in tf.TRACE_COLUMNS[1:]}
            f.write(tf.format_row(cyc, row) + "\n")

    dut._log.info("smoke: wrote %d-cycle trace to build/bridge.trace" % N_CYCLES)
