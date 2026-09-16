# What is in this folder

The lines-of-therapy engine. It reads a myeloma cohort and the Optum claims
behind it, and produces one row per patient and line: when the line started,
what started it, what was in its regimen, when and why it ended.

It sits beside two sibling folders:

| folder | what it does |
|---|---|
| `lot/` | **this folder** — the lines |
| `ndmm_study_updated/` | the study cohorts and variables, built on those lines |
| `dashboard/` | the R Shiny app that shows what both produced |

---

## Start here

| read this | for |
|---|---|
| `LOT_RULES_EXPLAINED.md` | every rule, each with a worked patient timeline |
| `LOT_RULES.md` | the same rules as a reference, with the section and the file each lives in |
| `FILES.md` | every file, in more detail than this page |
| `engine/config.csv` | every setting, with what each one does |

---

## The four packages

### `engine/` — the build

The lines themselves. One `Rscript build.R` produces every table.

| path | what it is |
|---|---|
| `build.R` | the entry point |
| `config.csv` | every setting and what it does. The environment beats the file |
| `R/build_lot.R` | the runner, the contract, and the table list |
| `R/steps/` | the build in order: code lists, claims, transplants, line 1, lines 2-5, ends, persistence |
| `R/line_criteria.R` | the patient-level criteria applied after the lines are built |
| `R/melp_rule.R` | the melphalan short-course rule |
| `R/foldin_rule.R` | the returning-drug rule |
| `R/prior_regimen.R` | what counts as a new agent, a restart, and a line-breaking transplant |
| `R/cart_rule.R` | the CAR-T consolidation rule |
| `tests/` | 584 checks across two files |

**Outputs.** `LOT_LONG` is every line the engine built. `LOT_LONG_FINAL` is the
same after the patient-level criteria — a patient excluded by one is absent
from it entirely, not merely shortened. Beside them: `MAP_STACKED` (the claims
as exposure episodes), `LOT_ATTRITION` (cohort to study population),
`LOT_RUN_METADATA`, `LOT_CODELIST_METADATA` and `LOT_BUILD_STATUS`.

Every downstream reader resolves which run owns a prefix through
`LOT_BUILD_STATUS`, and refuses a run that did not finish or that deviated from
the contract.

### `qc/` — 37 checks on a finished run

Not a re-implementation of the rules: each check states a property the lines
must have, and counts the rows that break it.

```bash
Rscript qc/run_lot_qc.R
```

Each check carries its severity, what it looks for, why that matters, and the
tables it needs. A `fail` is a defect, a `warn` is worth reading, an `info` is
context. The report names an example row for each finding, with the patient
identifier masked to its last six characters so the file can be circulated.

`Rscript qc/tests/test_lot_qc.R` — 295 checks. Every one of the 37 runs twice
against fixtures: clean, where it must count nothing, and carrying the defect
it describes, where it must count it.

`qc/trace_foldin.R` shows the fold-in rule (`LOT_RULES.md` 4.8) on real
patients: their raw MAP episodes beside the final lines. The persisted tables
carry no fold flag, so it reads the fold's signature instead: a regimen drug
the previous line carried, no episode inside the line's induction window, and
an episode inside the line. That is the same route check C1 accepts. One trace
per patient goes to `qc/out/`, ids unmasked so the patient can be looked up.

```bash
OBJECT_PREFIX=ndmm_ TRACE_EXECUTE=TRUE Rscript qc/trace_foldin.R
```

`qc/trace_returns.R` is the wider question the study team asked - **drugs that
come back** - on real patients: every return the 30 Aug 2026 rules touched,
in three kinds. A previous-line drug that *folded* into the line it returned
in (4.8); a line's own drug that came back after a confirmed break and stayed
in its line (4.3) - before the rule that return opened a new line, so a 1L
drug back after a holiday made a 2L that no longer exists; and an earlier
drug that came back and *opened* a line, which neither rule prevents (two or
more lines back, or across a transplant-opened line). Each patient's raw
episodes sit beside the final lines, the returns marked, with a paragraph
per return saying what the rule did and what the earlier reading would have
done. `TRACE_LINES=1,2` (the default) is the 2L question. What the report
looks like, rendered on fixture patients: `qc/examples/returns_trace_example.md`.

