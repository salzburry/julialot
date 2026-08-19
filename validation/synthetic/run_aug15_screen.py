#!/usr/bin/env python3
"""The mid-August MAP-splitting screen, held to the engine it sizes.

Plants patients, builds their lines with the engine's own SQL, then runs the
EXACT screen and funnel SQL out of analysis/questions/aug15_studyteam_qs.R
against those lines. The cases are the ones a wrong screen gets wrong:

  MS1   the pure returning drug            -> AFFECTED on both bases
  MS2   a first-exposure MED_ADD           -> absent from the screen
  MS3b  original returns, 1L held the
        biosimilar                         -> AFFECTED on SUBSTITUTE_FAMILY,
                                              absent on EXACT_TOKEN
  MS7   returning drug and a new drug on
        one day                            -> SAME_DAY_NEW_AGENT, whichever
                                              medication the engine stored
  MS8   returning drug and a RELEASED
        restart of the line's own drug on
        one day                            -> SAME_DAY_NEW_AGENT - the
                                              restart is an engine-valid
                                              candidate, not ignorable
  F1/F2 the discontinued-then-12mo-CE
        funnel, with F2's coverage broken
        inside the baseline window         -> F2 drops at the CE step

Classification must not depend on which same-day candidate the engine's
rand(42) tie-break stored, so every assertion here is deterministic.
"""
import os, sys, re, tempfile, subprocess, datetime
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_synthetic as rs
import duckdb

QS = os.path.join(HERE, "..", "..", "Jul 28", "analysis", "questions",
                  "aug15_studyteam_qs.R")
IX = 300

def P(pid, maps, spans=None, obs=1200):
    return dict(pid=pid, index=IX, death=None, obs_end=IX+obs,
                maps=[(m, c, IX+a, IX+b, 0) for (m, c, a, b) in maps],
                sct_ac=[], sct_auto=[],
                spans=[(IX+a, IX+b) for (a, b) in (spans or [(-365, obs)])],
                strict=[(IX-365, IX+obs)])

PATS = [
    P('MS1', [('DARA','MAB',0,80),('LEN','IMID',0,80),
              ('POMA','IMID',200,400),('DARA','MAB',260,400)]),
    P('MS2', [('LEN','IMID',0,80),('POMA','IMID',200,400),
              ('BORT','PI',260,400)]),
    P('MS3b',[('DARAB','MAB',0,80),('POMA','IMID',200,400),
              ('DARA','MAB',260,400)]),
    P('MS7', [('DARA','MAB',0,80),('LEN','IMID',0,80),('POMA','IMID',200,400),
              ('DARA','MAB',260,400),('BORT','PI',260,400)]),
    P('MS8', [('LEN','IMID',0,80),
              ('POMA','IMID',200,500),('CARF','PI',200,240),
              ('LEN','IMID',400,500),('CARF','PI',400,500)]),
    P('F1',  [('LEN','IMID',0,80),('POMA','IMID',200,400)]),
    P('F2',  [('LEN','IMID',0,80),('POMA','IMID',200,400)],
              spans=[(-365,150),(180,1200)]),
]

