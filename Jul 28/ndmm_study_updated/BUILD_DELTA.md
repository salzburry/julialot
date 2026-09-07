# What the existing build has to change

The `Jul 28/` delivery already builds an NDMM 1L cohort, 2L and 3L cohorts, and a
lines-of-therapy assignment. This file is the difference between what it does today
and what the Aug 26 2026 protocol asks for — nothing else.

Read with `IE_CRITERIA.md` (the rules) and `DATA_MAPPING.md` (the fields).

Legend: **matches** · **change** · **new** · **decide first** (blocked on
`OPEN_QUESTIONS.md`).

---

## 1. Settings

| setting | today | protocol | verdict |
|---|---|---|---|
| `STUDY_START` | `2016-01-01` | body text says 01 Jan 2018; Figures 1 and 2 say 01 Jan 2016 | **decide first** — Q1 |
| `STUDY_END` | `2026-03-31` | 31 Mar 2026 | **matches** |
| `LOT1_FROM` | `2017-01-01` | 1L initiation **≥ 01 Jan 2019** | **change** |
| `PRE_LOT1_DAYS` | `365` | 12 months | **matches** |
| `SUBSEQ_PRE_DAYS` | `365` | 12 months before the 2L/3L index | **matches** |
| `GAP_DAYS` | `30` | gaps ≤ 30 days are continuous | **matches** |
| `OUTPATIENT_WINDOW` | `90` | 2 outpatient claims within 90 days | **matches** |
| `MIN_AGE` | `18` | ≥ 18 at MM diagnosis, calendar year | **matches** |
| `FU_CE_DAYS` | `0` (index date itself enrolled) | "at least one claim (pharmacy or medical) from index date or death" | **change** — see §2 |
| `SUBSEQ_FU_CE_DAYS` | `90` gap-free enrolment after 2L/3L | the protocol's per-cohort follow-up test is the same one-claim test; the 90-day rule it does state is an **analysis-set** restriction on TTE outcomes | **change** — see §2 |
| `CENSOR_AT_DISENROLLMENT` | `FALSE` | follow-up ends at "end of continuous enrollment or end of study period or death, whichever occurs first" | **change** — see §4 |
| `MAX_LOT` | `5` | 1L-4L needed (no 4L cohort, but a 4L start date and regimen) | **matches** |
| `INDUCTION_WINDOW_DAYS` | `60` | "1L is defined as any pre-specified MM therapies received within 60 days of the 1L start date" | **matches** |
| `INDUCTION_WINDOW_DAYS_LOT_N` | `30` | "Each subsequent LOT includes all MM therapies received within 30 days on and following the LOT start date" | **matches** |
| `NDMM_INDEX_EXCLUDED_ABBRS` | empty | panobinostat and elotuzumab may not set the 1L index | **change** |
| `APPLY_NO_BELANTAMAB` | `TRUE` | "Received belantamab mafodotin in any LOT" excludes | **matches** |

## 2. Follow-up: three different tests, currently conflated

The build has one follow-up concept per cohort. The protocol has three, and they are
not the same thing.

| protocol concept | where | test | build today |
|---|---|---|---|
| **Evidence of follow-up** (eligibility) | §7.2.1.1 | ≥ 1 medical or pharmacy claim from the index date, or death | 1L: enrolled on the index date (`FU_CE_DAYS=0`). 2L/3L: 90 days of gap-free enrolment or death (`SUBSEQ_FU_CE_DAYS=90`) |
| **Follow-up period** (the observation window) | §7.1 | index → min(end of CE, study end, death) | `ENDDATE = least(study_end, DEATH_DT)` — **end of CE is not applied** |
| **≥ 3 months potential follow-up** (analysis set for TTNT/TTD/OS) | §7.8.2 | `index + 90 ≤ study end`, or death before `index + 90` | not implemented |

What to build:

- replace the 1L `FU_CE_DAYS=0` test and the 2L/3L `SUBSEQ_FU_CE_DAYS=90` test with
  the single **one-claim-or-death** test, applied identically to all cohorts;
- add `FU_END = least(cov_end_of_the_index_span, study_end, DEATH_DT)` as a column on
  every cohort table;
- add a `TTE_ELIGIBLE` flag for the ≥ 3-month rule — **a flag, not a filter**, or the
  Objective 1-3 denominators shift.

The 90-day number does not disappear; it moves from eligibility to the analysis set,
and it becomes a **potential**-follow-up test (calendar time in the database) rather
than an **observed**-enrolment test. On a rough reading that makes the 2L and 3L
cohorts larger than they are today.

## 3. Criteria

