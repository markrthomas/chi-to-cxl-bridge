"""
cocotb tests for chi_to_cxl_bridge with PyVSC functional coverage.

Each test drives the DUT, checks the observed flit against the pure-Python gold
model (env.expect_*), and samples the PyVSC covergroups (coverage.py). A
randomized soak fills coverage for breadth; a directed closure test guarantees
every bin and cross is hit; the final test reports coverage, writes a UCIS XML
database (cov.xml), and gates on COV_GOAL.

Run: make            (from this directory, or `make cocotb` from the repo root)
Env: COV_GOAL=<pct>  coverage floor to enforce (default 100.0)
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from env import (
    CHIDriver, CXLDriver, reset_dut,
    pack_chi_read, pack_chi_write, pack_chi_atomic, pack_chi_dataless,
    pack_cxl_drs, pack_cxl_ndr, pack_cxl_dbid,
    with_checksum, bridge_checksum,
    expect_cxl_from_chi, expect_chi_from_cxl,
    CHI_RD_OP_NOSNP, CHI_RD_OP_ONCE,
    CHI_WR_OP_NOSNP, CHI_WR_OP_UNIQUE, CHI_WR_OP_PTL,
    CXL_RSP_OK, CXL_RSP_ERR,
    CHI_RSP_KIND_INVALID,
    PKT_KIND_MSB, PKT_KIND_LSB,
    get_field,
)
import coverage as cov

# Both domains at 100 MHz (1:1). This cocotb layer targets the translation /
# protocol functional-coverage surface, which is clock-ratio independent; the CDC
# / clock-ratio behaviour is covered by the directed TB (1:1, 2:1, 1:3 sweep) and
# the async_fifo SymbiYosys proof. A 1:1 ratio keeps the cocotb valid/ready
# handshake free of cross-edge sampling races (matches the workspace pattern).
CLK_NS = 10
CXL_NS = 10

# Module-level covergroups shared across every test in this file (cocotb runs the
# tests in declaration order within one simulation).
REQ_COV = cov.ReqCoverage()
RSP_COV = cov.RspCoverage()


def _start_clocks(dut):
    """Start both clocks (cocotb kills forked tasks between tests, so each test
    restarts them)."""
    cocotb.start_soon(Clock(dut.clk,     CLK_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.cxl_clk, CXL_NS, units="ns").start())


async def _do_req(dut, chi, cxl, pkt):
    """Send a CHI request, return the observed CXL.mem flit, sample + check."""
    await chi.send(pkt)
    got = await cxl.recv()
    exp = expect_cxl_from_chi(pkt)
    assert got == exp, f"req 0x{pkt:016x}: expected 0x{exp:016x}, got 0x{got:016x}"
    cov.sample_request(REQ_COV, pkt)
    return got


async def _do_rsp(dut, chi, cxl, pkt):
    """Send a CXL.mem S2M flit, return the observed CHI response, sample + check."""
    await cxl.send(pkt)
    got = await chi.recv()
    exp = expect_chi_from_cxl(pkt)
    assert got == exp, f"rsp 0x{pkt:016x}: expected 0x{exp:016x}, got 0x{got:016x}"
    cov.sample_response(RSP_COV, pkt)
    return got


# ---------------------------------------------------------------------------
# Directed request-path tests (CHI -> CXL.mem M2S)
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_req_read(dut):
    """CHI ReadNoSnp -> CXL MEMRD."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)
    await _do_req(dut, chi, cxl, pack_chi_read(CHI_RD_OP_NOSNP, 0x3C, 0xBEEF, 0x04, 0xA1, 0x0F))


@cocotb.test()
async def test_req_read_once(dut):
    """CHI ReadOnce -> CXL MEMRDS (snooped/shared)."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)
    await _do_req(dut, chi, cxl, pack_chi_read(CHI_RD_OP_ONCE, 0x11, 0x2000, 0x08, 0xD4, 0xF5))


@cocotb.test()
async def test_req_write(dut):
    """CHI WriteNoSnp -> CXL MEMWR (posted)."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)
    await _do_req(dut, chi, cxl, pack_chi_write(CHI_WR_OP_NOSNP, 0x22, 0x4000, 0x04, 0xE5, 0xA3))


@cocotb.test()
async def test_req_write_ptl(dut):
    """CHI WriteNoSnpPtl -> CXL MEMWRPTL."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)
    await _do_req(dut, chi, cxl, pack_chi_write(CHI_WR_OP_PTL, 0x23, 0x40C0, 0x02, 0xE6, 0x5B))


@cocotb.test()
async def test_req_atomic(dut):
    """CHI Atomic -> CXL MEMINV (non-posted)."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)
    await _do_req(dut, chi, cxl, pack_chi_atomic(0x0, 0x33, 0x0008, 0x01, 0xF6, 0x77))


@cocotb.test()
async def test_req_dataless(dut):
    """CHI Dataless (CMO) -> CXL MEMINV (non-posted)."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)
    await _do_req(dut, chi, cxl, pack_chi_dataless(0x0, 0x44, 0x000C, 0x01, 0xA7, 0x5B))


# ---------------------------------------------------------------------------
# Directed response-path tests (CXL.mem S2M -> CHI response)
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_rsp_drs(dut):
    """CXL DRS (good CRC) -> CHI CompData."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)
    await _do_rsp(dut, chi, cxl, with_checksum(pack_cxl_drs(CXL_RSP_OK, 0x3C, 0x0040, 0x04, 0xC3, 0x18)))


