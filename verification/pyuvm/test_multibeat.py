"""Multi-beat (runtime-length) burst test for chi_to_cxl_bridge (PLAN Phase 3).

Drives reads and writes across all burst lengths 1..MAX_BEATS through the full
PyUVM env. The cross-check scoreboard proves that each read returns exactly its
LEN CompData beats (per-beat data) and each write emits exactly its LEN RwD beats
(per-beat data) plus one Comp, all against the independent Python gold model.
"""
import cocotb
import pyuvm
from pyuvm import uvm_test, ConfigDB

from env import BridgeEnv
from seq_lib.chi_seq_lib import MultiBeatSeq
from test_roundtrip import bringup, quiesce


@pyuvm.test()
class MultiBeatTest(uvm_test):
    def build_phase(self):
        self.env = BridgeEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        await bringup(dut)
        seqr = ConfigDB().get(self, "", "CHI_SEQR")
        await MultiBeatSeq("multibeat").start(seqr)
        await quiesce(dut)
        self.drop_objection()
