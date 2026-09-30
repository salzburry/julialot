# What is in this folder

The lines-of-therapy engine on MDV, and the rule vignettes that go with its
rules. The line rules are the Optum build's; the extraction that feeds them is
MDV's (`README.md`).

## Start here

| read this | for |
|---|---|
| `README.md` | what the MDV port changed in the engine, and why |
| this page | running a build; the test suites; every file and what it does |
| `LOT_RULES.md` | the rules: each one's setting, file and worked example, the pinned contract, what stops a run |
| `PORTING.md` | the seam between extraction and line assembly, which the MDV port was built to |
| `../MDV_RULES.md` | every rule, Optum and MDV side by side, and the decisions still open |
| `engine/config.csv` | every setting, with what each one does |

Paths are relative to `lot/`, and inside a package's table relative to that
package. Every script finds its own folder, so it can be run from anywhere.

---

## Running it

The engine needs R with `DBI`, `odbc` and `glue`. Every run needs
`DATABRICKS_PWD` in the environment and a schema to write to:
`DOMINO_USER_NAME` (e.g. `usr00000`), or `PROJECT_WORK_SCHEMA` to override it.

**Settings.** `engine/config.csv` holds every setting as `name,value,description`.
The environment wins; a variable that is unset or empty takes the file's value,
and the password is never read from the file. The cohort table and the output
prefix are never in the file — the caller passes them — and one prefix is one
study. The code lists are read from `CODELIST_DIR` (the MDV lists,
`/mnt/code/codelist_mdv` by default), and each file is hashed as it is read so
the run records which version it used. The settings that decide a line are
pinned (`LOT_RULES.md` §1).

```bash
# a build: cohort table and prefix, optionally the study window
Rscript engine/build.R mdv_NDMM_COHORT mdv_
Rscript engine/build.R mdv_NDMM_COHORT mdv_ 2018-01-01 2026-03-31
#   or INPUT_COHORT_TABLE, OBJECT_PREFIX, STUDY_START, STUDY_END

# the vignette catalogue, no connection
Rscript validation/run_vignettes.R
```

The cohort table is the MDV cohort build's (`../ndmm/`), and the build checks
its lineage against that build's `NDMM_BUILD_STATUS` under `COHORT_PREFIX`
(the output prefix unless set).

One build per prefix at a time, start to finish: a second run on a prefix that
another run still holds as `started` is refused, and LOT2-5 cannot be continued
in a session of its own, because a rebuild re-reads the code lists and the
cohort and could build LOT1 from one version and `LOT_LONG` from another. There
is no dry-run mode. Each build writes a run log (`PIPELINE_LOG_FILE`, or
`pipeline_run_<time>_<pid>.log` under `OUTPUT_DIR`) holding the warnings, the
messages and the `ERROR:` a run stops on.

**A sensitivity build** changes a pinned setting, so it is a different
algorithm: it needs `LOT_CONTRACT_OVERRIDE=TRUE`, goes under a prefix of its
own, and is stamped in `LOT_BUILD_STATUS` so every reader refuses it as the
study's numbers. On MDV the first ones to run are the day-supply values
(`README.md`, "Day supply"):

```bash
LOT_CONTRACT_OVERRIDE=TRUE MEDICAL_DAY_SUPPLY=21 COHORT_PREFIX=mdv_ \
  Rscript engine/build.R mdv_NDMM_COHORT mdvds21_
```

`COHORT_PREFIX` names the prefix the cohort was built under. It defaults to the
output prefix, so without it this run looks for the cohort's build status under
`mdvds21_`, finds none, and stops at the lineage check.

### The test suites

```bash
Rscript engine/tests/test_runner.R
Rscript engine/tests/test_line_criteria.R
Rscript engine/tests/test_mdv_extract.R
Rscript validation/tests/test_vignettes.R
```

None needs a warehouse. `test_mdv_extract.R` also needs python with `duckdb`
and `sqlglot`: it runs the MDV cohort build and then this engine's MDV
extraction against synthetic MDV. Without them it says `SKIP` and **exits
non-zero** — a run missing its executed blocks is not a clean run.
`ALLOW_SKIPPED_TESTS=TRUE` accepts an incomplete run deliberately; the skip is
printed either way. `../tests/run_all.R` runs these and the cohort's suites
together.

