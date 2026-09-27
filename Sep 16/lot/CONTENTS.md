# What is in this folder

The lines-of-therapy engine: stage 2 of the five (`ndmm/` → `lot/` →
`variables/` → `TFLS/` → `dashboard/`). It reads the myeloma cohort table stage
1 wrote and the Optum claims behind it, and produces one row per patient and
line: when the line started, what started it, what was in its regimen, when and
why it ended. The study package in `variables/` reads what it writes.

---

## Start here

| read this | for |
|---|---|
| `LOT_RULES_EXPLAINED.md` | the rules, each on a worked patient timeline |
| `LOT_RULES.md` | the rules as a reference: the setting and the file each lives in, the pinned contract, what stops a run |
| `FILES.md` | every file and what it does, the output tables, the code-list checks, adding a criterion |
| `PORTING.md` | moving the engine to another database |
| `engine/config.csv` | every setting, with what each one does |

---

## The four packages

### `engine/` — the build

The lines themselves. One `Rscript engine/build.R` produces every table, and it
is the only package here that writes a study run.

`LOT_LONG` is every line the engine built. `LOT_LONG_FINAL` is the same after
the patient-level criteria — a patient excluded by one is absent from it
entirely, not merely shortened — and it is what the study package reads.
`LOT_BUILD_STATUS` says which run owns a prefix and whether it finished:
`started`, then `complete` or `failed`. Every downstream reader resolves the run
through it, and refuses a run that did not finish or that deviated from the
contract. The full list of what a run writes is in `FILES.md`.

### `qc/` — 40 checks on a finished run

Not a re-implementation of the rules: each check states a property the lines
must have, and counts the rows that break it. A `fail` is a defect, a `warn` is
worth reading, an `info` is context. The report names an example row for each
finding, with the patient identifier masked to its last six characters so the
file can be circulated; anything that did not pass carries **why it matters**,
and a check with a declared blind spot (`C5`) says what a zero from it does not
cover.

Beside the checks, for looking at real patients (commands under "Running it"):

- `qc/trace_foldin.R` — patients the fold-in rule (`LOT_RULES.md` §4.8)
  touched, their raw episodes beside the final lines.
- `qc/trace_returns.R` — every drug that came back, in three kinds: folded into
  its return line (§4.8), stayed in its own line after a break (§4.3), or opened
  a line. `qc/examples/returns_trace_example.md` shows the report on fixture
  patients.
- `qc/extract_patients.R` — a named patient's own LOT **inputs**, written out
  so the real rows can be put back through the engine off the warehouse, and
  `qc/extract_review.R`, which lists the treatments in that extract that fall
  inside a line whose regimen does not name them.

The traces write unmasked ids by default, because they exist so a patient can be
looked up and stay on the platform; `TRACE_MASK_PATID=TRUE` masks them. The
extract masks by default, because it is written to be carried off the platform;
`EXTRACT_MASK_PATID=FALSE` writes ids whole. Masking is the same last-six rule
everywhere, so the files still join.

### `validation/` — the rule vignettes

The patients the algorithm is hardest on, each with the assignment the rules
give. A **specification**, not observed output — nothing here has run against a
warehouse. Every offset is derived from the setting that decides it, and the
boundary cases come in pairs straddling that setting by one day. `derived`
follows from the rule quoted beside it; `to_confirm` is a reading of how rules
interact that the first real run settles. `LOT_RULES.md` cites every case by id.

### `melphalan/` — what the melphalan rule did to the numbers

Two complete LOT builds, differenced: one with the rule the study adopted
(`LOT_RULES.md` §4.7) and one without it. That difference is the evidence the
adoption rests on, kept runnable. Opt-in, under its own `melp_simple_`
prefixes, and it cannot become a study run by accident.

---

## Running it

The engine needs R with `DBI`, `odbc` and `glue`, and no code outside
`engine/`. Every run needs `DATABRICKS_PWD` in the environment and a schema to
write to: `DOMINO_USER_NAME` (e.g. `usr00000`), or `PROJECT_WORK_SCHEMA` to
override it.

**Settings.** `engine/config.csv` holds every setting as `name,value,description`;
the environment wins over the file. The cohort table and the output prefix are
never in the file — the caller passes them — and one prefix is one study. The
code lists are read from `CODELIST_DIR`, outside version control, and each file
is hashed as it is read so the run records which version it used. The settings
that decide a line are pinned (`LOT_RULES.md` §1).

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

One build per prefix at a time, start to finish; a second run on a prefix that
another run still holds as `started` is refused. The engine has no dry-run
mode. Each build writes a run log (`PIPELINE_LOG_FILE`, or a
`pipeline_run_<time>_<pid>.log` under `OUTPUT_DIR`), and the `ERROR:` a run
stops on is in it. `qc/run_lot_qc.R` exits non-zero when any check failed,
errored or was skipped, so a handover can wait on it.

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
