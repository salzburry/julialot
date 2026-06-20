# Synthetic golden-test harness

Test-only. **Never runs in production** (see `../../REFACTOR_PLAN.md` §6). Runs
only in a non-prod Databricks schema; synthetic PATIDs are in the reserved range
**9000000000–9999999999** so they can never collide with real members.

## Layout

```
catalog.csv          spec-traceable inventory of cases (the "weird patients")
synthetic/           synthetic INPUT fixtures (canonical-shaped CSVs)
expected/            expected-OUTPUT artifacts (see provenance rule below)
```

## The provenance rule (important)

There are **two** kinds of expected output and they are produced differently —
never hand-mixed:

- **Regression-expected** = generated and frozen from the **approved legacy code
  at the baseline Git SHA** (on non-prod Databricks). Never hand-authored — hand
  authoring would encode what we *believe* the code does. This is the merge gate.
- **Spec-expected** = hand-derived from the specification and **dual-reviewed**
  (clinical + engineering) with sign-off.

So `expected/` here holds **templates only** (headers + `nondeterministic.md`).
Values are filled by generation (regression) or by reviewed derivation (spec).
`catalog.csv` carries `clinical_reviewer` / `engineering_reviewer` columns — a
case is not a merge gate until both are filled and `status = approved`.

## Input fixtures (`synthetic/`)

Canonical-shaped CSVs matching `../../contracts/inputs.md`:
`members.csv`, `medical.csv`, `pharmacy.csv` (and `diagnosis.csv` /
`procedure.csv` / `death.csv` as cases need them). A few cases are drafted
(`status = inputs_drafted` in the catalog) to fix the format; the rest are
`status = todo`.

The harness loads these into the non-prod schema as the `canonical_*` views,
runs the pipeline, and `compare_run_outputs.R` checks the result against the
matching `expected/` artifact.

## Coverage matrix

Every important spec rule needs **≥1 positive and ≥1 negative** fixture
(`polarity` column). The matrix is generated from `catalog.csv`; gaps block the
harness from being declared ready.

## Adding a case

1. Add a row to `catalog.csv` (case_id, area, rule_name, spec_section, polarity).
2. Add the canonical input rows under `synthetic/` (reserved PATID range).
3. Generate regression-expected from legacy@baseline, or hand-derive
   spec-expected and get it dual-reviewed.
4. Fill the reviewer columns and set `status`.