---

## The two packages

### `engine/` — builds the lines

The only package here that writes a study run. Entry point
`build.R <COHORT_TABLE> <prefix_> [<study_start> <study_end>]`. A cohort table
must provide `PATID`, `INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`, `DEATH_DT`,
`GDR_CD`, `YRDOB`, `AGE_INDEX_YR`, `FU_DAYS`, `FU_DAYS_CE`, one row per patient,
and must fit the study window the run was given. On MDV, `ENDDATE_CE` is the
patient's last MDV record, and it is where every line is observed to
(`LOT_RULES.md` §7.6).

| path | what it does |
|---|---|
| `build.R` | Entry point. Takes a cohort table and an output prefix and builds every line for it. Starts the run log. |
| `config.csv` | Every setting as `name,value,description`. |
| `R/build_lot.R` | The runner, and `CONTRACT` — the pinned settings a run is checked against before it starts (`LOT_RULES.md` §1). Also the setting validators, the cohort-input checks, `check_mdv_source()` (every MDV column the extraction reads exists, checked in the preflight, before the status row and any other write), `LOT_TABLES` (the declared list of what a run writes), the build status, the run metadata, the `LOT_LONG` checks, the funnel and the face-validity checks. |
| `R/config_lot.R` | Reads the settings into the run's config, the MDV schema, vintage, table and column names among them. |
| `R/mdv_source.R` | Every MDV table, column and value code the engine reads, as settings, and the selects that read them. The same file as the cohort build's. |
| `R/load_inputs.R` | Applies `config.csv` as defaults, never over a value already set. Normalises dates a spreadsheet has reformatted. |
| `R/codelists_lot.R` | Loads the four code lists from `CODELIST_DIR` — `cl_mma_rollup.csv`, `cl_mma_codelist.csv`, `permissible_subs.csv`, `cl_sct_codelist.csv`. No embedded fallback: a missing file stops the run, and each is hashed before and after being read. Reads `permissible_subs.csv` flat (see "The code-list checks"). |
| `R/db_utils_lot.R` | Connection, logging, retry, table naming (`wrk` / `lot_out`), `materialize()`, the step runner and the run log. |
| `R/line_criteria.R` | Extra criteria on finished lines, declared as data (see "Adding a criterion to a line"). |
| `R/cart_rule.R` | The CAR-T induction rule (`LOT_RULES.md` §6.4). |
| `R/melp_rule.R` | The melphalan short-course rule (`LOT_RULES.md` §4.7), spliced into the end steps because it needs each line's own induction window. `APPLY_MELP_RULE=off` builds without it, as a comparison. |
| `R/foldin_rule.R` | The returning-drug fold-in (`LOT_RULES.md` §4.8). `APPLY_MAP_FOLDIN=FALSE` builds without it, as a comparison. |
| `R/prior_regimen.R` | The prior-regimen rule and each line's run-out chain (`LOT_RULES.md` §4.3, §5.2), both off `APPLY_OWN_RETURN_FOLD`. |
| `R/steps/01_codelists.R` | Code lists into views, the drug list resolved to receipt codes (`MMA_RECEIPTS`), then the consistency checks between them (see "The code-list checks"). |
| `R/steps/02_patient_input.R` | The cohort as the build reads it, snapshotted into `LOT_PATIENT_INPUT`. Sets `OBS_END_DT`, the observation end every later gap and window is measured against. |
| `R/steps/03_mma_map.R` | Drug acts into medication available periods, `MAP_STACKED` (`LOT_RULES.md` §2, §5.1). Split at the seam: `phase_mma_extract()` reads MDV acts, and stops on an oral act with no days supplied whose care setting is neither `MDV_INPATIENT` nor `MDV_OUTPATIENT` (fix the codes, or declare the column `NONE`); `phase_map()` is the line-assembly half. |
| `R/steps/04_lot1_base.R` | Line 1's start, its induction medications and its base regimen. |
| `R/steps/05_sct.R` | Transplant and CAR-T events: autologous, allogeneic, CAR-T (`LOT_RULES.md` §6), and the SCT code-list checks. Split at the seam: `phase_sct_extract()` reads MDV acts and confirmed diagnoses; `phase_sct_cluster()` clusters them. |
| `R/steps/05b_lot1_sct.R` | Line 1's own transplant summary, which needs line 1's base. |
| `R/steps/06_lot1_end.R` | Line 1's end date and end reason, including the discontinuation confirmation buffer. |
| `R/steps/07_qc.R` | Counts on what was just built, logged with the run; the impossible ones are checked again, fatally, in `check_lot1_invariants()`. |
| `R/steps/08_persist.R` | Writes `LOT_RUN_METADATA` and `LOT_QC_SUMMARY`. Every other table is written by the step that builds it, all through `lot_out()`, so every name carries the prefix. |
| `R/steps/10_lot2_5_base.R` | Lines 2 to 5: their start candidates, regimens, run-outs and ends, and `LOT_LONG`. The file that decides where later lines begin. |
| `tests/test_runner.R` | The cohort switch, the contract, the setting validators, the criteria layer, the declared outputs against what the steps write. |
| `tests/test_line_criteria.R` | The per-line criteria layer. |
| `tests/test_mdv_extract.R` | The MDV cohort build, then this engine's preflight, code lists and MDV extraction, run against synthetic MDV in DuckDB, and the rows that come out. |
| `tests/testutil.R` | Shared assertion helpers. Not a suite. |

