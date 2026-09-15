"""PyUVM CHI-side agent + CXL responder + response monitor for chi_to_cxl_bridge.

Mirrors the SV/UVM taxonomy (sequence_item / driver / monitor / sequencer /
agent) the way ../ucie2-pipe7-bridge/dv/pyuvm/agents/fdi_agent.py does, so test
intent maps 1:1 and the cycle-accurate cross-check stays meaningful.

  * ChiDriver     drives CHI REQ (reads and writes) on `clk`; for a write it waits
                  for the bridge's DBIDResp before sending the WrData beat.
  * CxlResponder  emulates the CXL.mem device on `cxl_clk`: always accepts M2S
                  Req/RwD, then returns S2M DRS(MemData) for reads and NDR(Cmp)
                  for writes, echoing the bridge-assigned Tag.
  * ChiRspMonitor owns the CHI response accept side (`clk`): records DBIDResps for
                  the driver, and publishes Comp / CompData to the scoreboard.

Every response the responder injects is a deterministic function of the observed
request (read data = bridge_model.read_data_for_addr(addr)), so the scoreboard can
predict the full round trip from the driven stimulus alone.
"""
import cocotb
from cocotb.triggers import RisingEdge
from pyuvm import (uvm_sequence_item, uvm_driver, uvm_monitor, uvm_agent,
                   uvm_component, uvm_sequencer, uvm_analysis_port, ConfigDB)

import bridge_model as bm


def _i(handle):
    """Settled int read of a DUT handle (x/z -> 0)."""
    try:
        return int(handle.value)
    except Exception:
        return 0


# ============================ sequence item ==================================
class ChiReq(uvm_sequence_item):
    """One CHI request: a read, or a write carrying its data. `size` is the CHI
    request size field, which the bridge maps to a runtime burst length of
    `beats` = 1..MAX_BEATS (via bm.chi_req_beats). A write drives `beats` WrData
    beats; a read returns `beats` CompData beats. The default size keeps the item
    single-beat, so existing sequences are unchanged."""
    def __init__(self, name="ChiReq", opcode=bm.CHI_REQ_READNOSNP, addr=0,
                 txnid=0, data=0, size=6):
        super().__init__(name)
        self.opcode = opcode
        self.addr = addr
        self.txnid = txnid
        self.data = data
        self.size = size

    @property
    def is_write(self):
        return bm.is_write(self.opcode)

    @property
    def beats(self):
        return bm.chi_req_beats(self.size)

    def __str__(self):
        kind = "WR" if self.is_write else "RD"
        return (f"ChiReq({kind} op=0x{self.opcode:02x} addr=0x{self.addr:012x} "
                f"txnid=0x{self.txnid:02x} beats={self.beats})")


# ============================ CHI response monitor ===========================
class ChiRspMonitor(uvm_monitor):
    """Owns the CHI response accept side: always ready, records DBIDResps for the
    driver (keyed by TxnID), and publishes Comp and CompData to the scoreboard."""
    def build_phase(self):
        self.comp_ap = uvm_analysis_port("comp_ap", self)      # Comp (write done)
        self.compdata_ap = uvm_analysis_port("compdata_ap", self)  # CompData (read return)
        self.dbid = {}                                          # txnid -> DBID/tag
        ConfigDB().set(None, "*", "RSP_MON", self)

    async def wait_dbid(self, txnid, clk):
        while txnid not in self.dbid:
            await RisingEdge(clk)
        return self.dbid[txnid]

    async def run_phase(self):
        dut = cocotb.top
        dut.chi_rsp_ready.value = 1
        dut.chi_comp_data_ready.value = 1
        cocotb.start_soon(self._rsp_loop(dut))
        cocotb.start_soon(self._compdata_loop(dut))

    async def _rsp_loop(self, dut):
        while True:
            await RisingEdge(dut.clk)
            if _i(dut.chi_rsp_valid) and _i(dut.chi_rsp_ready):
                rsp = _i(dut.chi_rsp_data)
                op = bm.get(rsp, bm.CHI_RSP["OPCODE"])
                txnid = bm.get(rsp, bm.CHI_RSP["TXNID"])
                if op == bm.CHI_RSP_DBIDRESP:
                    self.dbid[txnid] = bm.get(rsp, bm.CHI_RSP["DBID"])
                elif op == bm.CHI_RSP_COMP:
                    self.comp_ap.write(("comp", txnid, rsp))

    async def _compdata_loop(self, dut):
        while True:
            await RisingEdge(dut.clk)
            if _i(dut.chi_comp_data_valid) and _i(dut.chi_comp_data_ready):
                dat = _i(dut.chi_comp_data)
                self.compdata_ap.write(
                    ("compdata", bm.get(dat, bm.CHI_DAT["TXNID"]),
                     bm.get(dat, bm.CHI_DAT["DATA"])))


