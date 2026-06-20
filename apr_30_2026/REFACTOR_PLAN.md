# LOT algorithm — behavior-preserving refactor roadmap (v2)

Status: **design/roadmap only.** No algorithm code is moved or changed by this
document. Implementation starts only after the regression harness and frozen
baseline exist (Increment 0A/0B).

This v2 incorporates review feedback: source-system-agnostic (not "DB-agnostic")
framing, contracts defined early, regression-expected vs spec-expected outputs,
PHI governance for frozen baselines, canonical comparison/checksum rules,
performance regression, dual-run/rollback, an explicit failure policy, a
spec-traceable + dual-reviewed fixture catalog, a three-state reference-data
registry, and the rule that **synthetic test data never ships to production**.

## 1. Goal & scope

Reuse the LOT (line-of-therapy) algorithm across **studies** and over **time**,
and make yearly/monthly **codelist updates** (NDC / HCPCS / CPT / dx) and other
reference-data changes easy and *safe*. Today the algorithm logic, the Optum
bindings, the study/cohort definition, and the codelists are interleaved, and
codelists have no versioning, provenance, or release-blocking validation.

**Scope guardrails (deliberately narrow):**
- Optum is the only near-term database. Define the canonical input/output
  contract now, but implement only the Optum canonicalization; **no** generalized
  multi-database adapter framework.
- **No** generic cohort-rule DSL. Use explicit, individually tested gate modules
  that a study file *enables/parameterizes by name*.
- **No** installable package / multi-repo release until a real second consumer
  (second DB, second team, or independently pinned study releases).
- **Behaviour-preserving**: the first refactor must reproduce current
  patient-level outputs; no opportunistic redesign while extracting modules.

## 2. Naming correction: source-system-agnostic, Spark-native core

The target is **not** a "DB-agnostic" core. The algorithm is Spark SQL +
Spark `aggregate()` state machines and depends on Databricks/Spark execution
semantics. The realistic first target is a **source-system-agnostic,
Spark-native** core: it stops depending on Optum physical table/column names
(reads canonical views), but still runs only on Spark/Databricks. It is **not**
portable to Snowflake/BigQuery/DuckDB/standard SQL, and this plan does not
promise that.

```
R/core/       # Source-system-agnostic, Spark-native LOT algorithm
R/adapters/   # Source-specific canonicalization, initially Optum only
```

## 3. Hard constraint: no local Spark/sparklyr

There is no local Spark/sparklyr, so:
- A full local (DuckDB) re-implementation is **rejected** — it would be a second
  algorithm that can itself be wrong.
- **Databricks is the only authoritative engine** for MAP/LOT/SCT.
- Local testing is limited to the **pure-R** surface (config, codelist
  validation, manifest hashing, gate selection, parameter/date helpers).

## 4. Principles

1. **Safety net first** — frozen baseline + synthetic golden tests before any
   algorithm code moves.
2. **Two tracks, never mixed** — (a) production stabilization branch for
   dashboard/cohort fixes; (b) refactor branch carrying baseline comparisons. No
   opportunistic cleanup during extraction, so a moved count is always
   attributable to code vs. fix.
3. **Config/data over code** — a new study or codelist update must not edit core
   SQL.
4. **Separate version axes** (§11) — algorithm, study, reference data,
   source-data vintage, dashboard — each independently recorded and immutable per
   run.
5. **Explicit gates, not a DSL** — each gate is a tested module; study files
   select/parameterize by name.
6. **Fail fast, by policy** (§10) — blocking errors before expensive claims
   scans; warnings vs. release-blocking errors clearly distinguished.
7. **Synthetic data is test-only** (§6) — it never ships to or runs in
   production.
8. **Package later** — strict internal modules + versioned manifests give most of
   the benefit now.

## 5. Canonical contracts (defined in Increment 0/1, before extraction)

The canonical **input** and **output** contracts are documented *before* code is
moved, so Increment 3 extraction does not bake in hidden Optum assumptions that
Increment 4 then has to undo. The Optum adapter is implemented later (Inc 4) but
implements *this* contract.

Each canonical input entity declares: required entities; canonical column names
& types; nullable vs required; code-normalization conventions; date semantics;
expected uniqueness; allowed duplicate behaviour; and (for outputs) keys &
schemas. Example:

```
canonical_medical
  patient_id        string, required
  service_date      date,   required
  procedure_code    string, nullable
  bill_proc_code    string, nullable
  ndc               string, nullable      # normalized 11-digit (see §12)
  claim_type        string, required       # {medical, pharmacy}
  source_record_id  string, recommended
```

Output contracts (`MAP_STACKED`, `LOT1_BASE`, `LOT_LONG`) pin keys, columns,
types, and which fields are intentionally nondeterministic (§9).

## 6. Synthetic data is test-only — never in production

The synthetic fixtures and the whole golden harness exist **only to let CI/dev
verify behaviour**. They must never be deployed to or executed in the production
(Domino/Databricks) environment.

- All synthetic data + harness live under `tests/` (a test-only tree).
- The production bundle/deploy copies only `R/`, `studies/`,
  `reference_data/approved/`, `orchestration/`, `reporting/` — **never**
  `tests/`. A `compare`/promote build step asserts no `tests/` path is included.
- Synthetic PATIDs use a reserved/obviously-fake range and a `SYNTHETIC` marker
  column, so they can never be confused with real members and are trivial to
  detect and purge.
- A documented "purge synthetic" / "verify-no-synthetic-in-prod" check runs
  before any production release.

## 7. Two kinds of expected outputs (do not mix)

- **Regression-expected (current-behavior)** — what the *current* code produces
  today. Used to prove the refactor changed nothing. This is the merge gate.
- **Spec-expected (clinical-expected)** — what the *specification* says should
  happen. Used to flag *future* algorithm fixes where current behaviour and spec
  diverge.

These live in separate files and are never mixed in one golden test — otherwise a
refactor failure (regression) becomes indistinguishable from a known
spec-divergence. Where they differ, the divergence is logged as a candidate
future fix, not a refactor blocker.

## 8. Frozen production baseline — PHI governance

Patient-level `MAP_STACKED` / `LOT1_BASE` / `LOT_LONG` for a frozen real cohort
are **sensitive data and are NOT committed to Git.** They live only in an
access-controlled Databricks schema / governed object store. The repo keeps only
**metadata**: schemas, row counts, deterministic checksums (§12), the comparison
script, and a pointer/manifest.

