# NDMM (1L newly-diagnosed multiple myeloma) cohort

Builds the 1L NDMM cohort and its attrition for one cohort prefix.

```
DATABRICKS_PWD=... Rscript build.R <prefix_>
DATABRICKS_PWD=... Rscript build.R mystudy_
```

Only the **1L cohort** is built. The 2L/3L subset cohorts are out of scope.

### One run per prefix at a time

Every table this writes is named work schema + prefix + table, with no run id
in it, and each checkpoint repoints its session view at the prefixed table it
has just replaced. So two runs on the *same* prefix do not produce two cohorts:
the second replaces tables the first is reading through, and both can still
finish and report "complete", each having published something partly the
other's. `check_no_active_run()` refuses the second before it writes anything,
naming the run that holds the prefix and when it started.

Two runs on *different* prefixes are safe, and that is how two cohorts are
meant to be built at once.

A **re-run keeps its run id** — `DOMINO_RUN_ID` pins it, and so does re-running
in one R session. So `NDMM_ATTRITION`, `NDMM_RUN_METADATA` and
`NDMM_CODELIST_METADATA` are cleared of this run's rows before the first step:
each writer clears its own, but only once reached, and an attempt that fails
before `write_run_metadata` would otherwise leave the previous attempt's row
naming the code and the code lists that built a cohort this attempt did not
build.

A clear that is **refused** stops the run, naming every table it could not
clear. Tables that do not exist yet are the first run on a prefix and are not a
failure; a permission or a lock is, because carrying on would publish this
run's rows beside an earlier attempt's under one run id, with nothing
downstream able to tell them apart.

It is a check, not a lock — nothing here can hold one — so two runs starting in
the same moment can both pass it. It catches the case worth catching: starting
a second run while one is going. A killed process leaves its `started` row
behind for ever, so `NDMM_IGNORE_ACTIVE_RUN=TRUE` gets past one; use it only
once the named run is known to be dead.

## What this reads

Standalone. It reads the raw Optum CDM and the production code lists, and no
table produced by another build. Every input is checked before any work starts,
and a missing one is named.

| input | what it is for |
|---|---|
| `medical`, `med_diagnosis`, `confinement` | the MM diagnosis, and the other-cancer rule |
| `member_cont_enrollment` | sex and birth year |
| `dod` | date of death |
| `member_enrollment` | continuous-enrolment spans |
| `rx`, `med_procedure` | treatment and pregnancy claims |

Code lists, all from `CODELIST_DIR`: `mm_dx.csv` (the diagnosis that defines
the population), `cl_mma_codelist.csv` (MM therapy, and belantamab within it),
`other_malig.csv`, `pregnancy.csv`. The md5 of each is written to
`<prefix>NDMM_CODELIST_METADATA`, so a cohort can be traced to the files that
built it.

### It used to need three tables from other builds

`OVERALL_COH_FINAL`, `LOT_LONG` and `MAP_STACKED`. None of them now:

- **MM diagnosis, age and demographics** are ported in from the overall build
  (`R/steps/00_mm_cohort.R`). Only the two criteria §6.2.1.1 inherits are
  applied — a qualifying diagnosis, and age ≥18 in its calendar year. That
  build has switches for six more; none is an NDMM criterion, and applying them
  would drop patients this funnel never accounts for.
  `tests/test_same_as_overall.R` holds the port to it.
- **The 1L index** is derived from claims (`R/steps/00b_lot1_index.R`) — see
  below.
- **Belantamab** is read off `cl_mma_codelist.csv` rather than `MAP_STACKED`.

### The study period

