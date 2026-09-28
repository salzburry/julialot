# The eligibility criteria, as this build applies them

`IE_CRITERIA.md` is the protocol: every rule quoted, with its section, and how
each is operationalised. This document is the other half — **who applies each
one**, the attrition funnel, and what to change to apply a date, a window or a
criterion differently.

---

## 1. The cohorts

The four cohorts and their index dates are `IE_CRITERIA.md` §1. The settings
that select and shape them:

| setting | default | what it does |
|---|---|---|
| `COHORTS` | `1L,2L,3L` | which cohorts to build — any of `1L`, `2L`, `3L`, `SEC2L`. 2L is nested in 1L and 3L in 2L, so selecting one brings its parent |
| `LOT1_INDEX_FROM` | 2019-01-01 | earliest 1L initiation that may index the 1L cohort |
| `SEC2L_INDEX_FROM` | 2020-01-01 | earliest 2L initiation for the secondary cohort |
| `COHORT_NESTED` | `TRUE` | whether 2L and 3L require membership of the cohort above — §7.2.1 read literally. `FALSE` lets each line stand on its own index; the run records which |

The secondary 2L cohort is not nested, which is why it needs its own input
(§5 below).

---

## 2. Who applies each criterion

**Most eligibility is applied upstream, before this package runs.** The cohort
table arrives with the verdict already recorded as a flag, and this package
reads it.

| criterion | rule | applied by |
|---|---|---|
| `I1_mm_dx` | multiple myeloma diagnosis | the cohort build |
| `I2_age` | ≥ 18 in the diagnosis calendar year | the cohort build |
| `I3_eligible_1l_tx` | an eligible 1L therapy initiation | the cohort build — and this package **checks** that the build barred the agents §7.2.1.1 names (`COHORT_INDEX_EXCLUSIONS`, default panobinostat and elotuzumab) from setting the index, from the build's recorded `INDEX_EXCLUDED`, and stops if it did not |
| `I4_ce_pre` | continuous enrolment before index | the cohort build, **re-applied here** on the line's own index date |
| `I5_followup` | evidence of follow-up from index | **here** |
| `X1_prior_mm_tx` | no prior myeloma therapy | the cohort build (flag `NO_PRIOR_MM_TX`) |
| `X2_other_cancer` | no other cancer before 1L | the cohort build (flag `NO_OTHER_CANCER_PRE_LOT1`) |
| `X3_pregnancy` | no pregnancy | the cohort build (flag `NO_PREGNANCY`) |
| `X4_belantamab` | no belantamab before 1L | the cohort build (flag `NO_BELANTAMAB_PRE_LOT1`) |
| `N1_received_line` | received the line this cohort indexes on | **here** |
| `N2_ce_pre` | continuous enrolment before *this line's* index | **here** |

`I4` and `N2` are the same rule on different dates, and that is deliberate: the
cohort build tested continuous enrolment before the **1L** index, and a 2L or
3L patient indexes later. Re-applying it here is what makes the 2L funnel show
that step's loss instead of carrying the count through untouched.

The LOT engine has a belantamab rule of its own — a patient with belantamab
in **any** line is removed after the lines are built — and it is a different
criterion from `X4`. Rebuilding the LOT run does not recreate the cohort flag.

The input cohort table comes in two shapes — **pre-filtered**, with `X1`–`X4`
already applied and no flags needed, or **wide**, keeping the patients who fail
an exclusion and carrying each verdict as a flag. What each shape means and
what `check_cohort_table()` refuses is `MODULES.md`, "The input cohort table".
A criterion in a cohort's list that `CRITERION_SOURCE` does not know stops the
run.

### Where these live in the code

`R/modules/01_cohorts.R`:

- `CRITERION_SOURCE` — the table above, as data
- `CRITERION_FLAG` — which column on the input table carries each upstream verdict
- `HERE_PRED` — the predicate this package applies for the ones it owns
- `check_cohort_table()` — the input checks

`R/registry.R` holds `CRITERIA_1L` and each cohort's own criteria list.

---

## 3. The funnel

