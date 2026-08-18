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
sys.path.insert(0, HERE)
REPO = os.path.dirname(os.path.dirname(HERE))

EPOCH = datetime.date(2016, 1, 1)
STUDY_END = 3800                       # days from EPOCH
def d(n): return (EPOCH + datetime.timedelta(days=int(n))).isoformat()

MEDS = [('LEN','IMID'), ('BORT','PI'), ('DARA','MAB'),
        ('POMA','IMID'), ('CYCLO','ALKY'), ('CARF','PI')]
STEROID = ('DEX', 'STEROID')
# Melphalan is in the code-list universe but never in a random history. A
# conditioning dose is a shape - one dose beside a transplant, sometimes a
# second one later - not a drug someone happens to be on, so drawing it would
# measure something the rule is not about. planted() builds the shapes.
MELP = ('MELP', 'ALKY')
ROLLUP = MEDS + [STEROID, MELP]


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
        # Never on the index date. A line ends the day BEFORE its allograft, so
        # an index-date ALLO would end LOT1 before it starts and leave the ALLO
        # line nowhere to begin - a shape the CDM does not produce either.
        if rnd.random() < 0.12:
            sct_ac.append(('ALLO', index + rnd.choice([45, 200, 500, 900])))
        if rnd.random() < 0.18:
            sct_ac.append(('CART', index + rnd.choice([20, 59, 60, 61, 300, 800])))

        if cutoff_close and maps:
            obs_end = min(obs_end, max(e for (_, _, _, e, _) in maps) + cutoff_off)
        # 03_mma_map bounds every claim source to [INDEX_DATE, OBS_END_DT], so
        # map_stacked cannot hold anything starting outside observation. A
        # generator that ignores that is testing a table the build cannot
        # produce - the first run of this harness did, and both invariant
        # breaks it reported were that and not the code.
        maps = [(m, c, s, e, f) for (m, c, s, e, f) in maps
                if index <= s <= obs_end]
        maps = coalesce_same_drug(maps)
        maps = [(m, c, s, min(e, obs_end), f) for (m, c, s, e, f) in maps]
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
    return pats + planted()


