#!/usr/bin/env python3
"""The melphalan short-course rule, proved on planted patients.

This is the rule the study adopted, so MELP_RULE=simplified is the CONTRACT
build here. The other arm is MELP_RULE=off - what the engine did before the
adoption - kept because a rule is only pinned by what it changes.

Runs the engine's own emitted SQL twice, over patients that pin each branch:

  SA  a short course on its own, outside induction  -> no new line; the
      course stays in the line it fell in
  SB  a short course of the line's OWN unreleased melphalan, with a new
      agent five days into it                       -> the next line starts
      on the melphalan date, where a build with no rule starts it on the
      agent's later date
  SC  the study team's worked case: melphalan day 100 for 28 days, a new
      agent day 105                                 -> the next line starts
      day 100
  SD  a course longer than the cap                  -> left to the engine;
      it advances on its own date under both builds
  SE  a short course after the line already ran out -> the line is carried
      to the course's last covered day and ends there; with no rule the dose
      gets a line of its own
  SF  a control with no melphalan and a released restart -> identical lines
      under both builds, or the mode is moving patients it cannot touch
  SG  the base drug covers PAST OBSERVATION and a suppressed course sits in
      the line -> the line still ends STUDY_END. A missing run-out here
      means treatment active at censoring, and the hold must never turn
      that into a discontinuation on the melphalan date. Checked at LOT1
      (SG) and at LOT2 (SG2), and for the five-branch as_asked mode too -
      the hold machinery is shared, so the same patients guard both.
"""
import os, sys, tempfile, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_synthetic as rs
import duckdb

IX = 300


def P(pid, maps, obs=1200, ac=()):
    return dict(pid=pid, index=IX, death=None, obs_end=IX + obs,
                maps=[(m, c, IX + a, IX + b, 0) for (m, c, a, b) in maps],
                sct_ac=[(t, IX + d) for (t, d) in ac], sct_auto=[],
                spans=[(IX - 365, IX + obs)], strict=[(IX - 365, IX + obs)])


PATS = [
    P('SA', [('LEN', 'IMID', 0, 400), ('MELP', 'ALKY', 100, 127)]),
    P('SB', [('LEN', 'IMID', 0, 400), ('MELP', 'ALKY', 0, 27),
             ('MELP', 'ALKY', 80, 107), ('BORT', 'PI', 85, 200)]),
    P('SC', [('LEN', 'IMID', 0, 400), ('MELP', 'ALKY', 100, 127),
             ('DARA', 'MAB', 105, 300)]),
    P('SD', [('LEN', 'IMID', 0, 400), ('MELP', 'ALKY', 100, 156)]),
    P('SE', [('LEN', 'IMID', 0, 150), ('MELP', 'ALKY', 300, 327)]),
    P('SF', [('LEN', 'IMID', 0, 29), ('DARA', 'MAB', 0, 199),
             ('LEN', 'IMID', 150, 180)]),
    # A 90-day dose pair, so the five-branch modes read B.2 and the
    # simplified mode reads two short unconfirmed courses - both suppress.
    P('SG', [('LEN', 'IMID', 0, 1250), ('MELP', 'ALKY', 100, 100),
             ('MELP', 'ALKY', 190, 190)]),
    P('SG2', [('LEN', 'IMID', 0, 80), ('DARA', 'MAB', 300, 1250),
              ('MELP', 'ALKY', 420, 420), ('MELP', 'ALKY', 510, 510)]),
    # SH: a course must be owned by ONE line - the latest whose start precedes
    # it. Line 1 runs out at day 200 and discontinues; line 2 opens at day 300;
    # a lone course sits at day 900. Bounded only by the OBSERVATION end, both
    # lines claimed that course and the hold took the max, so line 1 ended day
    # 299 MED_ADD with its real discontinuation gone. Line 1 must keep it, and
    # line 2 - the line the course actually falls after - carries it.
    P('SH', [('LEN', 'IMID', 0, 200), ('DARA', 'MAB', 300, 600),
             ('MELP', 'ALKY', 900, 927)]),
    # SI: the same, but the later line is opened by a PROCEDURE rather than a
    # drug. Scanning medications alone missed it, and line 1's day-50
    # discontinuation became a day-99 SCT_CART end.
    P('SI', [('LEN', 'IMID', 0, 50), ('MELP', 'ALKY', 200, 227)],
      ac=(('CART', 100),)),
    # SJ: an AUTO on day 30 - inside LOT1's own 60-day window, so LOT1 owns it
    # - and its planned tandem partner on day 180, 150 days later with nothing
    # in between. The engine says the pair continues the line. SJ0 is the same
    # patient without the partner, and the two must land identically.
    # SK: a procedure between the course and the drug that would confirm it.
    # LEN covers 1L, a short course lands on day 100, an allograft on 102 ends
    # 1L, and DARA arrives on 105. DARA is no candidate against 1L once the
    # allograft has ended it, so it cannot make 1L's course advance - and a
    # line BACKDATED to day 100 whose whole regimen is that course is one the
    # rule says does not exist. Confirmation scanned only for the agent.
    dict(P('SK', [('LEN', 'IMID', 0, 400), ('MELP', 'ALKY', 100, 127),
                  ('DARA', 'MAB', 105, 300)]),
         sct_ac=[('ALLO', IX + 102)]),
    # SKn: the same with no allograft, where DARA does confirm the course and
    # the line opens on the melphalan date. The pair is what tells the
    # transplant test from the agent test.
    P('SKn', [('LEN', 'IMID', 0, 400), ('MELP', 'ALKY', 100, 127),
              ('DARA', 'MAB', 105, 300)]),
    P('SJ0', [('LEN', 'IMID', 0, 600), ('MELP', 'ALKY', 500, 527)]),
    P('SJ', [('LEN', 'IMID', 0, 600), ('MELP', 'ALKY', 500, 527)]),
]
for _p in PATS:
    if _p['pid'] == 'SJ0':
        _p['sct_auto'] = [IX + 30]
    elif _p['pid'] == 'SJ':
        _p['sct_auto'] = [IX + 30, IX + 180]


