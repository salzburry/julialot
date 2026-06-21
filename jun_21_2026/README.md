# jun_21_2026 — LOT refactor workspace

This folder is the **refactor workspace** for turning the validated LOT algorithm
(currently in `../apr_30_2026/`) into a reusable, study-portable, reproducible
platform. The prior folder `../apr_30_2026/` is the **dashboard production code**
and is left untouched.

Governing design: **`REFACTOR_PLAN.md`** here (the v3 roadmap, the working copy
going forward; an identical reviewed snapshot also remains in `../apr_30_2026/`).

## Status

**The complete local (Level-1) layer is implemented and tested. No algorithm
code has been moved or changed.** Per the roadmap, algorithm extraction begins
only after the baseline (Increment 0A) and synthetic harness (0B) exist on a
dedicated refactor branch with baseline comparisons.

Run the unit tests (from this folder):

```
Rscript tests/run_unit_tests.R          # 139 tests, all pure-R / local
```

Run the live current-vs-prior comparison on hive_metastore (same DSN/odbc as
`apr_30_2026`; needs `DATABRICKS_DSN`/`DATABRICKS_PWD` + DBI/odbc):

```
# canonical-named (refactored) output tables:
Rscript scripts/compare_run_outputs.R --run hive_metastore.lot_prior hive_metastore.lot_current
# legacy apr_30 output tables use PATID (other names fold case): add --patid PATID
Rscript scripts/compare_run_outputs.R --run hive_metastore.lot_prior hive_metastore.lot_current --patid PATID
```

It runs the full hierarchy per table (schema -> membership anti-joins -> null-safe
value compare -> checksum) and exits 0 on `match`, 1 on `mismatch`.

Contents:

```
contracts/
  inputs.md / outputs.md         # canonical input (6 entities) + output contracts
  study.schema.json              # study definition (base + delta, phased gates)
  manifest.schema.json           # run manifest (7 version axes, secret-redacted)
cohort/gates/registry.yml        # gate modules: phase, depends_on, anchor, codelist
studies/overall.yml, ndmm.yml    # example base + derived study (Overall -> NDMM delta)
scripts/                         # all runnable + unit-tested (except the hive_metastore db_q seam):
  lib.R                          #   shared helpers (NDC normalize, hashing, yaml/json)
  validate_config.R              #   typed config, fail-fast
  validate_reference_data.R      #   codelist validation (schema/NDC/collision/bounds)
  validate_canonical.R           #   adapter validation report over canonical fixtures
  validate_study.R               #   base+delta cross-rules + gate DAG (cycle detection)
  build_coverage_matrix.R        #   positive/negative coverage from the catalog
  verify_no_synthetic.R          #   release gate: allowlist + reserved-PATID scan
  compare_run_outputs.R          #   comparison hierarchy: LOCAL CSV mode works + tested
                                 #   (numeric/date normalization, output contract); the
                                 #   hive_metastore SQL is authored - only db_q (ODBC) is unwired
  promote_reference_data.R       #   intake->validated->approved: validation + dry-run
                                 #   runnable + tested; only snapshot-write/impact = stub
  validate_manifest.R            #   ONE manifest gate: structural (closed schema,
                                 #   incl. secrets[]) + runtime (redaction, publish cross-rules)
tests/
  run_unit_tests.R, testutil.R   # Level-1 runner + tiny framework
  unit/                          # the tests (config, refdata, canonical, study, gate,
                                 #   compare) + cmp/ comparison fixtures
  fixtures/                      # catalog.csv + synthetic/ inputs + expected/ templates
```

## What is intentionally NOT here (hard-gated on Databricks or clinical review)

These are deliberately not done, because doing them would require the warehouse,
require clinical sign-off, or violate the behaviour-preserving mandate (no second
algorithm, no premature extraction):

- **Expected-output values.** Regression-expected outputs are *generated and
  frozen from the approved legacy code at the baseline Git SHA* (Databricks),
  never hand-authored. Spec-expected outputs are *hand-derived and dual-reviewed*
  with clinical sign-off. So `tests/fixtures/expected/` holds templates only.
- **The two hive_metastore-only seams:** executing the large-table comparison SQL
  (the SQL is authored as `sql_*` builders; only `db_q` ODBC execution in
  `compare_run_outputs.R` is unwired — the *local CSV* comparison is complete and
  tested) and the snapshot-write + affected-patient impact estimate in
  `promote_reference_data.R`. The engine is Databricks SQL over the
  **hive_metastore** catalog (DBI/odbc), not Spark.
- **Any moved/extracted algorithm code**, and the **Optum canonical-view shim**
  (Increment 1B) — both wait for the baseline + harness on the refactor branch.
- **Clinical sign-off** on the gate registry semantics and the example study
  gate values (all marked DRAFT).

## Conventions

- Synthetic PATIDs use the reserved range `9000000000`-`9999999999` (see
  `tests/fixtures/README.md`). Nothing synthetic ships to or runs in production.
- Config files are **ASCII-only** (the toolkit must parse under a `C` locale).
- The canonical contract keeps `raw_*` and `normalized_*` values together for
  auditability; NDC is normalized to 11 digits (rule in `contracts/inputs.md`).
