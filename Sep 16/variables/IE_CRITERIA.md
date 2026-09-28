# Inclusion / exclusion criteria — GSK 223926 (Aug 26 2026 protocol)

Every eligibility rule the protocol states, quoted with its section, and how
the build operationalises it.

Source: the GSK **223926** protocol. The criteria
are in §7.1, §7.2, §7.2.1.1, §7.2.1.2 and §7.4.1.1; quoted text is verbatim.

Where to read further:

- `IE_CRITERIA_APPLIED.md` — who applies each criterion, the attrition funnel,
  and the settings that change a date, a window or a criterion.
- `DATA_MAPPING.md` — each rule as Optum tables and columns.
- `../ndmm/README.md`, "The criteria as applied" — the cohort build's own
  implementation of I1 to X4.
- `OPEN_QUESTIONS.md` — the readings still with the study team (Q-numbers
  below).

---

## 1. What is being built

Four cohorts, not one.

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

The **secondary 2L cohort is not nested**: it takes 2L initiators "irrespective of
whether their 1L initiation occurred during the primary cohort ascertainment
period".

---

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

The build reads every "months" window as a fixed day count — 12 months is
`[index − 365, index − 1]`, 3 months is 90 days — because `add_months()` would
give two patients indexed a day apart different windows. The protocol never
disambiguates; Q21 records the reading, and `MONTHS_AS=calendar` produces the
other.

Two things about the baseline period that decide how the build is wired:

> "1L will have a 12-month baseline relative to 1L start, and 2L will have a
> 12-month baseline period relative to 2L start. **Only the 1L baseline period will
> be used to assess study eligibility.**" — §7.2

> "The baseline periods for 2L and 3L may overlap with time on a prior LOT,
> depending on the dates of treatment." — Figure 1 note [3]

So the 2L and 3L 12-month baselines are **descriptive windows**, not eligibility
windows — except for the continuous-enrolment requirement, which §7.2.1.1 does
restate for each cohort. §7.8.1 assesses comorbidities over the baseline
*including* the index date, so the build carries both windows (Q14).

### Follow-up: three different things

The protocol uses follow-up in three senses, and they are different tests:

| concept | protocol | test | how the build implements it |
|---|---|---|---|
| **Evidence of follow-up** — eligibility | §7.2.1.1 (I5, N3) | ≥ 1 medical or pharmacy claim from the index date, or death | criterion `I5_followup`, applied in this package to every cohort on that cohort's own index — §4, I5 |
| **Follow-up period** — the observation window | §7.1 | index → the earliest of end of continuous enrolment, study end, death | `S_PERIODS.FU_END`, below |
| **≥ 3 months of potential follow-up** — the time-to-event analysis set | §7.8.2 | index + 3 months ≤ study end, or death before | `S_PERIODS.TTE_ELIGIBLE`, a flag and not a filter — §7a |

