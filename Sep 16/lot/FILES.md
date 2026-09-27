# Every file in `lot/`

Every file and what it does, what a run writes, and the how-to material the code
points at. `CONTENTS.md` is the short page and has the commands and the test
suites; `LOT_RULES.md` is the rules.

Inside each package's table, paths are relative to that package — `R/build_lot.R`,
`tests/test_runner.R` — and every script finds its own folder, so it can be run
from anywhere.

Nothing in `lot/` reads outside it: the cohort table is passed in by name, and
no cohort is named anywhere in the folder. `variables/`, `TFLS/` and
`dashboard/` read the tables a run wrote, and the dashboard's and the study
package's test suites read `engine/R/build_lot.R` itself — to hold the table
lists to each other, and to fingerprint the engine for `LOT_RULES_EPOCH`
(`LOT_RULES.md` §1).

---

## `engine/` — builds the lines

Entry point `build.R <COHORT_TABLE> <prefix_> [<study_start> <study_end>]`, or
the same four as `INPUT_COHORT_TABLE`, `OBJECT_PREFIX`, `STUDY_START`,
`STUDY_END`. One run per prefix at a time, start to finish — LOT2-5 cannot be
continued in a session of its own, because a rebuild re-reads the code lists and
the cohort and could build LOT1 from one version and `LOT_LONG` from another.

A cohort table must provide `PATID`, `INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`,
`DEATH_DT`, `GDR_CD`, `YRDOB`, `AGE_INDEX_YR`, `FU_DAYS`, `FU_DAYS_CE`, one row
per patient, and must fit the study window the run was given.

