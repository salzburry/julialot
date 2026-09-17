# What is in this folder

`lot/` is the lines-of-therapy product. `CONTENTS.md` is the short page;
`LOT_RULES_EXPLAINED.md` walks every rule with a patient timeline;
`LOT_RULES.md` is the rules as a reference, each naming the vignette that
tests it; this file is every file and what it does.

One package writes. The rest read a finished run.

| | |
|---|---|
| `lot/engine/` | builds the lines. `build.R <COHORT_TABLE> <prefix_>`. The only package here that writes a study run. |
| `lot/qc/` | thirty-seven checks on a finished run, asked after the fact, two traces of the returning-drug rules on real patients, and an extract of a patient's inputs for replay. Reads only. `run_lot_qc.R`, `trace_foldin.R`, `trace_returns.R`, `extract_patients.R`. |
| `lot/melphalan/` | what the melphalan rule did to the numbers, as two complete builds differenced. Opt-in, its own prefixes. |
| `lot/validation/` | the rule vignettes — the machine-checked twin of `LOT_RULES.md`. No warehouse. |

## What is deliberately not here

The cohort, and everything derived from a finished run. A cohort is what the
engine is pointed at — `build.R` takes the cohort table by name — so it comes
before LOT rather than under it, and no cohort is named anywhere in this
folder. The study package in `../variables/` reads a finished run and
builds the study's cohorts and variables on it; the app in `../dashboard/`
shows what both produced; the shells in `../TFLS/` are filled from what the
study package wrote. Dependencies run one way: those three read the tables a
run wrote, and the dashboard's tests read `engine/R/build_lot.R` as text to
hold the two table lists to each other; nothing in `lot/` resolves back out.

## Why the engine is its own folder

It is copied into other projects as-is, so it may not reach outside itself: no
sibling on its path, no cohort named anywhere in it, and `DBI`, `odbc` and
`glue` its only outside dependencies.

## Settings

Each package has a `config.csv` where it has settings at all; the environment
wins over the file. The cohort table and the prefix are never in a config file —
the caller passes them. One prefix is one study, so a wrong prefix is a wrong
study.

Settings that change what a build *means* are pinned in `CONTRACT`
(`lot/engine/R/build_lot.R`) and refused if changed: a different threshold is a
different algorithm. `LOT_CONTRACT_OVERRIDE=TRUE` exists for the sensitivity
sweep and the rule cells. A run that uses it records what it deviated on in
`CONTRACT_DEVIATIONS`, and every reader refuses it as the study's numbers.

Code lists live outside version control on a mounted path (`CODELIST_DIR`),
hashed either side of each read so a run records which version it used.

Paths here are written from the study folder. Inside each package's file table
below they are relative to that package — `R/build_lot.R`, `Rscript build.R` —
because those are run from the package's folder.

---

# Every file

## `lot/engine/` — builds the lines

Entry point `build.R <COHORT_TABLE> <prefix_> [<study_start> <study_end>]`, or
the same four as `INPUT_COHORT_TABLE`, `OBJECT_PREFIX`, `STUDY_START`,
`STUDY_END`. One run per prefix at a time, start to finish — LOT2-5 cannot be
continued in a session of its own. A rebuild re-reads the code lists and the
cohort, so it could build LOT1 from one version and `LOT_LONG` from another.

A cohort table must provide `PATID`, `INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`,
`DEATH_DT`, `GDR_CD`, `YRDOB`, `AGE_INDEX_YR`, `FU_DAYS`, `FU_DAYS_CE`, one row
per patient, and must fit the study window the run was given.

