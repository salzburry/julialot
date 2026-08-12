# NDMM (1L newly-diagnosed multiple myeloma) cohort

Builds the 1L NDMM cohort and its attrition for one cohort prefix.

```
DATABRICKS_PWD=... Rscript build.R <prefix_>
DATABRICKS_PWD=... Rscript build.R mystudy_
```

`build.R` builds the 1L cohort only. The 2L and 3L subset cohorts are a
separate step, `build_subsequent_cohorts.R`, which runs after the LOT build -
see "The 2L and 3L cohorts come after the LOT run" below.

### One run per prefix at a time

Every table is named work schema + prefix + table, with no run id in it, so two
runs on the same prefix would replace tables the other is reading through and
both report "complete". `check_no_active_run()` refuses the second before it
writes anything. Two runs on different prefixes are safe, and that is how two
cohorts are built at once - and how a throwaway run is done without touching
anything.

It is a check, not a lock, so two runs starting in the same moment can both
pass it. A killed process leaves its `started` row behind for ever;
`NDMM_IGNORE_ACTIVE_RUN=TRUE` gets past one, and should be used only once the
named run is known to be dead.

A status table that is not there is the first run on a prefix and passes. Any
other failure to read it - a refused SELECT, a dropped connection, a table of
another shape - stops the run instead. Those used to take the first-run path
too, which turned this check off for the length of a build at exactly the
moments the warehouse was misbehaving. `NDMM_IGNORE_ACTIVE_RUN=TRUE` gets past
that as well, with the reason logged.

A re-run keeps its run id, so `NDMM_ATTRITION`, `NDMM_RUN_METADATA` and
`NDMM_CODELIST_METADATA` are cleared of this run's rows before the first step -
otherwise a failed attempt leaves a row naming the code that built a cohort
this attempt did not build. A clear that is refused stops the run.

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
`other_malig.csv`, `pregnancy.csv`, `clintrial.csv` (the descriptive trial
flag). The md5 of each is written to
`<prefix>NDMM_CODELIST_METADATA`, so a cohort can be traced to the files that
built it.

### It needs no table from another build

It reads raw CDM and its own code lists, nothing else. MM diagnosis, age and
demographics use the same rules as the `overall` package
(`R/steps/00_mm_cohort.R`), applying two criteria - a qualifying diagnosis, and
age >=18 in its calendar year - and `tests/test_same_as_overall.R` holds the two
packages together. The 1L index comes from claims
(`R/steps/00b_lot1_index.R`), and belantamab is read off
`cl_mma_codelist.csv`.

### The study period

01 Jan 2016 through 31 Mar 2026. It sets the pregnancy window, the MM-diagnosis
window, and - through `USE_QUARTERLY_TABLES` - which cumulative Optum tables are
read (`2026q1`).

### Views read more than once are checkpointed to tables

A temporary view is a query, not a result - Spark re-runs it on every read, and
these views sit on each other, so a second read of `NDMM_LOT1_STARTS` re-runs
the whole MM-diagnosis chain beneath it across the raw claim tables. It is read
twenty-one times. Every view read more than once is written to the work schema
once and the view repointed at the table; the steps are untouched and still
name the view. `tests/test_runner.R` counts the reads the way the SQL makes
them and fails if a view read more than once is missing from `CHECKPOINTS`.

A checkpoint that cannot be written stops the build. Falling back to the view
would still give the right numbers, but it turns minutes into hours with nothing
said, and a table declared as an output would not be there.

`NDMM_FLAGS_ALL` is checkpointed inside `06_flags.R` rather than by the
runner: `NDMM_PATIDS` is defined over it a few lines below and Spark inlines a
temporary view's plan, so repointing after that view exists would leave it on
the original query.

Every setting is checked twice: against `CONTRACT`, and against the `NDMM_*`
constants the SQL actually interpolates - those have their own environment
variables (`NDMM_LOT1_FROM` is not `LOT1_FROM`), so a contract checked against
`cfg` alone would not speak for the query that runs.

## What every run writes

All prefixed, so two cohorts sit side by side in one schema.

### The cohort, and what made it

| table | what it is |
|---|---|
| `NDMM_COHORT` | the cohort - one row per patient, the ten columns the lot build needs |
| `NDMM_ATTRITION` | the nine-step funnel, with counts and percentages. Belantamab from the index onward is applied in the LOT build |
| `NDMM_FLAGS_ALL` | one row per 1L candidate with every filter's verdict (also a checkpoint) |
| `NDMM_CLINTRIAL_FLAGS` | one row per 1L patient with trial evidence cut at the 1L start - descriptive, not a filter |
| `NDMM_RUN_METADATA` | the md5 of every R file, the contract as one string, the run choices, the waivers asked for and the waivers that fired, and any findings the run reported |
| `NDMM_CODELIST_METADATA` | the md5 and row count of every code list read |
| `NDMM_BUILD_STATUS` | started / complete / failed, per run and prefix - what `check_no_active_run()` reads |

### Clinical trial, on this build's index

The study team asked whether the POMA recorded at 1L really was first line, or
whether trial therapy came before it. The broad build already flags clinical
trial, but on its index - a diagnosis-based candidate - and its two flags
each miss half the answer: `CLINTRIAL_BASELINE` ends the day before that index,
so it never sees the diagnosis-to-1L stretch, while `CLINTRIAL_FOLLOWUP` starts
there and runs past 1L, mixing that stretch with evidence from after treatment
began. The window that matters is in neither.

`NDMM_CLINTRIAL_FLAGS` cuts the windows at the 1L start instead:

| column | window |
|---|---|
| `CLINTRIAL_PRE_DX` | before the MM diagnosis |
| `CLINTRIAL_DX_TO_LOT1` | diagnosis to the day before 1L - the one that was missing |
| `CLINTRIAL_POST_LOT1` | 1L onward - context, never evidence of a prior line |
| `CLINTRIAL_PRE_LOT1_12MO` | the twelve months before 1L |
| `CLINTRIAL_FIRST_PRE_LOT1_DT`, `CLINTRIAL_DAYS_BEFORE_LOT1` | when, over any claim before 1L |
| `CLINTRIAL_FIRST_DX_TO_LOT1_DT`, `CLINTRIAL_DX_TO_LOT1_DAYS` | when, over the diagnosis-to-1L window only |