def planted():
    """The shapes a random draw reaches too rarely to rely on.

    Everything above is drawn. That is the point of the harness, but it means a
    rule reached by a narrow combination of dates can go untested for a whole
    run and the coverage line reads zero. The ones below are built by hand so
    they are always there.

    Most are the same combination: a regimen that runs out EARLY and a
    transplant later in the same window. That is what SCT_AUTO_CONT exists for,
    and drawing it needs a short supply and a transplant in the right 60 days
    at once.

    Two are the CAR-T-started line, which is the shape most likely to orphan a
    transplant: a CAR-T line with no consolidation drug ends on its own start
    date, so its whole 45-day window sits after the end and every AUTO in that
    window depends on the hold to belong anywhere.

    The last is a transplant that lands BEFORE the patient's first line. The
    generator cannot draw it - its transplants start at least 100 days after
    index and its first medication by day 70 - and it is the shape that decides
    whether an unowned transplant is a defect or a reconciliation number.

    Still no expected answers. These are patients, not fixtures - they widen
    what the invariants are asked about, and nothing here says what any line
    should come back as.
    """
    ix, out = 300, []

    def pat(pid, maps, auto=(), ac=()):
        obs = ix + 1200
        out.append(dict(pid=pid, index=ix, death=None, obs_end=obs,
                        maps=maps, sct_ac=list(ac), sct_auto=list(auto),
                        spans=[(ix - 365, obs)], strict=[(ix - 365, obs)]))

    # Cover to day 19, transplant on day 40 - inside line 1's 60-day window,
    # and 21 days after the line would otherwise have run out.
    pat('P0000', [('LEN', 'IMID', ix, ix + 19, 0)], auto=[ix + 40])
    # The same patient with the transplant one day past the window, where it
    # cannot hold line 1 open and has to land somewhere else.
    pat('P0001', [('LEN', 'IMID', ix, ix + 19, 0)], auto=[ix + 60])
    # In-window transplant with a tandem partner far outside it. The partner
    # follows the first only because nothing happens between them.
    pat('P0002', [('LEN', 'IMID', ix, ix + 19, 0)],
        auto=[ix + 40, ix + 40 + 179])
    # An allograft on day 9 ends line 1 before the day-40 transplant. The build
    # stops reading a line's transplants at the first allograft, so that
    # transplant is not line 1's to hold - the case a check without the same
    # censor reports as an orphan.
    pat('P0003', [('LEN', 'IMID', ix, ix + 19, 0)],
        auto=[ix + 40], ac=[('ALLO', ix + 9)])
    # A CAR-T opens line 2 with no drug joining it, then a transplant 20 days
    # later - inside the 45-day consolidation window, and after the line would
    # otherwise have ended on its own start date. B5c is the check that has to
    # see this one, and it could not while it censored on the CAR-T that
    # started the line.
    pat('P0004', [('LEN', 'IMID', ix, ix + 19, 0)],
        auto=[ix + 220], ac=[('CART', ix + 200)])
    # The same shape with the CAR-T at line 2 and a later AUTO outside the
    # window, so the two sides of the window are both present.
    pat('P0005', [('LEN', 'IMID', ix, ix + 19, 0)],
        auto=[ix + 250], ac=[('CART', ix + 200)])
    # A transplant on day 5, with the first medication episode on day 20. The
    # SCT step keeps claims from INDEX_DATE and a line opens on the first
    # non-steroid episode, so the day-5 transplant belongs to no line and no
    # rule could have given it one. E5 must not call that a defect; E5b counts
    # it. Its twin - the same mismatch on a patient who never gets a line - is
    # what E5b used to be scoped to on its own.
    pat('P0006', [('LEN', 'IMID', ix + 20, ix + 200, 0)], auto=[ix + 5])

    # The melphalan shapes the rule in R/melp_rule.R is written against, one
    # patient each. Nothing here says what their lines should be - the point is
    # that MELP_RULE has something to act on at all. Without them the whole
    # rule is unreachable: MELP is not in any random history, so every mode
    # emitted different SQL and produced identical output.
    #
    #   A.1  a single conditioning dose inside induction
    #   A.2  inside induction, next exposure 180+ days later
    #   B.1  outside induction, next exposure inside 60 days
    #   B.2  outside induction, next exposure 60-179 days later
    #   B.3  outside induction, next exposure 180+ days later
    # LEN runs to d400, so the line is STILL ACTIVE at every melphalan dose
    # below. With LEN stopping at d90 the line had already ended before the
    # outside-induction doses, so each one opened a line by itself and the
    # branch under test was never reached - which is why all three modes
    # produced identical output on them.
    def melp(pid, doses, auto=(), cover=400):
        pat(pid, [('LEN', 'IMID', ix, ix + cover, 0)] +
                 [(MELP[0], MELP[1], ix + d, ix + d, 0) for d in doses], auto=auto)
    melp('M0001', [14, 14 + 100], auto=[ix + 21])   # A.1  in, next  <180
    melp('M0002', [14, 14 + 200], auto=[ix + 21])   # A.2  in, next >=180
    melp('M0003', [120, 120 + 30])                  # B.1  out, next  <60
    melp('M0004', [120, 120 + 90])                  # B.2  out, next 60-179
    melp('M0005', [120, 120 + 200])                 # B.3  out, next >=180
    # The control: no melphalan at all, and a regimen drug returning after a
    # confirmed gap. The melphalan modes must not move this patient - if they
    # do, a difference between the cells is not the melphalan rule.
    pat('M0006', [('LEN', 'IMID', ix, ix + 29, 0),
                  ('DARA', 'MAB', ix, ix + 199, 0),
                  ('LEN', 'IMID', ix + 150, ix + 180, 0)])
    # B.2 with the line ENDING BETWEEN the two doses, which M0004 cannot reach:
    # its LEN runs to d400, so the line is open at both. Here LEN runs out at
    # d150 and is confirmed 90 days later, so the line's own end lands between
    # the doses at d120 and d210. Removing melphalan's two boundaries is then
    # not enough - the request says both doses stay in the current line, and
    # without a hold the line ends at its run-out and the second dose falls
    # outside it. This is the patient that tells the two apart.
    melp('M0007', [120, 120 + 90], cover=150)
    # A.1 and B.3 with the line ending BEFORE the non-advancing exposure. Same
    # gap as M0007 opens for B.2, and the reason the hold covers every
    # suppressed exposure rather than B.2's alone: A.1's later dose and B.3's
    # first dose are each refused a line of their own, so if the line they
    # belong to has already ended they belong to nothing.
    melp('M0008', [14, 14 + 100], cover=60)    # A.1  in, next <180, cover ends d60
    melp('M0009', [70, 70 + 180], cover=29)    # B.3  out, next >=180, cover ends d29
    # B.2 after a CAR-T-started line with no consolidation drug. That line has
    # no medication to run out, so its natural end is its own start and the
    # whole 45-day window sits after it - the shape where a hold hung on a
    # non-null run-out was refused and both doses landed outside every line.
    # LEN to d90 so LOT1 ends and the CAR-T at d150 opens LOT2.
    pat('M0010', [('LEN', 'IMID', ix, ix + 90, 0),
                  (MELP[0], MELP[1], ix + 210, ix + 210, 0),
                  (MELP[0], MELP[1], ix + 300, ix + 300, 0)],
        ac=[('CART', ix + 150)])
    # LOT1 B.2 with SHORT follow-up after the held run-out. Observation ends 40
    # days past the second dose, so a discontinuation confirmed at that dose
    # has nothing like the 90 days the rule requires - the case that shows
    # whether the post-run-out guards read the held date or the original one.
    out.append(dict(pid='M0011', index=ix, death=None, obs_end=ix + 250,
                    maps=[('LEN', 'IMID', ix, ix + 150, 0),
                          (MELP[0], MELP[1], ix + 120, ix + 120, 0),
                          (MELP[0], MELP[1], ix + 210, ix + 210, 0)],
                    sct_ac=[], sct_auto=[],
                    spans=[(ix - 365, ix + 250)], strict=[(ix - 365, ix + 250)]))
    return out


