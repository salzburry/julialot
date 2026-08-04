# Melphalan: a proposed line-advancing rule

A study-team request to change how a melphalan (`MELP`) administration advances
the line of therapy, and what the build does today.

The primary build is unchanged. This records the rule as asked, sets it beside
the current behaviour branch by branch, and gives the query that sizes it. It is
also available as a sensitivity on the NDMM cohort - `lot_validation`'s
`run_melphalan_rule.R`, opt-in through `MELP_EXECUTE`, which reports the branch
counts and which lines the rule would move without touching the LOT tables.

What that measurement cannot give is the resulting line structure, which needs a
rebuild. `aug1_melp/` does that: three complete LOT runs - the contract build
and both readings of the rule - and the difference between them.

## The rule as asked

An exposure is one administration; doses less than 30 days apart are the
same exposure.

If the first MELP dose is inside the induction window

| next dose | proposed |
|---|---|
| < 180 days later | does not advance the LOT |
| >= 180 days later | advances - the new LOT starts at that later dose |

If the first MELP dose is outside the induction window

| next dose | proposed |
|---|---|
| < 60 days later | advances, and the new LOT starts back at the first dose |
| 60-179 days later | does not advance - both doses stay in the current line |
| >= 180 days later | the first dose does not advance; the later dose starts a new LOT on its own date |

## Why melphalan is the drug this is asked about

High-dose melphalan is the conditioning for autologous transplant, so a MELP
claim is often the transplant rather than a drug in a regimen. The build already
treats a transplant this way - `SCT_TANDEM_DAYS` is 180, and a second AUTO
within 180 days is a planned tandem that does not end the line, while one beyond
180 days is excess and does.

The proposed rule is the same 180-day reasoning applied to the drug claim.
That matters where the transplant procedure code is absent - a transplant billed
elsewhere leaves the melphalan claim as the only evidence it happened.

`lot_followup_qs.R` already asks the question underneath this (D1: is
melphalan-in-2L really transplant conditioning). This rule is a proposed answer
to it.

## What the build does today

There is no melphalan-specific rule. MELP is an ordinary MM agent, and four
settings decide what happens to a repeat dose:

| setting | value | what it does here |
|---|---|---|
| `MEDICAL_DAY_SUPPLY` | 28 | a medical MELP claim covers `dose ... dose+27` |
| `INDUCTION_WINDOW_DAYS` | 60 | a drug first seen within this of the 1L start joins the regimen |
| `MAP_DISCON_GAP_DAYS` | 90 | gap after a MAP's cover ends that counts as discontinuation |
| `SCT_TANDEM_DAYS` | 180 | tandem window - transplants only, not drug claims |

Two consequences decide every branch below.

A repeat dose 28 or more days later is a separate MAP. A claim beyond the
current cover opens a new one (`03_mma_map.R`), and 28 days is the assumed
supply. The proposed rule's 30-day exposure threshold is close to this but not
the same number.

A repeat dose of a drug already in the regimen extends the line rather than
advancing it. `LOT1_BASE_DISCON_DT` is `max(MAP_END_DT)` across the base
agents with no upper bound on the date (`04_lot1_base.R:51-62`), so a second
MELP dose - at any distance - pushes the line's discontinuation date out past
itself. Because the next line's trigger has to fall strictly after the previous
line's end, that dose can then never start one.

## Proposed against current, branch by branch

| | first dose | next dose | proposed | today | |
|---|---|---|---|---|---|
| A.1 | inside induction | < 180 d | does not advance | does not advance - the dose extends `DISCON` | agrees |
| A.2 | inside induction | >= 180 d | advances at the later dose | does not advance - same extension, at any distance | differs |
| B.1 | outside induction | < 60 d | advances, starting at the first dose | advances, starting at the first dose | agrees, incidentally |
| B.2 | outside induction | 60-179 d | does not advance | advances at the first dose | differs |
| B.3 | outside induction | >= 180 d | later dose starts a line on its own date | advances at the first dose | differs |

