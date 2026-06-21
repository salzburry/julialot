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
Rscript tests/run_unit_tests.R          # 190 tests, all pure-R / local
```

Run the LOCAL verification engine on synthetic data (a pure-R re-implementation,
faithful to `apr_30_2026/02_lot1.R`, that reproduces hand-derived expected output
— see `engine/` and `engine/fixtures/expected/TRACE.md`):

```
Rscript engine/run_engine.R engine/fixtures /tmp/out   # MAP_STACKED + LOT1_BASE + LOT1_END
```

The driver runs the full pipeline **MAP → LOT1 → SCT → LOT1 end** and its
`LOT1_END` output is verified against hand-derived expected (incl. an `SCT_ALLO`
end). Pharmacy day-supply imputation (null/<1→28) and same-day claim de-dup
(max day-supply) match production; the SCT AUTO window is 13 days.

**For reviewers:** `engine/REVIEW.md` maps every engine rule to its production
source line (`apr_30_2026/02_lot1.R:NNN`) and lists verified coverage + the
explicitly-deferred corners.

Verified stages + edge cases (against hand-derived expected):
- **MAP** (`engine/map.R`): pharmacy pushout / reset, gap→new MAP, medical
  no-pushout, same-day pharmacy-first tie, single claim, discon flag both sides of
  the 90-day boundary.
- **LOT1** (`engine/lot1.R`): steroid exclusion from start/induction/base,
  induction-window cutoff, multi-drug regimen, first-add med+date, steroid-only →
  no LOT1.
- **SCT** (`engine/sct.R`): AUTO 14-day window (max date) + 60-day gap merge +
  180-day tandem, single/tandem/excess AUTO, ALLO/CART censoring + LOT-end reason
  (1=AUTO/2=ALLO/3=CART). (Tandem-boundary date-selection corner documented as
  not-yet-ported.)
- **LOT1 end** (`engine/lot_end.R`): the priority cascade SCT > MED_ADD > DEATH >
  DISCONTINUATION > STUDY_END, each gated against the runout (a trigger after
  discontinuation does not fire). (CART_INIT + post-runout-death-guard documented
  as not-yet-ported.)

Still to port + verify the same way: the **LOT2-5** loop (`LOT_LONG`) — trigger
the next line from the LOT1 end event, re-derive the regimen, repeat to MAX_LOT.

This is **verification only** — it runs the algorithm on synthetic fixtures locally
so the refactor logic can be checked without a warehouse. It is NOT the production
engine (production is Databricks SQL on `hive_metastore`) and never ships
(`engine/` is outside the prod allowlist; fixtures use reserved synthetic PATIDs).

Run the live current-vs-prior comparison on hive_metastore (same DSN/odbc as
`apr_30_2026`; needs `DATABRICKS_DSN`/`DATABRICKS_PWD` + DBI/odbc):

```
Rscript scripts/compare_run_outputs.R --run hive_metastore.lot_prior hive_metastore.lot_current
# the patient-id column (PATID vs patient_id) is AUTO-DETECTED; override with --patid <col>
```

Per table it runs the full hierarchy and exits 0 on `match`, 1 on `mismatch`:
schema parity **incl. data types**, **key-uniqueness** (`GROUP BY ... HAVING count>1`),
membership anti-joins (`EXCEPT`), null-safe value compare over **every shared
column** (per-drug/class flags included), and a null-sentinel checksum.

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
