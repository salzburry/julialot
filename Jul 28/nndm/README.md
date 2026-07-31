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

- **MM diagnosis, age and demographics** are ported in from `Jul 28/overall`
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
NDMM_FLAGS_ALL         NDMM_MM_DX_CODES       NDMM_MM_DX_EVENTS
NDMM_MM_QUALIFYING     NDMM_BASE_COHORT       NDMM_ENROLL_SPANS
NDMM_MMA_CODELIST      NDMM_BELANTAMAB_CODES  NDMM_INDEX_TX
NDMM_LOT1_STARTS       NDMM_OTHER_MALIG_CODES NDMM_BELANTAMAB_TX
NDMM_BELANTAMAB_PATIDS NDMM_PATIDS
```

The list is not maintained by hand: `tests/test_runner.R` counts the reads in
the SQL and fails if anything read more than once is missing from it. Two
entries the count cannot see are `NDMM_BASE_COHORT` and
`NDMM_BELANTAMAB_PATIDS`, which reach the flags step as parameters.

A checkpoint that cannot be written **stops the build**. The April code
degraded to the in-place view on a write failure — correct arithmetic, but it
can turn minutes into hours without saying so, and a table declared as an
output would then not be there.

`NDMM_FLAGS_ALL` is checkpointed **inside** `06_flags.R` rather than by the
runner. `NDMM_PATIDS` is defined over it a few lines below, and Spark inlines a
temporary view's plan — repointing after that view exists would leave it on the
original query. It was the one materialization that still warned and carried
on; it is the same one call as the other ten now, and it is a deliverable as
well as a checkpoint.

Deliverables, all prefixed: `NDMM_COHORT` (the cohort, written as a table
`Jul 28/lot` can be pointed at — see below), `NDMM_ATTRITION` (the nine rows
below), `NDMM_CODELIST_METADATA`, `NDMM_RUN_METADATA`, `NDMM_BUILD_STATUS`.
`NDMM_FLAGS_ALL` — one row per candidate with every filter's verdict — is both
a deliverable and a checkpoint. The other checkpoint tables are listed above.

`07_cohort.R` still carries `build_lot_long_filtered()`, and `02_lot1_starts.R`
still carries `build_lot1_starts_ndmm()`. The runner calls neither: the first
served the April dashboard, the second read the index date out of `LOT_LONG`.
Both stay in their files so those files remain the source line for line.

`NDMM_RUN_METADATA` carries the md5 of every R file this package ships, the
contract as one sorted string, how belantamab was recognised, the waivers asked
for and the waivers that fired, and the final count.

Every setting is checked twice: against `CONTRACT`, and then against the
`NDMM_*` constants the SQL actually interpolates — those have their own
environment variables (`NDMM_LOT1_FROM` is not `LOT1_FROM`), so a contract
checked against `cfg` alone would not speak for the query that runs.

## The criteria as applied

This section is written from the code, not from the protocol. Where the two
differ it says so. Compare it against the protocol when either changes.

### Derived here, from the parent build's rules

`R/steps/00_mm_cohort.R` is a port of `Jul 28/overall`'s MM-diagnosis,
index-qualification and demographics SQL. Two criteria are applied — the two
§6.2.1.1 names — and no more.

| # | criterion | as applied | source |
|---|---|---|---|
| 1 | **MM diagnosis** | ≥1 inpatient medical claim with a **strict** MM code in any position (ICD-9-CM `203.0x` / ICD-10-CM `C90.0x`), **or** ≥2 outpatient MM claims on separate days **within 90 days**, during the study period. Inpatient means a place-of-service or type-of-service line flag, or a valid confinement. | `00_mm_cohort.R` |
| 2 | **Adult age** | **≥18** in the calendar year of that diagnosis. Applied *after* the earliest qualifying date is chosen, so it can only drop a patient — never move their diagnosis date. A patient who qualifies at 17 and again at 18 is **excluded**. See below. | `00_mm_cohort.R` |

**Why age comes after the ranking.** It used to come before: the qualifying
dates were filtered by age and the earliest survivor became `MM_DX_DT`. That
kept the 17-then-18 patient, by moving their diagnosis date to the later one —
and `MM_DX_DT` is not a demographic here, it gates the 1L index, which is the
*first* MM therapy claim on or after it. Advancing it lets a later therapy
claim be recorded as first line for someone whose real first line was at 17.
`Jul 28/overall` never did this: its age rule is `AND AGE_INDEX_YR >= min_age`
applied to an index date already chosen, which drops the patient. This build
now matches it. The change makes the cohort **smaller**, and the difference
lands entirely on attrition step 2.

**The parent's other four inclusion criteria are deliberately not here** —
six-month baseline CE, enrolment on the diagnosis date, no MM agent in
baseline, ≥1 MM agent in follow-up. They are switches in
`Jul 28/overall/config.csv`, not protocol criteria for this cohort, and NDMM
re-applies CE and baseline therapy at the 1L anchor instead.
`tests/test_same_as_overall.R` fails if any of their columns appears in the
port.

### Applied here

| # | criterion | as applied | source |
|---|---|---|---|
| 3 | **Eligible 1L treatment** | the **first** claim for an MM therapy on or after that patient's MM diagnosis and on or after `LOT1_FROM` (**2017-01-01**), scanned from raw `medical` and `rx` against `cl_mma_codelist.csv`. **Belantamab cannot set it** — §6.2.1.1 says the eligible 1L treatment is one "other than belantamab". Steroids cannot either: the code list has them dropped. That date is the NDMM index. See the note below on which other agents may set it. | `00b_lot1_index.R` |
| 4 | **12-month CE before index** | an enrollment span covering `[index − 365, index − 1]` in full, gaps of **≤30 days** treated as continuous | `01_enrollment.R`, `06_flags.R` |
| 5 | **Follow-up CE** | a **no-gap** span covering `[index, index + FU_CE_DAYS]`, where `FU_CE_DAYS = 0` — **one day: the index date itself** | `06_flags.R` |
| 6 | **No MM oncology therapy in the 12-month baseline** | no medical or pharmacy claim for an MM therapy in `[index − 365, index − 1]`, scanned from raw `medical` and `rx` against `cl_mma_codelist.csv`. **Steroids are excluded from this scan** (`DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE`) — a steroid claim alone does not make a patient previously treated. | `03_prior_therapy.R` |
| 7 | **No other cancer in the 12-month baseline** | excluded on **≥1 inpatient** claim, **or ≥2 outpatient** claims **within 30 days of each other**, for the same tumour group — **both claims inside** `[index − 365, index − 1]`. Inpatient is established from the confinement table and the claim header, not from a place-of-service code. Plasma-cell tumour groups do not count as another cancer — see below. | `04_other_malig.R` |
| 8 | **No pregnancy** | excluded on ≥1 medical claim with a diagnosis, procedure or revenue code indicating pregnancy or childbirth, anywhere in `[2016-01-01, 2026-03-31]` — the **study period**, not the baseline | `05_pregnancy.R` |
| 9 | **No belantamab in any LOT** | any claim for a belantamab code from `cl_mma_codelist.csv`, in `medical` or `rx`, **within the study period** — a claims proxy for LOT membership; see below | `00b_lot1_index.R`, `06_flags.R` |

**Not applied: clinical-trial participation.** The attrition spreadsheet in
`NNDM E/attritom.pdf` lists it as Step 10, but that sheet is the parent MM
cohort's funnel — six-month CE, age 18, the MM diagnosis steps — and protocol
Rev Round 2 §6.2.1.2 has four exclusions, this not among them.
If the study team wants it back it is a new step, not a toggle.

**On belantamab being matched by drug and not by class.** §6.2.1.2 writes the
exclusion as "Received belantamab mafodotin (i.e., an ADC) in any LOT" and
attaches a note:

> at the time of study belantamab mafodotin was the only ADC in use for MM

So "(i.e., an ADC)" names what the drug is; it does not widen the criterion to
the class.

**How belantamab is recognised is an assumption this package cannot check.**
`apr_30_2026` matched `MAP_MED_TYPE LIKE 'BEL%'` in `MAP_STACKED`, a table this
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

`apr_30_2026` overrode **only the first column** — it anchored on the wording
and split each triple. So a patient was excluded for having another cancer
because their plasma cell leukemia was in remission or in relapse, while an
identical patient whose plasma cell leukemia had not achieved remission was
kept. The disease state was never the question.

All six are overridden by default:

```
NDMM_MM_ADJACENT_STATES=override   # default
NDMM_MM_ADJACENT_STATES=exclude    # apr_30_2026's behaviour, to compare
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

