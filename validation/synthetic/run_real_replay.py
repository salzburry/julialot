#!/usr/bin/env python3
"""Replay REAL patients' extracted LOT inputs through the engine's own SQL.

  python3 validation/synthetic/run_real_replay.py <dir-of-extract-csvs>

<dir> is what `lot/qc/extract_patients.R` wrote on the platform:
lot_patient_input.csv, map_stacked.csv, tx_auto_dates.csv,
tx_allo_cart_dates.csv, permissible_subs.csv, med_universe.csv,
lot_long_final.csv and run_pin.csv.

Why this exists. When a run's lines look wrong for a patient there are three
possible answers, and only one of them is a bug:

  1. the engine's rules are wrong
  2. the run was built by code that is not the code in front of you
  3. the patient's shape is not the shape anyone reasoned about

A HAND-BUILT patient can only ever answer (1) about a hand-built patient. It
plants the shape someone believed the patient had - and if that belief is what
is wrong, the plant agrees with the belief and the real patient goes on being
unexplained. This puts the patient's OWN rows through the same statements, so
the three separate: the replay either reproduces the run's lines (so the rules
did this, deliberately, to this shape), or it does not (so the run was not
built by this code).

Both arms are run. The fold-in (LOT_RULES.md 4.8) is the rule most often in
question, so the lines are shown with it on and off, and a difference between
the two arms is the rule's own contribution to that patient - the thing an
argument about the rule is actually about.

Nothing here asserts. There is no expected answer for a real patient; that is
the question being asked, not something to assume. It prints, and a reader
compares.

Requires duckdb and sqlglot.
"""
import csv, os, subprocess, sys, tempfile

try:
    import duckdb, sqlglot
except ImportError as ex:
    sys.exit(f"SKIP: {ex.name} is not installed; this needs duckdb and sqlglot")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_synthetic as rs

FILES = ("lot_patient_input", "map_stacked", "tx_auto_dates",
         "tx_allo_cart_dates", "permissible_subs", "med_universe",
         "lot_long_final", "run_pin")


def read_csv(d, name, required=True):
    f = os.path.join(d, name + ".csv")
    if not os.path.exists(f):
        if required:
            sys.exit(f"{f} is missing. Run lot/qc/extract_patients.R and copy "
                     f"the whole out/extract directory across.")
        return []
    with open(f, newline="") as fh:
        return [ {k: (v if v != "" else None) for k, v in row.items()}
                 for row in csv.DictReader(fh) ]


def load_real(con, data):
    """The extracted rows, verbatim.

    Not run_synthetic.load(): that one DERIVES MAP_DISCON_FLG from the gaps it
    plants, which is right for a planted patient and wrong for a real one. The
    warehouse already decided that flag, under the run's own settings, and
    recomputing it here would replay a patient the run never saw.
    """
    for s in rs.DDL.strip().split(';'):
        if s.strip():
            con.execute(s)

    for r in data["med_universe"]:
        con.execute("INSERT INTO mma_rollup VALUES (?,?,NULL,NULL)",
                    [r["MAP_MED_TYPE"], r["MAP_MED_CLASS"]])
    for r in data["permissible_subs"]:
        vals = list(r.values())
        con.execute("INSERT INTO permissible_subs VALUES (?,?)", vals[:2])

    for p in data["lot_patient_input"]:
        con.execute("INSERT INTO lot_patient_input VALUES (?,?,?,?,?,?,?,?,?)",
                    [p["PATID"], p["INDEX_DATE"], p["ENDDATE"], p["ENDDATE_CE"],
                     p["OBS_END_DT"], p["DEATH_DT"], p["GDR_CD"],
                     int(p["YRDOB"]) if p["YRDOB"] else None,
                     int(p["AGE_INDEX_YR"]) if p["AGE_INDEX_YR"] else None])
        con.execute("INSERT INTO coh_1l VALUES (?,?)", [p["PATID"], p["DEATH_DT"]])
        # The emitted chain reads neither spans table - the 2L/3L cohort SQL
        # does, and that is not emitted here - so these cover the observation
        # window and decide nothing.
        for t in ("spans", "spans_strict"):
            con.execute(f"INSERT INTO {t} VALUES (?,?,?)",
                        [p["PATID"], p["INDEX_DATE"], p["OBS_END_DT"]])

    for m in data["map_stacked"]:
        con.execute("INSERT INTO map_stacked VALUES (?,?,?,?,?,?,?)",
                    [m["PATID"], m["MAP_MED_TYPE"], m["MAP_MED_CLASS"],
                     int(m["MAP_CNT"]), m["MAP_START_DT"], m["MAP_END_DT"],
                     int(m["MAP_DISCON_FLG"])])
    for t in data["tx_auto_dates"]:
        con.execute("INSERT INTO tx_auto_dates VALUES (?,?)", [t["PATID"], t["TX_DT"]])
    for t in data["tx_allo_cart_dates"]:
        con.execute("INSERT INTO tx_allo_cart_dates VALUES (?,?,?)",
                    [t["PATID"], t["TX_DT"], t["SCT_TYPE"]])


