# LOT algorithm — behavior-preserving refactor roadmap

Status: **design/roadmap only**. No algorithm code is moved or changed by this
document. Implementation starts only after the regression harness exists
(Increment 0).

## 1. Goal & scope

Reuse the LOT (line-of-therapy) algorithm across **studies** and over **time**,
and make yearly/monthly **codelist updates** (NDC / HCPCS / CPT / dx) and other
reference-data changes easy and *safe*. Today the algorithm logic, the Optum
database bindings, the study/cohort definition, and the codelists are
interleaved, and codelists have no versioning, provenance, or release-blocking
validation.

**Scope guardrails (deliberately narrow):**
- Optum is the only near-term database. Define a canonical input boundary, but
  **do not** build a generalized multi-database adapter framework yet.
- **Do not** build a generic cohort-rule DSL. Use explicit, individually tested
  gate modules that a study file enables/parameterizes.
- **Do not** create an installable package or multi-repo release process until
  there is a real second consumer (second DB, second team, or independently
  pinned study releases).
- **Behaviour-preserving**: the first refactor must reproduce current
  patient-level outputs; no opportunistic redesign while extracting modules.

## 2. Hard constraint: no local Spark/sparklyr

The real algorithm is Spark SQL + Spark `aggregate()` state machines (MAP, SCT)
executed on Databricks. There is **no local Spark/sparklyr**, so:
- A full local (e.g. DuckDB) re-implementation is **rejected** — it would be a
  second algorithm that can itself be wrong and give false confidence.
- Databricks is the **only authoritative execution engine** for MAP/LOT/SCT.
- Local testing is limited to the **pure-R** surface (config, codelist
  validation, manifest hashing, gate selection, parameter/date helpers).

## 3. Principles

1. **Safety net first.** Lock current outputs with a baseline + synthetic golden
   tests before moving any algorithm code.
2. **Two tracks, never mixed.** (a) production stabilization branch for
   dashboard/cohort bug fixes; (b) refactor branch with baseline comparisons. No
   opportunistic cleanup while extracting modules — otherwise a moved count
   can't be attributed to code vs. fix.
3. **Config/data over code.** A new study or a codelist update should not edit
   core SQL.
4. **Separate version axes** (see §7): algorithm, study definition, reference
   data, source-data vintage, dashboard — each independently recorded.
5. **Explicit gates, not a DSL.** Each cohort gate is an identifiable module with
   documented inputs, output flag, anchor date, and unit tests.
6. **Fail fast.** Invalid config/reference data is a release-blocking error
   *before* expensive claims scans, distinct from non-blocking warnings.
7. **Package later.** Strict internal modules + versioned manifests deliver most
   of the benefit now without operational overhead.

## 4. Test strategy (three levels)

| Level | Where | What it covers | Runs on every change? |
|------|-------|----------------|------------------------|
| 1. Unit | Local (pure R) | deterministic helpers, parameter rules, config validation, codelist load/validate/normalize, manifest hashing, gate selection | yes (CI) |
| 2. Synthetic integration | **Databricks** | the real Spark SQL / MAP / SCT / LOT2-5 pipeline over hand-built synthetic inputs with hand-defined expected outputs | per refactor increment |
| 3. Golden production regression | **Databricks** | frozen real-cohort `MAP_STACKED` / `LOT1_BASE` / `LOT_LONG` outputs compared patient-by-patient | before merging any core extraction |

DuckDB may be used for simple SQL/config checks but is **never** the authority
for MAP/SCT behaviour.

## 5. Synthetic golden-test harness — design

The harness is the guardrail that lets the algorithm be refactored safely. It
must be **rich enough to be trusted**: intentionally weird patients, not clean
examples. A too-small set gives false confidence.

