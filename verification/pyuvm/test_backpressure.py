"""Backpressure / FIFO-occupancy functional coverage for chi_to_cxl_bridge
(PLAN Phase 2 gap: the near-full / stall states were exercised but not gated).

A self-contained cocotb test (no scoreboard) that deliberately drives the bridge
into every observable backpressure condition and scores the separate
`coverage_model` BP covergroup, gating it at 100%:

  * M2S egress stalled by the link  -> tx_req_stall / tx_rwd_stall, and the
    request FIFOs fill until credits are exhausted -> req_stall + req_fifo_full,
    and the write-data FIFO fills -> wrdata_stall;
  * S2M response FIFOs filled by holding the CHI consumer off -> ndr_stall /
    drs_stall.

Runs under Verilator locally and Icarus in CI (make fcov MODULE=test_backpressure).
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

import bridge_model as bm
import coverage_model as cov

# Bridge defaults (src/chi_to_cxl_bridge.v): FIFO_DEPTH = POSTED = NP = 8.
CREDIT = 8


def _i(h):
    try:
        return int(h.value)
    except Exception:
        return 0


async def _reset(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    cocotb.start_soon(Clock(dut.cxl_clk, 3, units="ns").start())
    for n in ("chi_req_valid", "chi_req_data", "chi_wr_data_valid", "chi_wr_data",
              "cxl_tx_req_ready", "cxl_tx_rwd_ready", "cxl_rx_ndr_valid",
              "cxl_rx_ndr_data", "cxl_rx_drs_valid", "cxl_rx_drs_data",
              "chi_rsp_ready", "chi_comp_data_ready", "chi_snp_valid",
                 "chi_snp_data", "chi_snp_resp_ready", "link_up", "err_inj_en"):
        if hasattr(dut, n):
            getattr(dut, n).value = 0
    dut.rst_n.value = 0
    await Timer(12, units="ns")
    dut.rst_n.value = 1
    dut.link_up.value = 1
    for _ in range(6):
        await RisingEdge(dut.clk)


async def _observe(dut):
    """Sample every BP condition each clk edge (sustained stalls make cross-domain
    sampling from the clk edge reliable)."""
    while True:
        await RisingEdge(dut.clk)
        occ = max(_i(dut.req_p_occ), _i(dut.req_np_occ)) if hasattr(dut, "req_np_occ") else 0
        cov.sample_bp({
            "req_stall":     1 if _i(dut.chi_req_valid) and not _i(dut.chi_req_ready) else 0,
            "wrdata_stall":  1 if _i(dut.chi_wr_data_valid) and not _i(dut.chi_wr_data_ready) else 0,
            "tx_req_stall":  1 if _i(dut.cxl_tx_req_valid) and not _i(dut.cxl_tx_req_ready) else 0,
            "tx_rwd_stall":  1 if _i(dut.cxl_tx_rwd_valid) and not _i(dut.cxl_tx_rwd_ready) else 0,
            "ndr_stall":     1 if _i(dut.cxl_rx_ndr_valid) and not _i(dut.cxl_rx_ndr_ready) else 0,
            "drs_stall":     1 if _i(dut.cxl_rx_drs_valid) and not _i(dut.cxl_rx_drs_ready) else 0,
            "req_fifo_full": 1 if occ >= CREDIT else 0,
        })


@cocotb.test()
async def backpressure(dut):
    await _reset(dut)
    cocotb.start_soon(_observe(dut))
    dut.chi_rsp_ready.value = 1
    dut.chi_comp_data_ready.value = 1

    # ---- Phase A: write egress stalled -> fill posted + write-data FIFOs -------
    # Run first, while the tag pool is fresh (reads below hold tags until their
    # responses arrive, which they never do here). Accept one write into the
    # posted FIFO (its DBIDResp is consumed since chi_rsp_ready=1), then flood the
    # write-data channel: chi_wr_data_ready is just !req_dat_w_full (independent of
    # the request handshake), so the data FIFO fills -> wrdata_stall, and with
    # posted + data both non-empty the RwD beat is presented while the link is held
    # off -> tx_rwd_stall.
    dut.cxl_tx_req_ready.value = 0
    dut.cxl_tx_rwd_ready.value = 0
    dut.chi_req_data.value = bm.make_chi_req(bm.CHI_REQ_WRITENOSNPFULL, 0x2000, 0x40)
    dut.chi_req_valid.value = 1
    for _ in range(20):
        await RisingEdge(dut.clk)
        if _i(dut.chi_req_ready):
            break
    await RisingEdge(dut.clk)
    dut.chi_req_valid.value = 0
    dut.chi_wr_data.value = bm.make_chi_wr_data(0xABCD)
    dut.chi_wr_data_valid.value = 1
    for _ in range(3 * CREDIT + 12):
        await RisingEdge(dut.clk)
    dut.chi_wr_data_valid.value = 0
    # Drain the write side.
    dut.cxl_tx_rwd_ready.value = 1
    for _ in range(4 * CREDIT):
        await RisingEdge(dut.clk)
    dut.cxl_tx_rwd_ready.value = 0

    # ---- Phase B: read egress stalled -> fill np FIFO -------------------------
    # cxl_tx_req_ready held low: presented reads stall (tx_req_stall), np fills to
    # the NP credit limit (req_fifo_full), and further reads are refused (req_stall).
    dut.chi_req_data.value = bm.make_chi_req(bm.CHI_REQ_READNOSNP, 0x1000, 0x20)
    dut.chi_req_valid.value = 1
    for _ in range(2 * CREDIT + 20):
        await RisingEdge(dut.clk)
    dut.chi_req_valid.value = 0

    # ---- Phase C: S2M response FIFOs filled -> ndr_stall / drs_stall -----------
    # Hold the CHI response consumer off so the rsp FIFOs fill and back-pressure
    # the injected S2M flits.
    dut.chi_rsp_ready.value = 0
    dut.chi_comp_data_ready.value = 0
    dut.cxl_rx_ndr_data.value = bm.make_cxl_ndr(0)
    dut.cxl_rx_ndr_valid.value = 1
    dut.cxl_rx_drs_data.value = bm.make_cxl_drs(1, 0xF00D)
    dut.cxl_rx_drs_valid.value = 1
    for _ in range(4 * CREDIT + 20):
        await RisingEdge(dut.cxl_clk)
    dut.cxl_rx_ndr_valid.value = 0
    dut.cxl_rx_drs_valid.value = 0
    for _ in range(10):
        await RisingEdge(dut.clk)

    # ---- report / gate --------------------------------------------------------
    hit, total, pct = cov.overall_bp()
    out = os.environ.get("FCOV_OUT", "")
    miss = [n for (n, c, s, _p) in cov.per_point_bp() if c < s]
    dut._log.info(f"[BPCOV] bins={hit}/{total} = {pct:.1f}%  tool=cocotb_coverage")
    if miss:
        dut._log.info("[BPCOV] not-yet-full points: " + ", ".join(miss))
    assert pct >= 100.0, f"backpressure coverage {pct:.1f}% < 100%; missing: {miss}"
