"""CHI request sequences for chi_to_cxl_bridge (mirrors the SV seq_lib role in
../ucie2-pipe7-bridge/dv/pyuvm/seq_lib).

All sequences hand ChiReq items to the ChiDriver via the sequencer. TxnIDs are
kept distinct across in-flight requests (the bridge tracks up to 2**TAG_W = 16
outstanding), and addresses are 64-byte aligned.
"""
import random

from cocotb_coverage.crv import Randomized
from pyuvm import uvm_sequence
import bridge_model as bm
from agents.chi_cxl_agent import ChiReq

_READS = [bm.CHI_REQ_READNOSNP, bm.CHI_REQ_READONCE]
_WRITES = [bm.CHI_REQ_WRITENOSNPFULL, bm.CHI_REQ_WRITENOSNPPTL, bm.CHI_REQ_WRITEUNIQUEFULL]


class ChiReqRandom(Randomized):
    """Constrained-random CHI request generator (cocotb_coverage crv solver).

    Randomizes the opcode over the legal REQ set and a 64-byte-aligned address;
    replaces the ad-hoc `random`-module builders so the randomization is a proper
    constrained object the closure/stress sequence draws from.
    """
    def __init__(self):
        Randomized.__init__(self)
        self.opcode = _READS[0]
        self.addr_idx = 0
        self.add_rand("opcode", _READS + _WRITES)
        self.add_rand("addr_idx", list(range(1024)))

    @property
    def addr(self):
        return self.addr_idx << 6          # 64-byte aligned

    @property
    def is_write(self):
        return self.opcode in _WRITES


async def _send(seq, item):
    await seq.start_item(item)
    await seq.finish_item(item)


class ReadSeq(uvm_sequence):
    def __init__(self, name="ReadSeq", n=4, base_txnid=0x10):
        super().__init__(name)
        self.n = n
        self.base = base_txnid

    async def body(self):
        for i in range(self.n):
            op = _READS[i % len(_READS)]
            await _send(self, ChiReq(opcode=op, addr=0xC0DE_0000 + (i << 6),
                                     txnid=self.base + i))


class WriteSeq(uvm_sequence):
    def __init__(self, name="WriteSeq", n=4, base_txnid=0x40):
        super().__init__(name)
        self.n = n
        self.base = base_txnid

    async def body(self):
        for i in range(self.n):
            op = _WRITES[i % len(_WRITES)]
            await _send(self, ChiReq(opcode=op, addr=0xDEAD_0000 + (i << 6),
                                     txnid=self.base + i,
                                     data=0x1111_1111_1111_1111 * (i + 1) & ((1 << 512) - 1)))


class RoundTripSeq(uvm_sequence):
    """Directed mix: interleaved reads and writes across all opcodes."""
    async def body(self):
        await ReadSeq(n=4, base_txnid=0x10).start(self.sequencer)
        await WriteSeq(n=4, base_txnid=0x40).start(self.sequencer)
        await ReadSeq(n=2, base_txnid=0x70).start(self.sequencer)


class RandomSeq(uvm_sequence):
    """Constrained-random read/write mix with distinct TxnIDs (closure / stress).

    Draws each transaction from a ChiReqRandom crv object; TxnIDs step by a value
    coprime with 256 so they stay distinct across the run (the bridge tracks up to
    2**TAG_W outstanding). Write data is a deterministic per-index pattern (its
    content is not coverage-relevant, so it is not part of the constrained set).
    """
    def __init__(self, name="RandomSeq", n=24, seed=1):
        super().__init__(name)
        self.n = n
        self.seed = seed

    async def body(self):
        random.seed(self.seed)             # seeds the crv solver's RNG
        gen = ChiReqRandom()
        for i in range(self.n):
            gen.randomize()
            txnid = (i * 7 + 3) & 0xFF
            data = (0x9E3779B97F4A7C15 * (i + 1)) & ((1 << 512) - 1) if gen.is_write else 0
            await _send(self, ChiReq(opcode=gen.opcode, addr=gen.addr,
                                     txnid=txnid, data=data))
