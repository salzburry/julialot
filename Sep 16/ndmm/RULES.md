# NDMM cohort rules

Newly diagnosed multiple myeloma, one row per patient, indexed at the first
eligible first-line treatment. This page is the short version: `README.md`
("The criteria as applied") has each rule as the code applies it, and
`DECISIONS.md` records why each reads the way it does and what is still open.

## Who gets in

Applied in this order, each step counted in the attrition table.

| # | Rule |
|---|---|
| 1 | A qualifying MM diagnosis: one inpatient claim, or two outpatient claims on different days within 90 days |
| 2 | Aged 18 or over, by calendar year, at the first qualifying diagnosis |
| 3 | An eligible first-line treatment on or after that diagnosis and on or after 2019-01-01. Its date is the index |
| 4 | 365 days of continuous enrolment before the index |
| 5 | Enrolled on the index date itself |
| 6 | No myeloma therapy in the 365 days before the index |
| 7 | No other cancer in those 365 days |
| 8 | No pregnancy or childbirth anywhere in the study period |
| 9 | No belantamab before the index |

The study period runs from 2018-01-01 to 2026-03-31. Enrolment gaps of 30 days
or fewer still count as continuous.

## What the rules assume

- **Eligible first-line treatment** is any agent on the MM therapy code list
  except steroids, belantamab, and the agents the study restricts to later
  lines - panobinostat and elotuzumab - which are barred by name through the
  `NDMM_INDEX_EXCLUDED_ABBRS` setting. A barred agent cannot set the index. The
  study package refuses a cohort that did not bar them. (`DECISIONS.md` 3)
- **Follow-up enrolment is one day**: enrolled on the index date. The 2L and 3L
  cohorts use 90 days. (`DECISIONS.md` 1)
- **Belantamab** is split: this cohort removes belantamab before the index, and
  the lines-of-therapy build removes belantamab from the index onward. So this
  cohort's count is not the study's final N. (`DECISIONS.md` 2)
- **Other cancer**: both claims of an outpatient pair must fall inside the
  365-day baseline. Claims pair on the ICD category, so one cancer coded two
  ways still confirms itself; metastatic codes pair with each other whatever
  the site. Bone metastasis codes exclude. Plasma-cell disorders, including
  those coded in remission or relapse, are the index disease and do not
  exclude. (`DECISIONS.md` 4)
- **Months are day counts**: twelve months is 365 days and three months is 90.
  (`DECISIONS.md` 7)
- **Death dates** are built from the month and year the data carries, usually
  the 15th of the month; day-level death timing is not available.
  (`DECISIONS.md` 8)
- **Pregnancy** is looked for over the whole study period, not only around the
  patient's own index. (`DECISIONS.md` 9)
- **Maintenance** is a descriptive flag; no maintenance period is built.
  (`DECISIONS.md` 10)
- **A claim whose ICD version is blank or unrecognised** matches no code list.
  The run reports how many it saw, and on which codes, and continues.
  (`DECISIONS.md` 11)
- **Clinical-trial participation** is reported beside the cohort but excludes
  nobody.

## What stops a run

The build refuses to publish a cohort it cannot vouch for: a missing or
unusable code list, a setting that would silently build a different cohort, a
name (belantamab, a barred agent, a plasma-cell label) that matches nothing on
the code list, or a result that contradicts itself. `README.md` ("What stops a
run") has the full list.

## The 2L and 3L cohorts

Built after the lines-of-therapy build, because their index dates are line
starts. The index is the start of that line.

| # | Rule |
|---|---|
| 1 | Received that line: 2L for the 2L cohort, 3L for the 3L |
| 2 | 365 days of continuous enrolment before the line's start, gaps of 30 days or fewer allowed |
| 3 | 90 days of enrolment from it with no gaps, or death within those 90 days |

- 2L is drawn from the 1L cohort and 3L from the 2L cohort, so a 3L patient
  also met the 2L windows. `N_EXCLUDED_BY_PRIOR` counts the patients this
  removes.
- The study end does not shorten the 90 days: a living patient whose window
  runs past the data has not shown the enrolment.
- The 1L cohort's follow-up rule is one day and these cohorts' is 90 days, so
  the cohorts are not comparable on that axis.
- A patient outside the 2L cohort still has a 2L line in the lines-of-therapy
  tables; these are cohorts, not flags on lines.
