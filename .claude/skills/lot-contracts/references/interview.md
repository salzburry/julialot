# The contract interview

Questions to settle a new tumor's contract, grouped by axis, each mapped to the
field it fills. Work through all of them; an unanswerable question becomes a
`TBD:` entry in the contract naming what is needed and from whom. The people who
can answer are the study team / clinical leads — the interview's job is to make
their decisions explicit, not to make decisions for them.

Two framing rules before asking anything:

- Offer literature conventions as *proposals* (mark `assumed: true`), never as
  answers. "The 6-month PFI convention is common — is it this study's?" is the
  right shape.
- "None" is an answer and gets written down. A tumor with no event streams has
  `event_streams: {}` in its contract, on purpose.

## Drug roles → `drug_roles.*`

1. Which drug classes on this tumor's code list define lines? (default role)
2. What is supportive care here — invisible to line logic entirely? (steroids,
   antiemetics, G-CSF, bone agents…) → `supportive_classes`
3. Is there a backbone — therapy that continues across lines and must never
   start, advance, or end one, but should still be visible in outputs? (ADT in
   prostate; ET in some breast settings) → `backbone_classes`
4. Is there maintenance — therapy that may extend the line it belongs to but
   never advances one? (PARP/bev in ovarian) → `maintenance_classes`
5. For every class named: what is its exact spelling on the production code
   list? Unverified spellings are `TBD` — a misspelled class silently gets the
   default role, which is the failure mode this axis exists to prevent.

## Advancement → `advancement.*`

6. Does any new non-equivalent drug advance the line? (Almost always yes.)
7. Does a re-challenge advance — the same regimen restarting after a gap? If
   yes, what gap, measured runout-to-restart? (Ovarian platinum, SCLC doublet)
   → `same_regimen_gap_days`
8. Does dropping a drug from a combination ever advance? → `drop_based`

## Events → `event_streams.*`, `lines.line1_start_events`

9. Are there non-drug events that start or end lines — transplant, radiation,
   surgery? For each: the code list, grouping rules (window/merge), windows, and
   whether it may start line 1 or only later lines.
10. What may start line 1 at all? (Myeloma: drugs only.)
11. When several events fall on one day, what wins? → `lines.same_day_tie`

## Windows and caps → `lines.*`, `episodes.*`

12. Regimen window: how long may an agent join the starting regimen — first
    line, and later lines?
13. How many lines are worth building? → `max_lot` (a cap is a reporting
    choice; a capped patient is indistinguishable from a completed one)
14. Day supply for medical administrations; per-drug discontinuation gap — keep
    the engine defaults (28 / 90) unless the tumor has a reason.
15. When the drugs run out, how much observation has to follow before you would
    call it a discontinuation rather than the data running out? →
    `lines.discon_confirm_days` (`none` = any run-out counts). Ask it as a
    cadence question: how long after a missed dose would this tumor's clinic
    still expect to see the patient? Myeloma waits 90 days. Do not carry that
    number across — continuous oral therapy and three-weekly infusions leave
    different footprints when a patient stops.
16. If the patient turns up again after the run-out — a restart, a transplant —
    does that settle it on its own, or does the window still have to elapse? →
    `lines.discon_confirmed_by_return`. Worth spelling out what "no" costs: the
    next line starts after the previous one ends, so a line censored to end of
    observation absorbs the restart and the patient loses a line.
17. Does any event stream land inside first-line treatment as planned
    consolidation — a transplant or cell therapy given as part of induction
    rather than after it? → `event_streams.<NAME>.induction_absorbed`. Without
    it, first-line consolidation reads as a second line.

## Boundary labels → `boundary_labels.*`

15. What interval classifications does the study report — PFI, TFI,
    sensitive/resistant cut-points? Define each: from which event, to which
    event, thresholds. These label boundaries; confirm none is secretly a
    counting rule (if it is, it belongs under advancement instead).

## End of observation → `observation.*`

16. Does disenrollment censor in the primary analysis, or is it a sensitivity?
    (Engine default: sensitivity.)

## Exclusions → `criteria.*`

17. Any study-specific line/patient exclusions? (The engine's criteria layer —
    each is a named switch with a recorded cost.)

## Sign-off → `status`, `provenance`

18. Who reviewed this contract, and when? Until named: `status: draft`, and the
    contract's TBDs are its open questions list. Never mark `reviewed` on the
    author's own authority.
