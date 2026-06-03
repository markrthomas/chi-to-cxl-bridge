"""
Shared packet helpers, gold models, and drivers for chi_to_cxl_bridge cocotb tests.

Mirrors the Verilog pack helpers, bridge_checksum, translate_chi_to_cxl, and
translate_cxl_to_chi functions from chi_to_cxl_bridge_defs.vh / the directed TB.

CHIDriver  : drives chi_req_* (clk domain) and reads chi_rsp_* (clk domain).
CXLDriver  : drives cxl_rx_*  (cxl_clk domain) and reads cxl_tx_* (cxl_clk domain).
reset_dut  : asserts rst_n=0 for 6 clk cycles, then releases with link_up=1.
"""

from cocotb.triggers import RisingEdge

# ---- CHI request packet kinds [63:60] ----
CHI_REQ_KIND_READ     = 0x1
CHI_REQ_KIND_WRITE    = 0x2
CHI_REQ_KIND_ATOMIC   = 0x3
CHI_REQ_KIND_DATALESS = 0x4

# ---- CHI response packet kinds [63:60] ----
CHI_RSP_KIND_COMPDATA = 0x8
CHI_RSP_KIND_COMP     = 0x9
CHI_RSP_KIND_DBIDRESP = 0xA
CHI_RSP_KIND_INVALID  = 0xF

# ---- CHI read / write opcodes (PKT_CODE) ----
CHI_RD_OP_NOSNP  = 0x0
CHI_RD_OP_ONCE   = 0x1
CHI_WR_OP_NOSNP  = 0x0
CHI_WR_OP_UNIQUE = 0x1
CHI_WR_OP_PTL    = 0x2

# ---- CHI response status ----
CHI_RESP_OK  = 0x1
CHI_RESP_ERR = 0x2

# ---- CXL.mem downstream packet kinds [63:60] ----
CXL_M2S_KIND_REQ = 0x8
CXL_S2M_KIND_DRS = 0xA
CXL_S2M_KIND_NDR = 0xB
CXL_S2M_KIND_DBID = 0xC
CXL_KIND_ERROR   = 0xE

# ---- CXL M2S sub-ops (PKT_CODE of CXL_M2S_KIND_REQ) ----
CXL_M2S_MEMRD    = 0x1
CXL_M2S_MEMRDS   = 0x2
CXL_M2S_MEMWR    = 0x3
CXL_M2S_MEMWRPTL = 0x4
CXL_M2S_MEMINV   = 0x5

# ---- CXL S2M response status ----
CXL_RSP_OK  = 0x1
CXL_RSP_ERR = 0x2

# ---- Packet field bit positions ----
PKT_KIND_MSB, PKT_KIND_LSB =  63, 60
PKT_CODE_MSB, PKT_CODE_LSB =  59, 56
PKT_TAG_MSB,  PKT_TAG_LSB  =  55, 48
PKT_ADDR_MSB, PKT_ADDR_LSB =  47, 32
PKT_LEN_MSB,  PKT_LEN_LSB  =  31, 24
PKT_ID_MSB,   PKT_ID_LSB   =  23, 16
PKT_AUX_MSB,  PKT_AUX_LSB  =  15,  8
PKT_MISC_MSB, PKT_MISC_LSB =   7,  0


def _pack64(kind, code, tag, addr, length, id_, aux, misc):
    return (
        ((kind   & 0xF)    << 60) |
        ((code   & 0xF)    << 56) |
        ((tag    & 0xFF)   << 48) |
        ((addr   & 0xFFFF) << 32) |
        ((length & 0xFF)   << 24) |
        ((id_    & 0xFF)   << 16) |
        ((aux    & 0xFF)   <<  8) |
        (misc    & 0xFF)
    )


def get_field(pkt, msb, lsb):
    return (pkt >> lsb) & ((1 << (msb - lsb + 1)) - 1)


# ---- CHI request pack helpers ----

