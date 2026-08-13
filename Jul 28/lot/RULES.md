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

**A CAR-T inside line 1's 60-day window is part of line 1** — it does not end
the line and does not start one. Outside that window it does both.

**A second transplant within 180 days is a planned tandem**, not a new line.

**An allogeneic transplant is a one-day line** and carries no regimen.

**Maintenance is not implemented.** There is no maintenance period; those cases
end by whichever rule above applies first.

**Line 5 is a cap, not a finding.** A patient at line 5 may have had more.

**Belantamab removes the patient entirely** — every line of anyone who received
it at any point is dropped.

**The melphalan rule is not applied.** It is built and available, but the
study's numbers do not use it.

## What stops a run

A cohort whose own build did not finish, a setting that differs from the pinned
contract without an explicit override, a code list that cannot be read, or a
line that ends in a way the rules above cannot produce.
