#!/usr/bin/env python3
"""Structural clock-domain-crossing (CDC) check for chi_to_cxl_bridge.

Open-source CDC gate (Phase 5.0). Consumes a *flattened* Yosys JSON netlist in
which the sanctioned CDC primitives (async_fifo, cdc_sync, reset_sync,
credit_pulse_sync) are kept as BLACKBOXES, and proves the core structural CDC
property:

    No sequential element's data/enable/reset cone reaches a register (or RAM
    read) in the OTHER clock domain except through a sanctioned CDC primitive.

i.e. every real clk<->cxl_clk crossing goes through a vetted synchronizer; a
future edit that wires one domain's register straight into the other's logic is
flagged. Cone traversal stops at register outputs, RAM reads, primary inputs,
constants, and blackbox outputs -- the blackbox outputs are the sanctioned
boundaries, so this trusts that a signal emerging from a primitive is consumed in
its intended domain (that internal correctness is covered by the standalone
async_fifo/cdc_sync formal proofs). Scope/limitation is intentional and documented.

Usage:  cdc_check.py <netlist.json> <top_module> [clk] [cxl_clk]
Exit 0 = no unsynchronized register-to-register crossings; 1 = violation(s).
"""
import json
import sys
from collections import defaultdict

# Yosys cell types that are sequential state elements (domain = their CLK).
_FF_TYPES = {"$dff", "$dffe", "$adff", "$adffe", "$sdff", "$sdffe", "$sdffce",
             "$dffsr", "$dffsre", "$aldff", "$aldffe", "$dlatch"}
# Fallback input-port names (excluding the clock) for the FF family, used only
# if a cell somehow lacks port_directions.
_FF_INPUTS = ("D", "EN", "ARST", "SRST", "SET", "CLR", "ALOAD", "AD")


def _bits(conn):
    """Yosys connection -> list of signal bits (ints for nets, str for consts)."""
    return conn if isinstance(conn, list) else [conn]


def check(netlist_path, top, clk_name="clk", cxlclk_name="cxl_clk"):
    with open(netlist_path) as f:
        design = json.load(f)
    if top not in design["modules"]:
        sys.exit(f"[CDC] top module '{top}' not in netlist "
                 f"(have: {', '.join(design['modules'])})")
    m = design["modules"][top]
    cells = m["cells"]
    ports = m["ports"]

    # --- clock nets -> domain name ---
    def _port_bits(name):
        return set(b for b in ports.get(name, {}).get("bits", []) if isinstance(b, int))
    clk_bits = _port_bits(clk_name)
    cxl_bits = _port_bits(cxlclk_name)
    if not clk_bits or not cxl_bits:
        sys.exit(f"[CDC] could not find clock ports '{clk_name}'/'{cxlclk_name}'")

    def clk_domain(clk_conn):
        for b in _bits(clk_conn):
            if b in clk_bits:
                return clk_name
            if b in cxl_bits:
                return cxlclk_name
        return None            # gated/derived clock -- unknown

    def cell_io(cell):
        """(input_bits, output_bits) using port_directions, with an FF fallback."""
        pd = cell.get("port_directions")
        ins, outs = [], []
        if pd:
            for pname, d in pd.items():
                (outs if d == "output" else ins).extend(
                    _bits(cell["connections"].get(pname, [])))
        else:
            for pname, conn in cell["connections"].items():
                (ins if pname in _FF_INPUTS else outs).extend(_bits(conn))
        return ins, outs

    # --- classify cells; build bit colouring and the combinational driver map ---
    source_color = {}          # bit -> domain, for register/RAM-read outputs
    comb_driver = {}           # bit -> cell name (combinational driver)
    seq_elems = []             # (label, domain, [input cone bits]) to check
    mem_domain = {}            # memid -> domain (from its write port clock)

    # First pass: memory write-port clocks define each RAM's domain.
    for name, c in cells.items():
        if c["type"] in ("$memwr", "$memwr_v2"):
            mid = c.get("parameters", {}).get("MEMID")
            d = clk_domain(c["connections"].get("CLK", []))
            if d:
                mem_domain[mid] = d

    for name, c in cells.items():
        t = c["type"]
        conns = c["connections"]
        if t == "$scopeinfo":
            continue
        if t in _FF_TYPES:
            dom = clk_domain(conns.get("CLK", []))
            for b in _bits(conns.get("Q", [])):
                source_color[b] = dom
            ins, _ = cell_io(c)
            ins = [b for b in ins if b not in _bits(conns.get("CLK", []))]
            seq_elems.append((f"FF {name}", dom, ins))
        elif t in ("$memrd", "$memrd_v2"):
            mid = c.get("parameters", {}).get("MEMID")
            dom = mem_domain.get(mid, clk_domain(conns.get("CLK", [])))
            for b in _bits(conns.get("DATA", [])):
                source_color[b] = dom
            # the address/enable cone of a read is also domain-sensitive
            seq_elems.append((f"MEMRD {mid}", dom,
                              _bits(conns.get("ADDR", [])) + _bits(conns.get("EN", []))))
        elif t in ("$memwr", "$memwr_v2"):
            mid = c.get("parameters", {}).get("MEMID")
            dom = mem_domain.get(mid)
            seq_elems.append((f"MEMWR {mid}", dom,
                              _bits(conns.get("ADDR", [])) + _bits(conns.get("DATA", []))
                              + _bits(conns.get("EN", []))))
        elif t.startswith("$"):
            # combinational primitive: map each output bit to this cell
            _, outs = cell_io(c)
            for b in outs:
                comb_driver[b] = name
        else:
            # module instance = sanctioned CDC primitive (blackbox) OR other
            # sub-block: its outputs are cone boundaries (neutral).
            pass

    # --- for each sequential element, trace its input cone for a foreign source ---
    violations = []
    for label, dom, cone_bits in seq_elems:
        if dom is None:
            continue
        seen, stack = set(), list(cone_bits)
        while stack:
            b = stack.pop()
            if not isinstance(b, int) or b in seen:
                continue
            seen.add(b)
            if b in source_color:                 # reached a register / RAM read
                src = source_color[b]
                if src is not None and src != dom:
                    violations.append((label, dom, src, b))
                continue                           # register output = cone boundary
            drv = comb_driver.get(b)
            if drv is None:                        # port / const / blackbox out
                continue
            ins, _ = cell_io(cells[drv])
            stack.extend(ins)

    # --- report ---
    n_clk = sum(1 for _, d, _ in seq_elems if d == clk_name)
    n_cxl = sum(1 for _, d, _ in seq_elems if d == cxlclk_name)
    n_prim = sum(1 for c in cells.values()
                 if not c["type"].startswith("$") and c["type"] != "$scopeinfo")
    print(f"[CDC] {top}: {n_clk} {clk_name}-domain + {n_cxl} {cxlclk_name}-domain "
          f"sequential elements; {n_prim} sanctioned CDC-primitive instances.")
    if violations:
        print(f"[CDC] FAIL: {len(violations)} unsynchronized cross-domain path(s):")
        seen_pairs = set()
        for label, dom, src, bit in violations:
            key = (label, src)
            if key in seen_pairs:
                continue
            seen_pairs.add(key)
            print(f"  - {label} (domain {dom}) has a {src}-domain register in its "
                  f"combinational cone (net bit {bit}) with no CDC primitive between.")
        return 1
    print("[CDC] PASS: no unsynchronized register-to-register cross-domain paths "
          "(all crossings go through the sanctioned CDC primitives).")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    args = sys.argv[1:]
    sys.exit(check(*args))