### 5.1 Components
```
tests/
  fixtures/
    synthetic/
      members.csv            # PATID, enrollment spans, DOB, sex, death dt
      medical.csv            # PATID, svc_date, PROC_CD, BILL_PROC_CD, NDC, claim_type
      rx.csv                 # PATID, svc_date, NDC, days_sup
      med_diagnosis.csv      # PATID, dt, DIAG  (for SCT/cohort)
      med_procedure.csv      # PATID, dt, PROC  (ICD-tagged, for SCT)
      cohort_input.csv       # ELIG_COH_FINAL stand-in (PATID, OBS_END_DT, ...)
    expected/
      map_stacked.csv        # hand-defined expected MAP rows per patient
      lot1_base.csv          # hand-defined expected LOT1 fields
      lot_long.csv           # hand-defined expected LOT 1..5 rows
      nondeterministic.md    # documented fields excluded from strict compare
  databricks_integration/
    load_synthetic.R         # load fixtures as Databricks temp tables/views
    run_pipeline_synthetic.R # run 02_lot1 + 03_lot2_5 against the synthetic schema
  regression/
    compare_run_outputs.R    # patient/column diff: actual vs expected (or frozen prod)
```

### 5.2 Synthetic patient catalog (the cases that MUST exist)

Each patient is a tiny, hand-traced scenario with a documented expected result.

**MAP engine**
- pharmacy claim with simple runout (`date + days_sup - 1`)
- pharmacy **pushout**: new claim on/before current rx-runout → `rx_runout + new_days_sup`
- pharmacy **reset-without-pushout**: new claim after rx-runout but within med-runout (spec p.5 correction)
- medical claim runout (`date + day_supply - 1`, **never** pushed out)
- imputed medical day-supply (default 28) and imputed null/<1 rx day-supply
- MAP boundary: new MAP when `date > max(rx_runout, med_runout)`
- discontinuation flag at the 90-day gap threshold (exactly at, just under, just over)

**LOT1 induction**
- single-regimen LOT1
- induction-window edge: a med exactly at `LOT1_START + window - 1` (in) vs `+ window` (out)
- steroid excluded from induction (protocol 5.1.1) but attached separately
- permissible substitute (biosimilar) folded into base meds
- first-add-med date and the seeded random tie-break (flag as nondeterministic input → fixed seed)

**SCT**
- AUTO single
- AUTO tandem (2nd AUTO within 180d, no ALLO between) → tandem flag
- AUTO pair > tandem gap → treated as separate
- AUTO 14-day windowing: workup claims + actual TX on the last day in window
- AUTO 60-day gap merging across windows
- ALLO ends the LOT
- CART ends the LOT; CART consolidation (45-day) window
- tandem-boundary date selection (claim near the 180d post-first-AUTO boundary)

**LOT2-5**
- clean progression to LOT2/LOT3
- new induction med not in prior base meds triggering the next LOT
- `MAX_LOT` cap behaviour
- `ALLO_LOT_SPAN` single_day vs extend_to_next

**Censoring / observation**
- death before natural LOT end → `OBS_END_DT` cap
- `CENSOR_AT_DISENROLLMENT` sensitivity (primary vs sensitivity OBS_END_DT)
- enrollment gap within tolerance vs beyond

**Degenerate / "weird"**
- patient with only steroid claims (no qualifying backbone)
- patient with no qualifying meds at all
- same-date two-token case (documents the known nondeterministic display field)
- duplicate claims (same PATID/MED/date/claim_type) → dedup rule (max day-supply, min code)

### 5.3 Expected-output method
For each synthetic patient, the expected `MAP_STACKED` / `LOT1_BASE` /
`LOT_LONG` rows are **hand-derived from the spec** and stored in
`expected/`. Known nondeterministic fields (seeded tie-break, same-date token)
are listed in `nondeterministic.md` and excluded from the strict compare (or
compared as a set).

### 5.4 Comparison script (Databricks)
`compare_run_outputs.R` joins actual vs expected on `(PATID, LOT_NUM)` /
`(PATID, MAP_CNT)`, reports: patients only-in-actual / only-in-expected, and
per-column mismatches with both values. It returns a non-zero status on any
unexplained difference. The same script runs against a **frozen real cohort**
(Increment 0 baseline) for Level-3 regression.

## 6. Increment roadmap (behaviour-preserving)

> Do not move algorithm code into `core/` until Increment 0 exists.

- **Increment 0 — Freeze & document current behaviour.** Record the current Git
  SHA as a release baseline; persist patient-level `MAP_STACKED`, `LOT1_BASE`,
  `LOT_LONG` for a frozen real cohort + critical counts; build the synthetic
  fixtures + expected outputs (§5); write `compare_run_outputs.R`; enumerate
  known nondeterministic fields. Deliverable: a reproducible baseline + a
  red/green diff, not screenshots.