The order of the criteria is `IE_CRITERIA.md` §8. Its steps 0-8, bar I5, and
X4's pre-index half are the **cohort build's** funnel, which writes its own
attrition (`../ndmm/README.md`, "The attrition"). `S_ATTRITION` is this
package's, one step per criterion, per cohort, and it begins where the cohort
build's ends — so its first rows say what stood between the two.

| criterion | applied by | what it counts |
|---|---|---|
| `indexed_at_line` | `lot` | patients on the input with a line at this line number, from `LOT_LONG_ALLFLAGS` — every line the engine built, before its own criteria |
| `lot_line_criteria` | `lot` | the same patients after them. The difference is the engine's removals, of which belantamab in any LOT is one |
| each of the cohort's own | `cohort`, `here`, or both | the table in §2 |

**X4 is two criteria, not one.** `NO_BELANTAMAB_PRE_LOT1` is the cohort build's,
computed before any line exists, and it is the `X4_belantamab` step. The engine's
is "in any LOT", it truncates — a patient with belantamab anywhere loses every
line — and it is `lot_line_criteria`. They remove different patients and the
funnel reports them separately.

**A nested cohort starts from its parent, not from the engine's lines.** 2L and
3L get one opening row instead — `in_1L_cohort`, `in_2L_cohort` — the cohort they
are drawn from, so `N1_received_line`'s loss is the patients who did not go on to
that line. Everything the engine removed is already inside the parent's own
funnel. Under `COHORT_NESTED=FALSE` each line stands on its own index and is
nobody's subset, so it opens on the engine's lines like any other root.

Each row carries what remained and what that step removed. `N_LOST` is **what
that step removed, not what failed it**: a patient failing two criteria is lost
at the first one, so the funnel never gains patients as it descends. A
criterion the input applied upstream shows no loss here — it was already
applied; the step is in the funnel so the reader can see it was.

---

## 4. Changing dates, windows and criteria

Every eligibility decision this package makes is a setting, and each open
reading names the question behind it. Set any of them in the environment or in
`config.csv`; the environment wins.

### The dates

| setting | default | changes |
|---|---|---|
| `STUDY_START` | 2018-01-01 | the study window's start (Q1, answered) |
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
| `MONTHS_AS` | `days` | `days` or `calendar`: whether a "12-month" window is 365 days or 12 calendar months — Q21 |
| `TTE_MIN_POTENTIAL_FU_DAYS` | 90 | potential follow-up needed to enter the time-to-event analysis set |

### The criteria themselves

| setting | default | changes |
|---|---|---|
| `FU_EVIDENCE_RULE` | `claim_from_index` | what counts as evidence of follow-up: `claim_from_index`, `claim_after_index` or `enrolled_on_index` — `IE_CRITERIA.md` §4, I5, and Q5. The default excludes nobody |
| `SEC2L_APPLY_OTHER_CANCER` | FALSE | the secondary 2L cohort permits prior malignancy — Q7 |
| `SEC2L_INPUT_IS_WIDE` | FALSE | asserts the input was built without the other-cancer exclusion and the 1L floor — §5 |
| `CENSOR_AT_DISENROLLMENT` | TRUE | whether follow-up ends at disenrolment or runs to death or study end — Q13 |
| `COHORT_INDEX_EXCLUSIONS` | `panobinostat,elotuzumab` | the agents the cohort build must have barred from setting the 1L index; `none` checks nothing |
| `MAX_LOT` | 4 | the highest line this package describes |

Seven more are the cohort build's rules and are **recorded, not applied**,
here: `MM_DX_OUTPATIENT_CODES` (Q2), `MM_DX_OUTPATIENT_WINDOW_DAYS` (Q3),
`PRIOR_TX_DROP_STEROIDS` (Q6), `OTHER_CANCER_PAIR_DAYS`,
`OTHER_CANCER_PAIR_GRAIN`, `OTHER_CANCER_BOTH_IN_BASELINE` and
`PREGNANCY_WINDOW` (Q23). Changing one here does not change the cohort; where
the cohort build's recorded value can be read, the run records both and the
disagreement — §5.

### What stops a changed run