`FU_END` is built by `fu_end_sql()` in `R/windows.R`: the earliest of the
horizon, `STUDY_END` and the death date. Under `CENSOR_AT_DISENROLLMENT=TRUE`,
the default and the protocol's reading, the horizon is the end of the
enrolment span covering **this cohort's own** index date (spans rebuilt from
`member_enrollment`, gaps ≤ `GAP_DAYS` bridged), falling back to the cohort
table's `ENDDATE_CE` where no span covers the index. Under `FALSE` it is the
cohort table's `ENDDATE` — study end or death — which is the LOT engine's
primary reading (`../lot/LOT_RULES.md` §7.6, "Disenrollment is not
censoring"). Which is primary is Q13. Every time-to-event date, and every
treatment period, is clipped to `FU_END`: an event after it is a censoring.

The 90 days is not an eligibility test. The protocol's follow-up criterion
for every cohort is the one-claim test, and 90 days appears only in §7.8.2,
as **potential** follow-up — calendar time in the database, not observed
enrolment.

---

## 3. Line-of-therapy definitions the criteria depend on

Eligibility is stated in terms of LOT start dates, so the LOT algorithm is part of
the cohort definition, not downstream of it.

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
and on what opens a line. Where it goes beyond the wording, and what that
changes, is `CONFORMANCE.md`, "The LOT engine against the protocol's LOT
wording".

---

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

Operationally (the cohort build):

- inpatient arm: ≥ 1 inpatient claim, a strict 203.0x / C90.0x code **in any diagnosis position**
- outpatient arm: ≥ 2 outpatient claims, any code on `mm_dx.csv` in any position, **different service dates**, **≤ 90 days apart**
- the diagnosis date used downstream is the **first** qualifying MM claim (`MM_DX_DT`)

> **Open reading.** The strict code set is written against the inpatient arm; the
> outpatient arm says only "medical claims for MM". The deployed `mm_dx.csv`
> holds only the eight strict codes (`CODELISTS.md` §1), so both arms are strict
> in practice; widening the file is all the broad reading needs. Q2.

The 90 days is the only outpatient pairing window the protocol names, and the
build uses it (Q3). It is not the 30 days of the other-cancer rule (X2): they
are different numbers on different criteria.

### I2. Adult age

> "Aged **≥ 18 years** at the time of MM diagnosis **according to calendar year**"

Calendar-year arithmetic: `year(MM_DX_DT) − YRDOB`, not a birthday, applied
after the earliest qualifying diagnosis date is chosen. Optum carries year of
birth only (`YRDOB`), capped at 89 in CDM V9.0, so a "90+" patient reads as 89.

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

Three separate constraints ride on this one bullet:

1. the treatment must fall **on or after the MM diagnosis date**;
2. the agent must not be belantamab, panobinostat or elotuzumab — these cannot **set**
   the 1L index date;
3. the claim must be **on or after 01 Jan 2019**.

The cohort build sets the index. It bars belantamab by its own rule and any
other agent named in `NDMM_INDEX_EXCLUDED_ABBRS`, which is empty by default, so
the build is run with panobinostat and elotuzumab named there
(`../ndmm/README.md`, "Barring agents from the 1L index").
`<prefix>NDMM_INDEX_AGENTS` says what barring each one costs. This package
checks the result: `COHORT_INDEX_EXCLUSIONS` (default
`panobinostat,elotuzumab`) is compared with the cohort build's recorded
`INDEX_EXCLUDED`, and a cohort that did not bar both stops the run.

> **Gap.** Annex 2 — the eligible/expected MM therapy list and the SOC regimen
> categorisation — is outstanding (Q15). `cl_mma_codelist.csv` and
> `cl_mma_rollup.csv` are the nearest existing equivalent (`CODELISTS.md` §1).

### I4. Continuous enrolment before index

> "CE of at least **12-months** with **medical and pharmacy benefits** before the 1L
> cohort index date. Patients with gaps in enrolment of **≤ 30 days** are considered
> to be continuously enrolled"

An enrolment span covering `[index − 365, index − 1]`, gaps of ≤ 30 days
bridged. The benefit requirement is satisfied by construction: the deployed
`MEMBER_ENROLLMENT` carries no per-benefit flag, and §7.5 says "**All patients
in this database have both medical and pharmacy coverage**" (Q4,
`DATA_MAPPING.md` §7).

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
| `claim_after_index` | a medical or pharmacy claim strictly after the index and on or before `STUDY_END`, counted per line by `build_fu_claims()`, or a recorded death |
| `enrolled_on_index` | the enrolment span covering the index date |

Measured, every indexed member has a claim on their index date, so the default
excludes nobody and the strict reading would exclude about 1% (Q5). The cohort
build separately requires enrolment on the 1L index date itself
(`FU_CE_DAYS=0`, its contract).

---

## 5. Additional inclusion criteria — nested 2L and 3L cohorts

§7.2.1.1, "Additional eligibility for primary nested 2L and 3L RRMM Cohorts".

> "The subset of patients with evidence of each subsequent LOT will be included in
> the 2L or 3L cohort at the initiation of 2L/3L."

| # | criterion | text |
|---|---|---|
| N1 | Received the line | "Received a subsequent LOT required to qualify for a specific cohort (i.e., received a 2L treatment for 2L, 3L for 3L)" |
| N2 | CE before that line | "CE of at least **12-months** with medical and pharmacy benefits before the cohort index date (2L or 3L). Patients with gaps in enrolment of ≤ 30 days are considered to be continuously enrolled" |
| N3 | Follow-up | "CE during follow-up for each cohort: at least one claim (pharmacy or medical) from index date" |

And nothing else. The 1L exclusions are **not** re-applied at 2L or 3L — they were
already applied when the patient entered the 1L cohort, and §7.1 says only the 1L
baseline assesses eligibility.

