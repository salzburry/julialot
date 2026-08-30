#!/usr/bin/env python3
"""The MAP fold-in rule, proved on planted patients.

Runs the engine's own emitted SQL twice - the contract build and
MAP_FOLDIN=TRUE - over patients that pin each branch of the rule. The rule,
from the study team: a prior line's agent returning after the current line's
regimen window is PART of that line, not a reason to start the next one.

  F1  drug B (1L) returns during 2L          -> the split disappears; 2L runs
      to its own run-out
  F2  ...and returns after 2L already ran
      out                                    -> 2L is carried to B's cover
      and ends there
  F3  B returns the same day a genuinely
      new drug starts                        -> the boundary stays; the new
      drug starts the next line on that day under both builds
  F4  B's permissible substitute returns     -> folds like B itself
  F5  B restarts with NO newer line in
      between                                -> untouched: the engine's own
      restart rule still opens the next line
  F6  B returns two lines later, during 3L   -> does NOT fold. Two agents
      advanced the line between B's two doses, and the request's second
      clause gives that return a line of its own
  F7  a control with no prior-line return    -> identical under both builds
  F8  B returns in the gap between two
      episodes of 2L's own drug              -> it no longer breaks that
      drug's run-out chain; the line runs through
  F9  B returns after a single-day ALLO 2L   -> NO fold. A transplant that
      opened a line in between is a standalone boundary and overrides the
      fold, so the engine's own restart rule keeps the return
  F10 ...and after a CAR-T 2L with no
      consolidation drug                     -> the same
  F11 B returns with NO advance in between   -> count 0, not the request's
      case; the engine's restart rule keeps it
  F12 B returns with ONE advance in between  -> count 1, folds
  F13 B returns with TWO advances in between -> count 2, starts a line
  F14 B's return has a follow-up episode     -> one course, one answer: the
      whole course folds, not only its first episode
  F15 a PROCEDURE opens the line in between  -> it overrides the fold. One
      agent advanced the line, but a transplant or CAR-T keeps the engine's
      own rules and a line it opened is a boundary of its own
  F16 the only procedure in between is a
      PLANNED TANDEM                          -> it continues the line and
      opens nothing, so it is no advance: the return still folds
  F17 the only procedure in between is inside
      the line's own window                   -> it belongs to the line, so it
      is no advance either
  F18 ONE agent opens TWO lines in between   -> one agent, not two: DARA opens
      2L, discontinues, and opens 3L on a released restart. The return folds
"""
import os, sys, tempfile, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_synthetic as rs
import duckdb

IX = 300


def P(pid, maps, obs=1200):
    return dict(pid=pid, index=IX, death=None, obs_end=IX + obs,
                maps=[(m, c, IX + a, IX + b, 0) for (m, c, a, b) in maps],
                sct_ac=[], sct_auto=[],
                spans=[(IX - 365, IX + obs)], strict=[(IX - 365, IX + obs)])


L1 = [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80)]

