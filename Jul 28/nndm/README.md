# NDMM (1L newly-diagnosed multiple myeloma) cohort

Builds the 1L NDMM cohort and its attrition for one cohort prefix.

```
DATABRICKS_PWD=... Rscript build.R <prefix_>
DATABRICKS_PWD=... Rscript build.R mystudy_
```

Only the **1L cohort** is built. The 2L/3L subset cohorts are out of scope.

## What this reads, and what has to run first

This build makes none of its inputs. It stops before doing any work if any is
missing, naming the table and the build that produces it.

| input | produced by |
|---|---|
| `<prefix>ELIG_COH_FINAL` | `Jul 28/overall` |
| `<prefix>LOT_LONG` | `Jul 28/lot` |
| `<prefix>MAP_STACKED` | `Jul 28/lot` |
| `medical`, `rx`, `med_diagnosis`, `med_procedure`, `confinement` | Optum CDM |

So the order is **`overall` → `lot` → `nndm`**. The NDMM index date is the 1L
start, which comes out of `LOT_LONG`, so this cannot run first even though it
is wanted first.

Outputs, all prefixed: `NDMM_COHORT` (the PATIDs), `NDMM_ATTRITION` (the nine
rows below), `NDMM_FLAGS_ALL` (one row per candidate with every filter's
verdict), `NDMM_LOT_LONG_FILT`, `NDMM_BUILD_STATUS`.

## The criteria as applied

This section is written from the code, not from the protocol. Where the two
differ it says so. Compare it against the protocol when either changes.

### Inherited from the parent cohort

These are applied by `Jul 28/overall` and enter here through
`ELIG_COH_FINAL` - this build does not re-derive them.

| # | criterion | as applied |
|---|---|---|
| 1 | **MM diagnosis** | ≥1 inpatient medical claim with an MM diagnosis in any position (ICD-9-CM `203.0x` or ICD-10-CM `C90.0x`), **or** ≥2 outpatient medical claims for MM in any position on separate days within the outpatient window, during the study period |
| 2 | **Adult age** | ≥18 years in the index year |

The parent's own follow-up-CE and baseline-therapy steps are configured off for
this study (`pipeline_inputs.csv`), because NDMM re-applies them at the 1L
anchor rather than the MM-diagnosis anchor. That is the point of this build.

### Applied here

| # | criterion | as applied | source |
|---|---|---|---|
| 3 | **Eligible 1L treatment** | `LOT_NUM = 1` in `LOT_LONG` with `LOT_START_DT >= LOT1_FROM` (**2017-01-01**). The index date is that `LOT_START_DT`. | `02_lot1_starts.R` |
| 4 | **12-month CE before index** | an enrollment span covering `[index − 365, index − 1]` in full, gaps of **≤30 days** treated as continuous | `01_enrollment.R`, `06_flags.R` |
| 5 | **Follow-up CE** | a **no-gap** span covering `[index, index + FU_CE_DAYS]`, where `FU_CE_DAYS = 0` — **one day: the index date itself** | `06_flags.R` |
| 6 | **No MM oncology therapy in the 12-month baseline** | no medical or pharmacy claim for an MM therapy in `[index − 365, index − 1]`, scanned from raw `medical` and `rx` against `cl_mma_codelist.csv`. **Steroids are excluded from this scan** (`DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE`) — a steroid claim alone does not make a patient previously treated. | `03_prior_therapy.R` |
| 7 | **No other cancer in the 12-month baseline** | excluded on **≥1 inpatient** claim, **or ≥2 outpatient** claims **within 30 days of each other**, for the same tumour group, in `[index − 365, index − 1]`. Inpatient is established from the confinement table and the claim header, not from a place-of-service code. | `04_other_malig.R` |
| 8 | **No pregnancy** | excluded on ≥1 medical claim with a diagnosis, procedure or revenue code indicating pregnancy or childbirth, anywhere in `[STUDY_START, STUDY_END]` — the **study period**, not the baseline | `05_pregnancy.R` |
| 9 | **No belantamab in any LOT** | no belantamab row for the patient in `MAP_STACKED` (`MAP_MED_TYPE LIKE 'BEL%'`), any line, **no date bound** — see the attrition note below | `06_flags.R` |

**Not applied: clinical-trial participation.** The attrition spreadsheet in
`NNDM E/attritom.pdf` lists it as Step 10, but that sheet is the parent MM
cohort's funnel — six-month CE, age 18, the MM diagnosis steps — and protocol
Rev Round 2 §6.2.1.2 has four exclusions, this not among them.
`pipeline_inputs.csv` says the same. If the study team wants it back, it is a
new step, not a toggle.

**On belantamab being matched by drug and not by class.** §6.2.1.2 writes the
exclusion as "Received belantamab mafodotin (i.e., an ADC) in any LOT" and
attaches a note:

> at the time of study belantamab mafodotin was the only ADC in use for MM

So "(i.e., an ADC)" names what the drug is; it does not widen the criterion to
the class. `MAP_MED_TYPE LIKE 'BEL%'` is the criterion as written.