```bash
OBJECT_PREFIX=ndmm_ TRACE_EXECUTE=TRUE Rscript qc/trace_returns.R
```

### `validation/` — the edge-case catalogue

Thirty vignettes: the patients the algorithm is hardest on, each with the
assignment the rules give. A **specification**, not observed output — nothing
here has run against a warehouse.

Every offset is derived from the setting that decides it, and the cases come in
pairs straddling a boundary, so the catalogue moves when a setting moves. Two
confidence levels: `derived` follows from the rule quoted beside it;
`to_confirm` is our reading of how rules interact, and the first real run
settles it.

```bash
Rscript validation/run_vignettes.R   # writes out/lot_edge_case_vignettes.{md,csv}
```

### `melphalan/` — what the melphalan rule did to the numbers

Two complete LOT builds, differenced: one with the rule the study adopted and
one without it. That difference is the evidence the adoption rests on, kept
runnable rather than written down once.

Opt-in, under its own prefixes, and it cannot become a study run by accident.

---

## Running it

```bash
# a build
INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=lot_ Rscript engine/build.R

# then the checks on it
OBJECT_PREFIX=lot_ Rscript qc/run_lot_qc.R
```

The engine needs a connection and has no dry-run mode. (The study package does:
`DRY_RUN=TRUE` there resolves every setting and stops before connecting.) Its
test suites need no warehouse.

### The test suites

| suite | checks |
|---|---|
| `engine/tests/test_runner.R` | 527 |
| `engine/tests/test_line_criteria.R` | 57 |
| `qc/tests/test_lot_qc.R` | 295 |
| `qc/tests/test_foldin_trace.R` | 149 |
| `qc/tests/test_trace_returns.R` | 127 |
| `melphalan/tests/test_melp_simple.R` | 161 |
| `validation/tests/test_vignettes.R` | 36 |

None needs a warehouse. Where `duckdb` and `sqlglot` are installed, the suites
also execute the emitted SQL against fixtures and check the numbers that come
back; without them those blocks say `SKIP` and the rest still runs.

---

## The settings that decide a line

Full list in `engine/config.csv`. These are the ones that change where a
boundary falls:

| setting | default | decides |
|---|---|---|
| `INDUCTION_WINDOW_DAYS` | 60 | how long a drug has to join line 1's regimen |
| `LOT_N_INDUCTION_WINDOW_DAYS` | 30 | the same for later lines |
| `MAP_DISCON_GAP_DAYS` | 90 | the gap after an agent's cover ends that counts as discontinuation |
| `MEDICAL_DAY_SUPPLY` | 28 | how long a medical-claim administration is assumed to cover |
| `SCT_AUTO_WINDOW_DAYS` | 13 | how close two AUTO codes must be to be one transplant |
| `SCT_TANDEM_DAYS` | 180 | how close a second AUTO must be to be the tandem of the first |
| `CART_CONSOLIDATION_DAYS` | 45 | how long after an addition a CAR-T still closes the line |
| `MELP_SIMPLE_COURSE_DAYS` | 28 | melphalan cover at or under which a course is short |
| `MAX_LOT` | 5 | the highest line built |

A build that changes one of these is a **different algorithm**. The engine
records what it used in `LOT_RUN_METADATA`, and a build that departs from the
pinned contract is stamped in `LOT_BUILD_STATUS` and refused by every reader
that resolves run ownership — deliberately, so a sensitivity analysis cannot be
mistaken for the study's numbers.

---

## Also here

`FILES.md` is the fuller file-by-file index.
