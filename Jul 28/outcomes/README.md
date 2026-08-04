# Outcomes — treatment patterns and treatment-related outcomes

Protocol Secondary Objective 1, Table 4. Reads one finished LOT run and writes
five tables.

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
| `<prefix>OUT_ATTRITION` | line — the attrition categories, which partition it |
| `<prefix>OUT_LINE_GAP` | line pair — months from one line's start to the next |
| `<prefix>OUT_REGIMEN` | line and regimen — N and % receiving each |
| `<prefix>OUT_DX_TO_LOT1` | one row — months from MM diagnosis to the 1L index |

All of them carry `OUT_RUN_ID`, `LOT_RUN_ID` and `BUILT_AT`, so a run that dies
part-way leaves a mismatch rather than a silent mix. The tables are written
sequentially with `CREATE OR REPLACE`, so a run id on each one is what tells
this run's `OUT_TTE` from the last run's summaries beside it. The run **asks the
tables** at the end rather than logging that they are stamped, and stops if any
row carries a different outcomes run or a different LOT run.

`OUT_DX_TO_LOT1` is the only optional output, and an optional output is the one
that can be left behind — so a run with no readable base cohort **drops** it
rather than leaving an earlier run's copy beside four newer tables.

`LOT_RUN_ID` is a different question from `OUT_RUN_ID`: which LOT run supplied
the lines, not which outcomes run wrote the table.

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

**An event *after* the follow-up end is not an event** — the patient ran out of
observation rather than reaching the outcome, so it censors. An event **on** the
follow-up end is one. Death is the case that matters: the cohort clamps
`ENDDATE` at the death date, so for anyone who dies inside the study window the
death *is* the follow-up end — so a strict boundary can never fire on a death,
and leaves `OS_EVENT` at 0 for everyone: an OS curve with no events on it.
`TTNT_REASON` records which of `NEXT_LOT`, `DEATH` or `CENSORED` ended each row.

`TTD` is the one exception. A line whose own end is the run-out did not end —
the observation did — so a line carrying `LOT_END_REASON = 'STUDY_END'` censors
at that date rather than counting as a discontinuation.

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
died"*. Both are reported — `N_` and `PCT_` per category, over the line's own N.

Exclusive and ordered, because a patient can look like more than one: someone
who starts a next line and later dies is counted as receiving the next line,
since that is what the row is about. Every other category is conditioned on
there being no next line.

**"Received the next LOT" means observed to receive it.** lot's primary analysis
ignores disenrolment, so `LOT_LONG_FINAL` carries lines that start after a
patient's protocol follow-up has ended. Those are censored by `TTNT` and are not
progressions here: the categories key on `TTNT_EVENT = 1 AND TTNT_REASON =
'NEXT_LOT'`, not on `NEXT_LOT_NUM` being populated. Keying on the column would
credit the study with progressions nobody observed, and — because every other
category requires no next line — would leave those patients in no category at
all. `OUT_LINE_GAP` filters the same way, for the same reason.

**Table 4 names four, and they are not exhaustive.** A patient still on
treatment when the data runs out has *not* been lost to follow-up — they were
observed to the end of the study period and were still being treated. Folding
them into "lost to follow-up" would overstate loss and hide the ongoing group
entirely, so `N_ONGOING` is counted separately and the five sum to `N_ON_LINE`.
The two are told apart by whether observation stopped before the study did:

| | no next line, no death, line never ended inside follow-up |
|---|---|
| `N_LOST_TO_FU` | follow-up ended **before** the study end — they disenrolled |
| `N_ONGOING` | follow-up ran **to** the study end — the study stopped, not them |

## What it does not do

**Regimens are raw, not SOC categories.** Table 4 asks for regimen categories
per Section 6.2.2, which is Annex 2. That is not applied here, so `OUT_REGIMEN`
is the raw distribution a category map would be built against.

## The MM diagnosis date

`NDMM_COHORT` does **not** carry it. That table's `INDEX_DATE` is the **1L
treatment start**, and all ten of its columns are anchored there — age at
index, both follow-up lengths, where continuous enrolment ends.

The diagnosis date lives on `<prefix>NDMM_BASE_COHORT`, which the cohort build
already checkpoints, so nothing has to be rebuilt to get it. It is probed, not
assumed: if that table is not readable — a cohort built by another package has
no MM diagnosis date to offer — `MM_DX_DT` and `DX_TO_LOT1_DAYS` are NULL, the
`OUT_DX_TO_LOT1` table is dropped rather than written, and every other outcome
is unaffected. The join is a LEFT join for the same reason.

`COHORT_PREFIX` points at the cohort build's prefix when it differs from this
run's. One study is one prefix, so it defaults to the run's own.

`OUT_DX_TO_LOT1` counts `N_NEGATIVE` — a 1L start before the diagnosis. The
cohort build takes the first therapy claim *on or after* the diagnosis, so that
count is zero unless that rule has broken.

## Settings

`config.csv`, environment wins. Nothing here defines a clinical rule: the lines
are lot's and the population is the cohort's, so every setting is about which
run to read.

## What stops it

The same run-ownership rule every reader in this folder uses. The newest
`LOT_BUILD_STATUS` row has to be `complete`, built from the cohort named on the
command line, carry no `CONTRACT_DEVIATIONS`, and name the **same `STUDY_END`**
this package is set to, and its `LOT_RUN_METADATA` row has to name the cohort
attempt that is on disk now. None of it is waivable — this package does arithmetic on
a finished run, and if the run cannot be identified there is no reading of these
numbers worth having.

The study end is checked because the attrition split turns on it, and this
package holds its own copy. The two cohort builds in this folder disagree by
construction — `nndm` pins `2026-03-31`, `overall` uses `2025-06-30` — so an
unchecked copy running long would score every still-treated patient as lost to
follow-up, with the five categories still summing correctly and nothing logged.

**The cohort attempt is checked too, not just the cohort name.** Re-running the
cohort build under the same prefix replaces the cohort, the enrolment spans and
`NDMM_BASE_COHORT` in place — the table name is unchanged. So the run's
`LOT_RUN_METADATA` row is read by `RUN_ID` and its `COHORT_RUN_ID` /
`COHORT_STAMP` compared against the current `NDMM_BUILD_STATUS`. Without it,
lines built over attempt A would be measured against follow-up ends, death dates
and diagnosis dates from attempt B. This is the same guard, for the same reason,
as the one in `nndm/build_subsequent_cohorts.R`. Where nothing was recorded to
compare, that is said on the log rather than assumed to match.

A line can be absent from `OUT_TTE` for two reasons, and they are counted
separately: its patient is not in the cohort at all, or the line starts after
that patient's follow-up ends. A single "n dropped" would let the first hide
behind the second — and the first should be impossible, since lot builds its
lines from this cohort.

## Tests

```
Rscript tests/test_runner.R
```

No connection needed. The SQL is built as a string and checked, and the
censoring arithmetic is evaluated in R over hand-made cases — a next line
inside follow-up, a death with no next line, neither, and a next line after
follow-up ends.