PATS = [
    P('F1', L1 + [('DARA', 'MAB', 200, 400), ('BORT', 'PI', 300, 360)]),
    P('F2', L1 + [('DARA', 'MAB', 200, 250), ('BORT', 'PI', 400, 460)]),
    P('F3', L1 + [('DARA', 'MAB', 200, 400), ('BORT', 'PI', 300, 360),
                  ('CARF', 'PI', 300, 380)]),
    P('F4', L1 + [('DARA', 'MAB', 200, 400), ('BORTB', 'PI', 300, 360)]),
    P('F5', [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80),
             ('BORT', 'PI', 300, 360)]),
    P('F6', L1 + [('DARA', 'MAB', 200, 260), ('CARF', 'PI', 400, 500),
                  ('BORT', 'PI', 450, 510)]),
    P('F7', [('LEN', 'IMID', 0, 29), ('DARA', 'MAB', 0, 199),
             ('LEN', 'IMID', 150, 180)]),
    P('F8', L1 + [('DARA', 'MAB', 200, 250), ('DARA', 'MAB', 270, 330),
                  ('BORT', 'PI', 260, 290)]),
    dict(P('F9', L1 + [('BORT', 'PI', 300, 360)]),
         sct_ac=[('ALLO', IX + 200)]),
    dict(P('F10', L1 + [('BORT', 'PI', 300, 360)]),
         sct_ac=[('CART', IX + 200)]),
    # F11-F13: the COUNT itself, one patient per arm. Same shape throughout -
    # B is in 1L and returns on day 450 - and only the number of agents that
    # advanced the line in between changes.
    #
    # F11 count 0: nothing advanced the line, so the return is not the
    # request's case at all. The engine's own restart rule keeps it.
    P('F11', L1 + [('BORT', 'PI', 450, 510)]),
    # F12 count 1: DARA advanced the line once. B folds into the line it
    # returns in - the request's first clause, and its worked example.
    P('F12', L1 + [('DARA', 'MAB', 200, 600), ('BORT', 'PI', 450, 510)]),
    # F13 count 2: DARA then CARF. The second clause - the return starts a
    # line of its own, exactly as it does with the rule off.
    P('F13', L1 + [('DARA', 'MAB', 200, 260), ('CARF', 'PI', 300, 600),
                   ('BORT', 'PI', 450, 510)]),
    # F14: the returning COURSE, not just its first episode. B returns at d450
    # and folds; its own follow-up at d500 - inside the 90-day gap, so the same
    # course - had no advance behind it and was judged on its own, so it did
    # not fold and opened a line. One course, one answer.
    P('F14', L1 + [('DARA', 'MAB', 200, 600), ('BORT', 'PI', 450, 480),
                   ('BORT', 'PI', 500, 530)]),
    # F15: a PROCEDURE opens the line in between. Scanning medications alone,
    # LOT2 went on claiming B's return even though a CAR-T had opened LOT3,
    # and LOT2's own discontinuation became the CAR-T's end reason.
    dict(P('F15', L1 + [('DARA', 'MAB', 200, 250), ('BORT', 'PI', 450, 480)]),
         sct_ac=[('CART', IX + 300)]),
    # F16/F17: transplants that open NO line must not count as an advance.
    # DARA opens LOT2 on day 200 - one advance - and B returns on day 450.
    # F17 puts an AUTO on day 210, inside LOT2's own 30-day window, which the
    # line owns. F16 adds its planned tandem partner on day 350: 140 days
    # later with nothing in between, so the pair continues LOT2. Both must
    # fold exactly as F12 does. Bounding the scan at the line START rather
    # than its induction end, and reading the raw transplant dates rather
    # than the ones that break a line, refused both.
    dict(P('F16', L1 + [('DARA', 'MAB', 200, 600), ('BORT', 'PI', 450, 510)]),
         sct_auto=[IX + 210, IX + 350]),
    dict(P('F17', L1 + [('DARA', 'MAB', 200, 600), ('BORT', 'PI', 450, 510)]),
         sct_auto=[IX + 210]),
    # F18: the same agent opens two lines. DARA opens 2L on day 200, its cover
    # ends day 260, and a restart on day 400 - past the discontinuation gap -
    # opens 3L under the returning-drug release (LOT_RULES.md 4.3). Counting
    # LINES that is two advances and B is refused a fold; counting different
    # AGENTS, as the request words it, DARA is one agent and B folds.
    P('F18', L1 + [('DARA', 'MAB', 200, 260), ('DARA', 'MAB', 400, 600),
                   ('BORT', 'PI', 450, 510)]),
]


def build(foldin):
    # Both arms name the value. The default is read from the engine's shipped
    # config.csv now, and that carries TRUE, so leaving it unset would build
    # the fold-in on BOTH sides and compare the contract with itself.
    sqldir = tempfile.mkdtemp(prefix="foldin_")
    env = dict(os.environ)
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
    for pid, n, s, e, why in con.execute(
            "SELECT PATID, LOT_NUM, LOT_START_DT, LOT_BASE_END_DT, "
            "LOT_BASE_END_REASON FROM lot_long ORDER BY PATID, LOT_NUM").fetchall():
        lines.setdefault(pid, []).append((n, str(s)[:10], str(e)[:10], why))
    con.close()
    return lines