B.1 agrees for a different reason. Today a MELP dose first seen outside the
induction window is an added medication, so it ends the current line the day
before itself and starts the next one on its own date - whatever the second dose
does, and whether or not there is one. The proposed rule reaches the same place
in B.1 only because it happens to advance there too.

## What it would change

The rule moves in both directions, so the net effect on line counts is not
derivable - it depends on how many patients sit in each branch.

- A.2 makes more lines. A late re-dose that is currently absorbed into the
  first line would start a new one.
- B.2 and B.3 make fewer lines. A melphalan add that currently advances the
  line would stop doing so, or would advance later and at a different date.

Every downstream figure follows from the line count and the line dates - lines
per patient, the share reaching 2L and 3L, line durations, TTNT, and the
attrition table. This is a change to the algorithm, not a correction to it, so
it belongs behind `LOT_CONTRACT_OVERRIDE` and its own sensitivity cell rather
than in the primary run.

## Sizing it without rebuilding

Branch counts can be read off a finished run. This does not give the resulting
line counts - that needs a build - but it says how many patients each branch
touches, which is the first thing worth knowing.

```sql
WITH l1 AS (
  SELECT PATID, LOT_START_DT AS LOT1_START_DT
  FROM <prefix>LOT_LONG_FINAL WHERE LOT_NUM = 1
),
doses AS (
  SELECT PATID, MAP_START_DT AS DOSE_DT
  FROM <prefix>MAP_STACKED
  WHERE upper(trim(MAP_MED_TYPE)) = 'MELP'
),
-- One administration per exposure: doses less than 30 days apart are the same.
gapped AS (
  SELECT PATID, DOSE_DT,
         datediff(DOSE_DT,
                  lag(DOSE_DT) OVER (PARTITION BY PATID ORDER BY DOSE_DT)) AS SINCE_PREV
  FROM doses
),
expo AS (
  SELECT PATID, DOSE_DT,
         row_number() OVER (PARTITION BY PATID ORDER BY DOSE_DT) AS N
  FROM gapped
  WHERE SINCE_PREV IS NULL OR SINCE_PREV >= 30
),
pair AS (
  SELECT e.PATID, l1.LOT1_START_DT,
         max(CASE WHEN e.N = 1 THEN e.DOSE_DT END) AS DOSE1,
         max(CASE WHEN e.N = 2 THEN e.DOSE_DT END) AS DOSE2
  FROM expo e INNER JOIN l1 ON l1.PATID = e.PATID
  GROUP BY e.PATID, l1.LOT1_START_DT
)
SELECT
  CASE WHEN datediff(DOSE1, LOT1_START_DT) <= 59
       THEN 'A inside induction' ELSE 'B outside induction' END        AS FIRST_DOSE,
  CASE WHEN DOSE2 IS NULL                   THEN 'no second exposure'
       WHEN datediff(DOSE2, DOSE1) <  60     THEN '< 60 days'
       WHEN datediff(DOSE2, DOSE1) < 180     THEN '60-179 days'
       ELSE '>= 180 days' END                                          AS SECOND_DOSE,
  count(*)                                                             AS N_PATIENTS
FROM pair
GROUP BY 1, 2
ORDER BY 1, 2;
```

The cells that matter are `A / >= 180 days` (lines gained) and
`B / 60-179 days` together with `B / >= 180 days` (lines lost). `59` rather than
`60` because the induction window is inclusive of its first day, as the build
applies it.

Worth reading beside it: how many of these patients have an AUTO transplant
recorded on or near the melphalan date. Where the procedure code is present the
transplant rule already handles the event, and applying the drug rule as well
would count one clinical event twice.

```sql
SELECT count(DISTINCT m.PATID) AS n_melp,
       count(DISTINCT CASE WHEN a.PATID IS NOT NULL THEN m.PATID END) AS n_with_auto_within_14d
FROM (SELECT DISTINCT PATID, MAP_START_DT FROM <prefix>MAP_STACKED
      WHERE upper(trim(MAP_MED_TYPE)) = 'MELP') m
LEFT JOIN <prefix>TX_AUTO_DATES a
       ON a.PATID = m.PATID AND abs(datediff(a.TX_DT, m.MAP_START_DT)) <= 14;
```