| path | what it does |
|---|---|
| `build.R` | Entry point. Takes a cohort table and an output prefix, and builds every line for it. |
| `config.csv` | Every setting as `name,value,description`. The cohort table and prefix are not here; the caller passes them. |
| `R/build_lot.R` | The runner, and `CONTRACT` — the pinned settings a run is checked against before it starts. Deviating needs an explicit override and is recorded in the run's status row. Also the cohort-input checks, the run metadata and the face-validity checks. |
| `R/config_lot.R` | Reads the settings. The environment wins over `config.csv`. |
| `R/load_inputs.R` | Applies `config.csv` as defaults, never over a value already set, and never reads the password from it. |
| `R/codelists_lot.R` | Loads the four code lists from CSV — `cl_mma_rollup.csv`, `cl_mma_codelist.csv`, `permissible_subs.csv`, `cl_sct_codelist.csv`. No embedded fallback: a missing file stops the run, and each is hashed before and after being read. |
| `R/db_utils_lot.R` | Connection, logging, retry, table naming (`wrk` / `lot_out`), `materialize()` and the step runner. |
| `R/line_criteria.R` | Extra criteria on finished lines, declared as data. Every one is computed into `LOT_LONG_ALLFLAGS`; only the enabled ones are applied to `LOT_LONG_FINAL`. |
| `R/cart_rule.R` | The CAR-T induction rule: an infusion inside line 1's window belongs to line 1 and neither ends nor starts a line. |
| `R/melp_rule.R` | The melphalan rule: a short course outside induction does not advance a line on its own (`LOT_RULES.md` 4.7). It lives here because it needs each line's own induction window. `APPLY_MELP_RULE=off` builds without it, which is the reference arm `lot/melphalan/` measures against. |
| `R/foldin_rule.R` | The MAP fold-in. A drug from the immediately previous line coming back joins the line it returns in — its span and its regimen — when exactly ONE agent advanced the line between that drug's two doses; two or more and the return starts a line (`LOT_RULES.md` 4.8). It counts AGENTS, so one drug opening two lines is one advance; transplants stay outside the count and a line one opened overrides the fold. `APPLY_MAP_FOLDIN=FALSE` builds without it, as a comparison. |
| `R/prior_regimen.R` | The prior-regimen rule and each line's run-out. A drug in the previous regimen cannot start the next line; the line it belongs to extends over its later episodes instead, stopping at any other agent arriving in between. Narrowed by the fold-in above for drugs of EARLIER lines. |
| `R/steps/01_codelists.R` | Code lists into views, then the consistency checks between them — which are fatal, which are waivable through `CODELIST_WAIVERS`, and why. |
| `R/steps/02_patient_input.R` | The cohort as the build reads it, snapshotted into `LOT_PATIENT_INPUT`. Sets the observation end date every later gap and window is measured against. |
| `R/steps/03_mma_map.R` | Claims into medication available periods. A new period opens only for a claim beyond every runout; one arriving while cover is live pushes the runout out instead. |
| `R/steps/04_lot1_base.R` | Line 1's start, its induction medications and its base regimen. |
| `R/steps/05_sct.R` | Transplant and CAR-T events: autologous, allogeneic, CAR-T. |
| `R/steps/05b_lot1_sct.R` | Line 1's own transplant summary, which needs line 1's base. |
| `R/steps/06_lot1_end.R` | Line 1's end date and end reason, including the discontinuation confirmation buffer. |
| `R/steps/07_qc.R` | Counts on what was just built, recorded with the run. |
| `R/steps/08_persist.R` | Writes the outputs, every one through the prefix helper so a run cannot overwrite another cohort's. |
| `R/steps/10_lot2_5_base.R` | Lines 2 to 5: their start candidates, regimens, run-outs and ends, and `LOT_LONG`. The largest file here, and the one that decides where later lines begin. |
| `tests/test_runner.R` | The cohort switch, the contract, the setting validators, the declared outputs against what the steps write. |
| `tests/test_line_criteria.R` | The per-line criteria layer. |
| `tests/testutil.R` | Shared assertion helpers. Not a suite. |

