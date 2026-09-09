# The eligibility criteria, as this build applies them

`IE_CRITERIA.md` is the protocol: every rule quoted, with its section. This
document is the other half — which of those rules this build actually applies,
**where each one is applied**, and what to change to apply it differently.

Protocol: GSK **223926**, effective 26 August 2026. Sections §7.1, §7.2,
§7.2.1.1, §7.2.1.2 and §7.4.1.1.

---

## 1. Four cohorts, not one

| cohort | who | index date | earliest index |
|---|---|---|---|
| **1L (NDMM)** | patients initiating first-line therapy | start of the 1L regimen | `LOT1_INDEX_FROM` = 2019-01-01 |
| **2L** | the subset of 1L who initiate a second line | start of the 2L regimen | — |
| **3L** | the subset of 2L who initiate a third line | start of the 3L regimen | — |
| **Secondary 2L** | *all* patients initiating an assumed 2L, not only those in the 1L cohort | start of the 2L regimen | `SEC2L_INDEX_FROM` = 2020-01-01 |

2L and 3L are **nested**: a patient must be in the cohort above to be in them.
Secondary 2L is not nested — that is the whole point of it, and it is why it
needs its own input (see §5 below).

Select them with `COHORTS=1L,2L,3L,SEC2L`.

---

## 2. Who applies each criterion

This is the part that is easy to get wrong. **Most eligibility is applied
upstream, before this package runs.** The cohort table arrives with the verdict
already recorded as a flag, and this package reads it.

| criterion | rule | applied by |
|---|---|---|
| `I1_mm_dx` | multiple myeloma diagnosis | the cohort build |
| `I2_age` | age at index | the cohort build |
| `I3_eligible_1l_tx` | an eligible 1L therapy initiation | the cohort build |
| `I4_ce_pre` | continuous enrolment before index | the cohort build, **re-applied here** on the line's own index date |
| `I5_followup` | evidence of follow-up from index | **here** |
| `X1_prior_mm_tx` | no prior myeloma therapy | the cohort build (flag `NO_PRIOR_MM_TX`) |
| `X2_other_cancer` | no other cancer before 1L | the cohort build (flag `NO_OTHER_CANCER_PRE_LOT1`) |
| `X3_pregnancy` | no pregnancy | the cohort build (flag `NO_PREGNANCY`) |
| `X4_belantamab` | no belantamab before 1L | the **LOT engine** (flag `NO_BELANTAMAB_PRE_LOT1`) |
| `N1_received_line` | received the line this cohort indexes on | **here** |
| `N2_ce_pre` | continuous enrolment before *this line's* index | **here** |

`I4` and `N2` are the same rule on different dates, and that is deliberate: the
cohort build tested continuous enrolment before the **1L** index, and a 2L or
3L patient indexes later. Re-applying it here is what makes the 2L funnel show
that step's loss instead of carrying the count through untouched.

**A criterion whose evidence is not in the cohort or LOT tables stops the run.**
It is never silently skipped. If the input table does not carry
`NO_PREGNANCY`, the run says so and halts rather than reporting a funnel with
no pregnancy step in it.

### Where these live in the code

`R/modules/01_cohorts.R`:

- `CRITERION_SOURCE` — the table above, as data
- `CRITERION_FLAG` — which column on the input table carries each upstream verdict
- `HERE_PRED` — the predicate this package applies for the ones it owns
- `check_cohort_table()` — refuses an input with a duplicate patient id, a null
  patient id, or an eligibility flag that is null or not 0/1

`R/registry.R` holds `CRITERIA_1L` and each cohort's own criteria list.

---

## 3. The funnel

`S_ATTRITION` records one step per criterion, in the order they apply, per
cohort. Each row carries what remained and what that step removed.

`N_LOST` is **what that step removed, not what failed it**: a patient failing
two criteria is lost at the first one. The funnel therefore never gains
patients as it descends, and the suite asserts that.

A criterion the input applied upstream shows no loss here — which is the truth.
It was already applied; the step is in the funnel so the reader can see it was.

---

## 4. Making it flexible

Every eligibility decision this build makes is a setting, and each one names the
open question behind it. Nothing is hard-coded in a module.

### The dates

| setting | default | changes |
|---|---|---|
| `STUDY_START` | 2018-01-01 | the study window's start. The protocol body says 2018; its figures say 2016 — `OPEN_QUESTIONS.md` Q1. The run records which it used |
| `STUDY_END` | 2026-03-31 | the study window's end, and the CDM vintage it reads |
| `LOT1_INDEX_FROM` | 2019-01-01 | earliest 1L initiation that may index the 1L cohort |
| `SEC2L_INDEX_FROM` | 2020-01-01 | earliest 2L initiation for the secondary cohort |