def coalesce_same_drug(maps):
    """One drug cannot have two supply episodes running at once.

    03_mma_map opens a new MAP only for a claim landing beyond every runout
    (CASE 2); a claim arriving while cover is still active pushes the runout
    out instead (CASE 3, `rx_runout + ds`). So within a drug the episodes it
    emits are strictly disjoint, and the next MAP_START_DT is always past the
    previous MAP_END_DT.

    Drawing episodes independently breaks that - the same agent gets picked
    twice with windows that overlap - and produces a table no build can. It
    also makes `lag(...) ORDER BY MAP_START_DT` and "the latest episode ending
    before this date" name different rows as the previous episode, which is
    the very thing the added-medication rules turn on. Fold an overlap the way
    CASE 3 does rather than dropping it, so the draw is kept.
    """
    out, by_med = [], {}
    for m in maps:
        by_med.setdefault(m[0], []).append(m)
    for rows in by_med.values():
        cur = None
        for med, cls, s, e, flg in sorted(rows, key=lambda r: (r[2], r[3])):
            if cur is not None and s <= cur[3]:
                cur[3] += e - s + 1              # CASE 3: pushout by days supply
                continue
            cur = [med, cls, s, e, flg]          # CASE 1 / CASE 2: new episode
            out.append(cur)
    return [tuple(r) for r in sorted(out, key=lambda r: (r[2], r[0]))]


def discon_gap_days():
    """The gap 03_mma_map treats as a discontinuation. Same variable the engine
    reads, so a fixture and the build cannot disagree about it."""
    return int(os.environ.get("MAP_DISCON_GAP_DAYS", "90"))


def discon_flags(maps, obs_end, gap=None):
    """MAP_DISCON_FLG per drug: set when the gap to that drug's next start
    reaches the threshold. Mirrors what 03_mma_map computes.

    The threshold is a setting, not a constant - hardcoding it here made a
    fixture built at another value silently come back at 90.

    The last episode of a drug is discontinued only when observation still runs
    that many days past its end, which is the engine's second branch,
    `datediff(OBS_END_DT, MAP_END_DT) >= gap`. Flagging every terminal episode
    instead - what this did until now - marks a drug discontinued in a patient
    whose data simply stops, so a fixture claims a discontinuation the build
    would not.
    """
    if gap is None:
        gap = discon_gap_days()
    out, by_med = [], {}
    for m in maps: by_med.setdefault(m[0], []).append(m)
    for rows in by_med.values():
        rows.sort(key=lambda r: r[2])
        for j, (mm, cls, s, e, _) in enumerate(rows):
            nxt = rows[j + 1][2] if j + 1 < len(rows) else None
            reach = (nxt if nxt is not None else obs_end) - e
            out.append((mm, cls, s, e, 1 if reach >= gap else 0))
    return out