**What a run leaves behind.** `LOT_LONG` and `LOT_LONG_FINAL` (the study
population), `LOT_LONG_ALLFLAGS`, `LOT_PATIENT_INPUT`, `MAP_STACKED`,
`PERMISSIBLE_SUBS`, the LOT1 stage tables, the per-line `LOT<n>_<STAGE>`
tables, `LOT_ATTRITION`, `LOT_RUN_METADATA`, `LOT_CODELIST_METADATA`,
`LOT_QC_SUMMARY` and `LOT_BUILD_STATUS` — all prefixed. Read `LOT_BUILD_STATUS` before trusting any of
them: `started` once preflight passes, then `complete`, or `failed`.

The per-line stage tables stay behind deliberately: they are each line's
working, so why a patient's LOT3 ended where it did is a read, not a re-run.

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

Turn it on with `APPLY_L2_STARTED_ON_MED,TRUE` in `config.csv`. Any value other
than `TRUE` or `FALSE` stops the build rather than leaving the criterion
silently off. A criterion needing patient-level facts `lot_long` does not carry
declares `patients` too — SQL building one row per `PATID`, created before the
flags view and `LEFT JOIN`ed into it, both names derived from the criterion's so
a rename cannot leave the predicate reading nothing.

Every run says what it applied. The log names each criterion, whether it was
applied and how many patients fail it — the disabled ones too — and the same
goes into `LINE_CRITERIA_APPLIED` in `LOT_RUN_METADATA` as
`no_belantamab=on:truncate:37`. What a criterion means for the lines is in
`LOT_RULES.md`, under "Belantamab removes the patient, not the line".

### The funnel

`<prefix>LOT_ATTRITION`, one row per step, with patients and lines on each and
`PCT_OF_START` / `PCT_OF_PREV`. Not every row is attrition; `KIND` says which:

| `KIND` | what it is |
|---|---|
| `input` | cohort patients handed to LOT |
| `reconciliation` | with a mapped MM therapy episode, then with LOT1 built. On a treatment-indexed cohort such as NDMM these re-derive a fact the cohort build already established, so a drop is the two scans disagreeing rather than patients the study lost — reported as a discrepancy, not as loss |
| `criterion` | one row per enabled `truncate` criterion, cumulative |
| `final` | the study population, `LOT_LONG_FINAL` |
| `progression` | reached LOT1, LOT2, ... to `MAX_LOT`. Nobody was removed here — a patient with no LOT3 did not progress, or their follow-up ended |

Two rows are the same number reached two ways, deliberately: `final` must equal
the last `criterion` row, and `Reached LOT1` must equal `final`. Either
mismatch stops the build, as does a step larger than the one above it.

### The code-list checks

Three of the waivable checks have a reading a study team can accept: a
code-list med with no rollup row (`orphan_meds`), a rollup med with no
extractable NDC/HCPCS code (`uncoded_meds`), and a code type other than NDC or
HCPCS (`code_types`). Each stops the build unless named in `CODELIST_WAIVERS`.
The full waivable set:

```
orphan_meds  uncoded_meds  code_types  subs_substitute  subs_original
ndc_short  claim_ndc_short  claim_ndc_shape
```

These are not waivable. Each means a claim counted twice, a code matching every
claim with no NDC, a medication with no class, or an output column that is
always zero:

```
code_to_med  bad_ndc  rollup_defs  blank_keys  ndc_shape
multi_class  multi_original  class_agreement  subs_chain  subs_star
```

`subs_chain` and `subs_star` hold the substitution table flat: one hop each
way is exact for a pair and wrong for a chain `A -> B -> C` or a star. Before
the check runs, `permissible_subs.csv` is read flat by the loader: a pair the
file lists both ways is read once (the row whose original sorts first), and a
drug listed as its own substitute is dropped, each with a log line. One row
already makes a pair one agent in both directions, and the mirror made the
sites that collapse a drug to its original swap the two instead.

