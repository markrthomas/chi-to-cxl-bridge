"""Directed CHI<->CXL round-trip test for chi_to_cxl_bridge (PLAN Phase 3 DV).

Brings up both clock domains + the link, runs the directed read/write mix through
the full PyUVM env, and lets the cross-check scoreboard prove round-trip identity
and request translation against the independent Python gold model. This is the
default `make` target for the pyuvm tier (mirrors dv/pyuvm/test_roundtrip.py).
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import pyuvm
from pyuvm import uvm_test, ConfigDB

from env import BridgeEnv
from seq_lib.chi_seq_lib import RoundTripSeq


async def bringup(dut):
    cocotb.start_soon(Clock(dut.clk, 2, units="ns").start())
    cocotb.start_soon(Clock(dut.cxl_clk, 3, units="ns").start())
    dut.link_up.value = 0
    dut.err_inj_en.value = 0
    dut.rst_n.value = 0
    await Timer(12, units="ns")
    dut.rst_n.value = 1
    dut.link_up.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)


async def quiesce(dut, n=200):
    for _ in range(n):
        await RisingEdge(dut.clk)


@pyuvm.test()
class RoundTripTest(uvm_test):
    def build_phase(self):
        self.env = BridgeEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        await bringup(dut)
        seqr = ConfigDB().get(self, "", "CHI_SEQR")
        await RoundTripSeq("roundtrip").start(seqr)
        await quiesce(dut)
        self.drop_objection()