- **Increment 1 — Run manifests + typed config.** A validated config object
  (explicit types, allowed values, defaults, required fields, fail-fast). Every
  run writes a manifest: Git SHA, algorithm version, study id/version, full
  resolved config + its hash, source DB + quarterly vintage, reference-data file
  hashes, timestamp, runtime, key-stage row counts, output table checksums.
  No algorithm logic changes.
- **Increment 2 — Standardize reference-data loading (the codelist registry).**
  One loader + one validation contract, migrated incrementally (one low-risk
  list first, verify parity, then the rest). Registry row carries: code system,
  normalized code, concept/token, effective start/end, approval status, source,
  clinical owner, engineering approver, superseded version, change rationale,
  expected row-count range, duplicate/normalization policy. **Invalid rows are
  never silently dropped**; validation distinguishes warnings from
  release-blocking errors. SME intake → automated validate/promote → live
  (matches the mixed-ownership model).
- **Increment 3 — Extract core by existing stage (no redesign).** Split the
  *current* SQL into `core/{map,lot1,sct,lot2_5,maintenance}`, each exposing a
  small contract (inputs, parameters, outputs, QC checks). Output must be
  patient-for-patient equivalent (Level-3 gate).
- **Increment 4 — Optum normalization boundary.** Canonical Optum views
  (`patient_id, service_date, diagnosis_code, procedure_code, ndc, days_supply,
  place_of_service, ...`) that core reads. Optum-specific fields stay reachable
  via an extension area, not forced into a lowest-common-denominator minimum.
  Only one adapter (Optum) is implemented.
- **Increment 5 — Studies first-class.** `studies/<id>/` holds only what
  legitimately varies (study.yml, cohort.yml selecting/parameterizing existing
  gates, reference_data.lock, README). Adding a study selects gates or adds a
  new *tested* gate module — never edits core MAP/LOT/SCT.
- **Increment 6 — Package only at a real second consumer.** Promote `core/` to
  an installable package when a second DB is onboarded, another team consumes
  it, or multiple production studies need independently pinned algorithm
  releases.

## 7. Version axes (recorded in every run manifest)
- **algorithm version** — the core MAP/LOT/SCT logic
- **study-definition version** — cohort gates + study switches
- **reference-data version** — codelist/registry snapshot
- **source-data vintage** — Optum quarterly table set
- **dashboard version** — reporting layer

A monthly NDC/HCPCS change bumps only the reference-data version — no algorithm
release. This is what lets us answer *why* a count moved (code vs. cohort vs.
reference data vs. a new Optum quarter).

## 8. Target repository shape (end-state)
```
R/
  core/      { map/ lot1/ lot2_5/ sct/ }   # DB-agnostic algorithm
  cohort/    { gates/ }                     # explicit tested gate modules
  adapters/  { optum/ }                     # only Optum implemented for now
  config/                                   # one layered, validated config
  reference_data/                           # registry loader + validation
  orchestration/                            # run_pipeline + thin run_all wrapper
  reporting/                                # dashboards (current 04-07 logic)
studies/        { ndmm_2025/ }              # per-study config, no core edits
reference_data/ { intake/ approved/ manifest.yml }
tests/          { unit/ fixtures/ databricks_integration/ regression/ }
scripts/        { validate_config.R validate_reference_data.R
                  compare_run_outputs.R promote_reference_data.R }
```

## 9. Acceptance criteria (refactor "done")
- Frozen synthetic patients produce identical MAP and LOT results.
- The production comparison shows no unexplained patient-level changes.
- A study can change dates/thresholds/enabled gates without editing core code.
- A reference-data update requires no algorithm edit.
- Every output traces to code, study, source-data, and reference-data versions.
- Invalid config / malformed inputs fail before expensive claims scans start.
- Current `run_all.R` behaviour stays available via a thin compatibility wrapper.
- A second study can be added without copying the pipeline.

## 10. Explicitly out of scope for the first release
- Generalized multi-database adapter framework (revisit at a real 2nd DB).
- Installable R package / multi-repo release (revisit at a real 2nd consumer).
- Generic cohort-rule DSL (use explicit tested gates).
- Any algorithm redesign or opportunistic cleanup during extraction.
