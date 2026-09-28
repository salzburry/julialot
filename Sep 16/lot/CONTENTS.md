# What is in this folder

The lines-of-therapy engine: stage 2 of the five (`ndmm/` → `lot/` →
`variables/` → `TFLS/` → `dashboard/`). It reads the myeloma cohort table stage
1 wrote and the Optum claims behind it, and produces one row per patient and
line: when the line started, what started it, what was in its regimen, when and
why it ended.

Nothing in `lot/` reads outside it: the cohort table is passed in by name, and
no cohort is named anywhere in the folder. `variables/`, `TFLS/` and
`dashboard/` read the tables a run wrote, and the dashboard's and the study
package's test suites read `engine/R/build_lot.R` itself — to hold the table
lists to each other, and to fingerprint the engine for `LOT_RULES_EPOCH`
(`LOT_RULES.md` §1).

## Start here

| read this | for |
|---|---|
| this page | running a build, the checks, the traces and the melphalan package; the test suites; every file and what it does |
| `LOT_RULES.md` | the rules: each one's setting, file and worked example, the pinned contract, what stops a run |
| `PORTING.md` | moving the engine to another database |
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
study. The code lists are read from `CODELIST_DIR`, and each file is hashed as it
is read so the run records which version it used. The settings that decide a
line are pinned (`LOT_RULES.md` §1).

```bash
# a build: cohort table and prefix, optionally the study window
Rscript engine/build.R ndmm_NDMM_COHORT ndmm_
Rscript engine/build.R ndmm_NDMM_COHORT ndmm_ 2018-01-01 2026-03-31
#   or INPUT_COHORT_TABLE, OBJECT_PREFIX, STUDY_START, STUDY_END

# the checks on it (without QC_EXECUTE it lists the catalogue and reads nothing)
QC_EXECUTE=TRUE OBJECT_PREFIX=ndmm_ INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  Rscript qc/run_lot_qc.R

# the traces and the extract (each prints its plan without its _EXECUTE flag)
OBJECT_PREFIX=ndmm_ TRACE_EXECUTE=TRUE Rscript qc/trace_foldin.R
OBJECT_PREFIX=ndmm_ TRACE_EXECUTE=TRUE Rscript qc/trace_returns.R
OBJECT_PREFIX=ndmm_ EXTRACT_PATIDS=<id>,<id> EXTRACT_EXECUTE=TRUE \
  Rscript qc/extract_patients.R
Rscript qc/extract_review.R

# the vignette catalogue, no connection
Rscript validation/run_vignettes.R

# the melphalan comparison (prints the plan without MELP_SIMPLE_EXECUTE)
INPUT_COHORT_TABLE=ndmm_NDMM_COHORT COHORT_PREFIX=ndmm_ \
  MELP_SIMPLE_EXECUTE=TRUE Rscript melphalan/run_melp_simple.R
```

One build per prefix at a time, start to finish: a second run on a prefix that
another run still holds as `started` is refused, and LOT2-5 cannot be continued
in a session of its own, because a rebuild re-reads the code lists and the
cohort and could build LOT1 from one version and `LOT_LONG` from another. There
is no dry-run mode. Each build writes a run log (`PIPELINE_LOG_FILE`, or
`pipeline_run_<time>_<pid>.log` under `OUTPUT_DIR`) holding the warnings, the
messages and the `ERROR:` a run stops on. `qc/run_lot_qc.R` exits 1 when any
check failed, errored or was skipped, so a handover can wait on it.

**A sensitivity build** changes a pinned setting, so it is a different
algorithm: it needs `LOT_CONTRACT_OVERRIDE=TRUE`, goes under a prefix of its
own, and is stamped in `LOT_BUILD_STATUS` so every reader refuses it as the
study's numbers.

```bash
LOT_CONTRACT_OVERRIDE=TRUE INDUCTION_WINDOW_DAYS=90 \
  Rscript engine/build.R ndmm_NDMM_COHORT lot_ind90_
```

### The test suites

```bash
Rscript engine/tests/test_runner.R
Rscript engine/tests/test_line_criteria.R
Rscript qc/tests/test_lot_qc.R
Rscript qc/tests/test_foldin_trace.R
Rscript qc/tests/test_trace_returns.R
Rscript melphalan/tests/test_melp_simple.R
Rscript validation/tests/test_vignettes.R
```