## What has to be settled before it can be built

The measurement program had to pick an answer to some of these to run at all.
Where it did, the assumption is named below. An assumption is not a decision -
these are still the study team's to settle, and changing one changes the counts.

1. Does the rule apply to melphalan alone, or to any agent used as transplant
   conditioning? As written it is drug-specific, which is a first for this
   algorithm - every other rule is about classes, windows and gaps.
   *The program assumes melphalan alone, and takes the abbreviation from
   `MELP_MED_ABBR` so a second agent is a setting rather than an edit.*

2. What happens when the transplant procedure code is also present? The AUTO
   rule and this rule would both fire on one clinical event. One of them has to
   yield, and which one is a clinical decision.
   *The program runs both readings - `MELP_RULE_MODE=as_asked` judges every
   exposure, `yield_to_sct` leaves a coded one to the transplant rule - and
   writes the mode onto every row. Neither is treated as the answer.*

3. Is 30 days the exposure threshold, or 28? The build's medical day supply
   is 28, so MAPs already merge on that boundary. Two thresholds one day apart
   would disagree on a dose at exactly 28 or 29 days.
   *The program uses 30, the number the request names, through
   `MELP_EXPOSURE_DAYS`.*

4. Third and later exposures. The rule is written for a first and a next dose.
   A patient with three or more needs a stated rule - the transplant side
   handles this explicitly (a tandem pair is allowed; a third transplant ends
   the line).
   *The program judges consecutive pairs, so a third exposure is judged against
   the second. That is the reading that generalises the two-dose rule without
   adding one, but it is a choice: judging every later dose against the first
   would give different branches.*

5. Does it apply at every line, or only at 1L? "The induction window" is 60
   days at 1L and 30 at 2L and later, so the branches land differently.
   *The program applies it at every line, using that line's own window. Anchoring
   everything to LOT1 would put later-line doses in the wrong branch.*

6. In B.2, does "both doses stay in the current line" mean the line has to be
   held open to the second dose? The two are not the same thing, and the build
   can only do the first without a further decision.

   A line's discontinuation date is its base agents' last cover. A melphalan
   first seen outside the induction window is not a base agent, so it does not
   extend that date. Take a line starting on day 0 whose base regimen runs out
   on day 120, with melphalan on day 100 and again on day 170 - a 70-day gap,
   so B.2. Not advancing at day 100 removes the boundary melphalan would have
   made. It does not keep the line alive past day 120: the regimen ran out
   there for reasons that have nothing to do with melphalan, and the day-170
   dose then starts the next line under the ordinary new-therapy rule.

   Two readings, and the difference is clinical:

   - The line ends when its regimen runs out, and B.2 only means melphalan does
     not end it early. This is what `aug1_melp` builds.
   - Melphalan belongs to that line for the whole pair, so it should join the
     regimen and carry the line to the second dose. That needs a drug to be a
     member of a line whose induction window it never entered, which is a
     concept the algorithm does not have today - so it is a change to what a
     regimen means, not a setting.

   `n_b2_line_starts` counts the lines this decides, and it is the B.2
   population rather than a proxy: the previous line ended by running out;
   melphalan started this line, which needs the start type to be `MED` as well
   as the exposure to be on the start date, since a transplant coded the same
   day takes the start; the exposure immediately before it sits in the previous
   line outside that line's own induction window; and the two are 60 to 179 days
   apart. Immediately before, because the engine judges consecutive pairs - any
   earlier exposure in range would count pairs it never looked at.

   `n_b2_melp_only` is the subset of those where no other non-steroid agent
   starts on the same date. That distinction matters because a `MED` start says
   a medication won the tie-break and not which one, so a line another agent
   would have started anyway is no evidence either way. Those are the lines that
   would not exist under the second reading.

Patient examples were offered with the request. Running them through the branch
table is the fastest way to confirm the reading.

The sizing query above is the quick version: it looks at the first two exposures
only and measures both against LOT1. `run_melphalan_rule.R` does the full thing -
consecutive pairs at every line, each against its own induction window - so the
two will not agree for a patient with three or more doses, or one whose
melphalan is in a later line.