#### What a run writes

All prefixed. Read `LOT_BUILD_STATUS` before trusting any of them: every
downstream reader resolves the run through it and refuses a run that did not
finish or that deviated from the contract.

| table | what it holds |
|---|---|
| `LOT_LONG` | every line built, one row per patient and line |
| `LOT_LONG_ALLFLAGS` | `LOT_LONG` plus one 0/1 column per declared line criterion, enabled or not |
| `LOT_LONG_FINAL` | the study population: `LOT_LONG_ALLFLAGS` with the enabled criteria applied. A patient a patient-level criterion excludes is absent, not shortened. What the study package reads |
| `LOT_ATTRITION` | the funnel, below |
| `LOT_FACE_VALIDITY` | the face-validity checks, below |
| `LOT_BUILD_STATUS` | one row per run: `STATE` (`started` once preflight passes, then `complete` or `failed`), the cohort, `STUDY_END`, the code-list waivers requested and applied, and `CONTRACT_DEVIATIONS` (empty on a contract build) |
| `LOT_RUN_METADATA` | the settings the run used (`CONTRACT_SETTINGS`), the engine's code fingerprint (`CODE_MD5`), every MDV table, column and value mapping the extraction read (`MDV_SOURCE`, the string the cohort build records too), the study window, the cohort run it was built from, the line criteria applied (`LINE_CRITERIA_APPLIED`, as `no_belantamab=on:truncate:<patients failing>`), and the line counts |
| `LOT_CODELIST_METADATA` | each code-list file's hash and row count |
| `LOT_QC_SUMMARY` | one row per LOT1-stage consistency count (code-list medications with no rollup row, episodes ending before they start, LOT1 ending after observation, a transplant both tandem and single), each `PASS`, `WARN` or `ERROR` |
| `LOT_PATIENT_INPUT`, `MAP_STACKED`, `TX_AUTO_DATES`, `TX_ALLO_CART_DATES`, `PERMISSIBLE_SUBS` | the inputs line assembly reads (`PORTING.md` gives their columns) |
| `MMA_RECEIPTS` | the drug code list resolved to MDV receipt codes: each `RECEIPTCODE` row as written, and each `NAME_ENG` pattern as the drug-master codes it matched |
| `MMA_MED_PROCESSED`, `SCT_CLAIMS_RAW` | the extracted drug acts, and the transplant and CAR-T acts and diagnoses |
| `LOT1_INDUCTION_MEDS`, `LOT1_BASE`, `LOT1_SCT`, `LOT1_CONTAINS_MTX_REG`, `LOT1_BASE_END` | line 1's working |
| `LOT<n>_START_CANDIDATES`, `_START`, `_INDUCTION_MEDS`, `_BASE`, `_SCT`, `_CONTAINS_MTX_REG`, `_BASE_END` | each later line's working, one set per line built |

The working tables stay behind deliberately, so why a patient's LOT3 ended
where it did is a read, not a re-run.

