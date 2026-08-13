# NDMM cohort rules

Newly diagnosed multiple myeloma, one row per patient, indexed at the first
eligible first-line treatment. `DECISIONS.md` records why each rule reads the
way it does.

## Who gets in

The criteria are applied in this order and each step is counted in the
attrition table.

| # | Rule |
|---|---|
| 1 | A qualifying MM diagnosis: one inpatient claim, or two outpatient claims within 90 days |
| 2 | Aged 18 or over at that diagnosis |
| 3 | An eligible first-line treatment on or after 2017-01-01 |
| 4 | 365 days of continuous enrolment before the 1L index date |
| 5 | Enrolled on the index date itself |
| 6 | No myeloma therapy during those 365 days |
| 7 | No other cancer during those 365 days |
| 8 | No pregnancy or childbirth anywhere in the study period |
| 9 | No belantamab before the 1L index |

The study period runs from 2016-01-01 to 2026-03-31. Enrolment gaps of 30 days
or fewer still count as continuous.

## Assumptions

Follow-up enrolment is one day. `fu_ce_days = 0` means the index date itself.
The subsequent-line cohorts use 90 days.

For the other-cancer exclusion, both claims of a confirming pair must fall
inside the 365-day baseline, not only the first.

Other cancers are paired on the ICD category rather than the exact code, so two
claims for the same cancer written slightly differently still count once. Bone
metastasis excludes. Metastatic codes group together. Plasma-cell disorders in
remission remain excluded.

Months are day counts. Twelve months is 365 days and three months is 90. There
is no calendar arithmetic anywhere in the build.

Death dates are constructed from the month and year the CDM carries. Day-level
death timing is not available.

Maintenance is a descriptive flag. No maintenance period is built.

A diagnosis code naming neither ICD family is reported rather than dropped. The
run records how many it saw and continues.

## What stops a run

The build refuses to publish rather than publish something it cannot vouch for:
a code list that cannot be read, a code list with no usable codes, a code type
no claim source produces, a setting that is not a whole number, or a run that
cannot say which attempt of the cohort it was built over.

## The 2L and 3L cohorts

Built by `build_subsequent_cohorts.R`, which runs after the LOT build because
the index dates are line starts and only that build knows them. It writes
`NDMM_COHORT_2L`, `NDMM_COHORT_3L` and `NDMM_SUBSEQUENT_ATTRITION`.

Three criteria, and no others. The index date is the start of that line.

| # | Rule |
|---|---|
| 1 | Received that line: 2L for the 2L cohort, 3L for the 3L |
| 2 | 365 days of continuous enrolment before the line's start |
| 3 | 90 days of enrolment after it with no gaps, or death |

Each cohort is drawn from the one before it, 2L from the 1L cohort and 3L from
the 2L cohort. Receiving the lines in order is guaranteed anyway, since a LOT 3
row implies a LOT 2 row. What the chaining adds is that the earlier cohort's
enrolment windows had to be met as well: a patient can fail the follow-up
window after 2L and still be fully enrolled around 3L. `N_EXCLUDED_BY_PRIOR`
counts those patients.

### Assumptions

Death is the only alternative to the follow-up window. The study end is not. A
living patient whose 90 days run past the end of the data has not demonstrated
the enrolment, so the window is truncated at death and at nothing else.

Gaps of 30 days or fewer remain continuous for the 365 days before the line.
The 90 days after it allow no gap at all. Both windows are tested against a
single span, so a gap the span builder did not collapse will exclude the
patient.

Death dates are always coarsened. The source carries year and month only, so
every death is placed on the 15th of its month, or on the month's last day
where the 15th would fall before the diagnosis. Treatment in the second half of
that month therefore falls after the recorded death date, and observation has
already ended: `ENDDATE = least(study_end, DEATH_DT)`. A fill on the 20th of a
month whose death is recorded as the 15th is not observed at all, so it cannot
open a line and cannot be one of these cohorts' index dates.

The follow-up window is 90 days here and one day for the 1L cohort, so the two
cohorts are not comparable on that axis.

These are cohorts rather than flags. A patient outside the 2L cohort still has
a 2L line in the LOT tables; they are excluded from `LINE_ELIGIBLE`
denominators, not from the lines themselves.

Both windows are pinned. Changing either produces a different cohort under the
same table names, so it requires `NDMM_SUBSEQ_OVERRIDE=TRUE` and is recorded on
the run.

Outcomes will not read these tables unless the build recorded that it finished.
The three outputs are replaced one at a time, so a run that stopped part-way
leaves some of them from this attempt and the rest from the one before.
