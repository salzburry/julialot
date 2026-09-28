# Inclusion and exclusion criteria

Every eligibility rule the protocol states (§7.1, §7.2, §7.2.1.1, §7.2.1.2,
§7.4.1.1), quoted verbatim, with how it is operationalised, which stage applies
it, the funnel, and how to change a date, a window or a criterion. Each rule as
Optum tables and columns is `DATA_MAPPING.md` "8. Variable → source,
criteria"; the cohort build's own implementation of I1 to X4 is
`../ndmm/README.md` "The criteria as applied"; Q-numbers are
`OPEN_QUESTIONS.md`.

## 1. What is being built

| cohort | who | index date | protocol |
|---|---|---|---|
| **1L (NDMM)** | all patients initiating 1L therapy | start of the 1L regimen, **≥ 01 Jan 2019** | §7.2.1, primary |
| **2L (RRMM)** | the subset of the 1L cohort initiating 2L | start of the 2L regimen | §7.2.1, primary nested |
| **3L (RRMM)** | the subset of the 2L cohort initiating 3L | start of the 3L regimen | §7.2.1, primary nested |
| **Secondary 2L (RRMM)** | all patients initiating an assumed 2L therapy | start of the 2L regimen, **≥ 01 Jan 2020** | §7.4.1.1, sensitivity |

> "Patients may contribute sequentially to multiple cohorts as they progress
> through lines of therapy. Three cohorts will be assessed: 1L, 2L, 3L. Each
> subsequent line is a subset of the prior line." — Figure 1 note [1]

> "There is no 4L cohort. Only the 4L start date and 4L regimen received will be
> assessed." — Figure 1 note [4]

The **secondary 2L cohort is not nested**: it takes 2L initiators "irrespective
of whether their 1L initiation occurred during the primary cohort ascertainment
period" (§7.4.1.1). Whether 2L and 3L require membership of the cohort above is
`COHORT_NESTED` (`MODULES.md` "Selecting modules and cohorts").

## 2. Study periods and windows

| period | definition |
|---|---|
| Study period | **01 Jan 2018 → 31 Mar 2026** ("the most recent date of data availability at time of analysis") |
| 1L eligible-treatment period | 1L initiation **on or after 01 Jan 2019** |
| Secondary 2L index period | 2L initiation **on or after 01 Jan 2020** |
| Baseline period | the **12 months before the index date of that LOT**, **index date excluded** |
| Follow-up period | from the index date (**index included**) until **end of continuous enrolment, or end of study period, or death — whichever comes first** |
| Enrolment gap tolerance | gaps of **≤ 30 days** still count as continuous |

Figures 1 and 2 are labelled "Study start 01 Jan 2016"; the body text's
01 Jan 2018 is the study period, as the study team confirmed (Q1).

Every "months" window is a fixed day count - 12 months is
`[index − 365, index − 1]`, 3 months is 90 days - because `add_months()` would
give two patients indexed a day apart different windows. `MONTHS_AS=calendar`
produces the other reading (Q21).

§7.2 gives 1L a 12-month baseline relative to 1L start and 2L one relative to
2L start, and says **only the 1L baseline period assesses study eligibility**.

> "The baseline periods for 2L and 3L may overlap with time on a prior LOT,
> depending on the dates of treatment." — Figure 1 note [3]

So the 2L and 3L baselines are descriptive windows, not eligibility windows -
except for continuous enrolment, which §7.2.1.1 restates for each cohort.
§7.8.1 assesses comorbidities over the baseline *including* the index date, so
two windows are carried (Q14).

### Follow-up: three different things

| concept | protocol | test | as built |
|---|---|---|---|
| **Evidence of follow-up** - eligibility | §7.2.1.1 (I5, N3) | ≥ 1 medical or pharmacy claim from the index date, or death | criterion `I5_followup`, applied in this package to every cohort on its own index (I5 below) |
| **Follow-up period** - the observation window | §7.1 | index → the earliest of end of continuous enrolment, study end, death | `S_PERIODS.FU_END` |
| **≥ 3 months of potential follow-up** - the time-to-event analysis set | §7.8.2 | index + 3 months ≤ study end, or death before | `S_PERIODS.TTE_ELIGIBLE`, a flag and not a filter (§7a) |