Naming one of the second group is refused before the build starts.
`multi_class` is fatal because `min(MED_CLASS)` picks lexically, not clinically,
and the choice reaches the class flags and the steroid exclusion.
`multi_original` is fatal for the same reason: a substitute standing in for two
drugs is collapsed to one of them by `min()`, and that pick decides which
agent's return a §4.8 fold is judging. The SCT checks
in `05_sct.R` are on neither list and always stop the build. Run with none of
them set first: a check that fires is evidence about the production code lists.

**NDC shape** is the one worth reading twice. The join pads whatever digits it
finds to eleven — `lpad(regexp_replace(CL_CODE, '[^0-9]', ''), 11, '0')`.
`ndc_shape` is for codes that cannot be an NDC in any form: letters, more than
eleven digits, fewer than ten.

`ndc_short` is for ten-digit codes, and the pad gets most of them wrong. Ten
digits is a real FDA form with three layouts — 4-4-2, 5-3-2 and 5-4-1 — and the
eleven-digit form is made by inserting a zero into the short segment, not at the
far left. `50242-040-62` is 5-3-2, so it becomes `50242004062`; the blanket
left-pad produces `05024204062`, a different key. The conversion has to happen
in the file. Waive `ndc_short` only once the study team has confirmed the
ten-digit entries are 4-4-2, the one layout the pad gets right. `check_claim_ndc`
asks the same of both claim tables before LOT1 starts, under `claim_ndc_short` /
`claim_ndc_shape`.

**Steroids** are maintained separately, so their codes are not in
`cl_mma_codelist.csv`, and both places that build `mma_rollup` drop them by
class as well. The rollup file itself should not list them either — QC check
`D3` reports whether the production copy still does. That edit is made on the
server by hand; no script here makes it.

### Face validity

The structural invariants ask whether the output is internally consistent.
`LOT_FACE_VALIDITY` asks whether it looks like myeloma: a run can pass every
structural check with transplants in late lines, CAR-T in first line, or a
median line lasting three days.

| check | expects |
|---|---|
| autologous transplant lines that are LOT1-2 | >= 50% |
| CAR-T lines at LOT3 or later | >= 50% |
| patients with any allogeneic line | <= 5% |
| LOT1 lines started by a medication | >= 80% |
| median LOT1 length in days | 30-1500 |
| LOT1 patients covered by the ten commonest regimens | >= 25% |

The number is the point, not the verdict. Every check records what it found
whether or not it passed, and the bands are wide deliberately — they catch gross
failure, and none is a published benchmark. Reported, not fatal;
`FACE_VALIDITY_FATAL=TRUE` makes them stop.

## `lot/qc/` — the slower checks on a finished run

