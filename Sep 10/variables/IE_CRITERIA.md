# Inclusion / exclusion criteria — GSK 223926 (Aug 26 2026 protocol)

Every eligibility rule the updated protocol states, in the order a build would
apply it, with what each one needs from Optum and what is still ambiguous.

Source: the GSK **223926** protocol, effective **26 August 2026**. The criteria are
in §7.1, §7.2, §7.2.1.1, §7.2.1.2 and §7.4.1.1; each rule below cites its section.
Quoted text is verbatim.

`DATA_MAPPING.md` turns each rule into tables and columns. `BUILD_DELTA.md` says
what the cohort build has to change to apply them.

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

The build reads every "months" window as a fixed day count — 12 months is
`[index − 365, index − 1]`, 3 months is 90 days — because `add_months()` would give two
patients indexed a day apart different windows. The protocol says "12-month" and
"3 months" and never disambiguates, so the reading is still open; the 1L sensitivity put
it seven patients from the calendar-month reading (`OPEN_QUESTIONS.md` Q21).

Two things about the baseline period that decide how the build is wired:

> "1L will have a 12-month baseline relative to 1L start, and 2L will have a
> 12-month baseline period relative to 2L start. **Only the 1L baseline period will
> be used to assess study eligibility.**" — §7.2

> "The baseline periods for 2L and 3L may overlap with time on a prior LOT,
> depending on the dates of treatment." — Figure 1 note [3]

So the 2L and 3L 12-month baselines are **descriptive windows**, not eligibility
windows — except for the continuous-enrolment requirement, which §7.2.1.1 does
restate for each cohort.

> **Contradiction in the source.** The body text says the study period starts
> 01 Jan 2018. Figure 1 and Figure 2 are both labelled
> "Study start 01 Jan 2016". See `OPEN_QUESTIONS.md` Q1.

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

These match the engine in `../lot/` on the induction windows (60 / 30 days) and
on what opens a line. See `BUILD_DELTA.md` §3 for the points where they do not.

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

Operationally:

- inpatient arm: ≥ 1 inpatient claim, MM code **in any diagnosis position**, code set 203.0x / C90.0x
- outpatient arm: ≥ 2 outpatient claims, MM code in any position, **different service dates**, **≤ 90 days apart**
- the diagnosis date used downstream is the **first** qualifying MM claim (see V-`MM_DX_DT` in `VARIABLES.md`)

> **Ambiguity.** The strict code set (203.0x / C90.0x) is written against the
> inpatient arm; the outpatient arm says only "medical claims for MM". The deployed
> `mm_dx.csv` holds exactly eight codes — 203.0, 203.00, 203.01, 203.02, C90.0,
> C90.00, C90.01, C90.02 — matched by **equality on the normalised code, not by
> prefix**, so it covers the strict families and nothing else (`CODELISTS.md` §1). The
> alternative reading is the **broad** set (ICD-9 203.x / ICD-10 C90.x) on the
> outpatient arm with the inpatient arm left strict. The cohort build applies **one**
> code list to both arms and additionally requires the strict subset on the inpatient
> arm. See `OPEN_QUESTIONS.md` Q2.

> **Ambiguity.** "within 90 days" — 30- and 60-day pairs have also been raised as
> sensitivities; the protocol names only 90. See `OPEN_QUESTIONS.md` Q3. Do not let the
> 30 days of the other-cancer rule migrate onto this window: they are different numbers
> on different criteria.

### I2. Adult age

> "Aged **≥ 18 years** at the time of MM diagnosis **according to calendar year**"

Calendar-year arithmetic: `year(MM_DX_DT) − YRDOB`, not a birthday. Optum carries
year of birth only (`YRDOB`), capped at 89 in CDM V9.0, so a "90+" patient reads as 89.

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

> **Gap.** Annex 2 — the eligible/expected MM therapy list and the SOC regimen
> categorisation — is still **outstanding**. `cl_mma_codelist.csv` and
> `cl_mma_rollup.csv` are the nearest existing equivalent. See `CODELISTS.md` §1.

> **Change from the current build.** The cohort build bars only belantamab from setting
> the index (`NDMM_INDEX_EXCLUDED_ABBRS` defaults to empty) and keeps no allowlist of
> first-line regimens, deliberately: inventing one would shrink the cohort by a rule
> nobody could reproduce. The protocol now supplies the rule, so the two named agents go
> into `NDMM_INDEX_EXCLUDED_ABBRS`, which validates every entry against the code list and
> stops the run on a name matching nothing.
> `<prefix>NDMM_INDEX_AGENTS` says in advance what barring each one costs.

### I4. Continuous enrolment before index

> "CE of at least **12-months** with **medical and pharmacy benefits** before the 1L
> cohort index date. Patients with gaps in enrolment of **≤ 30 days** are considered
> to be continuously enrolled"