def arm(data, foldin):
    sqldir = tempfile.mkdtemp(prefix="replay_")
    env = dict(os.environ)
    env["MAP_FOLDIN"] = "TRUE" if foldin else "FALSE"
    # The run's own universe, so the emitted build carries the same flag
    # columns the warehouse build did.
    env["LOT_MEDS"] = ",".join(sorted({r["MAP_MED_TYPE"] for r in data["med_universe"]}))
    env["LOT_CLASSES"] = ",".join(sorted({r["MAP_MED_CLASS"] for r in data["med_universe"]}))
    r = subprocess.run(["Rscript", os.path.join(HERE, "emit_chain.R"), sqldir],
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        sys.exit("emit failed:\n" + r.stdout + r.stderr)
    con = duckdb.connect(); con.execute("SET TimeZone='UTC'")
    load_real(con, data)
    rs.run_chain(con, sqldir)
    out = {}
    for row in con.execute(
            "SELECT PATID, LOT_NUM, LOT_START_DT, LOT_START_TYPE, LOT_BASE_END_DT, "
            "LOT_BASE_END_REASON, coalesce(LOT_BASE_MEDS,''), LOT_MED_CNT "
            "FROM lot_long ORDER BY PATID, LOT_NUM").fetchall():
        out.setdefault(row[0], []).append(
            (row[1], str(row[2])[:10], row[3], str(row[4])[:10], row[5], row[6], row[7]))
    con.close()
    return r.stdout.strip(), out


def fmt(line):
    n, s, st, e, why, meds, cnt = line
    return f"    L{n}  {s} -> {e}  start={st:<9} end={why:<15} n={cnt}  {meds}"


def real_lines(data):
    out = {}
    for r in data["lot_long_final"]:
        out.setdefault(r["PATID"], []).append(
            (int(r["LOT_NUM"]), str(r.get("LOT_START_DT"))[:10],
             r.get("LOT_START_TYPE") or "?", str(r.get("LOT_BASE_END_DT"))[:10],
             r.get("LOT_BASE_END_REASON") or "?", r.get("LOT_BASE_MEDS") or "",
             r.get("LOT_MED_CNT") or ""))
    for v in out.values():
        v.sort()
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    d = sys.argv[1]
    data = {n: read_csv(d, n, required=n != "run_pin") for n in FILES}
    if not data["lot_patient_input"]:
        sys.exit("lot_patient_input.csv has no rows - the run never saw these patients.")

    pin = data["run_pin"][0] if data["run_pin"] else {}
    print("replaying run", pin.get("RUN_ID", "?"), "-", pin.get("UPDATED_AT", "?"))
    if pin.get("CODE_MD5"):
        print("  built by code", pin["CODE_MD5"])
    if pin.get("CONTRACT_SETTINGS"):
        print("  contract    ", pin["CONTRACT_SETTINGS"])
    print(f"  {len(data['lot_patient_input'])} patient(s), "
          f"{len(data['map_stacked'])} episode(s), "
          f"{len(data['tx_auto_dates'])} AUTO, "
          f"{len(data['tx_allo_cart_dates'])} ALLO/CAR-T, "
          f"{len(data['med_universe'])} drug(s) in the run's universe")

    note, on = arm(data, True)
    print(" ", note)
    _, off = arm(data, False)

    real = real_lines(data)
    agree = differ = 0
    for p in sorted({r["PATID"] for r in data["lot_patient_input"]}):
        print(f"\n{'='*72}\n{p}")
        eps = [m for m in data["map_stacked"] if m["PATID"] == p]
        print("  episodes")
        for m in eps:
            print(f"    {m['MAP_START_DT']} -> {m['MAP_END_DT']}  "
                  f"{m['MAP_MED_TYPE']:<8} {m['MAP_MED_CLASS']:<8} "
                  f"cnt={m['MAP_CNT']} discon={m['MAP_DISCON_FLG']}")
        tx = ([("AUTO", t["TX_DT"]) for t in data["tx_auto_dates"] if t["PATID"] == p] +
              [(t["SCT_TYPE"], t["TX_DT"]) for t in data["tx_allo_cart_dates"]
               if t["PATID"] == p])
        print("  transplants", ", ".join(f"{k} {v}" for k, v in sorted(tx, key=lambda x: x[1]))
              or "  none")

        print("  the run's lines (LOT_LONG_FINAL)")
        for l in real.get(p, []) or []:
            print(fmt(l))
        if not real.get(p):
            print("    none")
        print("  replayed, fold-in ON")
        for l in on.get(p, []) or []:
            print(fmt(l))
        if not on.get(p):
            print("    none")
        print("  replayed, fold-in OFF")
        for l in off.get(p, []) or []:
            print(fmt(l))
        if not off.get(p):
            print("    none")

        # LOT_LONG_FINAL is LOT_LONG after the line criteria, and the replay
        # applies none, so a patient the criteria dropped rows from will differ
        # for that reason alone. Dates, start type and end reason are what the
        # rules decide, so that is what is compared.
        key = lambda ls: [(n, s, st, e, why) for (n, s, st, e, why, _m, _c) in ls]
        same = key(on.get(p, [])) == key(real.get(p, []))
        agree, differ = (agree + 1, differ) if same else (agree, differ + 1)
        print("  ->", "the replay reproduces the run's lines" if same else
              "THE REPLAY DOES NOT REPRODUCE THE RUN'S LINES")
        if key(on.get(p, [])) != key(off.get(p, [])):
            print("     and the fold-in changes this patient: the two arms differ")
        else:
            print("     the fold-in changes nothing for this patient: both arms agree")

    print(f"\n{'='*72}")
    print(f"{agree} patient(s) reproduced, {differ} not")
    if differ:
        print("A patient the replay does not reproduce was not built by this code,\n"
              "or the line criteria dropped rows the replay does not apply.")
    else:
        print("Every line these patients have is what this engine does to these rows.\n"
              "If a line looks wrong, the rule is what to argue with - not the build.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