None needs a warehouse. Where python with `duckdb` and `sqlglot` is installed,
the suites also execute the emitted SQL against fixtures and check the numbers
that come back. Without them those blocks say `SKIP`, the rest still runs, and
the suite **exits non-zero** — a run missing its executed blocks is not a clean
run. `ALLOW_SKIPPED_TESTS=TRUE` accepts an incomplete run deliberately; the
skips are printed either way.

---

## The four packages

### `engine/` — builds the lines

The only package here that writes a study run. Entry point
`build.R <COHORT_TABLE> <prefix_> [<study_start> <study_end>]`. A cohort table
must provide `PATID`, `INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`, `DEATH_DT`,
`GDR_CD`, `YRDOB`, `AGE_INDEX_YR`, `FU_DAYS`, `FU_DAYS_CE`, one row per patient,
and must fit the study window the run was given.

| path | what it does |
|---|---|
| `build.R` | Entry point. Takes a cohort table and an output prefix and builds every line for it. Starts the run log. |
| `config.csv` | Every setting as `name,value,description`. |
| `R/build_lot.R` | The runner, and `CONTRACT` — the pinned settings a run is checked against before it starts (`LOT_RULES.md` §1). Also the setting validators, the cohort-input checks, `LOT_TABLES` (the declared list of what a run writes), the build status, the run metadata, the claim-side NDC profile, the `LOT_LONG` checks, the funnel and the face-validity checks. |
| `R/config_lot.R` | Reads the settings into the run's config. Fixes the four source table names. |
| `R/load_inputs.R` | Applies `config.csv` as defaults, never over a value already set. Normalises dates a spreadsheet has reformatted. |
| `R/codelists_lot.R` | Loads the four code lists from `CODELIST_DIR` — `cl_mma_rollup.csv`, `cl_mma_codelist.csv`, `permissible_subs.csv`, `cl_sct_codelist.csv`. No embedded fallback: a missing file stops the run, and each is hashed before and after being read. Reads `permissible_subs.csv` flat (see "The code-list checks"). |
| `R/db_utils_lot.R` | Connection, logging, retry, table naming (`wrk` / `lot_out`), the claim-side NDC key, `materialize()`, the step runner and the run log. |
| `R/line_criteria.R` | Extra criteria on finished lines, declared as data (see "Adding a criterion to a line"). |
| `R/cart_rule.R` | The CAR-T induction rule (`LOT_RULES.md` §6.4). |
| `R/melp_rule.R` | The melphalan short-course rule (`LOT_RULES.md` §4.7), spliced into the end steps because it needs each line's own induction window. `APPLY_MELP_RULE=off` builds without it — the reference arm `melphalan/` measures against. |
| `R/foldin_rule.R` | The returning-drug fold-in (`LOT_RULES.md` §4.8). `APPLY_MAP_FOLDIN=FALSE` builds without it, as a comparison. |
| `R/prior_regimen.R` | The prior-regimen rule and each line's run-out chain (`LOT_RULES.md` §4.3, §5.2), both off `APPLY_OWN_RETURN_FOLD`. |
| `R/steps/01_codelists.R` | Code lists into views, then the consistency checks between them (see "The code-list checks"). |
| `R/steps/02_patient_input.R` | The cohort as the build reads it, snapshotted into `LOT_PATIENT_INPUT`. Sets `OBS_END_DT`, the observation end every later gap and window is measured against. |
| `R/steps/03_mma_map.R` | Claims into medication available periods, `MAP_STACKED` (`LOT_RULES.md` §2, §5.1). |
| `R/steps/04_lot1_base.R` | Line 1's start, its induction medications and its base regimen. |
| `R/steps/05_sct.R` | Transplant and CAR-T events: autologous, allogeneic, CAR-T (`LOT_RULES.md` §6), and the SCT code-list checks. |
| `R/steps/05b_lot1_sct.R` | Line 1's own transplant summary, which needs line 1's base. |
| `R/steps/06_lot1_end.R` | Line 1's end date and end reason, including the discontinuation confirmation buffer. |
| `R/steps/07_qc.R` | Counts on what was just built, logged with the run; the impossible ones are checked again, fatally, in `check_lot1_invariants()`. |
| `R/steps/08_persist.R` | Writes `LOT_RUN_METADATA` and `LOT_QC_SUMMARY`. Every other table is written by the step that builds it, all through `lot_out()`, so every name carries the prefix. |
| `R/steps/10_lot2_5_base.R` | Lines 2 to 5: their start candidates, regimens, run-outs and ends, and `LOT_LONG`. The file that decides where later lines begin. |
| `tests/test_runner.R` | The cohort switch, the contract, the setting validators, the criteria layer, the declared outputs against what the steps write. |
| `tests/test_line_criteria.R` | The per-line criteria layer. |
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
| `LOT_RUN_METADATA` | the settings the run used (`CONTRACT_SETTINGS`), the engine's code fingerprint (`CODE_MD5`), the study window, the cohort run it was built from, the line criteria applied (`LINE_CRITERIA_APPLIED`, as `no_belantamab=on:truncate:<patients failing>`), and the line counts |
| `LOT_CODELIST_METADATA` | each code-list file's hash and row count |
| `LOT_QC_SUMMARY` | one row per LOT1-stage consistency count (code-list medications with no rollup row, episodes ending before they start, LOT1 ending after observation, a transplant both tandem and single), each `PASS`, `WARN` or `ERROR` |
| `LOT_PATIENT_INPUT`, `MAP_STACKED`, `TX_AUTO_DATES`, `TX_ALLO_CART_DATES`, `PERMISSIBLE_SUBS` | the inputs line assembly reads (`PORTING.md` gives their columns) |
| `MMA_MED_PROCESSED`, `SCT_CLAIMS_RAW` | the extracted drug and transplant claims |
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
The shipped criterion is `LOT_RULES.md` §8.

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

