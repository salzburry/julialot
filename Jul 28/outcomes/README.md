# Outcomes — treatment patterns and treatment-related outcomes

Protocol Secondary Objective 1, Table 4. Reads one finished LOT run and writes
four tables.

```
DATABRICKS_PWD=... Rscript build.R <COHORT_TABLE> <lot_prefix_>
DATABRICKS_PWD=... Rscript build.R ndmm_NDMM_COHORT ndmm_
```

Reads only. It writes no cohort table and no LOT table, so it can be re-run
against a finished run as often as needed.

## What it writes

| table | one row per |
|---|---|
| `<prefix>OUT_TTE` | patient per line — the three time-to-event outcomes |
| `<prefix>OUT_ATTRITION` | line — Table 4's four attrition categories |
| `<prefix>OUT_LINE_GAP` | line pair — months from one line's start to the next |
| `<prefix>OUT_REGIMEN` | line and regimen — N and % receiving each |

All four carry `OUT_RUN_ID` and `BUILT_AT`, so a run that dies part-way leaves
a mismatch rather than a silent mix.

## The three outcomes

Each is a **date and a 0/1**, not a summary. A median with no event flag beside
it cannot be recomputed or checked, and the curves are the study team's to fit.

| | ends at | censored at |
|---|---|---|
| `TTNT` | next LOT start, or death | follow-up end |
| `TTD` | end of current LOT, next LOT start, or death — earliest | follow-up end |
| `OS` | death | follow-up end |

The index day does not count and the event day does — the protocol's "start
date (excluded) … (included)" — which is a plain date difference.

**An event at or after the follow-up end is not an event.** The patient ran out
of observation rather than reaching the outcome, so it censors. That is written
once so all three treat the boundary the same way, and `TTNT_REASON` records
which of `NEXT_LOT`, `DEATH` or `CENSORED` ended each row.

### Follow-up end

Protocol 6.1: *"from the index date (i.e., excluding index) until the end of
continuous enrollment or end of study period or death, whichever occurs
first."*

The cohort carries both halves — `ENDDATE` is min(death, study end) and
`ENDDATE_CE` is where continuous enrolment stops — so the follow-up end is the
earlier of the two. `ENDDATE_CE` is NULL for a patient who never disenrolled,
and a NULL inside `least()` swallows the whole expression, so it is coalesced
rather than compared raw.

This is **not** the LOT run's observation window. LOT's primary analysis
ignores disenrolment (`OBS_END_DT = ENDDATE`); the protocol's follow-up period
does not. The two are different questions and the difference is deliberate.

### The next line

`lead()` over the patient's ordered lines, not `LOT_NUM + 1`. A gap in the
numbering would otherwise read as "no next line" and censor a patient who
plainly had one.

## Attrition

Table 4: *"Number and percent of patients who received each subsequent LOT,
discontinued treatment and did not receive another, were lost to follow-up, or
died"*. The four are **exclusive and ordered**, because a patient can look like
more than one: someone who starts a next line and later dies is counted as
receiving the next line, since that is what the row is about. The other three
are each conditioned on there being no next line.

## What it does not do

**Regimens are raw, not SOC categories.** Table 4 asks for regimen categories
per Section 6.2.2, which is Annex 2. That is not applied here, so `OUT_REGIMEN`
is the raw distribution a category map would be built against.

**Time from diagnosis to 1L is not computed.** It needs the MM diagnosis date,
which `NDMM_COHORT` does not carry — the cohort's ten columns are anchored on
the 1L index.

## Settings

`config.csv`, environment wins. Nothing here defines a clinical rule: the lines
are lot's and the population is the cohort's, so every setting is about which
run to read.

## What stops it

The same run-ownership rule every reader in this folder uses. The newest
`LOT_BUILD_STATUS` row has to be `complete`, built from the cohort named on the
command line, and carry no `CONTRACT_DEVIATIONS`. None of it is waivable — this
package does arithmetic on a finished run, and if the run cannot be identified
there is no reading of these numbers worth having.

A line starting after its patient's follow-up ends is excluded and the count
reported, so "none were excluded" is evidence rather than silence.

## Tests

```
Rscript tests/test_runner.R
```

No connection needed. The SQL is built as a string and checked, and the
censoring arithmetic is evaluated in R over hand-made cases — a next line
inside follow-up, a death with no next line, neither, and a next line after
follow-up ends.
