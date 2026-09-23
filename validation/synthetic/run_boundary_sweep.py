#!/usr/bin/env python3
"""Every boundary day in the rules, and the invariants that must hold on it.

The MAP fold-in had a defect one day wide. The transplant override asks for a
line opened STRICTLY between a drug's two doses; the arrival scan asks for a
dose STRICTLY after this line's start. The transplant's own date is outside
both, so a dose landing on it was refused by neither, folded, and then stood
as the PREVIOUS dose for the next one in its course - which measured its
interval from a day the transplant no longer sat inside, and folded too. On an
allogeneic line that took the single day 4.6 gives it and swallowed the line
the course should have opened.

Four other places in the engine have the same shape - a pair of bounds that
between them skip one day, where a real event can land on it:

  melp_rule.R  confirm_med_boundary   > EXPO_DT and < the course's own date
  melp_rule.R  melp_taken             > the line's start (with <= EXPO_DT)
  melp_rule.R  melp_inject            > the line's start (with <= the span)
  prior_regimen.R  the interrupt scan > SCAN_FROM and < the episode

This sweep does not assume any of them is wrong. It plants each one's event on
the boundary day and one day either side, and asserts the things the RULES
promise - not a diff against a neighbour, which would fire on every legitimate
difference between "before the transplant" and "after" it. A boundary day is a
defect when it breaks a stated rule, not when it differs from its neighbours.

  I1  4.6   an ALLO-started line spans one day and names nothing, unless a
            melphalan course carried it (4.7, the one documented lift)
  I2  4.8   the fold decides nothing past a transplant that opened a line:
            with the fold on and with it off, the lines from that line on are
            the same. This is the assertion F42-F47 are built on.
  I3        every non-steroid episode starts inside some line, and every drug
            a line names has an episode inside it
  I4        lines are numbered 1..N with no gap, and none starts on or before
            the previous one's end

Run it around any change to a date bound in the engine. It is cheap: two
builds for the whole planted population.
"""
import os, sys, tempfile, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_synthetic as rs
import duckdb

IX = 300
TX = 350          # every transplant in this file lands here
MELP = ('MELP', 'ALKY')


def P(pid, maps, ac=(), auto=(), obs=1200):
    return dict(pid=pid, index=IX, death=None, obs_end=IX + obs,
                maps=[(m, c, IX + a, IX + b, 0) for (m, c, a, b) in maps],
                sct_ac=[(t, IX + d) for (t, d) in ac],
                sct_auto=[IX + d for d in auto],
                spans=[(IX - 365, IX + obs)], strict=[(IX - 365, IX + obs)])


# 1L on two drugs, then a third opens 2L: one advance, which is what 4.8's
# count needs before anything can fold.
L1 = [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80)]
OPEN2 = [('DARA', 'MAB', 200, 600)]

OFFSETS = (-1, 0, 1)          # the day before the boundary, the day, the day after
TXTYPE = (('ALLO', 'ac'), ('CART', 'ac'), ('AUTO', 'auto'))

PATS = []


def add(p):
    PATS.append(p)
    return p['pid']


def tx_of(kind, day):
    """The planting arguments for one transplant, by kind."""
    return dict(ac=[(kind, day)]) if kind != 'AUTO' else dict(auto=[day])


# --- S1: a fold-set dose against the transplant's own date -------------------
#
# The defect this file was written for, kept as the sweep's own worked case.
# BORT is 2L's regimen through the fold, returns at the transplant, and again
# after it. Both the reference product and its permissible substitute, because
# 4.4 makes the pair one agent and the pair is where the course grouping and
# the lag both have to agree.
for kind, _ in TXTYPE:
    for off in OFFSETS:
        for med, tag in (('BORT', 'ref'), ('BORTB', 'sub')):
            add(P('S1_%s_%s_%+d' % (kind, tag, off),
                  L1 + OPEN2 + [('BORT', 'PI', 300, 330),
                                (med, 'PI', TX + off, TX + off + 30),
                                (med, 'PI', TX + off + 60, TX + off + 90)],
                  **tx_of(kind, TX)))

