"""
PyVSC functional coverage model for chi_to_cxl_bridge.

Defines SystemVerilog-style covergroups (via the `vsc` package) over the bridge's
protocol surface, plus helpers that decode a 64-bit flit and sample the relevant
covergroup. The cocotb tests in test_chi_to_cxl_bridge.py instantiate these,
sample on every transaction, and at end-of-run report coverage, write a UCIS XML
database, and gate on a coverage goal.

Coverage model (see doc/coverage-plan.md):

  ReqCoverage (sampled per accepted CHI request -> CXL.mem M2S flit)
    cp_req_kind : READ / WRITE / ATOMIC / DATALESS
    cp_cxl_op   : MEMRD / MEMRDS / MEMWR / MEMWRPTL / MEMINV   (translated op)
    cp_route    : non-posted / posted                          (FIFO routing)

  RspCoverage (sampled per accepted CXL.mem S2M flit -> CHI response)
    cp_rsp_kind : DRS / NDR / DBID
    cp_status   : OK / ERR                                     (completion status)
    cp_crc      : bad / good                                   (link CRC check)
    cp_chi_rsp  : COMPDATA / COMP / DBIDRESP / INVALID         (translated kind)
    cr_kind_crc : cross(cp_rsp_kind, cp_crc)                   (each kind x CRC)
"""

import vsc

from env import (
    get_field,
    PKT_KIND_MSB, PKT_KIND_LSB, PKT_CODE_MSB, PKT_CODE_LSB,
    PKT_MISC_MSB, PKT_MISC_LSB,
    expect_cxl_from_chi, expect_chi_from_cxl, cmd_is_posted, bridge_checksum,
    CHI_REQ_KIND_READ, CHI_REQ_KIND_WRITE, CHI_REQ_KIND_ATOMIC, CHI_REQ_KIND_DATALESS,
    CXL_M2S_MEMRD, CXL_M2S_MEMRDS, CXL_M2S_MEMWR, CXL_M2S_MEMWRPTL, CXL_M2S_MEMINV,
    CXL_S2M_KIND_DRS, CXL_S2M_KIND_NDR, CXL_S2M_KIND_DBID,
    CHI_RESP_OK, CHI_RESP_ERR,
    CHI_RSP_KIND_COMPDATA, CHI_RSP_KIND_COMP, CHI_RSP_KIND_DBIDRESP, CHI_RSP_KIND_INVALID,
)


@vsc.covergroup
class ReqCoverage(object):
    """Coverage of the CHI request -> CXL.mem M2S translation path."""

    def __init__(self):
        self.with_sample(
            kind=vsc.bit_t(4),
            cxl_op=vsc.bit_t(4),
            posted=vsc.bit_t(1),
        )

        self.cp_req_kind = vsc.coverpoint(self.kind, bins=dict(
            read=vsc.bin(CHI_REQ_KIND_READ),
            write=vsc.bin(CHI_REQ_KIND_WRITE),
            atomic=vsc.bin(CHI_REQ_KIND_ATOMIC),
            dataless=vsc.bin(CHI_REQ_KIND_DATALESS),
        ))

        self.cp_cxl_op = vsc.coverpoint(self.cxl_op, bins=dict(
            memrd=vsc.bin(CXL_M2S_MEMRD),
            memrds=vsc.bin(CXL_M2S_MEMRDS),
            memwr=vsc.bin(CXL_M2S_MEMWR),
            memwrptl=vsc.bin(CXL_M2S_MEMWRPTL),
            meminv=vsc.bin(CXL_M2S_MEMINV),
        ))

        self.cp_route = vsc.coverpoint(self.posted, bins=dict(
            non_posted=vsc.bin(0),
            posted=vsc.bin(1),
        ))


@vsc.covergroup
class RspCoverage(object):
    """Coverage of the CXL.mem S2M response -> CHI response translation path."""

    def __init__(self):
        self.with_sample(
            kind=vsc.bit_t(4),
            status=vsc.bit_t(4),
            crc_ok=vsc.bit_t(1),
            chi_kind=vsc.bit_t(4),
        )

        self.cp_rsp_kind = vsc.coverpoint(self.kind, bins=dict(
            drs=vsc.bin(CXL_S2M_KIND_DRS),
            ndr=vsc.bin(CXL_S2M_KIND_NDR),
            dbid=vsc.bin(CXL_S2M_KIND_DBID),
        ))

        self.cp_status = vsc.coverpoint(self.status, bins=dict(
            ok=vsc.bin(CHI_RESP_OK),
            err=vsc.bin(CHI_RESP_ERR),
        ))

        self.cp_crc = vsc.coverpoint(self.crc_ok, bins=dict(
            bad=vsc.bin(0),
            good=vsc.bin(1),
        ))

        self.cp_chi_rsp = vsc.coverpoint(self.chi_kind, bins=dict(
            compdata=vsc.bin(CHI_RSP_KIND_COMPDATA),
            comp=vsc.bin(CHI_RSP_KIND_COMP),
            dbidresp=vsc.bin(CHI_RSP_KIND_DBIDRESP),
            invalid=vsc.bin(CHI_RSP_KIND_INVALID),
        ))

        # Each S2M kind observed with both a good and a corrupted link CRC.
        self.cr_kind_crc = vsc.cross([self.cp_rsp_kind, self.cp_crc])


# ---- Sampling helpers ----

def sample_request(req_cov, chi_pkt):
    """Decode a CHI request flit and sample ReqCoverage."""
    kind   = get_field(chi_pkt, PKT_KIND_MSB, PKT_KIND_LSB)
    cxl    = expect_cxl_from_chi(chi_pkt)
    cxl_op = get_field(cxl, PKT_CODE_MSB, PKT_CODE_LSB)
    posted = 1 if cmd_is_posted(cxl) else 0
    req_cov.sample(kind, cxl_op, posted)


def sample_response(rsp_cov, cxl_pkt):
    """Decode a CXL.mem S2M response flit and sample RspCoverage."""
    kind     = get_field(cxl_pkt, PKT_KIND_MSB, PKT_KIND_LSB)
    status   = get_field(cxl_pkt, PKT_CODE_MSB, PKT_CODE_LSB)
    misc     = get_field(cxl_pkt, PKT_MISC_MSB, PKT_MISC_LSB)
    crc_ok   = 1 if bridge_checksum(cxl_pkt & ~0xFF) == misc else 0
    chi      = expect_chi_from_cxl(cxl_pkt)
    chi_kind = get_field(chi, PKT_KIND_MSB, PKT_KIND_LSB)
    rsp_cov.sample(kind, status, crc_ok, chi_kind)


def overall_coverage(*covergroups):
    """Minimum coverage across the given covergroup instances (percent)."""
    return min(cg.get_coverage() for cg in covergroups)
