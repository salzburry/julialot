# Lines of therapy — the rules, in short

How a patient's treatment is cut into lines. `LOT_RULES.md` is the full
reference with every branch; this is the one-page version.

## The shape of it

**A line starts** with the first non-steroid MM agent. Anything else that
starts within the induction window joins the same line rather than opening a
new one — **60 days** for line 1, **30 days** for later lines.

**A line ends** at the first of these, in this order:

| Priority | Ends because | |
|---|---|---|
| 1 | a transplant or CAR-T | line ends the day before it |
| 2 | `CART_INIT` | an agent added, then CAR-T within 45 days — bridging |
| 3 | `MED_ADD` | a new agent added outside the induction window |
| 4 | `DEATH` | |
| 5 | `DISCONTINUATION` | the drugs ran out, and it was confirmed |
| 6 | `STUDY_END` | nothing else happened |

**Running out** is per drug: a gap of **90 days or more** to the next fill.
The line has run out when its last agent has.

**Confirmed** means one of two things — **90 days** of data follow the run-out
with nothing in them, or the patient came back (a restart, a transplant). Below
that, with no return, the line is censored at end of observation instead.

**Up to 5 lines** are built per patient.

## Assumptions worth knowing

**Steroids are invisible.** They never start a line, join a regimen, end a line,
or trigger an added-medication end. Corticosteroids are not treated as oncology
agents.

**A medical claim gets 28 days of supply**, because the claim does not carry
one.

**Disenrollment is not censoring.** A patient who leaves the plan keeps
contributing follow-up; the line ends `STUDY_END`. The `*_CE_SENS` columns
carry the alternative reading.

**A second transplant within 180 days is a planned tandem**, not a new line.

**An allogeneic transplant is a one-day line** and carries no regimen.

**Maintenance is not implemented.** There is no maintenance period; those cases
end by whichever rule above applies first.

**Line 5 is a cap, not a finding.** A patient at line 5 may have had more.

**Belantamab removes the patient entirely** — every line of anyone who received
it at any point is dropped.

## CAR-T — applied

**Inside line 1's 60-day induction window, a CAR-T is part of line 1.** It does
not end the line and it does not start one. Confirmed by the study team on
2026-08-13; runs before that date differ.

**Outside that window it does both** — the line ends the day before the
infusion, and the CAR-T opens the next line.

**Bridging.** An agent added and then a CAR-T within **45 days** is bridging,
not a new regimen. The line ends `CART_INIT` the day before the infusion and
the bridging agent stays in it.

**It does not reopen a closed line.** If the line already ended on day 30 for
some other reason and the CAR-T is on day 40, the line still ended on day 30 —
the rule stops that CAR-T starting a line, it does not extend the previous one.

## Melphalan — built, not applied

**The study's numbers do not use this rule.** It is built as three complete
runs in `melphalan/`, each recording the deviation, so the effect can be
measured before anyone decides. What follows is what those runs apply.

Doses less than **30 days** apart are one *exposure*. Consecutive exposures are
then judged as a pair — by the gap between them, and by whether the first sits
inside the line's induction window:

| Where the first dose sits | Gap | Effect |
|---|---|---|
| inside induction | < 180 days | nothing |
| inside induction | ≥ 180 days | the later dose advances the line |
| outside induction | < 60 days | this dose starts a line |
| outside induction | 60–179 days | nothing |
| outside induction | ≥ 180 days | the later dose advances the line |

**A coded transplant is read two ways**, which is why three runs exist rather
than two. High-dose melphalan is transplant conditioning, so a melphalan claim
and an AUTO code are often the same event and the transplant rule already fires
on it. `as_asked` judges every exposure anyway; `yield_to_sct` leaves an
exposure with an AUTO within **14 days** to the transplant rule.

**Two things are still open.** The 60–179 day case removes the boundary but
does not hold the line open, so a regimen that runs out between the two doses
still ends there. And a pair whose first dose sits beside a transplant but whose
second does not currently does not advance. Both are with the study team.

## What stops a run

A cohort whose own build did not finish, a setting that differs from the pinned
contract without an explicit override, a code list that cannot be read, or a
line that ends in a way the rules above cannot produce.
