#!/usr/bin/env python3
"""Run a synthetic patient population through the whole LOT chain.

  python3 validation/synthetic/run_synthetic.py [--seed N] [--n N]
                                                [--snap FILE] [--base FILE]

Not a fixture sweep. Patients are generated at random from a fixed seed and
pushed through every statement the build issues, in order. Nothing here says
what any individual patient's answer should be - that is the thing an author
gets wrong, and gets wrong identically in the fixture and the expectation.
What it checks is INVARIANTS: properties that hold whatever the rules are, so a
break surfaces without anyone having to predict it.

Two things it will tell you that a green suite will not:

  COVERAGE. "Every invariant holds" over a population that never reaches a rule
  proves nothing about that rule. The coverage block counts how many patients
  reached each rule, and calls out a bucket reading zero as a green that tested
  nothing.

  REGRESSION. --snap writes a canonical snapshot; --base diffs against one.
  Run it before a change and after, and every row that moved has to be a row
  the change meant to move. One transition type and no line-count change is
  what a clean fix looks like.

Requires duckdb and sqlglot. Neither is a dependency of anything else here,
which is part of why this is opt-in rather than in the merge gate.
"""
import datetime, json, os, random, subprocess, sys, tempfile

try:
    import duckdb, sqlglot
    from sqlglot import exp
except ImportError as ex:
    sys.exit(f"SKIP: {ex.name} is not installed; this harness needs duckdb and sqlglot")

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

EPOCH = datetime.date(2016, 1, 1)
STUDY_END = 3800                       # days from EPOCH
def d(n): return (EPOCH + datetime.timedelta(days=int(n))).isoformat()

MEDS = [('LEN','IMID'), ('BORT','PI'), ('DARA','MAB'),
        ('POMA','IMID'), ('CYCLO','ALKY'), ('CARF','PI')]
STEROID = ('DEX', 'STEROID')


def generate(seed, n):
    """Treatment histories with the awkward shapes deliberately included."""
    rnd = random.Random(seed)
    pats = []
    for i in range(n):
        pid = f"S{i:04d}"
        index = rnd.randint(0, 2600)
        death = None
        if rnd.random() < 0.28:
            death = index + rnd.randint(0, 1500)
            if death > STUDY_END: death = None
        obs_end = min(STUDY_END, death if death is not None else STUDY_END)
        # Without this, treatment finishes years before observation does and
        # nothing exercises the discontinuation buffer. For a share of
        # patients observation ends shortly after treatment - a recent
        # diagnosis meeting the data cutoff - at offsets either side of 90.
        cutoff_close = rnd.random() < 0.45
        cutoff_off = rnd.choice([0, 1, 30, 60, 89, 90, 91, 120, 200])

        maps, sct_ac, sct_auto = [], [], []
        # Induction: agents at 0..70 days, so some land inside the 60-day
        # window and some just outside it.
        for _ in range(rnd.randint(1, 4)):
            med, cls = rnd.choice(MEDS)
            s = index + rnd.choice([0, 0, 0, 1, 7, 28, 55, 59, 60, 61, 70])
            maps.append((med, cls, s, s + rnd.choice([27, 27, 55, 83, 111, 200, 400]), 0))
        if rnd.random() < 0.4:
            maps.append((STEROID[0], STEROID[1], index, index + 27, 0))
        # Later episodes at gaps straddling every threshold the rules use.
        t = index + rnd.randint(30, 400)
        for _ in range(rnd.randint(0, 5)):
            med, cls = rnd.choice(MEDS)
            t += rnd.choice([1, 15, 29, 30, 31, 44, 45, 46, 59, 60, 61,
                             89, 90, 91, 179, 180, 181, 300])
            if t > obs_end + 200: break
            maps.append((med, cls, t, t + rnd.choice([27, 55, 83, 200]), 0))
        # Transplants: tandems either side of 180, CAR-T either side of 60.
        if rnd.random() < 0.30:
            a1 = index + rnd.choice([100, 150, 200, 400])
            sct_auto.append(a1)
            if rnd.random() < 0.35:
                sct_auto.append(a1 + rnd.choice([120, 179, 180, 181, 300]))
        if rnd.random() < 0.12:
            sct_ac.append(('ALLO', index + rnd.choice([0, 200, 500, 900])))
        if rnd.random() < 0.18:
            sct_ac.append(('CART', index + rnd.choice([20, 59, 60, 61, 300, 800])))

        if cutoff_close and maps:
            obs_end = min(obs_end, max(e for (_, _, _, e, _) in maps) + cutoff_off)
        # 03_mma_map bounds every claim source to [INDEX_DATE, OBS_END_DT], so
        # map_stacked cannot hold anything starting outside observation. A
        # generator that ignores that is testing a table the build cannot
        # produce - the first run of this harness did, and both invariant
        # breaks it reported were that and not the code.
        maps = [(m, c, s, min(e, obs_end), f) for (m, c, s, e, f) in maps
                if index <= s <= obs_end]
        if not maps:
            maps = [(MEDS[0][0], MEDS[0][1], index, min(index + 27, obs_end), 0)]
        sct_ac   = [(t_, x) for (t_, x) in sct_ac if index <= x <= obs_end]
        sct_auto = [x for x in sct_auto if index <= x <= obs_end]

        pats.append(dict(pid=pid, index=index, death=death, obs_end=obs_end,
                         maps=maps, sct_ac=sct_ac, sct_auto=sct_auto,
                         spans=[(index - rnd.choice([200, 364, 365, 400, 900]),
                                 obs_end + rnd.choice([0, 100]))],
                         strict=[(index - rnd.choice([100, 365]),
                                  obs_end - rnd.choice([0, 0, 50, 200]))]))
    return pats