Two timing pairs, not one, because a timing figure has to be about the same
claims as the count it is printed beside. `CLINTRIAL_DAYS_BEFORE_LOT1` covers
any claim before 1L, so a patient whose only trial code predates their
diagnosis contributes to it while contributing nothing to
`CLINTRIAL_DX_TO_LOT1` - and one with codes in both windows contributes the
older date. `CLINTRIAL_DX_TO_LOT1_DAYS` is NULL unless
`CLINTRIAL_DX_TO_LOT1 = 1`, by construction, so the count and the timing
cannot describe different patients.

The first three partition the study period and can be added. The fourth
spans the first two - it is there because it is the window criterion 3 uses
for prior MM therapy, so the two read side by side; adding it to the others
double-counts.

It is not a criterion and must not become one. Clinical trial does not
filter this cohort. It gets its own table rather than columns on
`NDMM_FLAGS_ALL` because every column there is a criterion or feeds one, and
`ndmm_criteria_where()` reads that table - a descriptive flag sitting among them
invites being read as one. It is built after the flags and joins nothing into
them, so the cohort is identical with it and without it, and
`tests/test_runner.R` fails if a `CLINTRIAL` column reaches either the criteria
list or `06_flags.R`.

`check_icd_flag()` covers these codes too. It asks which claims carry a code
this cohort reads but name no ICD family, and a trial diagnosis or procedure
claim with a blank flag matches nothing and is missed silently - the exact
condition that check exists to surface. The code list is therefore built
before the check; the flag itself needs 1L and the base cohort and stays
after them.

Evidence, not proof. A trial code identifies neither the study drug nor
the condition treated, so a positive flag is a patient to review rather than
a proven prior line, and a zero is not proof that none occurred. The
diagnosis-to-1L interval is also days for one patient and years for another,
so `CLINTRIAL_PRE_LOT1_12MO` - a fixed window - is the more comparable
figure between groups.

The codes come from `clintrial.csv`, the same file and the same normalisation
the broad build uses, so a difference between the two cohorts is about the
window rather than about the codes. That adds a fifth entry to
`CODELIST_FILES`: the file is now required, and its md5 is recorded beside
the other four.

### The review tables

Seven review tables. Each exists because a rule is silent, a code
list cannot answer, or the answer needs a build that has not run yet.
None of them changes the cohort - they are what the decision gets made
against, so nobody has to guess and nobody has to re-run to find out.

| table | the question it answers | what to do with it |
|---|---|---|
| `NDMM_INDEX_AGENTS` | which agents actually set a 1L index | every `CL_MED_ABBR` on the code list, whether this run let it set an index, and how many it set. Review it; bar one with `NDMM_INDEX_EXCLUDED_ABBRS` if it should not have |
| `NDMM_MM_ADJACENT_GROUPS` | which tumour groups are the index disease rather than another cancer | every plasma-cell-looking label, and whether the override reaches it |
| `NDMM_MM_ADJACENT_CODES` | which codes are kept as the index disease rather than another cancer | every code the override keeps, with the label that kept it. No `C79.5x` is among them: `C79.51`, `C79.52` and `198.5` are metastatic cancers and exclude - see `DECISIONS.md` section 4 |
| `NDMM_OTHER_MALIG_GROUPS` | what counts as one tumour type | every ICD category the code list resolves to, with its code and label counts. A category holding one code can only confirm itself |
| `NDMM_OTHER_MALIG_GRAIN` | is that grain actually costing anything? | criterion 7 counted at the finest, configured and coarsest grouping. The gap between the first row and the last is the whole question - if it is small, no map is needed |
| `NDMM_FU_CE_COUNTS` | what the follow-up CE window costs - the one setting resting on a relay, not a document | `N_PASSING_CRITERION_5` and `N_COHORT` at 0 / 30 / 60 / 90 days and at an exact 3 months, with this run's row marked |
| `NDMM_BELANTAMAB_RECONCILE` | which cohort members `lot` will remove | every belantamab claim belonging to a cohort member, with dates, bounded by that patient's own `ENDDATE` - which is the window `lot` reads. Criterion 9 has already removed anyone whose claim precedes their index, so every row is on or after it and `lot`'s `no_belantamab` removes every patient listed. Nothing here needs adjudicating. Under `CENSOR_AT_DISENROLLMENT=TRUE` `lot` narrows further, so the count is an upper bound on a sensitivity run |

This list is maintained by hand and has fallen behind the code before. The
build's own declaration is `OUTPUTS` in `build_ndmm.R`, and
`tests/test_runner.R` holds that to what the run actually writes; read it if
the two disagree.

## The criteria as applied

Written from the code. Where it differs from the study's own wording it says
so.

### Shared with the `overall` package

`R/steps/00_mm_cohort.R` uses the same MM-diagnosis, index-qualification and
demographics SQL as the `overall` package, and `tests/test_same_as_overall.R`
holds the two together. Two criteria are applied here, and no more.

| # | criterion | as applied | source |
|---|---|---|---|
| 1 | MM diagnosis | >=1 inpatient claim with a strict MM code (ICD-9-CM `203.0x` / ICD-10-CM `C90.0x`), or >=2 outpatient claims on separate days within 90 days. The two arms do not use the same codes: strict is required only of the inpatient arm, and the outpatient pair accepts any code on `mm_dx.csv`. Any position on the claim. Inpatient means a place-of-service or type-of-service line flag, or a valid confinement. Claims are bounded to the study period. | `00_mm_cohort.R` |
| 2 | Adult age | >=18 in the calendar year of that diagnosis. Applied after the earliest qualifying date is chosen, so it can only drop a patient - never move their diagnosis date. A patient who qualifies at 17 and again at 18 is excluded. See below. | `00_mm_cohort.R` |

