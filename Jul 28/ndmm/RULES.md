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

## Also here

`build_subsequent_cohorts.R` builds the **2L and 3L** cohorts — the same
patients, restricted to those who reached that line with **365 days** of
enrolment before it and **90 days** after it. Run it after the lines exist.
