# Line of therapy rules

The short version. `LOT_RULES.md` carries every branch.

## Starting and ending a line

A line starts at the patient's first non-steroid myeloma agent. Any other agent
that starts within the induction window joins that line rather than opening a
new one. The window is 60 days for line 1 and 30 days for lines 2 to 5.

A line ends at the first of these events, in this order:

| Priority | Reason | End date |
|---|---|---|
| 1 | transplant or CAR-T | day before the procedure |
| 2 | `CART_INIT` | day before a CAR-T that follows an added agent within 45 days |
| 3 | `MED_ADD` | day before an agent added outside the induction window |
| 4 | `DEATH` | date of death |
| 5 | `DISCONTINUATION` | the date the regimen ran out |
| 6 | `STUDY_END` | end of observation |

Running out is measured per drug. A drug has run out when the gap from the end
of its supply to its next fill is 90 days or more. The line has run out when
its last remaining agent has.

A run-out becomes a discontinuation only once confirmed. Either 90 days of
observation follow it with nothing in them, or the patient turns up again with
a restart, a new agent or a transplant. If neither happens the line is censored
at the end of observation and ends `STUDY_END` or `DEATH` instead.

Five lines are built per patient.

## Assumptions

Steroids are excluded throughout. They do not start a line, join a regimen, end
a line, or count as an added medication. Corticosteroids are not treated as
oncology agents.

Medical claims carry no day supply, so 28 days is assumed for each.

An agent joins a line's regimen by starting a supply episode inside the induction
window. Optum supplies no treatment end date: coverage is derived from the fill
date and the days supplied, and overlapping refills stockpile it forward into one
episode. So a supply dispensed during the previous line and stockpiled into this
one does not join this one — a patient who has switched is no longer filling the
old agent, and the leftover cover is a dispensing artefact rather than treatment.
The same test also drops a fill made inside the window when a still-open episode
of that agent absorbs it, which is narrower than the protocol's "all MM therapies
received within 30 days"; `lot/validation/run_stockpiling_rule.R` sizes it.

Disenrollment does not censor. A patient who leaves the plan keeps contributing
follow-up and the line ends `STUDY_END`. The `*_CE_SENS` columns hold the
alternative reading.

Line 1's first autologous transplant is part of induction and does not end the
line. A second one ends it, unless it falls within 180 days of the first — that
is a planned tandem, and then it takes a third. Lines 2 to 5 do not keep this
convention: there the first transplant after the induction window ends the line.

That is about which transplant *ends* a line. One falling after a line has
already ended opens the next line whatever the line number.

An allogeneic transplant occupies a single day and carries no regimen string.

Maintenance is not implemented. Patients on maintenance therapy end by
whichever of the rules above applies first.

Five lines is a cap, not a finding. A patient recorded at line 5 may have had
more.

Belantamab removes the patient rather than the line. Every line belonging to
anyone who received it at any point is dropped.

## A returning agent

An agent already seen opens or ends a line only where the patient had stopped
it. Formally, both must hold:

    the agent is absent from that line's regimen
    AND (it is a first exposure OR its preceding episode was discontinued)

| the agent returns | result |
|---|---|
| never had it before | opens or ends a line |
| its previous supply ended under 90 days ago | continuation - no boundary |
| its previous supply ended 90 days ago or more | reintroduction - opens a line |
| already in this line's regimen | no boundary |

Discontinued means the same `MAP_DISCON_GAP_DAYS` used everywhere else, so
there is one threshold in the build and not two. The test reads the *preceding*
episode, never the returning one - an episode's own flag describes the gap that
follows it.

A supply episode reopens whenever cover lapses by a single day, so an episode
starting is not on its own evidence that the patient started the drug. That is
what this rule separates.

The setting is `RETURNING_AGENT_REQUIRES_DISCONTINUATION` in
`engine/config.csv`. Turned off, the build behaves as though this section were
absent.

## Treatment that does not advance a line

