"""CHI SNP -> SnpResp path test for chi_to_cxl_bridge (PLAN Phase 3).

The CXL.mem device is memory-only, so the bridge answers every host snoop
directly with SnpResp, final state Invalid. This self-contained cocotb test
drives all three snoop opcodes (with backpressure on the response channel to
exercise the 2-deep skid FIFO), checks each SnpResp against the gold model
(opcode SnpResp, RESP=I, RESPERR=OK, matching TxnID/SrcID, in order), and gates
the snoop-opcode covergroup at 100%.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

import bridge_model as bm
import coverage_model as cov

SNPS = [
    (bm.CHI_SNP_SNPONCE,   0x1000, 0x11, 0x5),
    (bm.CHI_SNP_SNPSHARED, 0x2040, 0x22, 0x6),
    (bm.CHI_SNP_SNPUNIQUE, 0x3080, 0x33, 0x7),
    (bm.CHI_SNP_SNPSHARED, 0x40C0, 0x44, 0x5),
]


def _i(h):
    try:
        return int(h.value)
    except Exception:
        return 0


async def _collect(dut, out, n):
    """Accept SnpResp beats (with intermittent backpressure) into `out`."""
    cyc = 0
    while len(out) < n:
        # Toggle ready on a free-running cycle counter (not on accepts) so the
        # skid FIFO is stressed but the channel always makes forward progress.
        dut.chi_snp_resp_ready.value = 0 if (cyc % 3 == 2) else 1
        await RisingEdge(dut.clk)
        if _i(dut.chi_snp_resp_valid) and _i(dut.chi_snp_resp_ready):
            out.append(_i(dut.chi_snp_resp_data))
        cyc += 1
    dut.chi_snp_resp_ready.value = 1


@cocotb.test()
async def snoop(dut):
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

    resps = []
    cocotb.start_soon(_collect(dut, resps, len(SNPS)))

    # Drive the snoops (respecting chi_snp_ready backpressure).
    for (op, addr, txnid, srcid) in SNPS:
        dut.chi_snp_data.value = bm.make_chi_snp(op, addr, txnid, srcid)
        dut.chi_snp_valid.value = 1
        await RisingEdge(dut.clk)
        while not _i(dut.chi_snp_ready):
            await RisingEdge(dut.clk)
        cov.sample_snp({"opcode": op})
    dut.chi_snp_valid.value = 0

    for _ in range(60):
        await RisingEdge(dut.clk)
        if len(resps) >= len(SNPS):
            break

    # ---- check every SnpResp against the gold model (in order) ----
    assert len(resps) == len(SNPS), f"got {len(resps)} SnpResps, expected {len(SNPS)}"
    errors = []
    for i, (rsp, (op, addr, txnid, srcid)) in enumerate(zip(resps, SNPS)):
        exp = bm.pack(bm.CHI_SNPRSP, resperr=bm.CHI_RESPERR_OK, resp=bm.CHI_CACHE_I,
                      txnid=txnid, opcode=bm.CHI_RSP_SNPRESP, srcid=srcid)
        if rsp != exp:
            errors.append(
                f"snoop #{i} (op=0x{op:02x} txnid=0x{txnid:02x}): SnpResp 0x{rsp:06x} != gold 0x{exp:06x} "
                f"(opcode=0x{bm.get(rsp, bm.CHI_SNPRSP['OPCODE']):x} "
                f"resp=0x{bm.get(rsp, bm.CHI_SNPRSP['RESP']):x} "
                f"txnid=0x{bm.get(rsp, bm.CHI_SNPRSP['TXNID']):02x})")
    assert not errors, "SNP path mismatch:\n  " + "\n  ".join(errors)

    hit, total, pct = cov.overall_snp()
    dut._log.info(f"[SNP] {len(resps)} snoops answered SnpResp_I OK; "
                  f"snp coverage {hit}/{total} = {pct:.1f}%")
    assert pct >= 100.0, f"snoop-opcode coverage {pct:.1f}% < 100%"
