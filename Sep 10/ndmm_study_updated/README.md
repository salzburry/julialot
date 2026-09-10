# NDMM study — updated protocol, read and mapped

This folder turns the updated NDMM protocol into something a build can be written
from: the eligibility criteria, the variables, the Optum CDM mapping for each of
them, and the list of things still to be decided or sent.

**Scope: this folder only.** `Jul 28/ndmm/` and `Sep 10/lot/` are not edited by
this work. Where the protocol needs the cohort or LOT build to behave
differently, that is delivered as an environment override on a re-run of those
builds, never as a change to them — `BUILD_DELTA.md` section 0 lists every one
and shows it is already read from the environment.

## The protocol

| | |
|---|---|
| document | `Belantamab_Optum LoT_Unmet_Need_Aug 26 2026 (final).docx` |
| GSK study | **223926** · asset GSK2857916, Belantamab Mafodotin (Blenrep) |
| title | *Unmet Needs and Rates of Key Background Safety Events of Interest Relating to Treatment Use among Newly Treated and Relapsed/Refractory Patients with Multiple Myeloma* |
| accountable | Ashley Holub, Director Epidemiology, Oncology |
| effective | 26 August 2026 |
| classification | Non-PASS · Tier 2 · secondary data collection · no safety objective |
| data source | Optum Clinformatics Data Mart (CDM) |
| classification marking | Critical and Sensitive Information (CSI) |

## Files

`CONTENTS.md` lists every file in this folder and what each is for. Read
`IE_CRITERIA.md` first; `IE_CRITERIA_APPLIED.md` says which of its rules this
build applies and how to change one. `OPEN_QUESTIONS.md` is what to send the
study team.

## The cohorts, in one table

| cohort | who | index | eligibility |
|---|---|---|---|
| 1L (NDMM) | all patients initiating 1L therapy | 1L start, ≥ 01 Jan 2019 | I1-I5, X1-X4 |
| 2L (RRMM) | nested subset initiating 2L | 2L start | + received 2L, 12-month CE before it |
| 3L (RRMM) | nested subset initiating 3L | 3L start | + received 3L, 12-month CE before it |
| Secondary 2L (RRMM) | **not nested** — all 2L initiators | 2L start, ≥ 01 Jan 2020 | same as 1L except the index, and prior malignancy is permitted |

There is no 4L cohort — only a 4L start date and 4L regimen. Expected sizes from the
protocol's own feasibility count (August 2026): **10,514** 1L, **5,179** 2L,
**3,127** 3L, before study criteria are applied.

## What the source does not cover

The protocol runs to 64 pages. Two stretches are not available.

1. **Pages 31-32** — unreadable in the copy supplied. They carry the tail of
   Table 4's Primary Objective 1 rows and most of Primary Objective 2's.
2. **Pages 59-64** — not supplied. These are the bodies of **Annexes 2-7**: the
   SOC regimen categorisation, the outcome code lists, the table and figure
   shells, the LOT algorithm, and the claims-based frailty algorithm.

Annex 1 (page 57) lists all seven annexes, so the inventory is known even though the
contents are not. **Annexes 2 and 3 are code lists — nothing can be built without
them.** See `CODELISTS.md` §5 for the exact ask.

> The protocol's **Table of Contents and its own Annex 1 disagree about the annex
> numbers.** The ToC (page 6) reads: 3 TABLES, 4 FIGURES, 5 CODELISTS. Annex 1's table
> (page 57) reads: 3 Codelists to define study outcomes, 4 Main study table shells,
> 5 Main study figures. The body text agrees with Annex 1 — §7.3.2 and §7.8.5 both cite
> **Annex 3** for code lists, and §7.8 cites *"Annex 4 and Annex 5"* for table and
> figure shells. **This folder uses the body's numbering.** The ToC also spells them
> "ALGORITHIM" and "FRAILITY". `OPEN_QUESTIONS.md` Q20.

## Optum documentation reviewed

