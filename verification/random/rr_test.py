"""Seeded random stimulus for chi_to_cxl_bridge, checked by the EXISTING pyuvm
scoreboard (verification/pyuvm/env.py -> BridgeScoreboard). No new checker here.

Knobs (env vars, set by rr.py): RR_SEED, RR_N (txns), RR_PROFILE (mix|read|write|burst),
RR_BP (0..100 % of cycles a sink-side ready is low), RR_GAP (max idle cycles between
requests). Everything is drawn from random.Random(RR_SEED): deterministic per seed.
"""
import os
import random

import cocotb
import pyuvm
from cocotb.triggers import RisingEdge
from pyuvm import uvm_test, ConfigDB, uvm_sequence

import bridge_model as bm
from agents.chi_cxl_agent import ChiReq
from env import BridgeEnv
from test_roundtrip import bringup, quiesce

_READS = [bm.CHI_REQ_READNOSNP, bm.CHI_REQ_READONCE]
_WRITES = [bm.CHI_REQ_WRITENOSNPFULL, bm.CHI_REQ_WRITENOSNPPTL, bm.CHI_REQ_WRITEUNIQUEFULL]
_WR_PCT = {"mix": 50, "read": 15, "write": 85, "burst": 50}


def cfg():
    return dict(seed=int(os.environ.get("RR_SEED", "1"), 0),
                n=int(os.environ.get("RR_N", "40")),
                profile=os.environ.get("RR_PROFILE", "mix"),
                bp=int(os.environ.get("RR_BP", "0")),
                gap=int(os.environ.get("RR_GAP", "0")))


class RrSeq(uvm_sequence):
    def __init__(self, c):
        super().__init__("rr_seq")
        self.c = c

    async def body(self):
        c, dut = self.c, cocotb.top
        rng = random.Random(c["seed"])
        ids = rng.sample(range(256), min(c["n"], 256))      # distinct TxnIDs
        wr_pct = _WR_PCT[c["profile"]]
        for i in range(c["n"]):
            is_wr = rng.randrange(100) < wr_pct
            op = rng.choice(_WRITES if is_wr else _READS)
            if c["profile"] == "burst":
                beats = rng.choice([1, bm.MAX_BEATS, bm.MAX_BEATS])
            else:
                beats = rng.randint(1, bm.MAX_BEATS)
            item = ChiReq(opcode=op, addr=rng.randrange(1024) << 6, txnid=ids[i],
                          data=rng.getrandbits(512) if is_wr else 0, size=beats)
            await self.start_item(item)
            await self.finish_item(item)
            for _ in range(rng.randint(0, c["gap"])):
                await RisingEdge(dut.clk)


async def _stall(sig, clk, pct, rng):
    """Randomly de-assert a sink-side ready (the DUT must hold its flit)."""
    while True:
        await RisingEdge(clk)
        sig.value = 0 if rng.randrange(100) < pct else 1


@pyuvm.test()
class RrTest(uvm_test):
    def build_phase(self):
        self.env = BridgeEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut, c = cocotb.top, cfg()
        self.logger.info("RR config %s" % c)
        await bringup(dut)
        await RisingEdge(dut.clk)              # let env components set their defaults
        if c["bp"]:
            r = random.Random(c["seed"] ^ 0x5EED)
            for sig, clk in ((dut.cxl_tx_req_ready, dut.cxl_clk),
                             (dut.cxl_tx_rwd_ready, dut.cxl_clk),
                             (dut.chi_rsp_ready, dut.clk),
                             (dut.chi_comp_data_ready, dut.clk)):
                cocotb.start_soon(_stall(sig, clk, c["bp"], random.Random(r.getrandbits(32))))
        seqr = ConfigDB().get(self, "", "CHI_SEQR")
        await RrSeq(c).start(seqr)
        await quiesce(dut, 400 + 40 * c["n"] * (1 + c["bp"] // 20))
        self.drop_objection()