# --- S2: melp_taken's "strictly after the line's start" ----------------------
#
# The rule asks whether ANOTHER agent was given between the line's start and
# the melphalan exposure - that is what decides the line took the course. A
# drug on the line's own start date is outside that scan. The line here opens
# on the transplant, so its start date is a day a drug can really land on.
for kind, _ in TXTYPE:
    for off in OFFSETS:
        add(P('S2_%s_%+d' % (kind, off),
              L1 + OPEN2 + [('CARF', 'PI', TX + off, TX + off + 20),
                            MELP + (TX + 40, TX + 67)],
              **tx_of(kind, TX)))

# --- S3: an injected melphalan course on the line's start date ---------------
#
# 4.7's injected course really did open a line, so it stays visible where a
# suppressed one does not. Its scan is bounded at the line's start the same way.
for kind, _ in TXTYPE:
    for off in OFFSETS:
        add(P('S3_%s_%+d' % (kind, off),
              L1 + OPEN2 + [MELP + (TX + off, TX + off + 27),
                            ('CARF', 'PI', TX + off + 5, TX + off + 120)],
              **tx_of(kind, TX)))

# --- S4: confirm_med_boundary, both of its bounds ---------------------------
#
# A short course outside induction does not advance a line on its own; another
# agent arriving in between confirms it. The scan is strict at BOTH ends, so
# two boundary days: the exposure date, and the course's own date.
for off in OFFSETS:
    add(P('S4_expo_%+d' % off,
          [('LEN', 'IMID', 0, 400), MELP + (100, 127),
           ('DARA', 'MAB', 100 + off, 100 + off + 60)]))
    add(P('S4_course_%+d' % off,
          [('LEN', 'IMID', 0, 400), MELP + (100, 127),
           ('DARA', 'MAB', 127 + off, 127 + off + 60)]))

# --- S5: the run-out chain's interrupt scan ---------------------------------
#
# A drug that is neither the line's own nor folded breaks a base drug's
# run-out chain. The scan is strict at both ends, so a drug landing exactly on
# a refill's date, or on the scan's own start, is in neither.
for off in OFFSETS:
    add(P('S5_%+d' % off,
          [('LEN', 'IMID', 0, 60), ('LEN', 'IMID', 120, 180),
           ('CARF', 'PI', 120 + off, 120 + off + 20)]))


