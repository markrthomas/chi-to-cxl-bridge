"""Independent Python gold model of chi_to_cxl_bridge (Phase 3a-c).

Bit-exact mirror of the field maps and translation functions in
src/chi_to_cxl_bridge_defs.vh / src/chi_to_cxl_bridge.v. The pyuvm scoreboard
uses this as a reference the RTL must agree with, so a common-mode bug in one
cannot pass silently. No RTL is imported -- the constants below are transcribed
from the defs header and MUST be kept in sync with it.

Channels (single beat, 64-byte data):
  CHI REQ  in   -> CXL M2S Req (read)  /  CXL M2S RwD (write, after DBIDResp+WrData)
  CXL S2M DRS  -> CHI CompData (read return)
  CXL S2M NDR  -> CHI Comp     (write completion)
"""

# ============================ field maps (from defs.vh) ======================
# (lsb, width) per field. Names mirror <FLIT>_<FIELD>.
CHI_REQ = {
    "ORDER": (0, 2), "MEMATTR": (2, 4), "SIZE": (6, 3), "ADDR": (9, 48),
    "OPCODE": (57, 7), "TXNID": (64, 8), "SRCID": (72, 7), "TGTID": (79, 7),
    "QOS": (86, 4),
}
CHI_REQ_W = 90

CHI_RSP = {
    "RESPERR": (0, 2), "DBID": (2, 4), "TXNID": (6, 8), "OPCODE": (14, 4),
    "SRCID": (18, 7),
}
CHI_RSP_W = 25

CHI_DAT = {
    "DATA": (0, 512), "BE": (512, 64), "POISON": (576, 1), "DATAID": (577, 4),
    "RESPERR": (581, 2), "RESP": (583, 3), "TXNID": (586, 8), "OPCODE": (594, 4),
}
CHI_DAT_W = 598

CXL_REQ = {
    "TC": (0, 2), "ADDR": (2, 48), "TAG": (50, 4), "METAVAL": (54, 2),
    "METAFLD": (56, 2), "SNPTYPE": (58, 3), "MEMOP": (61, 4),
}
CXL_REQ_W = 65

CXL_RWD = {
    "DATA": (0, 512), "BE": (512, 64), "POISON": (576, 1), "METAVAL": (577, 2),
    "METAFLD": (579, 2), "ADDR": (581, 48), "TAG": (629, 4), "MEMOP": (633, 4),
}
CXL_RWD_W = 637

CXL_NDR = {
    "DEVLOAD": (0, 2), "TAG": (2, 4), "METAVAL": (6, 2), "METAFLD": (8, 2),
    "OPCODE": (10, 3),
}
CXL_NDR_W = 13

CXL_DRS = {
    "DATA": (0, 512), "POISON": (512, 1), "DEVLOAD": (513, 2), "TAG": (515, 4),
    "METAVAL": (519, 2), "METAFLD": (521, 2), "OPCODE": (523, 3),
}
CXL_DRS_W = 526

# ============================ opcodes / codes ================================
CHI_REQ_READNOSNP = 0x04
CHI_REQ_READONCE = 0x03
CHI_REQ_WRITENOSNPFULL = 0x1D
CHI_REQ_WRITENOSNPPTL = 0x1C
CHI_REQ_WRITEUNIQUEFULL = 0x19

CHI_RSP_COMP = 0x4
CHI_RSP_DBIDRESP = 0x3
CHI_RSP_COMPDBIDRESP = 0x5

CHI_DAT_COMPDATA = 0x4
CHI_DAT_NCBWRDATA = 0x3

CHI_RESPERR_OK = 0x0

CXL_MEMRD = 0x1
CXL_MEMRDDATA = 0x2
CXL_MEMWR = 0x3
CXL_MEMWRPTL = 0x4
CXL_MEMINV = 0x5

CXL_NDR_CMP = 0x0
CXL_DRS_MEMDATA = 0x0

BE_W = 64
DATA_W = 512
_BE_ALL = (1 << BE_W) - 1

READ_OPS = (CHI_REQ_READNOSNP, CHI_REQ_READONCE)
WRITE_OPS = (CHI_REQ_WRITENOSNPFULL, CHI_REQ_WRITENOSNPPTL, CHI_REQ_WRITEUNIQUEFULL)