| criterion | today | protocol | verdict |
|---|---|---|---|
| MM diagnosis (I1) | one code list for both arms, plus a strict `203.0x`/`C90.0x` requirement on the inpatient arm; 90-day outpatient pairing | strict on the inpatient arm; outpatient arm says only "medical claims for MM" | **decide first** — Q2 |
| Age (I2) | `year(MM_DX_DT) - YRDOB >= 18`, applied to the **earliest** qualifying date | ≥ 18 at MM diagnosis by calendar year | **matches** |
| Eligible 1L treatment (I3) | first non-steroid MM agent on/after diagnosis and on/after `LOT1_FROM`, belantamab barred | same, plus panobinostat and elotuzumab barred, and `LOT1_FROM = 2019-01-01` | **change** |
| 12-month CE (I4) | own spans from `member_enrollment`, gaps ≤ 30 d | same, plus "with medical and pharmacy benefits" | **decide first** — Q4 |
| Follow-up (I5) | see §2 | see §2 | **change** |
| Prior MM therapy (X1) | any MM agent in the 365-day baseline, **steroids dropped** | "≥ 1 medical or pharmacy claim for any MM oncology therapy" — no steroid carve-out stated | **decide first** — Q6 |
| Other cancer (X2) | ≥ 1 inpatient, or 2 outpatient claims **both inside the 365-day baseline**, paired on ICD category | ≥ 1 inpatient, or ≥ 2 outpatient **on separate days within 30 days**, same primary tumour type and/or metastatic | **change** — the 30-day window is new |
| Pregnancy (X3) | diagnosis and procedure codes, whole study period | diagnosis, procedure **or revenue** code, whole study period | **change** — add revenue codes |
| Belantamab (X4) | flag computed in the cohort build, exclusion applied in the LOT build once lines exist | "in any LOT" | **matches** |
| 2L/3L: received the line (N1) | a LOT 2 / LOT 3 row exists | same | **matches** |
| 2L/3L: 12-month CE (N2) | `SUBSEQ_PRE_DAYS=365`, gaps ≤ 30 d | same | **matches** |
| 2L/3L: follow-up (N3) | 90 days gap-free enrolment or death | one claim from index | **change** — see §2 |

## 4. Follow-up end and disenrollment

`Jul 28/lot/LOT_RULES.md` §7.6 says **"Disenrollment is not censoring"**, and
`CENSOR_AT_DISENROLLMENT=FALSE` is the primary-analysis setting. The protocol's §7.1
says the follow-up period runs "until the **end of continuous enrollment** or end of
study period or death, whichever occurs first".

These are opposite. Every time-to-event estimate depends on which one holds:
TTNT, TTD and OS all censor "at their follow-up end date", and that date is
different under each rule.

The engine already has the switch. Flipping it is a one-line config change plus a
rerun; deciding to flip it is not. `OPEN_QUESTIONS.md` Q13.

## 5. The LOT engine

Broadly aligned. The protocol's LOT text is a summary of the same GSK algorithm the
engine implements (it cites *"Development of line of therapy rules in multiple
myeloma: Optum Claims (Study no: 219870)"*, which is the Domino project the code
lists come from).

| protocol statement | engine | verdict |
|---|---|---|
| 1L = therapies within 60 days of the 1L start | `induction_window_days = 60` (§3.2) | **matches** |
| 2L+ starts at the earliest of: allogeneic SCT, **unplanned** autologous SCT, CAR-T, or a new agent not in the previous regimen | §4.1 "a later line opens on the earliest of four candidates"; §3.4 line 1's first autologous transplant never ends line 1; §6.3 a second AUTO within 180 days is a planned tandem | **matches**, with the engine supplying the operational meaning of "unplanned" |
| Subsequent LOT includes therapies within 30 days on and following the start | `lot_n_induction_window_days = 30` (§4.2) | **matches** |
| Discontinuation = all MM agents stopped, or a new agent / qualifying SCT introduced | §5.1-§5.3 (90-day run-out, 90-day confirmation), §7.1-§7.5 | **matches in substance**; the engine's 90-day run-out and 90-day confirmation are operational detail the protocol does not state |
| 4L start date and 4L regimen, no 4L cohort | `max_lot = 5` | **matches** |
| — | §4.3 own-return fold, §4.7 melphalan short course, §4.8 MAP fold-in | **not stated in the protocol.** These are study-team refinements agreed 15-30 Aug 2026 (`Jul 28/STUDY_TEAM_ASKS.md`). They are compatible with "a new MM agent that was not part of the previous LOT regimen" but they are not derivable from it — reconfirm they are still wanted, and get them into Annex 6 |

## 6. What is entirely new