**`codelists/eligible_1l_agents.csv`** — one row per agent, and three modes:

```
med_abbr,eligible,note
BOR,1,bortezomib - SOC first line
LEN,1,lenalidomide
CART,0,later lines only
```

| what is in the file | what happens |
|---|---|
| **no rows** (what ships) | no allowlist — any MM therapy sets the index, which is the current cohort |
| **only `eligible=0`** | a deny list — those agents are barred, everything else still sets the index |
| **any `eligible=1`** | an **allowlist** — only those agents set the index, every other agent on the code list is barred |

`eligible=0` is the same thing as naming an agent in
`NDMM_INDEX_EXCLUDED_ABBRS`, in a file rather than an environment variable; the
two combine. Belantamab stays barred whatever the file says. Set
`NDMM_ELIGIBLE_1L_CSV` to use a file elsewhere.

**The allowlist mode is the dangerous one, so it is loud.** An agent left off
does not fail — it silently takes its patients out of the cohort at attrition
step 3. So an allowed `med_abbr` that matches no row of `cl_mma_codelist.csv`
**stops the run** (a typo there is not a restriction applying to nothing, it is
an agent that should have been let through and was not), and the run logs how
many agents the allowlist barred. Malformed rows stop the run for the same
reasons the other fill-in file's do.

