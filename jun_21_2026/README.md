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
Rscript tests/run_unit_tests.R          # 303 tests, all pure-R / local (also run in CI)
```

Run the LOCAL verification engine on synthetic data (a pure-R re-implementation,
faithful to `apr_30_2026/02_lot1.R`, that reproduces hand-derived expected output
— see `engine/` and `engine/fixtures/expected/TRACE.md`):

```
Rscript engine/run_engine.R engine/fixtures /tmp/out   # MAP_STACKED + LOT1_BASE + LOT1_END + LOT_LONG
```

The driver runs the full pipeline **MAP → LOT1 → SCT → LOT1 end → LOT2-5** and all
four outputs are compared against hand-derived golden CSVs: `MAP_STACKED`,
`LOT1_BASE`, `LOT1_END`, and the **full 23-column `LOT_LONG`** — now a **full match**
(`contains_mtx_reg` is computed, no remaining gap). Pharmacy day-supply imputation
(null/<1→28) and same-day claim de-dup (max day-supply) match production; the SCT AUTO
window is 13 days.

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
- **SCT** (`engine/sct.R`): AUTO 13-day window + 60-day gap merge + 180-day tandem,
  single/tandem/excess AUTO, ALLO/CART censoring + LOT-end reason (1=AUTO/2=ALLO/
  3=CART), and the tandem-boundary date selection (window straddling the 180-day
  mark picks the boundary-closest date).
- **LOT1 end** (`engine/lot_end.R`): the priority cascade SCT > CART_INIT > MED_ADD
  > DEATH > DISCONTINUATION > STUDY_END, each gated against the runout, with
  CART_INIT (MED_ADD then CART within 45d) and the post-runout death guard (a LOT2
  trigger after the runout makes DISCONTINUATION win over DEATH).

- **LOT2-5** (`engine/lot_long.R`): the multi-line loop — trigger candidates
  (d_MED/d_ALLO/d_CART/d_AUTO) from the prior line's end, start+type tie-break,
  per-line regimen (30-day window), **line-scoped SCT** end (a MED-started line
  ending at a later ALLO/CART), repeat to MAX_LOT. The **LOT applicable window**
  (Step N.4) is enforced: an AUTO within `lot_window_days` of the start (1 ALLO /
  45 CART / 30 else) is an in-line transplant, but the first AUTO *outside* it
  becomes the ENDING_AUTO that closes the line; ALLO/CART are scoped `> start`
  (strict) so a line's own start SCT never ends it. Special starts: **ALLO
  single-day** (configurable via `allo_lot_span`: `single_day` default vs
  `extend_to_next`, where the next MM agent ends the ALLO line via `MED_ADD`) and
  **CART with no consolidation agent → `SCT_CART` single-day**. A **final
  projection clamp** (Step N.7) then trims the in-LOT AUTO fields to
  `<= LOT_BASE_END_DT` and recomputes SING/TAND/MAX, so an AUTO after the line
  actually ended is dropped. The driver emits the full 23-column `LOT_LONG` (incl.
  SCT flags + CE-sensitive fields). Verified on a 3-line MED cohort +
  line-scoped-SCT, in/out-of-window AUTO, the after-end clamp, CART-no-med, and
  both `allo_lot_span` modes.

Medical day-supply is hardcoded to `medical_day_supply` (every medical claim,
matching production), pharmacy invalid day-supply to 28; the SCT codelist is
required **by content** (the driver fails closed unless it has rows + the
`code_type`/`code`/`sct_type` columns, so SCT can never silently be empty).
CE-sensitive end is implemented (caps at `enddate_ce`, reason `DISENROLLMENT`).
**`contains_mtx_reg` is now COMPUTED** (S16b / Step N.5): 1 iff a LOT's induction
contains a valid maintenance subset (a MONO drug, or a DUAL pair) PLUS an anchor drug
outside it. `MONOMAINTENANCE` / `DUALMAINTENANCEWITH` are **required rollup columns**
(production loads them from `cl_mma_rollup`): `run_engine` **fails closed** if they are
absent, so the field is genuinely *evaluated* and never silently 0 from a missing input
— and the end-to-end golden includes a positive `contains_mtx_reg=1` row (`BORT LENA` =
mono LENA + anchor BORT). LOT_LONG is therefore fully derived — no remaining parity
gap; `UNIMPLEMENTED_FIELDS` is empty (the partial_match mechanism is retained for any
future gap). `run_engine` derives its **defaults from** and **validates the full
resolved config against** the refactor's one typed contract `CONFIG_SPEC` (its
engine-tunable subset — single source, no drift): an unknown key (`max_lott`), a
non-integer (`sct_tandem_days="bad"`), or an out-of-range value (`map_discon_gap_days=0`,
`max_lot=2.9`) is rejected fail-closed, even with no overrides. (`CONFIG_SPEC` is the
*refactor's* contract; `apr_30_2026` production still resolves config from env vars via
`config_lot.R` and does not yet consume it — that wiring is a future step.) **All**
tunables (incl. `cart_consolidation_days`, `lot_n_induction_window_days`,
`sct_tandem_days`) propagate into the LOT1 end logic too (CART_INIT / post-runout death
guard), so a non-default study is internally consistent across LOT1 and LOT2-5.
Regression-expected output (legacy execution on the same synthetic data) is the owner's
hive_metastore step — this proves spec-conformance, not legacy equivalence; `run_engine`
typed-validates params but does
**not** yet run the full canonical-input ROW validator (`validate_canonical`) — the
adapter→canonical-validation→core wiring is still pending, as listed below.

This is **verification only** — it runs the algorithm on synthetic fixtures locally
so the refactor logic can be checked without a warehouse. It is NOT the production
engine (production is Databricks SQL on `hive_metastore`) and never ships
(`engine/` is outside the prod allowlist; fixtures use reserved synthetic PATIDs).

Run the live current-vs-prior comparison on hive_metastore (same DSN/odbc as
`apr_30_2026`; needs `DATABRICKS_DSN`/`DATABRICKS_PWD` + DBI/odbc):

```
Rscript scripts/compare_run_outputs.R --run hive_metastore.lot_prior hive_metastore.lot_current
# the patient-id column is detected PER SIDE and a cross-convention compare (legacy
# PATID vs canonical patient_id) is auto-normalized to patient_id - no flag needed.
# --patid <col> is ONLY for a NONSTANDARD side-A id name (and is ignored unless that
# column exists on side A); do NOT use it to bridge PATID vs patient_id.
```

Both `--local` and `--run` exit **0 on `match`, 2 on `partial_match`, 1 on
`mismatch`** and print per-table status. Each table runs the full hierarchy: schema
parity **incl. data types**, **key-uniqueness** (reported as
`KEYS{dup_a dup_b null_a null_b}` so a null-key block is distinct from a duplicate),
membership anti-joins (`EXCEPT`, which stop the column compare — both modes — when
populations differ), null-safe value compare over **every shared column** in a
**single join** (per-column conditional aggregates — one scan, not one join per
column — counts kept as **double**; `connect_compare` maps BIGINT to numeric so a
`>2^31` count is never narrowed), and a **failure-isolated** null-sentinel checksum
(non-authoritative; a failure is surfaced as `CHECKSUM_FAILED(audit-only)`, never
aborts the verdict). Keys are excluded from the value compare **case-insensitively**
(a legacy `PATID` key never leaks into the aggregates). On a value mismatch only, a
**bounded, deterministic** (`ORDER BY` keys, `LIMIT 100`) diagnostic of the changed
keys + a/b values can be produced; being patient-level it is **OFF by default** —
`--sample-into <catalog.schema.cmp_<run_id>>` (validated to **exactly** that shape: 3
nonempty parts + a run-scoped `cmp_` final, so concurrent/repeat runs don't overwrite)
writes it to a **governed** run-scoped table (the log shows only
`sample_table:<name>(rows=N)` + the `cols:` field), and `--sample-inprocess` is an
explicit diagnostic that holds it in
the R process; neither prints patient data, and a failure shows `SAMPLE_FAILED(audit-only)`.
Clean runs pay nothing.

The **`partial_match`** verdict is **caller-scoped**, not global — for **both** modes,
default **strict**. No output field uses it today (`contains_mtx_reg` is now computed,
`UNIMPLEMENTED_FIELDS` is empty); the mechanism is retained so that if a *future*
deterministic field is not yet derived on one side, that caller passes it as a gap and
the run reports `partial_match` (surfaced, non-blocking) rather than a silent `match`.
The cross-convention id bridge casts the legacy `PATID` to the canonical **string**
`patient_id` (`contracts/inputs.md`). The live warehouse RUN is unexecuted here; the
comparator builders + normalization + reshape + verdict logic are unit-tested.

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
  compare_run_outputs.R          #   comparison hierarchy: LOCAL CSV mode works + tested;
                                 #   hive_metastore SQL authored + db_q/--run wired (DBI/odbc) -
                                 #   only the live warehouse RUN is unexecuted here
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
- **The live hive_metastore RUN of the comparator** (the `sql_*` builders + `db_q`
  + `--run` are wired and unit-tested; what is not done here is EXECUTING them
  against a real warehouse — none in this environment; the *local CSV* comparison
  is complete and tested) and the snapshot-write + affected-patient impact estimate
  in `promote_reference_data.R`. The engine is Databricks SQL over the
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