| document | what it is | pages read |
|---|---|---|
| the Optum CDM V9.0 data dictionary | Clinformatics Data Mart Data Dictionary, **CDM V9.0** (SES view) — TITLE NOTES, MEMBER_CONTINUOUS_ENROLLMENT, MEMBER_ENROLLMENT, MEDICAL, MED_DIAGNOSIS, MED_PROCEDURE, CONFINEMENT, RX, LABRESULT, PROVIDER, PROVIDER BRIDGE, SES, LU_DIAGNOSIS, LU_NDC, LU_PROCEDURE | 24 / 24 |
| the Optum business rules document | `Final_Business rule doc_OPTUM_V1_30_08_2022.xlsx` — the join diagram, the table inventory, and 14 numbered rules | 7 / 7 |
| the Optum enrolment documentation | Databricks `describe table hive_metastore.clnprw_optum.t_member_enrollment_2025q4` (all 27 columns) and the observed `BUS` / `CDHP` / `PRODUCT` distributions in the MM population | 4 / 4 |
| `docs/Part 3/Program Spec/*_validated.csv` | the Jan-2026 program spec, whose "Optum CDM Implementation" column names the tables and columns used per variable | all |

The copies under `Apr 18 2026/Optum - Business Rules/` are byte-identical to the
Part 3 copies — the April folder introduced no revision.

`Jul 28/ndmm/DECISIONS.md` and `Jul 28/ndmm/README.md` were read in full as well. The
existing cohort build has already profiled the warehouse, and its §6 answers two things
the vendor documents leave open: that medical and pharmacy benefits are satisfied by
construction (no predicate to write, and the claims proxy is a trap), and that
`MED_PROCEDURE.PROC` is the ICD procedure code — 43.1M of 43.2M rows are seven-character
ICD-10-PCS — which settles a contradiction inside the business rules. It also marks four
of its own decisions still open, and the new protocol resolves none of them.
`OPEN_QUESTIONS.md` carries both.

## The five things most likely to change a count

1. **Study period start** — the text says 01 Jan 2018, both figures say 01 Jan 2016
   (`OPEN_QUESTIONS.md` Q1).
2. **1L index from 01 Jan 2019** — the build uses 2017 today, and now has to bar
   panobinostat and elotuzumab as well as belantamab.
3. **Bone metastasis still excludes** — `C79.51` is a metastatic cancer to the rule and
   myeloma bone disease to a haematologist. The build knows and excludes anyway
   (`IE_CRITERIA.md` §6). The 30-day pairing window the protocol states is already what
   the build does.
4. **Follow-up is three different tests** — an eligibility test, an observation
   window, and a ≥ 3-month analysis-set restriction — where the build has one
   (`BUILD_DELTA.md` §2).
5. **Disenrollment censors follow-up** on the protocol's wording; the LOT engine says
   it does not (`OPEN_QUESTIONS.md` Q13).

## The code

`study223926/` is a new package that runs **after** the LOT engine: it reads
`LOT_LONG_FINAL` and the NDMM cohort table and writes its own `S_*` tables. It builds
no line and no MM cohort of its own, so it can be re-run against a finished LOT run as
often as needed.

```
Rscript study223926/build.R                                   # on a Databricks cluster
DRY_RUN=TRUE Rscript study223926/build.R                      # print the plan only
MODULES=safety COHORTS=2L Rscript study223926/build.R         # one module, one cohort
Rscript study223926/tests/run_tests.R                         # 361 checks, no warehouse
```

Twelve modules, four cohorts, and every reading this folder records as open is a
setting with the protocol's answer as its default. Six of the twelve modules run
today; the other six are blocked on Annexes 2 and 3, and the run says so by name
before it opens a connection. `study223926/MODULES.md` has the rest.

## Standalone

Nothing in this folder reads a file outside it. The package carries its own code
lists (`study223926/codelists/` — the shapes, not the codes, which do not exist
anywhere yet), its own settings and its own tests, and a test asserts that no
path function in any R file reaches out. The two things it needs that are not
files are the warehouse and, optionally, the production code-list directory.

The documents cite about ninety files elsewhere in the repository. Those are the
evidence trail, not dependencies: every quotation they support is reproduced
inline. `SOURCES.md` separates the two.

## What this folder does not do

It does not change the cohort build. `study223926/` runs after it and after
the LOT engine, and reads what they wrote. `BUILD_DELTA.md` says what would
have to change in the cohort build to match this protocol; making those
changes is separate work, and several of them are blocked on
`OPEN_QUESTIONS.md`.
