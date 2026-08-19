#!/usr/bin/env python3
"""The simplified melphalan rule, proved on planted patients.

Runs the engine's own emitted SQL twice - the contract build and
MELP_RULE=simplified - over patients that pin each branch of the rule:

  SA  a short course on its own, outside induction  -> no new line; the
      course stays in the line it fell in
  SB  a short course of the line's OWN unreleased melphalan, with a new
      agent five days into it                       -> the next line starts
      on the melphalan date, where the contract build starts it on the
      agent's later date
  SC  the study team's worked case: melphalan day 100 for 28 days, a new
      agent day 105                                 -> the next line starts
      day 100
  SD  a course longer than the cap                  -> left to the engine;
      it advances on its own date under both builds
  SE  a short course after the line already ran out -> the line is carried
      to the dose and ends there; the contract build gives the dose a line
      of its own
  SF  a control with no melphalan and a released restart -> identical lines
      under both builds, or the mode is moving patients it cannot touch
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
]


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
    ref = build("")
    smp = build("simplified")

    fails = []
    def ok(cond, what):
        print(("  ok    " if cond else "  FAIL  ") + what)
        if not cond:
            fails.append(what)

    def starts(lines, pid):
        return [r[1] for r in lines.get(pid, [])]

    ok(len(ref['SA']) == 2 and starts(ref, 'SA')[1] == rs.d(IX + 100),
       "SA contract: the short course opens a line of its own on day 100")
    ok(len(smp['SA']) == 1,
       "SA simplified: it does not - the course stays in the only line")

    ok(len(ref['SB']) == 2 and starts(ref, 'SB')[1] == rs.d(IX + 85),
       "SB contract: the new agent starts the next line on ITS date, day 85")
    ok(len(smp['SB']) == 2 and starts(smp, 'SB')[1] == rs.d(IX + 80),
       "SB simplified: the next line starts on the melphalan date, day 80")

    ok(starts(smp, 'SC')[1:] == [rs.d(IX + 100)],
       "SC simplified: melphalan day 100, agent day 105 - the line starts day 100")
    ok(starts(ref, 'SC')[1:] == [rs.d(IX + 100)],
       "SC contract: the same here, since this melphalan was new to the line")

    ok(starts(ref, 'SD')[1:] == [rs.d(IX + 100)]
       and starts(smp, 'SD')[1:] == [rs.d(IX + 100)],
       "SD: a course past the cap is left to the engine under both builds")

    ok(len(ref['SE']) == 2 and starts(ref, 'SE')[1] == rs.d(IX + 300),
       "SE contract: the late dose gets a melphalan-only line")
    ok(len(smp['SE']) == 1 and smp['SE'][0][2] == rs.d(IX + 300)
       and smp['SE'][0][3] == 'DISCONTINUATION',
       "SE simplified: one line, carried to the dose and ending there")

    ok(ref.get('SF') == smp.get('SF') and ref.get('SF'),
       "SF: a patient with no melphalan is identical under both builds")

    print()
    if fails:
        print("%d check(s) failed" % len(fails)); sys.exit(1)
    print("the simplified rule lands every planted case where the request puts it")


if __name__ == "__main__":
    main()