| path | what it does |
|---|---|
| `run_lot_qc.R` | Runs thirty-seven checks against a finished run and refuses one whose own build did not complete. Reads only; writes a report to `out/`. Exit status is 0 when nothing failed and 1 when something did, so it can gate a handover. |
| `R/checks.R` | The checks as data — one entry per check, each carrying the query that finds violations, so the catalogue can be read without running it. |
| `tests/test_lot_qc.R` | That each check answers the same shape, reads only the tables it declares, masks every patient id, and turns a count into the right verdict. |
| `trace_foldin.R` | Finds the patients the fold-in rule (`LOT_RULES.md` 4.8) touched in a finished run and writes each one's raw MAP episodes beside the final lines, the folded episode marked, to `out/`. Reads only. Prints its plan without `TRACE_EXECUTE=TRUE`. `TRACE_N` is how many patients to trace, `TRACE_PATIDS` names them instead, `TRACE_MASK_PATID=TRUE` masks the ids. Unmasked by default, because it exists so a patient can be looked up, so the file stays inside the study environment. |
| `R/foldin_trace.R` | The queries, the sample and the rendering behind the trace. Connection-free, so every piece of it is tested. |
| `tests/test_foldin_trace.R` | That the trace reads the fold's signature and nothing else, samples the same patients every time, and renders what the fixtures say it should. |
| `trace_returns.R` | The wider trace: every drug that CAME BACK in a finished run, in three kinds - a previous-line drug that folded into the line it returned in (`LOT_RULES.md` 4.8), a line's own drug that came back after a confirmed break and stayed in its line (4.3; before the rule it opened a new line), and an earlier drug that came back and opened a line (neither rule). Raw episodes beside the final lines, each return marked and narrated with what the earlier reading would have done. `TRACE_LINES` (default `1,2`, the 2L question), `TRACE_KINDS`, `TRACE_N`, `TRACE_PATIDS`, `TRACE_MASK_PATID` as the fold-in trace. Reads only; writes `out/returns_trace.md` and four CSVs. |
| `R/return_trace.R` | The three signatures, the stacking, the filters, the sample, the summary, the annotation and the rendering behind `trace_returns.R`. The fold is `foldin_trace.R`'s own query, unchanged. Connection-free. |
| `trace_returns_example.R` | Renders `trace_returns.R`'s report on eight fixture patients, one per shape, to `examples/returns_trace_example.md` - what the study team sees before a run against the warehouse. No connection. |
| `examples/returns_trace_example.md` | That rendered example. The suite holds it to a fresh render, so it cannot drift from the code. |
| `tests/returns_fixture.R` | The six fixture patients and the DuckDB row runner the suite and the example share. |
| `tests/test_trace_returns.R` | That each kind reads its signature and nothing else, that the queries executed on the fixture return exactly the planted returns and none of the controls, that the sample, summary, annotation and narratives say what the fixture says, that the committed example is a fresh render, and that no fixture line is a shape the engine could not have built. |
| `extract_patients.R` | Writes named patients' LOT **inputs** out of a finished run as CSVs, so the real rows can be put back through the engine rather than argued about from the lines alone. `EXTRACT_PATIDS` names them; reads `LOT_PATIENT_INPUT`, `MAP_STACKED`, `TX_AUTO_DATES`, `TX_ALLO_CART_DATES`, `PERMISSIBLE_SUBS` and `LOT_LONG_FINAL`, plus the run's whole drug universe and its code hash. Reads only; prints its plan without `EXTRACT_EXECUTE=TRUE`. Ids are masked by DEFAULT here, unlike the two traces: those stay on the platform and this file is written to be carried off it. |
| `extract_review.R` | Reads the CSVs `extract_patients.R` wrote and prints the one thing a returning drug raises: every treatment that falls inside a line whose regimen does not name it, and for each, the two things `LOT_RULES.md` 4.8 decides on — whether the drug was in the previous line's regimen, and whether a transplant opened a line between its previous episode and this one. No connection, no python. Output is a short table, not the extract. |
| `tests/run_duckdb_rows.py` | Executes a statement against fixture rows, transpiling Spark to DuckDB, for the trace suite. Reports a statement it could not run rather than reading it as an empty result. |

Nothing here duplicates a check the build already makes. Three severities:
`fail` is something the algorithm's own definition says cannot happen, `warn` is
worth a look, `info` is counted and never scored. A check that could not run is
reported as an error, not a pass. A run is judged by its own recorded
`CONTRACT_SETTINGS`, not by `config.csv`.

## `lot/melphalan/` — what the melphalan rule did to the numbers

Two complete LOT builds, differenced: one with the rule the study adopted
(`LOT_RULES.md` 4.7) and one with `APPLY_MELP_RULE=off`. That difference is the
evidence the adoption rests on, kept runnable rather than written down once.

Opt-in, and it cannot become a study run by accident. Cells write to
`melp_simple_` prefixes of their own, a plan that would write to the study's
prefix is refused, and the rule-off cell launches with `LOT_CONTRACT_OVERRIDE`
and is stamped in `CONTRACT_DEVIATIONS`, so every reader refuses it as the
study's numbers. The cell that does carry the rule is the contract build and
deviates from nothing.

