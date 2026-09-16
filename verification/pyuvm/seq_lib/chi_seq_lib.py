"""CHI request sequences for chi_to_cxl_bridge (mirrors the SV seq_lib role in
../ucie2-pipe7-bridge/dv/pyuvm/seq_lib).

All sequences hand ChiReq items to the ChiDriver via the sequencer. TxnIDs are
kept distinct across in-flight requests (the bridge tracks up to 2**TAG_W = 16
outstanding), and addresses are 64-byte aligned.
"""
import random

import cocotb
from cocotb.triggers import RisingEdge
from cocotb_coverage.crv import Randomized
from pyuvm import uvm_sequence
import bridge_model as bm
import coverage_model as cov
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
        self.size = 1
        self.add_rand("opcode", _READS + _WRITES)
        self.add_rand("addr_idx", list(range(1024)))
        self.add_rand("size", list(range(1, bm.MAX_BEATS + 1)))  # burst length 1..MAX_BEATS

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


class MultiBeatSeq(uvm_sequence):
    """Directed multi-beat burst mix: reads and writes across all burst lengths
    1..MAX_BEATS, plus single-beat, with distinct TxnIDs. Exercises the
    runtime-variable-length datapath (per-transaction beat count in the request)."""
    async def body(self):
        txnid = 0x80
        for beats in (1, 2, 3, 4):
            await _send(self, ChiReq(opcode=bm.CHI_REQ_READNOSNP,
                                     addr=0x5EAD_0000 + (beats << 6),
                                     txnid=txnid, size=beats))
            txnid += 1
            await _send(self, ChiReq(opcode=bm.CHI_REQ_WRITENOSNPFULL,
                                     addr=0x7A17_0000 + (beats << 6),
                                     txnid=txnid, size=beats,
                                     data=0xABCD_0000_0000_0000 * (beats + 1)
                                          & ((1 << 512) - 1)))
            txnid += 1


class MultiBeatStressSeq(uvm_sequence):
    """High-volume interleaved multi-beat stress: many mixed reads/writes of
    random burst length (1..MAX_BEATS) with distinct TxnIDs, issued in bursts of
    reads (to build up outstanding transactions past the 16-tag pool and pressure
    the response FIFOs) interleaved with multi-beat writes. Self-throttles on the
    bridge's tag-pool/credit backpressure; the scoreboard proves every burst still
    round-trips with the right per-beat data and length."""
    def __init__(self, name="MultiBeatStressSeq", rounds=6, per_round=10, seed=7):
        super().__init__(name)
        self.rounds = rounds
        self.per_round = per_round
        self.seed = seed

    async def body(self):
        random.seed(self.seed)
        gen = ChiReqRandom()
        txnid = 0
        for _ in range(self.rounds):
            # A burst of reads first (maximizes outstanding count / tag pressure),
            # then a few writes, each with a randomized burst length.
            for _ in range(self.per_round):
                gen.randomize()
                op = _READS[gen.opcode % len(_READS)] if gen.is_write else gen.opcode
                await _send(self, ChiReq(opcode=op, addr=gen.addr,
                                         txnid=txnid & 0xFF, size=gen.size))
                txnid = (txnid + 7) & 0xFF
            for _ in range(max(1, self.per_round // 3)):
                gen.randomize()
                op = _WRITES[gen.opcode % len(_WRITES)]
                await _send(self, ChiReq(opcode=op, addr=gen.addr, txnid=txnid & 0xFF,
                                         size=gen.size,
                                         data=(0x9E3779B97F4A7C15 * (txnid + 1))
                                              & ((1 << 512) - 1)))
                txnid = (txnid + 7) & 0xFF


class CoverageDrivenSeq(uvm_sequence):
    """Closed-loop, coverage-driven generation (PLAN Phase 2).

    Before each transaction, read the LIVE functional-coverage DB and soft-bias
    the crv toward the request opcode / burst-length bins still uncovered, so the
    random stream converges on 100% of the generation-reachable functional set
    quickly and deterministically -- instead of relying on blind randomness to
    eventually stumble into every bin. Stops as soon as the generation-reachable
    bins are all hit; `hit_at` records how many transactions that took.
    """
    def __init__(self, name="CoverageDrivenSeq", max_txns=64, seed=3):
        super().__init__(name)
        self.max_txns = max_txns
        self.seed = seed
        self.hit_at = None          # #txns at which opcode+beats bins all closed

    async def body(self):
        random.seed(self.seed)
        gen = ChiReqRandom()
        dut = cocotb.top
        txnid = 0
        for i in range(self.max_txns):
            unc_ops = cov.uncovered_opcodes()
            unc_beats = cov.uncovered_beats()
            if not unc_ops and not unc_beats:
                self.hit_at = i
                break
            # Soft (numeric-weight) constraints: heavily favour an uncovered
            # opcode / burst length, but stay satisfiable once a set is closed.
            gen.randomize_with(
                lambda opcode: 50 if opcode in unc_ops else 1,
                lambda size: 50 if size in unc_beats else 1)
            # crv returns numpy scalars; cast to plain int for handle assignment.
            opcode, size, addr = int(gen.opcode), int(gen.size), int(gen.addr)
            data = ((0x9E3779B97F4A7C15 * (txnid + 1)) & ((1 << 512) - 1)
                    if bm.is_write(opcode) else 0)
            await _send(self, ChiReq(opcode=opcode, addr=addr,
                                     txnid=txnid & 0xFF, data=data, size=size))
            txnid = (txnid + 7) & 0xFF
            # Let the request-side observer sample this transaction before the
            # next generation decision reads the coverage DB.
            for _ in range(3):
                await RisingEdge(dut.clk)
        if self.hit_at is None and not cov.uncovered_opcodes() and not cov.uncovered_beats():
            self.hit_at = self.max_txns


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
                                     txnid=txnid, data=data, size=gen.size))
