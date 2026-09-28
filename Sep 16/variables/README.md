# NDMM study 223926

Stage 3 of the study pipeline: the study package that turns the cohort (`ndmm/`)
and a finished lines-of-therapy run (`lot/`) into the study's cohorts, its
variables and the released `S_*` tables. `CONTENTS.md` says what is in this
folder, where to start and how to run it.

## The protocol

| | |
|---|---|
| GSK study | **223926** · asset GSK2857916, Belantamab Mafodotin (Blenrep) |
| title | *Unmet Needs and Rates of Key Background Safety Events of Interest Relating to Treatment Use among Newly Treated and Relapsed/Refractory Patients with Multiple Myeloma* |
| accountable | Epidemiology, Oncology |
| classification | Non-PASS · Tier 2 · secondary data collection · no safety objective |
| data source | Optum Clinformatics Data Mart (CDM) |
| classification marking | Critical and Sensitive Information (CSI) |
| study period | 01 Jan 2018 → 31 Mar 2026 (`OPEN_QUESTIONS.md` Q1) |

## The cohorts

| cohort | who | index | eligibility |
|---|---|---|---|
| 1L (NDMM) | all patients initiating 1L therapy | 1L start, ≥ 01 Jan 2019 | I1-I5, X1-X4 |
| 2L (RRMM) | nested subset initiating 2L | 2L start | + received 2L, 12-month CE before it |
| 3L (RRMM) | nested subset initiating 3L | 3L start | + received 3L, 12-month CE before it |
| Secondary 2L (RRMM) | **not nested** - all 2L initiators | 2L start, ≥ 01 Jan 2020 | same as 1L except the index, and prior malignancy is permitted |

There is no 4L cohort - only a 4L start date and 4L regimen. Expected sizes from
the protocol's own feasibility count: **10,514** 1L, **5,179** 2L,
**3,127** 3L, before study criteria are applied.

The rules are quoted in `IE_CRITERIA.md`; which of them this package applies,
and how to change one, is `IE_CRITERIA_APPLIED.md`. The secondary 2L cohort
cannot be built from the shipped cohort table: it needs a wide cohort input
(`MODULES.md` "The secondary 2L cohort needs a wide input"). Cohort settings
are changed on the cohort side, in `../ndmm/README.md` "Settings".

## What the protocol does not yet specify

Annexes 2 to 7 are stand-alone documents and none has been issued: the SOC
regimen categorisation (Annex 2), the outcome code lists (Annex 3), the table
and figure shells (Annexes 4 and 5), the LOT algorithm (Annex 6) and the
claims-based frailty algorithm (Annex 7). **Annexes 2 and 3 are code lists -
the SOC, safety, HCRU and malignancy outcomes cannot be computed without
them.** `CODELISTS.md` §5 has the exact ask; `OPEN_QUESTIONS.md` Q15 lists what
is outstanding, including the incomplete Table 4 rows for Primary Objectives 1
and 2.

The protocol's contents list and its Annex 1 disagree about the annex numbers.
This folder follows the body text, which agrees with Annex 1: Annex 3 is the
code lists, Annexes 4 and 5 the shells (`OPEN_QUESTIONS.md` Q20).

## The five things most likely to change a count

1. **Disenrollment censors follow-up** on the protocol's wording
   (`CENSOR_AT_DISENROLLMENT=TRUE`, this package's default); the LOT engine's
   primary reading does not censor (`OPEN_QUESTIONS.md` Q13).
2. **Which route makes a hospitalisation MM-related** - the two readings differ
   by a factor of two (`OPEN_QUESTIONS.md` Q27).
3. **The outpatient MM diagnosis code set** - strict or broad
   (`OPEN_QUESTIONS.md` Q2).
4. **How an emergency visit is identified** - the three claims constructions
   differ by 37% (`OPEN_QUESTIONS.md` Q11).
5. **Bone metastasis still excludes** - `C79.51` is a metastatic cancer to the
   rule and myeloma bone disease to a haematologist. The build knows and
   excludes anyway (`IE_CRITERIA.md` §6).

Follow-up is three different tests - an eligibility test (I5), an observation
window, and a ≥ 3-month analysis-set restriction on the time-to-event
outcomes. This package applies all three (`IE_CRITERIA.md` §2, I5 and §7a).

`OPEN_QUESTIONS.md` "What each decision is worth" ranks every open reading by
what it moves.

## Mapping to Optum

`DATA_MAPPING.md` turns each rule and variable into Optum CDM tables and
columns, and records where the deployed extract differs from the published
dictionary. The difference that matters most is `MEMBER_ENROLLMENT`: it carries
`STATE` and no `REGION`, so region is derived through a state crosswalk
(`OPEN_QUESTIONS.md` Q9).