def discon_flags(maps):
    """MAP_DISCON_FLG per drug: set when the gap to that drug's next start is
    90+ days, or nothing follows. Mirrors what 03_mma_map computes."""
    out, by_med = [], {}
    for m in maps: by_med.setdefault(m[0], []).append(m)
    for rows in by_med.values():
        rows.sort(key=lambda r: r[2])
        for j, (mm, cls, s, e, _) in enumerate(rows):
            nxt = rows[j + 1][2] if j + 1 < len(rows) else None
            out.append((mm, cls, s, e, 1 if (nxt is None or nxt - e >= 90) else 0))
    return out


DDL = """
CREATE TABLE lot_patient_input (PATID VARCHAR, INDEX_DATE DATE, ENDDATE DATE,
  ENDDATE_CE DATE, OBS_END_DT DATE, DEATH_DT DATE, GDR_CD VARCHAR, YRDOB INT,
  AGE_INDEX_YR INT);
CREATE TABLE map_stacked (PATID VARCHAR, MAP_MED_TYPE VARCHAR, MAP_MED_CLASS VARCHAR,
  MAP_START_DT DATE, MAP_END_DT DATE, MAP_DISCON_FLG INT);
CREATE TABLE mma_rollup (CL_MED_ABBR VARCHAR, CL_MED_CLASS VARCHAR,
  MONOMAINTENANCE VARCHAR, DUALMAINTENANCEWITH VARCHAR);
CREATE TABLE permissible_subs (original_med VARCHAR, substitute_med VARCHAR);
CREATE TABLE tx_auto_dates (PATID VARCHAR, TX_DT DATE);
CREATE TABLE tx_allo_cart_dates (PATID VARCHAR, TX_DT DATE, SCT_TYPE VARCHAR);
CREATE TABLE coh_1l (PATID VARCHAR, DEATH_DT DATE);
CREATE TABLE spans (PATID VARCHAR, cov_start DATE, cov_end DATE);
CREATE TABLE spans_strict (PATID VARCHAR, cov_start DATE, cov_end DATE);
"""