@cocotb.test()
async def test_rsp_ndr(dut):
    """CXL NDR (good CRC) -> CHI Comp."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)
    await _do_rsp(dut, chi, cxl, with_checksum(pack_cxl_ndr(CXL_RSP_OK, 0x22, 0x0040, 0x04, 0xE5, 0xA3)))


@cocotb.test()
async def test_rsp_dbid(dut):
    """CXL DBID (good CRC) -> CHI DBIDResp."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)
    await _do_rsp(dut, chi, cxl, with_checksum(pack_cxl_dbid(CXL_RSP_OK, 0x33, 0x0001, 0x01, 0xF6, 0x77)))


@cocotb.test()
async def test_rsp_bad_crc(dut):
    """CXL DRS with a corrupted CRC -> CHI RespErr (INVALID)."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)
    bad = with_checksum(pack_cxl_drs(CXL_RSP_OK, 0x77, 0x0040, 0x04, 0xC3, 0x18)) ^ 0xFF
    got = await _do_rsp(dut, chi, cxl, bad)
    assert get_field(got, PKT_KIND_MSB, PKT_KIND_LSB) == CHI_RSP_KIND_INVALID


# ---------------------------------------------------------------------------
# Randomized soak (breadth) + directed coverage closure
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_soak(dut):
    """Randomized request/response stream, gold-checked, sampling coverage."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)
    rng = random.Random(0xC0FFEE)

    req_builders = [
        lambda: pack_chi_read(rng.choice([CHI_RD_OP_NOSNP, CHI_RD_OP_ONCE]),
                              rng.randint(0, 255), rng.randint(0, 0xFFFF),
                              rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255)),
        lambda: pack_chi_write(rng.choice([CHI_WR_OP_NOSNP, CHI_WR_OP_UNIQUE, CHI_WR_OP_PTL]),
                               rng.randint(0, 255), rng.randint(0, 0xFFFF),
                               rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255)),
        lambda: pack_chi_atomic(0x0, rng.randint(0, 255), rng.randint(0, 0xFFFF),
                                rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255)),
        lambda: pack_chi_dataless(0x0, rng.randint(0, 255), rng.randint(0, 0xFFFF),
                                  rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255)),
    ]
    rsp_builders = [pack_cxl_drs, pack_cxl_ndr, pack_cxl_dbid]

    for _ in range(120):
        await _do_req(dut, chi, cxl, rng.choice(req_builders)())

        status = rng.choice([CXL_RSP_OK, CXL_RSP_ERR])
        flit = with_checksum(rng.choice(rsp_builders)(
            status, rng.randint(0, 255), rng.randint(0, 0xFFFF),
            rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255)))
        if rng.random() < 0.25:           # corrupt the CRC a quarter of the time
            flit ^= (1 << rng.randint(0, 7)) or 0x1
        await _do_rsp(dut, chi, cxl, flit)


@cocotb.test()
async def test_coverage_closure(dut):
    """Drive the specific corner combinations needed to close every bin/cross."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.cxl_clk)
    chi, cxl = CHIDriver(dut, dut.clk), CXLDriver(dut, dut.cxl_clk)

    # Every request kind / opcode -> every CXL M2S op + both routes.
    for pkt in (
        pack_chi_read(CHI_RD_OP_NOSNP, 0x01, 0x1000, 0x04, 0x10, 0x00),
        pack_chi_read(CHI_RD_OP_ONCE,  0x02, 0x1040, 0x04, 0x11, 0x00),
        pack_chi_write(CHI_WR_OP_NOSNP, 0x03, 0x2000, 0x08, 0x12, 0x00),
        pack_chi_write(CHI_WR_OP_PTL,   0x04, 0x20C0, 0x02, 0x13, 0x00),
        pack_chi_atomic(0x0, 0x05, 0x3000, 0x01, 0x14, 0x00),
        pack_chi_dataless(0x0, 0x06, 0x3008, 0x01, 0x15, 0x00),
    ):
        await _do_req(dut, chi, cxl, pkt)

    # Every S2M kind x {good, bad CRC} x {OK, ERR status} -> closes cp_rsp_kind,
    # cp_status, cp_crc, cp_chi_rsp, and the cr_kind_crc cross.
    for builder in (pack_cxl_drs, pack_cxl_ndr, pack_cxl_dbid):
        for status in (CXL_RSP_OK, CXL_RSP_ERR):
            good = with_checksum(builder(status, 0x20, 0x0040, 0x04, 0x21, 0x22))
            await _do_rsp(dut, chi, cxl, good)
            await _do_rsp(dut, chi, cxl, good ^ 0xFF)   # corrupt CRC -> INVALID


@cocotb.test()
async def test_coverage_report(dut):
    """Report functional coverage, write a UCIS XML DB, and gate on COV_GOAL."""
    import vsc

    goal = float(os.environ.get("COV_GOAL", "100.0"))
    xml_path = os.environ.get("COV_XML", "cov.xml")

    print("\n==== chi_to_cxl_bridge functional coverage ====")
    vsc.report_coverage(details=True)

    try:
        vsc.write_coverage_db(xml_path)
        print(f"[cov] UCIS coverage DB written to {xml_path}")
    except Exception as e:           # pragma: no cover - DB writer is optional
        print(f"[cov] warning: write_coverage_db failed: {e}")

    req_pct = REQ_COV.get_coverage()
    rsp_pct = RSP_COV.get_coverage()
    overall = min(req_pct, rsp_pct)
    print(f"[cov] ReqCoverage = {req_pct:.1f}%  RspCoverage = {rsp_pct:.1f}%  "
          f"overall = {overall:.1f}%  (goal {goal:.1f}%)")

    assert overall >= goal, (
        f"functional coverage {overall:.1f}% below goal {goal:.1f}% "
        f"(ReqCoverage={req_pct:.1f}%, RspCoverage={rsp_pct:.1f}%)")
    print(f"[cov] PASS: meets the {goal:.1f}% goal")
