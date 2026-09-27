"""Randomized CHI<->CXL stress/closure test for chi_to_cxl_bridge.

Runs a randomized read/write mix (distinct TxnIDs) through the full PyUVM env; the
same cross-check scoreboard proves round-trip identity + translation. Kept in its
own module so it runs in a clean simulation (one PyUVM test per cocotb run). This
is the default `make`/`make wave` target for the pyuvm tier (no MODULE specified).
"""
import os

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
        # Fixed seed 2 for the reproducible gate; TEST_SEED overrides it (root
        # `make wave` sets a fresh one each run and prints it for replay).
        env_seed = os.environ.get("TEST_SEED", "")
        seed = int(env_seed, 0) if env_seed else 2
        self.logger.info(f"RandomSeq seed = {seed}" + (" (from TEST_SEED)" if env_seed else ""))
        await RandomSeq("random", n=24, seed=seed).start(seqr)
        await quiesce(dut, 400)
        self.drop_objection()
