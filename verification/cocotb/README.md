# cocotb + PyVSC functional coverage — chi_to_cxl_bridge

OSS, UVM-equivalent regression for the bridge built on **cocotb** (Python
testbench, Icarus VPI) with **PyVSC** (`vsc`) SystemVerilog-style **functional
coverage** (covergroups, coverpoints, crosses, UCIS XML export).

This layer targets the *protocol / translation* surface and its functional
coverage. Structural / clock-ratio behaviour (CDC, 1:1 / 2:1 / 1:3) is covered by
the directed Icarus TB and the `async_fifo` SymbiYosys proof; line coverage is
owned by the Verilator harness (`make coverage`). Both cocotb clocks run at a 1:1
ratio here so the valid/ready handshake is free of cross-edge sampling races.

## Files

| File | Role |
|:---|:---|
| `env.py` | Packet pack helpers, CRC-8, gold models (`expect_cxl_from_chi` / `expect_chi_from_cxl`), and the `CHIDriver` / `CXLDriver` valid/ready drivers + `reset_dut`. Pure-Python port of the RTL `translate_*` / `defs`. |
| `coverage.py` | PyVSC covergroups (`ReqCoverage`, `RspCoverage`) + `sample_*` helpers. |
| `test_chi_to_cxl_bridge.py` | cocotb tests: per-kind directed checks, a randomized soak, a directed coverage-closure test, and a final report/gate test. |
| `Makefile` | cocotb run (Icarus); exports `COV_GOAL`. |

## Coverage model

See [../../doc/coverage-plan.md](../../doc/coverage-plan.md) for the full plan.

```
ReqCoverage (per accepted CHI request -> CXL.mem M2S flit)
  cp_req_kind : READ / WRITE / ATOMIC / DATALESS
  cp_cxl_op   : MEMRD / MEMRDS / MEMWR / MEMWRPTL / MEMINV
  cp_route    : non-posted / posted

RspCoverage (per accepted CXL.mem S2M flit -> CHI response)
  cp_rsp_kind : DRS / NDR / DBID
  cp_status   : OK / ERR
  cp_crc      : bad / good
  cp_chi_rsp  : COMPDATA / COMP / DBIDRESP / INVALID
  cr_kind_crc : cross(cp_rsp_kind, cp_crc)
```

The final test prints a coverage report, writes a **UCIS XML** database to
`cov.xml`, and fails if overall coverage is below `COV_GOAL` (default `100.0`).

## Running

```bash
make            # from this directory (or `make cocotb` from the repo root)
make COV_GOAL=90.0     # relax the coverage gate
COCOTB_RESULTS_FILE=results.xml make   # JUnit XML (default)
```

Outputs: `results.xml` (cocotb JUnit), `cov.xml` (PyVSC UCIS coverage DB).

## Environment / setup

cocotb runs the testbench under the **pip Python** (`cocotb-config --python-bin`,
here `/usr/bin/python3`), not the OSS CAD Suite Python. Install the two Python
deps into that interpreter:

```bash
/usr/bin/python3 -m pip install --user cocotb==1.8.1 pyvsc
```

The `Makefile` already:
- pins `ICARUS_BIN_DIR=/usr/bin` (use the system Icarus, not the OSS-suite build,
  to avoid a Python/VPI mismatch);
- sets `PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)`;
- strips `VIRTUAL_ENV` / `PYTHONHOME` so the pip-installed VPI loads cleanly.

PyVSC pulls in `pyboolector` (constraint solver) and `pyucis` (UCIS XML writer)
as dependencies; both install from wheels via the command above.

## Notes

- The drivers drive signals synchronously *after* a clock edge and hold `valid`
  until the `ready` edge, which is exactly-once and robust to back-to-back beats
  (a combinational `ready` otherwise races cocotb's value application).
- A harmless `DeprecationWarning` from `vsc` (`__int__ returned non-int`) is
  emitted by the PyVSC scalar model under Python 3.10/3.11; it does not affect
  results.