The baseline manifest records (so "same quarter" can't silently drift):
Delta table version/timestamp, source table identifiers, schema snapshot/hash,
extraction timestamp, cohort snapshot id, access-control owner. Prefer Delta
time-travel / physical snapshotting over a bare quarter name.

## 9. Synthetic golden-test harness — design

The harness must be **rich enough to be trusted**: intentionally weird patients,
not clean examples. A too-small set gives false confidence.

### 9.1 Fixture catalog (spec-traceable, dual-reviewed)
Each fixture is a row in a catalog (more durable than prose):
```
case_id, spec_section, rule_name, input_files, expected_outputs,
expected_qc, clinical_reviewer, engineering_reviewer, status
```
**Governance:** each hand-derived expected output is derived by one person,
independently reviewed by another, tied to a spec section, approved before it
becomes a merge gate, and changed only through explicit review. A mistaken
fixture must not be allowed to force the refactor to reproduce a mistaken
expectation.

### 9.2 Patient catalog (cases that MUST exist)
MAP: simple runout; pharmacy pushout; pharmacy reset-without-pushout (spec p.5);
medical runout (never pushed out); imputed medical day-supply (28) and imputed
null/<1 rx day-supply; MAP boundary; 90-day discontinuation at / just under /
just over threshold. **Two records same date, conflicting days-supply.**
**Duplicates differing only in source_record_id.** **Overlapping pharmacy +
medical coverage for the same drug.**

LOT1: single regimen; induction-window edge (`+window-1` in vs `+window` out);
steroid excluded from induction but attached separately; permissible substitute;
seeded random tie-break (fixed seed); **multiple same-day agents that could
change LOT ordering.**

SCT: AUTO single; AUTO tandem (2nd within 180d, no ALLO between); AUTO pair
beyond tandem gap; AUTO 14-day windowing (workup vs actual TX on last day);
AUTO 60-day gap merging; ALLO ends LOT; CART ends LOT + 45-day consolidation;
tandem-boundary date selection.

LOT2-5: clean progression; new induction med triggering next LOT; `MAX_LOT` cap;
`ALLO_LOT_SPAN` single_day vs extend_to_next.

Censoring: death cap on `OBS_END_DT`; `CENSOR_AT_DISENROLLMENT` sensitivity;
enrollment gap within vs beyond tolerance.

Reference-data / dates: **10→11-digit NDC normalization that collides with
another source form**; **effective-dated codelist where a code changes
classification over time**; **patient exactly at study-start and study-end
boundaries**; **leap-day / month-end date arithmetic**; **backdated record
arriving after an earlier run** but inside the study period; **null/malformed
service date rejected before execution**.

Degenerate: only-steroid patient; no-qualifying-meds patient; dedup
(max day-supply, min code).

Cohort gates / derivation (prove base + delta): a patient who **passes the base
(Overall) but fails an added gate** (e.g. a pregnancy code in window → dropped by
NDMM); a patient **flipped by a parameter change** (passes 6-month baseline CE,
fails 12-month); a patient **flipped by a tightened gate** (qualifies on ≥1-day
follow-up CE, fails strict 3-month). These prove a derived study = base + delta
yields the expected attrition difference, per added / changed gate.

### 9.3 Coverage matrix
An explicit matrix shows every important spec rule has **≥1 positive and ≥1
negative** fixture. Gaps in the matrix block the harness from being declared
ready.

## 10. Failure policy (explicit)

| Class | Example | Behaviour |
|------|---------|-----------|
| Blocking error | malformed codelist, missing required column, invalid date range | abort before claims scans |
| Blocking regression | patient-level mismatch vs current-behavior expected | fail the build/merge |
| Warning | unusual-but-allowed row count | proceed, record in manifest |
| Degraded mode | a gate's source unavailable | allowed **only** where clinically approved, and recorded in the manifest |
| Informational | expected data-vintage change | record only |

A clinical cohort gate must **not** silently pass all patients because a source
is unavailable unless that degraded behaviour is explicitly approved and recorded
in the run manifest.

## 11. Run manifest (immutable once a run completes)

Records, at minimum: Git SHA + dirty-state flag; algorithm version; study
id/version; full resolved config + its hash + config precedence sources; source
DB + **exact Delta table versions** (not just names) + quarterly vintage;
reference-data file hashes + approval status; Databricks Runtime + Spark version
+ warehouse/cluster config + Photon on/off + relevant Spark settings; key-stage
row counts + stage runtimes; output table names + **schema hash** + output
checksums; warnings + degraded gates; baseline/comparison run id; hash algorithm
used; run timestamp + runtime version. **A completed manifest must be sufficient
to reproduce the run's inputs and settings**, and is immutable after completion.

**Five version axes** (a monthly NDC/HCPCS change bumps only reference-data — no
algorithm release): algorithm · study-definition · reference-data ·
source-data vintage · dashboard.

## 12. Canonical comparison & checksums

Equality is checked only **after canonical normalization**: deterministic sort
keys; one canonical null representation; explicit date/time & timezone handling;
numeric type coercion; floating-point tolerance; arrays declared ordered or
unordered; duplicates treated as errors or normalized; intentionally-excluded
columns (the nondeterministic fields); documented allowed-equivalence rules.

**Checksums are computed only after canonical sort + normalization** — for large
Spark tables use deterministic sorted hashes or per-partition fingerprints, so
drift comes from logic, not row ordering or type coercion. The hash algorithm is
recorded in the manifest.

## 13. Performance regression

Patient-level equivalence is necessary but not sufficient — a behaviour-
preserving refactor can still be unusably slow. Capture stage-level baselines:
duration; rows read/written; shuffle volume; spill; task skew; count of repeated
heavy scans; output file/table counts. Use **tolerances**, not exact durations,
e.g.:

```
No core stage may exceed baseline duration by >30% without an approved explanation.
```

## 14. Dual-run & rollback

Every extraction increment supports old path, new path, side-by-side compare,
explicit promotion, and immediate rollback. A switch drives it:

```
LOT_ENGINE_MODE = legacy | refactored | compare
```

`compare` runs both paths and fails on any unexplained difference. A validated
stage is **never** replaced in place before its replacement passes both synthetic
and frozen-production comparisons. Rollback to the prior algorithm version is
documented and tested.

## 15. Reference-data registry (three states)

```
intake     editable SME submission
validated  machine-validated, not yet approved
approved   immutable production release (versioned + hashed)
```

Promotion intake→approved requires: schema validation; code-system validation;
**NDC 10→11-digit normalization with the exact documented rule** (not a generic
format check) + normalization-collision checks; duplicate policy; effective-date
checks; expected token coverage; row-count bounds (**at the codelist/version
level, not per row**); clinical approval; engineering approval; generated
immutable version + hash. Invalid rows are **never silently dropped**; the
validation result distinguishes warnings from release-blocking errors.

Registry row carries: code system; normalized code; concept/token; effective
start/end; approval status; source; clinical owner; engineering approver;
superseded version; change rationale; duplicate/normalization policy.

## 16. Study definitions: derivation + the four gate change-types

Studies relate by **derivation**, not independent flat lists. The real
Overall → NDMM transition is the general case: moving to a new study **added**
some IE criteria, **changed** some existing ones, and left the rest alone.
NDMM added the no-belantamab / no-prior-MM-tx / no-other-cancer / no-pregnancy
exclusions *and* tightened existing gates (follow-up CE from ≥1 day to strict
3-month; baseline CE from 6 to 12 months) on top of the Step-6 Overall base. A
study definition must make that **explicit and auditable** — never a
copied-and-edited pipeline.

### 16.1 Base + delta (inheritance)
A study may declare a `base:` it derives from, inheriting that base's resolved
gate set + parameters, then apply a **gate delta**:

```yaml
# studies/ndmm_2025/cohort.yml
base: overall_2025                # inherit Overall's gate set (Step-6 denominator)
gates:
  add:                            # NEW IE criteria not in the base
    no_belantamab:   true
    no_prior_mm_tx:  true
    no_other_cancer: { lookback_months: 12 }
    no_pregnancy:    { anchor: study_period }
  override:                       # EXISTING gates whose params/logic CHANGED
    followup_ce: { months: 3, strict: true }   # Overall was >=1 day
    baseline_ce: { months: 12 }                # Overall was 6 months
  disable: []                     # base gates turned off (relaxation), recorded
```

`overall_2025` is itself a base study that stops at the Step-6 denominator with
the NDMM-only exclusions absent.

### 16.2 The four change-types (each distinguishable + traceable)
1. **New gate** — not in the base (new IE). Needs its own tested module + fixtures.
2. **Parameter change** — same module, different params (baseline CE 6→12mo). The
   module is parameterized; the study pins different values.
3. **Logic change** — the rule itself changes, not just a number. This is a **new
   gate version**, not a silent edit; both versions stay tested.
4. **Removal/relaxation** — a base gate disabled/loosened, recorded explicitly.

### 16.3 Versioned gates + an explicit base-diff
Each gate module is versioned; a study pins `gate@version` + parameters. The
**resolved gate set AND the diff from the base** are written to the run manifest,
so when NDMM counts differ from Overall the cause is attributable ("added
no_pregnancy; tightened followup_ce to strict 3-month"), never guessed. This is
the cohort-side complement of the five version axes (§11): the study-definition
version is the composition of its base + gate-version pins + parameters.

Each gate module declares: input contract; index/anchor date; lookback/follow-up
window; output flag; failure behaviour; relevant codelist; QC count; test cases.
Study files **select and parameterize** modules by name — they never encode SQL
(`where: "age >= 18 ..."` is disallowed).

## 17. Test strategy (three levels)

1. **Unit (local, pure R)** — helpers, parameter rules, config validation,
   codelist load/validate/normalize, manifest hashing, gate selection. Runs in CI
   on every change.
2. **Synthetic integration (Databricks)** — the real Spark pipeline over the
   §9 fixtures vs current-behavior expected. Per increment.
3. **Golden production regression (Databricks)** — frozen real-cohort
   `MAP_STACKED`/`LOT1_BASE`/`LOT_LONG`, patient-by-patient (§8, §12). Before any
   core extraction merges.

## 18. Increment roadmap (behaviour-preserving)

- **0A — Baseline inventory.** Freeze Git SHA; inventory source/output schemas;
  define the deterministic comparison rules (§12); identify nondeterminism;
  capture governed production snapshots (§8). A formal release baseline.
- **0B — Synthetic harness.** Build fixtures (§9); **independently review &
  approve** expected outputs; automate Databricks execution + comparison
  (`compare_run_outputs.R`).
- **1 — Contracts, manifest, typed config.** Define canonical input/output
  contracts (§5); implement validated typed config (types, allowed values,
  defaults, required, fail-fast); write immutable run manifests (§11). No
  algorithm logic changes.
- **2 — Reference-data registry** (§15) — one loader + one validation contract,
  migrated incrementally (one low-risk list first, verify parity, then the rest).
- **3 — Stage extraction (no redesign).** Split current SQL into
  `core/{map,lot1,sct,lot2_5,maintenance}`, each with an `inputs/parameters/
  outputs/QC` contract. Keep `legacy|refactored|compare` modes (§14);
  patient-for-patient equivalent (Level-3 gate).
- **4 — Optum normalization implementation.** Build the canonical Optum views
  implementing the Increment-1 contract; Optum-specific fields stay reachable via
  an extension area, not forced into a lowest-common-denominator minimum.
- **5 — Studies first-class** (§16) — `studies/<id>/` holds only what varies;
  adding a study selects gates or adds a new *tested* gate, never edits core.
- **6 — Package only at a real second consumer.**

## 19. Repository shape (end-state)
```
R/
  core/      { map/ lot1/ lot2_5/ sct/ }    # source-system-agnostic, Spark-native
  cohort/    { gates/ }                      # explicit tested gate modules
  adapters/  { optum/ }                      # Optum canonicalization only (for now)
  config/                                    # one layered, validated config
  reference_data/                            # registry loader + validation
  orchestration/                             # run_pipeline + thin run_all wrapper
  reporting/                                 # dashboards (current 04-07 logic)
studies/        { ndmm_2025/ }               # per-study config, no core edits
reference_data/ { intake/ validated/ approved/ manifest.yml }
tests/          { unit/ fixtures/ databricks_integration/ regression/ }  # NEVER shipped to prod
scripts/        { validate_config.R validate_reference_data.R
                  compare_run_outputs.R promote_reference_data.R }
```

## 20. Acceptance criteria (refactor "done")
- Frozen synthetic patients produce identical MAP and LOT results (current-behavior).
- The production comparison shows no unexplained patient-level changes.
- Old and new paths can run side by side during migration (`compare` mode).
- A study can change dates/thresholds/enabled gates without editing core code.
- A derived study (e.g. NDMM from Overall) is expressed as an explicit, versioned
  gate delta — gates added / parameter-changed / logic-changed (new version) /
  removed are auditable from the manifest, not a copied-and-edited pipeline.
- A reference-data update requires no algorithm edit; releases are immutable once approved.
- Output schemas are versioned and backward-compatible or explicitly migrated.
- No unapproved degraded gate is allowed.
- Every output traces to code, study, source-data, and reference-data versions.
- Every synthetic fixture maps to a spec rule and a reviewer.
- Invalid config / malformed inputs fail before expensive claims scans start.
- Core-stage runtime stays within approved performance tolerance.
- Frozen production data is stored outside Git with governed access.
- **No synthetic data or harness ships to / runs in production.**
- Current `run_all.R` behaviour stays available via a thin compatibility wrapper.
- A completed run manifest is sufficient to reproduce the run's inputs & settings.
- Rollback to the prior algorithm version is documented and tested.
- A second study can be added without copying the pipeline.

## 21. Out of scope for the first release
- Generalized multi-database adapter framework (revisit at a real 2nd DB).
- Installable R package / multi-repo release (revisit at a real 2nd consumer).
- Generic cohort-rule DSL (use explicit tested gates).
- Portability to non-Spark engines (Snowflake/BigQuery/DuckDB/standard SQL).
- Any algorithm redesign or opportunistic cleanup during extraction.