# ============================ bit-field helpers ==============================
def get(val, field):
    lsb, w = field
    return (val >> lsb) & ((1 << w) - 1)


def pack(layout, **fields):
    """Pack named fields (default 0) into an int per the given layout dict."""
    out = 0
    for name, (lsb, w) in layout.items():
        v = fields.get(name.lower(), 0) & ((1 << w) - 1)
        out |= v << lsb
    return out


def is_write(opcode):
    return opcode in WRITE_OPS


def is_read(opcode):
    return opcode in READ_OPS


# ============================ translations (mirror RTL) ======================
def chi_req_to_cxl_req(chi_pkt, tag):
    """translate_chi_req_to_cxl (M2S Req for reads)."""
    op = get(chi_pkt, CHI_REQ["OPCODE"])
    if op == CHI_REQ_READNOSNP:
        memop = CXL_MEMRD
    elif op == CHI_REQ_READONCE:
        memop = CXL_MEMRDDATA
    else:
        memop = CXL_MEMINV
    return pack(CXL_REQ, memop=memop, tag=tag,
                addr=get(chi_pkt, CHI_REQ["ADDR"]))


def chi_wr_to_cxl_rwd(chi_req, chi_dat, tag):
    """translate_chi_wr_to_cxl (M2S RwD for writes)."""
    op = get(chi_req, CHI_REQ["OPCODE"])
    memop = CXL_MEMWRPTL if op == CHI_REQ_WRITENOSNPPTL else CXL_MEMWR
    return pack(CXL_RWD, memop=memop, tag=tag,
                addr=get(chi_req, CHI_REQ["ADDR"]),
                poison=get(chi_dat, CHI_DAT["POISON"]),
                be=get(chi_dat, CHI_DAT["BE"]),
                data=get(chi_dat, CHI_DAT["DATA"]))


def cxl_ndr_to_chi_comp(cxl_ndr, txnid):
    """translate_cxl_ndr_to_chi + the tag-manager TXNID recovery at the boundary.

    The RTL fills TXNID=0 in the translate and the recovery mux overwrites it
    with the original request TXNID; the observable boundary value is `txnid`.
    """
    return pack(CHI_RSP, resperr=CHI_RESPERR_OK,
                dbid=get(cxl_ndr, CXL_NDR["TAG"]),
                txnid=txnid, opcode=CHI_RSP_COMP)


def cxl_drs_to_chi_compdata(cxl_drs, txnid):
    """translate_cxl_drs_to_chi + boundary TXNID recovery (see above)."""
    return pack(CHI_DAT, data=get(cxl_drs, CXL_DRS["DATA"]), be=_BE_ALL,
                poison=get(cxl_drs, CXL_DRS["POISON"]),
                resperr=CHI_RESPERR_OK, txnid=txnid, opcode=CHI_DAT_COMPDATA)


# ============================ stimulus builders ==============================
def make_chi_req(opcode, addr, txnid, srcid=0, size=6):
    return pack(CHI_REQ, opcode=opcode, addr=addr, txnid=txnid, srcid=srcid,
                size=size)


def make_chi_wr_data(data, be=_BE_ALL, poison=0):
    return pack(CHI_DAT, data=data, be=be, poison=poison, opcode=CHI_DAT_NCBWRDATA)


def make_cxl_ndr(tag, opcode=CXL_NDR_CMP):
    return pack(CXL_NDR, tag=tag, opcode=opcode)


def make_cxl_drs(tag, data, poison=0, opcode=CXL_DRS_MEMDATA):
    return pack(CXL_DRS, tag=tag, data=data, poison=poison, opcode=opcode)


def read_data_for_addr(addr):
    """Deterministic 512-bit read-return pattern for an address, so a read's
    CompData is predictable end-to-end without a shared mutable memory."""
    lane = (addr * 0x9E3779B97F4A7C15 + 0xA5A5A5A5) & ((1 << 64) - 1)
    val = 0
    for i in range(DATA_W // 64):
        val |= ((lane ^ (i * 0x0101010101010101)) & ((1 << 64) - 1)) << (64 * i)
    return val
