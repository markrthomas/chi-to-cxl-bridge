#!/usr/bin/env python3
"""Random regression driver for chi_to_cxl_bridge (build / run / triage / replay).

Stimulus: verification/random/rr_test.py (seeded) on the pyuvm env, so the checker is the
existing BridgeScoreboard. Contract and knobs: README.md in this directory.
"""
import argparse
import concurrent.futures as cf
import datetime
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(HERE, "runs")
CORPUS = os.path.join(HERE, "corpus.json")
BUILD = os.path.join(HERE, "build", "sim_build")
TIMEOUT = int(os.environ.get("RR_TIMEOUT", "300"))

PROFILES = ["mix", "read", "write", "burst"]
BPS = [0, 20, 50, 80]
GAPS = [0, 2, 8]


def knobs(seed):
    """Config derived from the seed only (so 'seed' alone reproduces a job)."""
    return dict(profile=PROFILES[seed % 4], bp=BPS[(seed // 4) % 4],
                gap=GAPS[(seed // 16) % 3], n=20 + (seed * 7) % 41)


def cfg_str(k):
    return "profile=%(profile)s bp=%(bp)d gap=%(gap)d n=%(n)d" % k


def sim_cmd(seed, k, results, ):
    return ["make", "-C", HERE, "-f", "sim.mk", "COCOTB_RESULTS_FILE=" + results,
            "RR_SEED=%d" % seed, "RR_PROFILE=%s" % k["profile"], "RR_BP=%d" % k["bp"],
            "RR_GAP=%d" % k["gap"], "RR_N=%d" % k["n"]]


def repro_cmd(seed, k):
    return ("make -C verification/random -f sim.mk COCOTB_RESULTS_FILE=/tmp/rr_%d.xml "
            "RR_SEED=%d RR_PROFILE=%s RR_BP=%d RR_GAP=%d RR_N=%d"
            % (seed, seed, k["profile"], k["bp"], k["gap"], k["n"]))


def signature(text, rc, timed_out):
    """First failing check, normalised so numbers/hex do not split clusters."""
    if timed_out:
        return "TIMEOUT (hang)"
    m = re.search(r"cross-check failed:\s*\n\s*(.+)", text)
    line = m.group(1) if m else None
    if line is None:
        for pat in (r"AssertionError.*", r"ASSERT.*", r"%Error.*", r"Traceback.*", r"ERROR.*"):
            m = re.search(pat, text)
            if m:
                line = m.group(0)
                break
    if line is None:
        line = "unknown failure rc=%d" % rc
    line = re.sub(r"0x[0-9a-fA-F]+", "0xH", line)
    line = re.sub(r"\b\d+\b", "N", line)
    return line.strip()[:160]


def run_one(seed, k, logpath):
    res = logpath[:-4] + ".xml"
    t0 = time.time()
    timed_out = False
    try:
        p = subprocess.run(sim_cmd(seed, k, res), capture_output=True, text=True, timeout=TIMEOUT)
        out, rc = p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        out, rc, timed_out = (e.stdout or b"").decode(errors="replace"), 1, True
    with open(logpath, "w") as f:
        f.write(out)
    ok = (rc == 0 and not timed_out and "FAIL=0" in out and "PASS=1" in out
          and "cross-check PASS" in out)
    return ok, ("" if ok else signature(out, rc, timed_out)), out


def cmd_build(_a):
    # Compile + a tiny smoke sim (the smoke verdict is irrelevant here: a mutated DUT
    # may legitimately fail it; only a missing simulator binary is a build failure).
    os.makedirs(os.path.join(HERE, "build"), exist_ok=True)
    r = subprocess.run(["make", "-C", HERE, "-f", "sim.mk",
                        "COCOTB_RESULTS_FILE=" + os.path.join(HERE, "build", "build.xml"),
                        "RR_SEED=1", "RR_N=4", "sim"], capture_output=True, text=True)
    if not os.path.exists(os.path.join(BUILD, "Vtop")):
        print(r.stdout[-3000:], r.stderr[-2000:])
        return 1
    print("rr-build: OK (%s)" % os.path.relpath(BUILD))
    return 0


def cmd_run(a):
    base = a.seed
    # Bring the model up to date once, serially (jobs must not race a rebuild after
    # an RTL edit); an up-to-date build makes this a no-op.
    if cmd_build(a) != 0:
        print("rr run: build failed")
        return 2
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S")
    d = os.path.join(RUNS, ts)
    os.makedirs(d, exist_ok=True)
    jobs = []
    for i in range(a.n):
        s = base + i
        jobs.append((i, s, knobs(s), os.path.join(d, "job%04d.log" % i)))

    def work(j):
        i, s, k, lp = j
        ok, sig, _ = run_one(s, k, lp)
        return {"job": i, "seed": s, "config": cfg_str(k), "status": "PASS" if ok else "FAIL",
                "signature": sig, "log": os.path.relpath(lp), "repro": repro_cmd(s, k)}

    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        rows = list(ex.map(work, jobs))
    with open(os.path.join(d, "results.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    fails = sum(r["status"] == "FAIL" for r in rows)
    print("rr run: %s seed_base=%d jobs=%d fail=%d" % (os.path.relpath(d), base, a.n, fails))
    return 1 if fails else 0


def cmd_triage(a):
    run = a.run
    if not run:
        subs = sorted(os.listdir(RUNS)) if os.path.isdir(RUNS) else []
        if not subs:
            print("rr-triage: no runs under %s" % RUNS)
            return 1
        run = os.path.join(RUNS, subs[-1])
    f = os.path.join(run, "results.jsonl") if os.path.isdir(run) else run
    rows = [json.loads(l) for l in open(f) if l.strip()]
    clusters = {}
    for r in rows:
        if r["status"] == "FAIL":
            clusters.setdefault(r["signature"], []).append(r)
    if not clusters:
        print("rr-triage: %s: no failures (%d jobs)" % (run, len(rows)))
        return 0
    for sig, rs in sorted(clusters.items(), key=lambda kv: -len(kv[1])):
        print("cluster count=%d seeds=%s sig=%r repro: %s"
              % (len(rs), ",".join(str(r["seed"]) for r in rs[:5]), sig, rs[0]["repro"]))
    return 0


def cmd_replay(_a):
    corpus = json.load(open(CORPUS))
    d = os.path.join(RUNS, "replay")
    os.makedirs(d, exist_ok=True)
    bad = 0
    for e in corpus.get("entries", []):
        k = knobs(e["seed"])
        k.update({x: e[x] for x in ("profile", "bp", "gap", "n") if x in e})
        ok, sig, _ = run_one(e["seed"], k, os.path.join(d, "%s.log" % e["id"]))
        fixed = bool(e.get("fixed"))
        verdict = "PASS" if ok else "FAIL"
        good = ok if fixed else True      # unfixed (known-open) entries may fail
        print("replay %-20s seed=%d fixed=%s -> %s%s" % (e["id"], e["seed"], fixed, verdict,
                                                         "" if ok else "  (%s)" % sig))
        bad += 0 if good else 1
    print("rr-replay: %d entries, %d regressions" % (len(corpus.get("entries", [])), bad))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("build")
    r = sp.add_parser("run")
    r.add_argument("--n", type=int, default=20)
    r.add_argument("--jobs", type=int, default=2)
    r.add_argument("--seed", type=int, default=1)
    t = sp.add_parser("triage")
    t.add_argument("--run", default="")
    sp.add_parser("replay")
    a = ap.parse_args()
    return {"build": cmd_build, "run": cmd_run, "triage": cmd_triage, "replay": cmd_replay}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