def load(con, pats):
    for s in DDL.strip().split(';'):
        if s.strip(): con.execute(s)
    for med, cls in MEDS + [STEROID]:
        con.execute("INSERT INTO mma_rollup VALUES (?,?,NULL,NULL)", [med, cls])
    for p in pats:
        dd = d(p['death']) if p['death'] is not None else None
        con.execute("INSERT INTO lot_patient_input VALUES (?,?,?,?,?,?,?,?,?)",
                    [p['pid'], d(p['index']), d(p['obs_end']), d(p['obs_end']),
                     d(p['obs_end']), dd, 'M', 1955, 61])
        con.execute("INSERT INTO coh_1l VALUES (?,?)", [p['pid'], dd])
        for med, cls, s, e, flg in discon_flags(p['maps']):
            con.execute("INSERT INTO map_stacked VALUES (?,?,?,?,?,?)",
                        [p['pid'], med, cls, d(s), d(e), flg])
        for day in p['sct_auto']:
            con.execute("INSERT INTO tx_auto_dates VALUES (?,?)", [p['pid'], d(day)])
        for typ, day in p['sct_ac']:
            con.execute("INSERT INTO tx_allo_cart_dates VALUES (?,?,?)",
                        [p['pid'], d(day), typ])
        for a, b in p['spans']:
            con.execute("INSERT INTO spans VALUES (?,?,?)", [p['pid'], d(a), d(b)])
        for a, b in p['strict']:
            con.execute("INSERT INTO spans_strict VALUES (?,?,?)", [p['pid'], d(a), d(b)])


def _fix_concat_ws(node):
    """Spark's concat_ws flattens an array argument; duckdb's stringifies it.

    Left alone, concat_ws(' ', sort_array(collect_set(x))) comes back as the
    literal "[LEN, MELP]" rather than "LEN MELP", so every regimen-string
    predicate downstream silently matches nothing. Every concat_ws in the build
    takes a list, so the rewrite is unconditional here.
    """
    if isinstance(node, exp.ConcatWs) and len(node.expressions) == 2:
        sep, lst = node.expressions
        return exp.Anonymous(this="array_to_string", expressions=[lst, sep])
    return node


def to_duckdb(sql):
    return sqlglot.parse_one(sql, read='spark').transform(_fix_concat_ws).sql(dialect='duckdb')


def run_chain(con, sqldir):
    for i, st in enumerate(open(os.path.join(sqldir, 'full_chain.sql')).read().split('\n;;;\n')):
        if not st.strip(): continue
        # Spark's seeded rand() has no duckdb equivalent; it only breaks a
        # same-day tie between added agents, and pinning it keeps the run
        # reproducible. Dates and line counts do not depend on it.
        st = st.replace('rand(42)', '0')
        try:
            con.execute(to_duckdb(st))
        except Exception as ex:
            raise RuntimeError(f"statement {i} failed: {str(ex)[:400]}\n{st[:300]}")
    # LOT_LONG_FINAL is LOT_LONG after the line criteria; none is enabled here.
    con.execute("CREATE OR REPLACE VIEW lot_long_final AS SELECT * FROM lot_long")
    for n in (2, 3):
        con.execute(to_duckdb(open(os.path.join(sqldir, f'sub_{n}l.sql')).read()))


REASONS = ('SCT_ALLO','SCT_CART','SCT_AUTO','SCT','CART_INIT','MED_ADD',
           'DEATH','DISCONTINUATION','STUDY_END')