Both cells carry the contract's 28-day course cap. The package varies whether
the rule runs, not the threshold it runs at.

| path | what it does |
|---|---|
| `run_melp_simple.R` | Builds the two cells and reads them. Prints the plan by default; `MELP_SIMPLE_EXECUTE=TRUE` builds, `MELP_SIMPLE_READ=TRUE` reads cells already built. |
| `read_melp_asks.R` | The study team's three questions, off built cells: the change in each line's duration, how many lines contain melphalan and how many are melphalan alone, and how many patients receive a transplant in a melphalan-containing line, by line. |
| `R/cells.R` | The cell plan, the provenance checks that hold both cells to one cohort and one build of the engine, and the metrics read off each. |
| `tests/test_melp_simple.R` | That `off` really is the absence of the rule, that every spliced fragment opens with its own newline, that a cell cannot write over the study's tables or be read from a build it does not match, and — where duckdb and sqlglot are installed — that the metrics and the rule's decision chain return the answers the fixtures work out by hand. |
| `tests/run_duckdb.py` | Executes a statement against a fixture, transpiling Spark to DuckDB. Reports a statement it could not run rather than reading it as an empty result. |
| `tests/exec_cells.R` | Nine patients and sixteen lines, and what every metric must count over them. |
| `tests/exec_rule.R` | Fifteen patients, one line each, one branch of 4.7 apiece — the boundaries the whole-patient fixtures do not reach cheaply: a confirming agent on the course's last covered day, a hold capped at the line's span, a course an earlier line owned. |

Until 2026-08-30 this package also carried the five-branch rule the study team
asked for first, as a third cell. That rule was measured, not adopted, and
removed.

## `lot/validation/` — the rule vignettes, machine-checked

The twin of the rules in `LOT_RULES.md`. Every rule there carries a timeline of
claims and what the algorithm makes of them, and 21 of those name a vignette id;
this is where that id lives. It is a **specification**, not observed data —
nothing here has been run against a warehouse.

It stays with the rules because it states what the build's rules say rather than
measuring the build.

| path | what it does |
|---|---|
| `R/vignettes.R` | The edge cases the algorithm is hardest on, each with the assignment the rules give. Every offset is derived from the parameter that decides it, so a case moves when a setting moves and a renamed setting fails the catalogue rather than leaving prose describing a rule that is gone. |
| `run_vignettes.R` | Renders the catalogue. No warehouse and no connection; writes a CSV and a markdown table to `out/`. Both are kept beside it, so re-run it after any change to `R/vignettes.R` and keep what it writes — the run stops if the catalogue disagrees with the config it was resolved against. `OUTPUT_DIR` redirects the render. |
| `tests/test_vignettes.R` | The catalogue cannot drift: the parameters have to exist, the boundary pairs have to straddle them and expect different things, the timelines have to run forwards, and the files the rules are quoted from have to be there. It also holds `LOT_RULES.md` and the catalogue to each other in both directions — a rule citing a vignette that does not exist fails, and a vignette no rule cites fails too. |
| `out/` | Generated. Nothing reads it back. |

Each vignette carries a `confidence` of `derived` or `to_confirm`. That is a
claim about us, not about the algorithm: `to_confirm` marks where the rules
interact and the first real run settles it.

---

# Tests

None needs a connection.

```
Rscript lot/engine/tests/test_runner.R
Rscript lot/engine/tests/test_line_criteria.R
Rscript lot/qc/tests/test_lot_qc.R
Rscript lot/qc/tests/test_foldin_trace.R
Rscript lot/qc/tests/test_trace_returns.R
Rscript lot/melphalan/tests/test_melp_simple.R
Rscript lot/validation/tests/test_vignettes.R
```

`CONTENTS.md` gives each suite's count. The suites for the other two folders
are listed in `../variables/CONTENTS.md` and
`../dashboard/DASHBOARD.md`.