# ============================ CHI driver =====================================
class ChiDriver(uvm_driver):
    """Drives CHI REQ from the sequencer; for writes, waits for the bridge
    DBIDResp then drives the WrData beat. Publishes each driven request as the
    scoreboard's expected stream."""
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        dut = cocotb.top
        rsp_mon = ConfigDB().get(self, "", "RSP_MON")
        dut.chi_req_valid.value = 0
        dut.chi_wr_data_valid.value = 0
        while True:
            req = await self.seq_item_port.get_next_item()
            await self._drive_req(dut, req)
            if req.is_write:
                await rsp_mon.wait_dbid(req.txnid, dut.clk)
                await self._drive_wrdata(dut, req)
            self.ap.write(("req", req.opcode, req.addr, req.txnid, req.data, req.beats))
            self.seq_item_port.item_done()

    async def _drive_req(self, dut, req):
        dut.chi_req_data.value = bm.make_chi_req(req.opcode, req.addr, req.txnid,
                                                 size=req.size)
        dut.chi_req_valid.value = 1
        await RisingEdge(dut.clk)
        while not _i(dut.chi_req_ready):
            await RisingEdge(dut.clk)
        dut.chi_req_valid.value = 0

    async def _drive_wrdata(self, dut, req):
        for beat in range(req.beats):
            dut.chi_wr_data.value = bm.make_chi_wr_data(bm.wr_beat_data(req.data, beat))
            dut.chi_wr_data_valid.value = 1
            await RisingEdge(dut.clk)
            while not _i(dut.chi_wr_data_ready):
                await RisingEdge(dut.clk)
        dut.chi_wr_data_valid.value = 0


# ============================ CXL responder ==================================
class CxlResponder(uvm_component):
    """Emulates the CXL.mem device on `cxl_clk`. Always accepts M2S Req/RwD,
    publishes the observed M2S flits for the translation cross-check, and returns
    S2M DRS(MemData)/NDR(Cmp) echoing the bridge-assigned Tag. Read data is a
    deterministic function of the address (bridge_model.read_data_for_addr)."""
    def build_phase(self):
        self.m2s_req_ap = uvm_analysis_port("m2s_req_ap", self)   # observed reads
        self.m2s_rwd_ap = uvm_analysis_port("m2s_rwd_ap", self)   # observed writes
        self._drs_q = []   # pending (tag, data) DRS to return
        self._ndr_q = []   # pending (tag,) NDR to return
        self._rwd_seen = {}  # tag -> RwD beats seen so far (for multi-beat writes)

    async def run_phase(self):
        dut = cocotb.top
        dut.cxl_tx_req_ready.value = 1
        dut.cxl_tx_rwd_ready.value = 1
        dut.cxl_rx_ndr_valid.value = 0
        dut.cxl_rx_drs_valid.value = 0
        cocotb.start_soon(self._accept_loop(dut))
        cocotb.start_soon(self._drs_loop(dut))
        cocotb.start_soon(self._ndr_loop(dut))

    async def _accept_loop(self, dut):
        while True:
            await RisingEdge(dut.cxl_clk)
            if _i(dut.cxl_tx_req_valid) and _i(dut.cxl_tx_req_ready):
                flit = _i(dut.cxl_tx_req_data)
                tag = bm.get(flit, bm.CXL_REQ["TAG"])
                addr = bm.get(flit, bm.CXL_REQ["ADDR"])
                beats = bm.get(flit, bm.CXL_REQ["LEN"])
                # One M2S Req carries LEN; return that many DRS beats for the read.
                self.m2s_req_ap.write(("m2s_req", bm.get(flit, bm.CXL_REQ["MEMOP"]),
                                       addr, tag, beats))
                for k in range(beats):
                    self._drs_q.append((tag, bm.read_data_for_addr(addr, k)))
            if _i(dut.cxl_tx_rwd_valid) and _i(dut.cxl_tx_rwd_ready):
                flit = _i(dut.cxl_tx_rwd_data)
                tag = bm.get(flit, bm.CXL_RWD["TAG"])
                beats = bm.get(flit, bm.CXL_RWD["LEN"])
                k = self._rwd_seen.get(tag, 0)
                # Each RwD beat is published in order; the device completes (NDR)
                # once it has consumed all LEN beats of the write burst.
                self.m2s_rwd_ap.write(("m2s_rwd", bm.get(flit, bm.CXL_RWD["MEMOP"]),
                                       bm.get(flit, bm.CXL_RWD["ADDR"]), tag,
                                       bm.get(flit, bm.CXL_RWD["DATA"]), k, beats))
                k += 1
                if k >= beats:
                    self._ndr_q.append((tag,))
                    self._rwd_seen[tag] = 0
                else:
                    self._rwd_seen[tag] = k

    async def _drs_loop(self, dut):
        while True:
            await RisingEdge(dut.cxl_clk)
            if self._drs_q and not _i(dut.cxl_rx_drs_valid):
                tag, data = self._drs_q[0]
                dut.cxl_rx_drs_data.value = bm.make_cxl_drs(tag, data)
                dut.cxl_rx_drs_valid.value = 1
            if _i(dut.cxl_rx_drs_valid) and _i(dut.cxl_rx_drs_ready):
                self._drs_q.pop(0)
                dut.cxl_rx_drs_valid.value = 0

    async def _ndr_loop(self, dut):
        while True:
            await RisingEdge(dut.cxl_clk)
            if self._ndr_q and not _i(dut.cxl_rx_ndr_valid):
                (tag,) = self._ndr_q[0]
                dut.cxl_rx_ndr_data.value = bm.make_cxl_ndr(tag)
                dut.cxl_rx_ndr_valid.value = 1
            if _i(dut.cxl_rx_ndr_valid) and _i(dut.cxl_rx_ndr_ready):
                self._ndr_q.pop(0)
                dut.cxl_rx_ndr_valid.value = 0


# ============================ agent ==========================================
class ChiCxlAgent(uvm_agent):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.driver = ChiDriver("driver", self)
        self.rsp_mon = ChiRspMonitor("rsp_mon", self)
        self.responder = CxlResponder("responder", self)
        ConfigDB().set(None, "*", "CHI_SEQR", self.seqr)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)