Why age comes after the ranking. Filtering the qualifying dates by age
first would keep the 17-then-18 patient by moving their diagnosis to the later
date. `MM_DX_DT` is not a demographic here - it gates the 1L index, which is
the first MM therapy claim on or after it - so advancing it would let a later
claim be recorded as first line for someone whose real first line was at 17.
Applied after the ranking it can only drop the patient. `overall` does the
same. Attrition step 2 is where the difference lands.

`overall`'s other four inclusion criteria are deliberately not here - six-month
baseline CE, enrolment on the diagnosis date, no MM agent in baseline, >=1 MM
agent in follow-up. They are switches in `overall/config.csv`, not criteria for
this cohort, and this build re-applies CE and baseline therapy at the 1L anchor
instead. `tests/test_same_as_overall.R` fails if any of their columns appears
here.

### Applied here

| # | criterion | as applied | source |
|---|---|---|---|
| 3 | Eligible 1L treatment | the first claim for an MM therapy on or after that patient's MM diagnosis, on or after `LOT1_FROM` (2017-01-01) and on or before the study end. Five arms over raw claims - `PROC_CD`, `BILL_PROC_CD` and `NDC` in `medical`, `NDC` in `rx`, `PROC` in `med_procedure` - each matched against `cl_mma_codelist.csv` and only against the code types that source can carry. Belantamab cannot set it - an eligible 1L treatment is one other than belantamab; steroids cannot either, being dropped from the code list. That date is the NDMM index. | `00b_lot1_index.R` |
| 4 | 12-month CE before index | an enrollment span covering `[index - 365, index - 1]` in full, gaps of <=30 days treated as continuous | `01_enrollment.R`, `06_flags.R` |
| 5 | Follow-up CE | a no-gap span covering `[index, index + FU_CE_DAYS]`, where `FU_CE_DAYS = 0` - one day: the index date itself | `06_flags.R` |
| 6 | No MM oncology therapy in the 12-month baseline | no claim for an MM therapy in `[index - 365, index - 1]`, read from raw claims against `cl_mma_codelist.csv` over five sources - `PROC_CD`, `BILL_PROC_CD` and `NDC` in `medical`, `NDC` in `rx`, `PROC` in `med_procedure`. Steroids are excluded (`DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE`) - a steroid claim alone does not make a patient previously treated. | `03_prior_therapy.R` |
| 7 | No other cancer in the 12-month baseline | excluded on >=1 inpatient claim, or >=2 outpatient claims within 30 days of each other for the same cancer - both claims inside `[index - 365, index - 1]`. Inpatient is established from the confinement table and the claim header, not from a place-of-service code. Plasma-cell tumour groups are the index disease and do not count. "The same cancer" is the three-character ICD category for a primary, and one shared group for metastatic codes, which pair with each other whatever the site - both below. | `04_other_malig.R` |
| 8 | No pregnancy | excluded on >=1 medical claim with a diagnosis, procedure or revenue code indicating pregnancy or childbirth, anywhere in `[2016-01-01, 2026-03-31]` - the study period, not the baseline | `05_pregnancy.R` |
| 9 | No belantamab before the 1L index | any claim for a belantamab code from `cl_mma_codelist.csv`, in `medical`, `rx` or `med_procedure`, dated strictly before the index. This is half of the belantamab exclusion - the half `lot` cannot see, because the claims it reads start at the index. The other half, belantamab from the index onward, is `lot`'s `no_belantamab` line criterion. Overlaps #6 by design: that one already removes belantamab inside the 12-month baseline, so this one's incremental drop is the patients whose belantamab predates it | `00b_lot1_index.R`, `06_flags.R` |

Four of the nine need a number from a real run before anyone can sign them
off. Each is decided and implemented - `DECISIONS.md` is the record - and each
writes a review table saying what it cost, so the confirmation is a reading
rather than a rewrite:

| criterion | what the run has to settle | read it from |
|---|---|---|
| #3 | which agents actually set the index - the code list is the eligible set, so this is a review rather than a decision | `NDMM_INDEX_AGENTS` |
| #5 | one day of follow-up CE against the study's three months | `NDMM_FU_CE_COUNTS` |
| #7 | which codes stay the index disease rather than another cancer | `NDMM_MM_ADJACENT_CODES` -> `NDMM_MM_ADJACENT_OVERRIDE` in `ndmm_constants.R` |
| #7 | whether the ICD category is the right unit for "same primary tumour type" | `NDMM_OTHER_MALIG_GRAIN`, `NDMM_OTHER_MALIG_GROUPS` |

None of them changes anything until somebody acts. Every file ships empty
and every default is unchanged, so the criteria above are what runs today.

Not applied: clinical-trial participation. It belongs to the broader MM
cohort's funnel, not to this one's four exclusions. Putting it back is a new
step, not a toggle.

Belantamab is matched by drug, not by class. The exclusion names belantamab
and calls it an ADC because it was the only ADC in use for MM at the time. That
describes the drug; it does not widen the criterion to the class.

How belantamab is spelled is an assumption this package cannot check.
`NDMM_BELANTAMAB_ABBR`, default `BELA`, matched as a whole `CL_MED_ABBR`
rather than as a prefix. `lot` matches it the same way - the two have to
recognise the same drug identically, or a code list carrying more than one
`BEL*` spelling would have this build take them all and `lot` take only its
own.

The production CSV is not visible from here, so `build_ndmm_belantamab_codes()`
stops the run on either failure - if the abbreviation matches no row, or if the
list carries another `BEL*` abbreviation this one does not name, which is the
case an exact match would otherwise miss in silence. On the first: otherwise
exclusion 4 would quietly do nothing and belantamab claims could set the 1L
index date. The value used is recorded in `NDMM_RUN_METADATA`. Confirm it
against the production code list before the first run.

### What counts as "another cancer"

Remission does not come into it. The rule is another cancer: >=1 inpatient
or >=2 outpatient codes for the same primary tumour type. No states, no
exemptions.