Two parts, and the second is the one the current build does not do: the protocol
requires **both** benefit types. Optum CDM V9.0 as deployed carries no per-benefit
flag on `MEMBER_ENROLLMENT` (see `DATA_MAPPING.md` §4), and §7.5 of the protocol
itself says "**All patients in this database have both medical and pharmacy
coverage**" — which, if taken at face value, makes the requirement
automatically satisfied. See `OPEN_QUESTIONS.md` Q4.

### I5. Evidence of follow-up

> "at least one claim (pharmacy or medical) **from index date** or death"

and, restated per cohort:

> "**CE during follow-up for each cohort:** at least one claim (pharmacy or medical)
> from index date" — §7.2.1.1

This is a claims-presence test, not an enrolment-span test. The index claim itself
is a medical or pharmacy claim, so on a literal reading every indexed patient passes
it. See `OPEN_QUESTIONS.md` Q5.

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

---

## 6. Exclusion criteria — applied on the 1L baseline

§7.2.1.2. All four are transcribed in full.

### X1. MM oncology therapy in the 12-month 1L baseline

> "**Evidence of an MM oncology therapy during the 12-month 1L baseline period:**
> ≥ 1 medical or pharmacy claim for any MM oncology therapy
> - This is to ensure that treatment exposure and LOT assignments reflect incident
>   therapy starts at the index date and are not confounded by ongoing or recent
>   prior MM treatments"

This is the "newly treated" criterion. Note it says **any MM oncology therapy** —
wider than the eligible-1L list of I3, and it is a *medical or pharmacy* claim, so
both J-code administration and pharmacy fill count.

> **Note.** The cohort build drops steroid rows from this scan (`NDMM_STEROID_ABBRS`),
> on the reasoning that a steroid claim alone is supportive care. The protocol does not
> say so, but the drop **removes nothing on today's code list**: of the 26 agents on
> `cl_mma_codelist.csv`, none is spelled `DEX`, `DEXA`, `DEXAMETHASONE`, `PRED` or
> `PREDNISONE`, so the guard fires on no one. It becomes a real decision when Annex 2's
> therapy list arrives. `OPEN_QUESTIONS.md` Q6.

### X2. Another cancer in the 1L baseline

> "**Evidence of another cancer in the 1L baseline period:** Patients with either
> **≥ 1 inpatient or ≥ 2 outpatient** ICD-9-CM or ICD-10-CM codes **on separate days,
> within 30 days**, for the **same primary tumor type and/or metastatic cancer** will be
> excluded"

The cohort build already implements all four parts of this: `diff_days <= 30` on
outpatient pairs built from **distinct dates**, one inpatient claim sufficient on its
own, and pairing per tumour group. The 30 is **hard-coded** there, not a config key.

What the build layers on top, each of which the study team should confirm rather than
inherit:

| # | the build's reading | why | effect |
|---|---|---|---|
| 1 | **Both** claims of a pair must fall inside `[index−365, index−1]` | the criterion is another cancer **in** the 1L baseline, and the source bounded only the first claim | cohort **larger** — a pair straddling the index no longer excludes |
| 2 | Pairs match on the **first three characters of the ICD code**, not on `tumor_group` | `other_malig.csv` has 1,643 codes and 1,618 distinct `tumor_group` values, so the label is one per code — pairing on it would reduce to needing the identical code twice | cohort **smaller** — claims that never paired now do |
| 3 | Metastatic codes collapse into a single `MET` group — `C77`, `C78`, `C79`, `C7B`, `C800` and ICD-9 `196`, `197`, `198`, `1990` (**not** `C80`, `199`) | "and/or metastatic cancer" is one concept | — |
| 4 | **Bone metastasis excludes.** `C79.51`, `C79.52` and `198.5` are metastatic cancers and are kept in | myeloma bone disease is commonly coded `C79.51`, so some patients removed by this will be MM patients whose lesions were coded as metastases; the decision is that the stated rule governs | cohort **smaller**, and some of the loss is myeloma miscoded |
| 5 | Plasma-cell disorders and monoclonal gammopathy do **not** count as another cancer (`NDMM_MM_ADJACENT_OVERRIDE`), and six state-coded labels are still open | they are the index disease showing itself | — |

Reading 4 is the one to put to the study team first: it is a known, deliberate,
count-moving trade against a real risk of dropping myeloma patients.

Also note the two windows are different numbers and must not be conflated: the
other-cancer pairing window is **30 days**, the MM-diagnosis outpatient pairing window
is **90** (`OUTPATIENT_WINDOW`).

### X3. Pregnancy or childbirth

> "**Evidence of pregnancy:** ≥ 1 of medical claim with a **diagnosis, procedure, or
> revenue code** indicating pregnancy or childbirth **during the study period**"

Three code types, not one, and the window is the **whole study period**, not the
baseline. The cohort build already does all of this: it applies the rule
study-period-wide and its scan admits `ICD9DIAG, ICD10DIAG, ICD9PROC, ICD10PROC,
HCPCS, REV` (`NDMM_PREG_CODE_TYPES`). The production `pregnancy.csv` carries all six
types — 3,049 `ICD9DIAG`, 1,549 `ICD10DIAG`, 447 `ICD9PROC`, 69 `ICD10PROC`, 185
`HCPCS` and 19 `REV`, 5,318 codes in all. **No change needed.**

