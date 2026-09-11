"""Canonical per-cycle trace format for the chi_to_cxl_bridge cross-check.

Mirrors dv/common/models/trace_format.py in ../ucie2-pipe7-bridge: the single
source of truth for the cycle-accurate trace. The pyuvm bench emits one line per
CHI-domain clock (`clk`) to a ``*.trace`` file using exactly this column order;
tools/trace_compare.py diffs two such traces and fails on the first divergent
cycle. Observable DUT boundary only -- outputs any environment must agree on.

If you add or reorder a column here, update every trace emitter to match.
"""

# Column 0 is the free-running clk cycle index; the rest are observable outputs
# on the CHI (clk) boundary of chi_to_cxl_bridge.
TRACE_COLUMNS = [
    "cycle",
    "chi_req_ready",       # CHI REQ accept
    "chi_wr_data_ready",   # CHI WrData accept
    "chi_rsp_valid",       # CHI RSP present (Comp / DBIDResp)
    "chi_comp_data_valid", # CHI CompData present
    "cxl_tx_req_valid",    # M2S Req present
    "cxl_tx_rwd_valid",    # M2S RwD present
    "drain_done",          # reset-drain complete
    "chi_rsp_data",        # hex, no 0x prefix, zero-padded to CHI_RSP_W nibbles
]

TRACE_HEADER = ",".join(TRACE_COLUMNS)

# CHI_RSP_W = 25 bits -> 7 nibbles.
_RSP_NIBBLES = 7


def format_row(cycle, sig):
    """Return one CSV trace line. ``sig`` maps column name -> int value."""
    cells = [str(cycle)]
    for col in TRACE_COLUMNS[1:]:
        val = int(sig.get(col, 0))
        cells.append(format(val, "0{}x".format(_RSP_NIBBLES))
                     if col == "chi_rsp_data" else str(val))
    return ",".join(cells)