CHECKS = [
 ("a line ends before it starts",
  "SELECT PATID, LOT_NUM FROM lot_long WHERE LOT_BASE_END_DT < LOT_START_DT"),
 ("LOT_BASE_LENGTH disagrees with the dates",
  "SELECT PATID, LOT_NUM FROM lot_long WHERE LOT_BASE_LENGTH <> "
  "datediff('day', LOT_START_DT, LOT_BASE_END_DT) + 1"),
 ("a line starts after observation ended",
  "SELECT l.PATID, l.LOT_NUM FROM lot_long l JOIN lot_patient_input p "
  "ON p.PATID = l.PATID WHERE l.LOT_START_DT > p.OBS_END_DT"),
 ("a line ends after observation ended",
  "SELECT l.PATID, l.LOT_NUM FROM lot_long l JOIN lot_patient_input p "
  "ON p.PATID = l.PATID WHERE l.LOT_BASE_END_DT > p.OBS_END_DT"),
 ("an end reason outside the known set",
  f"SELECT DISTINCT LOT_BASE_END_REASON FROM lot_long "
  f"WHERE LOT_BASE_END_REASON NOT IN {REASONS}"),
 ("line numbers are not contiguous from 1",
  "SELECT PATID FROM (SELECT PATID, count(*) c, max(LOT_NUM) m, min(LOT_NUM) n "
  "FROM lot_long GROUP BY PATID) WHERE n <> 1 OR c <> m"),
 ("two rows for one patient and line",
  "SELECT PATID, LOT_NUM FROM lot_long GROUP BY PATID, LOT_NUM HAVING count(*) > 1"),
 ("a later line does not start after the previous one ends",
  "SELECT a.PATID, a.LOT_NUM FROM lot_long a JOIN lot_long b "
  "ON b.PATID = a.PATID AND b.LOT_NUM = a.LOT_NUM - 1 "
  "WHERE a.LOT_START_DT <= b.LOT_BASE_END_DT"),
 ("DISCONTINUATION with no discontinuation date",
  "SELECT PATID, LOT_NUM FROM lot_long WHERE LOT_BASE_END_REASON = 'DISCONTINUATION' "
  "AND LOT_BASE_DISCON_DT IS NULL"),
 ("an unconfirmed discontinuation - B8's invariant",
  "SELECT l.PATID, l.LOT_NUM FROM lot_long l JOIN lot_patient_input p "
  "ON p.PATID = l.PATID WHERE l.LOT_BASE_END_REASON = 'DISCONTINUATION' "
  "AND datediff('day', l.LOT_BASE_END_DT, p.OBS_END_DT) < 90 AND l.LOT_NUM < 5 "
  "AND NOT EXISTS (SELECT 1 FROM lot_long n WHERE n.PATID = l.PATID "
  "                AND n.LOT_NUM = l.LOT_NUM + 1)"),
 ("more lines than the cap",
  "SELECT PATID FROM lot_long WHERE LOT_NUM > 5"),
 ("a line for a patient with no MAP row",
  "SELECT DISTINCT l.PATID FROM lot_long l LEFT JOIN map_stacked m "
  "ON m.PATID = l.PATID WHERE m.PATID IS NULL"),
 ("in 3L but not in 2L",
  "SELECT PATID FROM coh_3l WHERE PATID NOT IN (SELECT PATID FROM coh_2l)"),
 ("a cohort row whose index is not that line's start",
  "SELECT c.PATID FROM coh_2l c JOIN (SELECT PATID, min(LOT_START_DT) ix "
  "FROM lot_long WHERE LOT_NUM = 2 GROUP BY PATID) l ON l.PATID = c.PATID "
  "WHERE c.COHORT_INDEX_DATE <> l.ix"),
 ("a cohort row published without both enrolment flags",
  "SELECT PATID FROM coh_2l WHERE CE_PRE <> 1 OR CE_FU <> 1"),
 ("a cohort patient with no such line",
  "SELECT c.PATID FROM coh_2l c WHERE NOT EXISTS "
  "(SELECT 1 FROM lot_long l WHERE l.PATID = c.PATID AND l.LOT_NUM = 2)"),
]

COVERAGE = [
 ("lines ending within 90d of observation end",
  "datediff('day', l.LOT_BASE_END_DT, p.OBS_END_DT) < 90"),
 ("discontinuations inside the buffer",
  "l.LOT_BASE_DISCON_DT IS NOT NULL AND "
  "datediff('day', l.LOT_BASE_DISCON_DT, p.OBS_END_DT) < 90"),
 ("lines censored at STUDY_END",       "l.LOT_BASE_END_REASON = 'STUDY_END'"),
 ("lines ended by a transplant or CAR-T",
  "l.LOT_BASE_END_REASON IN ('SCT_ALLO','SCT_CART','SCT_AUTO','CART_INIT')"),
 ("lines started by something other than a drug", "l.LOT_START_TYPE <> 'MED'"),
 ("single-day lines",                  "l.LOT_BASE_LENGTH = 1"),
]


def snapshot(con):
    rows = con.execute(
        "SELECT PATID, LOT_NUM, LOT_START_DT, LOT_START_TYPE, LOT_BASE_END_DT, "
        "LOT_BASE_END_REASON, LOT_BASE_LENGTH, LOT_BASE_MEDS "
        "FROM lot_long ORDER BY PATID, LOT_NUM").fetchall()
    return {"lines": [[str(x) for x in r] for r in rows],
            "coh": {str(n): sorted(r[0] for r in
                    con.execute(f"SELECT PATID FROM coh_{n}l").fetchall())
                    for n in (2, 3)}}


