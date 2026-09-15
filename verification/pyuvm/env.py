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
        driven = _drain(self.exp_fifo)                  # ("req", op, addr, txnid, data, beats)
        m2s_req = _drain(self.m2s_req_fifo)             # ("m2s_req", memop, addr, tag, beats)
        m2s_rwd = _drain(self.m2s_rwd_fifo)             # ("m2s_rwd", memop, addr, tag, data, beat, beats)
        comps = _drain(self.comp_fifo)                  # ("comp", txnid, rsp)
        compdata = _drain(self.compdata_fifo)           # ("compdata", txnid, data)

        reads = [d for d in driven if not bm.is_write(d[1])]
        writes = [d for d in driven if bm.is_write(d[1])]
        comp_txn = {c[1] for c in comps}
        # CompData beats grouped per TxnID, in arrival order (multi-beat reads).
        cdata_by_txn = {}
        for c in compdata:
            cdata_by_txn.setdefault(c[1], []).append(c[2])

        if not driven:
            self.errors.append("no CHI requests driven (empty run)")

        # 1/2. reads: one M2S Req per read (carrying LEN) + `beats` CompData beats
        # round trip (per TxnID, in order).
        if len(m2s_req) != len(reads):
            self.errors.append(
                f"M2S Req count {len(m2s_req)} != {len(reads)} driven reads")
        for i, (rd, mr) in enumerate(zip(reads, m2s_req)):
            _op, addr, txnid, beats = rd[1], rd[2], rd[3], rd[5]
            if mr[1] != _expected_req_memop(_op):
                self.errors.append(
                    f"read #{i}: M2S MemOpcode 0x{mr[1]:x} != expected 0x{_expected_req_memop(_op):x}")
            if mr[2] != addr:
                self.errors.append(
                    f"read #{i}: M2S Req Addr 0x{mr[2]:x} != driven 0x{addr:x}")
            if mr[4] != beats:
                self.errors.append(
                    f"read #{i}: M2S Req LEN {mr[4]} != expected {beats}")
            got = cdata_by_txn.get(txnid, [])
            if len(got) != beats:
                self.errors.append(
                    f"read #{i}: CompData beats {len(got)} != {beats} for TxnID 0x{txnid:02x}")
            for k in range(min(len(got), beats)):
                if got[k] != bm.read_data_for_addr(addr, k):
                    self.errors.append(
                        f"read #{i}: CompData beat {k} for TxnID 0x{txnid:02x} data mismatch")

        # 1/2. writes: `beats` M2S RwD beats per write (in order across the flat
        # RwD stream) + one Comp round trip (by TxnID).
        exp_rwd_beats = sum(w[5] for w in writes)
        if len(m2s_rwd) != exp_rwd_beats:
            self.errors.append(
                f"M2S RwD beat count {len(m2s_rwd)} != {exp_rwd_beats} expected")
        idx = 0
        for i, wr in enumerate(writes):
            op, addr, txnid, data, beats = wr[1], wr[2], wr[3], wr[4], wr[5]
            exp_memop = bm.CXL_MEMWRPTL if op == bm.CHI_REQ_WRITENOSNPPTL else bm.CXL_MEMWR
            for k in range(beats):
                if idx >= len(m2s_rwd):
                    break
                mw = m2s_rwd[idx]
                idx += 1
                if mw[1] != exp_memop:
                    self.errors.append(
                        f"write #{i} beat {k}: M2S MemOpcode 0x{mw[1]:x} != expected 0x{exp_memop:x}")
                if mw[2] != addr:
                    self.errors.append(
                        f"write #{i} beat {k}: M2S RwD Addr 0x{mw[2]:x} != driven 0x{addr:x}")
                if mw[4] != bm.wr_beat_data(data, k):
                    self.errors.append(f"write #{i} beat {k}: M2S RwD Data mismatch")
                if mw[6] != beats:
                    self.errors.append(
                        f"write #{i} beat {k}: M2S RwD LEN {mw[6]} != expected {beats}")
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