def main():
    ref = build(False)
    fold = build(True)

    fails = []
    def ok(cond, what):
        print(("  ok    " if cond else "  FAIL  ") + what)
        if not cond:
            fails.append(what)

    def n(lines, pid):
        return len(lines.get(pid, []))

    ok(n(ref, 'F1') == 3 and ref['F1'][2][1] == rs.d(IX + 300),
       "F1 contract: the returning drug splits 2L and starts a 3L on day 300")
    ok(n(fold, 'F1') == 2 and fold['F1'][1][2] == rs.d(IX + 400)
       and fold['F1'][1][3] == 'DISCONTINUATION',
       "F1 fold-in: no split - 2L runs to its own run-out on day 400")

    ok(n(ref, 'F2') == 3 and ref['F2'][2][1] == rs.d(IX + 400),
       "F2 contract: the post-run-out return gets a line of its own")
    ok(n(fold, 'F2') == 2 and fold['F2'][1][2] == rs.d(IX + 460)
       and fold['F2'][1][3] == 'DISCONTINUATION',
       "F2 fold-in: 2L is carried to the returning drug's cover, day 460")

    ok(n(ref, 'F3') == 3 and n(fold, 'F3') == 3
       and fold['F3'][2][1] == rs.d(IX + 300),
       "F3: a genuinely new same-day drug keeps the boundary under both builds")

    ok(n(ref, 'F4') == 3 and n(fold, 'F4') == 2,
       "F4: the permissible substitute folds exactly like the drug it replaces")

    ok(ref.get('F5') == fold.get('F5') and n(ref, 'F5') == 2
       and ref['F5'][1][1] == rs.d(IX + 300),
       "F5: a restart with no newer line in between still opens the next line")

    ok(n(ref, 'F6') == 4 and n(fold, 'F6') == 4,
       "F6: two advances in between, so the return starts a line under both")

    ok(ref.get('F7') == fold.get('F7') and ref.get('F7'),
       "F7: a patient with no prior-line return is identical under both builds")

    # The count, arm by arm.
    ok(ref.get('F11') == fold.get('F11') and ref.get('F11'),
       "F11 count 0: nothing advanced in between, so the rule leaves it alone")
    ok(n(ref, 'F12') > n(fold, 'F12'),
       "F12 count 1: one advance in between, so the return folds")
    ok(ref.get('F13') == fold.get('F13') and ref.get('F13'),
       "F13 count 2: two advances in between, so the return still starts a line")

    ok(n(ref, 'F14') == 3 and n(fold, 'F14') == 2,
       "F14: the whole returning course folds, not only its first episode")
    ok(n(fold, 'F14') == 2 and fold['F14'][1][2] == rs.d(IX + 600),
       "F14: ...and one line owns it, so no line opens on the follow-up")
    ok(n(ref, 'F15') == 4 and n(fold, 'F15') == 4,
       "F15: a CAR-T opened a line in between, and that overrides the fold")
    ok(n(fold, 'F15') == 4 and fold['F15'][1][2] == rs.d(IX + 250)
       and fold['F15'][1][3] == 'DISCONTINUATION',
       "F15: ...so LOT2 keeps its own discontinuation")

    ok(n(ref, 'F18') == 4 and n(fold, 'F18') == 3,
       "F18 contract: one agent opening two lines refuses the fold")
    ok(n(fold, 'F18') == 3 and fold['F18'][2][2] == rs.d(IX + 600)
       and fold['F18'][2][3] == 'DISCONTINUATION',
       "F18 fold-in: DARA is one agent, so the return folds into 3L")

    for pid, what in (('F17', "an AUTO inside the line's own window"),
                      ('F16', "...and its planned tandem partner")):
        ok(n(ref, pid) == 3, "%s contract: the return still takes a line" % pid)
        ok(n(fold, pid) == 2 and fold[pid][1][2] == rs.d(IX + 600)
           and fold[pid][1][3] == 'DISCONTINUATION',
           "%s fold-in: %s is no advance, so the return folds" % (pid, what))

    ok(n(ref, 'F8') == 3,
       "F8 contract: the return breaks 2L's own drug's chain and takes a line")
    ok(n(fold, 'F8') == 2 and fold['F8'][1][2] == rs.d(IX + 330)
       and fold['F8'][1][3] == 'DISCONTINUATION',
       "F8 fold-in: the chain holds and 2L runs through to day 330")

    ok(n(ref, 'F9') == 3 and ref['F9'][2][1] == rs.d(IX + 300),
       "F9 contract: the return after the ALLO line starts a line of its own")
    ok(fold.get('F9') == ref.get('F9'),
       "F9 fold-in: the ALLO opened the line in between, so it overrides the "
       "fold and the return keeps its own line")
    ok(n(ref, 'F10') == 3 and ref['F10'][2][1] == rs.d(IX + 300),
       "F10 contract: the same after a drugless CAR-T line")
    ok(fold.get('F10') == ref.get('F10'),
       "F10 fold-in: the same after a drugless CAR-T line")

    print()
    if fails:
        print("%d check(s) failed" % len(fails)); sys.exit(1)
    print("the fold-in lands every planted case where the request puts it")


if __name__ == "__main__":
    main()
