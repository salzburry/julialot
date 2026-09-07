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
      (SG) and at LOT2 (SG2).
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
    # SL/SLn: a suppressed course must not break a base drug's run-out chain.
    # LEN covers 0-80, a short unconfirmed course covers 100-127, and LEN
    # itself returns on day 200. The course advances nothing, so the line has
    # to run over it exactly as it does when the course is absent. Breaking
    # the chain there truncated LEN's cover, its day-200 episode was never
    # reached, and 4.3 refuses that episode a line of its own - so sixty-one
    # days of treatment belonged to no line at all.
    P('SL',  [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 100, 127),
              ('LEN', 'IMID', 200, 260)]),
    P('SLn', [('LEN', 'IMID', 0, 80), ('LEN', 'IMID', 200, 260)]),
    # SM: a course LONGER than the cap. 4.7 leaves such a course to the engine
    # untouched, so it breaks the base drug's run-out chain like any other drug
    # and the line ends at its own discontinuation. Keeping every melphalan row
    # out of that scan - which is how the short-course case was first fixed -
    # made an over-cap course stop ending the line at day 80, moving it to a
    # day-99 MED_ADD instead.
    P('SM',  [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 100, 128),
              ('LEN', 'IMID', 200, 260)]),
    # SN/SNs/SNn: what confirms a short course, with a CAR-T-opened line and
    # the same course at day 400 in all three. Only the drug arriving at 405
    # during its cover changes, and the three answers are the rule:
    #   a steroid              - confirms nothing, the course is held (2.1)
    #   a previous-line drug   - opens a line on ITS OWN date, not the course's
    #   a drug never given     - confirms, so the line opens on the course
    dict(P('SNs', [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80),
                   ('MELP', 'ALKY', 400, 427), ('DEX', 'STEROID', 405, 600)]),
         sct_ac=[('CART', IX + 200)]),
    dict(P('SN',  [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80),
                   ('MELP', 'ALKY', 400, 427), ('BORT', 'PI', 405, 600)]),
         sct_ac=[('CART', IX + 200)]),
    dict(P('SNn', [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80),
                   ('MELP', 'ALKY', 400, 427), ('POMA', 'IMID', 405, 600)]),
         sct_ac=[('CART', IX + 200)]),
    P('SJ0', [('LEN', 'IMID', 0, 600), ('MELP', 'ALKY', 500, 527)]),
    # SJ1: SJ0's transplant moved OUTSIDE LOT1's 60-day window, on a line still
    # running. 3.4 says the first transplant never ends LOT1 wherever it falls,
    # so this must read exactly like SJ0. It did not: the boundary helper took
    # any AUTO past the window as a break at LOT1 too, so the course was marked
    # TAKEN, LOT1 never judged it, it was never suppressed, and it opened a line
    # of its own on the melphalan date - which 4.7 forbids outright. SJ0 could
    # not catch it because its transplant is in-window, which was always right.
    P('SJ1', [('LEN', 'IMID', 0, 600), ('MELP', 'ALKY', 500, 527)]),
    P('SJ', [('LEN', 'IMID', 0, 600), ('MELP', 'ALKY', 500, 527)]),
    # SP*: one course, with a transplant in three positions around it. The two
    # doses are closer together than melp_exposure_days, so they are ONE
    # course, and the ask is that a course of 28 days or fewer outside ANY
    # induction window does not advance the line - in all three.
    #
    # SPin is the one that was wrong. The course starts before the transplant
    # line begins, so that line dropped it from judging altogether, and its
    # later dose reached the engine as an ordinary added medication and opened
    # a line of its own. SPbefore and SPafter always worked; they are here so
    # the three read as one rule rather than a fix bolted onto one shape.
    P('SPbefore', [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 90, 90),
                   ('MELP', 'ALKY', 110, 110)], ac=[('ALLO', 85)]),
    P('SPin',     [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 90, 90),
                   ('MELP', 'ALKY', 110, 110)], ac=[('ALLO', 100)]),
    P('SPafter',  [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 90, 90),
                   ('MELP', 'ALKY', 110, 110)], ac=[('ALLO', 120)]),
    P('SPnone',   [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 90, 90),
                   ('MELP', 'ALKY', 110, 110)]),
    # SQ: a CONFIRMED course given as more than one dose, with transplants
    # ending the line it opened. DARA d95 confirms the d90 course, so the
    # course advances the line on d90 - and its d110 dose belongs to whatever
    # line is running by then, never to one of its own.
    #
    # Injection stored only the course's first date while suppression expanded
    # to every dose, so d110 stayed an ordinary candidate and opened a line -
    # which 4.7 forbids. Holding for it then has to reach only the LATER
    # doses: a single-dose course has nothing after its boundary to own, and
    # holding there swallowed an agent that should have opened its own line
    # (SK).
    P('SQ', [('LEN', 'IMID', 0, 80), ('DARA', 'MAB', 95, 300),
             ('MELP', 'ALKY', 90, 90), ('MELP', 'ALKY', 110, 110)],
       ac=[('ALLO', 100), ('ALLO', 105)]),
    # SR: a held course spanning a procedure. 4.7 says a held course joins
    # neither the regimen nor the count, but the induction window collects
    # every non-steroid episode in it before the verdict is known, so the
    # post-procedure dose entered the new line's regimen and its drug count.
    P('SR', [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 195, 195),
             ('MELP', 'ALKY', 205, 222)], ac=[('CART', 200)]),
    # ZB*: a previous-line drug returning at a PROCEDURE-opened line is
    # line-defining - the CAR-T it crossed overrides the fold (4.8) - so it is
    # a boundary like any other, and the melphalan rule has to see it as one.
    # It did not: the rule reads "not new" straight off the previous line's
    # regimen, which is right for what may CONFIRM a course and wrong for what
    # may take one, and both halves went through the same set.
    #
    # ZB1 is confirmation. SN's returning BORT arrives on 405 and a drug the
    # patient never had on 410, both while the day-400 course still covers.
    # BORT opens the line on its own date (SN), so POMA arrives after that
    # boundary and belongs to the line BORT opened - it cannot make the earlier
    # line's course advance. Scanning only for transplants, it did: the line
    # was backdated to day 400 with BORT swept into a line starting before it.
    # ZB2 is the same two drugs with no melphalan at all, and the two must give
    # the same line starts.
    dict(P('ZB1', [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80),
                   ('MELP', 'ALKY', 400, 427), ('BORT', 'PI', 405, 600),
                   ('POMA', 'IMID', 410, 600)]),
         sct_ac=[('CART', IX + 200)]),
    dict(P('ZB2', [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80),
                   ('BORT', 'PI', 405, 600), ('POMA', 'IMID', 410, 600)]),
         sct_ac=[('CART', IX + 200)]),
    # ZB3 is ownership. BORT returns on day 300 and opens a line there; a lone
    # short course sits at day 400 with nothing to confirm it. The course
    # belongs to the line the return opened, not to the CAR-T line before it.
    # Invisible to that scan, the CAR-T line claimed it too and was carried
    # from a single day to the day before the return - its SCT_CART end
    # becoming a MED_ADD. ZB3x is the same patient with the course removed,
    # which is the shape the CAR-T line must keep.
    dict(P('ZB3', [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80),
                   ('BORT', 'PI', 300, 500), ('MELP', 'ALKY', 400, 427)]),
         sct_ac=[('CART', IX + 200)]),
    dict(P('ZB3x', [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80),
                    ('BORT', 'PI', 300, 500)]),
         sct_ac=[('CART', IX + 200)]),
    # SU1/SU2: a suppressed course must not reach a line that starts after its
    # cover has run out. LEN to day 80, a short course days 200-227 that 4.7
    # correctly suppresses and that carries line 1 to day 227, and then a
    # transplant on day 700 with no drug after it.
    #
    # melp_judged had no lower bound, so line 2 took the day-200 course as well;
    # melp_hold followed, and melp_runout_case handed a regimen-less transplant
    # line a run-out 473 days BEFORE its own start. SCT_AUTO_CONT read that as a
    # line ending too early and clamped line 2 to a single day - 500 days of
    # follow-up lost, and the state shipped QC check B7 calls a failure.
    #
    # SU2 is the same patient with no melphalan at all. The two lines 2 must be
    # identical: the course belongs to line 1 and line 1 alone.
    # SW1/SW2: the next-line statement must read 3.4's first-transplant
    # exemption the way line 1's own build does. SW1's only AUTO is on day 100,
    # outside line 1's window; SW2 moves it inside. A confirmed course at day
    # 300 opens line 2 on the melphalan date in both, or the two statements
    # disagree about one course and line 1 ends on a boundary line 2 refuses.
    P('SW1', [('LEN', 'IMID', 0, 600), ('MELP', 'ALKY', 30, 57),
              ('MELP', 'ALKY', 300, 327), ('DARA', 'MAB', 305, 600)]),
    P('SW2', [('LEN', 'IMID', 0, 600), ('MELP', 'ALKY', 30, 57),
              ('MELP', 'ALKY', 300, 327), ('DARA', 'MAB', 305, 600)]),
    P('SU1', [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 200, 227)]),
    P('SU2', [('LEN', 'IMID', 0, 80)]),
]
for _p in PATS:
    if _p['pid'] in ('SU1', 'SU2'):
        _p['sct_auto'] = [IX + 700]
    elif _p['pid'] == 'SW1':
        _p['sct_auto'] = [IX + 100]
    elif _p['pid'] == 'SW2':
        _p['sct_auto'] = [IX + 40]