def pack_chi_read(opcode, txn_id, addr16, size, src_id, attr):
    return _pack64(CHI_REQ_KIND_READ, opcode, txn_id, addr16, size, src_id, attr, 0)

def pack_chi_write(opcode, txn_id, addr16, size, src_id, attr):
    return _pack64(CHI_REQ_KIND_WRITE, opcode, txn_id, addr16, size, src_id, attr, 0)

def pack_chi_atomic(opcode, txn_id, addr16, size, src_id, attr):
    return _pack64(CHI_REQ_KIND_ATOMIC, opcode, txn_id, addr16, size, src_id, attr, 0)

def pack_chi_dataless(opcode, txn_id, addr16, size, src_id, attr):
    return _pack64(CHI_REQ_KIND_DATALESS, opcode, txn_id, addr16, size, src_id, attr, 0)


# ---- CHI response pack helpers ----

def pack_chi_compdata(resp, txn_id, byte_count, size, src_id, attr):
    return _pack64(CHI_RSP_KIND_COMPDATA, resp, txn_id, byte_count, size, src_id, attr, 0)

def pack_chi_comp(resp, txn_id, byte_count, size, src_id, attr):
    return _pack64(CHI_RSP_KIND_COMP, resp, txn_id, byte_count, size, src_id, attr, 0)

def pack_chi_dbidresp(resp, txn_id, byte_count, size, src_id, attr):
    return _pack64(CHI_RSP_KIND_DBIDRESP, resp, txn_id, byte_count, size, src_id, attr, 0)


# ---- CXL.mem M2S / S2M pack helpers ----

def pack_cxl_m2s(cxl_op, tag, addr16, size, src_id, attr, checksum=0):
    return _pack64(CXL_M2S_KIND_REQ, cxl_op, tag, addr16, size, src_id, attr, checksum)

def pack_cxl_drs(status, tag, byte_count, size, src_id, attr, checksum=0):
    return _pack64(CXL_S2M_KIND_DRS, status, tag, byte_count, size, src_id, attr, checksum)

def pack_cxl_ndr(status, tag, byte_count, size, src_id, attr, checksum=0):
    return _pack64(CXL_S2M_KIND_NDR, status, tag, byte_count, size, src_id, attr, checksum)

def pack_cxl_dbid(status, tag, byte_count, size, src_id, attr, checksum=0):
    return _pack64(CXL_S2M_KIND_DBID, status, tag, byte_count, size, src_id, attr, checksum)


# ---- Checksum ----

def _crc8_step(b):
    """One byte through 8 iterations of CRC-8/CCITT (poly=0x07). Matches Verilog crc8_step."""
    b &= 0xFF
    for _ in range(8):
        b = ((b << 1) ^ 0x07) & 0xFF if (b & 0x80) else (b << 1) & 0xFF
    return b


def bridge_checksum(pkt_64):
    """CRC-8/CCITT over bytes [63:8] of a 64-bit packet (byte [7:0] must be 0)."""
    c = 0
    for shift in (56, 48, 40, 32, 24, 16, 8):
        c = _crc8_step(c ^ ((pkt_64 >> shift) & 0xFF))
    return c


def with_checksum(pkt_64):
    """Set the MISC byte [7:0] to the CRC-8 checksum of the other 7 bytes."""
    return (pkt_64 & ~0xFF) | bridge_checksum(pkt_64 & ~0xFF)


# ---- Gold models (mirror translate_* functions in bridge RTL) ----