`FU_END` (`fu_end_sql()`, `R/windows.R`) is the earliest of the horizon,
`STUDY_END` and the death date. Under `CENSOR_AT_DISENROLLMENT=TRUE`, the
default and the protocol's reading, the horizon is the end of the enrolment
span covering **this cohort's own** index date (spans rebuilt from
`member_enrollment`, gaps ≤ `GAP_DAYS` bridged), falling back to the cohort
table's `ENDDATE_CE`, then `ENDDATE`, where no span covers the index. Under
`FALSE` it is the cohort table's `ENDDATE` - study end or death - which is the
LOT engine's primary reading (`../lot/LOT_RULES.md` §7.6). Which is primary is
Q13. Every time-to-event date and every treatment period is clipped to
`FU_END`: an event after it is a censoring.

## 3. Line-of-therapy definitions the criteria depend on

Eligibility is stated in terms of LOT start dates, so the LOT algorithm is part
of the cohort definition.

> "**1L is defined** as any pre-specified MM therapies received within **60 days** of
> the 1L start date" — §7.2.1.1

> "**Start of 2L and subsequent LOTs are defined as** the earliest of: a stem cell
> transplant (SCT; **allogeneic or an unplanned autologous SCT**), CAR-T cellular
> therapy, or the date of the first administration for a **new MM agent that was not
> part of the previous LOT regimen**. Each subsequent LOT includes all MM therapies
> received within **30 days** on and following the LOT start date" — §7.2.1.1

> "*per GSK LoT algorithm definition, discontinuation of a regimen occurs when all
> MM agents in the LOT are stopped or when a new agent/qualifying SCT event is
> introduced*" — Table 4 footnote

> "LOT assignment and regimens will be assigned according to prior internal GSK work
> to define a claims-based LOT regimen (GSK 2026)" — §7.2

The engine in `../lot/` matches these on the induction windows (60 / 30 days)
and on what opens a line. Where it goes beyond the wording is
`OPEN_QUESTIONS.md` "Known deviations and gaps".

## 4. Inclusion criteria — 1L (NDMM) cohort

§7.2.1.1, "Overall study eligibility, as defined for primary 1L NDMM cohort".

### I1. MM diagnosis

> "At least one **inpatient** medical claim with a diagnosis code for MM in any
> position (any **ICD-9-CM = 203.0x** or **ICD-10-CM code = C90.0x**) **or ≥ 2
> outpatient** medical claims for MM in any position on the claim, **on separate days
> within 90 days**, during the study period"

> "As data in Optum CDM is collected primarily for health insurance and not research
> purposes, **all MM diagnosis codes are to be considered**. Inclusion will focus on
> defining NDMM according to patients who are newly treated, defined as the receipt
> of a 1L treatment, and with no prior MM oncology therapy in the preceding 12
> months"

The cohort build applies it:

- inpatient arm: ≥ 1 inpatient claim with a strict 203.0x / C90.0x code in any
  diagnosis position;
- outpatient arm: ≥ 2 outpatient claims with any code on `mm_dx.csv` in any
  position, on different service dates ≤ 90 days apart (the only pairing window
  the protocol names, Q3 - not the 30 days of X2);
- the diagnosis date used downstream is the first qualifying MM claim
  (`MM_DX_DT`).

The strict code set is written against the inpatient arm; the outpatient arm
says only "for MM". The production `mm_dx.csv` holds only the eight strict
codes, so both arms are strict in practice and the broad reading is a code-list
edit (Q2).

### I2. Adult age

> "Aged **≥ 18 years** at the time of MM diagnosis **according to calendar year**"

`year(MM_DX_DT) − YRDOB`, not a birthday. Optum carries year of birth only,
capped at 89, so a "90+" patient reads as 89.