- **The contract.** The numbers the protocol states outright are pinned in
  `CONTRACT` (`R/config_223926.R`): `BASELINE_DAYS`, `CE_PRE_DAYS`, `GAP_DAYS`,
  `LOT_POST_DISCON_DAYS`, `ACUTE_WASHOUT_DAYS`, `TTE_MIN_POTENTIAL_FU_DAYS`,
  `SUPPRESS_MIN_N`, `LOT1_INDEX_FROM`, `SEC2L_INDEX_FROM` and `STUDY_END`.
  Changing one stops the run unless `SETTINGS_OVERRIDE=TRUE` is set as well,
  and the run is then stamped as a deviation in its metadata so no reader
  mistakes it for the study's numbers.
- **The cohort it reads.** `STUDY_START`, `STUDY_END` and `LOT1_INDEX_FROM` are
  held to the values the cohort build recorded (`BINDING_UPSTREAM_SETTINGS`,
  `read_upstream_settings()`). A disagreement stops the run unless
  `SETTINGS_OVERRIDE=TRUE`, which records it as a deviation. Moving the study
  window therefore means moving it on both sides: rebuild the cohort and the
  LOT run under the new window (`../ndmm/README.md`, "Settings"), then run this
  package against them.

The open-question readings change freely.

```bash
# a sensitivity on an open reading - no override needed
MONTHS_AS=calendar INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  OBJECT_PREFIX=s223926_cal_ Rscript build.R

# a contract number moved - the run records the deviation
SETTINGS_OVERRIDE=TRUE TTE_MIN_POTENTIAL_FU_DAYS=180 \
  INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=s223926_fu180_ Rscript build.R
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
verdict comes from, and — where this package applies it — a predicate in
`HERE_PRED`. A criterion in a cohort's list with no source stops the run naming
it; one declared `here` with no predicate stops it too, naming the map that
is missing it. The funnel, cohort membership (`IN_COHORT`), the attrition
table and the dashboard all follow from that list.

**Membership and the funnel are generated from the same two maps**, so they
cannot disagree: `IN_COHORT` is the AND of every `HERE_PRED` predicate and
every retained-flag predicate the cohort's list names, and the funnel's last
step accumulates exactly those, each predicate parenthesised so one may carry
an `OR`. A predicate in `HERE_PRED` is written over `S_COHORT`'s own columns —
`MET_N2`, `MET_I5`, `MET_X1` to `MET_X4`, `INDEX_DATE`, `LOT_NUM` — which are
computed for every indexed patient whatever the list says. So a new criterion
such as

```r
CRITERION_SOURCE[["I4_custom_ce"]] <- "here"
HERE_PRED[["I4_custom_ce"]]        <- "MET_N2 = 1"
```

listed in place of `I4_ce_pre` is applied by membership *and* reported by the
funnel. A criterion taken off the list leaves both together.

A criterion applied **upstream** cannot be added or removed here at all —
see §5.

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
`SEC2L_INPUT_IS_WIDE=TRUE` stops the run and says this (`MODULES.md`, "The
secondary 2L cohort needs a wide input").

**Eligibility applied upstream cannot be undone here.** If the cohort table
arrives with a patient already removed, no setting in this package brings them
back. Changing `I1` to `X4` means rebuilding the cohort table under the cohort
build's own settings (`../ndmm/README.md`, "Settings") — `X4` included: its
flag, `NO_BELANTAMAB_PRE_LOT1`, is the cohort build's, and rebuilding the LOT
run does not recreate it (§2). The settings above change what this package
applies and what it reports — they do not reach backwards.

---

## 6. What is not settled

`OPEN_QUESTIONS.md` holds every question still with the study team. The ones
that can change eligibility are Q2 (outpatient MM codes) and Q6 (steroids as
prior therapy), both applied upstream, and Q13 (disenrolment as censoring),
applied here. Q1, Q5, Q7, Q14 and Q21 are answered or recorded, and each keeps
its setting so the other reading can still be run.

Each reading applied here is one setting, recorded in the run's metadata, with
`SETTINGS_OVERRIDE=TRUE` beside it where the setting is part of the contract.
A reading applied upstream needs the cohort rebuilt.