### The windows

| setting | default | changes |
|---|---|---|
| `BASELINE_DAYS` | 365 | how far back the baseline period reaches |
| `BASELINE_INCLUDES_INDEX` | FALSE | whether the index date is in the baseline. §7.1 says no |
| `COMORBIDITY_BASELINE_INCLUDES_INDEX` | TRUE | §7.8.1 says yes, **for comorbidities only**. The two windows genuinely differ — Q14 |
| `CE_PRE_DAYS` | 365 | days of continuous enrolment required before index |
| `GAP_DAYS` | 30 | an enrolment gap this long or shorter is still continuous |
| `MONTHS_AS` | fixed | whether a "12-month" window is 365 days or 12 calendar months — Q21 |

### The criteria themselves

| setting | default | changes |
|---|---|---|
| `FU_EVIDENCE_RULE` | `claim_from_index` | what counts as evidence of follow-up. Three readings, and they are different criteria — Q5. `claim_from_index` excludes nobody, because the index claim is itself a claim on the index date |
| `PRIOR_TX_DROP_STEROIDS` | TRUE | whether steroid rows count as prior therapy — Q6 |
| `OTHER_CANCER_PAIR_DAYS` | 30 | how close two outpatient cancer claims must be to confirm each other |
| `OTHER_CANCER_PAIR_GRAIN` | `icd3` | what those two claims must share — the same 3-character ICD code, or the same tumour group |
| `OTHER_CANCER_BOTH_IN_BASELINE` | TRUE | whether both claims of a pair must fall inside the baseline |
| `PREGNANCY_WINDOW` | `study_period` | whether pregnancy is looked for over the study period or the patient's own — Q23 |
| `SEC2L_APPLY_OTHER_CANCER` | FALSE | the secondary 2L cohort permits prior malignancy — Q7 |
| `CENSOR_AT_DISENROLLMENT` | TRUE | whether follow-up ends at disenrolment or runs to death or study end — Q13 |
| `MAX_LOT` | 4 | the highest line this package describes |

Set any of them in the environment or in `config.csv`; the environment wins.

```bash
# a build with the 2016 study start and calendar-month windows
STUDY_START=2016-01-01 MONTHS_AS=calendar \
  INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=s223926_alt_ Rscript build.R
```

Write to a **different `OBJECT_PREFIX`** and the two runs sit side by side.
That is what the dashboard's Compare tab reads: two prefixes are two scenarios,
and it can show them against each other stratum by stratum.

### Changing which criteria apply at all

To add, drop or reorder a criterion, edit `R/registry.R`:

```r
CRITERIA_1L <- c("I1_mm_dx", "I2_age", "I3_eligible_1l_tx", "I4_ce_pre",
                 "I5_followup", "X1_prior_mm_tx", "X2_other_cancer",
                 "X3_pregnancy", "X4_belantamab")
```

and give the new criterion an entry in `CRITERION_SOURCE` saying where its
verdict comes from. A criterion in a cohort's list with no source stops the run
naming it. The funnel, the attrition table and the dashboard all follow from
that list — none of them needs a separate edit.

### What every run records

`S_RUN_METADATA` carries the reading the run took for **each** open question,
alongside the cohort attempt, the code-list hashes and the LOT run it read. So
a number can always be traced to the settings that produced it, and two runs
can be shown to differ only in what you meant them to differ in.

Where a setting was applied upstream, the run records the upstream value too,
and marks it verified or unverified. Where the two disagree, it records **both**
— the value that shaped the data and the value this run was set to.

---

## 5. Two things to know before changing anything

**The secondary 2L cohort needs its own input.** It is not nested in the 1L
cohort, so it cannot be built from a cohort table that already applied the 1L
index floor and the other-cancer exclusion — the result would be nested by
construction, and its baseline malignancy prevalence would be zero because the
exclusion had already removed those patients. Selecting `SEC2L` without
`SEC2L_INPUT_IS_WIDE=TRUE` stops the run and says this.

**Eligibility applied upstream cannot be undone here.** If the cohort table
arrives with a patient already removed, no setting in this package brings them
back. Changing `X1` through `X3` means rebuilding the cohort table; changing
`X4` means rebuilding the LOT run. The settings above change what this package
applies and what it reports — they do not reach backwards.

---

## 6. What is not settled

`OPEN_QUESTIONS.md` holds every question still with the study team. The ones
that change eligibility are Q1 (study start), Q5 (follow-up evidence),
Q6 (steroids as prior therapy), Q7 (prior malignancy in the secondary cohort),
Q13 (disenrolment as censoring), Q14 (index date in the baseline) and
Q21 (calendar months).

Each has a default above, each default is recorded in the run's metadata, and
each can be changed with one setting. None of them is a code change.