The open item is the *window*, not the codes: the narrower patient-specific reading is
still undecided (`OPEN_QUESTIONS.md` Q23). The protocol says "during the study period";
the build applies that.

### X4. Belantamab mafodotin in any LOT

> "**Received belantamab mafodotin (i.e., an ADC) in any LOT**
> - Note: at the time of study belantamab mafodotin was the only ADC in use for MM"

"In any LOT" means this cannot be evaluated before lines exist. The current build
already handles it this way: the flag is computed over the whole study period in the
cohort build and the exclusion is applied in `../lot/engine/R/line_criteria.R` once LOT
membership is known (`../lot/LOT_RULES.md` §8).

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
cannot tabulate prior malignancies in a cohort that excluded them. See
`OPEN_QUESTIONS.md` Q7.

Also from §7.4.1.1: the index is 2L initiation ≥ 01 Jan 2020 "irrespective of
whether their 1L initiation occurred during the primary cohort ascertainment
period", so this cohort reaches patients whose 1L falls before 01 Jan 2019.

---

## 7a. The analysis-set restriction that is not an eligibility criterion

§7.8.2, adds a restriction that never appears in §7.2.1 and is easy to
miss:

> "Outcomes will only be assessed in the subset of patients who have **≥ 3 months of
> potential follow-up (or die before 3 months) from their index date** to ensure
> adequate time in the database for outcome assessments."

This is scoped to the **time-to-event treatment-related outcomes** (TTNT, TTD, OS).
It is an analysis set, not a cohort: it must be a flag on the cohort table
(`TTE_ELIGIBLE`), not a filter in the attrition funnel, or the descriptive
denominators for Primary Objectives 1-3 will be wrong.

"Potential follow-up" is time in the database, not observed enrolment — so
`index + 90 days ≤ study end`, OR death before `index + 90 days`. Note this is a
weaker test than the current 2L/3L rule, which requires 90 days of gap-free
**enrolment** (`SUBSEQ_FU_CE_DAYS = 90`). See `BUILD_DELTA.md` §2.

---

## 8. The order to apply them, and the attrition table

The protocol does not prescribe an order. This one keeps every count reproducible
and matches the funnel the current build already writes.

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

### What `S_ATTRITION` writes, and the steps above it

Steps 0-8 are the **cohort build's** funnel: it applies I1 to X3 and writes its
own attrition. `S_ATTRITION` is this package's, and it begins where the cohort
build's ends — so its first rows say what stood between the two, which is not
nothing.

| criterion | applied by | what it counts |
|---|---|---|
| `indexed_at_line` | `lot` | patients on the input with a line at this line number, from `LOT_LONG_ALLFLAGS` — every line the engine built, before its own criteria |
| `lot_line_criteria` | `lot` | the same patients after them. The difference is the engine's removals, of which **X4** — belantamab in any LOT — is one |
| each of the cohort's own | `cohort`, `here`, or both | as the table above |

Two things follow from this that are easy to get wrong.

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

---

## 9. What the source does not contain

| what | where it should be | status |
|---|---|---|
| Table 4 rows between "Types of 1L, 2L, 3L SOCs or classes by line" and the Primary Objective 3 block | §7.3, Table 4 | not available |
| **Annex 2** — eligible/expected MM therapies and SOC regimen categorisation | the annexes | outstanding |
| **Annex 3** — ICD-10-CM code lists for the key safety events | the annexes | outstanding |
| **Annex 4-5** — table shells and figures | the annexes | outstanding |
| **Annex 6** — the LOT algorithm | the annexes | outstanding |
| **Annex 7** — the claims-based frailty (Kim CFI) algorithm | the annexes | outstanding |

Annex numbers above follow the **body text**, which cites Annex 3 for code lists and
Annex 4-5 for shells. The protocol's Table of Contents disagrees with its own Annex 1
and says 3 = TABLES, 4 = FIGURES, 5 = CODELISTS. `OPEN_QUESTIONS.md` Q20.

The missing rows sit between the end of Primary Objective 1's baseline block and the
"*per GSK LoT algorithm definition*" footnote that opens Primary Objective 2's rows, so
what is absent is the tail of Primary Objective 1 (baseline prevalence of key safety
events and baseline healthcare utilisation) and the head of Primary Objective 2 (its
incidence rows and the LOT treatment-period definition). Their shape is recoverable from
the surrounding rows; their exact wording is not. `VERSION_DIFF.md` §3 reconstructs them
from the June 2026 version and says what has certainly changed since.

**Ask the study team for Annexes 2, 3, 6 and 7, and for the missing Table 4 rows.**
Annexes 2 and 3 are code lists — nothing can be built without them.
