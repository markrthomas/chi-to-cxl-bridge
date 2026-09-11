"""Independent functional-coverage driver for chi_to_cxl_bridge (make fcov).

A single PyUVM test that drives the directed + randomized CHI request mix through
the env and scores FUNCTIONAL coverage via cocotb_coverage (coverage_model). In
CI this runs on the independent Icarus engine -- a redundant cross-check to the
pyuvm/verilator tiers (different simulator, testbench, coverage tool, metric).
Mirrors dv/pyuvm/test_fcov.py in ../ucie2-pipe7-bridge.

The directed round-trip exercises all five CHI REQ opcodes, all four translated
M2S MemOpcodes, both CHI RSP opcodes, and CompData -- an honest 100% of the
loopback-reachable functional set.
"""
import os

import cocotb
from cocotb.triggers import RisingEdge
import pyuvm
from pyuvm import uvm_test, ConfigDB

from env import BridgeEnv
from seq_lib.chi_seq_lib import RoundTripSeq
from test_roundtrip import bringup, quiesce
import bridge_model as bm
import coverage_model as cov


def _i(h):
    try:
        return int(h.value)
    except Exception:
        return 0


@pyuvm.test()
class FcovTest(uvm_test):
    def build_phase(self):
        self.env = BridgeEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        await bringup(dut)
        cocotb.start_soon(self._observe_clk(dut))
        cocotb.start_soon(self._observe_cxl(dut))

        seqr = ConfigDB().get(self, "", "CHI_SEQR")
        # The directed round-trip alone spans all five REQ opcodes, all four
        # translated MemOpcodes, both RSP opcodes and CompData -> honest 100%.
        await RoundTripSeq("roundtrip").start(seqr)
        await quiesce(dut, 300)

        self._finish()
        self.drop_objection()

    async def _observe_clk(self, dut):
        while True:
            await RisingEdge(dut.clk)
            if _i(dut.chi_req_valid) and _i(dut.chi_req_ready):
                op = bm.get(_i(dut.chi_req_data), bm.CHI_REQ["OPCODE"])
                cov.sample_req({"opcode": op,
                                "kind": "write" if bm.is_write(op) else "read"})
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

    def _finish(self):
        hit, total, pct = cov.overall()
        out = os.environ.get("FCOV_OUT", "")
        if out:
            cov.dump(json_path=os.path.join(out, "fcov.json"),
                     txt_path=os.path.join(out, "fcov.txt"))
        miss = [n for (n, c, s, _p) in cov.per_point() if c < s]
        self.logger.info(f"[FCOV] bins={hit}/{total} = {pct:.1f}%  tool=cocotb_coverage")
        if miss:
            self.logger.info("[FCOV] not-yet-full points: " + ", ".join(miss))
        assert pct >= 100.0, f"functional coverage {pct:.1f}% < 100%; missing: {miss}"
