#!/usr/bin/env python3
"""Cycle-accurate cross-check: diff two per-cycle traces column-for-column.

Aligned with ../ucie2-pipe7-bridge/tools/trace_compare.py. Both traces are emitted
by test_smoke.py using the shared column order in
verification/common/models/trace_format.py; this tool is generic over the two
sources (labelled via --a-label/--b-label), so it serves the cross-SIMULATOR
consistency check (Verilator vs Icarus smoke) here in place of the reference's
SV-UVM-vs-PyUVM check.

Fails on: a header mismatch, the FIRST divergent cycle, or a length mismatch.
Exit 0 = the two traces track cycle-for-cycle.
"""
import argparse
import sys


def load(path):
    with open(path) as f:
        lines = [ln.rstrip("\n") for ln in f if ln.strip()]
    if not lines:
        sys.exit(f"trace_compare: {path} is empty")
    return lines[0], lines[1:]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--a", required=True, help="first trace CSV")
    ap.add_argument("--b", required=True, help="second trace CSV")
    ap.add_argument("--a-label", default="A")
    ap.add_argument("--b-label", default="B")
    args = ap.parse_args()

    a_hdr, a_rows = load(args.a)
    b_hdr, b_rows = load(args.b)
    la, lb = args.a_label, args.b_label

    if a_hdr != b_hdr:
        print("HEADER MISMATCH", file=sys.stderr)
        print(f"  {la}: {a_hdr}", file=sys.stderr)
        print(f"  {lb}: {b_hdr}", file=sys.stderr)
        return 2
    cols = a_hdr.split(",")

    n = min(len(a_rows), len(b_rows))
    for i in range(n):
        ac, bc = a_rows[i].split(","), b_rows[i].split(",")
        if ac != bc:
            print(f"DIVERGENCE at cycle {i}:", file=sys.stderr)
            for j in range(min(len(ac), len(bc))):
                if ac[j] != bc[j]:
                    print(f"  {cols[j]}: {la}={ac[j]} {lb}={bc[j]}", file=sys.stderr)
            return 1

    if len(a_rows) != len(b_rows):
        print(f"LENGTH MISMATCH: {la}={len(a_rows)} cycles, {lb}={len(b_rows)} "
              f"cycles (matched first {n})", file=sys.stderr)
        return 1

    print(f"[TRACE] {la} and {lb} agree cycle-for-cycle ({n} cycles)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