An agent this rule declines still happened, so it is recorded. `LOT_BASE_MEDS`
stays the induction regimen the protocol defines, and `LOT_CONTINUING_MEDS`
carries anything else dispensed while the line ran - an episode starting inside
the line, not a steroid, not already in the regimen.

It is descriptive. A continuing agent does not hold the line open: run-out is
still measured on the induction regimen alone.

An agent can be continuing in one line and part of the next line's regimen, so
a tally of exposure by line has to read both columns.

## Worked examples

Every line below is the engine's own output. Days supply of 60 for the first
LEN fill unless stated; a medical claim carries 28.

**A second agent inside line 1's window joins it.** LEN 1 Jan, POMA 1 Feb:

    LOT1  2016-01-01 -> 2016-02-29   LEN POMA

**Outside the window it starts a line.** LEN 1 Jan, POMA 2 Mar - day 61, past
the 60-day window:

    LOT1  2016-01-01 -> 2016-02-29   LEN
    LOT2  2016-03-02 -> 2016-03-29   POMA

**A refill inside cover extends the line by its own days supply**, rather than
moving the end to the refill's own runout. LEN 1 Jan ds60 covers to 29 Feb; a
LEN refill on 1 Feb ds28 arrives while cover is live, so the runout is pushed
out by 28 days:

    LOT1  2016-01-01 -> 2016-03-28   LEN

**A drug returning after a real break starts a line, on itself.** LEN 1 Jan
ds60, nothing else, LEN 1 Sep - 185 days after cover ran out:

    LOT1  2016-01-01 -> 2016-02-29   LEN
    LOT2  2016-09-01 -> 2016-09-30   LEN

**A drug returning while another agent runs.** LEN 1 Jan-28 Mar, POMA 15 Mar-20
May, LEN again 1 May - 34 days after LEN's own cover ended, so LEN never
stopped:

    LOT1  2016-01-01 -> 2016-03-14   LEN
    LOT2  2016-03-15 -> 2016-05-20   POMA    continuing LEN

POMA starts while LEN is still covered and still opens a line: it is outside
line 1's window and in no regimen. LEN's reappearance opens nothing, and is
recorded against line 2 instead. Line 2 ends on POMA's run-out.

## CAR-T

A CAR-T inside line 1's 60-day induction window belongs to line 1. It does not
end that line and it does not start one. Outside the window it does both: the
line ends the day before the infusion and the CAR-T opens the next line.

An agent added and then followed by a CAR-T within 45 days is bridging therapy.
The line ends `CART_INIT` the day before the infusion, and the bridging agent
stays in that line rather than starting a regimen of its own.

The rule does not reopen a closed line. If line 1 ended on day 30 for some
other reason and the CAR-T falls on day 40, line 1 still ends on day 30. The
rule stops that infusion starting a line; it does not extend the one before it.

## Melphalan

Not applied: the study's numbers do not include this rule. It is built as three
complete runs under `melphalan/`, each recording the deviation. What follows
describes those runs, not the study cohort.

Doses less than 30 days apart form one exposure. Consecutive exposures are then
judged as a pair, on the gap between them and on whether the first falls inside
the line's induction window.

| First dose | Gap to the next exposure | Effect |
|---|---|---|
| inside induction | under 180 days | none |
| inside induction | 180 days or more | the later dose advances the line |
| outside induction | under 60 days | this dose starts a line |
| outside induction | 60 to 179 days | none |
| outside induction | 180 days or more | the later dose advances the line |

High-dose melphalan is transplant conditioning, so a melphalan claim and an
AUTO code often describe the same event, which the transplant rule has already
acted on. Two readings are built. `as_asked` judges every exposure regardless.
`yield_to_sct` leaves any exposure with an AUTO within 14 days to the
transplant rule.

Two cases are unresolved. In the 60 to 179 day case the boundary is removed but
the line is not held open, so a regimen that runs out between the two doses
still ends there. And a pair whose first dose sits beside a transplant while the
second does not will not advance the line.

## What stops a run

A cohort whose own build did not finish. A setting that differs from the pinned
contract without an explicit override. A code list that cannot be read. A line
that ends in a way these rules cannot produce.