| path | what it does |
|---|---|
| `build.R` | Entry point. Takes a cohort table and an output prefix, and builds every line for it. Starts the run log. |
| `config.csv` | Every setting as `name,value,description`. The environment wins over it. The cohort table and prefix are not here; the caller passes them. |
| `R/build_lot.R` | The runner, and `CONTRACT` — the pinned settings a run is checked against before it starts (`LOT_RULES.md` §1). Also the setting validators, the cohort-input checks, `LOT_TABLES` (the declared list of what a run writes), the build status, the run metadata, the `LOT_LONG` checks, the attrition funnel and the face-validity checks. |
| `R/config_lot.R` | Reads the settings into the run's config. |
| `R/load_inputs.R` | Applies `config.csv` as defaults, never over a value already set, and never reads the password from it. Normalises dates that a spreadsheet has reformatted. |
| `R/codelists_lot.R` | Loads the four code lists from CSV under `CODELIST_DIR` — `cl_mma_rollup.csv`, `cl_mma_codelist.csv`, `permissible_subs.csv`, `cl_sct_codelist.csv`. No embedded fallback: a missing file stops the run, and each is hashed before and after being read. Reads `permissible_subs.csv` flat (see "The code-list checks"). |
| `R/db_utils_lot.R` | Connection, logging, retry, table naming (`wrk` / `lot_out`), the claim-side NDC key, `materialize()` and the step runner. The run log: `start_run_log()` tees the console into `PIPELINE_LOG_FILE`, or `pipeline_run_<time>_<pid>.log` under `OUTPUT_DIR`; `run_logged()` writes warnings, messages and the `ERROR:` a run stops on into it. |
| `R/line_criteria.R` | Extra criteria on finished lines, declared as data. Every one is computed into `LOT_LONG_ALLFLAGS`; only the enabled ones are applied to `LOT_LONG_FINAL`. |
| `R/cart_rule.R` | The CAR-T induction rule (`LOT_RULES.md` §6.4). |
| `R/melp_rule.R` | The melphalan short-course rule (`LOT_RULES.md` §4.7). Spliced into the end steps because it needs each line's own induction window. `APPLY_MELP_RULE=off` builds without it, which is the reference arm `melphalan/` measures against. |
| `R/foldin_rule.R` | The returning-drug fold-in (`LOT_RULES.md` §4.8). `APPLY_MAP_FOLDIN=FALSE` builds without it, as a comparison. |
| `R/prior_regimen.R` | The prior-regimen rule and each line's run-out chain (`LOT_RULES.md` §4.3, §5.2), both halves off `APPLY_OWN_RETURN_FOLD`. |
| `R/steps/01_codelists.R` | Code lists into views, then the consistency checks between them — which are fatal, which are waivable through `CODELIST_WAIVERS`, and why. |
| `R/steps/02_patient_input.R` | The cohort as the build reads it, snapshotted into `LOT_PATIENT_INPUT`. Sets `OBS_END_DT`, the observation end every later gap and window is measured against. |
| `R/steps/03_mma_map.R` | Claims into medication available periods, `MAP_STACKED` (`LOT_RULES.md` §2, §5.1). |
| `R/steps/04_lot1_base.R` | Line 1's start, its induction medications and its base regimen. |
| `R/steps/05_sct.R` | Transplant and CAR-T events: autologous, allogeneic, CAR-T (`LOT_RULES.md` §6). |
| `R/steps/05b_lot1_sct.R` | Line 1's own transplant summary, which needs line 1's base. |
| `R/steps/06_lot1_end.R` | Line 1's end date and end reason, including the discontinuation confirmation buffer. |
| `R/steps/07_qc.R` | Counts on what was just built, logged with the run; the impossible ones are checked again, fatally, in `check_lot1_invariants()`. |
| `R/steps/08_persist.R` | Writes `LOT_RUN_METADATA` (the run's settings and LOT1 counts) and `LOT_QC_SUMMARY`. Every other table is written by the step that builds it, all through `lot_out()`, so every name carries the prefix. |
| `R/steps/10_lot2_5_base.R` | Lines 2 to 5: their start candidates, regimens, run-outs and ends, and `LOT_LONG`. The file that decides where later lines begin. |
| `tests/test_runner.R` | The cohort switch, the contract, the setting validators, the criteria layer, the declared outputs against what the steps write. |
| `tests/test_line_criteria.R` | The per-line criteria layer. |
| `tests/testutil.R` | Shared assertion helpers. Not a suite. |

### What a run writes

All prefixed. Read `LOT_BUILD_STATUS` before trusting any of them.

| table | what it holds |
|---|---|
| `LOT_LONG` | every line built, one row per patient and line |
| `LOT_LONG_ALLFLAGS` | `LOT_LONG` plus one 0/1 column per declared line criterion, enabled or not |
| `LOT_LONG_FINAL` | the study population: `LOT_LONG_ALLFLAGS` with the enabled criteria applied. What the study package reads |
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

The per-line working tables stay behind deliberately, so why a patient's LOT3
ended where it did is a read, not a re-run.

### Adding a criterion to a line

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
later one. Turn it on with `APPLY_L2_STARTED_ON_MED,TRUE` in `config.csv`. Any
value other than `TRUE` or `FALSE` stops the build rather than leaving the
criterion silently off. A criterion needing patient-level facts `lot_long` does
not carry declares `patients` too — SQL building one row per `PATID` into the
view `lc_<name>_patients`, `LEFT JOIN`ed into the flags view as `p_<name>` —
both names derived from the criterion's so a rename cannot leave the predicate
reading nothing. A flag that collides with a `LOT_LONG` column, or a criterion
aimed above `MAX_LOT`, stops the build.

Every run says what it applied. The log names each criterion, whether it was
applied and how many patients fail it — the disabled ones too — and the same
goes into `LINE_CRITERIA_APPLIED` in `LOT_RUN_METADATA`. What the shipped
criterion means for the lines is `LOT_RULES.md` §8.

### The funnel

`LOT_ATTRITION`, one row per step, with patients and lines on each and
`PCT_OF_START` / `PCT_OF_PREV`. Not every row is attrition; `KIND` says which:

| `KIND` | what it is |
|---|---|
| `input` | cohort patients handed to LOT |
| `reconciliation` | with a mapped MM therapy episode, then with LOT1 built. On a treatment-indexed cohort such as NDMM these re-derive a fact the cohort build already established, so a drop is the two scans disagreeing rather than patients the study lost — logged as a warning, not as loss |
| `criterion` | one row per enabled `truncate` criterion, cumulative |
| `final` | the study population, `LOT_LONG_FINAL` |
| `progression` | reached LOT1, LOT2, ... to `MAX_LOT`. Nobody was removed here — a patient with no LOT3 did not progress, or their follow-up ended |

Two rows are the same number reached two ways: `final` must equal the row above
it, and `Reached LOT1` must equal `final`. Either mismatch stops the build, as
does a step larger than the one above it.

### The code-list checks

`R/steps/01_codelists.R` checks the code lists before any claim is read. Every
finding stops the build unless it is waivable **and** named in
`CODELIST_WAIVERS` (comma-separated). These are the waivable ones — each has a
reading a study team can accept once it has reviewed the finding:

| check | the finding |
|---|---|
| `orphan_meds` | a code-list medication with no rollup row |
| `uncoded_meds` | a rollup medication with no NDC or HCPCS code |
| `code_types` | a code type other than NDC or HCPCS, which nothing extracts |
| `subs_substitute` | a `substitute_med` the code list never produces |
| `subs_original` | an `original_med` the code list never produces |
| `ndc_short` | a ten-digit NDC, padded as if 4-4-2 (below) |

These are not waivable, and naming one in `CODELIST_WAIVERS` is refused before
the build starts. Each means a claim counted twice, a code matching every claim
with no code, a medication with no class or two, or an output column that is
always zero:

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
checks run, `permissible_subs.csv` is read flat by the loader: a pair the file
lists both ways is read once (the row whose original sorts first), and a drug
listed as its own substitute is dropped, each with a log line. One row already
makes a pair one agent in both directions.

The build also stops on a code list too short to be the production one (fewer
than 20 rollup medications or 50 code-list entries), and on the SCT code-list
checks in `R/steps/05_sct.R`, which are on neither list. Run with no waivers
first: a check that fires is evidence about the production code lists.

**NDC shape.** The code-list side of the join pads whatever digits it finds to
eleven — `lpad(regexp_replace(CL_CODE, '[^0-9]', ''), 11, '0')`. `ndc_shape` is
for codes that cannot be an NDC in any form: letters, more than eleven digits,
fewer than ten.

`ndc_short` is for ten-digit codes, and the pad gets most of them wrong. Ten
digits is a real FDA form with three layouts — 4-4-2, 5-3-2 and 5-4-1 — and the
eleven-digit form is made by inserting a zero into the short segment, not at the
far left. `50242-040-62` is 5-3-2, so it becomes `50242004062`; the blanket
left-pad produces `05024204062`, a different key. The conversion has to happen
in the file. Waive `ndc_short` only once the study team has confirmed the
ten-digit entries are 4-4-2, the one layout the pad gets right.

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
reports whether the production copy still does. That edit is made on the
server by hand; no script here makes it.

### Face validity

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

---

## `qc/` — the checks on a finished run

Reads only. Nothing here duplicates a check the build already makes. Three
severities: `fail` is something the algorithm's own definition says cannot
happen, `warn` is worth a look, `info` is counted and never scored. A check
that could not run is reported as an error, not a pass. A run is judged by its
own recorded `CONTRACT_SETTINGS`, not by `config.csv`. Every script that reads
the warehouse refuses a run whose build did not complete, and a run that
deviated from the contract unless `QC_ALLOW_DEVIATION=TRUE`.

| path | what it does |
|---|---|
| `run_lot_qc.R` | Runs the catalogue against a finished run. Lists the checks and reads nothing without `QC_EXECUTE=TRUE`; needs `OBJECT_PREFIX` and `INPUT_COHORT_TABLE` (the whole cohort table name). Writes `out/lot_qc_report.md`: each check's count and an example row, the `why` of anything that did not pass, and the declared limits of any check that has them — a limit changes how a zero reads, so it is printed whatever the check counted. Exits 1 when any check failed, errored or was skipped, 0 otherwise. |
| `R/checks.R` | The checks as data — one entry per check, each carrying its severity, what it looks for, why, the tables it needs, the query that finds violations, and `limits` where there is something it cannot see. |
| `tests/test_lot_qc.R` | That each check answers the same shape, reads only the tables it declares, masks every patient id, and turns a count into the right verdict; that `CONTENTS.md` quotes the catalogue's size; and, where DuckDB is available, that each check counts nothing on a clean fixture and counts the defect it describes. |
| `tests/exec_cases.R` | The clean fixture and, per check, the defect planted for it. |
| `tests/exec_harness.R` | Runs the checks against those fixtures, transpiled to DuckDB. |
| `tests/run_duckdb.py` | Executes a check against fixture tables through sqlglot and DuckDB and reports what it counted. |
| `trace_foldin.R` | Finds the patients the fold-in rule (`LOT_RULES.md` §4.8) touched in a finished run and writes each one's raw MAP episodes beside the final lines, the folded episode marked, to `out/`. Prints its plan without `TRACE_EXECUTE=TRUE`. `TRACE_N` (default 10) is how many patients to trace, `TRACE_PATIDS` names them instead, `TRACE_MASK_PATID=TRUE` masks the ids. The persisted tables carry no fold flag, so it reads the fold's signature: a regimen drug the previous line carried, no episode inside the line's induction window, and an episode inside the line. |
| `R/foldin_trace.R` | The queries, the sample and the rendering behind the trace. Connection-free. |
| `tests/test_foldin_trace.R` | That the trace reads the fold's signature and nothing else, samples the same patients every time, and renders what the fixtures say it should. |
| `trace_returns.R` | Every drug that came back in a finished run, in three kinds — a previous-line drug that folded into the line it returned in (§4.8), a line's own drug that came back after a confirmed break and stayed in its line (§4.3), and an earlier drug that came back and opened a line. Raw episodes beside the final lines, each return marked with a paragraph saying what the rules did and what a reading without §4.3 and §4.8 would have made of it. `TRACE_LINES` (default `1,2`, the 2L question; empty for every line), `TRACE_KINDS`, `TRACE_N` (default 12), `TRACE_PATIDS`, `TRACE_MASK_PATID` as the fold-in trace. Writes `out/returns_trace.md` and four CSVs. |
| `R/return_trace.R` | The three signatures, the stacking, the filters, the sample, the summary, the annotation and the rendering behind `trace_returns.R`. The fold is `foldin_trace.R`'s own query. Connection-free. |
| `trace_returns_example.R` | Renders `trace_returns.R`'s report on the fixture patients to `examples/returns_trace_example.md`. No connection; needs python with DuckDB and sqlglot. |
| `examples/returns_trace_example.md` | That rendered example, on invented patients, one per shape. Generated; the suite holds it to a fresh render. |
| `tests/returns_fixture.R` | The fixture patients the returns suite and the example share, one per shape the trace tells apart. |
| `tests/test_trace_returns.R` | That each kind reads its signature and nothing else, that the queries return exactly the planted returns and none of the controls, that the sample, summary and narratives say what the fixture says, that the example is a fresh render, and that no fixture line is a shape the engine could not have built. |
| `tests/run_duckdb_rows.py` | Executes statements against fixture rows through sqlglot and DuckDB and prints the rows, for the trace suites. Reports a statement it could not run rather than reading it as an empty result. |
| `extract_patients.R` | Writes named patients' LOT **inputs** out of a finished run as CSVs to `out/extract/` (`EXTRACT_DIR`), so the real rows can be put back through the engine rather than argued about from the lines alone. `EXTRACT_PATIDS` names them; prints its plan without `EXTRACT_EXECUTE=TRUE`. Writes `LOT_PATIENT_INPUT`, `MAP_STACKED`, `TX_AUTO_DATES`, `TX_ALLO_CART_DATES`, `PERMISSIBLE_SUBS`, the run's whole drug universe (`MED_UNIVERSE`) and `LOT_LONG_FINAL`, plus `RUN_PIN.csv` with the run id, code hash and contract settings. Ids are masked by default (`EXTRACT_MASK_PATID=FALSE` writes them whole). |
| `extract_review.R` | Reads what `extract_patients.R` wrote and prints every treatment that falls inside a line whose regimen does not name it, and for each the two things §4.8 turns on — whether the drug was in the previous line's regimen, and whether a transplant opened a line between its previous course and this one. It decides nothing: the advance count is not computable from the extract. No connection, no python. |

---

## `melphalan/` — what the melphalan rule did to the numbers

Two complete LOT builds, differenced: one with the rule the study adopted
(`LOT_RULES.md` §4.7) and one with `APPLY_MELP_RULE=off`. That difference is the
evidence the adoption rests on, kept runnable.

Opt-in, and it cannot become a study run by accident. `run_melp_simple.R`
writes its cells under `melp_simple_reference_` and `melp_simple_simplified_`,
a plan that would write to the study's prefix is refused, and the rule-off cell
launches with `LOT_CONTRACT_OVERRIDE` and is stamped in `CONTRACT_DEVIATIONS`,
so every reader refuses it as the study's numbers. The cell that carries the
rule is the contract build and deviates from nothing. Both cells carry the
contract's 28-day course cap: the package varies whether the rule runs, not the
threshold.

| path | what it does |
|---|---|
| `run_melp_simple.R` | Builds the two cells and reads them. Prints the plan by default; `MELP_SIMPLE_EXECUTE=TRUE` builds, `MELP_SIMPLE_READ=TRUE` reads cells already built. |
| `read_melp_asks.R` | The study team's three questions, off built cells: the change in each line's duration, how many lines contain melphalan and how many are melphalan alone (among the captured non-steroid agents, so melphalan with a steroid reads as alone), and how many patients receive a transplant in a melphalan-containing line, by line. Writes five CSVs. It reads cells under `melp_<cell>_` unless `AUG1_PREFIX_BASE` says otherwise, so set `AUG1_PREFIX_BASE=melp_simple_` to read the cells `run_melp_simple.R` built. |
| `R/cells.R` | The cell plan, the provenance checks that hold both cells to one cohort and one build of the engine, and the metrics read off each. |
| `tests/test_melp_simple.R` | That `off` really is the absence of the rule, that every spliced fragment opens with its own newline, that a cell cannot write over the study's tables or be read from a build it does not match, and — where DuckDB and sqlglot are installed — that the metrics and the rule's decision chain return the answers the fixtures work out by hand. |
| `tests/run_duckdb.py` | Executes a statement against a fixture, transpiling Spark to DuckDB. Reports a statement it could not run rather than reading it as an empty result. |
| `tests/exec_cells.R` | Whole-patient fixtures, and what every metric must count over them. |
| `tests/exec_rule.R` | One line per patient, one branch of §4.7 apiece — the boundaries the whole-patient fixtures do not reach cheaply: a confirming agent on the course's last covered day, a hold capped at the line's span, a course an earlier line owned. |

---

## `validation/` — the rule vignettes

The worked examples `LOT_RULES.md` cites by id. A **specification**, not
observed data — nothing here has been run against a warehouse.

| path | what it does |
|---|---|
| `R/vignettes.R` | The edge cases the algorithm is hardest on, each with the assignment the rules give and a `confidence` of `derived` or `to_confirm`. Every offset is derived from the setting that decides it, so a case moves when a setting moves and a renamed setting fails the catalogue. |
| `run_vignettes.R` | Renders the catalogue against the settings it is run with (`config.csv`, the environment winning). No connection; writes a CSV and a markdown table to `out/`, and stops if the catalogue disagrees with the config it was resolved against. Re-run it after any change to `R/vignettes.R` and keep what it writes. `OUTPUT_DIR` redirects the render. |
| `tests/test_vignettes.R` | The settings have to exist, the boundary pairs have to straddle them by one day and expect different things, the timelines have to run forwards, and the files the rules are quoted from have to be there. It also holds `LOT_RULES.md` and the catalogue to each other in both directions — a rule citing a vignette that does not exist fails, and a vignette no rule cites fails too. |
| `out/` | Generated: `lot_edge_case_vignettes.csv` and `.md`. Nothing in the package reads it back. |
