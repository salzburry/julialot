# What is in this folder

`lot/` is the lines-of-therapy product. Two documents: `LOT_RULES.md` is the
rules the build applies, each naming the vignette that tests it; this file is
what is here and what each file does.

One package writes. The rest read a finished run.

| | |
|---|---|
| `lot/engine/` | builds the lines. `build.R <COHORT_TABLE> <prefix_>`. The only package here that writes a study run. |
| `lot/qc/` | thirty-seven checks on a finished run, asked after the fact. Reads only. `run_lot_qc.R`. |
| `exploration/lot/` | the rule scenarios, machine-checked against the settings that decide them. No warehouse. |

## What is deliberately not here

A cohort, everything derived from a finished run, and every experiment on the
rules — each sits beside this folder, so the algorithm is one directory with
three packages in it:

| | |
|---|---|
| `ndmm/`, `overall/` | the cohort builds. A cohort is what the engine is pointed at, so it comes before LOT rather than under it |
| `reporting/dashboard/` | one self-contained HTML off a finished run |
| `analysis/outcomes/` | TTNT, TTD, OS and attrition |
| `analysis/questions/` | the study team's asks, one script each |
| `exploration/melphalan/` | how the melphalan rule the build applies was chosen, and the one that was not |
| `exploration/lot/run_foldin_cells.R` | the MAP fold-in the build applies, measured against a build without it |
| `exploration/lot/` | benchmarks, definitions, sensitivity, stockpiling, re-challenge, audit counts |

Each area has its own `FILES.md`. Dependencies run one way: those areas resolve
`lot/engine` and read its modules; nothing in `lot/` resolves back out.
`reporting/` and `analysis/outcomes/` read a run's tables and carry their own
helpers.

## What a study run uses

`lot/engine/`, then `reporting/dashboard/`, `analysis/outcomes/` and
`analysis/questions/` over what it wrote. `lot/qc/` signs it off.

Nothing under `exploration/` is part of a run. The two things there that build
are opt-in and write to throwaway prefixes of their own.

## Why the engine is its own folder

It is copied into other projects as-is, so it may not reach outside itself: no
sibling on its path, no cohort named anywhere in it, and `DBI`, `odbc` and
`glue` its only outside dependencies. A check outside the study folder holds
every file to that.

## The cohorts are not here

`overall/` and `ndmm/` build them. `build.R` takes the cohort table by name, so
a cohort comes before LOT rather than under it, and neither cohort build reads
this folder at run time.

Two crossings. `ndmm/build_subsequent_cohorts.R` runs *after* a LOT run — the
2L and 3L index dates are line starts — and still lives with the cohorts. And
`ndmm/tests/` reads `lot/engine/R/build_lot.R` as a source file, to pin the
interface: the columns the engine requires of a cohort, and the columns its
status table really has.

## Settings

Each package has a `config.csv` where it has settings at all; the environment
wins over the file. The cohort table and the prefix are never in a config file —
the caller passes them. One prefix is one study, so a wrong prefix is a wrong
study.

Settings that change what a build *means* are pinned in `CONTRACT`
(`lot/engine/R/build_lot.R`) and refused if changed: a different threshold is a
different algorithm. `LOT_CONTRACT_OVERRIDE=TRUE` exists for the sensitivity
sweep and the rule cells. A run that uses it records what it deviated on in
`CONTRACT_DEVIATIONS`, and every reader in the delivery refuses it as the
study's numbers.

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
| `R/melp_rule.R` | The melphalan rule. The study's mode is `simplified` — a short course outside induction does not advance a line on its own (`LOT_RULES.md` 4.7). It lives here because it needs each line's own induction window. The other modes, and `off`, are comparison builds — `exploration/melphalan/` below. |
| `R/foldin_rule.R` | The MAP fold-in. A drug from an earlier line coming back joins the line it returns in, when exactly ONE agent advanced the line between that drug's two doses; two or more and the return starts a line (`LOT_RULES.md` 4.8). It counts AGENTS, so one drug opening two lines is one advance; transplants stay outside the count and a line one opened overrides the fold. `APPLY_MAP_FOLDIN=FALSE` builds without it, as a comparison — `exploration/lot/run_foldin_cells.R`. |
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
population), `LOT_LONG_ALLFLAGS`, `LOT_PATIENT_INPUT`, `MAP_STACKED`, the LOT1
stage tables, the per-line `LOT<n>_<STAGE>` tables, `LOT_ATTRITION`,
`LOT_RUN_METADATA`, `LOT_CODELIST_METADATA`, `LOT_QC_SUMMARY` and
`LOT_BUILD_STATUS` — all prefixed. Read `LOT_BUILD_STATUS` before trusting any of
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

