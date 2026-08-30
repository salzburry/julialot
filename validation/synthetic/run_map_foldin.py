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
  F9  B returns after a single-day ALLO 2L   -> the ALLO line is carried to
      B's cover and ends there - a line with no regimen has no run-out of
      its own, so the hold has to supply one rather than extend one
  F10 ...and after a CAR-T 2L with no
      consolidation drug                     -> the same
  F11 B returns with NO advance in between   -> count 0, not the request's
      case; the engine's restart rule keeps it
  F12 B returns with ONE advance in between  -> count 1, folds
  F13 B returns with TWO advances in between -> count 2, starts a line
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

    ok(n(ref, 'F8') == 3,
       "F8 contract: the return breaks 2L's own drug's chain and takes a line")
    ok(n(fold, 'F8') == 2 and fold['F8'][1][2] == rs.d(IX + 330)
       and fold['F8'][1][3] == 'DISCONTINUATION',
       "F8 fold-in: the chain holds and 2L runs through to day 330")

    ok(n(ref, 'F9') == 3 and ref['F9'][2][1] == rs.d(IX + 300),
       "F9 contract: the return after the ALLO line starts a line of its own")
    ok(n(fold, 'F9') == 2 and fold['F9'][1][2] == rs.d(IX + 360)
       and fold['F9'][1][3] == 'DISCONTINUATION',
       "F9 fold-in: the ALLO line is carried to the return's cover, day 360")
    ok(n(ref, 'F10') == 3 and ref['F10'][2][1] == rs.d(IX + 300),
       "F10 contract: the same after a drugless CAR-T line")
    ok(n(fold, 'F10') == 2 and fold['F10'][1][2] == rs.d(IX + 360)
       and fold['F10'][1][3] == 'DISCONTINUATION',
       "F10 fold-in: the drugless CAR-T line is carried to day 360 too")

    print()
    if fails:
        print("%d check(s) failed" % len(fails)); sys.exit(1)
    print("the fold-in lands every planted case where the request puts it")


if __name__ == "__main__":
    main()