def main():
    sqldir = tempfile.mkdtemp(prefix="aug15t_")
    r = subprocess.run(["Rscript", os.path.join(HERE, "emit_chain.R"), sqldir],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(r.stdout + r.stderr)
    con = duckdb.connect(); con.execute("SET TimeZone='UTC'")
    rs.load(con, PATS)
    con.execute("INSERT INTO permissible_subs VALUES ('DARA','DARAB')")
    con.execute("INSERT INTO mma_rollup VALUES ('DARAB','MAB',NULL,NULL)")
    rs.run_chain(con, sqldir)

    src = open(QS).read()
    ctes = re.search(r'screen_ctes <- glue\("\n(.*?)\n    "\)\n', src, re.S).group(1)
    counts_sel = re.search(
        r'affected <- db_q\(con, paste0\(screen_ctes, "\n(.*?)"\)\)', src, re.S).group(1)
    roster_sel = re.search(
        r'roster <- db_q\(con, paste0\(screen_ctes, glue\("\n(.*?)"\)\)\)', src, re.S).group(1)
    funnel_sel = re.search(r'd <- db_q\(con, glue\("\n(.*?)"\)\)', src, re.S).group(1)

    def fill(q, n=2):
        return (q.replace("{lines}", "lot_long")
                 .replace("{subs_src}", "permissible_subs")
                 .replace("{maps}", "map_stacked")
                 .replace("{spans}", "spans")
                 .replace("{cart}", "45").replace("{indn}", "30")
                 .replace("{n - 1}", str(n-1)).replace("{n}", str(n)))

    fails = []
    def ok(cond, what):
        print(("  ok    " if cond else "  FAIL  ") + what)
        if not cond: fails.append(what)

    verdicts = {}
    q = rs.to_duckdb(fill(ctes) + "\nSELECT MATCH_BASIS, PATID, LOT_NUM, CLASS FROM verdict")
    for basis, pid, lot, cls in con.execute(q).fetchall():
        verdicts[(basis, pid, lot)] = cls

    ok(verdicts.get(("EXACT_TOKEN", "MS1", 2)) == "AFFECTED",
       "MS1: the pure returning drug is AFFECTED on the exact-token basis")
    ok(verdicts.get(("SUBSTITUTE_FAMILY", "MS1", 2)) == "AFFECTED",
       "MS1: ...and on the family basis")
    ok(not any(k[1] == "MS2" for k in verdicts),
       "MS2: a first-exposure MED_ADD is not in the screen at all")
    ok(("EXACT_TOKEN", "MS3b", 2) not in verdicts,
       "MS3b: the original returning for the biosimilar is absent on exact token")
    ok(verdicts.get(("SUBSTITUTE_FAMILY", "MS3b", 2)) == "AFFECTED",
       "MS3b: ...and AFFECTED on the family basis")
    ok(verdicts.get(("EXACT_TOKEN", "MS7", 2)) == "SAME_DAY_NEW_AGENT"
       and verdicts.get(("SUBSTITUTE_FAMILY", "MS7", 2)) == "SAME_DAY_NEW_AGENT",
       "MS7: a same-day new agent keeps the boundary, whatever pick was stored")
    ok(verdicts.get(("EXACT_TOKEN", "MS8", 2)) == "SAME_DAY_NEW_AGENT"
       and verdicts.get(("SUBSTITUTE_FAMILY", "MS8", 2)) == "SAME_DAY_NEW_AGENT",
       "MS8: a released restart of the line's own drug keeps the boundary")

    q = rs.to_duckdb(fill(ctes) + "\n" + fill(roster_sel))
    cols = None
    rows = con.execute(q).fetchall()
    cols = [d[0] for d in con.execute(q).description]
    def cell(pid, basis, col):
        for r_ in rows:
            m = dict(zip(cols, r_))
            if m["PATID"] == pid and m["MATCH_BASIS"] == basis:
                return m[col]
        return None
    ok(cell("MS8", "EXACT_TOKEN", "OTHER_MEDS_STARTING_SAME_DAY") == "CARF",
       "MS8 roster: the released restart is visible in the same-day column")
    ok(cell("MS1", "EXACT_TOKEN", "RETURNING_PREV_MEDS") == "DARA"
       and cell("MS1", "EXACT_TOKEN", "OTHER_MEDS_STARTING_SAME_DAY") == "",
       "MS1 roster: the returning drug is named and nothing else started")
    ok(cell("MS1", "EXACT_TOKEN", "GAP_FROM_PRIOR_EPISODE_END_DAYS") == 180,
       "MS1 roster: the gap is measured from the drug's last cover")

    # All seven patients discontinue 1L and reach 2L; F2 alone has the break
    # inside [2L start - 365, 2L start - 1], so only the CE step moves.
    got = con.execute(rs.to_duckdb(fill(funnel_sel, 2))).fetchone()
    ok(got == (7, 7, 6),
       "funnel 2L: 7 discontinued 1L, 7 with a 2L, 6 with unbroken 12mo CE (%r)" % (got,))

    print()
    if fails:
        print("%d check(s) failed" % len(fails)); sys.exit(1)
    print("the screen matches the engine on every planted case")

if __name__ == "__main__":
    main()
