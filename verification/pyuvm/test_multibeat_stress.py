"""High-volume interleaved multi-beat stress test for chi_to_cxl_bridge.

Drives many mixed reads/writes of random burst length (1..MAX_BEATS) with
distinct TxnIDs, in read-heavy bursts that push the number of outstanding
transactions past the 16-entry tag pool and pressure the response FIFOs. The
bridge self-throttles on tag-pool/credit backpressure; the cross-check scoreboard
proves every burst still round-trips with the right per-beat data and length.
"""
import cocotb
import pyuvm
from pyuvm import uvm_test, ConfigDB

from env import BridgeEnv
from seq_lib.chi_seq_lib import MultiBeatStressSeq
from test_roundtrip import bringup, quiesce


@pyuvm.test()
class MultiBeatStressTest(uvm_test):
    def build_phase(self):
        self.env = BridgeEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        await bringup(dut)
        seqr = ConfigDB().get(self, "", "CHI_SEQR")
        await MultiBeatStressSeq("mb_stress").start(seqr)
        await quiesce(dut, 600)
        self.drop_objection()