This package builds the 2L and 3L cohorts itself, from the 1L cohort and the
LOT engine's lines: N1 is a line at that number, N2 is continuous enrolment
before that line's own start, N3 is `I5_followup` on it. The cohort build's
own 2L and 3L tables, and their `SUBSEQ_FU_CE_DAYS` enrolment test, are not
read.

---

## 6. Exclusion criteria — applied on the 1L baseline

§7.2.1.2. All four are quoted in full, and all four are the cohort build's
(`../ndmm/README.md`, "The criteria as applied").

### X1. MM oncology therapy in the 12-month 1L baseline

> "**Evidence of an MM oncology therapy during the 12-month 1L baseline period:**
> ≥ 1 medical or pharmacy claim for any MM oncology therapy
> - This is to ensure that treatment exposure and LOT assignments reflect incident
>   therapy starts at the index date and are not confounded by ongoing or recent
>   prior MM treatments"

This is the "newly treated" criterion. It says **any MM oncology therapy** —
wider than the eligible-1L list of I3 — on a *medical or pharmacy* claim, so
both J-code administration and pharmacy fill count. The cohort build scans
`cl_mma_codelist.csv` over `[index − 365, index − 1]`.

> **Note.** The cohort build drops steroid rows from this scan, on the
> reasoning that a steroid claim alone is supportive care. The protocol does not
> say so. On today's code list the drop removes nothing — no agent is spelled
> `DEX`, `DEXA`, `DEXAMETHASONE`, `PRED` or `PREDNISONE` — and it becomes a real
> decision when Annex 2's therapy list arrives. Q6.

### X2. Another cancer in the 1L baseline

> "**Evidence of another cancer in the 1L baseline period:** Patients with either
> **≥ 1 inpatient or ≥ 2 outpatient** ICD-9-CM or ICD-10-CM codes **on separate days,
> within 30 days**, for the **same primary tumor type and/or metastatic cancer** will be
> excluded"

The cohort build applies all four parts: one inpatient claim is enough on its
own; outpatient pairs are built from **distinct dates** at most 30 days apart
(the 30 is fixed in that build, not a setting); and pairing is per tumour type.
It layers five readings on top, each of which the study team should confirm
rather than inherit:

| # | the build's reading | effect |
|---|---|---|
| 1 | **Both** claims of a pair must fall inside `[index−365, index−1]` — the criterion is another cancer **in** the 1L baseline | cohort **larger**: a pair straddling the index does not exclude |
| 2 | Pairs match on the **first three characters of the ICD code**, not on `tumor_group`, because `other_malig.csv` carries nearly one label per code (1,618 labels over 1,643 codes) | cohort **smaller**: claims pair that a per-label match would not |
| 3 | Metastatic codes collapse into a single `MET` group — `C77`, `C78`, `C79`, `C7B`, `C800` and ICD-9 `196`, `197`, `198`, `1990` (**not** `C80`, `199`) — "and/or metastatic cancer" is one concept | — |
| 4 | **Bone metastasis excludes.** `C79.51`, `C79.52` and `198.5` are metastatic cancers and are kept in, although myeloma bone disease is commonly coded `C79.51` | cohort **smaller**, and some of the loss is myeloma miscoded |
| 5 | Plasma-cell disorders and monoclonal gammopathy do **not** count as another cancer (`NDMM_MM_ADJACENT_OVERRIDE`) — they are the index disease | — |

Reading 4 is the one to put to the study team first: it is a known,
deliberate, count-moving trade against a real risk of dropping myeloma
patients. `<prefix>NDMM_OTHER_MALIG_GROUPS` and `<prefix>NDMM_OTHER_MALIG_GRAIN`
price the pairing grain on every run.

### X3. Pregnancy or childbirth

> "**Evidence of pregnancy:** ≥ 1 of medical claim with a **diagnosis, procedure, or
> revenue code** indicating pregnancy or childbirth **during the study period**"

Three code types, and the window is the **whole study period**, not the
baseline. The cohort build reads `ICD9DIAG`, `ICD10DIAG`, `ICD9PROC`,
`ICD10PROC`, `HCPCS` and `REV` (`NDMM_PREG_CODE_TYPES`), and the production
`pregnancy.csv` carries all six. The narrower patient-specific window is
recorded as a reading, not taken (Q23).

### X4. Belantamab mafodotin in any LOT

> "**Received belantamab mafodotin (i.e., an ADC) in any LOT**
> - Note: at the time of study belantamab mafodotin was the only ADC in use for MM"