`R/steps/01_codelists.R` checks the code lists before any claim is read. Every
finding stops the build unless it is waivable **and** named in
`CODELIST_WAIVERS` (comma-separated). Run with no waivers first: a check that
fires is evidence about the production code lists. These can be waived, each
once the study team has reviewed the finding:

| check | the finding |
|---|---|
| `orphan_meds` | a code-list medication with no rollup row |
| `uncoded_meds` | a rollup medication with no NDC or HCPCS code |
| `code_types` | a code type other than NDC or HCPCS, which nothing extracts |
| `subs_substitute` | a `substitute_med` the code list never produces |
| `subs_original` | an `original_med` the code list never produces |
| `ndc_short` | a ten-digit NDC, padded as if 4-4-2 (below) |

These cannot, and naming one in `CODELIST_WAIVERS` is refused before the build
starts. Each means a claim counted twice, a code matching every claim with no
code, a medication with no class or two, or an output column that is always
zero:

```
code_to_med  bad_ndc  rollup_defs  blank_keys  ndc_shape  spaced_med_abbr
multi_class  multi_original  class_agreement  subs_chain  subs_star
```

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
than 20 rollup medications or 50 code-list entries), and on the SCT code-list
checks in `R/steps/05_sct.R`, which are on neither list.

**NDC shape.** The code-list side of the join pads whatever digits it finds to
eleven — `lpad(regexp_replace(CL_CODE, '[^0-9]', ''), 11, '0')`. `ndc_shape` is
for codes that cannot be an NDC in any form: letters, more than eleven digits,
fewer than ten.

`ndc_short` is for ten-digit codes, and the pad gets most of them wrong. Ten
digits is a real FDA form with three layouts — 4-4-2, 5-3-2 and 5-4-1 — and the
eleven-digit form is made by inserting a zero into the short segment, not at the
far left. `50242-040-62` is 5-3-2, so it becomes `50242004062`; the left-pad
produces `05024204062`, a different key. The conversion has to happen in the
file. Waive `ndc_short` only once the study team has confirmed the ten-digit
entries are 4-4-2, the one layout the pad gets right.