def expect_cxl_from_chi(chi_pkt):
    """Expected CXL.mem M2S flit for a given CHI request packet."""
    kind = get_field(chi_pkt, PKT_KIND_MSB, PKT_KIND_LSB)
    code = get_field(chi_pkt, PKT_CODE_MSB, PKT_CODE_LSB)
    tag  = get_field(chi_pkt, PKT_TAG_MSB,  PKT_TAG_LSB)
    addr = get_field(chi_pkt, PKT_ADDR_MSB, PKT_ADDR_LSB)
    ln   = get_field(chi_pkt, PKT_LEN_MSB,  PKT_LEN_LSB)
    id_  = get_field(chi_pkt, PKT_ID_MSB,   PKT_ID_LSB)
    aux  = get_field(chi_pkt, PKT_AUX_MSB,  PKT_AUX_LSB)
    misc = get_field(chi_pkt, PKT_MISC_MSB, PKT_MISC_LSB)
    attr = (aux ^ misc) & 0xFF

    if kind == CHI_REQ_KIND_READ:
        op = CXL_M2S_MEMRDS if code == CHI_RD_OP_ONCE else CXL_M2S_MEMRD
        return with_checksum(pack_cxl_m2s(op, tag, addr, ln, id_, attr))
    elif kind == CHI_REQ_KIND_WRITE:
        op = CXL_M2S_MEMWRPTL if code == CHI_WR_OP_PTL else CXL_M2S_MEMWR
        return with_checksum(pack_cxl_m2s(op, tag, addr, ln, id_, attr))
    elif kind == CHI_REQ_KIND_ATOMIC:
        return with_checksum(pack_cxl_m2s(CXL_M2S_MEMINV, tag, addr, ln, id_, attr))
    elif kind == CHI_REQ_KIND_DATALESS:
        return with_checksum(pack_cxl_m2s(CXL_M2S_MEMINV, tag, addr, ln, id_, attr))
    else:
        raw = (CXL_KIND_ERROR << 60) | (tag << 48) | (id_ << 16)
        return with_checksum(raw)


def expect_chi_from_cxl(cxl_pkt):
    """Expected CHI response for a given CXL.mem S2M response flit."""
    kind = get_field(cxl_pkt, PKT_KIND_MSB, PKT_KIND_LSB)
    code = get_field(cxl_pkt, PKT_CODE_MSB, PKT_CODE_LSB)
    tag  = get_field(cxl_pkt, PKT_TAG_MSB,  PKT_TAG_LSB)
    addr = get_field(cxl_pkt, PKT_ADDR_MSB, PKT_ADDR_LSB)
    ln   = get_field(cxl_pkt, PKT_LEN_MSB,  PKT_LEN_LSB)
    id_  = get_field(cxl_pkt, PKT_ID_MSB,   PKT_ID_LSB)
    aux  = get_field(cxl_pkt, PKT_AUX_MSB,  PKT_AUX_LSB)
    misc = get_field(cxl_pkt, PKT_MISC_MSB, PKT_MISC_LSB)

    valid_chk = bridge_checksum(cxl_pkt & ~0xFF) == misc
    invalid   = _pack64(CHI_RSP_KIND_INVALID, 0, tag, 0, 0, id_, 0, 0)

    if kind == CXL_S2M_KIND_DRS:
        return pack_chi_compdata(code, tag, addr, ln, id_, aux) if valid_chk else invalid
    elif kind == CXL_S2M_KIND_NDR:
        return pack_chi_comp(code, tag, addr, ln, id_, aux) if valid_chk else invalid
    elif kind == CXL_S2M_KIND_DBID:
        return pack_chi_dbidresp(code, tag, addr, ln, id_, aux) if valid_chk else invalid
    else:
        return invalid


# ---- Routing helpers (mirror is_posted() / arbiter classification in the RTL) ----

def is_posted_kind(kind):
    """True if a CHI request kind routes to the posted FIFO (WRITE only)."""
    return kind == CHI_REQ_KIND_WRITE


def cmd_is_posted(flit):
    """Classify an observed cxl_tx command into the posted (MEMWR/MEMWRPTL) or
    non-posted (MEMRD/MEMRDS/MEMINV + ERROR) FIFO, matching the bridge routing."""
    k  = get_field(flit, PKT_KIND_MSB, PKT_KIND_LSB)
    op = get_field(flit, PKT_CODE_MSB, PKT_CODE_LSB)
    if k == CXL_M2S_KIND_REQ:
        return op in (CXL_M2S_MEMWR, CXL_M2S_MEMWRPTL)
    return False  # ERROR (from an invalid kind) routes via the non-posted FIFO


