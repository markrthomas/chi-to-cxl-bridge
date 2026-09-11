"""CHI request sequences for chi_to_cxl_bridge (mirrors the SV seq_lib role in
../ucie2-pipe7-bridge/dv/pyuvm/seq_lib).

All sequences hand ChiReq items to the ChiDriver via the sequencer. TxnIDs are
kept distinct across in-flight requests (the bridge tracks up to 2**TAG_W = 16
outstanding), and addresses are 64-byte aligned.
"""
import random

from pyuvm import uvm_sequence
import bridge_model as bm
from agents.chi_cxl_agent import ChiReq

_READS = [bm.CHI_REQ_READNOSNP, bm.CHI_REQ_READONCE]
_WRITES = [bm.CHI_REQ_WRITENOSNPFULL, bm.CHI_REQ_WRITENOSNPPTL, bm.CHI_REQ_WRITEUNIQUEFULL]


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
    """Randomized read/write mix with distinct TxnIDs (closure / stress)."""
    def __init__(self, name="RandomSeq", n=24, seed=1):
        super().__init__(name)
        self.n = n
        self.seed = seed

    async def body(self):
        rng = random.Random(self.seed)
        for i in range(self.n):
            txnid = (i * 7 + 3) & 0xFF
            if rng.random() < 0.5:
                op = rng.choice(_READS)
                await _send(self, ChiReq(opcode=op, addr=(rng.randrange(1 << 40)) << 6,
                                         txnid=txnid))
            else:
                op = rng.choice(_WRITES)
                await _send(self, ChiReq(opcode=op, addr=(rng.randrange(1 << 40)) << 6,
                                         txnid=txnid, data=rng.getrandbits(512)))