### Where this departs from the protocol

**Follow-up CE — criterion 5.** Protocol Rev Round 2 §6.2.1.1 reads:

> CE during follow-up: CE from index date until the earliest of 3-months post
> index or death, with no gaps in enrollment.

The study team confirmed **one day** of follow-up CE for the 1L cohort, which
overrides that text. `apr_30_2026` implements the three-month rule, so this
build produces a **larger** cohort than that code does, and the difference lands
entirely on attrition step 5.

The window is `NDMM_FU_CE_DAYS`, set to `0`, and the change is registered as a
named deviation in `tests/test_same_as_source.R` — reverting it to 90 fails the
suite. The 2L/3L bullet in the protocol still asks for three months and carries
no change bar, so if those cohorts are built later they do **not** inherit this.

Two comments are anchored to that bullet in the protocol PDF and are not in the
rendered page. They have not been read.

### Thresholds worth double-checking

The protocol PDF is a scanned document. Its text layer renders four thresholds
wrong; the values below are what the **images** show, and what this build uses.

| criterion | text layer | document, and this build |
|---|---|---|
| enrollment gaps | `< 30 days` | **`≤ 30 days`** |
| other cancer | `>1 IP or >2 OP` | **`≥1 IP or ≥2 OP`** |
| adult age | `> 18` | **`≥18`** |
| outpatient MM diagnosis | `> 2 claims` | **`≥2 claims`** |

## The attrition

`<prefix>NDMM_ATTRITION`, one row per step, with the count and the percentage
of the starting population.

The steps follow the protocol's own order: §6.2.1.1's inclusions, then
§6.2.1.2's four exclusions as that section lists them, belantamab last.
`apr_30_2026` applied belantamab first and follow-up CE second-to-last; the
final cohort is the same conjunction either way, but the per-step counts are
not.

| # | step | protocol |
|---|---|---|
| 1 | Patients in `LOT_LONG` | — |
| 2 | + in `ELIG_COH_FINAL` (parent IE) | parent cohort |
| 3 | + 1L start on or after `LOT1_FROM` | §6.2.1.1 |
| 4 | + 12-month CE before index | §6.2.1.1 |
| 5 | + CE during follow-up | §6.2.1.1 |
| 6 | + no MM oncology therapy in 12-month baseline | §6.2.1.2, excl. 1 |
| 7 | + no other cancer in 12-month baseline | §6.2.1.2, excl. 2 |
| 8 | + no pregnancy in study period | §6.2.1.2, excl. 3 |
| 9 | + no belantamab in any LOT — **the 1L NDMM cohort** | §6.2.1.2, excl. 4 |

**Step 9 is not a baseline criterion.** Every other step is anchored to the 1L
index date; this one is "in any LOT", with no date bound at all, so a patient
can be removed for a belantamab claim years *after* their 1L index. That is
what §6.2.1.2 says, and it is what `06_flags.R` does — the whole of
`MAP_STACKED`, not a window — but it means the 1L cohort depends on follow-up
data and cannot be built from baseline alone.

Step 2 is intersected with `LOT_LONG` so the funnel is monotonic: the parent
cohort contains patients who never enter `LOT_LONG`, and a bare
`ELIG_COH_FINAL` count would exceed step 1. The build checks that each step is
no larger than the one above it and stops if it is not — a funnel that grows is
a fan-out, not a count — and stops if the final cohort is empty.

## The port

`R/steps/` and `R/nndm_constants.R` are a line-for-line port of the cohort half
of `apr_30_2026/06_ndmm_dashboard.R`, source lines 62-839. The remaining ~640
lines of that file render a dashboard and are not here.

`tests/test_same_as_source.R` compares every ported file against the range it
came from, with comments compared out and code required to be identical; undoes
the named deviations first, and reports one that has gone missing rather than
letting it read as a match; checks the ranges are contiguous, so narrowing one
leaves a gap it names; and parses every file, because line-for-line equality
does not catch a range that ends mid-statement. It did not, once.

The runner, helpers and this README are not ports. `apr_30_2026` is never
modified.

## Settings

`config.csv`; the environment wins over it. `R/build_nndm.R` checks them all
against `CONTRACT` before the first query, so a value that would build a
different cohort stops the run.

| setting | default | effect |
|---|---|---|
| `LOT1_FROM` | `2017-01-01` | 1L eligible-treatment period opens |
| `PRE_LOT1_DAYS` | `365` | CE and baseline window before index |
| `FU_CE_DAYS` | `0` | days after index the follow-up CE must cover |
| `GAP_DAYS` | `30` | gaps this size or smaller are still continuous |
| `STUDY_END` | `2025-06-30` | study period end; picks the quarterly CDM tables |
| `STUDY_START` | `2015-07-01` | lower bound of the pregnancy scan |
| `CODELIST_DIR` | `/mnt/code/codelist` | `cl_mma_codelist.csv`, `pregnancy.csv` |

## Status

Never run against Databricks. Nothing here is validated output until it has
been, and the count compared against the source implementation patient by
patient.
