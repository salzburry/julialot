# NDMM cohort — the rules, in short

Newly diagnosed multiple myeloma. One patient per row, indexed at their first
eligible first-line treatment. `DECISIONS.md` has the reasoning; this is the
list.

## Who gets in

Applied in order. Each step is counted in the attrition table.

| # | Rule |
|---|---|
| 1 | A qualifying MM diagnosis — 1 inpatient claim, or 2 outpatient claims within **90 days** |
| 2 | Aged **18+** at that diagnosis |
| 3 | An eligible 1L treatment on or after **2017-01-01** |
| 4 | **365 days** of continuous enrolment before the 1L index date |
| 5 | Enrolled on the index date itself |
| 6 | No MM oncology therapy in those 365 days |
| 7 | No other cancer in those 365 days |
| 8 | No pregnancy or childbirth anywhere in the study period |
| 9 | No belantamab before the 1L index |

Study period **2016-01-01 to 2026-03-31**. Enrolment gaps of **30 days or
fewer** still count as continuous.

## Assumptions worth knowing

**Follow-up enrolment is one day, not three months.** The protocol says three;
the study team confirmed one day for this cohort. Other cohorts in this study
use 90. `fu_ce_days = 0` means the index date itself.

**Two claims, both inside baseline.** For "other cancer", both claims of a
confirming pair must fall in the 365-day baseline — not just the first.

**Other cancers pair on the ICD category**, not the exact code, so two claims
for the same cancer written slightly differently still count as one cancer.
Bone metastasis excludes; metastatic codes group together. Plasma-cell
disorders in remission stay excluded.

**Months are day counts.** "12 months" is 365 days, "3 months" is 90. No
calendar arithmetic.

**Death dates are constructed** from the month and year the CDM carries, not
read as a date. Day-level death timing is not available.

**Maintenance is a flag, not a line.** No maintenance period is built.

**A diagnosis code naming neither ICD family is reported, not dropped** — the
run records how many and carries on.

## What stops a run

The cohort refuses to publish rather than publish something unproven: an
unreadable code list, a code list with no usable codes, a code type nothing
reads, a setting that is not a whole number, or a run that cannot say which
attempt of the cohort it built.

## The 2L and 3L cohorts

`build_subsequent_cohorts.R`, run **after** the lines exist — the index dates
are line starts, so only the LOT build knows them. Writes
`NDMM_COHORT_2L`, `NDMM_COHORT_3L` and `NDMM_SUBSEQUENT_ATTRITION`.

Three rules, and no others. Index date is the start of that line.

| # | Rule |
|---|---|
| 1 | Received that line — 2L for the 2L cohort, 3L for the 3L |
| 2 | **365 days** of continuous enrolment before the line's start |
| 3 | **90 days** of enrolment after it with **no gaps**, or death |

**Each cohort is drawn from the one before it** — 2L from the 1L cohort, 3L
from the 2L cohort. Receiving the lines in order is guaranteed anyway, since a
LOT 3 row implies a LOT 2 row; what chaining adds is that the earlier cohort's
enrolment windows had to be met too. A patient can fail the follow-up window
after 2L and still be fully enrolled around 3L. `N_EXCLUDED_BY_PRIOR` counts
them.

### Assumptions worth knowing

**Death is the only alternative to the follow-up window.** Not the study end —
a living patient whose 90 days run past the data has not shown the enrolment.
The window is truncated at death and at nothing else.

**Gaps of 30 days or fewer are still continuous** before the line. The 90 days
after it allow **no gap at all**.

**The follow-up window is 90 days here, and one day for the 1L cohort.** They
are different rules on purpose, so the two are not comparable on that axis.

**These are cohorts, not flags.** A patient outside the 2L cohort still has a
2L line in the LOT tables; they are excluded from `LINE_ELIGIBLE` denominators,
not from the lines.

**The windows are pinned.** Changing either is a different cohort under the
same table names, so it needs `NDMM_SUBSEQ_OVERRIDE=TRUE` and is recorded.

**Outcomes refuses to read them unless the build says it finished** — the three
tables are replaced one at a time, so a run that stopped part-way leaves some
of them this attempt's and the rest the previous one's.