def build(mode):
    sqldir = tempfile.mkdtemp(prefix="melp_simple_")
    env = dict(os.environ)
    env.pop("MELP_RULE", None)
    if mode:
        env["MELP_RULE"] = mode
    r = subprocess.run(["Rscript", os.path.join(HERE, "emit_chain.R"), sqldir],
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        sys.exit(r.stdout + r.stderr)
    con = duckdb.connect(); con.execute("SET TimeZone='UTC'")
    rs.load(con, PATS)
    rs.run_chain(con, sqldir)
    lines = {}
    for pid, n, s, e, why in con.execute(
            "SELECT PATID, LOT_NUM, LOT_START_DT, LOT_BASE_END_DT, "
            "LOT_BASE_END_REASON FROM lot_long ORDER BY PATID, LOT_NUM").fetchall():
        # duckdb hands some derived dates back as datetimes; keep the day.
        lines.setdefault(pid, []).append((n, str(s)[:10], str(e)[:10], why))
    con.close()
    return lines


def main():
    ref = build("off")
    smp = build("simplified")
    ask = build("as_asked")

    fails = []
    def ok(cond, what):
        print(("  ok    " if cond else "  FAIL  ") + what)
        if not cond:
            fails.append(what)

    def starts(lines, pid):
        return [r[1] for r in lines.get(pid, [])]

    # SK/SKn: a transplant between the course and the drug that would confirm
    # it. With the allograft the course confirms nothing and 1L simply runs to
    # it; without it the course advances on its own date, as SKn shows. The
    # pair fails as one line vs three if confirmation stops reading
    # transplants.
    ok(len(smp['SK']) == 3 and starts(smp, 'SK')[0] == rs.d(IX)
       and starts(smp, 'SK')[1] == rs.d(IX + 102)
       and starts(smp, 'SK')[2] == rs.d(IX + 105),
       "SK simplified: an agent arriving after the allograft cannot confirm "
       "the course, so no line is backdated to the melphalan date")
    ok(len(smp['SKn']) == 2 and starts(smp, 'SKn')[1] == rs.d(IX + 100),
       "SKn simplified: ...and with no allograft in between it confirms it, "
       "opening the line on the melphalan date")

    ok(len(ref['SA']) == 2 and starts(ref, 'SA')[1] == rs.d(IX + 100),
       "SA no rule: the short course opens a line of its own on day 100")
    ok(len(smp['SA']) == 1,
       "SA simplified: it does not - the course stays in the only line")

    ok(len(ref['SB']) == 2 and starts(ref, 'SB')[1] == rs.d(IX + 85),
       "SB no rule: the new agent starts the next line on ITS date, day 85")
    ok(len(smp['SB']) == 2 and starts(smp, 'SB')[1] == rs.d(IX + 80),
       "SB simplified: the next line starts on the melphalan date, day 80")

    ok(starts(smp, 'SC')[1:] == [rs.d(IX + 100)],
       "SC simplified: melphalan day 100, agent day 105 - the line starts day 100")
    ok(starts(ref, 'SC')[1:] == [rs.d(IX + 100)],
       "SC no rule: the same here, since this melphalan was new to the line")

    ok(starts(ref, 'SD')[1:] == [rs.d(IX + 100)]
       and starts(smp, 'SD')[1:] == [rs.d(IX + 100)],
       "SD: a course past the cap is left to the engine under both builds")

    ok(len(ref['SE']) == 2 and starts(ref, 'SE')[1] == rs.d(IX + 300),
       "SE no rule: the late dose gets a melphalan-only line")
    ok(len(smp['SE']) == 1 and smp['SE'][0][2] == rs.d(IX + 327)
       and smp['SE'][0][3] == 'DISCONTINUATION',
       "SE simplified: one line, owning the course's full cover to day 327")

    ok(ref.get('SF') == smp.get('SF') and ref.get('SF'),
       "SF: a patient with no melphalan is identical under both builds")

    ok(len(smp['SG']) == 1 and smp['SG'][0][3] == 'STUDY_END',
       "SG simplified: base cover past observation keeps the line STUDY_END")
    ok(len(ask['SG']) == 1 and ask['SG'][0][3] == 'STUDY_END',
       "SG as_asked: ...and the five-branch hold does the same")
    ok(len(smp['SG2']) == 2 and smp['SG2'][1][3] == 'STUDY_END',
       "SG2 simplified: the same at a later line")
    ok(len(ask['SG2']) == 2 and ask['SG2'][1][3] == 'STUDY_END',
       "SG2 as_asked: ...under the five-branch hold too")

    print()
    # SH - one line owns the course, and the earlier line keeps its own end.
    # Bounded only by the observation end, EVERY line claimed EVERY later
    # course and the hold took the max, so line 1 lost its discontinuation to
    # a course 700 days after it.
    sh = smp.get('SH', [])
    ok(len(sh) == 2, "SH simplified: the lone course opens no line of its own")
    ok(len(sh) == 2 and sh[0][2] == rs.d(IX + 200)
       and sh[0][3] == 'DISCONTINUATION',
       "SH simplified: line 1 keeps its real day-200 discontinuation")
    ok(len(sh) == 2 and sh[1][2] == rs.d(IX + 927),
       "SH simplified: line 2 - the line the course falls after - carries it")
    ok(len(ref.get('SH', [])) == 3,
       "SH no rule: the course gets a melphalan-only line of its own")

    # SI - a procedure opens the later line, and must disqualify it just as a
    # drug does.
    si = smp.get('SI', [])
    ok(len(si) == 2 and si[0][2] == rs.d(IX + 50)
       and si[0][3] == 'DISCONTINUATION',
       "SI simplified: a CAR-T line in between leaves line 1's own end alone")
    ok(len(si) == 2 and si[1][2] == rs.d(IX + 227),
       "SI simplified: the CAR-T line carries the course instead")

    # SJ - a planned tandem is not a boundary, so it does not switch the rule
    # off. The tandem patient and the single-AUTO patient must agree.
    ok(len(smp.get('SJ0', [])) == 1 and smp['SJ0'][0][2] == rs.d(IX + 600)
       and smp['SJ0'][0][3] == 'DISCONTINUATION',
       "SJ0 simplified: the in-window AUTO leaves the rule alone - one line")
    ok(smp.get('SJ') == smp.get('SJ0'),
       "SJ simplified: its planned tandem partner does not switch the rule off")

    if fails:
        print("%d check(s) failed" % len(fails)); sys.exit(1)
    print("the simplified rule lands every planted case where the request puts it")


if __name__ == "__main__":
    main()
