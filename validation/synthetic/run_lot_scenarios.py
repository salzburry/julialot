#!/usr/bin/env python3
"""Re-run the worked scenarios through the engine and hold them to what they say.

    python3 validation/synthetic/run_lot_scenarios.py

Jul 28/exploration/lot/R/lot_scenarios.R carries a treatment history and the
lines the engine builds from it. That second half is the part a reader trusts
and the part that goes stale silently: change a threshold and the file still
claims the old answer.

So the patients are planted here, the engine's own SQL is run over them, and
the lines that come back are compared with the ones the file states. A
mismatch exits non-zero and prints both.

Same duckdb + sqlglot harness as run_synthetic.py, and the same emitted chain,
so what runs is the engine's SQL and not a model of it.
"""
import os, re, sys, tempfile, subprocess, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    import duckdb                      # noqa: F401
    import run_synthetic as rs
except ImportError as ex:
    sys.exit(f"SKIP: {ex.name} is not installed; this harness needs duckdb and sqlglot")

REPO = os.path.dirname(os.path.dirname(HERE))
FOLDER = os.environ.get("STUDY_FOLDER", "Jul 28")
CATALOGUE = os.path.join(REPO, FOLDER, "exploration", "lot", "R", "lot_scenarios.R")
IX = 300                                # index day, as run_synthetic numbers them
EPOCH = datetime.date(2016, 1, 1) + datetime.timedelta(days=IX)


def scenarios(path):
    """Read id, patient and lines out of the R catalogue.

    A parse of the R rather than a second copy of the data. The three fields
    are each a fixed shape, so this reads them without evaluating anything -
    the catalogue is data, and running it to get the data back would need R.
    """
    src = open(path, encoding="utf-8").read()
    out = []
    for blk in re.finditer(r'list\(id = "([^"]+)", group = "([^"]*)",(.*?)\n\n', src + "\n\n",
                           re.S):
        sid, group, body = blk.group(1), blk.group(2), blk.group(3)
        pm = re.search(r"patient = list\((.*?)\),\n", body, re.S)
        lm = re.search(r"lines = c\((.*?)\),\n", body, re.S)
        if not pm or not lm:
            continue
        p = pm.group(1)
        meds = re.search(r'meds = "([^"]*)"', p)
        auto = re.search(r'auto = "([^"]*)"', p)
        ac = re.search(r'ac = "([^"]*)"', p)
        subs = re.search(r'subs = "([^"]*)"', p)
        death = re.search(r"death = (\d+)", p)
        obs = re.search(r"obs = (\d+)", p)
        lines = [x.strip() for x in re.findall(r'"([^"]*)"', lm.group(1))]
        out.append(dict(
            id=sid, group=group, lines=lines,
            meds=[t.strip() for t in (meds.group(1) if meds else "").split(";") if t.strip()],
            auto=[int(x) for x in (auto.group(1).split(",") if auto else []) if x.strip()],
            ac=[t.strip() for t in (ac.group(1) if ac else "").split(",") if t.strip()],
            subs=[t.strip() for t in (subs.group(1) if subs else "").split(",") if t.strip()],
            death=int(death.group(1)) if death else None,
            obs=int(obs.group(1)) if obs else 1200))
    return out


def plant(sc):
    maps = []
    for m in sc["meds"]:
        abbr, cls, a, b = [x.strip() for x in m.split(":")]
        maps.append((abbr, cls, IX + int(a), IX + int(b), 0))
    ac = []
    for e in sc["ac"]:
        typ, d = [x.strip() for x in e.split(":")]
        ac.append((typ, IX + int(d)))
    obs = IX + sc["obs"]
    return dict(pid=sc["id"], index=IX, death=(IX + sc["death"] if sc["death"] else None),
                obs_end=obs, maps=maps, sct_ac=ac,
                sct_auto=[IX + d for d in sc["auto"]],
                spans=[(IX - 365, obs)], strict=[(IX - 365, obs)])


def day(x):
    x = x.date() if isinstance(x, datetime.datetime) else x
    return (x - EPOCH).days


def rendered(rows):
    """The same shape the catalogue writes: LOTn dA-dB TYPE REASON regimen R."""
    out = []
    for n, a, b, typ, reason, meds in rows:
        meds = (meds or "").strip()
        out.append("LOT%d  d%d-d%d  %s  %s  regimen %s"
                   % (n, day(a), day(b), typ, reason, meds if meds else "(none)"))
    return out


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def main():
    if not os.path.exists(CATALOGUE):
        print("SKIP: no scenario catalogue at", CATALOGUE)
        return 3
    scs = scenarios(CATALOGUE)
    if not scs:
        sys.exit("read no scenarios out of " + CATALOGUE)

    sqldir = tempfile.mkdtemp(prefix="lot_scen_")
    r = subprocess.run(["Rscript", os.path.join(HERE, "emit_chain.R"), sqldir],
                       capture_output=True, text=True)
    if r.returncode == 3:
        print(r.stdout.strip() or "SKIP")
        return 3
    if r.returncode != 0:
        sys.exit("emit failed:\n" + r.stdout + r.stderr)

    con = duckdb.connect()
    con.execute("SET TimeZone='UTC'")
    rs.load(con, [plant(s) for s in scs])
    # Biosimilar pairs, and a rollup row for any agent the harness's own list
    # does not carry - the engine reads mma_rollup for every drug it sees.
    known = {m for m, _ in rs.ROLLUP}
    for s in scs:
        for pair in s["subs"]:
            orig, sub = [x.strip() for x in pair.split(":")]
            con.execute("INSERT INTO permissible_subs VALUES (?, ?)", [orig, sub])
        for m in s["meds"]:
            abbr, cls = [x.strip() for x in m.split(":")[:2]]
            if abbr not in known:
                known.add(abbr)
                con.execute("INSERT INTO mma_rollup VALUES (?, ?, NULL, NULL)",
                            [abbr, cls])
    rs.run_chain(con, sqldir)
    print("%d scenarios planted and run through the engine\n" % len(scs))

    bad = 0
    for s in scs:
        rows = con.execute(
            "SELECT LOT_NUM, LOT_START_DT, LOT_BASE_END_DT, LOT_START_TYPE, "
            "LOT_BASE_END_REASON, LOT_BASE_MEDS FROM lot_long "
            "WHERE PATID = ? ORDER BY LOT_NUM", [s["id"]]).fetchall()
        got = rendered(rows)
        want = s["lines"]
        ok = len(got) == len(want) and all(norm(a) == norm(b) for a, b in zip(got, want))
        print("  %-5s %s" % (s["id"], "ok" if ok else "DIFFERS"))
        if not ok:
            bad += 1
            print("     the file says")
            for l in want:
                print("       ", l)
            print("     the engine builds")
            for l in got or ["(no lines)"]:
                print("       ", l)
    print()
    if bad:
        print("%d scenario(s) no longer match the engine." % bad)
        return 1
    print("every scenario matches the lines the catalogue states")
    return 0


if __name__ == "__main__":
    sys.exit(main())