# ---- Reset ----

async def reset_dut(dut, clk, cxl_clk):
    """Assert rst_n=0 for 6 clk cycles, release with link_up=1, settle both domains."""
    dut.rst_n.value         = 0
    dut.link_up.value       = 0
    dut.err_inj_en.value    = 0
    dut.chi_req_valid.value = 0
    dut.chi_req_data.value  = 0
    dut.cxl_tx_ready.value  = 0
    dut.cxl_rx_valid.value  = 0
    dut.cxl_rx_data.value   = 0
    dut.chi_rsp_ready.value = 0

    for _ in range(6):
        await RisingEdge(clk)

    dut.rst_n.value   = 1
    dut.link_up.value = 1

    for _ in range(4):
        await RisingEdge(clk)
    for _ in range(4):
        await RisingEdge(cxl_clk)


# ---- CHI-domain driver ----

class CHIDriver:
    """Drives chi_req_* and reads chi_rsp_* on the CHI host (clk) domain."""

    def __init__(self, dut, clk):
        self.dut = dut
        self.clk = clk

    async def send(self, pkt, timeout=64):
        dut = self.dut
        clk = self.clk
        # Drive synchronously: set data/valid just after an edge (so the writes
        # land in the ReadWrite region and are sampled at the *next* edge), then
        # hold valid until the edge where ready is high (the transfer), then
        # deassert. This is exactly-once and robust to back-to-back sends, where
        # a combinational ready would otherwise drop or duplicate a beat.
        await RisingEdge(clk)
        dut.chi_req_data.value  = pkt
        dut.chi_req_valid.value = 1
        await RisingEdge(clk)
        for _ in range(timeout):
            if int(dut.chi_req_ready.value) == 1:
                dut.chi_req_valid.value = 0
                return
            await RisingEdge(clk)
        raise AssertionError(f"Timeout on chi_req handshake (pkt=0x{pkt:016x})")

    async def recv(self, timeout=64):
        dut = self.dut
        clk = self.clk
        dut.chi_rsp_ready.value = 1
        for _ in range(timeout):
            await RisingEdge(clk)
            if int(dut.chi_rsp_valid.value) == 1:
                data = int(dut.chi_rsp_data.value)
                dut.chi_rsp_ready.value = 0
                return data
        raise AssertionError("Timeout waiting for chi_rsp_valid")


# ---- CXL-domain driver ----

class CXLDriver:
    """Drives cxl_rx_* and reads cxl_tx_* on the CXL link (cxl_clk) domain."""

    def __init__(self, dut, cxl_clk):
        self.dut     = dut
        self.cxl_clk = cxl_clk

    async def send(self, pkt, timeout=64):
        dut = self.dut
        clk = self.cxl_clk
        # Drive synchronously, exactly-once (see CHIDriver.send for rationale).
        await RisingEdge(clk)
        dut.cxl_rx_data.value  = pkt
        dut.cxl_rx_valid.value = 1
        await RisingEdge(clk)
        for _ in range(timeout):
            if int(dut.cxl_rx_ready.value) == 1:
                dut.cxl_rx_valid.value = 0
                return
            await RisingEdge(clk)
        raise AssertionError(f"Timeout on cxl_rx handshake (pkt=0x{pkt:016x})")

    async def recv(self, timeout=64):
        dut = self.dut
        clk = self.cxl_clk
        dut.cxl_tx_ready.value = 1
        for _ in range(timeout):
            await RisingEdge(clk)
            if int(dut.cxl_tx_valid.value) == 1:
                data = int(dut.cxl_tx_data.value)
                dut.cxl_tx_ready.value = 0
                return data
        raise AssertionError("Timeout waiting for cxl_tx_valid")