"In any LOT" cannot be evaluated before lines exist, so it is applied in two
halves:

- **before the 1L index** — the cohort build's flag `NO_BELANTAMAB_PRE_LOT1`,
  the funnel step `X4_belantamab`;
- **from the first line on** — the LOT engine's `no_belantamab` line criterion,
  which removes every line of a patient with belantamab anywhere
  (`../lot/LOT_RULES.md` §8), reported as the funnel's `lot_line_criteria`
  step.

They remove different patients and the funnel reports them separately
(`IE_CRITERIA_APPLIED.md` §3).

---

## 7. Secondary 2L cohort

§7.4.1.1.

> "A sensitivity analysis in which all patients initiating an assumed 2L therapy on
> **≥ 01 Jan 2020** will be assessed."

> "All inclusion/exclusion criteria will be the same as the primary cohort, **with the
> exception of the index date**. Patients in this analysis are analysis are eligible
> if there is **evidence of a malignancy prior to 2L**."

The second sentence carries a duplication ("are analysis are") in the source. Read
literally it **reverses X2** for this cohort: a prior malignancy does not exclude.
That reading is consistent with §7.4.1.2, which says the only modification to
Primary Objective 3 is that "all malignancies occurring after diagnosis but prior to
2L will be tabulated, and new malignancies occurring 2L will be assessed" — you
cannot tabulate prior malignancies in a cohort that excluded them. Q7.

Also from §7.4.1.1: the index is 2L initiation ≥ 01 Jan 2020 "irrespective of
whether their 1L initiation occurred during the primary cohort ascertainment
period", so this cohort reaches patients whose 1L falls before 01 Jan 2019.
It therefore needs its own input — `IE_CRITERIA_APPLIED.md` §5.

---

## 7a. The analysis-set restriction that is not an eligibility criterion

§7.8.2 adds a restriction that never appears in §7.2.1 and is easy to miss:

> "Outcomes will only be assessed in the subset of patients who have **≥ 3 months of
> potential follow-up (or die before 3 months) from their index date** to ensure
> adequate time in the database for outcome assessments."

This is scoped to the **time-to-event treatment-related outcomes** (TTNT, TTD, OS).
It is an analysis set, not a cohort: a flag, not a step in the attrition
funnel, or the descriptive denominators for Primary Objectives 1-3 would be
wrong.

"Potential follow-up" is time in the database, not observed enrolment.
`tte_eligible_sql()` (`R/windows.R`) writes `S_PERIODS.TTE_ELIGIBLE` = 1 where
index + `TTE_MIN_POTENTIAL_FU_DAYS` (90, built by the same `MONTHS_AS` rule as
every month window) falls on or before `STUDY_END`, or the patient died before
that date. `S_TTE` keeps every cohort row with the flag beside it; the
restricted analysis is the rows where `TTE_ELIGIBLE = 1`. The
potential-follow-up reading is not yet an open question (`CONFORMANCE.md`,
`OUT-TTE-ANALYSIS-SET`).

---

## 8. The order to apply them

The protocol does not prescribe an order. This one keeps every count
reproducible and is the order the funnels are written in.

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

Steps 9-13 need the LOT build to have run. Steps 0-8 do not.

The secondary 2L cohort repeats steps 0-8 with the index at 2L ≥ 01 Jan 2020 and,
on the reading above, step 7 dropped.

Which build writes which part of the funnel, and what `S_ATTRITION` records, is
`IE_CRITERIA_APPLIED.md` §3.

---

## 9. What the source does not contain

| what | status |
|---|---|
| **Annex 2** — eligible/expected MM therapies and SOC regimen categorisation | outstanding |
| **Annex 3** — ICD-10-CM code lists for the key safety events | outstanding |
| **Annex 4-5** — table shells and figures | outstanding |
| **Annex 6** — the LOT algorithm | outstanding |
| **Annex 7** — the claims-based frailty (Kim CFI) algorithm | outstanding |
| Table 4 rows for the rest of Primary Objective 1 and the head of Primary Objective 2 | not legible — `VARIABLES.md` §4 |

Annex numbers above follow the **body text**, which cites Annex 3 for code lists
and Annex 4-5 for shells; the Table of Contents numbers them differently (Q20).

**Ask the study team for Annexes 2, 3, 6 and 7, and for the Table 4 rows**
(Q15). Annexes 2 and 3 are code lists — nothing that depends on them can be
built without them.