| # | what | why |
|---|---|---|
| 1 | **Secondary 2L cohort** — non-nested, index = 2L initiation ≥ 01 Jan 2020, prior malignancy permitted, 1L may fall outside the primary ascertainment period | §7.4. No equivalent exists |
| 2 | **Demographics**: race, ethnicity, region, insurance type | Table 4. Nothing in the repo reads `RACE`, `ETHNICITY`, `REGION`/`STATE` or `BUS` today — grep confirms zero references |
| 3 | **Charlson Comorbidity Index (Quan 2011)**, MM-adjusted | Table 4 |
| 4 | **Kim Frailty Index** | Table 4, Table 1 row 4 — pending feasibility |
| 5 | **22 key safety events**, at baseline and during each LOT treatment period | Table 3, Objectives 1 and 2 |
| 6 | **Person-time denominators** — baseline PY and PY at risk, with the chronic/acute rules | §7.8.1 |
| 7 | **Healthcare utilisation** — all-cause hospitalisation, MM-related hospitalisation (MM dx in position 1 or 2), LOS, ED visits | §7.3.2, §7.8.1 |
| 8 | **Secondary malignancies** — 10 categories, confirmed by ≥ 2 diagnosis codes on separate dates, dated at the first | §7.2.4, Objective 3 |
| 9 | **SOC regimen categorisation** and the Sankey between categories | §7.2.2, Table 5 |
| 10 | **TTNT / TTD / OS** with Kaplan-Meier, Brookmeyer-Crowley 95% CI, landmark survival at 6/9/12/18/24 months | §7.8.2 |
| 11 | **Treatment attrition** across 1L → 4L | Table 5 |
| 12 | **Subgroup machinery** — SOC, age ≥ 75, neuropathy, frailty, with the **< 25 patients** suppression rule | §7.2.3, §7.8 |
| 13 | **`TTE_ELIGIBLE`** flag (≥ 3 months potential follow-up) | §7.8.2 |

`Jul 28/analysis/outcomes/` is the natural home for 5-11; the cohort build owns 1-4
and 13.

## 7. The counting rules that will bite

These are stated once, in §7.8.1, and are easy to lose:

1. **Multiple claims on the same day are one event; claims more than 1 day apart are
   distinct events** (baseline prevalence).
2. **Acute events need a ≥ 30-day washout** between events of the same type.
3. **Chronic conditions are counted once, at first instance**, and a patient with the
   condition before the treatment period is **removed from both the numerator and the
   person-time denominator** for it. Named explicitly: chronic kidney disease,
   moderate-to-severe renal impairment or ESRD, pulmonary hypertension, peripheral
   neuropathy, Parkinson's disease, other movement disorders, malignancies,
   thrombocytopenia, anaemia.
4. **A hospitalisation due to a chronic condition is treated as an acute event** and
   may be counted more than once.
5. **Hospitalisations are assigned by admit date**, whichever period the discharge
   falls in. `LOS` runs admit (included) to discharge (**excluded**).
6. **Hospitalisations with no discharge date** count towards patient and event counts
   but are excluded from LOS summaries.
7. An event belongs to a LOT if it falls in
   `[LOT start, min(next LOT start − 1, discontinuation + 30 days)]`. Beyond
   discontinuation + 30 days it is **not counted at all**, even if a later LOT starts.
8. **Baseline characteristics are taken at the index date where possible; if missing
   at index, the value nearest the index within the baseline is used. Comorbidities
   are assessed over the 12-month baseline including the index date** — which
   contradicts §7.1's "does not include index date". `OPEN_QUESTIONS.md` Q14.
9. Rates are per person-year, scaled per 10,000 or 100,000.
10. **< 25 patients in a stratification ⇒ no analysis** (unless SOC-specific).
11. No imputation. Missing values are reported and dropped where necessary.
12. No p-values, no log-rank, no hypothesis tests anywhere.

## 8. Suggested order of work

1. Settle Q1, Q2, Q4, Q6, Q13 with the study team — each changes a count.
2. Get Annexes 2, 3 and 7, and document pages 31-32.
3. Cohort build: `LOT1_FROM`, the index-agent exclusions, the 30-day other-cancer
   window, the follow-up rework (§2), `FU_END`, `TTE_ELIGIBLE`, and the four new
   demographic columns.
4. Secondary 2L cohort as a fifth build target.
5. Code lists (`CODELISTS.md` §4) — the long pole, and blocked on Annex 3.
6. Outcomes package: baseline prevalence, incidence with person-time, HCRU,
   secondary malignancies, TTNT/TTD/OS.
7. Subgroups and SOC categorisation.