DDL = """
CREATE TABLE lot_patient_input (PATID VARCHAR, INDEX_DATE DATE, ENDDATE DATE,
  ENDDATE_CE DATE, OBS_END_DT DATE, DEATH_DT DATE, GDR_CD VARCHAR, YRDOB INT,
  AGE_INDEX_YR INT);
CREATE TABLE map_stacked (PATID VARCHAR, MAP_MED_TYPE VARCHAR, MAP_MED_CLASS VARCHAR,
  MAP_CNT INT, MAP_START_DT DATE, MAP_END_DT DATE, MAP_DISCON_FLG INT);
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
    for med, cls in ROLLUP:
        con.execute("INSERT INTO mma_rollup VALUES (?,?,NULL,NULL)", [med, cls])
    for p in pats:
        dd = d(p['death']) if p['death'] is not None else None
        con.execute("INSERT INTO lot_patient_input VALUES (?,?,?,?,?,?,?,?,?)",
                    [p['pid'], d(p['index']), d(p['obs_end']), d(p['obs_end']),
                     d(p['obs_end']), dd, 'M', 1955, 61])
        con.execute("INSERT INTO coh_1l VALUES (?,?)", [p['pid'], dd])
        cnt = {}
        for med, cls, s, e, flg in discon_flags(p['maps'], p['obs_end']):
            # MAP_CNT is 1-based per patient and drug, in claim order - what the
            # aggregate in 03_mma_map assigns as it opens each episode.
            cnt[med] = cnt.get(med, 0) + 1
            con.execute("INSERT INTO map_stacked VALUES (?,?,?,?,?,?,?)",
                        [p['pid'], med, cls, cnt[med], d(s), d(e), flg])
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


# SCT_AUTO_CONT is in the set: a transplant inside a line's own window holds
# that line open and ends it ON the transplant date. Left out, every patient
# who reaches that branch fails "an end reason outside the known set" - the
# harness reporting its own list as a defect in the build.
REASONS = ('SCT_ALLO','SCT_CART','SCT_AUTO','SCT_AUTO_CONT','SCT','CART_INIT',
           'MED_ADD','DEATH','DISCONTINUATION','STUDY_END')

# The same two settings emit_chain.R reads off the environment, read the same
# way here. A check that hardcodes what the emitted SQL was told is a check of
# a different build: at CONFIRM_DAYS=0 every immediate discontinuation is
# legitimate and a hardcoded 90 reports each one as a failure, and at
# CART_RULE=FALSE the in-induction exemption is not in the engine, so applying
# it here excuses an orphan the build would really produce.
def settings():
    return {
        "confirm": int(os.environ.get("CONFIRM_DAYS", "90")),
        "cart_rule": os.environ.get("CART_RULE", "TRUE").upper() == "TRUE",
        "max_lot": 5,
        "ind1": 60,
    }


def checks(c):
  # Every melphalan dose the rule refuses to let start a line has to end up
  # INSIDE a line. Suppressing a dose and owning it are two halves of one
  # statement, and only the first half is visible in line dates - so without
  # this the run went green while M0010's two doses sat in no line at all.
  #
  # Only when the rule is on. With it off the engine makes no such promise, and
  # a melphalan dose outside every line is an ordinary unowned exposure.
  #
  # The carve-out is the CAP, not "after the last line". A patient already at
  # max_lot has no line left to give, so a dose past their final line is the
  # cap showing. Below the cap a line was still available, and a dose past the
  # final line is exactly the failure this exists to catch.
  #
  # Written the other way round first - excusing every dose past the last line -
  # it could not see M0010, whose CAR-T line ends on its own start date so that
  # BOTH its doses are past it. The check went green on the one patient it was
  # added for. Same shape as E5's excuse, and for the same reason.
  max_lot = c["max_lot"]
  melp_owned = [] if not os.environ.get("MELP_RULE") else [
   ("a melphalan dose the rule suppressed sits in no line",
    f"""SELECT m.PATID, m.MAP_START_DT
       FROM map_stacked m
       WHERE upper(trim(m.MAP_MED_TYPE)) = 'MELP'
         AND EXISTS (SELECT 1 FROM lot_long c WHERE c.PATID = m.PATID)
         AND m.MAP_START_DT >= (SELECT min(c.LOT_START_DT) FROM lot_long c
                                 WHERE c.PATID = m.PATID)
         AND ((SELECT count(*) FROM lot_long c WHERE c.PATID = m.PATID) < {max_lot}
              OR m.MAP_START_DT <= (SELECT max(c.LOT_BASE_END_DT) FROM lot_long c
                                     WHERE c.PATID = m.PATID))
         AND NOT EXISTS (SELECT 1 FROM lot_long l
                          WHERE l.PATID = m.PATID
                            AND m.MAP_START_DT BETWEEN l.LOT_START_DT
                                                   AND l.LOT_BASE_END_DT)"""),
   ("a melphalan dose falls in two lines at once",
    """SELECT m.PATID, m.MAP_START_DT
       FROM map_stacked m
       WHERE upper(trim(m.MAP_MED_TYPE)) = 'MELP'
       GROUP BY m.PATID, m.MAP_START_DT
       HAVING (SELECT count(*) FROM lot_long l
                WHERE l.PATID = m.PATID
                  AND m.MAP_START_DT BETWEEN l.LOT_START_DT
                                         AND l.LOT_BASE_END_DT) > 1"""),
  ]
  return melp_owned + [
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
 # The window is the run's, not a constant. At CONFIRM_DAYS=0 a run-out is
 # confirmed the moment it happens, and every one of them would fail a
 # hardcoded 90.
 ("an unconfirmed discontinuation - B8's invariant",
  "SELECT l.PATID, l.LOT_NUM FROM lot_long l JOIN lot_patient_input p "
  "ON p.PATID = l.PATID WHERE l.LOT_BASE_END_REASON = 'DISCONTINUATION' "
  f"AND datediff('day', l.LOT_BASE_END_DT, p.OBS_END_DT) < {c['confirm']} "
  f"AND l.LOT_NUM < {c['max_lot']} "
  "AND NOT EXISTS (SELECT 1 FROM lot_long n WHERE n.PATID = l.PATID "
  "                AND n.LOT_NUM = l.LOT_NUM + 1)"),
 ("more lines than the cap",
  f"SELECT PATID FROM lot_long WHERE LOT_NUM > {c['max_lot']}"),
 ("two supply episodes of one drug overlapping - no build can emit this",
  "SELECT a.PATID, a.MAP_MED_TYPE FROM map_stacked a JOIN map_stacked b "
  "ON b.PATID = a.PATID AND b.MAP_MED_TYPE = a.MAP_MED_TYPE "
  "AND b.MAP_START_DT > a.MAP_START_DT AND b.MAP_START_DT <= a.MAP_END_DT"),
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
  "l.LOT_BASE_END_REASON IN ('SCT_ALLO','SCT_CART','SCT_AUTO','CART_INIT',"
  "'SCT_AUTO_CONT')"),
 ("lines held open to a transplant in their own window",
  "l.LOT_BASE_END_REASON = 'SCT_AUTO_CONT'"),
 ("lines started by something other than a drug", "l.LOT_START_TYPE <> 'MED'"),
 ("single-day lines",                  "l.LOT_BASE_LENGTH = 1"),
]


def run_qc(con, sqldir):
    """The shipped QC catalogue, run against the synthetic output.

    The harness used to carry Python rewrites of two QC predicates, which
    proved the rewrites. A rewrite can be right while the shipped check is
    wrong, and that is what happened: this run was green over a valid
    AUTO-started line with an empty regimen, while the real A7 would have
    failed it. So emit_qc.R asks checks.R for its own SQL and it is that SQL
    which runs here.

    A fail-severity check with a row is an invariant break, the same as
    anything in CHECKS. warn and info are counted and printed. A check that
    could not run is reported as itself - never as a pass.
    """
    qcfile = os.path.join(sqldir, "qc.tsv")
    r = subprocess.run(["Rscript", os.path.join(HERE, "emit_qc.R"), qcfile],
                       capture_output=True, text=True)
    if r.returncode == 3:
        print("  " + (r.stdout.strip() or "SKIP")); return [], []
    if r.returncode != 0:
        raise RuntimeError("emit_qc.R failed:\n" + r.stdout + r.stderr)
    print("  " + r.stdout.strip())

    bad, noted, skipped, broke = [], [], [], []
    with open(qcfile) as fh:
        head = fh.readline().rstrip("\n").split("\t")
        for line in fh:
            row = dict(zip(head, line.rstrip("\n").split("\t")))
            if not row["sql"]:
                skipped.append(f"{row['id']} (needs {row['missing']})"); continue
            sql = row["sql"].replace("\\n", "\n")
            try:
                n, detail = con.execute(to_duckdb(sql)).fetchone()
            except Exception as ex:
                broke.append(f"{row['id']}: {str(ex).splitlines()[0][:90]}"); continue
            if not n:
                continue
            line_out = f"{row['id']} ({row['severity']}): {n} - {row['what']}"
            if detail:
                line_out += f"  e.g. {detail}"
            (bad if row["severity"] == "fail" else noted).append(line_out)
    for s_i in noted:
        print("  reported ", s_i)
    # A check that could not run is not a check that found nothing. Both lists
    # are printed, and a translation failure counts against the run: silence
    # here would read as a clean catalogue.
    for s_i in skipped:
        print("  skipped  ", s_i)
    for s_i in broke:
        print("  ERROR    ", s_i)
    return bad, broke


def run_qc_scenarios():
    """The shipped checks against hand-built tables, for the ones the patients
    cannot reach. See qc_scenarios.py for why these have expected answers when
    nothing else here does."""
    import qc_scenarios
    sqldir = tempfile.mkdtemp(prefix="qc_scen_")
    qcfile = os.path.join(sqldir, "qc.tsv")
    env = dict(os.environ, SCENARIO="1")
    r = subprocess.run(["Rscript", os.path.join(HERE, "emit_qc.R"), qcfile],
                       capture_output=True, text=True, env=env)
    if r.returncode == 3:
        print("  " + (r.stdout.strip() or "SKIP")); return []
    if r.returncode != 0:
        raise RuntimeError("emit_qc.R failed:\n" + r.stdout + r.stderr)
    sql = {}
    with open(qcfile) as fh:
        head = fh.readline().rstrip("\n").split("\t")
        for line in fh:
            row = dict(zip(head, line.rstrip("\n").split("\t")))
            if row["sql"]:
                sql[row["id"]] = row["sql"].replace("\\n", "\n")

    bad, n = [], 0
    for sc in qc_scenarios.scenarios():
        if sc["check"] not in sql:
            bad.append(f"{sc['check']} is not in the emitted catalogue"); continue
        con = duckdb.connect(); con.execute("SET TimeZone='UTC'")
        for st in sc["sql"]:
            con.execute(st)
        got = con.execute(to_duckdb(sql[sc["check"]])).fetchone()[0]
        n += 1
        if got != sc["rows"]:
            bad.append(f"{sc['check']} on '{sc['name']}': {got} row(s), "
                       f"expected {sc['rows']}")
        con.close()
    print(f"  {n} scenarios over {len(set(s['check'] for s in qc_scenarios.scenarios()))} "
          f"checks the patient run cannot reach")
    return bad


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
    pats = generate(seed, npat)
    load(con, pats)
    probe = sqlglot.transpile("SELECT datediff(date '2024-01-11', date '2024-01-01')",
                              read='spark', write='duckdb')[0]
    assert con.execute(probe).fetchall()[0][0] == 10, "datediff does not mean a - b here"
    # len(pats), not npat: the planted patients are patients too, and printing
    # the argument instead reported a population smaller than the one that ran.
    print(f"calibration ok; {len(pats)} synthetic patients "
          f"({npat} drawn on seed {seed}, {len(pats) - npat} planted)\n")

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

    cfg = settings()
    if cfg["confirm"] != 90 or not cfg["cart_rule"]:
        print(f"settings: CONFIRM_DAYS={cfg['confirm']}, "
              f"CART_RULE={cfg['cart_rule']} - the checks follow them too")

    print("\ncoverage of the input space")
    vacuous = 0
    for name, pred in COVERAGE:
        v = q(f"SELECT sum(CASE WHEN {pred} THEN 1 ELSE 0 END) FROM lot_long l "
              f"JOIN lot_patient_input p ON p.PATID = l.PATID")[0][0] or 0
        if not v: vacuous += 1
        print(f"  {name:46} {v}{'   <-- nothing here, so nothing was tested' if not v else ''}")

    print("\nthe shipped QC catalogue, against these patients")
    qc_bad, qc_broke = run_qc(con, sqldir)

    print("\n...and against fixtures, for the checks no patient can reach")
    scen_bad = run_qc_scenarios()
    for s_i in scen_bad:
        print("  WRONG    ", s_i)

    bad = [(n, rows) for n, sql in checks(cfg) for rows in [q(sql)] if rows]
    bad += [(n, ["-"]) for n in qc_bad + qc_broke + scen_bad]
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
