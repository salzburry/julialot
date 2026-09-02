#!/usr/bin/env python3
"""The MAP fold-in rule, proved on planted patients.

Runs the engine's own emitted SQL twice, over patients that pin each branch of
the rule. CONTRACT pins APPLY_MAP_FOLDIN TRUE, so the FOLD arm is the study's
build; the other arm is MAP_FOLDIN=FALSE, kept as the reference to measure it
against. The assertions below name them `fold` and `ref` for that reason - the
word "contract" in an assertion label means the reference arm and is a
leftover, not a claim about what the contract pins. The rule, from the study
team: a prior line's agent returning after the current line's regimen window is
PART of that line, not a reason to start the next one.

  F1  drug B (1L) returns during 2L          -> the split disappears; 2L runs
      to its own run-out
  F2  ...and returns after 2L already ran
      out                                    -> 2L is carried to B's cover
      and ends there
  F3  B returns the same day a genuinely
      new drug starts                        -> the boundary stays; the new
      drug starts the next line on that day under both builds
  F4  B's permissible substitute returns     -> folds like B itself
  F4b ...and the REVERSE: the substitute is
      the prior regimen's drug and the
      reference product returns              -> the same. 4.4 makes the pair
      one agent, so the fold has to read the same whichever half the regimen
      names
  F4c the pair dosed on ONE day              -> the course grouping takes both,
      so the tie decides nothing
  F5  B restarts with NO newer line in
      between                                -> ONE line either way. Nothing
      was given in between, so 4.3 keeps the restart inside the line it left
      and this rule has nothing to decide
  F6  B returns two lines later, during 3L   -> does NOT fold. B is not in
      the previous line's regimen, so it is outside the fold set. The
      request's second clause would give the same answer, but it is not what
      decides this one - see F13
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
  F13 B returns with TWO advances in between -> starts a line. Scoped to the
      previous line the count cannot reach two, so this pins the OUTCOME the
      request's second clause describes, not the clause itself
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
  F18 the line's own drug restarts, then B
      returns                                -> DARA's restart no longer opens
      a line of its own (4.3), so one agent advanced the line and B folds
  F19 the return lands inside a short
      MELPHALAN course                       -> it does not confirm it. A
      returning drug is not a NEW agent, so the melphalan rule cannot read as
      a change the drug this rule bundles
  F19n ...and the same patient with no
      melphalan at all                       -> identical regimen and count. A
      suppressed course decides nothing, so it must not decide this either
  F20-F26                                    -> the transplant, course and
      substitute cases; each is commented where it is planted below
  F27 a suppressed course that was in the
      previous regimen                       -> joins neither regimen nor
      count (4.7), where the fold would otherwise have taken it
  F28-F30 how far back the returner was
      last seen                              -> previous line folds; anything
      further back is simply a new agent
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
    # F4r: F4 with the reference product in place of the substitute, and
    # nothing else changed. 4.4 makes the pair one agent, so the two patients
    # have to come out with the same lines - same dates, same end reasons.
    # Counting lines alone cannot see the difference: the run-out chain read a
    # substitute's single distant episode as this line's cover, because the
    # interrupt scan looked only between a drug's OWN episodes and a substitute
    # the patient never took in the line has none to look between. F4 ended 1L
    # on day 199 as MED_ADD where F4r ended it on day 80 as DISCONTINUATION.
    P('F4r', L1 + [('DARA', 'MAB', 200, 400), ('BORT', 'PI', 300, 360)]),
    # F4d/F4e: the pair the OTHER way round in ordinary line-building, not in
    # the fold. 1L reports the biosimilar and the reference product returns.
    # 4.4 makes them one agent whichever half the line names, so the return
    # cannot open a line - and the two patients have to come out identical.
    # The substitution expansion ran reference -> substitute only, so the
    # biosimilar-first patient had the reference product open 2L for them.
    P('F4d', [('LEN', 'IMID', 0, 80), ('BORTB', 'PI', 0, 80),
              ('BORT', 'PI', 450, 510)]),
    P('F4e', [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80),
              ('BORTB', 'PI', 450, 510)]),
    # F4f: a folded drug, then the equivalent product after it. BORT folds
    # into 2L; BORTB arriving later is the same agent, so it belongs to 2L
    # too. Adding only the exact folded abbreviation to the working set, BORTB
    # ended 2L as an addition while the next line refused to open on it - and
    # that treatment sat in no line at all.
    P('F4f', L1 + [('DARA', 'MAB', 200, 900), ('BORT', 'PI', 450, 510),
                   ('BORTB', 'PI', 600, 660)]),
    # F4b: the reverse direction. BORTB is 1L's regimen drug and BORT - the
    # drug it stands in for - is what returns. Expanding the raw regimen picked
    # up substitutes of a named drug but not the drug a named substitute stands
    # in for, so this pair folded one way and not the other.
    P('F4b', [('LEN', 'IMID', 0, 80), ('BORTB', 'PI', 0, 80),
              ('DARA', 'MAB', 200, 400), ('BORT', 'PI', 300, 360)]),
    # F4c: both halves of the pair on one date, with different cover. They
    # share an agent, so the lag inside that partition has two candidates and
    # no order between them - the course grouping is what makes it not matter.
    P('F4c', L1 + [('DARA', 'MAB', 200, 400),
                   ('BORT', 'PI', 300, 360), ('BORTB', 'PI', 300, 500)]),
    P('F5', [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80),
             ('BORT', 'PI', 300, 360)]),
    # F6: B returns two lines after its own. Same outcome as F13 and for the
    # same reason - the fold set is the previous line's regimen and B is not
    # in it - so this pins the outcome, not the two-or-more clause.
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
    # F13 count 2: DARA then CARF, so the interval holds two advances.
    #
    # It starts a line of its own, exactly as it does with the rule off - but
    # NOT because the two-or-more clause fired. By day 450 the immediately
    # previous line's regimen is CARF, and the fold set is that regimen, so B
    # is not a fold candidate and the count is never asked. Scoped to the
    # previous line the count can only ever be nought or one; the two-or-more
    # clause is the rule the study team asked for and is unreachable, which
    # STUDY_TEAM_ASKS.md carries as an open scope question. What this patient
    # pins is the OUTCOME the clause describes, by whichever route: a return
    # with two advances behind it gets a line.
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
    # F18: the line's own drug takes a break. DARA opens 2L on day 200, its
    # cover ends day 260, and it restarts on day 400 - past the discontinuation
    # gap. Under LOT_RULES.md 4.3 that restart opens no line: nothing new was
    # given, so DARA is returning to the line it left and 2L runs over the
    # break. One agent has advanced the line while B was away, so B folds.
    P('F18', L1 + [('DARA', 'MAB', 200, 260), ('DARA', 'MAB', 400, 600),
                   ('BORT', 'PI', 450, 510)]),
    # F20-F24 come from an external review of the rules as first shipped.
    # Every one produced a wrong line, a drug in a regimen it never covered, or
    # treatment in no line at all.
    #
    # F20: B returns the SAME DAY a genuinely new CARF opens the next line. The
    # count looks strictly BEFORE the return, so it does not see CARF and folds
    # anyway - and the regimen union had no medication boundary, so 2L named a
    # drug whose only episode began after 2L had ended, while 3L named it too.
    # F20n: F20 with the return removed, to show where 2L ends on its own.
    # The return must not move that: assigned to 3L by the regimen while still
    # extending 2L, one episode was doing two jobs in two lines.
    P('F20n', L1 + [('DARA', 'MAB', 200, 400), ('CARF', 'PI', 450, 600)]),
    P('F20', L1 + [('DARA', 'MAB', 200, 400), ('BORT', 'PI', 450, 510),
                   ('CARF', 'PI', 450, 600)]),
    # F21: a return after a break SHORTER than the discontinuation gap. B is
    # away from d190 to d250 - 60 days, not 90 - and one agent advanced the
    # line while it was away, so it folds.
    #
    # This was reported as a defect, on the reading that "comes back after
    # being stopped" means the engine's 90-day discontinuation. It does not:
    # the request's own worked case (scenario S01) has the drug away for 60
    # days, so requiring a discontinuation would refuse to fold the very
    # example the rule was written for. A new episode opens only for a claim
    # beyond every run-out, so every episode after a drug's first already
    # follows a break in cover, and that is the parent condition.
    P('F21', [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 20),
              ('BORT', 'PI', 160, 190), ('DARA', 'MAB', 200, 600),
              ('BORT', 'PI', 250, 300)]),
    # F22: B folds into 2L, then stops and returns AGAIN with nothing in
    # between. The fold put B in 2L's reported regimen, so 4.3 refused it a
    # line of its own - but the WORKING set did not carry it, so 2L stopped at
    # its own drug's cover and the second return fell in no line at all.
    P('F22', L1 + [('DARA', 'MAB', 200, 600), ('BORT', 'PI', 300, 360),
                   ('BORT', 'PI', 700, 760)]),
    # F23: CARF and DARA co-start 2L. That is ONE advance, not two, so B's
    # return still folds. Counting each opener drug made it two.
    P('F23', L1 + [('DARA', 'MAB', 200, 600), ('CARF', 'PI', 200, 600),
                   ('BORT', 'PI', 450, 510)]),
    # F24: the return comes BEFORE the melphalan course, where F19 has it
    # after. B folds into 2L, so it is not another agent taking the course from
    # 2L - but melp_taken read the working base set, where a folded drug is
    # absent, and let the course end 2L as an added medication with no line
    # opening on it.
    P('F24', L1 + [('DARA', 'MAB', 200, 600), ('BORT', 'PI', 300, 360),
                   ('MELP', 'ALKY', 450, 477)]),
    # F25/F26: what BREAKS a line, by kind. An ALLO or CAR-T breaks it from
    # the line START - no window - which is how lot{n}_regimen_cutoff cuts a
    # regimen. Only an AUTO gets the induction window and the tandem
    # exemption. Reading one window over all three was a helper that
    # contradicted the rule it cited.
    dict(P('F25', L1 + [('DARA', 'MAB', 200, 600), ('BORT', 'PI', 450, 510)]),
         sct_ac=[('CART', IX + 210)]),
    dict(P('F26', L1 + [('DARA', 'MAB', 200, 600), ('BORT', 'PI', 450, 510)]),
         sct_ac=[('ALLO', IX + 210)]),
    # F19: where the two adopted rules meet. DARA opens 2L. A short melphalan
    # course sits at day 450, outside 2L's window, and B returns at day 455 -
    # inside that course's cover. The melphalan rule advances a short course
    # when a NEW agent starts while it still covers; this rule says B is not a
    # new drug but the returning one. Without that, B was bundled by one rule
    # and read as a change by the other, and 3L opened on the melphalan date.
    P('F19', L1 + [('DARA', 'MAB', 200, 600),
                   ('MELP', 'ALKY', 450, 477), ('BORT', 'PI', 455, 520)]),
    # F19n: F19 with the melphalan course taken out and nothing else changed.
    # The course is SUPPRESSED, so it decides nothing and B's fold must read
    # the same either way - regimen and count included. The "genuinely new
    # agent" scan did not know about suppressed dates, so it treated the
    # course as a drug arriving and dropped B from 2L's regimen while leaving
    # every date identical: a doublet reported as a single agent, invisible in
    # the shape of the line.
    P('F19n', L1 + [('DARA', 'MAB', 200, 600), ('BORT', 'PI', 455, 520)]),
    # F27: melphalan is in 1L's OWN regimen and returns as a suppressed short
    # course during 2L. 4.7 says a held course joins neither regimen nor
    # count; the fold folded it in regardless, and the two rules disagreed
    # about one episode.
    P('F27', [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 0, 27),
              ('DARA', 'MAB', 200, 600), ('MELP', 'ALKY', 450, 477)]),
    P('F27n', [('LEN', 'IMID', 0, 80),
               ('DARA', 'MAB', 200, 600), ('MELP', 'ALKY', 450, 477)]),
    # F31: a suppressed course and a returning drug starting the SAME DAY.
    # melp_suppress_dates carries a patient and a date, so a suppression test
    # that matched on those alone removed whatever else began that day - B was
    # dropped from the fold set and opened a line of its own. B must fold here
    # exactly as it does when it arrives a day later, which F31n is.
    P('F31', L1 + [('DARA', 'MAB', 200, 600),
                   ('MELP', 'ALKY', 450, 477), ('BORT', 'PI', 450, 510)]),
    P('F31n', L1 + [('DARA', 'MAB', 200, 600),
                    ('MELP', 'ALKY', 450, 477), ('BORT', 'PI', 451, 510)]),
    # F32: the study team's day-100/105 rule where the melphalan is ALSO a
    # returning previous-line drug. MELP is in 1L's regimen, DARA opens 2L,
    # MELP returns at d450 for 28 days, and POMA starts at d455 inside that
    # cover - so 4.7 CONFIRMS the course and the next line starts on the
    # melphalan date. 4.8 must stand back: a dose that starts a line is not a
    # drug folding back into the line before it.
    #
    # Claimed by both rules, 2L ran to d449 with MELP in its regimen - a drug
    # whose only episode begins at d450, after 2L has ended - and its end
    # reason changed with it. F32n is the same patient without the confirming
    # agent, where the course IS suppressed and 2L legitimately holds it.
    P('F32', [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 0, 27),
              ('DARA', 'MAB', 200, 300), ('MELP', 'ALKY', 450, 477),
              ('POMA', 'IMID', 455, 520)]),
    P('F32n', [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 0, 27),
               ('DARA', 'MAB', 200, 300), ('MELP', 'ALKY', 450, 477)]),
    # F33: an injected course is a BOUNDARY for a different returning drug.
    # MELP returns at d450 and POMA d455 confirms it, so the course opens the
    # next line on d450. BORT - a 1L drug - returns at d451, AFTER that
    # boundary, so it belongs to the line the boundary opened.
    #
    # The fold-in excluded injected MELP from every scan, including the one
    # that asks what ARRIVED between a returning drug's doses. That hid a real
    # boundary: BORT saw only DARA behind it, folded into a line that had
    # already ended, and 2L reported a drug whose only episode began at d451.
    P('F33', [('LEN', 'IMID', 0, 80), ('BORT', 'PI', 0, 80),
              ('DARA', 'MAB', 200, 300), ('MELP', 'ALKY', 450, 477),
              ('BORT', 'PI', 451, 520), ('POMA', 'IMID', 455, 560)]),
    # F34: F33 with MELP moved INTO the first line, and nothing else changed.
    #
    # That one move puts melphalan in the fold set, and the between-scan drops
    # every fold-set drug before it asks whether a row is an injected course -
    # so the d450 boundary went invisible and BORT, returning at d451, folded
    # into a 2L that had already ended. 2L then reported BORT with its only
    # returning episode starting after 2L's end, and BORT stood in both 2L and
    # 3L. F33 cannot reach this: melphalan is not in ITS fold set, so the
    # exclusion has nothing to match and the boundary survives by luck of the
    # regimen rather than by the rule.
    #
    # The pair is the test. F33 and F34 must give the same answer, because
    # which line happened to have given melphalan earlier says nothing about
    # whether a confirmed course is a boundary.
    P('F34', [('LEN', 'IMID', 0, 80), ('MELP', 'ALKY', 0, 27),
              ('BORT', 'PI', 0, 80),
              ('DARA', 'MAB', 200, 300), ('MELP', 'ALKY', 450, 477),
              ('BORT', 'PI', 451, 520), ('POMA', 'IMID', 455, 560)]),
    # F28/F29/F30: one scope for "not new". Three patients with the same
    # history and the same short melphalan course at day 600, differing only
    # in how far back the drug returning inside it was last seen.
    #
    #   F28  the previous line's drug  -> folds, and there is no next line
    #   F29  a drug from TWO lines back -> does not fold, but it IS new, so it
    #        confirms the course and the next line opens on the melphalan date
    #   F30  a drug never seen          -> the same as F29
    #
    # melp_not_new read EVERY earlier line while the fold set reads only the
    # previous one, so F29's drug was at once too old to confirm and - 4.3
    # excluding only the previous regimen - new enough to open a line. It
    # started the next line on its own date, ten days after the melphalan one,
    # where F30 started it on the course. F29 and F30 now agree.
    P('F28', L1 + [('DARA', 'MAB', 200, 280), ('CARF', 'PI', 400, 800),
                   ('MELP', 'ALKY', 600, 627), ('DARA', 'MAB', 610, 700)]),
    P('F29', L1 + [('DARA', 'MAB', 200, 280), ('CARF', 'PI', 400, 800),
                   ('MELP', 'ALKY', 600, 627), ('BORT', 'PI', 610, 700)]),
    P('F30', L1 + [('DARA', 'MAB', 200, 280), ('CARF', 'PI', 400, 800),
                   ('MELP', 'ALKY', 600, 627), ('POMA', 'IMID', 610, 700)]),
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
    for pid, n, s, e, why, meds, cnt in con.execute(
            "SELECT PATID, LOT_NUM, LOT_START_DT, LOT_BASE_END_DT, "
            "LOT_BASE_END_REASON, coalesce(LOT_BASE_MEDS, ''), LOT_MED_CNT "
            "FROM lot_long ORDER BY PATID, LOT_NUM").fetchall():
        lines.setdefault(pid, []).append((n, str(s)[:10], str(e)[:10], why))
        REGIMEN.setdefault((foldin, pid), {})[n] = (meds, cnt)
    # OWNERSHIP, the two invariants the line table alone cannot show. A drug a
    # line REPORTS has to have an episode inside that line, and every
    # non-steroid episode has to belong to a line. The harness read only line
    # numbers, dates and end reasons before, which is how a line naming a drug
    # it never covered, and a return left in no line at all, both passed.
    #
    # Not "a drug appears in one line only" - a drug legitimately returns in a
    # later line and is that line's regimen too.
    # The shipped QC over planted patients that HAVE a substitution pair, with
    # the fold-in on. run_synthetic runs the same catalogue over its drawn
    # population and its own pair; this run adds the cases a draw does not
    # reach. C1 failed a legitimately folded biosimilar for want of a test that
    # could see it, and neither run could see it while both tables were empty.
    if foldin:
        QC.extend(qc_findings(con, sqldir))
    OWNERSHIP[foldin] = {
        "orphan": con.execute("""
            SELECT ms.PATID, ms.MAP_MED_TYPE, cast(ms.MAP_START_DT AS date)
            FROM map_stacked ms
            LEFT JOIN lot_long l
              ON l.PATID = ms.PATID
             AND ms.MAP_START_DT >= l.LOT_START_DT
             AND ms.MAP_START_DT <= l.LOT_BASE_END_DT
            WHERE ms.MAP_MED_CLASS <> 'STEROID' AND l.PATID IS NULL
            ORDER BY 1, 3""").fetchall(),
        "phantom": con.execute("""
            WITH reg AS (
              SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT, m AS MED_ABBR
              FROM lot_long l, UNNEST(str_split(coalesce(l.LOT_BASE_MEDS,''),' ')) AS t(m)
              WHERE m <> ''
            )
            SELECT r.PATID, r.LOT_NUM, r.MED_ABBR
            FROM reg r
            LEFT JOIN map_stacked ms
              ON ms.PATID = r.PATID AND ms.MAP_MED_TYPE = r.MED_ABBR
             AND ms.MAP_START_DT >= r.LOT_START_DT
             AND ms.MAP_START_DT <= r.LOT_BASE_END_DT
            WHERE ms.PATID IS NULL ORDER BY 1, 2""").fetchall(),
    }
    con.close()
    return lines


def qc_findings(con, sqldir):
    """Every fail-severity row the shipped catalogue returns on this build.

    Asks checks.R for its own SQL rather than re-implementing any of it - a
    rewrite can be right while the shipped check is wrong, which is exactly
    what C1 was.
    """
    qcfile = os.path.join(sqldir, "qc.tsv")
    r = subprocess.run(["Rscript", os.path.join(HERE, "emit_qc.R"), qcfile],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return ["emit_qc.R failed: " + (r.stdout + r.stderr).strip()[:200]]
    out = []
    with open(qcfile) as fh:
        head = fh.readline().rstrip("\n").split("\t")
        for line in fh:
            row = dict(zip(head, line.rstrip("\n").split("\t")))
            if not row["sql"] or row["severity"] != "fail":
                continue
            try:
                n, detail = con.execute(
                    rs.to_duckdb(row["sql"].replace("\\n", "\n"))).fetchone()
            except Exception as ex:
                out.append(f"{row['id']} could not run: {str(ex).splitlines()[0][:80]}")
                continue
            if n:
                out.append(f"{row['id']}: {n} - {row['what']}"
                           + (f"  e.g. {detail}" if detail else ""))
    return out


# Filled by build(): the reported regimen per (arm, patient, line), and the
# three ownership queries. Kept beside the line table so an assertion can ask
# about either without a second build.
REGIMEN, OWNERSHIP, QC = {}, {}, []


def regimen(foldin, pid, lot):
    return REGIMEN.get((foldin, pid), {}).get(lot, ("", 0))


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
    ok(fold.get('F4') == fold.get('F4r') and ref.get('F4') == ref.get('F4r'),
       "F4/F4r: ...and the whole line - dates and end reasons, not just the "
       "count - is what the reference product gives")
    ok(not QC, "the shipped QC has no fail on a build with a substitution "
               "pair" + (": " + "; ".join(QC) if QC else ""))
    ok(n(fold, 'F4d') == 1 and fold.get('F4d') == fold.get('F4e'),
       "F4d/F4e: the pair is one agent whichever half the regimen names, so "
       "neither half's return opens a line")
    ok(n(ref, 'F4b') == 3 and n(fold, 'F4b') == 2,
       "F4b: ...and so does the reference product when the substitute is the "
       "regimen drug")
    ok(n(ref, 'F4c') == 3 and n(fold, 'F4c') == 2
       and fold['F4c'][1][2] == rs.d(IX + 500),
       "F4c: the pair dosed on one day folds as one course, to day 500")

    ok(n(fold, 'F29') == 4 and fold['F29'][3][1] == rs.d(IX + 600)
       and n(fold, 'F30') == 4 and fold['F30'][3][1] == rs.d(IX + 600),
       "F29/F30: a drug from further back than the fold reaches is NEW, so it "
       "confirms the course and the line opens on the melphalan date, exactly "
       "as a drug never seen does")
    ok(n(fold, 'F28') == 3,
       "F28: ...while the previous line's own drug still folds, and no line "
       "opens at all")

    ok(n(fold, 'F4f') == 2 and fold['F4f'][1][2] == rs.d(IX + 900),
       "F4f: a folded drug brings its whole agent, so the equivalent product "
       "after it stays in the line and is not left outside every line")

    ok(ref.get('F5') == fold.get('F5') and n(ref, 'F5') == 1,
       "F5: a restart with no newer line in between stays in the line it left")

    # F32: the two adopted rules reaching for one course. 4.7 wins, by the
    # study team's own words - the new line starts when the melphalan appears.
    ok(fold.get('F32') == ref.get('F32') and n(fold, 'F32') == 3,
       "F32: a confirmed course that is also a returning drug starts a line, "
       "so the fold leaves it alone and both builds agree")
    ok(n(fold, 'F32') == 3 and fold['F32'][1][2] == rs.d(IX + 300) and
       fold['F32'][2][1] == rs.d(IX + 450),
       "F32: ...2L keeps its own end at d300 and 3L starts on the melphalan "
       "date, not the confirming agent's")
    ok(REGIMEN[(True, 'F32')][2][0] == 'DARA',
       "F32: ...and 2L does not name a drug whose episode begins after it ended")
    ok(n(fold, 'F32n') == 2 and fold['F32n'][1][2] == rs.d(IX + 477),
       "F32n: with no confirming agent the course is suppressed, and 2L is "
       "held to its cover as before")

    ok(REGIMEN[(True, 'F33')][2][0] == 'DARA' and n(fold, 'F33') == 3,
       "F33: an injected course is a boundary, so a drug returning after it "
       "does not fold into the line before it")
    ok(REGIMEN[(True, 'F34')][2][0] == 'DARA' and n(fold, 'F34') == 3,
       "F34: the same, with melphalan in the fold set - a confirmed course is "
       "a boundary whoever else has given the drug")
    ok(fold['F34'][1][2] == fold['F33'][1][2] and
       fold['F34'][1][3] == fold['F33'][1][3],
       "F34: ...so it ends where F33 ends, for the same reason: which line "
       "gave melphalan earlier decides nothing here")
    ok(fold['F33'][1][2] == rs.d(IX + 300),
       "F33: ...and that line keeps its own end rather than being carried "
       "past the boundary")

    ok(n(ref, 'F6') == 4 and n(fold, 'F6') == 4,
       "F6: a return from two lines back is outside the fold set, so it "
       "starts a line under both")

    ok(ref.get('F7') == fold.get('F7') and ref.get('F7'),
       "F7: a patient with no prior-line return is identical under both builds")

    # The count, arm by arm.
    ok(ref.get('F11') == fold.get('F11') and ref.get('F11'),
       "F11 count 0: nothing advanced in between, so the rule leaves it alone")
    ok(n(ref, 'F12') > n(fold, 'F12'),
       "F12 count 1: one advance in between, so the return folds")
    ok(ref.get('F13') == fold.get('F13') and ref.get('F13'),
       "F13: two advances in between, so the return starts a line - by the "
       "fold set's scope, not by the two-or-more clause, which cannot fire")

    ok(n(ref, 'F14') == 3 and n(fold, 'F14') == 2,
       "F14: the whole returning course folds, not only its first episode")
    ok(n(fold, 'F14') == 2 and fold['F14'][1][2] == rs.d(IX + 600),
       "F14: ...and one line owns it, so no line opens on the follow-up")
    ok(n(ref, 'F15') == 4 and n(fold, 'F15') == 4,
       "F15: a CAR-T opened a line in between, and that overrides the fold")
    ok(n(fold, 'F15') == 4 and fold['F15'][1][2] == rs.d(IX + 250)
       and fold['F15'][1][3] == 'DISCONTINUATION',
       "F15: ...so LOT2 keeps its own discontinuation")

    ok(regimen(True, 'F19', 2) == regimen(True, 'F19n', 2),
       "F19/F19n: a suppressed course decides nothing, so the folded regimen "
       "reads the same with and without it (" + str(regimen(True, 'F19', 2))
       + " vs " + str(regimen(True, 'F19n', 2)) + ")")
    ok(n(fold, 'F31') == 2 and regimen(True, 'F31', 2) == regimen(True, 'F31n', 2),
       "F31/F31n: a suppressed course removes only MELP, so a drug arriving "
       "the same day still folds (" + str(regimen(True, 'F31', 2)) + ")")

    ok(regimen(True, 'F27', 2) == regimen(True, 'F27n', 2),
       "F27/F27n: a held melphalan course joins neither regimen nor count, "
       "even where the fold would otherwise take it ("
       + str(regimen(True, 'F27', 2)) + " vs "
       + str(regimen(True, 'F27n', 2)) + ")")

    ok(n(ref, 'F19') == 3 and ref['F19'][2][1] == rs.d(IX + 450),
       "F19 contract: the melphalan course advances the line on its own date")
    ok(n(fold, 'F19') == 2 and fold['F19'][1][2] == rs.d(IX + 600)
       and fold['F19'][1][3] == 'DISCONTINUATION',
       "F19 fold-in: the returning drug is not a new agent, so it confirms "
       "nothing and 2L runs through")

    ok(n(ref, 'F18') == 3 and n(fold, 'F18') == 2,
       "F18 contract: the own-drug restart opens no line, and B still takes one")
    ok(n(fold, 'F18') == 2 and fold['F18'][1][2] == rs.d(IX + 600)
       and fold['F18'][1][3] == 'DISCONTINUATION',
       "F18 fold-in: ...and with one agent in between B folds, so 2L runs on")

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

    ok(n(fold, 'F20') == 3 and regimen(True, 'F20', 2)[0] == 'DARA'
       and n(ref, 'F20') == 3,
       "F20: a same-day new agent keeps the boundary, and 2L does not name "
       "the drug whose episode starts in 3L")
    ok(fold['F20'][1][2] == fold['F20n'][1][2]
       and fold['F20'][1][3] == fold['F20n'][1][3],
       "F20/F20n: the new drug takes preference, so the return belongs to the "
       "line it opens and leaves the previous line's end exactly where its own "
       "run-out put it (" + str(fold['F20'][1][2:4]) + ")")

    ok(regimen(True, 'F20', 3)[0] == 'BORT CARF',
       "F20: ...the line the return actually falls in names it")
    ok(n(ref, 'F21') == 3 and n(fold, 'F21') == 2
       and regimen(True, 'F21', 2)[0] == 'BORT DARA',
       "F21: a 60-day break is a return for this rule, as in the request's own "
       "worked case, so it folds")
    ok(n(fold, 'F22') == 2 and fold['F22'][1][2] == rs.d(IX + 760)
       and fold['F22'][1][3] == 'DISCONTINUATION',
       "F22: a folded drug's second return stays in the line that folded it")
    ok(n(ref, 'F23') == 3 and n(fold, 'F23') == 2
       and regimen(True, 'F23', 2)[1] == 3,
       "F23: two drugs co-starting a line advance it once, so the return folds")
    ok(n(fold, 'F24') == 2 and fold['F24'][1][2] == rs.d(IX + 600)
       and fold['F24'][1][3] == 'DISCONTINUATION',
       "F24: a folded drug is not another agent taking a melphalan course")

    for pid, kind in (('F25', 'CAR-T'), ('F26', 'an ALLO')):
        ok(fold.get(pid) == ref.get(pid) and n(fold, pid) == 4,
           "%s: %s inside the line's window still breaks it, so the return "
           "takes its own line" % (pid, kind))

    # The invariants, over every planted patient in both arms. A drug in two
    # regimens, a drug a line names but never covered, or an episode in no line
    # at all is a defect whatever the line numbers say.
    for arm, on in (("contract", False), ("fold-in", True)):
        o = OWNERSHIP[on]
        ok(not o["phantom"],
           "%s: every drug a line reports has an episode inside it (%s)"
           % (arm, o["phantom"][:3] or "none"))
        ok(not o["orphan"],
           "%s: every non-steroid episode belongs to a line (%s)"
           % (arm, o["orphan"][:3] or "none"))

    print()
    if fails:
        print("%d check(s) failed" % len(fails)); sys.exit(1)
    print("the fold-in lands every planted case where the request puts it")


if __name__ == "__main__":
    main()
