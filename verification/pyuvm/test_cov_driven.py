"""Closed-loop coverage-driven generation for chi_to_cxl_bridge (PLAN Phase 2).

A single PyUVM test that samples FUNCTIONAL coverage live (via cocotb_coverage)
while a coverage-driven sequence biases the constrained-random generator toward
the request opcode / burst-length bins that are still uncovered. This proves that
purely random stimulus + coverage feedback -- with no directed round-trip -- closes
100% of the generation-reachable functional set, and reports how few transactions
it takes. Complements test_fcov (which reaches 100% by directed construction).
"""
import os

import cocotb
from cocotb.triggers import RisingEdge
import pyuvm
from pyuvm import uvm_test, ConfigDB

from env import BridgeEnv
from seq_lib.chi_seq_lib import CoverageDrivenSeq
from test_roundtrip import bringup, quiesce
import bridge_model as bm
import coverage_model as cov


def _i(h):
    try:
        return int(h.value)
    except Exception:
        return 0


@pyuvm.test()
class CovDrivenTest(uvm_test):
    def build_phase(self):
        self.env = BridgeEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        await bringup(dut)
        cocotb.start_soon(self._observe_clk(dut))
        cocotb.start_soon(self._observe_cxl(dut))

        seqr = ConfigDB().get(self, "", "CHI_SEQR")
        seq = CoverageDrivenSeq("cov_driven", max_txns=64)
        await seq.start(seqr)
        await quiesce(dut, 300)

        self._finish(seq)
        self.drop_objection()

    async def _observe_clk(self, dut):
        while True:
            await RisingEdge(dut.clk)
            if _i(dut.chi_req_valid) and _i(dut.chi_req_ready):
                req = _i(dut.chi_req_data)
                op = bm.get(req, bm.CHI_REQ["OPCODE"])
                cov.sample_req({"opcode": op,
                                "kind": "write" if bm.is_write(op) else "read"})
                cov.sample_beats({"beats": bm.chi_req_beats(bm.get(req, bm.CHI_REQ["SIZE"]))})
            if _i(dut.chi_rsp_valid) and _i(dut.chi_rsp_ready):
                cov.sample_rsp({"opcode": bm.get(_i(dut.chi_rsp_data), bm.CHI_RSP["OPCODE"])})
            if _i(dut.chi_comp_data_valid) and _i(dut.chi_comp_data_ready):
                cov.sample_compdata({"seen": 1})

    async def _observe_cxl(self, dut):
        while True:
            await RisingEdge(dut.cxl_clk)
            if _i(dut.cxl_tx_req_valid) and _i(dut.cxl_tx_req_ready):
                cov.sample_m2s({"memop": bm.get(_i(dut.cxl_tx_req_data), bm.CXL_REQ["MEMOP"])})
            if _i(dut.cxl_tx_rwd_valid) and _i(dut.cxl_tx_rwd_ready):
                cov.sample_m2s({"memop": bm.get(_i(dut.cxl_tx_rwd_data), bm.CXL_RWD["MEMOP"])})

    def _finish(self, seq):
        hit, total, pct = cov.overall()
        out = os.environ.get("FCOV_OUT", "")
        if out:
            cov.dump(json_path=os.path.join(out, "cov_driven.json"),
                     txt_path=os.path.join(out, "cov_driven.txt"))
        miss = [n for (n, c, s, _p) in cov.per_point() if c < s]
        self.logger.info(
            f"[COVDRV] closed opcode+beats bins after {seq.hit_at} transactions; "
            f"overall bins={hit}/{total} = {pct:.1f}%")
        if miss:
            self.logger.info("[COVDRV] not-yet-full points: " + ", ".join(miss))
        assert seq.hit_at is not None, \
            "coverage-driven loop did not close opcode+beats bins within max_txns"
        assert pct >= 100.0, f"functional coverage {pct:.1f}% < 100%; missing: {miss}"
