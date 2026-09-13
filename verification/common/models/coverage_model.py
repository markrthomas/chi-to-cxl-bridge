"""Functional-coverage model for chi_to_cxl_bridge (independent-tool tier).

Aligned with ../ucie2-pipe7-bridge/dv/common/models/coverage_model.py: the bins
are scored by ``cocotb_coverage`` (pure Python), independent of Verilator's line
coverage, and in CI the stimulus runs on the independent Icarus engine
(``make fcov``) -- a different simulator, testbench, coverage tool, and metric
(functional vs line) than the pyuvm/verilator tiers.

The bin set is derived from the flit encoding space in
src/chi_to_cxl_bridge_defs.vh: CHI REQ opcode + read/write kind; the CXL M2S
MemOpcode the bridge translates to; and the CHI response opcode + CompData seen.
Every bin is reachable from the directed round-trip stimulus with the CXL
responder loopback, so the honest target is 100% of the set.
"""
import json

from cocotb_coverage.coverage import CoverPoint, coverage_db

import bridge_model as bm

REQ_OPS = [bm.CHI_REQ_READNOSNP, bm.CHI_REQ_READONCE, bm.CHI_REQ_WRITENOSNPFULL,
           bm.CHI_REQ_WRITENOSNPPTL, bm.CHI_REQ_WRITEUNIQUEFULL]
REQ_LABELS = ["ReadNoSnp", "ReadOnce", "WriteNoSnpFull", "WriteNoSnpPtl", "WriteUniqueFull"]
MEMOPS = [bm.CXL_MEMRD, bm.CXL_MEMRDDATA, bm.CXL_MEMWR, bm.CXL_MEMWRPTL]
MEMOP_LABELS = ["MemRd", "MemRdData", "MemWr", "MemWrPtl"]
RSP_OPS = [bm.CHI_RSP_DBIDRESP, bm.CHI_RSP_COMP]
RSP_LABELS = ["DBIDResp", "Comp"]

POINTS = [
    "bridge.chi.req_opcode", "bridge.chi.req_kind",
    "bridge.cxl.m2s_memop", "bridge.chi.rsp_opcode", "bridge.chi.compdata",
]


@CoverPoint("bridge.chi.req_opcode", xf=lambda s: s["opcode"], bins=REQ_OPS,
            bins_labels=REQ_LABELS)
@CoverPoint("bridge.chi.req_kind", xf=lambda s: s["kind"], bins=["read", "write"])
def sample_req(s):
    """s = {opcode, kind('read'|'write')}."""
    pass


@CoverPoint("bridge.cxl.m2s_memop", xf=lambda s: s["memop"], bins=MEMOPS,
            bins_labels=MEMOP_LABELS)
def sample_m2s(s):
    """s = {memop}."""
    pass


@CoverPoint("bridge.chi.rsp_opcode", xf=lambda s: s["opcode"], bins=RSP_OPS,
            bins_labels=RSP_LABELS)
def sample_rsp(s):
    """s = {opcode} for a CHI RSP-channel flit (DBIDResp / Comp)."""
    pass


@CoverPoint("bridge.chi.compdata", xf=lambda s: s["seen"], bins=[1])
def sample_compdata(s):
    """s = {seen: 1} for each CHI CompData beat returned."""
    pass


# ---- backpressure / FIFO-occupancy covergroup (PLAN Phase 2 gap) ------------
# Kept in a SEPARATE point set (BP_POINTS) with its own overall_bp(), so the
# functional 100% gate (make fcov) is unaffected: these bins need the dedicated
# stall stimulus in test_backpressure.py. Each is a boolean "condition occurred"
# bin over an observable stall/near-full event.
BP_POINTS = [
    "bridge.bp.req_stall", "bridge.bp.wrdata_stall",
    "bridge.bp.tx_req_stall", "bridge.bp.tx_rwd_stall",
    "bridge.bp.ndr_stall", "bridge.bp.drs_stall",
    "bridge.bp.req_fifo_full",
]


@CoverPoint("bridge.bp.req_stall", xf=lambda s: s["req_stall"], bins=[1])
@CoverPoint("bridge.bp.wrdata_stall", xf=lambda s: s["wrdata_stall"], bins=[1])
@CoverPoint("bridge.bp.tx_req_stall", xf=lambda s: s["tx_req_stall"], bins=[1])
@CoverPoint("bridge.bp.tx_rwd_stall", xf=lambda s: s["tx_rwd_stall"], bins=[1])
@CoverPoint("bridge.bp.ndr_stall", xf=lambda s: s["ndr_stall"], bins=[1])
@CoverPoint("bridge.bp.drs_stall", xf=lambda s: s["drs_stall"], bins=[1])
@CoverPoint("bridge.bp.req_fifo_full", xf=lambda s: s["req_fifo_full"], bins=[1])
def sample_bp(s):
    """One per-cycle sample of the backpressure conditions; pass 1 for each that
    holds this cycle (0 otherwise). Bins fire on the first occurrence of each.

    Keys: req_stall (chi_req_valid & !chi_req_ready), wrdata_stall,
    tx_req_stall / tx_rwd_stall (M2S egress stalled by the link),
    ndr_stall / drs_stall (S2M ingress stalled by a full response FIFO),
    req_fifo_full (a request FIFO reached its credit/depth limit)."""
    pass


# ---- aggregation / reporting (mirrors the reference API) --------------------
def per_point():
    rows = []
    for name in POINTS:
        if name in coverage_db:
            ci = coverage_db[name]
            rows.append((name, int(ci.coverage), int(ci.size), float(ci.cover_percentage)))
    return rows


def overall():
    rows = per_point()
    hit = sum(r[1] for r in rows)
    total = sum(r[2] for r in rows)
    return hit, total, (100.0 * hit / total if total else 0.0)


def per_point_bp():
    rows = []
    for name in BP_POINTS:
        if name in coverage_db:
            ci = coverage_db[name]
            rows.append((name, int(ci.coverage), int(ci.size), float(ci.cover_percentage)))
    return rows


def overall_bp():
    rows = per_point_bp()
    hit = sum(r[1] for r in rows)
    total = sum(r[2] for r in rows)
    return hit, total, (100.0 * hit / total if total else 0.0)


def dump(json_path=None, txt_path=None):
    rows = per_point()
    hit, total, pct = overall()
    doc = {
        "tool": "cocotb_coverage", "metric": "functional",
        "bins_hit": hit, "bins_total": total, "pct": round(pct, 2),
        "points": [{"name": n, "covered": c, "size": s, "pct": round(p, 2)}
                   for (n, c, s, p) in rows],
    }
    if json_path:
        with open(json_path, "w") as f:
            json.dump(doc, f, indent=2)
    if txt_path:
        with open(txt_path, "w") as f:
            f.write(f"Functional coverage (cocotb_coverage): {hit}/{total} bins = {pct:.2f}%\n\n")
            for (n, c, s, p) in rows:
                f.write(f"  {n:28s} {c:3d}/{s:<3d} {p:6.1f}%\n")
    return doc