The override is not a departure from that criterion - it is what makes it mean
what it says. `other_malig.csv` is the study's generic other-cancer code list,
so it can carry codes that ARE the index disease, and excluding on those would
remove patients for having the disease that put them in the cohort.

How far that reaches is unverified: the file is not in this repo, and whether
it carries myeloma's own codes as well as the plasma-cell ones has never been
checked. `NDMM_MM_ADJACENT_GROUPS` selects on `tumor_group LIKE '%MYELOMA%'`,
so the first run says. If they are there, the derived override below is doing
real work; if not, the four labels are the whole mechanism.

So the question is never "is this in remission?" but "is this the index
disease?", and it is answered two ways:

1. Derived. Any code on `mm_dx.csv` is the index disease by definition - that
   same file decides who is an MM patient - so it can never also make them an
   other-cancer patient, whatever its description says. This is the rule that
   matters, and it needs no list to maintain.
2. Listed. Four tumour groups that are adjacent to MM without being on the
   diagnosis list: plasma cell leukemia, solitary and extramedullary
   plasmacytoma, and monoclonal gammopathy (the precursor). MM bone disease is
   not among them - `C79.51`, `C79.52` and `198.5` are metastatic cancers
   and exclude anyway; see below and `DECISIONS.md` section 4.

`other_malig.csv` carries each of those plasma-cell conditions in three
states, each its own `tumor_group`:

| condition | not achieved remission | in remission | in relapse |
|---|---|---|---|
| Plasma cell leukemia | `C9010` | `C9011` | `C9012` |
| Extramedullary plasmacytoma | `C9020` | `C9021` | `C9022` |
| Solitary plasmacytoma | `C9030` | `C9031` | `C9032` |

the override covered only the first column - it anchored on the wording
and split each triple. So a patient was excluded for having another cancer
because their plasma cell leukemia was in remission or in relapse, while an
identical patient whose plasma cell leukemia had not achieved remission was
kept. The disease state was never the question.

All six are overridden by default:

```
NDMM_MM_ADJACENT_STATES=override   # default
NDMM_MM_ADJACENT_STATES=exclude    # keep them in the filter, to compare
```

This makes the cohort larger, and the difference lands on attrition step 7.

The four labels stay required: if the code list does not carry one,
the run stops, because the override would silently fail and patients would be
excluded for an MM-adjacent condition. The six state labels are not
required - their absence would just mean the wording changed.

Every run writes `<prefix>NDMM_MM_ADJACENT_GROUPS`: every tumour group on the
code list that looks plasma-cell related - anything matching `%REMISSION%`,
`%RELAPSE%`, `%PLASMACYTOMA%`, `%PLASMA CELL%`, `%GAMMOPATHY%` or `%MYELOMA%` -
with whether the override reaches it and how many codes it carries. Anything in
it marked `EXCLUDES` is the open question, named in the log.

### Which agents may set the 1L index