#### Adding a criterion to a line

LOT is defined by the rules in `R/steps`. To require something more of a line —
any line, not only L1 — add it to `LINE_CRITERIA` in `R/line_criteria.R` rather
than editing those rules:

```r
list(
  name    = "l2_started_on_med",
  label   = "L2 started on a drug, not a transplant",
  lines   = 2L,                        # 1L, c(2L, 3L), or "*" for every line
  flag    = "L2_START_IS_MED",
  sql     = "LOT_START_TYPE = 'MED'",  # any expression over lot_long
  on_fail = "flag"                     # or "truncate"
)
```

`flag` only adds the column; `truncate` drops the first failing line and every
later one. Every criterion is computed into `LOT_LONG_ALLFLAGS`; only the
enabled ones are applied to `LOT_LONG_FINAL`. Turn it on with
`APPLY_L2_STARTED_ON_MED,TRUE` in `config.csv`; any value other than `TRUE` or
`FALSE` stops the build rather than leaving the criterion silently off. A
criterion needing patient-level facts `lot_long` does not carry declares
`patients` too — SQL building one row per `PATID` into the view
`lc_<name>_patients`, `LEFT JOIN`ed into the flags view as `p_<name>` — both
names derived from the criterion's, so a rename cannot leave the predicate
reading nothing. A flag that collides with a `LOT_LONG` column, or a criterion
aimed above `MAX_LOT`, stops the build.

The log names each criterion, whether it was applied and how many patients fail
it — the disabled ones too — and the same goes into `LINE_CRITERIA_APPLIED`.
The bundled criterion is `LOT_RULES.md` §8.

#### The funnel

`LOT_ATTRITION`, one row per step, with patients and lines on each and
`PCT_OF_START` / `PCT_OF_PREV`. Not every row is attrition; `KIND` says which:

| `KIND` | what it is |
|---|---|
| `input` | cohort patients handed to LOT |
| `reconciliation` | with a mapped MM therapy episode, then with LOT1 built. On a treatment-indexed cohort such as NDMM these re-derive a fact the cohort build already established, so a drop is the two scans disagreeing rather than patients the study lost — logged as a warning, not as loss |
| `criterion` | one row per enabled `truncate` criterion, cumulative |
| `final` | the study population, `LOT_LONG_FINAL` |
| `progression` | reached LOT1, LOT2, ... to `MAX_LOT`. Nobody was removed here — a patient with no LOT3 did not progress, or their follow-up ended |

`final` must equal the row above it, and `Reached LOT1` must equal `final`.
Either mismatch stops the build, as does a step larger than the one above it.

#### The code-list checks

`R/steps/01_codelists.R` checks the code lists before any act is read. Every
finding stops the build unless it is waivable **and** named in
`CODELIST_WAIVERS` (comma-separated). Run with no waivers first: a check that
fires is evidence about the production code lists. These can be waived, each
once the study team has reviewed the finding:

| check | the finding |
|---|---|
| `orphan_meds` | a code-list medication with no rollup row |
| `uncoded_meds` | a rollup medication with no `RECEIPTCODE` or `NAME_ENG` row, which no act can match |
| `code_types` | a code type other than `RECEIPTCODE` or `NAME_ENG` — an Optum NDC or HCPCS row, say — which nothing extracts |
| `unresolved_names` | a `NAME_ENG` pattern that matches no drug in the drug master: right for an agent not sold in Japan, a misspelling otherwise. Checked whatever `uncoded_meds` found, so waiving one never skips the other |
| `sct_unresolved_names` | the same on `cl_sct_codelist.csv`, checked in `R/steps/05_sct.R`: a CAR-T or transplant pattern matching no drug. Most likely a misspelling (`'%vicleucell%'`), and one that silently removes those events and moves the lines they end |
| `receipt_shape` | a `RECEIPTCODE` that is not nine digits, which matches no act unless the delivery really keys drugs another way |
| `subs_substitute` | a `substitute_med` the code list never produces |
| `subs_original` | an `original_med` the code list never produces |

These cannot, and naming one in `CODELIST_WAIVERS` is refused before the build
starts. Each means an act counted twice, a medication with no class or two, a
supply with no reading, or an output column that is always zero:

```
code_to_med  route  multi_route  rollup_defs  blank_keys  spaced_med_abbr
multi_class  multi_original  class_agreement  subs_chain  subs_star
```

`code_to_med` is checked on the resolved receipt codes: one receipt code
reaching two drugs — two `NAME_ENG` patterns matching one master name, or a
listed code a pattern also finds under another agent — would make one act two
treatment events. `route` and `multi_route` are fatal because `CL_ROUTE`
decides how an act's supply is counted (`LOT_RULES.md` §2.2): a route other
than `ORAL` or `INJ`, or two routes for one code, has no reading that leaves
the lines usable.

`multi_class` is fatal because `min(MED_CLASS)` picks lexically, not
clinically, and the choice reaches the class flags and the steroid exclusion.
`multi_original` is fatal for the same reason: a substitute standing in for two
drugs is collapsed to one of them by `min()`, and that pick decides which
agent's return a §4.8 fold is judging. `spaced_med_abbr` is fatal because a
regimen is one space-joined string, so an abbreviation with a space in it reads
back as two agents that do not exist.

`subs_chain` and `subs_star` hold the substitution table flat: one hop each way
is exact for a pair and wrong for a chain `A -> B -> C` or a star. Before the
checks run the loader reads `permissible_subs.csv` flat: a pair the file lists
both ways is read once (the row whose original sorts first), and a drug listed
as its own substitute is dropped, each with a log line.

The build also stops on a code list too short to be the production one (fewer
than 20 rollup medications or 20 code-list entries: an MDV list naming drugs by
pattern can be one row per agent), and on the other SCT code-list checks in
`R/steps/05_sct.R` - a code naming two transplant types, an `SCT_TYPE` or code
type nothing reads, `ICD10` rows with no ICD-10 column - which are on neither
list. `sct_unresolved_names`, above, is the one SCT check that can be waived.

**Steroids** are maintained separately, so their codes are not in
`cl_mma_codelist.csv`, and both places that build the rollup drop them by class
as well. The rollup file itself should not list them either.

#### Face validity

The structural checks ask whether the output is internally consistent.
`LOT_FACE_VALIDITY` asks whether it looks like myeloma: a run can pass every
structural check with transplants in late lines, CAR-T in first line, or a
median line lasting three days. Each is read off `LOT_LONG_FINAL`.

| check | expects |
|---|---|
| lines containing an autologous transplant that are LOT1 or LOT2 | >= 50% |
| patients whose CAR-T falls at LOT3 or later | >= 50% |
| patients with any allogeneic transplant line | <= 5% |
| LOT2+ lines started by a medication rather than a procedure | >= 60% |
| median LOT1 length in days | 30-1500 |
| LOT1 patients covered by the ten commonest regimens | >= 25% |

Every check records what it found whether or not it passed; a check that
returns no value is reported with the ones outside their band. The bands are
wide plausibility bands, not published benchmarks. Reported, not fatal;
`FACE_VALIDITY_FATAL=TRUE` makes them stop.

### `validation/` — the rule vignettes

The patients the algorithm is hardest on, each with the assignment the rules
give — the worked examples `LOT_RULES.md` cites by id. A **specification**, not
observed output: nothing here has run against a warehouse. Every offset is
derived from the setting that decides it, and the boundary cases come in pairs
straddling that setting by one day. `derived` follows from the rule quoted
beside it; `to_confirm` is a reading of how rules interact that the first real
run settles.

| path | what it does |
|---|---|
| `R/vignettes.R` | The catalogue. A case moves when its setting moves, and a renamed setting fails the catalogue. |
| `run_vignettes.R` | Renders the catalogue against the settings it is run with (`config.csv`, the environment winning) to `out/` (`OUTPUT_DIR` redirects it), and stops if the catalogue disagrees with the config it was resolved against. Re-run it after any change to `R/vignettes.R` and keep what it writes. |
| `tests/test_vignettes.R` | The settings exist, the boundary pairs straddle them by one day and expect different things, the timelines run forwards, the files the rules are quoted from are there — and `LOT_RULES.md` and the catalogue agree in both directions: a rule citing a case that does not exist fails, and so does a case no rule cites. |
| `out/` | Generated: `lot_edge_case_vignettes.csv` and `.md`. Nothing reads it back. |
