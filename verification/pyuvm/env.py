"""PyUVM environment + cross-check scoreboard for chi_to_cxl_bridge.

Aligned with ../ucie2-pipe7-bridge/dv/pyuvm/env.py: a multi-way scoreboard so a
common-mode bug in one model cannot pass silently. Per run it checks, against the
independent Python gold model (bridge_model):

  1. round-trip identity : every driven read gets a CompData with the matching
                           TxnID and the expected read data; every driven write
                           gets a Comp with the matching TxnID.
  2. request translation : the DUT's M2S Req/RwD stream (per channel, in order)
                           matches the model's translation of the driven CHI
                           requests (MemOpcode, Addr, and write Data).

Any disagreement localizes the fault to {DUT, Python model, stimulus}.
"""
from pyuvm import (uvm_env, uvm_scoreboard, uvm_tlm_analysis_fifo)

from agents.chi_cxl_agent import ChiCxlAgent
import bridge_model as bm


def _drain(fifo):
    out = []
    while fifo.can_get():
        ok, item = fifo.try_get()
        if not ok:
            break
        out.append(item)
    return out


def _expected_req_memop(opcode):
    if opcode == bm.CHI_REQ_READNOSNP:
        return bm.CXL_MEMRD
    if opcode == bm.CHI_REQ_READONCE:
        return bm.CXL_MEMRDDATA
    return bm.CXL_MEMINV


class BridgeScoreboard(uvm_scoreboard):
    def build_phase(self):
        self.exp_fifo = uvm_tlm_analysis_fifo("exp_fifo", self)
        self.m2s_req_fifo = uvm_tlm_analysis_fifo("m2s_req_fifo", self)
        self.m2s_rwd_fifo = uvm_tlm_analysis_fifo("m2s_rwd_fifo", self)
        self.comp_fifo = uvm_tlm_analysis_fifo("comp_fifo", self)
        self.compdata_fifo = uvm_tlm_analysis_fifo("compdata_fifo", self)
        self.errors = []

    def check_phase(self):
        driven = _drain(self.exp_fifo)                  # ("req", op, addr, txnid, data)
        m2s_req = _drain(self.m2s_req_fifo)             # ("m2s_req", memop, addr, tag)
        m2s_rwd = _drain(self.m2s_rwd_fifo)             # ("m2s_rwd", memop, addr, tag, data)
        comps = _drain(self.comp_fifo)                  # ("comp", txnid, rsp)
        compdata = _drain(self.compdata_fifo)           # ("compdata", txnid, data)

        reads = [d for d in driven if not bm.is_write(d[1])]
        writes = [d for d in driven if bm.is_write(d[1])]
        comp_txn = {c[1] for c in comps}
        cdata_by_txn = {c[1]: c[2] for c in compdata}

        if not driven:
            self.errors.append("no CHI requests driven (empty run)")

        # 1/2. reads: M2S Req translation (in order) + CompData round trip (by txnid)
        if len(m2s_req) != len(reads):
            self.errors.append(
                f"M2S Req count {len(m2s_req)} != {len(reads)} driven reads")
        for i, (rd, mr) in enumerate(zip(reads, m2s_req)):
            _op, addr, txnid = rd[1], rd[2], rd[3]
            if mr[1] != _expected_req_memop(_op):
                self.errors.append(
                    f"read #{i}: M2S MemOpcode 0x{mr[1]:x} != expected 0x{_expected_req_memop(_op):x}")
            if mr[2] != addr:
                self.errors.append(
                    f"read #{i}: M2S Req Addr 0x{mr[2]:x} != driven 0x{addr:x}")
            if txnid not in cdata_by_txn:
                self.errors.append(f"read #{i}: no CompData for TxnID 0x{txnid:02x}")
            elif cdata_by_txn[txnid] != bm.read_data_for_addr(addr):
                self.errors.append(
                    f"read #{i}: CompData for TxnID 0x{txnid:02x} data mismatch")

        # 1/2. writes: M2S RwD translation (in order) + Comp round trip (by txnid)
        if len(m2s_rwd) != len(writes):
            self.errors.append(
                f"M2S RwD count {len(m2s_rwd)} != {len(writes)} driven writes")
        for i, (wr, mw) in enumerate(zip(writes, m2s_rwd)):
            op, addr, txnid, data = wr[1], wr[2], wr[3], wr[4]
            exp_memop = bm.CXL_MEMWRPTL if op == bm.CHI_REQ_WRITENOSNPPTL else bm.CXL_MEMWR
            if mw[1] != exp_memop:
                self.errors.append(
                    f"write #{i}: M2S MemOpcode 0x{mw[1]:x} != expected 0x{exp_memop:x}")
            if mw[2] != addr:
                self.errors.append(
                    f"write #{i}: M2S RwD Addr 0x{mw[2]:x} != driven 0x{addr:x}")
            if mw[4] != data:
                self.errors.append(f"write #{i}: M2S RwD Data mismatch")
            if txnid not in comp_txn:
                self.errors.append(f"write #{i}: no Comp for TxnID 0x{txnid:02x}")

        self.logger.info(
            f"[SB] driven={len(driven)} (rd={len(reads)} wr={len(writes)}) "
            f"m2s_req={len(m2s_req)} m2s_rwd={len(m2s_rwd)} "
            f"comp={len(comps)} compdata={len(compdata)}")

        assert not self.errors, \
            "chi_to_cxl_bridge cross-check failed:\n  " + "\n  ".join(self.errors)

    def report_phase(self):
        if not self.errors:
            self.logger.info("[SB] chi_to_cxl_bridge cross-check PASS (round-trip + translation)")


class BridgeEnv(uvm_env):
    def build_phase(self):
        self.agent = ChiCxlAgent("agent", self)
        self.sb = BridgeScoreboard("sb", self)

    def connect_phase(self):
        self.agent.driver.ap.connect(self.sb.exp_fifo.analysis_export)
        self.agent.responder.m2s_req_ap.connect(self.sb.m2s_req_fifo.analysis_export)
        self.agent.responder.m2s_rwd_ap.connect(self.sb.m2s_rwd_fifo.analysis_export)
        self.agent.rsp_mon.comp_ap.connect(self.sb.comp_fifo.analysis_export)
        self.agent.rsp_mon.compdata_ap.connect(self.sb.compdata_fifo.analysis_export)
