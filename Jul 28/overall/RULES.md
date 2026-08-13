# Overall cohort — the rules, in short

The broad myeloma cohort: everyone treated for MM in the window, without the
newly-diagnosed restrictions. Writes `OVERALL_COH_FINAL`.

It exists because two of the study team's questions are about patients the
NDMM cohort excludes.

## Who gets in

| # | Rule | On? |
|---|---|---|
| 1 | A qualifying MM diagnosis — 1 inpatient claim, or 2 outpatient within **90 days** | always |
| 2 | Aged **18+** at index | yes |
| 3 | **183 days** of baseline enrolment before index | yes |
| 4 | Enrolled on the index date (1+ day follow-up) | yes |
| 5 | No MM agent in baseline | yes |
| 6 | At least one MM agent in follow-up | yes |
| 7 | No MM diagnosis in baseline | **off** |
| 8 | No other cancer | **off** |
| 9 | No pregnancy | **off** |
| 10 | No clinical trial | **off** |

Index date is the **earliest** qualifying diagnosis in the identification
period. Inpatient claims must carry a strict MM code (`203.0x` / `C90.0x`);
outpatient pairs use the broader list.

Study period **2015-07-01 to 2025-06-30**; identification period
**2016-01-01 to 2025-06-30**. Enrolment gaps of **30 days or fewer** still
count as continuous.

## Assumptions worth knowing

**Steps 7–10 are computed but not applied.** Every flag is written to
`ELIG_COH_ALLFLAGS`, so the cost of each is visible — but none of them removes
a patient from `OVERALL_COH_FINAL`. That is what makes this cohort "overall".
Turning one on changes who is in the cohort, so it is a config change made
deliberately, not a default.

**Baseline is 183 days, not 365.** Half a year, against NDMM's full year. The
two cohorts are not built to the same baseline and their counts are not
comparable on that axis.

**No belantamab rule here.** That exclusion belongs to NDMM and to the lines
build; this cohort does not apply it.

**Index is the earliest qualifying diagnosis**, not the first treatment. NDMM
indexes on treatment. Same patient, different index date, in most cases.

## What stops a run

A setting that disagrees with the pinned contract, a missing or unreadable code
list, or an output table name that is not the one this build is meant to write.
