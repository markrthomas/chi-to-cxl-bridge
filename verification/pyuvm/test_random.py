"""Randomized CHI<->CXL stress/closure test for chi_to_cxl_bridge.

Runs a randomized read/write mix (distinct TxnIDs) through the full PyUVM env; the
same cross-check scoreboard proves round-trip identity + translation. Kept in its
own module so it runs in a clean simulation (one PyUVM test per cocotb run).
"""
import cocotb
import pyuvm
from pyuvm import uvm_test, ConfigDB

from env import BridgeEnv
from seq_lib.chi_seq_lib import RandomSeq
from test_roundtrip import bringup, quiesce


@pyuvm.test()
class RandomTest(uvm_test):
    def build_phase(self):
        self.env = BridgeEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        await bringup(dut)
        seqr = ConfigDB().get(self, "", "CHI_SEQR")
        await RandomSeq("random", n=24, seed=2).start(seqr)
        await quiesce(dut, 400)
        self.drop_objection()