### I3. Eligible 1L treatment

> "Received an eligible or expected treatment for MM on or after MM diagnosis
> (**other than belantamab**), occurring **on or after 01 Jan 2019** (eligible treatment
> period)."
> - "The 1L cohort index date is the date of the **first claim for MM treatment**
>   within the identification period"
> - "Eligible/expected treatments include MM regimens commonly used in the first line
>   setting, **excluding those restricted to later LOTs**"
>   - "Exclusions include: **panobinostat** and **elotuzumab**. Other potential therapies
>     pending review of data may be considered"
> - "For a full list of eligible/expected MM therapies, see **Annex 2**"

Three constraints: the treatment is **on or after the MM diagnosis date**; the
agent is not belantamab, panobinostat or elotuzumab (these cannot **set** the
1L index); the claim is **on or after 01 Jan 2019**.

The cohort build sets the index. It bars belantamab by its own rule and any
other agent named in `NDMM_INDEX_EXCLUDED_ABBRS`, which is empty by default, so
the build is run with panobinostat and elotuzumab named there
(`../ndmm/README.md` "Barring agents from the 1L index");
`<prefix>NDMM_INDEX_AGENTS` says what barring each one costs. This package
checks the result: `COHORT_INDEX_EXCLUSIONS` (default
`panobinostat,elotuzumab`, `none` checks nothing) is resolved to abbreviations
through `cl_mma_rollup.csv` and compared with the cohort build's recorded
`INDEX_EXCLUDED`, and a cohort that did not bar both stops the run. Annex 2's
therapy list is outstanding (Q15); `cl_mma_codelist.csv` and
`cl_mma_rollup.csv` are the nearest equivalent.

### I4. Continuous enrolment before index

> "CE of at least **12-months** with **medical and pharmacy benefits** before the 1L
> cohort index date. Patients with gaps in enrolment of **≤ 30 days** are considered
> to be continuously enrolled"

An enrolment span covering `[index − 365, index − 1]`, gaps of ≤ 30 days
bridged. The benefit requirement is satisfied by construction: the deployed
`MEMBER_ENROLLMENT` carries no per-benefit flag, and §7.5 says "**All patients
in this database have both medical and pharmacy coverage**" (Q4).

### I5. Evidence of follow-up

> "at least one claim (pharmacy or medical) **from index date** or death"

and, restated per cohort:

> "**CE during follow-up for each cohort:** at least one claim (pharmacy or medical)
> from index date" — §7.2.1.1

A claims-presence test, not an enrolment-span test. `I5_followup` is applied
in this package, to every cohort, on that cohort's own index date, under
`FU_EVIDENCE_RULE`:

| reading | test |
|---|---|
| `claim_from_index` (default, the protocol's words) | passes everyone: the index claim is itself a claim on the index date |
| `claim_after_index` | a medical or pharmacy claim strictly after the line's index and on or before `STUDY_END`, or a recorded death |
| `enrolled_on_index` | an enrolment span covering the index date |

Measured, every indexed member has a claim on their index date, so the default
excludes nobody and the strict reading would exclude about 1% (Q5). The cohort
build separately requires enrolment on the 1L index date itself (its
`FU_CE_DAYS=0`).

## 5. Additional inclusion criteria — nested 2L and 3L cohorts

§7.2.1.1, "Additional eligibility for primary nested 2L and 3L RRMM Cohorts".

> "The subset of patients with evidence of each subsequent LOT will be included in
> the 2L or 3L cohort at the initiation of 2L/3L."

| # | criterion | text |
|---|---|---|
| N1 | Received the line | "Received a subsequent LOT required to qualify for a specific cohort (i.e., received a 2L treatment for 2L, 3L for 3L)" |
| N2 | CE before that line | "CE of at least **12-months** with medical and pharmacy benefits before the cohort index date (2L or 3L). Patients with gaps in enrolment of ≤ 30 days are considered to be continuously enrolled" |
| N3 | Follow-up | "CE during follow-up for each cohort: at least one claim (pharmacy or medical) from index date" |

And nothing else: the 1L exclusions are not re-applied at 2L or 3L - they were
applied when the patient entered the 1L cohort, and §7.1 says only the 1L
baseline assesses eligibility. This package builds the 2L and 3L cohorts from
the 1L cohort and the LOT engine's lines: N1 is a line at that number, N2 is
continuous enrolment before that line's own start, N3 is `I5_followup` on it.
The cohort build's own 2L and 3L tables, and their `SUBSEQ_FU_CE_DAYS`
enrolment test, are not read.

## 6. Exclusion criteria — applied on the 1L baseline

§7.2.1.2. All four are applied by the cohort build (`../ndmm/README.md` "The
criteria as applied").

### X1. MM oncology therapy in the 12-month 1L baseline

> "**Evidence of an MM oncology therapy during the 12-month 1L baseline period:**
> ≥ 1 medical or pharmacy claim for any MM oncology therapy
> - This is to ensure that treatment exposure and LOT assignments reflect incident
>   therapy starts at the index date and are not confounded by ongoing or recent
>   prior MM treatments"

The "newly treated" criterion. It says **any MM oncology therapy** - wider than
I3's eligible-1L list - on a medical or pharmacy claim, so J-code
administration and pharmacy fills both count. The cohort build scans
`cl_mma_codelist.csv` over `[index − 365, index − 1]` and drops steroid rows
(`DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE`) on the reasoning that a
steroid claim alone is supportive care. The protocol does not say so. On the
production code list the drop removes nothing; it becomes a real decision when
Annex 2's therapy list arrives (Q6).

### X2. Another cancer in the 1L baseline

> "**Evidence of another cancer in the 1L baseline period:** Patients with either
> **≥ 1 inpatient or ≥ 2 outpatient** ICD-9-CM or ICD-10-CM codes **on separate days,
> within 30 days**, for the **same primary tumor type and/or metastatic cancer** will be
> excluded"

The cohort build applies all four parts: one inpatient claim is enough;
outpatient pairs are built from distinct dates at most 30 days apart (fixed in
that build's code); pairing is per tumour type. It layers five readings on top,
each of which the study team should confirm rather than inherit (the settings
named are the ones this package records them under, §10):

| # | the build's reading | effect |
|---|---|---|
| 1 | **Both** claims of a pair must fall inside `[index−365, index−1]` (`OTHER_CANCER_BOTH_IN_BASELINE`) | cohort **larger**: a pair straddling the index does not exclude |
| 2 | Pairs match on the **first three characters of the ICD code** (`OTHER_CANCER_PAIR_GRAIN=icd3`), because `other_malig.csv` carries nearly one `tumor_group` label per code (1,618 labels over 1,643 codes) | cohort **smaller**: claims pair that a per-label match would not |
| 3 | Metastatic codes collapse into one `MET` group - `C77`, `C78`, `C79`, `C7B`, `C800` and ICD-9 `196`, `197`, `198`, `1990` (**not** `C80`, `199`) | - |
| 4 | **Bone metastasis excludes.** `C79.51`, `C79.52` and `198.5` are kept in as metastatic cancers, although myeloma bone disease is commonly coded `C79.51` | cohort **smaller**, and some of the loss is myeloma miscoded |
| 5 | Plasma-cell disorders and monoclonal gammopathy do **not** count as another cancer (`NDMM_MM_ADJACENT_OVERRIDE`) - they are the index disease | - |

Reading 4 is the one to put to the study team first: a known, count-moving
trade against a real risk of dropping myeloma patients.
`<prefix>NDMM_OTHER_MALIG_GROUPS` and `<prefix>NDMM_OTHER_MALIG_GRAIN` price the
pairing grain on every run.

### X3. Pregnancy or childbirth

> "**Evidence of pregnancy:** ≥ 1 of medical claim with a **diagnosis, procedure, or
> revenue code** indicating pregnancy or childbirth **during the study period**"

Three code types, and the window is the **whole study period**, not the
baseline. The cohort build reads `ICD9DIAG`, `ICD10DIAG`, `ICD9PROC`,
`ICD10PROC`, `HCPCS` and `REV` (`NDMM_PREG_CODE_TYPES`), and the production
`pregnancy.csv` carries all six. The patient-specific window is recorded as a
reading, not taken (Q23).

### X4. Belantamab mafodotin in any LOT

> "**Received belantamab mafodotin (i.e., an ADC) in any LOT**
> - Note: at the time of study belantamab mafodotin was the only ADC in use for MM"

"In any LOT" cannot be evaluated before lines exist, so it is applied in two
halves that remove different patients and are reported separately:

- **before the 1L index** - the cohort build's flag `NO_BELANTAMAB_PRE_LOT1`,
  the funnel step `X4_belantamab`;
- **from the first line on** - the LOT engine's `no_belantamab` line criterion,
  which removes every line of a patient with belantamab anywhere
  (`../lot/LOT_RULES.md` §8), the funnel step `lot_line_criteria`.

## 7. Secondary 2L cohort

§7.4.1.1.

> "A sensitivity analysis in which all patients initiating an assumed 2L therapy on
> **≥ 01 Jan 2020** will be assessed."

> "All inclusion/exclusion criteria will be the same as the primary cohort, **with the
> exception of the index date**. Patients in this analysis are analysis are eligible
> if there is **evidence of a malignancy prior to 2L**."

Read literally the second sentence (duplication in the source) **reverses X2**
for this cohort: a prior malignancy does not exclude. §7.4.1.2 agrees - "all
malignancies occurring after diagnosis but prior to 2L will be tabulated" - and
so does §7.8.1 (Q7, answered). Because the index is 2L initiation "irrespective
of whether their 1L initiation occurred during the primary cohort ascertainment
period", the cohort reaches patients whose 1L falls before 01 Jan 2019 and
needs its own input (`MODULES.md` "The secondary 2L cohort's wide input").

## 7a. The analysis-set restriction that is not an eligibility criterion

> "Outcomes will only be assessed in the subset of patients who have **≥ 3 months of
> potential follow-up (or die before 3 months) from their index date** to ensure
> adequate time in the database for outcome assessments." — §7.8.2

Scoped to the time-to-event outcomes (TTNT, TTD, OS). It is an analysis set,
not a cohort: a flag, not a funnel step, or the descriptive denominators for
Primary Objectives 1-3 would be wrong. "Potential follow-up" is read as time in
the database, not observed enrolment: `tte_eligible_sql()` (`R/windows.R`)
sets `S_PERIODS.TTE_ELIGIBLE = 1` where index + `TTE_MIN_POTENTIAL_FU_DAYS` (90,
built by the same `MONTHS_AS` rule as every month window) falls on or before
`STUDY_END`, or the patient died before that date. `S_TTE` keeps every cohort
row with the flag beside it; the restricted analysis is the rows where
`TTE_ELIGIBLE = 1`. The 90 days is not an eligibility test.

## 8. The order to apply them, and the funnel

The protocol prescribes no order. This one keeps every count reproducible and
is the order the funnels are written in.

| step | criterion | population after it |
|---|---|---|
| 0 | any MM diagnosis claim in the study period | MM-coded patients |
| 1 | **I1** qualifying MM diagnosis (1 IP or 2 OP ≤ 90 d) | diagnosed |
| 2 | **I2** age ≥ 18 in the diagnosis calendar year | diagnosed adults |
| 3 | **I3** eligible 1L treatment on/after diagnosis, ≥ 01 Jan 2019, not belantamab / panobinostat / elotuzumab | indexed |
| 4 | **I4** 12 months CE before index, gaps ≤ 30 d | enrolled at baseline |
| 5 | **I5** ≥ 1 claim from the index date, or death | observed |
| 6 | **X1** no MM oncology therapy in the 12-month baseline | newly treated |
| 7 | **X2** no other cancer in the 12-month baseline | no second cancer |
| 8 | **X3** no pregnancy or childbirth in the study period | 1L cohort (pre-LOT) |
| 9 | **X4** no belantamab in any LOT | **1L (NDMM) cohort** |
| 10 | **N1** received 2L | |
| 11 | **N2** 12 months CE before the 2L index, gaps ≤ 30 d | **2L cohort** |
| 12 | **N1** received 3L | |
| 13 | **N2** 12 months CE before the 3L index, gaps ≤ 30 d | **3L cohort** |

Steps 9-13 need the LOT build to have run; steps 0-8 do not. The secondary 2L
cohort repeats steps 0-8 with the index at 2L ≥ 01 Jan 2020 and, on Q7's
answer, step 7 dropped.

Steps 0-8 bar I5, and X4's pre-index half, are the **cohort build's** funnel,
with its own attrition (`../ndmm/README.md` "The attrition"). `S_ATTRITION` is
this package's: one row per step, per cohort, beginning where the cohort
build's ends, so its first rows say what stood between the two.

| opening step | `APPLIED_BY` | what it counts |
|---|---|---|
| `indexed_at_line` | `lot` | patients on the input with a line at this line number (and on or after the cohort's index floor) in `LOT_LONG_ALLFLAGS` - every line the engine built, before its own criteria |
| `lot_line_criteria` | `lot` | the same patients after the engine's criteria; the difference is the engine's removals, belantamab in any LOT among them |
| `in_1L_cohort`, `in_2L_cohort` | `carried in` | a nested cohort's single opening row: the parent cohort it is drawn from, so `N1_received_line`'s loss is the patients who did not go on to that line |

Then one step per criterion of the cohort, `APPLIED_BY` `cohort`, `here` or
`cohort+here`. Under `COHORT_NESTED=FALSE` each line is nobody's subset and
opens on the engine's lines. Each row carries `N_REMAINING` and `N_LOST`, which
is what that step removed, not what failed it: a patient failing two criteria
is lost at the first, so the funnel never gains patients as it descends. A
criterion applied upstream shows no loss - it is in the funnel so the reader
can see it was applied. Where `LOT_LONG_ALLFLAGS` is absent (an older LOT
build) the opening steps are left out with a warning; where it cannot be read
the run stops.

## 9. Who applies each criterion

Most eligibility is applied upstream: the cohort table arrives with the
verdict already made, and this package reads it.

| criterion | rule | applied by |
|---|---|---|
| `I1_mm_dx` | multiple myeloma diagnosis | the cohort build |
| `I2_age` | ≥ 18 in the diagnosis calendar year | the cohort build |
| `I3_eligible_1l_tx` | an eligible 1L therapy initiation | the cohort build; this package **checks** the agents barred from the index (I3 above) |
| `I4_ce_pre` | continuous enrolment before index | the cohort build, **re-applied here** on the line's own index date |
| `I5_followup` | evidence of follow-up from index | **here** |
| `X1_prior_mm_tx` | no prior myeloma therapy | the cohort build (flag `NO_PRIOR_MM_TX`) |
| `X2_other_cancer` | no other cancer before 1L | the cohort build (flag `NO_OTHER_CANCER_PRE_LOT1`) |
| `X3_pregnancy` | no pregnancy | the cohort build (flag `NO_PREGNANCY`) |
| `X4_belantamab` | no belantamab before 1L | the cohort build (flag `NO_BELANTAMAB_PRE_LOT1`) |
| `N1_received_line` | received the line this cohort indexes on | **here** |
| `N2_ce_pre` | continuous enrolment before *this line's* index | **here** |

`I4` and `N2` are the same rule on different dates: the cohort build tested
enrolment before the **1L** index, and a 2L or 3L patient indexes later, so
re-applying it here makes the 2L funnel show that step's loss. The LOT
engine's belantamab rule is a different criterion from `X4`, and rebuilding the
LOT run does not recreate the cohort flag. The input table's two shapes, and
what `check_cohort_table()` refuses, are `MODULES.md` "The input cohort table".

**Every `S_COHORT` row says what its verdict is over.** `CRITERIA_ASKED` is the
list the cohort is judged on: 1L and SEC2L on nine criteria (SEC2L eight under
the bundled default, which drops X2), 2L and 3L on three - `N1`, `N2`, `I5`.
`MET_X1`-`MET_X4` sit on every row but are part of the verdict only where the
list names them, so ANDing the `MET_*` flags reproduces 1L and gets a different
cohort at 2L, 3L and SEC2L. Use `IN_COHORT`. `I1`-`I3` have no predicate here:
a patient on the input passed them by being there.

In the code (`R/modules/01_cohorts.R`): `CRITERION_SOURCE` is the table above as
data; `CRITERION_FLAG` names the input column carrying each upstream verdict;
`HERE_PRED` holds the predicate for each criterion this package applies;
`check_cohort_table()` the input checks. `R/registry.R` holds `CRITERIA_1L` and
each cohort's own list. A criterion in a cohort's list that `CRITERION_SOURCE`
does not know stops the run, and so does one declared `here` with no
`HERE_PRED` predicate.

## 10. Changing dates, windows and criteria

Every eligibility decision this package makes is a setting. Set it in the
environment or in `config.csv`; the environment wins.

| setting | default | changes |
|---|---|---|
| `STUDY_START` | 2018-01-01 | the study window's start (Q1) |
| `STUDY_END` | 2026-03-31 | the study window's end, and the CDM quarter it reads |
| `LOT1_INDEX_FROM` | 2019-01-01 | earliest 1L initiation that may index the 1L cohort |
| `SEC2L_INDEX_FROM` | 2020-01-01 | earliest 2L initiation for the secondary cohort |
| `COHORTS` | `1L,2L,3L` | which cohorts to build |
| `COHORT_NESTED` | `TRUE` | whether 2L and 3L require membership of the cohort above |
| `BASELINE_DAYS` | 365 | how far back the baseline reaches |
| `BASELINE_INCLUDES_INDEX` | `FALSE` | whether the index date is in the baseline; §7.1 says no (Q14) |
| `COMORBIDITY_BASELINE_INCLUDES_INDEX` | `TRUE` | §7.8.1 says yes, for comorbidities only (Q14) |
| `CE_PRE_DAYS` | 365 | days of continuous enrolment required before index |
| `GAP_DAYS` | 30 | an enrolment gap this long or shorter is still continuous |
| `MONTHS_AS` | `days` | `days` or `calendar` (Q21) |
| `TTE_MIN_POTENTIAL_FU_DAYS` | 90 | potential follow-up needed for the time-to-event analysis set |
| `FU_EVIDENCE_RULE` | `claim_from_index` | what counts as evidence of follow-up (I5, Q5) |
| `CENSOR_AT_DISENROLLMENT` | `TRUE` | whether follow-up ends at disenrolment or runs to death or study end (Q13) |
| `SEC2L_APPLY_OTHER_CANCER` | `FALSE` | the secondary 2L cohort permits prior malignancy (Q7) |
| `SEC2L_INPUT_IS_WIDE` | `FALSE` | asserts the input was built without the other-cancer exclusion and the 1L floor |
| `COHORT_INDEX_EXCLUSIONS` | `panobinostat,elotuzumab` | the agents the cohort build must have barred from setting the 1L index; `none` checks nothing |
| `MAX_LOT` | 4 | the highest line this package describes (1 to 5) |

### Settings the cohort build owns

`STUDY_START`, `MM_DX_OUTPATIENT_CODES` (Q2), `MM_DX_OUTPATIENT_WINDOW_DAYS`
(Q3), `PRIOR_TX_DROP_STEROIDS` (Q6), `OTHER_CANCER_PAIR_DAYS`,
`OTHER_CANCER_PAIR_GRAIN`, `OTHER_CANCER_BOTH_IN_BASELINE` and
`PREGNANCY_WINDOW` (Q23) are the cohort build's rules. Here they are
**recorded, not applied**: changing one does not change the cohort, and where
the cohort build's recorded value can be read the run records both
(`MODULES.md` "What a run records"). Changing one means rebuilding the cohort
table under the cohort build's own settings (`../ndmm/README.md` "Settings").

### What stops a changed run

- **The contract.** The numbers the protocol states outright are pinned in
  `CONTRACT` (`R/config_223926.R`): `BASELINE_DAYS`, `CE_PRE_DAYS`, `GAP_DAYS`,
  `LOT_POST_DISCON_DAYS`, `ACUTE_WASHOUT_DAYS`, `TTE_MIN_POTENTIAL_FU_DAYS`,
  `SUPPRESS_MIN_N`, `LOT1_INDEX_FROM`, `SEC2L_INDEX_FROM` and `STUDY_END`.
  Changing one stops the run unless `SETTINGS_OVERRIDE=TRUE`, and the run is
  then stamped in `S_RUN_METADATA.CONTRACT_DEVIATIONS`, which no reader
  downstream accepts as the study's numbers.
- **The cohort it reads.** `STUDY_START`, `STUDY_END` and `LOT1_INDEX_FROM` are
  held to the values the cohort build recorded (`BINDING_UPSTREAM_SETTINGS`,
  read by `read_upstream_settings()`). A disagreement stops the run unless
  `SETTINGS_OVERRIDE=TRUE`, which records it as a deviation. The other
  upstream settings only shape a criterion's reading: a disagreement is logged,
  both values are recorded, and the run goes on. Moving the study window means
  rebuilding the cohort and the LOT run under the new window, then running this
  package against them.

The open-question readings change freely. Write each run to a **different
`OBJECT_PREFIX`** and the runs sit side by side - two prefixes are two
scenarios in the dashboard's Compare tab:

```bash
# a sensitivity on an open reading - no override needed
MONTHS_AS=calendar INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  OBJECT_PREFIX=s223926_cal_ Rscript build.R

# a contract number moved - the run records the deviation
SETTINGS_OVERRIDE=TRUE TTE_MIN_POTENTIAL_FU_DAYS=180 \
  INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=s223926_fu180_ Rscript build.R
```

### Adding or dropping a criterion

Edit the cohort's list in `R/registry.R`:

```r
CRITERIA_1L <- c("I1_mm_dx", "I2_age", "I3_eligible_1l_tx", "I4_ce_pre",
                 "I5_followup", "X1_prior_mm_tx", "X2_other_cancer",
                 "X3_pregnancy", "X4_belantamab")
```

and give a new criterion an entry in `CRITERION_SOURCE` and, where this package
applies it, a predicate in `HERE_PRED`. Membership and the funnel are generated
from the same maps, so they cannot disagree: `IN_COHORT` is the AND of every
`HERE_PRED` predicate and every retained-flag predicate the list names, each
parenthesised so one may carry an `OR`, and the funnel's last step accumulates
exactly those. A predicate is written over `S_COHORT`'s own columns - `MET_N2`,
`MET_I5`, `MET_X1` to `MET_X4`, `INDEX_DATE`, `LOT_NUM` - which are computed for
every indexed patient whatever the list says. So

```r
CRITERION_SOURCE[["I4_custom_ce"]] <- "here"
HERE_PRED[["I4_custom_ce"]]        <- "MET_N2 = 1"
```

listed in place of `I4_ce_pre` is applied by membership and reported by the
funnel; a criterion taken off the list leaves both.

**Eligibility applied upstream cannot be undone here.** A patient the cohort
table arrives without cannot be brought back by any setting in this package.
Changing `I1` to `X4` means rebuilding the cohort table under the cohort
build's settings - `X4` included, since `NO_BELANTAMAB_PRE_LOT1` is the cohort
build's flag and rebuilding the LOT run does not recreate it.