The claim side is profiled, not gated. `check_claim_ndc()` in `R/build_lot.R`
counts the NDC shapes on both claim tables before any claim is extracted and
logs them. The claim key (`ndc_key()`) takes eleven digits as they are, pads
ten digits on the 4-4-2 layout, and gives no key at all to anything else —
letters, all zeros, other lengths — so those match nothing rather than
colliding with a real code. A material count of ten-digit claim NDCs wants a
crosswalk.

**Steroids** are maintained separately, so their codes are not in
`cl_mma_codelist.csv`, and both places that build the rollup drop them by class
as well. The rollup file itself should not list them either — QC check `D3`
reports whether the production copy does. That edit is made on the server by
hand; no script here makes it.

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

### `qc/` — 40 checks on a finished run

Reads only, and duplicates no check the build already makes. Not a
re-implementation of the rules: each check states a property the lines must
have and counts the rows that break it. `fail` is something the algorithm's own
definition says cannot happen, `warn` is worth reading, `info` is counted and
never scored; a check that could not run is reported as an error, not a pass. A
run is judged by its own recorded `CONTRACT_SETTINGS`, not by `config.csv`.
Every script that reads the warehouse refuses a run whose build did not
complete, and a run that deviated from the contract unless
`QC_ALLOW_DEVIATION=TRUE`.

The report names an example row for each finding, with the patient identifier
masked to its last six characters so the file can be circulated. The traces
write ids whole by default, because they exist so a patient can be looked up on
the platform (`TRACE_MASK_PATID=TRUE` masks them); the extract masks by default,
because it is written to be carried off it (`EXTRACT_MASK_PATID=FALSE` writes
ids whole). Masking is the same last-six rule everywhere, so the files still
join.

| path | what it does |
|---|---|
| `run_lot_qc.R` | Runs the catalogue against a finished run. Lists the checks and reads nothing without `QC_EXECUTE=TRUE`; needs `OBJECT_PREFIX` and `INPUT_COHORT_TABLE` (the whole cohort table name). Writes `out/lot_qc_report.md`: each check's count and an example row, **why it matters** for anything that did not pass, and the declared limits of any check that has them (`C5`), printed whatever the check counted because a limit changes how a zero reads. Exits 1 when any check failed, errored or was skipped. |
| `R/checks.R` | The checks as data — each with its severity, what it looks for, why, the tables it needs, the query that finds violations, and `limits` where there is something it cannot see. |
| `trace_foldin.R` | The patients the fold-in rule (`LOT_RULES.md` §4.8) touched in a finished run, each one's raw MAP episodes beside the final lines with the folded episode marked, to `out/foldin_trace.md` and CSVs. `TRACE_N` (default 10) patients, or `TRACE_PATIDS` names them. The persisted tables carry no fold flag, so it reads the fold's signature: a regimen drug the previous line carried, no episode inside the line's induction window, and an episode inside the line. |
| `R/foldin_trace.R` | The queries, the sample and the rendering behind that trace. Connection-free. |
| `trace_returns.R` | Every drug that came back, in three kinds: a previous-line drug that folded into the line it returned in (§4.8), a line's own drug that came back after a confirmed break and stayed in its line (§4.3), and an earlier drug that came back and opened a line. Raw episodes beside the final lines, each return annotated with what the rules did and what a reading without §4.3 and §4.8 would have made of it. `TRACE_LINES` (default `1,2`; empty for every line), `TRACE_KINDS`, `TRACE_N` (default 12), `TRACE_PATIDS`. Writes `out/returns_trace.md` and four CSVs. |
| `R/return_trace.R` | The three signatures, the sample, the summary, the annotation and the rendering behind `trace_returns.R`. The fold is `foldin_trace.R`'s own query. Connection-free. |
| `trace_returns_example.R` | Renders `trace_returns.R`'s report on the fixture patients to `examples/returns_trace_example.md`. No connection; needs python with DuckDB and sqlglot. |
| `examples/returns_trace_example.md` | That rendered example, on invented patients, one per shape. Generated; the suite holds it to a fresh render. |
| `extract_patients.R` | Writes named patients' LOT **inputs** out of a finished run as CSVs to `out/extract/` (`EXTRACT_DIR`), so the real rows can be put back through the engine off the warehouse. `EXTRACT_PATIDS` names them. Writes `LOT_PATIENT_INPUT`, `MAP_STACKED`, `TX_AUTO_DATES`, `TX_ALLO_CART_DATES`, `PERMISSIBLE_SUBS`, the run's drug universe (`MED_UNIVERSE`) and `LOT_LONG_FINAL`, plus `RUN_PIN.csv` with the run id, code hash and contract settings. |
| `extract_review.R` | Reads that extract (`out/extract`, or a folder given as its argument) and prints every treatment inside a line whose regimen does not name it, with the two things §4.8 turns on — whether the drug was in the previous line's regimen, and whether a transplant opened a line between its previous course and this one. It decides nothing: the advance count is not computable from the extract. No connection, no python. |
| `tests/test_lot_qc.R` | Each check answers the same shape, reads only the tables it declares, masks every patient id and turns a count into the right verdict; this page's heading quotes the catalogue's size; and, with DuckDB, each check counts nothing on a clean fixture and counts the error it describes. |
| `tests/exec_cases.R`, `tests/exec_harness.R` | The clean fixture and the error planted per check, and the runner that executes the checks against them, transpiled to DuckDB. |
| `tests/test_foldin_trace.R` | The fold-in trace reads the fold's signature and nothing else, samples the same patients every time, and renders what the fixtures say. |
| `tests/test_trace_returns.R`, `tests/returns_fixture.R` | Each kind reads its signature and nothing else, the queries return exactly the planted returns and none of the controls, the example is a fresh render, and no fixture line is a shape the engine could not have built; the fixture patients, one per shape, shared with the example. |
| `tests/run_duckdb.py`, `tests/run_duckdb_rows.py` | Execute a statement against fixture tables through sqlglot and DuckDB and report the count or the rows. A statement that could not run is reported, not read as an empty result. |

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