**01 Jan 2016 through 31 Mar 2026**, from protocol §6.1 ("the study period is
defined as 01 Jan 2016 through 31 Mar 2026"). It sets the pregnancy window, the
MM-diagnosis window, and — through `USE_QUARTERLY_TABLES` — which cumulative
Optum tables are read (`2026q1`).

### Nothing is left as a temporary view that is read twice

A temporary view is a query, not a result — Spark re-runs it on every read. The
views here sit on top of each other, so a second read of `NDMM_LOT1_STARTS` is
a second run of the whole MM-diagnosis chain beneath it, across the raw claim
tables. It is read **thirteen** times.

Every view read more than once is written to the work schema once and the view
is repointed at the table, so each later read is a table scan. The steps are
untouched — they still name the view:

```
NDMM_FLAGS_ALL          NDMM_MM_DX_CODES         NDMM_MM_DX_EVENTS
NDMM_MM_QUALIFYING      NDMM_BASE_COHORT         NDMM_ENROLL_SPANS
NDMM_ENROLL_SPANS_STRICT NDMM_MMA_CODELIST       NDMM_BELANTAMAB_CODES
NDMM_LOT1_STARTS        NDMM_OTHER_MALIG_CODES   NDMM_OTHER_MALIG_EVENTS
NDMM_BELANTAMAB_PATIDS  NDMM_INDEX_TX            NDMM_BELANTAMAB_TX
NDMM_PATIDS             NDMM_INDEX_INELIGIBLE    NDMM_PREG_CODES
```

The list is not maintained by hand: `tests/test_runner.R` counts the reads in
the SQL and fails if anything read more than once is missing from it. Two
entries the count cannot see are `NDMM_BASE_COHORT` and
`NDMM_BELANTAMAB_PATIDS`, which reach the flags step as parameters.

A checkpoint that cannot be written **stops the build**. The source
degraded to the in-place view on a write failure — correct arithmetic, but it
can turn minutes into hours without saying so, and a table declared as an
output would then not be there.

`NDMM_FLAGS_ALL` is checkpointed **inside** `06_flags.R` rather than by the
runner. `NDMM_PATIDS` is defined over it a few lines below, and Spark inlines a
temporary view's plan — repointing after that view exists would leave it on the
original query. It was the one materialization that still warned and carried
on; it is the same one call as the other ten now, and it is a deliverable as
well as a checkpoint.

The deliverables are listed in **What every run writes**, below.

`07_cohort.R` still carries `build_lot_long_filtered()`, and `02_lot1_starts.R`
still carries `build_lot1_starts_ndmm()`. The runner calls neither: the first
served the source's dashboard, the second read the index date out of
`LOT_LONG`. Both stay where they are rather than being deleted piecemeal from
files that are otherwise carried across whole.

`NDMM_RUN_METADATA` carries the md5 of every R file this package ships, the
contract as one sorted string, how belantamab was recognised, the waivers asked
for and the waivers that fired, and the final count.

Every setting is checked twice: against `CONTRACT`, and then against the
`NDMM_*` constants the SQL actually interpolates — those have their own
environment variables (`NDMM_LOT1_FROM` is not `LOT1_FROM`), so a contract
checked against `cfg` alone would not speak for the query that runs.

## What every run writes

All prefixed, so two cohorts sit side by side in one schema.

### The cohort, and what made it

| table | what it is |
|---|---|
| `NDMM_COHORT` | the cohort — one row per patient, the ten columns the lot build needs |
| `NDMM_ATTRITION` | the nine-step funnel, with counts and percentages |
| `NDMM_FLAGS_ALL` | one row per 1L candidate with every filter's verdict (also a checkpoint) |
| `NDMM_RUN_METADATA` | the md5 of every R file, the contract as one string, the run choices, the waivers asked for and the waivers that fired |
| `NDMM_CODELIST_METADATA` | the md5 and row count of every code list and fill-in file read |
| `NDMM_BUILD_STATUS` | started / complete / failed, per run and prefix — what `check_no_active_run()` reads |

### The review tables

**Eight review tables.** Each exists because the protocol is silent, a code
list cannot answer, or the answer needs a build that has not run yet.
None of them changes the cohort — they are what the decision gets made
*against*, so nobody has to guess and nobody has to re-run to find out.

| table | the question it answers | what to do with it |
|---|---|---|
| `NDMM_INDEX_AGENTS` | which agents actually set a 1L index | every `CL_MED_ABBR` on the code list, whether this run let it set an index, and how many it set. Review it; bar one with `NDMM_INDEX_EXCLUDED_ABBRS` if it should not have |
| `NDMM_MM_ADJACENT_GROUPS` | which tumour groups are the index disease rather than another cancer | every plasma-cell-looking label, and whether the override reaches it |
| `NDMM_MM_ADJACENT_CODES` | *which* `C79.5x` is myeloma bone disease and which is a breast primary — a label cannot say | every code kept as the index disease, in the columns `codelists/mm_adjacent_overrides.csv` uses. Copy, set the ones you want to `0`, paste |
| `NDMM_OTHER_MALIG_GROUPS` | which code-list labels are one tumour type | every label with the group it pairs under. Anything whose `PRIMARY_GROUP` is still itself can only confirm itself. Fill in `codelists/primary_tumor_groups.csv` |
| `NDMM_OTHER_MALIG_GRAIN` | is that grain actually costing anything? | criterion 7 counted at the finest, configured and coarsest grouping. **The gap between the first row and the last is the whole question** — if it is small, no map is needed |
| `NDMM_FU_CE_COUNTS` | what the follow-up CE window costs — the one setting resting on a relay, not a document | `N_PASSING_CRITERION_5` and `N_COHORT` at 0 / 30 / 60 / 90 days and at an exact 3 months, with this run's row marked |
| `NDMM_BELANTAMAB_SCOPE_COUNTS` | which claims proxy stands for "in any LOT" | `N_PATIENTS` and `N_COHORT` under each of the three readings, with this run's marked |
| `NDMM_BELANTAMAB_RECONCILE` | **which patients the proxy could not settle** | every belantamab claim belonging to a patient whose membership turns on this criterion alone, both those the proxy kept and those it excluded, with dates and which way it went. Join to `LOT_LONG` after the lot build runs |

`tests/test_runner.R` requires every declared output to be named here, so this
list cannot fall behind the code — it had, twice, before that test existed.

## The files you fill in

Two questions cannot be answered from this repository. A tumour-group label
cannot say whether a `C79.5x` is myeloma bone disease or a breast primary; no
document here lists the eligible 1L treatments; and one label per ICD code is
the wrong grain for "the same cancer". Each is a **code-level** decision, and
code-level decisions belong in a file somebody can review, not in a setting
somebody has to discover.

So the package ships two CSVs in `codelists/`, **both empty**:

| file | one row per | the columns | what it decides |
|---|---|---|---|
| `mm_adjacent_overrides.csv` | ICD code | `dx, icd_family, override, note` | `override=1` treats the code as the index disease (do **not** exclude); `0` treats it as another cancer (**do** exclude). Wins over the tumour-group label **both ways** |
| `primary_tumor_groups.csv` | code-list label | `tumor_group, primary_tumor_group, note` | labels sharing a `primary_tumor_group` pair together for the two-outpatient-claim rule |

**Empty means the source's cohort.** An unlisted code keeps its label's verdict,
an unlisted agent can still set an index, an unmapped label stays its own group.
So a checkout with nothing filled in produces the source build's cohort, not a
variation on it. Nothing here changes until you write in one of these.

**In production these three are configured separately** from the four core code
lists. Those come from `CODELIST_DIR`; these come from `NDMM_MM_ADJACENT_CSV` and `NDMM_PRIMARY_GROUPS_CSV`, and each falls back to
the empty file shipped in `codelists/` when its variable is unset. A deploy
that points `CODELIST_DIR` at production and misses these three runs green on
the placeholders.

So every run ends with a line saying which it had:

```
Rule fill-ins: 0 supplied, 2 empty
  > mm_adjacent_overrides.csv: empty (md5 d41d8...) - tumour-group labels
    alone decide the other-cancer criterion
  > An empty file is a run without that rule, and reads the same as one whose
    path was never set. Check the paths against <prefix>NDMM_CODELIST_METADATA
    before this cohort is used.
```

A supplied file is listed with its row count and md5 instead. Both are also in
`<prefix>NDMM_CODELIST_METADATA`, so a finished cohort can be checked without
the log — a shipped placeholder is a known md5 with `n_rows = 0`.

**Each has a table to fill it in from**, so it is a copy and an edit rather than
a research task:

| the file | fill it in from |
|---|---|
| `mm_adjacent_overrides.csv` | `NDMM_MM_ADJACENT_CODES` — the codes currently kept, in these columns |
| `primary_tumor_groups.csv` | `NDMM_OTHER_MALIG_GROUPS` — every label and the group it pairs under |

### What they all do

- **Absent is the same as empty**, and neither is a failure. A checkout that
  deleted them, or a run pointed elsewhere, still builds.
- **A malformed row stops the run.** A blank code, an `override` that is not 0
  or 1, an `icd_family` nobody can act on, one key given two answers, a missing
  column. Skipping a bad row would let a file whose only purpose is to be exact
  quietly decide something nobody chose.
- **A named thing that matches nothing stops the run** when it would otherwise
  read as a rule doing nothing — an allowed `med_abbr` that is on no code list
  is not a permission, it is an agent silently barred, and its patients leave at
  attrition step 3.
- **The md5 goes into `NDMM_CODELIST_METADATA` even when the file is empty**,
  because "read it, no rows" and "never looked" are different, and only one of
  them is a decision.
- Values are normalised the way the code lists are — punctuation stripped from
  codes, everything upper-cased — so `C79.51` and `C7951`, `ICD-10` and `10`,
  `bor` and `BOR` all match.
- **Point elsewhere** with `NDMM_MM_ADJACENT_CSV`,   `NDMM_PRIMARY_GROUPS_CSV`. The path is recorded whether or not a file is
  found there.

The detail for each is in **Bone metastasis, and the codes you can decide
yourself**, **Which agents may set the 1L index**, and **One label per code is
the wrong grain for "another cancer"**.

## The criteria as applied

This section is written from the code, not from the protocol. Where the two
differ it says so. Compare it against the protocol when either changes.

### Derived here, from the parent build's rules

`R/steps/00_mm_cohort.R` is a port of the overall build's MM-diagnosis,
index-qualification and demographics SQL. Two criteria are applied — the two
§6.2.1.1 names — and no more.

| # | criterion | as applied | source |
|---|---|---|---|
| 1 | **MM diagnosis** | ≥1 inpatient claim with a **strict** MM code (ICD-9-CM `203.0x` / ICD-10-CM `C90.0x`), **or** ≥2 outpatient claims on separate days **within 90 days**. The two arms do not use the same codes: **strict is required only of the inpatient arm**, and the outpatient pair accepts any code on `mm_dx.csv`. Any position on the claim. Inpatient means a place-of-service or type-of-service line flag, or a valid confinement. Claims are bounded to the study period. | `00_mm_cohort.R` |
| 2 | **Adult age** | **≥18** in the calendar year of that diagnosis. Applied *after* the earliest qualifying date is chosen, so it can only drop a patient — never move their diagnosis date. A patient who qualifies at 17 and again at 18 is **excluded**. See below. | `00_mm_cohort.R` |

**Why age comes after the ranking.** It used to come before: the qualifying
dates were filtered by age and the earliest survivor became `MM_DX_DT`. That
kept the 17-then-18 patient, by moving their diagnosis date to the later one —
and `MM_DX_DT` is not a demographic here, it gates the 1L index, which is the
*first* MM therapy claim on or after it. Advancing it lets a later therapy
claim be recorded as first line for someone whose real first line was at 17.
the overall build never did this: its age rule is `AND AGE_INDEX_YR >= min_age`
applied to an index date already chosen, which drops the patient. This build
now matches it. The change makes the cohort **smaller**, and the difference
lands entirely on attrition step 2.

**The parent's other four inclusion criteria are deliberately not here** —
six-month baseline CE, enrolment on the diagnosis date, no MM agent in
baseline, ≥1 MM agent in follow-up. They are switches in
`overall/config.csv`, not protocol criteria for this cohort, and NDMM
re-applies CE and baseline therapy at the 1L anchor instead.
`tests/test_same_as_overall.R` fails if any of their columns appears in the
port.

### Applied here

| # | criterion | as applied | source |
|---|---|---|---|
| 3 | **Eligible 1L treatment** | the **first** claim for an MM therapy on or after that patient's MM diagnosis, on or after `LOT1_FROM` (**2017-01-01**) and on or before the study end. Four arms over raw claims — `PROC_CD` and `BILL_PROC_CD` and `NDC` in `medical`, `NDC` in `rx` — each matched against `cl_mma_codelist.csv` and only against the code types that source can carry. **Belantamab cannot set it** (§6.2.1.1: an eligible 1L treatment is one "other than belantamab"); steroids cannot either, being dropped from the code list. That date is the NDMM index. | `00b_lot1_index.R` |
| 4 | **12-month CE before index** | an enrollment span covering `[index − 365, index − 1]` in full, gaps of **≤30 days** treated as continuous | `01_enrollment.R`, `06_flags.R` |
| 5 | **Follow-up CE** | a **no-gap** span covering `[index, index + FU_CE_DAYS]`, where `FU_CE_DAYS = 0` — **one day: the index date itself** | `06_flags.R` |
| 6 | **No MM oncology therapy in the 12-month baseline** | no medical or pharmacy claim for an MM therapy in `[index − 365, index − 1]`, scanned from raw `medical` and `rx` against `cl_mma_codelist.csv`. **Steroids are excluded from this scan** (`DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE`) — a steroid claim alone does not make a patient previously treated. | `03_prior_therapy.R` |
| 7 | **No other cancer in the 12-month baseline** | excluded on **≥1 inpatient** claim, **or ≥2 outpatient** claims **within 30 days of each other** for the same cancer — **both claims inside** `[index − 365, index − 1]`. Inpatient is established from the confinement table and the claim header, not from a place-of-service code. Plasma-cell tumour groups are the index disease and do not count; what "the same cancer" means is a code-list label unless a map says otherwise — both below. | `04_other_malig.R` |
| 8 | **No pregnancy** | excluded on ≥1 medical claim with a diagnosis, procedure or revenue code indicating pregnancy or childbirth, anywhere in `[2016-01-01, 2026-03-31]` — the **study period**, not the baseline | `05_pregnancy.R` |
| 9 | **No belantamab in any LOT** | any claim for a belantamab code from `cl_mma_codelist.csv`, in `medical` or `rx`, **within the study period** — a claims proxy for LOT membership, because lines do not exist yet. Configurable, and not exact under any setting; see below | `00b_lot1_index.R`, `06_flags.R` |

**Five of the nine are open in some way**, and each has somewhere to go rather
than a note saying so:

| criterion | what is undecided | decide it with |
|---|---|---|
| #3 | which agents actually set the index — the code list is the eligible set, so this is a review rather than a decision | `NDMM_INDEX_AGENTS` |
| #5 | one day of follow-up CE against the protocol's three months | `NDMM_FU_CE_COUNTS` |
| #7 | whether a `C79.5x` is myeloma bone disease or a metastasis | `NDMM_MM_ADJACENT_CODES` → `codelists/mm_adjacent_overrides.csv` |
| #7 | whether two labels are one cancer | `NDMM_OTHER_MALIG_GRAIN`, `NDMM_OTHER_MALIG_GROUPS` → `codelists/primary_tumor_groups.csv` |
| #9 | which claims proxy stands for "in any LOT" | `NDMM_BELANTAMAB_SCOPE_COUNTS`, `NDMM_BELANTAMAB_RECONCILE` |

**None of them changes anything until somebody acts.** Every file ships empty
and every default is the source's, so the criteria above are what runs today.

**Not applied: clinical-trial participation.** The attrition spreadsheet
supplied with the study documents lists it as Step 10, but that sheet is the
parent MM cohort's funnel — six-month CE, age 18, the MM diagnosis steps — and protocol
Rev Round 2 §6.2.1.2 has four exclusions, this not among them.
If the study team wants it back it is a new step, not a toggle.

**On belantamab being matched by drug and not by class.** §6.2.1.2 writes the
exclusion as "Received belantamab mafodotin (i.e., an ADC) in any LOT" and
attaches a note:

> at the time of study belantamab mafodotin was the only ADC in use for MM

So "(i.e., an ADC)" names what the drug is; it does not widen the criterion to
the class.

**How belantamab is recognised is an assumption this package cannot check.**
the source build matched `MAP_MED_TYPE LIKE 'BEL%'` in `MAP_STACKED`, a table this
build no longer reads. Reading `cl_mma_codelist.csv` directly, the same token
is the medication abbreviation — `NDMM_BELANTAMAB_ABBR`, default `BEL%`. The
production CSV is not visible from here, so `build_ndmm_belantamab_codes()`
**stops the run** if it matches no row: otherwise exclusion 4 would quietly do
nothing and belantamab claims could set the 1L index date. The value used is
recorded in `NDMM_RUN_METADATA`. **Confirm it against the production code list
before the first run.**

### What counts as "another cancer"

**The protocol says nothing about remission.** §6.2.1.2 says another cancer:
≥1 inpatient or ≥2 outpatient codes for the same primary tumour type. No
states, no exemptions.

The override is not a departure from that criterion — it is what makes it mean
what it says. `other_malig.csv` is the study's **generic** other-cancer code
list and it carries myeloma's own codes, so without an override every NDMM
patient would be excluded for having the disease that put them in the cohort.

So the question is never "is this in remission?" but **"is this the index
disease?"**, and it is answered two ways:

1. **Derived.** Any code on `mm_dx.csv` is the index disease by definition —
   that same file decides who is an MM patient — so it can never also make them
   an other-cancer patient, whatever its description says. This is the rule that
   matters, and it needs no list to maintain.
2. **Listed.** Five tumour groups that are adjacent to MM without being on the
   diagnosis list: plasma cell leukemia, solitary and extramedullary
   plasmacytoma, monoclonal gammopathy (the precursor), and MM bone disease.

`other_malig.csv`, read on the warehouse **2026-07-30**, carries each of those
plasma-cell conditions in **three states**, each its own `tumor_group`:

| condition | not achieved remission | in remission | in relapse |
|---|---|---|---|
| Plasma cell leukemia | `C9010` | `C9011` | `C9012` |
| Extramedullary plasmacytoma | `C9020` | `C9021` | `C9022` |
| Solitary plasmacytoma | `C9030` | `C9031` | `C9032` |

the source build overrode **only the first column** — it anchored on the wording
and split each triple. So a patient was excluded for having another cancer
because their plasma cell leukemia was in remission or in relapse, while an
identical patient whose plasma cell leukemia had not achieved remission was
kept. The disease state was never the question.

All six are overridden by default:

```
NDMM_MM_ADJACENT_STATES=override   # default
NDMM_MM_ADJACENT_STATES=exclude    # the source build's behaviour, to compare
```

This makes the cohort **larger**, and the difference lands on attrition step 7.

Note that `tumor_group` in that file is **one label per ICD code**, not a
grouping — so "≥2 outpatient claims for the same tumour group" means the same
exact diagnosis description, and the three states above are three different
groups to the rule that reads it. That is inherited from the parent build and
has not been changed here.

The five original labels stay **required**: if the code list does not carry one,
the run stops, because the override would silently fail and patients would be
excluded for an MM-adjacent condition. The six state labels are **not**
required — their absence would just mean the wording changed.

Every run writes `<prefix>NDMM_MM_ADJACENT_GROUPS`: every tumour group on the
code list that looks plasma-cell related — anything matching `%REMISSION%`,
`%RELAPSE%`, `%PLASMACYTOMA%`, `%PLASMA CELL%`, `%GAMMOPATHY%` or `%MYELOMA%` —
with whether the override reaches it and how many codes it carries. Anything in
it marked `EXCLUDES` is the open question, named in the log.

### Which agents may set the 1L index

§6.2.1.1 says the eligible treatments are

> MM regimens commonly used in the first line setting, **excluding those
> restricted to later LOTs (see exclusion criteria)**

and §6.2.1.2's exclusion criteria name exactly one therapy: belantamab. So the
protocol as written restricts nothing else, and this build restricts nothing
else — anything on `cl_mma_codelist.csv` that is not belantamab and not a
steroid can set the index.

**Annex 2 is not that list.** It is *"Categorization of SOC Regimens"*, which
§6.2.2 describes as "an exemplary list of potential treatment combinations…
Final treatment groupings may depend on data availability… and may be
recategorized". It is an analysis grouping, and a stand-alone document not
included in the protocol PDF.

So this build does not invent an allowlist — that would shrink the cohort by a
rule nobody could reproduce from the document. It reads one if you write it
down, and writes the sheet to build it from.

**`<prefix>NDMM_INDEX_AGENTS`** — every `CL_MED_ABBR` on the code list, whether
this run would let it set an index (`ELIGIBLE`), and how many patients it
actually set one for (`N_PATIENTS`, counted on the index date itself, off the
same scan the index came from). Every agent, not only the ones that won a date:
under an allowlist the winners are by definition the allowed ones, so a table
of winners could only ever confirm itself.


### Bone metastasis, and the codes you can decide yourself

The other-cancer criterion is decided on `other_malig.csv`'s `tumor_group`
label, and five groups are overridden — treated as the index disease rather
than another cancer. Four of them the label settles: **monoclonal gammopathy**,
**solitary plasmacytoma**, **plasma cell leukemia**, **extramedullary
plasmacytoma** are plasma-cell disease.

The fifth is not like the others. **`SECONDARY MALIGNANT NEOPLASM OF BONE`** —
`C79.51`, `C79.52`, `198.5` — says a cancer spread to bone. It does not say
*which* cancer. Myeloma bone disease is usually coded as MM with bone
involvement, but it is miscoded here too, which is why the source build overrides
the group. A breast or prostate primary metastatic to bone carries the same
code. **The label cannot separate those. A code can.**

So there is a file to fill in:

```
nndm/codelists/mm_adjacent_overrides.csv
dx,icd_family,override,note
C79.51,ICD10,0,metastasis - exclude as another cancer
C90.02,ICD10,1,myeloma in remission - the index disease
```

| column | meaning |
|---|---|
| `dx` | the ICD code; punctuation is ignored, `C79.51` and `C7951` are the same |
| `icd_family` | `ICD9` or `ICD10` (`9`/`10`/`ICD-10` also accepted) |
| `override` | `1` = the index disease, do **not** exclude · `0` = another cancer, **do** exclude |
| `note` | free text — why, for whoever reads this next |

**A row here wins over the tumour-group label, in both directions.** The file
ships empty, which means the labels decide everything, which is exactly
the source build's cohort — so nothing changes until you put something in it. Set
`NDMM_MM_ADJACENT_CSV` to use a file somewhere else.

Every run writes **`<prefix>NDMM_MM_ADJACENT_CODES`**: every code currently
kept as the index disease, with its group, in these columns. That is the list
to copy from — you should not have to go looking for the codes.

Malformed rows **stop the run** rather than being skipped: an override that is
not 0 or 1, an unrecognised `icd_family`, a `dx` that is blank once punctuation
is stripped, one code given two answers, or missing columns. A row silently
dropped from a file whose only purpose is to be exact would read as a decision
somebody made. The file's md5 goes into `NDMM_CODELIST_METADATA` even when it
is empty, so a cohort says which version of it was read.

### One label per code is the wrong grain for "another cancer"

Criterion 7 Path B is **two outpatient claims within 30 days for the same
cancer**. "Same" is decided on `other_malig.csv`'s `tumor_group` — and that
column carries **one label per ICD code**. A label is a code description, not a
tumour type:

- `PLASMA CELL LEUKEMIA IN REMISSION` and `PLASMA CELL LEUKEMIA NOT HAVING
  ACHIEVED REMISSION` are two labels for one disease
- a solid tumour coded at two subsites is two more

Two claims that should confirm each other land in different labels, never pair,
and the patient is **not excluded**. The criterion under-detects, so the cohort
is **too large** — the direction that puts patients into a study they don't
belong in.

**The real fix is a `primary_tumor_group` column on the production code list.**
Until there is one, `codelists/primary_tumor_groups.csv`:

```
tumor_group,primary_tumor_group,note
PLASMA CELL LEUKEMIA IN REMISSION,PLASMA CELL LEUKEMIA,same disease
PLASMA CELL LEUKEMIA NOT HAVING ACHIEVED REMISSION,PLASMA CELL LEUKEMIA,
```

Every label mapped to the same `primary_tumor_group` pairs together. Anything
unmapped stays its own group, so **the empty file that ships is exactly the rule
the source build runs**. `NDMM_OTHER_MALIG_GROUPS` lists every label on the code
list to map from — anything whose `PRIMARY_GROUP` is still its own label can
only confirm itself. Set `NDMM_PRIMARY_GROUPS_CSV` for a file elsewhere.

**You do not need the map to find out whether it is worth writing.** Every run
writes **`<prefix>NDMM_OTHER_MALIG_GRAIN`**:

| `GRAIN` | `N_EXCLUDED` |
|---|---|
| same code-list label | … ← the finest grain, and what the source build does |
| as configured | … ← the same until the map says otherwise |
| any label at all | … ← the coarsest, and the upper bound |

**The gap between the first row and the last is the whole question.** If it is
small the grain does not matter; if it is large the map is worth writing. All
three are computed off `NDMM_OTHER_MALIG_EVENTS` — the claim scan is split out
from the rule it feeds, so `med_diagnosis` is read once, not four times.

### Where this departs from the protocol

All protocol references are to the current protocol document
(*Rev Round 2, June 16 2026*), 58 pages. An earlier draft is also in
circulation — its own title bar reads `OLD DO NOT USE` — and its eligibility
text differs. Check the revision before reading a criterion off it.

**Follow-up CE — criterion 5.** Protocol Rev Round 2 §6.2.1.1 reads:

> CE during follow-up: CE from index date until the earliest of 3-months post
> index or death, with no gaps in enrollment.

The study team confirmed **one day** of follow-up CE for the 1L cohort, which
overrides that text. The source implements the three-month rule, so this build
produces a **larger** cohort than that code does, and the difference lands
entirely on attrition step 5.

The window is `NDMM_FU_CE_DAYS`, set to `0`, and it is named in the contract
rather than written into the SQL, so changing it is a deliberate act and is
recorded in the run metadata. The 2L/3L bullet in the protocol still asks for three months and carries
no change bar, so if those cohorts are built later they do **not** inherit this.

The one-day rule comes from the study team, relayed in the build request. It is
not written in any document in this repository, and two comments anchored to
that bullet in the protocol PDF are not in the rendered page and have not been
read. Until the decision exists in a controlled source, `FU_CE_DAYS = 0` rests
on that relay alone — **this is the only setting in this package that does**.

**So the run produces the number the decision should be made against.** Nobody
can sign off a deviation from the protocol against a difference nobody has
measured, so every run writes **`<prefix>NDMM_FU_CE_COUNTS`**:

| `FU_CE_RULE` | `N_PASSING_CRITERION_5` | `N_COHORT` | `IS_THIS_RUN` |
|---|---|---|---|
| 0 days | … | … | 1 |
| 30 days | … | … | 0 |
| 60 days | … | … | 0 |
| 90 days | … | … | 0 |
| 3 months (exact) | … | … | 0 |

`N_COHORT` is the **whole conjunction** at that window — the cohort size you
would ship, not one criterion's count. So the row marked `IS_THIS_RUN` against
the `90 days` row is exactly what the deviation costs, in patients. It is one
extra pass over the no-gap spans, bounded by death and the study end the same
way the flag itself is, and it does **not** change the cohort: the run still
applies `NDMM_FU_CE_DAYS`.

The windows are derived from the configured value, so whatever
`NDMM_FU_CE_DAYS` is set to has a row — the table always contains the run that
produced it.

**"3 months" is applied as 90 days**, because `NDMM_FU_CE_DAYS` is a day count.
`add_months(index, 3)` is the exact reading and lands 0–2 days later; it is in
the table as its own row so the difference is a number rather than an
assumption. This build **cannot currently be set to** the exact-months rule — if
the study team picks it, that is a code change, and the table says first whether
it is worth one.

### Thresholds worth double-checking

The protocol document's extracted text renders four thresholds wrong. The
values below are what the document itself states, and what this build uses.
Check these four against the controlled copy before a production run.

| criterion | text layer | document, and this build |
|---|---|---|
| enrollment gaps | `< 30 days` | **`≤ 30 days`** |
| other cancer | `>1 IP or >2 OP` | **`≥1 IP or ≥2 OP`** |
| adult age | `> 18` | **`≥18`** |
| outpatient MM diagnosis | `> 2 claims` | **`≥2 claims`** |

**Other cancer — criterion 7.** the source build bounded only the *first* of the
two outpatient claims to the baseline. A claim the day before the index and its
confirmation a month after it therefore excluded the patient, on a single
baseline claim, when the criterion asks for two in the baseline. Both are
bounded here.

This can only remove exclusions, so the cohort is **larger** than the one
the source build builds, and the difference lands on attrition step 7. Registered
as a named deviation. If the study team means a post-index claim to be allowed
to confirm baseline disease, this is the line to take back out.

### NDC matching, and what has to be checked before the first run

The prior-therapy scan matches an NDC by stripping non-digits and left-padding
to eleven. That is the **4-4-2** layout. A ten-digit NDC written 5-3-2 or 5-4-1
pads to a different key, so `50242-040-62` — canonically `50242004062` —
becomes `05024204062`: a real prior therapy missed, or the wrong drug matched.
The patient's inclusion turns on it and nothing downstream can see it happen.

`check_ndc_shape()` profiles the values before the scan runs, on both sides of
the join and scoped to the NDMM candidates — from the earlier of the study
start and twelve months before each patient's diagnosis, through the study end
— and stops on any of four conditions:

| check | what it found |
|---|---|
| `claim_ndc_shape` | a claim NDC that cannot be an NDC — letters, wrong length, or all zeros |
| `claim_ndc_short` | a ten-digit claim NDC, where the padding is only right for 4-4-2 |
| `codelist_ndc_shape` | the same on the code list side — fixable at source |
| `codelist_ndc_short` | a ten-digit code on the code list — write it as NDC11 |

Each is accepted separately, and only once the study team has looked:
`NDMM_WAIVERS=claim_ndc_short`. Nothing outside those four names can be waived,
and a waiver naming something else stops the build as a typo. What was asked
for and what actually fired are recorded apart in `NDMM_RUN_METADATA` — a run
can ask for a waiver on a condition that never occurs.

**Run the first production build with no waivers set** and read the profile it
prints. That is the point of it.

### NDMM_COHORT is a LOT input

The next stage runs the LOT algorithm over these patients, so this table is
written as a cohort the lot build can be pointed at directly:

```
DATABRICKS_PWD=... Rscript build.R NDMM_COHORT ndmm_
```

It carries the ten columns that build reads off whatever cohort it is given —
`PATID`, `INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`, `DEATH_DT`, `GDR_CD`, `YRDOB`,
`AGE_INDEX_YR`, `FU_DAYS`, `FU_DAYS_CE` — and `check_ndmm_cohort()` verifies
them, one row per patient, and that the count agrees with the attrition, before
the run finishes.

**`INDEX_DATE` is the 1L start.** Everything that depends on where the anchor
sits is recomputed from it: age at index, both follow-up lengths, and where
continuous enrollment ends. Only sex, birth year and date of death are
inherited from the parent cohort, because those do not move with an anchor.
Carrying the parent's `AGE_INDEX_YR` or `FU_DAYS` instead would describe the
MM-diagnosis index, and a LOT run over this table would measure its lines from
the wrong day.

## The attrition

`<prefix>NDMM_ATTRITION`, one row per step, with the count and the percentage
of the starting population.

The steps follow the protocol's own order: §6.2.1.1's inclusions, then
§6.2.1.2's four exclusions as that section lists them, belantamab last.
the source build applied belantamab first and follow-up CE second-to-last; the
final cohort is the same conjunction either way, but the per-step counts are
not.

| # | step | protocol |
|---|---|---|
| 1 | Patients with a qualifying MM diagnosis | §6.2.1.1 incl. 1 |
| 2 | + aged 18 or over at diagnosis | §6.2.1.1 incl. 2 |
| 3 | + eligible 1L treatment on or after `LOT1_FROM` | §6.2.1.1 incl. 3 |
| 4 | + 12-month CE before index | §6.2.1.1 incl. 4 |
| 5 | + CE during follow-up | §6.2.1.1 incl. 5 |
| 6 | + no MM oncology therapy in 12-month baseline | §6.2.1.2, excl. 1 |
| 7 | + no other cancer in 12-month baseline | §6.2.1.2, excl. 2 |
| 8 | + no pregnancy in study period | §6.2.1.2, excl. 3 |
| 9 | + no belantamab in any LOT — **the 1L NDMM cohort** | §6.2.1.2, excl. 4 |

**Every step is this build's own.** Nothing arrives pre-filtered, so each row
of the funnel is a criterion the protocol names and the count beside it is
reproducible from this folder alone.

### The table

| column | |
|---|---|
| `RUN_ID` | which run wrote the row; cleared and rewritten as one unit, so a retried insert cannot double it |
| `STEP_NUM` | 1–9, the order above |
| `CRITERION` | the step's label — prose, and meant to be editable |
| `N_PATIENTS` | distinct patients still in at that step |
| `PCT_OF_START` | percentage of step 1, to two decimals |
| `RECORDED_AT` | when |

Counts are distinct patients, never claims, and every step after the third is
one more `AND` on the same `NDMM_FLAGS_ALL` row — a widening conjunction over a
fixed population, not a re-scan. So the funnel can only narrow, and each row is
comparable with the one above it.

Counts reach SQL as digits rather than as R prints them. `as.character(1e5)`
is `"1e+05"`, which a warehouse reads as a double, and a cohort of exactly
100,000 would have been written as one.

### What stops the build

- **A step larger than the one above it.** The funnel only narrows; a step that
  grows means a join fanned out or a filter hit the wrong population. Checked
  **before** the table is written, so a fanned-out funnel is never published.
- **An empty final cohort.** A count of zero is not a result to ship.
- **A cohort table whose row count disagrees with step 9.** `check_ndmm_cohort()`
  compares the two and stops if they differ, so the delivered table and the
  funnel that describes it cannot drift apart.

### Step 9 is not like the others

**Step 9 is not a baseline criterion.** Every other step is anchored to the 1L
index date; this one is "in any LOT", so a patient can be removed for a
belantamab claim years *after* their 1L index. That is what §6.2.1.2 says, but
it means the 1L cohort depends on follow-up data and cannot be built from
baseline alone.

**And "in any LOT" cannot be applied exactly here.** Lines of therapy do not
exist when this build runs — the LOT algorithm runs over the cohort it
produces. So the exclusion is a claims proxy, chosen by
`NDMM_BELANTAMAB_SCOPE`:

| scope | a patient is excluded if they have a belantamab claim… |
|---|---|
| `study_period` *(default)* | anywhere in `[2016-01-01, 2026-03-31]`. Lines are only ever built over the study period, so a claim outside it is in no LOT. |
| `from_index` | on or after their own 1L index. Lines are numbered from that date, so this is the strictest reading — and excludes fewest patients. |

the source build bounded neither end but the upper one, so a claim from **before
the study period** excluded the patient. That is wrong under either reading,
and is the defect this fixes.

Neither scope is LOT membership. **Only running the LOT algorithm over the
cohort and checking which line a belantamab claim landed in is exact** — that
is a reconciliation pass after the lot build, not something this build can do.
So it does the two things it can: cost the choice, and emit what the
reconciliation needs.

**`<prefix>NDMM_BELANTAMAB_SCOPE_COUNTS`** — for each reading, how many 1L
candidates it excludes *and* the resulting cohort size:

| `SCOPE` | `N_PATIENTS` | `N_COHORT` | `IS_THIS_RUN` |
|---|---|---|---|
| ever | … | … | 0 |
| study_period | … | … | 1 |
| from_index | … | … | 0 |

`N_COHORT` is the whole conjunction, because a claim count alone overstates the
choice: some of the patients a wider proxy catches were already gone on another
criterion. The scope in force is pinned in `CONTRACT` and recorded in
`NDMM_RUN_METADATA`.

**`<prefix>NDMM_BELANTAMAB_RECONCILE`** — the patients still to adjudicate.
One row per belantamab claim belonging to a patient who passes every *other*
criterion, so the belantamab decision is the only thing that moves them in or
out, with `INDEX_DATE`, `BEL_DT`, `DAYS_FROM_INDEX` and `EXCLUDED_BY_PROXY`.

Both directions are in it, and that is the point. `EXCLUDED_BY_PROXY = 0` is a
patient the proxy kept who carries a claim it did not count; `= 1` is one it
removed. A table built from the cohort alone could only ever show the first
kind — the patients the proxy excluded are not in the cohort to be looked at —
and over-exclusion is the error that costs patients.

After the lot build has run, that table closes the criterion in both
directions:

```sql
SELECT DISTINCT r.PATID
FROM   <prefix>NDMM_BELANTAMAB_RECONCILE r
JOIN   <prefix>LOT_LONG l ON l.PATID = r.PATID
WHERE  r.BEL_DT BETWEEN l.LOT_START_DT AND coalesce(l.LOT_END_DT, r.BEL_DT)
```

Run it over the `EXCLUDED_BY_PROXY = 0` rows and every `PATID` returned
received belantamab **in a line**: it should have been excluded under §6.2.1.2
and was not, because the claims proxy did not reach it. Remove those and note
the count against attrition step 9.

Run it over the `EXCLUDED_BY_PROXY = 1` rows and the answer is the other way
round: a `PATID` it does **not** return has no belantamab claim inside any
line, so the proxy removed a patient §6.2.1.2 does not exclude. Those belong
back in the cohort.

The proxy was exact for this data only when both passes come back empty. One
empty pass answers half the question.

## The step files

Nine step files. Each one is a phase of the build, and every rule the cohort
turns on lives in exactly one of them.

| file | what it defines |
|---|---|
| `R/steps/00_mm_cohort.R` | the MM diagnosis, its qualification, and demographics — the two criteria §6.2.1.1 inherits |
| `R/steps/00b_lot1_index.R` | the 1L index date, derived from claims, and the two sensitivity tables beside it |
| `R/steps/01_enrollment.R` | continuous-enrolment spans, with and without gaps |
| `R/steps/02_lot1_starts.R` | the 1L starts the funnel counts from |
| `R/steps/03_prior_therapy.R` | the 12-month baseline MM-therapy scan, steroids excluded |
| `R/steps/04_other_malig.R` | what counts as another cancer, and the codes you can decide yourself |
| `R/steps/05_pregnancy.R` | the pregnancy scan over the study period |
| `R/steps/06_flags.R` | one row per candidate carrying every criterion's verdict, and the cohort defined over it |
| `R/steps/07_cohort.R` | the filtered cohort, and the counts the attrition is read from |

The runner, the helpers and the tests are not step files: `R/build_nndm.R`
holds the order, the contract, the criteria list and the attrition, and
`R/steps` holds the rules it applies.

### The criteria are one list

`NDMM_CRITERIA` in `R/build_nndm.R` is the cohort definition: one entry per
criterion, in the order the protocol applies them, each carrying the flag it
tests and the label the attrition prints. Three readers render it —
`NDMM_PATIDS` ANDs all of it, the funnel walks a prefix of it per row, and the
two sensitivity tables take all-but-the-one they vary. Nothing writes the
conjunction out for itself, so the cohort table, the funnel and those tables
cannot disagree about what the criteria are.

### Decisions that change who is in the cohort

Five, each deliberate and each recorded:

| change | direction |
|---|---|
| follow-up CE is one day, not three months (§6.2.1.1 says three; the study team said one) | **larger** cohort |
| a code list value that normalises to blank no longer matches a claim with no code | **larger** — it can only remove matches that should not have been made |
| both outpatient claims must fall in the baseline, not just the first | **larger** |
| `mm_adjacent_overrides.csv` can decide a code the tumour-group label cannot | either way, and **nothing** until the file is filled in |
| outpatient claims pair on a mapped tumour type, not on a code description | **smaller**, and **nothing** until the map is filled in |


### And to the parent, where line-for-line is impossible

`tests/test_same_as_overall.R` holds `00_mm_cohort.R` to the overall build, and
deliberately **does not** compare line for line — the parent's steps are
entries in a phase-runner list, they carry columns only its own attrition
reads, and its inpatient / outpatient / qualifying steps are three views where
this build needs one. Saying otherwise would be a lie about what is checked.

Instead it lifts the clinically decisive expressions out of the parent's own
files, renames its views to ours, and requires each to appear here verbatim:
what counts as inpatient, which codes qualify an inpatient claim, how a
diagnosis claim joins its header, the outpatient window, how a partial death
date resolves, which eligibility row wins. Change one here and it fails;
change one in the parent and it fails too, which is the drift worth catching.
It also fails if any of the parent's *other* criteria leak in — this build
applies two of its six, and a patient dropped by a seventh would never appear
in the funnel.

## Settings

`config.csv`; the environment wins over it. Everything below is read by name —
`tests/test_runner.R` requires each one to appear here, so this list cannot
fall behind the code.

### To run at all

| setting | default | |
|---|---|---|
| `DATABRICKS_PWD` | *(none)* | **required** — the build stops without it |
| `DATABRICKS_DSN` | `RWDE` | ODBC data source |
| `DATABRICKS_CATALOG` | `hive_metastore` | catalog for both schemas |
| `OPTUM_CDM_SCHEMA` | `clnprw_optum` | where the raw CDM lives |
| `PROJECT_WORK_SCHEMA` | *(none)* | where output goes. Falls back to `DOMINO_USER_NAME`, then `DOMINO_STARTING_USERNAME`; **no default**, so a build that skipped this stops rather than writing somewhere shared |
| `OBJECT_PREFIX` | *(none)* | the cohort prefix, or pass it to `build.R`. Must end in `_` |
| `DOMINO_RUN_ID` | a timestamp | identifies the run in every metadata table |
| `OUTPUT_DIR` | `/mnt/artifacts/results` | artifacts |
| `PIPELINE_LOG_FILE` | a dated file | the run log |

### The contract

Change one and it is a different cohort, so `check_contract()` **refuses the
run** rather than building something the name no longer describes.

| setting | default | effect |
|---|---|---|
| `LOT1_FROM` | `2017-01-01` | 1L eligible-treatment period opens |
| `PRE_LOT1_DAYS` | `365` | CE and baseline window before index |
| `FU_CE_DAYS` | `0` | days after index the follow-up CE must cover |
| `GAP_DAYS` | `30` | gaps this size or smaller are still continuous |
| `STUDY_END` | `2026-03-31` | study period end; picks the quarterly CDM tables |
| `STUDY_START` | `2016-01-01` | study period start; the pregnancy and belantamab scans |
| `OUTPATIENT_WINDOW` | `90` | two outpatient MM claims within this many days confirm a diagnosis |
| `MIN_AGE` | `18` | minimum age in the MM-diagnosis year |
| `NDMM_BELANTAMAB_ABBR` | `BEL%` | how belantamab is recognised on the code list — it is exclusion 4, so it is pinned |
| `USE_QUARTERLY_TABLES` | `TRUE` | read the quarterly CDM tables for the study end |
| `CODELIST_DIR` | `/mnt/code/codelist` | `mm_dx.csv`, `cl_mma_codelist.csv`, `other_malig.csv`, `pregnancy.csv` |
| `TBL_CONFINEMENT` | `confinement` | inpatient stays |
| `TBL_MEMBER_ENROLLMENT` | `member_enrollment` | enrolment spans |
| `TBL_MEMBER_ELIG` | `member_cont_enrollment` | sex and birth year |
| `TBL_DOD` | `dod` | date of death |

Every one is checked **twice** — against `CONTRACT`, and then against the
`NDMM_*` constants the SQL actually interpolates. Those have their own
environment variables (`NDMM_LOT1_FROM` is not `LOT1_FROM`), so a contract
checked against `cfg` alone would not speak for the query that runs.

### Run choices

Places the protocol is silent or the data has to answer. Each is validated
against the values it may take and recorded in `NDMM_RUN_METADATA`, and **none
is pinned to its default** — the review tables exist to be acted on.

| choice | default | may be |
|---|---|---|
| `NDMM_BELANTAMAB_SCOPE` | `study_period` | `study_period`, `from_index` |
| `NDMM_MM_ADJACENT_STATES` | `override` | `override`, `exclude` |
| `NDMM_INDEX_EXCLUDED_ABBRS` | *(empty)* | comma-separated `CL_MED_ABBR` patterns |
| `NDMM_INDEX_EXCLUDED_CODES` | *(empty)* | comma-separated `TYPE:CODE` or bare codes |
| `NDMM_WAIVERS` | *(empty)* | the four NDC-shape checks and `raw_icd_flag`, by name |

### Where the fill-in files are, and one way out

| setting | default | |
|---|---|---|
| `NDMM_MM_ADJACENT_CSV` | `codelists/mm_adjacent_overrides.csv` | see **The files you fill in** |
| `NDMM_PRIMARY_GROUPS_CSV` | `codelists/primary_tumor_groups.csv` | |
| `NDMM_IGNORE_ACTIVE_RUN` | *(unset)* | `TRUE` gets past a `started` row a killed process left behind. Use it only once the named run is known to be dead — see **One run per prefix at a time** |

`FINAL_TABLE_NAME` is read into `NDMM_FINAL_TABLE_NAME` by the ported constants
and used by nothing: it named the parent cohort table this build no longer
reads. It is left in place so `R/nndm_constants.R` stays line-for-line with its
source, and setting it does nothing.

## Status

Never run against Databricks. Nothing here is validated output until it has
been, and the count compared against the source implementation patient by
patient.