def arg(name, default, cast=str):
    return cast(sys.argv[sys.argv.index(name) + 1]) if name in sys.argv else default


def main():
    seed, npat = arg('--seed', 20260813, int), arg('--n', 600, int)
    snap_to, base = arg('--snap', None), arg('--base', None)

    sqldir = tempfile.mkdtemp(prefix="lot_synth_")
    r = subprocess.run(["Rscript", os.path.join(HERE, "emit_chain.R"), sqldir],
                       capture_output=True, text=True)
    if r.returncode == 3:
        print(r.stdout.strip() or "SKIP"); return 0
    if r.returncode != 0:
        sys.exit("emit failed:\n" + r.stdout + r.stderr)
    print(r.stdout.strip())

    con = duckdb.connect(); con.execute("SET TimeZone='UTC'")
    load(con, generate(seed, npat))
    probe = sqlglot.transpile("SELECT datediff(date '2024-01-11', date '2024-01-01')",
                              read='spark', write='duckdb')[0]
    assert con.execute(probe).fetchall()[0][0] == 10, "datediff does not mean a - b here"
    print(f"calibration ok; {npat} synthetic patients, seed {seed}\n")

    run_chain(con, sqldir)
    q = lambda s: con.execute(s).fetchall()
    print(f"{q('SELECT count(*) FROM lot_long')[0][0]} lines over "
          f"{q('SELECT count(DISTINCT PATID) FROM lot_long')[0][0]} patients")
    print("  by line   ", ", ".join(f"L{a}={b}" for a, b in
          q("SELECT LOT_NUM, count(*) FROM lot_long GROUP BY 1 ORDER BY 1")))
    print("  by reason ", ", ".join(f"{a}={b}" for a, b in
          q("SELECT LOT_BASE_END_REASON, count(*) FROM lot_long GROUP BY 1 ORDER BY 2 DESC")))
    for n in (2, 3):
        print(f"  {n}L cohort: {q(f'SELECT count(*) FROM coh_{n}l')[0][0]}")

    print("\ncoverage of the input space")
    vacuous = 0
    for name, pred in COVERAGE:
        v = q(f"SELECT sum(CASE WHEN {pred} THEN 1 ELSE 0 END) FROM lot_long l "
              f"JOIN lot_patient_input p ON p.PATID = l.PATID")[0][0] or 0
        if not v: vacuous += 1
        print(f"  {name:46} {v}{'   <-- nothing here, so nothing was tested' if not v else ''}")

    bad = [(n, rows) for n, sql in CHECKS for rows in [q(sql)] if rows]
    print()
    if bad:
        print(f"{len(bad)} INVARIANT(S) BROKEN:")
        for name, rows in bad:
            print(f"  - {name}: {len(rows)} row(s)  e.g. {rows[:3]}")
    else:
        print("every invariant holds")
    if vacuous:
        print(f"...but {vacuous} coverage bucket(s) are empty, so that green is "
              f"partly vacuous")

    snap = snapshot(con)
    if snap_to:
        json.dump(snap, open(snap_to, 'w'), indent=0)
        print(f"snapshot written to {snap_to}")
    if base:
        old = json.load(open(base))
        a = {(r[0], r[1]): r for r in old['lines']}
        b = {(r[0], r[1]): r for r in snap['lines']}
        only = set(a) ^ set(b)
        moved = sorted(k for k in set(a) & set(b) if a[k] != b[k])
        print(f"\nvs {base}")
        print(f"  lines present in one run only: {len(only)}")
        print(f"  lines whose value changed:     {len(moved)}")
        seen = {}
        for k in moved:
            seen[(a[k][5], b[k][5])] = seen.get((a[k][5], b[k][5]), 0) + 1
        for (x, y), n in sorted(seen.items(), key=lambda kv: -kv[1]):
            print(f"    {x:16} -> {y:16} {n}")
        for n in (2, 3):
            da = set(old['coh'][str(n)]) ^ set(snap['coh'][str(n)])
            print(f"  {n}L membership differs for {len(da)} patient(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