### `melphalan/` — what the melphalan rule does to the numbers

Two complete LOT builds, differenced: one with the rule (`LOT_RULES.md` §4.7)
and one with `APPLY_MELP_RULE=off`. The difference is the evidence for the rule,
kept runnable.

Opt-in, and it cannot become a study run by accident. `run_melp_simple.R`
writes its cells under `melp_simple_reference_` and `melp_simple_simplified_`,
a plan that would write to the study's prefix is refused, and the rule-off cell
launches with `LOT_CONTRACT_OVERRIDE` and is stamped in `CONTRACT_DEVIATIONS`,
so every reader refuses it as the study's numbers. The cell that carries the
rule is the contract build. Both cells carry the contract's 28-day course cap:
the package varies whether the rule runs, not the threshold.

| path | what it does |
|---|---|
| `run_melp_simple.R` | Builds the two cells and reads them. Prints the plan by default; `MELP_SIMPLE_EXECUTE=TRUE` builds, `MELP_SIMPLE_READ=TRUE` reads cells already built. |
| `read_melp_summary.R` | Three summaries off built cells: the change in each line's duration; how many lines contain melphalan and how many are melphalan alone (among the non-steroid agents, so melphalan with a steroid reads as alone); and how many patients receive a transplant in a melphalan-containing line, by line. Writes five CSVs. Reads cells under `melp_simple_<cell>_`; `MELP_PREFIX_BASE` names another prefix base. Before its schema, password and provenance checks it removes the reports an earlier read wrote (the names are in `R/cells.R`), so a read stopped by a check leaves no stale report; a failure while loading its settings or helpers comes before that and can leave them in place. |
| `R/cells.R` | The cell plan, the provenance checks that hold both cells to one cohort and one build of the engine, and the metrics read off each. |
| `tests/test_melp_simple.R` | `off` really is the absence of the rule, every spliced fragment opens with its own newline, a cell cannot write over the study's tables or be read from a build it does not match, and — with DuckDB and sqlglot — the metrics and the rule's decision chain return the answers the fixtures work out by hand. |
| `tests/exec_cells.R` | Whole-patient fixtures, and what every metric must count over them. |
| `tests/exec_rule.R` | One line per patient, one branch of §4.7 apiece — a confirming agent on the course's last covered day, a hold capped at the line's span, a course an earlier line owned. |
| `tests/run_duckdb.py` | Executes a statement against a fixture, transpiling Spark to DuckDB; reports a statement it could not run rather than reading it as empty. |