The eligible treatments are the MM regimens commonly used in the first line
setting, excluding those restricted to later LOTs (see exclusion first-line
setting, less those restricted to later lines - and the exclusions name exactly
one therapy: belantamab. So nothing else is restricted, and neither does this
build - anything on `cl_mma_codelist.csv` that is not belantamab and not a
steroid can set the index. On the production file that is 25 of 26 agents; see
`DECISIONS.md` section 3.

Annex 2 is not that list. It is "Categorization of SOC Regimens", which the
regimen categorisation calls "an exemplary list of potential treatment
combinations... may be recategorized" - an analysis grouping. Inventing an
allowlist from it would shrink the cohort by a rule nobody could reproduce from
the document.

`<prefix>NDMM_INDEX_AGENTS` - every `CL_MED_ABBR` on the code list, whether
this run would let it set an index, and how many patients it set one for.

### Bone metastasis excludes

Two outpatient claims confirm another cancer only if they are the same cancer,
and they are paired on the three-character ICD category (`substr(dx, 1, 3)`)
rather than on the code list's own label - a label is close to one code per
row, so pairing on it would need the same code twice. Four `tumor_group`
labels are overridden - treated as the index disease rather
than another cancer: monoclonal gammopathy, solitary plasmacytoma,
plasma cell leukemia, extramedullary plasmacytoma. All four are
plasma-cell disease, which is the index disease or its precursor.

Secondary neoplasm of bone is not among them, and that is deliberate.
The rule excludes on the same primary tumour type or metastatic cancer,
and `C79.51`, `C79.52` and `198.5` are metastatic cancers. An earlier override
kept `SECONDARY MALIGNANT NEOPLASM OF BONE` because myeloma bone disease is
commonly miscoded that way; this build follows the stated rule instead and
lets all three exclude. They pair under ICD category `C79` with the rest of the
secondary-neoplasm block.

That makes the cohort smaller, and some of the patients it
removes will be myeloma patients whose bone lesions were coded as metastases.
That cost is accepted - see `DECISIONS.md` section 4.

Every run writes `<prefix>NDMM_MM_ADJACENT_CODES`: every code still kept as
the index disease, with the label that kept it. Four labels now, not five.

### Two outpatient claims pair on the ICD category, or on being metastatic

Criterion 7 Path B is two outpatient claims within 30 days for the same
cancer, and the rule is "the same primary tumor type and/or metastatic
cancer".

`other_malig.csv` cannot express that through its labels: it carries 1,618
distinct `tumor_group` values over 1,643 codes, so a label is a code, and
pairing on it means requiring the identical diagnosis code twice. A cancer
coded at two subsites, or once "in remission" and once not, never confirms
itself.

So the pair is made on the ICD category - the first three characters, on the
already-punctuation-stripped code. Every `C50.x` is breast, every `C34.x` lung,
every `C79.x` a secondary neoplasm, which is the metastatic half of the same
sentence. `C7951 -> C79`, `1985 -> 198`; ICD-10 always starts with a letter and
ICD-9 never does, so the two families cannot land in one group.

This makes the cohort smaller, because claims that never
paired now do. `<prefix>NDMM_OTHER_MALIG_GROUPS` lists every category with its
code and label counts, and `<prefix>NDMM_OTHER_MALIG_GRAIN` prices the category
against the per-label grain and against pairing on any label at all.

Where the category over-groups: `C44` (skin), `C76` and `C80` (ill-defined and
unspecified sites) are broad. In each case both claims are still the same broad
cancer type, which is the unit the rule names.

### The one place this differs from the written rule

Follow-up enrolment - criterion 5. The written rule asks for three months;
the study team confirmed one day for this cohort. So the cohort is
larger than three months would give, and the difference lands entirely on
attrition step 5. The window is `NDMM_FU_CE_DAYS = 0`, named in the contract
rather than written into the SQL. Other cohorts keep three months.

It rests on a request rather than a signed record - the only setting here that
does. `DECISIONS.md` section 1 says what is still needed.

`followup_days.sql` is the follow-up numbers themselves, paste-and-run: the
distribution on both definitions, what ended follow-up, and the same by index
year. It reads this build's own output, so only its last statement needs a LOT
run. The dashboard and the POMA workbook report the same figures over the LOT
population with the same predicates, and a test compares all three.

So the run produces the number the decision should be made against. Every
run writes `<prefix>NDMM_FU_CE_COUNTS`: the cohort size at 0, 30, 60 and 90
days and at exactly three calendar months, with the applied row marked.
`N_COHORT` is the whole conjunction at that window - the cohort you would ship,
not one criterion's count - so the gap between this run's row and the `90 days`
row is what the deviation costs, in patients. It does not change the cohort;
the run still applies `NDMM_FU_CE_DAYS`, and whatever that is set to has a row.

"3 months" is applied as 90 days, because `NDMM_FU_CE_DAYS` is a day count.
`add_months(index, 3)` is the exact reading and lands 0-2 days later; it is its
own row so the difference is a number rather than an assumption. The build
cannot currently be set to the exact-months rule - that would be a code
change, and the table says first whether it is worth one.

### Thresholds worth double-checking

Four thresholds have been written down inconsistently in different places. The
values below are the ones this build uses. Confirm them before a production
run.

| criterion | sometimes written as | this build |
|---|---|---|
| enrollment gaps | `< 30 days` | `<= 30 days` |
| other cancer | `>1 IP or >2 OP` | `>=1 IP or >=2 OP` |
| adult age | `> 18` | `>=18` |
| outpatient MM diagnosis | `> 2 claims` | `>=2 claims` |

Other cancer - criterion 7. An earlier reading bounded only the first of the
two outpatient claims to the baseline. A claim the day before the index and its
confirmation a month after it therefore excluded the patient, on a single
baseline claim, when the criterion asks for two in the baseline. Both are
bounded here.

This can only remove exclusions, so the cohort is larger than the one would
otherwise be built, and the difference lands on attrition step 7. Registered as
a named deviation. If the study team means a post-index claim to be allowed to
confirm baseline disease, this is the line to take back out.

### NDC matching, and what has to be checked before the first run

The prior-therapy scan matches an NDC by stripping non-digits and left-padding
to eleven. That is the 4-4-2 layout. A ten-digit NDC written 5-3-2 or 5-4-1
pads to a different key, so `50242-040-62` - canonically `50242004062` -
becomes `05024204062`: a real prior therapy missed, or the wrong drug matched.
The patient's inclusion turns on it and nothing downstream can see it happen.

`check_ndc_shape()` profiles the values before the scan runs, on both sides of
the join and scoped to the NDMM candidates - from the earlier of the study
start and twelve months before each patient's diagnosis, through the study end
- and stops on any of four conditions:

| check | what it found |
|---|---|
| `claim_ndc_shape` | a claim NDC that cannot be an NDC - letters, wrong length, or all zeros |
| `claim_ndc_short` | a ten-digit claim NDC, where the padding is only right for 4-4-2 |
| `codelist_ndc_shape` | the same on the code list side - fixable at source |
| `codelist_ndc_short` | a ten-digit code on the code list - write it as NDC11 |

The claim-side rows are reported, never gated: a value that keys to nothing
is a non-match, and `ndc_key()` gives no key to anything that is not ten or
eleven digits. The two code-list rows stop the build, because that side is
fixable at source.

### `raw_icd_flag` reports, and does not stop

A claim whose `ICD_FLAG` names neither family while its code is on a list this
cohort reads. It stopped the build until the first production run, where it
found sixteen rows across two CDM tables and halted a build that was otherwise
fine. It now warns.

So the report has to carry the decision instead. It names the codes and which
list each is on, because that is what says how far it reaches: an MM code that
stops matching can exclude a patient, an other-cancer or pregnancy code can
keep one, a trial code moves nobody - trial evidence is descriptive and filters
nothing.

The count and the per-code breakdown are two statements built from one
predicate, so the breakdown is of the rows that were found and not of some
wider set, and they are checked against each other at run time. Long lists are
cut at twenty codes and say how many were left out.

The finding goes on the run's own row as `NDMM_RUN_METADATA.FINDINGS`, with
its magnitude - `raw_icd_flag(16 rows, 15 patient-hits (summed, >= distinct),
2 codes; C9000[MM diagnosis,12r,11p] ...)` - so a cohort found months later
says what it was built over and how much of it, without anyone having kept the
log. The patient figure is a sum over codes and over both CDM tables, so a
patient with two affected codes counts twice; it bounds distinct patients from
above rather than counting them.

`NDMM_ICD_FLAG_MAX_ROWS` stops the build above a row count. It ships empty, so
the build reports at any volume until the study team sets one. Whichever it was
is recorded as `icd_ceiling(...)` in the same column, found or not. It bounds
volume, not composition - `DECISIONS.md` #11.

A run the ceiling stops never reaches the metadata write, and the previous
attempt's row was cleared when it started, so that column would be empty for
exactly the run worth reading. The findings are therefore written to
`NDMM_BUILD_STATUS.FINDINGS` as well, on the row recording the failure. On a
completed run the two agree; on a stopped one only the status row exists.

A count that cannot be read stops, from either CDM source independently: one
source unreadable and the other reporting rows makes the total a partial, and a
ceiling weighed against a partial passes on a volume nobody measured. `NDMM_WAIVERS=raw_icd_flag` is still accepted and now does
nothing - an unrecognised waiver name stops the build as a typo, so removing it
would break the commands that were told to pass it.

Each waiver is accepted separately:
`NDMM_WAIVERS=codelist_ndc_shape,codelist_ndc_short`. Those two are the only
ones that still gate anything; `raw_icd_flag` is accepted and inert. Nothing
outside the three names can be waived, and a waiver naming something else stops
the build as a typo. What was asked for and what actually fired are recorded
apart in `NDMM_RUN_METADATA` - a run can ask for a waiver on a condition that
never occurs.

Run the first production build with no waivers set and read the profile it
prints. That is the point of it.

### NDMM_COHORT is a LOT input

The next stage runs the LOT algorithm over these patients, so this table is
written as a cohort the lot build can be pointed at directly:

```
DATABRICKS_PWD=... Rscript build.R ndmm_NDMM_COHORT ndmm_
```

The cohort table is named with its prefix. This build prefixes everything it
writes, so `OBJECT_PREFIX=ndmm_` makes the table `ndmm_NDMM_COHORT`; `lot` adds
its prefix only to its own outputs and reads the cohort name exactly as given.
Pass the bare name and preflight will stop, saying the table does not exist.

It carries the ten columns that build reads off whatever cohort it is given -
`PATID`, `INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`, `DEATH_DT`, `GDR_CD`, `YRDOB`,
`AGE_INDEX_YR`, `FU_DAYS`, `FU_DAYS_CE` - and `check_ndmm_cohort()` verifies
them, one row per patient, and that the count agrees with the attrition, before
the run finishes.

`INDEX_DATE` is the 1L start. Everything that depends on where the anchor
sits is recomputed from it: age at index, both follow-up lengths, and where
continuous enrollment ends. Only sex, birth year and date of death are
carried over unchanged, because those do not move with an anchor. Carrying
`AGE_INDEX_YR` or `FU_DAYS` measured elsewhere would describe the
MM-diagnosis index, and a LOT run over this table would measure its lines from
the wrong day.

### The 2L and 3L cohorts come after the LOT run

Protocol 6.2.1.1 has an "Additional eligibility for 2L and 3L RRMM Cohorts"
block. Those cohorts are indexed on the start of that line, so lot has to
have found the lines first:

```
DATABRICKS_PWD=... Rscript build_subsequent_cohorts.R ndmm_
```

Three criteria, all the protocol's, and nothing else:

1. received that line - a LOT 2 (or LOT 3) row in `<prefix>LOT_LONG_FINAL`
2. CE for the 12 months before that line's start, gaps of 30 days or fewer
   still continuous
3. CE for 90 days of follow-up from it, no gaps, or death in the window

Death is the only stated alternative, so it is the only thing that shortens
the window. The study end does not: a living patient whose window runs past the
data has not shown the enrolment, and would be included on the data's account
rather than the protocol's.

The enrollment tests read `<prefix>NDMM_ENROLL_SPANS` and
`<prefix>NDMM_ENROLL_SPANS_STRICT`, the two span tables this build already
checkpointed, so no enrollment rule is written a second time.

Both windows are settings of these cohorts:

| setting | default | |
|---|---|---|
| `SUBSEQ_PRE_DAYS` | 365 | days of CE before the cohort index date |
| `SUBSEQ_FU_CE_DAYS` | 90 | days of CE after it, or death, with no gaps |

`SUBSEQ_PRE_DAYS` is deliberately not `PRE_LOT1_DAYS`. That one is pinned
by `CONTRACT` to the value the 1L cohort was built with, so it cannot move
without redefining that cohort; these are a separate question.

Both are counted in days, with `date_sub` and `date_add` - the same shape
`06_flags.R` uses for the 1L windows, so the two follow-up rules differ only in
their number. "3 months" is applied as 90 days here for the same reason it is
at 1L (see "3 months is applied as 90 days" below): `add_months(index, 3)` is
the exact reading and lands 0-2 days later, so 90 is the more permissive of the
two. See `DECISIONS.md` #7 - the day-count reading is a recorded
interpretation.

They are settings, but not free ones. 365 and 90 are pinned the way the 1L
contract pins its windows: any other pair stops the build, because it makes a
different cohort that still lands in `NDMM_COHORT_2L` and `NDMM_COHORT_3L` -
the names everything downstream reads as the study's.
`NDMM_SUBSEQ_OVERRIDE=TRUE` builds it anyway, marked in the log as a
sensitivity.

Whatever they are set to is written into all three outputs as `CE_PRE_DAYS` and
`CE_FU_DAYS`, so a cohort always says which windows made it.

The gap allowance is not settable here. `GAP_DAYS = 30` is baked into the
span tables the 1L build wrote, so changing it moves nothing until that build
is re-run - and `CONTRACT` stops it being changed anyway. A gap longer than
that splits the span, so a 40-day break anywhere inside the 365 days before a
3L start means no single span covers the window and the patient is out.

Each cohort is drawn from the one before it - 2L from the 1L cohort, 3L
from the 2L cohort. The progression is 1L -> 2L -> 3L, and the study design note
says "each subsequent line is a subset of the prior line".

Receiving the lines in order is guaranteed anyway: lines are numbered
sequentially, so a LOT 3 row implies a LOT 2 row. What the chain adds is that
the 2L cohort's enrolment windows must also have been met. Those are not the
same test - a patient can have a gap that fails the follow-up window after 2L
and still be fully enrolled for the 365 days before 3L and the 90 after it.
`N_EXCLUDED_BY_PRIOR` in the attrition counts them: patients who meet 3L's own
three criteria and are dropped only for not being in the 2L cohort. The funnel
is run twice for 3L, once off each population, so that number is counted rather
than inferred.

Writes `<prefix>NDMM_COHORT_2L`, `<prefix>NDMM_COHORT_3L` and
`<prefix>NDMM_SUBSEQUENT_ATTRITION` - a funnel per cohort, so what each
criterion cost is on the record. All three carry `SUBSEQ_RUN_ID`, so a run that
died between them leaves a mismatch rather than a silent mix. It changes
nothing else.

It refuses to run unless the newest `LOT_BUILD_STATUS` row is `complete`, was
built from this cohort, carries no `CONTRACT_DEVIATIONS`, and names the same
cohort attempt (`COHORT_RUN_ID`, `COHORT_STAMP`) that `NDMM_BUILD_STATUS` holds
now. That last one matters because a re-run under one prefix replaces the
cohort and both span tables in place: without it, lines from one attempt and
enrollment from another carry the same names.

Unprovable is refused too, not only mismatched. A missing `NDMM_BUILD_STATUS`,
a metadata row recording no cohort attempt, a status row with no
`INPUT_COHORT_TABLE` or too old to carry `CONTRACT_DEVIATIONS` - each means
the proof is absent rather than failed, and a subset cohort over mixed
vintages looks exactly like a right one. `NDMM_SUBSEQ_ALLOW_UNPROVEN=TRUE`
accepts an unproven lineage by name, on the record; a proven mismatch still
stops with it set.

## The attrition

`<prefix>NDMM_ATTRITION`, one row per step, with the count and the percentage
of the starting population.

The steps follow the study's own order: the inclusions, then the four
exclusions as they are listed, belantamab last. an earlier ordering applied
belantamab first and follow-up CE second-to-last; the final cohort is the same
conjunction either way, but the per-step counts are not.

| # | step | criterion |
|---|---|---|
| 1 | Patients with a qualifying MM diagnosis | inclusion 1 |
| 2 | + aged 18 or over at diagnosis | inclusion 2 |
| 3 | + eligible 1L treatment on or after `LOT1_FROM` | inclusion 3 |
| 4 | + 12-month CE before index | inclusion 4 |
| 5 | + CE during follow-up | inclusion 5 |
| 6 | + no MM oncology therapy in 12-month baseline | exclusion 1 |
| 7 | + no other cancer in 12-month baseline | exclusion 2 |
| 8 | + no pregnancy in study period | exclusion 3 |
| 9 | + no belantamab before the 1L index | exclusion 4, the half this build can see |

Every step is this build's own. Nothing arrives pre-filtered, so each row
of the funnel is a named criterion and the count beside it is
reproducible from this folder alone.

### The table

| column | |
|---|---|
| `RUN_ID` | which run wrote the row; cleared and rewritten as one unit, so a retried insert cannot double it |
| `STEP_NUM` | 1-9, the order above |
| `CRITERION` | the step's label - prose, and meant to be editable |
| `N_PATIENTS` | distinct patients still in at that step |
| `PCT_OF_START` | percentage of step 1, to two decimals |
| `RECORDED_AT` | when |

Counts are distinct patients, never claims, and every step after the third is
one more `AND` on the same `NDMM_FLAGS_ALL` row - a widening conjunction over a
fixed population, not a re-scan. So the funnel can only narrow, and each row is
comparable with the one above it.

Counts reach SQL as digits rather than as R prints them. `as.character(1e5)`
is `"1e+05"`, which a warehouse reads as a double, and a cohort of exactly
100,000 would have been written as one.

### What stops the build

- A step larger than the one above it. The funnel only narrows; a step that
  grows means a join fanned out or a filter hit the wrong population. Checked
  before the table is written, so a fanned-out funnel is never published.
- An empty final cohort. A count of zero is not a result to ship.
- A cohort table whose row count disagrees with step 9. `check_ndmm_cohort()`
  compares the two and stops if they differ, so the delivered table and the
  funnel that describes it cannot drift apart.

### Why the funnel stops at nine, and what `lot` still adds

The belantamab exclusion is split, because no one package can see all of
it. It removes a patient who received belantamab "in any LOT" - and unlike the
three exclusions beside it, that bullet carries no period.

The half applied here is belantamab before the 1L index, criterion 9.
`lot` cannot see it at any price: the claims it reads start at the cohort's
`INDEX_DATE`, so a belantamab line earlier in the patient's history is not in
its data at all. It is not a proxy for anything either - a belantamab claim
before the index is a belantamab line before the index.

The half applied in `lot` is belantamab from the index onward:
`lot/engine/R/line_criteria.R`, criterion `no_belantamab`, switched on by
`APPLY_NO_BELANTAMAB`. It reads `map_stacked` over the patient's whole LOT span,
so it is not bounded by `MAX_LOT` or by where in a regimen the drug sat.

Together the two halves are the study's sentence. See `DECISIONS.md` #2.

What this build still does about belantamab. `NO_BELANTAMAB` is computed and
ships on `NDMM_FLAGS_ALL` as an advisory flag - nothing filters on it, and the
cohort table itself carries only the ten columns LOT reads - over the whole
study period, since its only job is to say who carries a claim at all.
And `<prefix>NDMM_BELANTAMAB_RECONCILE` lists every cohort member with a
belantamab claim and its dates, which is the handover.

"Other than belantamab" is a different rule and stays here.
Belantamab cannot set the 1L index date, and the index is what LOT1 is
anchored on, so that has to be settled before the LOT run. It is enforced by the
anti-join in `00_lot1_index.R`.

So read the two numbers correctly. `<prefix>NDMM_COHORT` is the NDMM cohort
pending half of one exclusion, and the attrition's last row is not the study's
N. The index-onward half of the exclusion runs in the LOT build, so the final
study population is the patients in `LOT_LONG_FINAL` and the final count is
the last row of `LOT_ATTRITION` - nowhere in this package's tables.

## The step files

Nine step files. Each one is a phase of the build, and every rule the cohort
turns on lives in exactly one of them.

| file | what it defines |
|---|---|
| `R/steps/00_mm_cohort.R` | the MM diagnosis, its qualification, and demographics - two criteria |
| `R/steps/00b_lot1_index.R` | the 1L index date, derived from claims, and the two sensitivity tables beside it |
| `R/steps/01_enrollment.R` | continuous-enrolment spans, with and without gaps |
| `R/steps/02_lot1_starts.R` | the 1L starts the funnel counts from |
| `R/steps/03_prior_therapy.R` | the 12-month baseline MM-therapy scan, steroids excluded |
| `R/steps/04_other_malig.R` | what counts as another cancer, and the codes you can decide yourself |
| `R/steps/05_pregnancy.R` | the pregnancy scan over the study period |
| `R/steps/06_flags.R` | one row per candidate carrying every criterion's verdict, and the cohort defined over it |
| `R/steps/07_cohort.R` | the filtered cohort, and the counts the attrition is read from |

The runner, the helpers and the tests are not step files: `R/build_ndmm.R`
holds the order, the contract, the criteria list and the attrition, and
`R/steps` holds the rules it applies.

### The criteria are one list

`NDMM_CRITERIA` in `R/build_ndmm.R` is the cohort definition: one entry per
criterion, in the order the study applies them, each carrying the flag it tests
and the label the attrition prints. Three readers render it - `NDMM_PATIDS`
ANDs all of it, the funnel walks a prefix of it per row, and the two
sensitivity tables take all-but-the-one they vary. Nothing writes the
conjunction out for itself, so the cohort table, the funnel and those tables
cannot disagree about what the criteria are.

### Decisions that change who is in the cohort

Five, each deliberate and each recorded:

| change | direction |
|---|---|
| follow-up enrolment is one day, not three months | larger cohort |
| a code list value that normalises to blank does not match a claim with no code | larger - it can only remove matches that should not have been made |
| both outpatient claims must fall in the baseline, not just the first | larger |
| outpatient claims pair on a mapped tumour type, not on a code description | smaller, and nothing until the map is filled in |


### And to `overall`, where line-for-line is impossible

`tests/test_same_as_overall.R` holds `00_mm_cohort.R` to the `overall` package,
but deliberately not line for line - the two are shaped differently, and
`overall` splits its inpatient / outpatient / qualifying work across three
views where this build needs one. Instead it lifts the clinically decisive
expressions out of `overall`'s files, renames its views to ours, and requires
each word for word: what counts as inpatient, which codes qualify an inpatient
claim, how a diagnosis claim joins its header, the outpatient window, how a
partial death date resolves, which eligibility row wins. Change one on either
side and it fails. It also fails if any of `overall`'s other criteria leak
in - this build applies two of its six.

## Settings

`config.csv`; the environment wins over it. Everything below is read by name.
`CONTRACT` in `build_ndmm.R` is the authority on which settings cannot be
changed without changing the cohort; this list is a description of it.

### To run at all

| setting | default | |
|---|---|---|
| `DATABRICKS_PWD` | (none) | required - the build stops without it |
| `DATABRICKS_DSN` | `RWDE` | ODBC data source |
| `DATABRICKS_CATALOG` | `hive_metastore` | catalog for both schemas |
| `OPTUM_CDM_SCHEMA` | `clnprw_optum` | where the raw CDM lives |
| `PROJECT_WORK_SCHEMA` | (none) | where output goes. Falls back to `DOMINO_USER_NAME`, then `DOMINO_STARTING_USERNAME`; no default, so a build that skipped this stops rather than writing somewhere shared |
| `OBJECT_PREFIX` | (none) | the cohort prefix, or pass it to `build.R`. Must end in `_` |
| `DOMINO_RUN_ID` | a timestamp | identifies the run in every metadata table |
| `OUTPUT_DIR` | `/mnt/artifacts/results` | artifacts |
| `PIPELINE_LOG_FILE` | a dated file | the run log |

### The contract

Change one and it is a different cohort, so `check_contract()` refuses the
run rather than building something the name no longer describes.

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
| `NDMM_BELANTAMAB_ABBR` | `BELA` | how belantamab is recognised on the code list, as a whole abbreviation - it is exclusion 4, so it is pinned. Must equal `lot`'s `BELANTAMAB_MED_ABBR` |
| `USE_QUARTERLY_TABLES` | `TRUE` | read the quarterly CDM tables for the study end |
| `CODELIST_DIR` | `/mnt/code/codelist` | `mm_dx.csv`, `cl_mma_codelist.csv`, `other_malig.csv`, `pregnancy.csv` |
| `TBL_CONFINEMENT` | `confinement` | inpatient stays |
| `TBL_MEMBER_ENROLLMENT` | `member_enrollment` | enrolment spans |
| `TBL_MEMBER_ELIG` | `member_cont_enrollment` | sex and birth year |
| `TBL_DOD` | `dod` | date of death |

Every one is checked twice - against `CONTRACT`, and then against the
`NDMM_*` constants the SQL actually interpolates. Those have their own
environment variables (`NDMM_LOT1_FROM` is not `LOT1_FROM`), so a contract
checked against `cfg` alone would not speak for the query that runs.

### Run choices

Places nothing is settled, or the data has to answer. Each is validated
against the values it may take and recorded in `NDMM_RUN_METADATA`, and none
is pinned to its default - the review tables exist to be acted on.

| choice | default | may be |
|---|---|---|
| `NDMM_MM_ADJACENT_STATES` | `override` | `override`, `exclude` |
| `NDMM_INDEX_EXCLUDED_ABBRS` | (empty) | comma-separated `CL_MED_ABBR` patterns |
| `NDMM_INDEX_EXCLUDED_CODES` | (empty) | comma-separated `TYPE:CODE` or bare codes |
| `NDMM_WAIVERS` | (empty) | `codelist_ndc_shape`, `codelist_ndc_short`, `raw_icd_flag`, by name |

### One way out

| setting | default | |
|---|---|---|
| `NDMM_IGNORE_ACTIVE_RUN` | (unset) | `TRUE` gets past a `started` row a killed process left behind. Use it only once the named run is known to be dead - see One run per prefix at a time |

`FINAL_TABLE_NAME` is read into `NDMM_FINAL_TABLE_NAME` and used by nothing:
it names a cohort table this build does not read. Setting it does nothing.