def build(foldin, span="single_day"):
    sqldir = tempfile.mkdtemp(prefix="bsweep_")
    env = dict(os.environ)
    env["ALLO_LOT_SPAN"] = span
    env["MAP_FOLDIN"] = "TRUE" if foldin else "FALSE"
    r = subprocess.run(["Rscript", os.path.join(HERE, "emit_chain.R"), sqldir],
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        sys.exit(r.stdout + r.stderr)
    con = duckdb.connect(); con.execute("SET TimeZone='UTC'")
    rs.load(con, PATS)
    con.execute("INSERT INTO permissible_subs VALUES ('BORT','BORTB')")
    con.execute("INSERT INTO mma_rollup VALUES ('BORTB','PI',NULL,NULL)")
    rs.run_chain(con, sqldir)
    lines = {}
    for row in con.execute(
            "SELECT PATID, LOT_NUM, LOT_START_DT, LOT_BASE_END_DT, "
            "LOT_START_TYPE, LOT_BASE_END_REASON, coalesce(LOT_BASE_MEDS,''), "
            "LOT_MED_CNT FROM lot_long ORDER BY PATID, LOT_NUM").fetchall():
        pid, n, s, e, st, why, meds, cnt = row
        lines.setdefault(pid, []).append(
            (n, str(s)[:10], str(e)[:10], st, why, meds, cnt))
    # A melphalan episode covering each line, for 4.7's lift - the one
    # documented reason an ALLO line may outlive its day.
    melp = set(con.execute(
        "SELECT DISTINCT cast(l.PATID as string), l.LOT_NUM "
        "FROM lot_long l INNER JOIN map_stacked ms "
        "  ON cast(ms.PATID as string) = cast(l.PATID as string) "
        " AND upper(trim(ms.MAP_MED_TYPE)) = 'MELP' "
        " AND ms.MAP_START_DT <= l.LOT_BASE_END_DT "
        " AND ms.MAP_END_DT   >= l.LOT_START_DT").fetchall())
    orphan = con.execute("""
        SELECT cast(ms.PATID as string), ms.MAP_MED_TYPE, cast(ms.MAP_START_DT AS date)
        FROM map_stacked ms
        LEFT JOIN lot_long l
          ON l.PATID = ms.PATID AND ms.MAP_START_DT >= l.LOT_START_DT
         AND ms.MAP_START_DT <= l.LOT_BASE_END_DT
        WHERE ms.MAP_MED_CLASS <> 'STEROID' AND l.PATID IS NULL
        ORDER BY 1, 3""").fetchall()
    phantom = con.execute("""
        WITH reg AS (
          SELECT cast(l.PATID as string) AS PATID, l.LOT_NUM, l.LOT_START_DT,
                 l.LOT_BASE_END_DT, m AS MED_ABBR
          FROM lot_long l, UNNEST(str_split(coalesce(l.LOT_BASE_MEDS,''),' ')) AS t(m)
          WHERE m <> ''
        )
        SELECT r.PATID, r.LOT_NUM, r.MED_ABBR
        FROM reg r
        LEFT JOIN map_stacked ms
          ON cast(ms.PATID as string) = r.PATID AND ms.MAP_MED_TYPE = r.MED_ABBR
         AND ms.MAP_START_DT >= r.LOT_START_DT AND ms.MAP_START_DT <= r.LOT_BASE_END_DT
        WHERE ms.PATID IS NULL ORDER BY 1, 2""").fetchall()
    con.close()
    return lines, melp, orphan, phantom


def main():
    fold, melp, orphan, phantom = build(True)
    ref, _, _, _ = build(False)

    fails = []
    def ok(cond, what):
        print("  %-5s %s" % ("ok" if cond else "FAIL", what))
        if not cond:
            fails.append(what)

    print("\n-- I1: 4.6 gives an allogeneic line one day and no regimen --")
    bad_span, bad_reg = [], []
    for pid, rows in sorted(fold.items()):
        for r in rows:
            if r[3] != 'SCT_ALLO':
                continue
            if r[5] or r[6]:
                bad_reg.append("%s LOT%d names %r (%d drug(s))"
                               % (pid, r[0], r[5], r[6]))
            # 4.7's melphalan lift is the one documented exception to the day.
            if r[1] != r[2] and (pid, r[0]) not in melp:
                bad_span.append("%s LOT%d ran %s to %s" % (pid, r[0], r[1], r[2]))
    ok(not bad_reg, "no ALLO line carries a regimen (%s)" % (bad_reg[:2] or "none"))
    ok(not bad_span,
       "no ALLO line outlives its own day without melphalan covering it (%s)"
       % (bad_span[:2] or "none"))

    print("\n-- I2: the fold decides nothing past a transplant that opened a line --")
    # From the first line a transplant opened, both arms have to agree. The
    # fold may differ before it - that is the rule working - so the comparison
    # starts at that line and runs to the end, on the fold arm's index and the
    # reference arm's own.
    # A transplant does not always open a line, and that is 6.5 rather than
    # anything this invariant is about: an AUTO inside a line's own window
    # belongs to that line. Those have nothing to compare and are counted, not
    # skipped in silence - a sweep that quietly drops most of its cases is a
    # green that means nothing. A transplant opening a line in ONE arm only is
    # a finding, because that is the fold deciding something it may not.
    disagree, no_tx = [], 0
    for pid in sorted(fold):
        if not pid.startswith(('S1_', 'S2_', 'S3_')):
            continue
        f, rf = fold.get(pid, []), ref.get(pid, [])
        fi = next((i for i, r in enumerate(f) if r[3] != 'MED'), None)
        ri = next((i for i, r in enumerate(rf) if r[3] != 'MED'), None)
        if fi is None and ri is None:
            no_tx += 1
            continue
        if fi is None or ri is None:
            disagree.append("%s: a transplant opens a line in one arm only" % pid)
            continue
        if [r[1:] for r in f[fi:]] != [r[1:] for r in rf[ri:]]:
            disagree.append("%s: %s vs %s" % (pid, [r[1:] for r in f[fi:]][:2],
                                              [r[1:] for r in rf[ri:]][:2]))
    ok(not disagree,
       "every planted transplant reads the same with the fold and without it (%s)"
       % (disagree[:2] or "none"))
    ok(no_tx < sum(1 for p in fold if p.startswith(('S1_', 'S2_', 'S3_'))),
       "...and the comparison had something to compare (%d of %d histories have "
       "no transplant-opened line, which 6.5 allows)"
       % (no_tx, sum(1 for p in fold if p.startswith(('S1_', 'S2_', 'S3_')))))

    print("\n-- I3: every episode is in a line, every named drug has one --")
    ok(not orphan, "no episode starts outside every line (%s)" % (orphan[:2] or "none"))
    ok(not phantom, "no line names a drug it never covered (%s)" % (phantom[:2] or "none"))

    print("\n-- I4: the lines are contiguous and do not overlap --")
    bad = []
    for pid, rows in sorted(fold.items()):
        if [r[0] for r in rows] != list(range(1, len(rows) + 1)):
            bad.append("%s is numbered %s" % (pid, [r[0] for r in rows]))
        for a, b in zip(rows, rows[1:]):
            if b[1] <= a[2]:
                bad.append("%s LOT%d starts %s, LOT%d ended %s"
                           % (pid, b[0], b[1], a[0], a[2]))
    ok(not bad, "no line starts on or before the previous one's end (%s)"
       % (bad[:2] or "none"))

    # 4.6 says two things, and only the span is allo_lot_span's. The empty
    # regimen holds under BOTH, so the same histories run again under
    # extend_to_next - the mode nothing could emit until this sweep was
    # written, which is how the two came to be coupled in the engine.
    print("\n-- the other span: 4.6's empty regimen is not the setting's --")
    xf, xmelp, _, _ = build(True, "extend_to_next")
    xr, _, _, _ = build(False, "extend_to_next")
    bad = ["%s LOT%d names %r" % (pid, r[0], r[5])
           for pid, rows in sorted(xf.items()) for r in rows
           if r[3] == 'SCT_ALLO' and (r[5] or r[6])]
    ok(not bad, "no ALLO line carries a regimen under extend_to_next (%s)"
       % (bad[:2] or "none"))
    xd = []
    for pid in sorted(xf):
        if not pid.startswith(('S1_', 'S2_', 'S3_')):
            continue
        f, rf = xf.get(pid, []), xr.get(pid, [])
        fi = next((i for i, r in enumerate(f) if r[3] != 'MED'), None)
        ri = next((i for i, r in enumerate(rf) if r[3] != 'MED'), None)
        if fi is None and ri is None:
            continue
        if fi is None or ri is None or \
                [r[1:] for r in f[fi:]] != [r[1:] for r in rf[ri:]]:
            xd.append(pid)
    ok(not xd, "...and the fold still decides nothing past the transplant "
       "there either (%s)" % (xd[:3] or "none"))

    print("\n%d planted histories across 5 boundaries, 3 offsets each, "
          "both ALLO spans" % len(PATS))
    if fails:
        print("%d invariant(s) broken" % len(fails)); sys.exit(1)
    print("every boundary day keeps the invariants the rules state")


if __name__ == "__main__":
    main()
