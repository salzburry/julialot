# jun_21_2026 — LOT refactor workspace

This folder is the **refactor workspace** for turning the validated LOT algorithm
(currently in `../apr_30_2026/`) into a reusable, study-portable, reproducible
platform. The prior folder `../apr_30_2026/` is the **dashboard production code**
and is left untouched.

Governing design: **`REFACTOR_PLAN.md`** here (the v3 roadmap, the working copy
going forward; an identical reviewed snapshot also remains in `../apr_30_2026/`).

## Status

**Scaffolding / first deliverable only. No algorithm code has been moved or
changed.** Per the roadmap, algorithm extraction begins only after the baseline
(Increment 0A) and synthetic harness (0B) exist, on a dedicated refactor branch
with baseline comparisons.

This first deliverable contains the pieces that can be authored locally **without
Databricks**:

```
contracts/
  inputs.md            # canonical input entity contracts (6 entities) — DRAFT
  outputs.md           # MAP_STACKED / LOT1_BASE / LOT_LONG output contracts — DRAFT
  study.schema.json    # study definition (base + delta, phased gates) — DRAFT
  manifest.schema.json # run manifest (7 version axes, secret-redacted) — DRAFT
tests/fixtures/
  catalog.csv          # spec-traceable fixture inventory (the "weird patients")
  README.md            # how the harness works + the expected-output provenance rule
  synthetic/           # example synthetic INPUT fixtures (a few cases, to set format)
  expected/            # expected-output TEMPLATES only (values are NOT authored here)
scripts/
  validate_config.R          # typed config validation (pure R, runnable)
  validate_reference_data.R  # codelist/registry validation (pure R, runnable)
  verify_no_synthetic.R      # release gate: allowlist + no-synthetic check (pure R)
  compare_run_outputs.R      # comparison hierarchy skeleton (Databricks parts stubbed)
  promote_reference_data.R   # intake -> validated -> approved promotion skeleton
```

## What is intentionally NOT here yet

- **Expected-output values.** Regression-expected outputs are *generated and
  frozen from the approved legacy code at the baseline Git SHA* (on Databricks),
  never hand-authored. Spec-expected outputs are *hand-derived and dual-reviewed*
  with clinical sign-off. So `tests/fixtures/expected/` holds templates only.
- **Any moved/extracted algorithm code.** That waits for the baseline + harness.
- **The Optum adapter / canonical-view shim implementation** (Increment 1B).

## Conventions

- Synthetic PATIDs use the reserved range `9_000_000_000`–`9_999_999_999` (see
  `tests/fixtures/README.md`). Nothing synthetic ships to or runs in production.
- The canonical contract keeps `raw_*` and `normalized_*` values together for
  auditability; NDC is normalized to 11 digits (rule in `contracts/inputs.md`).