for _p in PATS:
    if _p['pid'] == 'SJ0':
        _p['sct_auto'] = [IX + 30]
    elif _p['pid'] == 'SJ1':
        _p['sct_auto'] = [IX + 200]
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
    # The regimen and drug count come back too: 4.7 says a held course joins
    # neither, and a line's dates cannot show whether it did.
    for pid, n, s, e, why, meds, cnt in con.execute(
            "SELECT PATID, LOT_NUM, LOT_START_DT, LOT_BASE_END_DT, "
            "LOT_BASE_END_REASON, coalesce(LOT_BASE_MEDS, ''), LOT_MED_CNT "
            "FROM lot_long ORDER BY PATID, LOT_NUM").fetchall():
        # duckdb hands some derived dates back as datetimes; keep the day.
        lines.setdefault(pid, []).append((n, str(s)[:10], str(e)[:10], why,
                                          meds, cnt))
    con.close()
    return lines


def main():
    ref = build("off")
    smp = build("simplified")

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

    ok(len(smp['SNs']) == 2,
       "SNs simplified: a steroid confirms nothing - melphalan with one is "
       "still melphalan on its own, and the course is held")
    ok(len(smp['SN']) == 3 and starts(smp, 'SN')[2] == rs.d(IX + 405),
       "SN simplified: a previous-line drug the procedure made line-defining "
       "opens the next line on ITS OWN date, not the melphalan date")
    ok(len(smp['SNn']) == 3 and starts(smp, 'SNn')[2] == rs.d(IX + 400),
       "SNn simplified: ...where a drug never given before confirms the "
       "course, so that line opens on the melphalan date instead")

    ok(starts(smp, 'ZB1') == starts(smp, 'ZB2')
       and len(smp['ZB1']) == 3 and starts(smp, 'ZB1')[2] == rs.d(IX + 405)
       and smp['ZB1'][2][4] == 'BORT POMA',
       "ZB1/ZB2: a new agent arriving after a returning drug opened a line "
       "cannot backdate that line to the melphalan date")
    ok(len(smp['SW1']) == 2 and smp['SW1'][1][1] == rs.d(IX + 300)
       and 'MELP' in smp['SW1'][1][4]
       and [r[1:] for r in smp['SW1']] == [r[1:] for r in smp['SW2']],
       "SW1/SW2: line 1's first transplant is exempt in the next-line statement "
       "too, so a confirmed course opens line 2 on the melphalan date")

    ok(len(smp['SU1']) == 2 and smp['SU1'][1] == smp['SU2'][1]
       and smp['SU1'][1][3] == 'STUDY_END'
       and smp['SU1'][0][2] == rs.d(IX + 227),
       "SU1/SU2: line 1 owns the course and is carried to it; the transplant "
       "line after it is untouched, not clamped to a single day")

    ok(smp['ZB3'] == smp['ZB3x'],
       "ZB3/ZB3x: the CAR-T line does not claim a course that falls after the "
       "returning drug opened a line of its own")

    ok(len(smp['SM']) == 2 and starts(smp, 'SM')[1] == rs.d(IX + 100)
       and smp['SM'][0][3] == 'DISCONTINUATION',
       "SM simplified: a course past the cap is left to the engine, so the "
       "line ends at its own run-out and the course opens the next")

    ok(smp['SL'] == smp['SLn'] and len(smp['SL']) == 1,
       "SL/SLn: a suppressed course leaves the run-out chain alone, so the "
       "line runs over it exactly as it does with no melphalan at all")

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
       "SG: base cover past observation keeps the line STUDY_END")
    ok(len(smp['SG2']) == 2 and smp['SG2'][1][3] == 'STUDY_END',
       "SG2: the same at a later line")

    # SP*: a short course never advances the line, wherever a transplant sits.
    # Checked as OWNERSHIP, not line count: what went wrong was a melphalan
    # dose starting a line, and what went wrong when that was fixed was the
    # same dose belonging to nothing.
    for pid in ('SPnone', 'SPbefore', 'SPin', 'SPafter'):
        starts = [str(l[1])[:10] for l in smp[pid]]
        ok(rs.d(IX + 110) not in starts and rs.d(IX + 90) not in starts,
           f"{pid}: no line starts on a melphalan dose - a short course "
           f"outside any induction window does not advance the line")
        # ...and the other half of the same statement. Refusing a course a
        # boundary without giving it to a line leaves the treatment nowhere,
        # which is what removing the line-opening alone did to SPin.
        owned = [d for d in (90, 110)
                 if not any(l[1] <= rs.d(IX + d) <= l[2] for l in smp[pid])]
        ok(not owned,
           f"{pid}: ...and every dose of it sits inside a line"
           + (f" - d{owned} in none" if owned else ""))
    # SQ: no line starts on a dose, and every dose is owned.
    sq_starts = [str(l[1])[:10] for l in smp['SQ']]
    ok(rs.d(IX + 110) not in sq_starts,
       "SQ: a later dose of a CONFIRMED course does not open a line of its own")
    ok(all(any(l[1] <= rs.d(IX + d) <= l[2] for l in smp['SQ']) for d in (90, 110)),
       "SQ: ...and both doses of it sit inside a line")
    ok(rs.d(IX + 90) in sq_starts,
       "SQ: ...while the course's FIRST day is still the boundary it earns")

    # SR: a held course joins neither the regimen nor the count.
    sr = [l for l in smp['SR'] if str(l[1])[:10] == rs.d(IX + 200)]
    ok(len(sr) == 1 and not sr[0][4] and sr[0][5] == 0,
       "SR: a held course joins neither the line's regimen nor its drug count")

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
    ok(smp.get('SJ1') == smp.get('SJ0'),
       "SJ1 simplified: a FIRST transplant outside the window does not switch "
       "it off either - 3.4 gives LOT1 that transplant wherever it falls")

    if fails:
        print("%d check(s) failed" % len(fails)); sys.exit(1)
    print("the simplified rule lands every planted case where the request puts it")


if __name__ == "__main__":
    main()
