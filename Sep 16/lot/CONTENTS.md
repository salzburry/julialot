# What is in this folder

The lines-of-therapy engine. It reads a myeloma cohort and the Optum claims
behind it, and produces one row per patient and line: when the line started,
what started it, what was in its regimen, when and why it ended.

It sits beside two sibling folders:

| folder | what it does |
|---|---|
| `lot/` | **this folder** — the lines |
| `variables/` | the study cohorts and variables, built on those lines |
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
| `tests/` | two files, neither needing a warehouse |

**Outputs.** `LOT_LONG` is every line the engine built. `LOT_LONG_FINAL` is the
same after the patient-level criteria — a patient excluded by one is absent
from it entirely, not merely shortened. Beside them: `MAP_STACKED` (the claims
as exposure episodes), `LOT_ATTRITION` (cohort to study population),
`LOT_RUN_METADATA`, `LOT_CODELIST_METADATA` and `LOT_BUILD_STATUS`.

Every downstream reader resolves which run owns a prefix through
`LOT_BUILD_STATUS`, and refuses a run that did not finish or that deviated from
the contract.

### `qc/` — 40 checks on a finished run

Not a re-implementation of the rules: each check states a property the lines
must have, and counts the rows that break it.

```bash
Rscript qc/run_lot_qc.R
```

Each check carries its severity, what it looks for, why that matters, and the
tables it needs. A `fail` is a defect, a `warn` is worth reading, an `info` is
context. The report names an example row for each finding, with the patient
identifier masked to its last six characters so the file can be circulated.

The report carries the catalogue's own prose, not only its counts. Anything
that did not pass is followed by **why it matters**, so a finding arrives with
the reasoning behind it rather than as a number to argue with. And a check that
declares a limit says so under **what these checks cannot see** whatever it
counted — because the reading a limit changes is the zero, and a zero is not a
finding. `C5` declares one.

`Rscript qc/tests/test_lot_qc.R` — every one of the 40 runs twice
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
come back** - on real patients, in three kinds. A previous-line drug that
*folded* into the line it returned in (4.8); a line's own drug that came back
after a confirmed break and stayed in its line (4.3); and an earlier drug that
came back and *opened* a line, which neither rule prevents (two or more lines
back, or across a transplant-opened line). Each patient's raw episodes sit
beside the final lines, the returns marked, with a paragraph per return saying
what the rule did.

Each paragraph also says what a reading without 4.3 and 4.8 would have made of
that return. That is the comparison the study team asked for and is the report
answering it, not background: it is how a reader sees which lines these rules
removed and which they kept. `TRACE_LINES=1,2` (the default) is the 2L question. What the report
looks like, rendered on fixture patients: `qc/examples/returns_trace_example.md`.

```bash
OBJECT_PREFIX=ndmm_ TRACE_EXECUTE=TRUE Rscript qc/trace_returns.R
```

`qc/extract_patients.R` answers a different question from either trace. A
trace shows what the run DID with a patient. When that looks wrong, there are
three possible reasons and only one of them is a bug in the rules: the rules
are wrong, the run was built by code that is not the code in front of you, or
the patient's shape is not the shape anyone reasoned about. Arguing from the
lines alone cannot tell them apart, and neither can a hand-built patient - a
plant is someone's belief about the shape, so if the belief is what is wrong
the plant agrees with it and the real patient goes on being unexplained.

This writes the patient's own INPUT rows out - episodes with their class,
count and discontinuation flag, the transplant dates, the observation window,
the substitution pairs, the run's whole drug universe and its code hash - so
they can be put back through the engine's own statements off the warehouse
and the three separate.

```bash
OBJECT_PREFIX=ndmm_ EXTRACT_PATIDS=33062938660,33007568794 \
  EXTRACT_EXECUTE=TRUE Rscript qc/extract_patients.R
```

Ids are masked to their last six characters by default here - the two traces
are unmasked because they stay on the platform, and this file is written to be
carried off it. `EXTRACT_MASK_PATID=FALSE` writes them whole. The masking is
applied to every file at once, so the rows still join to each other and to a
trace written with `TRACE_MASK_PATID=TRUE`.

`qc/extract_review.R` reads what the extract wrote and asks one question of
it: which treatments fall inside a line whose regimen does not name them.

A drug carried over from the line before is one ordinary way that happens, and
a returning drug the fold took is another. What is left over is the set worth
arguing about, and beside each one it prints what 4.8 reads — whether the drug
was in the previous line's regimen, which is what makes it a fold candidate,
and whether a transplant opened a line between the drug's previous episode and
this one, which overrides the fold whatever the agent count says.

```bash
Rscript qc/extract_review.R          # or pass the directory as the first argument
```

No connection and no python: it reads the CSVs and prints a short table.

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

```bash
(cd engine     && Rscript tests/test_runner.R)
(cd engine     && Rscript tests/test_line_criteria.R)
(cd qc         && Rscript tests/test_lot_qc.R)
(cd qc         && Rscript tests/test_foldin_trace.R)
(cd qc         && Rscript tests/test_trace_returns.R)
(cd melphalan  && Rscript tests/test_melp_simple.R)
(cd validation && Rscript tests/test_vignettes.R)
```

Each prints how many assertions it made, and that number is deliberately not
quoted here - nothing reads a number in a document, so it goes stale the next
time a suite grows.

None needs a warehouse. Where `duckdb` and `sqlglot` are installed, the suites
also execute the emitted SQL against fixtures and check the numbers that come
back. Without them those blocks say `SKIP`, the rest still runs, and the suite
**exits non-zero** — a run missing its executed blocks is not a clean run, and
the counts above are for a complete one. `ALLOW_SKIPPED_TESTS=TRUE` accepts an
incomplete run deliberately; the skips are printed either way.

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