If a later-line-only agent appears in it, name it — by the code list's own
abbreviation, or by HCPCS/NDC if that is what you have:

```
NDMM_INDEX_EXCLUDED_ABBRS=CART,TALQ
NDMM_INDEX_EXCLUDED_CODES=HCPCS:J9999,NDC:12345678901
NDMM_INDEX_EXCLUDED_CODES=J9999            # bare code, any type
```

Abbreviations match `CL_MED_ABBR` the way `NDMM_BELANTAMAB_ABBR` does. Codes are
stripped of punctuation and uppercased, the same normalisation the code list
gets — **stripped, not padded to eleven**, because the code list stores its
codes stripped too and the padding happens at the join, so padding here would
stop a ten-digit entry matching the ten-digit code you typed.

Belantamab is always barred whatever is set. An abbreviation or code matching
no row of `cl_mma_codelist.csv` **stops the run** rather than reading as a
restriction that applies to nothing. Both values are pinned in `CONTRACT` and
recorded in `NDMM_RUN_METADATA`, because setting either changes the count.

### Bone metastasis, and the codes you can decide yourself

The other-cancer criterion is decided on `other_malig.csv`'s `tumor_group`
label, and five groups are overridden — treated as the index disease rather
than another cancer. Four of them the label settles: **monoclonal gammopathy**,
**solitary plasmacytoma**, **plasma cell leukemia**, **extramedullary
plasmacytoma** are plasma-cell disease.

The fifth is not like the others. **`SECONDARY MALIGNANT NEOPLASM OF BONE`** —
`C79.51`, `C79.52`, `198.5` — says a cancer spread to bone. It does not say
*which* cancer. Myeloma bone disease is usually coded as MM with bone
involvement, but it is miscoded here too, which is why `apr_30_2026` overrides
the group. A breast or prostate primary metastatic to bone carries the same
code. **The label cannot separate those. A code can.**

So there is a file to fill in:

```
Jul 28/nndm/codelists/mm_adjacent_overrides.csv
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
`apr_30_2026`'s cohort — so nothing changes until you put something in it. Set
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

### Where this departs from the protocol

All protocol references are to `Questions/July 30 2026/Updated NNDM cohort.pdf`
(*Rev Round 2, June 16 2026*), 58 pages. `docs/june_22_2026/NNDM/nmdmprotocol.pdf`
is an earlier draft — its own title bar reads `OLD DO NOT USE` — and its
eligibility text differs. Check the newer file.

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

The one-day rule comes from the study team, relayed in the build request. It is
not written in any document in this repository, and two comments anchored to
that bullet in the protocol PDF are not in the rendered page and have not been
read. Until the decision exists in a controlled source, `FU_CE_DAYS = 0` rests
on that relay alone — worth getting in writing before anyone signs the count.

### Thresholds worth double-checking

The protocol PDF is a scanned document. Its text layer renders four thresholds
wrong; the values below are what the **images** show, and what this build uses.

| criterion | text layer | document, and this build |
|---|---|---|
| enrollment gaps | `< 30 days` | **`≤ 30 days`** |
| other cancer | `>1 IP or >2 OP` | **`≥1 IP or ≥2 OP`** |
| adult age | `> 18` | **`≥18`** |
| outpatient MM diagnosis | `> 2 claims` | **`≥2 claims`** |

**Other cancer — criterion 7.** `apr_30_2026` bounded only the *first* of the
two outpatient claims to the baseline. A claim the day before the index and its
confirmation a month after it therefore excluded the patient, on a single
baseline claim, when the criterion asks for two in the baseline. Both are
bounded here.

This can only remove exclusions, so the cohort is **larger** than the one
`apr_30_2026` builds, and the difference lands on attrition step 7. Registered
as a named deviation. If the study team means a post-index claim to be allowed
to confirm baseline disease, this is the line to take back out.

### NDC matching, and what has to be checked before the first run

The prior-therapy scan matches an NDC by stripping non-digits and left-padding
to eleven. That is the **4-4-2** layout. A ten-digit NDC written 5-3-2 or 5-4-1
pads to a different key, so `50242-040-62` — canonically `50242004062` —
becomes `05024204062`: a real prior therapy missed, or the wrong drug matched.
The patient's inclusion turns on it and nothing downstream can see it happen.

`check_ndc_shape()` profiles the values before the scan runs, on both sides of
the join and scoped to the NDMM candidates and the baseline window, and stops
on any of four conditions:

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
written as a cohort `Jul 28/lot` can be pointed at directly:

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
`apr_30_2026` applied belantamab first and follow-up CE second-to-last; the
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

`apr_30_2026` bounded neither end but the upper one, so a claim from **before
the study period** excluded the patient. That is wrong under either reading,
and is the defect this fixes.

Neither scope is LOT membership. **Only running the LOT algorithm over the
cohort and checking which line a belantamab claim landed in is exact** — that
is a reconciliation pass after `Jul 28/lot`, not something this build can do.
Until then, every run writes `<prefix>NDMM_BELANTAMAB_SCOPE_COUNTS`: how many
1L candidates each of the three readings — `ever`, `study_period`, `from_index`
— would exclude, so the choice can be made against real numbers. The scope in
force is pinned in `CONTRACT` and recorded in `NDMM_RUN_METADATA`.

The build checks that each step is
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
| `STUDY_END` | `2026-03-31` | study period end; picks the quarterly CDM tables |
| `STUDY_START` | `2016-01-01` | study period start; the pregnancy and belantamab scans |
| `OUTPATIENT_WINDOW` | `90` | two outpatient MM claims within this many days confirm a diagnosis |
| `MIN_AGE` | `18` | minimum age in the MM-diagnosis year |
| `CODELIST_DIR` | `/mnt/code/codelist` | `mm_dx.csv`, `cl_mma_codelist.csv`, `other_malig.csv`, `pregnancy.csv` |

Those are the **contract** — change one and it is a different cohort, so
`check_contract()` refuses the run. The settings below are **run choices**:
places the protocol is silent or the data has to answer. Each is validated
against the values it may take and recorded in `NDMM_RUN_METADATA`, but none is
pinned to its default — the review tables exist to be acted on.

| choice | default | may be |
|---|---|---|
| `NDMM_BELANTAMAB_SCOPE` | `study_period` | `study_period`, `from_index` |
| `NDMM_MM_ADJACENT_STATES` | `override` | `override`, `exclude` |
| `NDMM_INDEX_EXCLUDED_ABBRS` | *(empty)* | comma-separated `CL_MED_ABBR` patterns |
| `NDMM_INDEX_EXCLUDED_CODES` | *(empty)* | comma-separated `TYPE:CODE` or bare codes |
| `NDMM_WAIVERS` | *(empty)* | the four NDC-shape checks, by name |

## Status

Never run against Databricks. Nothing here is validated output until it has
been, and the count compared against the source implementation patient by
patient.
