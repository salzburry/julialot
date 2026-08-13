# Overall cohort rules

The broad myeloma cohort: everyone treated for myeloma in the window, without
the newly-diagnosed restrictions. It writes `OVERALL_COH_FINAL`.

It exists because two of the study team's questions concern patients the NDMM
cohort excludes.

## Who gets in

| # | Rule | Applied |
|---|---|---|
| 1 | A qualifying MM diagnosis: one inpatient claim, or two outpatient within 90 days | always |
| 2 | Aged 18 or over at index | yes |
| 3 | 183 days of baseline enrolment before index | yes |
| 4 | Enrolled on the index date | yes |
| 5 | No myeloma agent during baseline | yes |
| 6 | At least one myeloma agent during follow-up | yes |
| 7 | No MM diagnosis during baseline | no |
| 8 | No other cancer | no |
| 9 | No pregnancy | no |
| 10 | No clinical trial | no |

The index date is the earliest qualifying diagnosis in the identification
period. Inpatient claims must carry a strict MM code (`203.0x` or `C90.0x`);
outpatient pairs use the broader list.

The study period runs from 2015-07-01 to 2025-06-30 and the identification
period from 2016-01-01 to 2025-06-30. Enrolment gaps of 30 days or fewer still
count as continuous.

## Assumptions

Criteria 7 to 10 are computed but not applied. Every flag is written to
`ELIG_COH_ALLFLAGS`, so the cost of each is visible, but none of them removes a
patient from `OVERALL_COH_FINAL`. That is what makes the cohort an overall one.
Turning any of them on changes who is in the cohort, so it is a deliberate
config change rather than a default.

Baseline here is 183 days against NDMM's 365. The two cohorts are not built to
the same baseline and their counts are not comparable on that axis.

The belantamab exclusion is not applied here. It belongs to the NDMM cohort and
to the lines build.

The index is the earliest qualifying diagnosis, where NDMM indexes on the first
treatment. For most patients that is the same person with a different index
date.

## What stops a run

A setting that disagrees with the pinned contract. A code list that is missing
or cannot be read. An output table name that is not the one this build is meant
to write.