Three consistency checks are reviewable: a code-list med with no rollup row
(`orphan_meds`), a rollup med with no extractable NDC/HCPCS code
(`uncoded_meds`), and a code type other than NDC or HCPCS (`code_types`). Each
stops the build unless named in `CODELIST_WAIVERS`, because each has a reading
a study team can accept. The full waivable set:

```
orphan_meds  uncoded_meds  code_types  subs_substitute  subs_original
ndc_short  claim_ndc_short  claim_ndc_shape
```

These are not waivable. Each means a claim counted twice, a code matching every
claim with no NDC, a medication with no class, or an output column that is
always zero:

```
code_to_med  bad_ndc  rollup_defs  blank_keys  ndc_shape
multi_class  class_agreement
```

Naming one of the second group is refused before the build starts.
`multi_class` is fatal because `min(MED_CLASS)` picks lexically, not clinically,
and the choice reaches the class flags and the steroid exclusion. The SCT checks
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
| `run_lot_qc.R` | Runs thirty-five checks against a finished run and refuses one whose own build did not complete. Reads only; writes a report to `out/`. Exit status is 0 when nothing failed and 1 when something did, so it can gate a handover. |
| `R/checks.R` | The checks as data — one entry per check, each carrying the query that finds violations, so the catalogue can be read without running it. |
| `run_lot_audit_counts.R` | Real-data frequencies for the LOT assignment findings — the audit's questions put to the real run. |
| `tests/test_lot_qc.R` | That each check answers the same shape, reads only the tables it declares, masks every patient id, and turns a count into the right verdict. |

Nothing here duplicates a check the build already makes. Three severities:
`fail` is something the algorithm's own definition says cannot happen, `warn` is
worth a look, `info` is counted and never scored. A check that could not run is
reported as an error, not a pass. A run is judged by its own recorded
`CONTRACT_SETTINGS`, not by `config.csv`.

## `exploration/lot/` — the rule scenarios, machine-checked

The twin of the rules in `LOT_RULES.md`. Every rule there carries a timeline of
claims and what the algorithm makes of them, and 21 of those name a vignette id;
this is where that id lives. It is a **specification**, not observed data —
nothing here has been run against a warehouse.

It stays with the rules because it states what the build's rules say rather than
measuring the build. The measurements are in `exploration/lot/`.

| path | what it does |
|---|---|
| `R/vignettes.R` | The edge cases the algorithm is hardest on, each with the assignment the rules give. Every offset is derived from the parameter that decides it, so a case moves when a setting moves and a renamed setting fails the catalogue rather than leaving prose describing a rule that is gone. |
| `run_vignettes.R` | Renders the catalogue. No warehouse and no connection; writes a CSV and a markdown table to `out/`. Both are committed, and the merge gate re-renders them and fails on any difference — so the tracked catalogue cannot drift from the code that generates it. `OUTPUT_DIR` redirects the render, which is how the gate compares without touching the working tree. |
| `tests/test_vignettes.R` | The catalogue cannot drift: the parameters have to exist, the boundary pairs have to straddle them and expect different things, the timelines have to run forwards, and the files the rules are quoted from have to be there. It also holds `LOT_RULES.md` and the catalogue to each other in both directions — a rule citing a vignette that does not exist fails, and a vignette no rule cites fails too. |
| `out/` | Generated. Nothing reads it back. |

Each vignette carries a `confidence` of `derived` or `to_confirm`. That is a
claim about us, not about the algorithm: `to_confirm` marks where the rules
interact and the first real run settles it.

---

# Tests

None needs a connection. The merge gate runs every suite with a single exit
status, so "all suites pass" is recorded against a commit rather than reported
by whoever ran them.

```
Rscript lot/engine/tests/test_runner.R           # and test_line_criteria.R
Rscript lot/qc/tests/test_lot_qc.R
Rscript lot/validation/tests/test_vignettes.R
```

The suites for everything outside this folder are listed in the study folder's
`README.md`, in one block.
