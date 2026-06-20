# LOT algorithm — behavior-preserving refactor roadmap (v3)

Status: **design/roadmap only.** No algorithm code is moved or changed by this
document. Implementation starts only after baseline governance + the synthetic
harness exist (Increments 0A/0B), and on a dedicated refactor branch that
carries baseline comparisons.

v3 closes the four items the review made mandatory before implementation:
(1) model the pipeline as a gate/stage dependency DAG (§10); (2) run-scoped
outputs with atomic publication (§12); (3) the canonical shim *before* core
extraction (§20, Increment 1B); (4) a non-production Databricks test +
baseline-governance model (§3, §6, §8). Plus the supporting refinements.

## 1. Goal & scope

Reuse the LOT (line-of-therapy) algorithm across **studies** and over **time**,
and make yearly/monthly **codelist updates** (NDC / HCPCS / CPT / dx) and other
reference-data changes easy and *safe*. Today the algorithm logic, the Optum
bindings, the study/cohort definition, and the codelists are interleaved, and
codelists have no versioning, provenance, or release-blocking validation.

**Scope guardrails:** Optum-only for now (define the contract, implement only
Optum); no generic cohort-rule DSL (a *closed* base+delta schema, §17); no
package/multi-repo until a real second consumer; **behaviour-preserving** — the
refactor must reproduce current patient-level outputs, no opportunistic redesign
during extraction.

## 2. Naming: source-system-agnostic, Spark-native core

The target is **not** "DB-agnostic." The core stops depending on Optum physical
table/column names (reads canonical views) but still runs only on Spark/
Databricks. It is **not** portable to Snowflake/BigQuery/DuckDB/standard SQL.
```
R/core/      # source-system-agnostic, Spark-native LOT algorithm
R/adapters/  # source-specific canonicalization, Optum only (for now)
```

## 3. Execution engines & the non-production test target

- **No local Spark/sparklyr** → a local (DuckDB) re-implementation is rejected
  (it would be a second algorithm that can itself be wrong). Databricks is the
  **only authoritative engine** for MAP/LOT/SCT.
- **Local (pure-R)** tests cover config, codelist validation, manifest hashing,
  gate selection/DAG validation, parameter/date helpers, comparison-rule logic.
- **Non-production Databricks test target** (required): a non-prod workspace or,
  if only one workspace exists, a strongly isolated **test catalog/schema** +
  cluster policy + a **dedicated service principal**, with **no access to
  production outputs**, an **isolated schema per run**, and **automatic
  cleanup/TTL**. "Never in production" means *never mixed with production data or
  outputs* — not that synthetic integration cannot run on Databricks at all.

## 4. Principles

1. **Safety net first** — baseline governance + synthetic golden tests before any
   algorithm code moves.
2. **Two tracks, never mixed** — production stabilization vs. refactor (the latter
   carries baseline comparisons), so a moved count is always attributable.
3. **Config/data over code.** 4. **Seven version axes** (§13), each independently
   recorded. 5. **Explicit phased gates, not a DSL** (§10, §17). 6. **Fail-closed
   for cohort-defining gates** (§11). 7. **Synthetic data is test-only** (§6).
8. **Atomic publication** — dashboards read only promoted outputs (§12).
9. **Package later.**

## 5. Canonical contracts (defined in 1A, before extraction)

Separate event entities (not one entity with a `claim_type` discriminator):
```
canonical_medical    canonical_pharmacy    canonical_diagnosis
canonical_procedure  canonical_enrollment  canonical_death
```
Each event entity keeps **raw and normalized values together** for auditability,
e.g.:
```
patient_id, event_date, raw_code, normalized_code, code_system,
source_table, source_record_id, claim_status, reversal_status,
days_supply, place_of_service, data_vintage
```
Each contract documents: primary key / expected uniqueness; duplicate
resolution; leading-zero (NDC) preservation; rejected-record behaviour; null-date
behaviour; reversal handling; effective-dated reference-data joins; source
lineage. The adapter emits a **validation report before core stages run**
(schema conformance, uniqueness, null rates, invalid dates, domain values, code
normalization collisions). Output contracts (`MAP_STACKED`, `LOT1_BASE`,
`LOT_LONG`) pin keys, columns, types, and the intentionally-nondeterministic
fields (§14). The contract is versioned (a §13 axis).

## 6. Synthetic data is test-only — never in production (hard requirement)

Non-negotiable: synthetic fixtures + the harness exist **only** to verify
behaviour and must be kept entirely away from production.
- **Where it runs:** only the non-prod Databricks target (§3). Never production
  schemas, the production bundle, or any stakeholder run.
- **Isolation, not in-band markers:** prefer a **dedicated synthetic catalog/
  schema** + a **reserved, non-colliding PATID range** + **test-run metadata
  outside the clinical columns**. A `SYNTHETIC` marker is *not* required by the
  core canonical contract.
- **Allowlist deploy (not just "exclude tests/"):** the production artifact is
  built from an **include list** — `R/`, `studies/`,
  `reference_data/approved/`, runtime scripts — and the **packaged file manifest
  is verified before release**.
- **Release gate:** a verify-no-synthetic / purge check **blocks** any release
  where a synthetic row, fixture path, or test-only artifact would ship or
  persist in production; test schemas are dropped after the run.

## 7. Two expected-output types — different provenance

- **Regression-expected (current behaviour)** — **generated and frozen from the
  approved legacy code at the baseline Git SHA**, never hand-recreated (hand
  recreation encodes what reviewers *believe* the code does). The merge gate.
- **Spec-expected (clinical)** — hand-derived from the specification and
  **dual-reviewed**. Flags *future* fixes where current ≠ spec; not a refactor
  blocker.

They live in separate files and are never mixed. Each expected artifact records:
`expected_type`, `source_git_sha` or `spec_section`, `created_by`, `reviewed_by`,
`approval_date`, `change_reason`.

## 8. Frozen production baseline — PHI governance

Patient-level `MAP_STACKED`/`LOT1_BASE`/`LOT_LONG`, **exact checksums, and
sensitive small counts are PHI-derived and stay in the governed location**
(access-controlled Databricks schema / governed object store) — a deterministic
cohort checksum can support membership confirmation, so it is not in Git. Git
holds only: baseline id; governed-location pointer; non-sensitive schema
contract; comparison code; approval metadata. The **governed** manifest holds
exact counts, table hashes, and patient-level comparison results.

Because Delta time-travel may expire, a release baseline requires either a
**retained immutable snapshot/clone** or a **documented retention guarantee**
covering the audit period (plus Delta version/timestamp, source ids, schema
hash, extraction timestamp, cohort snapshot id, owner).

## 9. Synthetic golden-test harness — design

Must be **rich enough to be trusted**: intentionally weird patients.

**Fixture catalog (spec-traceable, dual-reviewed):**
`case_id, spec_section, rule_name, input_files, expected_outputs, expected_qc,
clinical_reviewer, engineering_reviewer, status`. Each expected output is derived
by one person, independently reviewed, tied to a spec section, approved before it
is a merge gate, changed only via review.

**Patient catalog (must exist):** MAP — simple runout; pharmacy pushout;
reset-without-pushout (spec p.5); medical runout (never pushed); imputed
day-supply; MAP boundary; 90-day discontinuation at/just-under/just-over;
**same-date conflicting days-supply**; **duplicates differing only in
source_record_id**; **overlapping pharmacy+medical for the same drug**. LOT1 —
single regimen; induction-window edge (in/out); steroid excluded but attached;
permissible substitute; seeded tie-break; **multiple same-day agents changing LOT
ordering**. SCT — AUTO single/tandem(180d)/beyond-gap; 14-day windowing; 60-day
merge; ALLO ends LOT; CART ends LOT + 45-day consolidation; tandem-boundary date.
LOT2-5 — progression; new induction triggers next LOT; `MAX_LOT`; `ALLO_LOT_SPAN`.
Censoring — death cap; `CENSOR_AT_DISENROLLMENT`; enrollment gap in/out. Dates/
refdata — **10→11 NDC normalization collision**; **effective-dated code changing
classification over time**; **study-start/end boundary**; **leap-day/month-end**;
**backdated record after a prior run**; **null/malformed date rejected
pre-execution**. Degenerate — only-steroid; no-qualifying-meds; dedup.
**Cohort gates / derivation:** a patient passing the base but failing an *added*
gate; flipped by a *parameter change* (6 vs 12-month baseline CE); flipped by a
*tightened* gate (≥1-day vs strict 3-month follow-up CE).

**Coverage matrix:** every important spec rule has ≥1 positive and ≥1 negative
fixture; gaps block "harness ready."

## 10. Gate/stage execution DAG (mandatory)

Cohort gates do **not** all run at one point. NDMM is two-stage:
`base cohort → base LOT derivation → LOT1 anchor → post-LOT1 study gates →
study-specific filtered LOT_LONG`. So each gate declares a **phase** and
**dependencies**:
```yaml
gate: no_prior_mm_tx@1
phase: post_lot1        # pre_lot | post_lot1 | post_lot_long | study_period
depends_on: [lot1_start]
anchor: lot1_start
lookback: { months: 12 }
```
- `pre_lot`: qualifying MM, age, baseline enrollment, dx-derived prior therapy.
- `post_lot1`: 12-mo CE before LOT1, strict 3-mo CE after LOT1, prior-MM-tx
  before LOT1, other-cancer before LOT1.
- `study_period`: pregnancy, belantamab in any LOT.

The orchestrator builds the dependency graph and **rejects impossible or cyclic
gate configurations**. This keeps base+delta YAML honest about the two-stage
construction NDMM already requires.

## 11. Failure policy — cohort gates fail-closed

| Class | Behaviour |
|------|-----------|
| Blocking error (malformed codelist, missing required column, invalid date range) | abort before claims scans |
| Blocking regression (patient-level mismatch vs current-behavior) | fail the build/merge |
| **Cohort-defining gate source unavailable** | **block publication (fail-closed)** |
| Reporting-only analysis unavailable | render an unavailable warning (no false zeros) |
| Approved sensitivity run | allow degraded output, clearly labeled **non-primary** |
| Warning / informational | proceed, record in manifest |

A missing source for pregnancy / prior-tx / other-cancer must **not** silently
broaden the production cohort. Any approved pass-all mode sets machine-readable
manifest+output fields, e.g. `cohort_valid_for_primary_use = false`,
`degraded_gates = ["no_pregnancy"]`; the publish step **blocks primary aliases
and stakeholder dashboards** when that flag is false.

## 12. Run isolation & atomic publication (mandatory)

Legacy and refactored paths **never** share temp views or fixed table names.
Each run writes to a run-scoped namespace:
```
<work_schema>.__runs/<run_id>/legacy/
<work_schema>.__runs/<run_id>/refactored/
```
After all comparisons + release checks pass, publish via an **atomic pointer/
view swap**: `LOT_LONG_CURRENT → validated run output`. A failed run **never**
overwrites the last validated production output. **Dashboards read only promoted
outputs**, never mutable staging names. This also gives concurrent-run safety,
clean rollback, retention/cleanup, and reproducible comparison.

## 13. Run manifest (secret-safe, immutable)

**Never record secrets** (passwords, tokens, credential-bearing DSNs, secret
contents). For each secret record only: reference/name, version if available,
whether resolution succeeded. "Full resolved config" is secret-redacted.

Records: Git SHA + dirty flag; **seven version axes** (below); full resolved
(redacted) config + hash + precedence sources; source DB + **exact Delta table
versions** + vintage + **snapshot retention date**; reference-data hashes +
approval status; Databricks Runtime + Spark version + warehouse/cluster +
Photon + Spark settings; **R version + package versions / renv.lock hash + ODBC
driver version + OS/container image digest + session timezone/locale**;
key-stage counts + stage runtimes; output names + schema hash + checksums;
warnings + degraded gates + `cohort_valid_for_primary_use`; **publication
status**; baseline/comparison run id; **parent run id**; hash algorithm; run
timestamp + runtime. A completed manifest reproduces inputs+settings and is
immutable; **failed/degraded runs also write a manifest** (failing stage,
degraded gates, partial counts).

**Seven version axes** (a monthly NDC/HCPCS change bumps only reference-data; an
Optum normalization fix is attributable separately from a MAP/LOT change):
algorithm · **canonical-contract** · **source-adapter/canonicalization** ·
study-definition · reference-data · source-data vintage · dashboard.

## 14. Comparison authority & nondeterminism

**Full patient-level comparison is authoritative; checksums are an optimization.**
Hierarchy: (1) schema + key-uniqueness; (2) anti-joins for missing/extra rows;
(3) column-level value comparison **after canonical normalization** (sort keys,
one null representation, tz handling, numeric coercion, float tolerance, arrays
declared ordered/unordered, duplicate policy, excluded display-only columns);
(4) checksums as early warning + compact audit. Per-partition fingerprints can
change from repartitioning alone, so they are **not** the release authority
unless partitioning is canonicalized; row hashes may narrow the changed
population, but **patient-level Spark comparison is the final gate**.

**Nondeterminism is minimized, not broadly excluded.** Only *display-only*
nondeterminism is excluded. Any field that influences downstream MAP/LOT state
must be deterministic. For same-date ties: record the seed + Spark/runtime
versions; compare unordered sets only where order has no clinical meaning; plan a
later, separately validated deterministic tie-break fix.

## 15. Performance regression (controlled)

Wall-clock alone is noisy. Use a controlled protocol: same warehouse/cluster
policy, same data snapshot, same Photon, documented warm/cold-cache policy,
multiple runs where practical, compare **p50**. Track stabler metrics: bytes
read, shuffle bytes, spill, task skew, source-scan count, output rows/files,
DBU/compute cost. A duration threshold (e.g. >30% over baseline needs an approved
explanation) is blocking **only when the environment is comparable**.

## 16. Reference-data registry (three states + governance)

`intake` (editable SME) → `validated` (machine-validated) → `approved`
(immutable, versioned + hashed). Monthly updates **promote a complete immutable
snapshot**, not mutate an approved file.

Promotion requires: schema + code-system validation (**code-system version**,
e.g. HCPCS year / ICD-10-CM release); **documented NDC 10→11 normalization rule**
+ collision checks; duplicate policy; effective-date + **overlapping-effective-
date** validation; explicit include/exclude semantics; **token-level coverage**
expectations; row-count bounds at the **codelist/version** level; clinical +
engineering approval. Also: **immutable full snapshot per release**; a
**human-readable diff** from the prior approved version; **affected-patient /
affected-claim impact estimates**; an **emergency withdrawal/rollback** process;
**lock files pinning version + content hash**. Invalid rows are never silently
dropped; warnings vs. release-blocking errors are distinct.

## 17. Study definitions — closed base+delta schema

Studies derive via `base` + a **closed-schema** delta (`add` / `override` /
`disable`) — *not* a generic DSL. The Overall→NDMM example (added pregnancy /
other-cancer / belantamab / prior-tx; tightened follow-up CE ≥1-day→strict
3-month and baseline CE 6→12mo) is **spec-backed config requiring clinical-owner
sign-off**, not a permanent roadmap assumption.

Four change-types: new gate · parameter change · logic change (= a **new gate
version**) · removal/relaxation. Validation rules: one base only; no inheritance
cycles; `override` references only inherited gates; `add` may not duplicate
inherited gates; a gate cannot be both disabled and overridden; gate
dependencies (§10) satisfied; parameters conform to the module schema. **Pin the
base by version + hash** (never resolve a mutable base dynamically); the **fully
resolved gate set is emitted as a standalone artifact** and frozen in the
manifest. Each gate declares: input contract, phase, depends_on, index/anchor,
lookback/follow-up, output flag, failure behaviour, codelist, QC count, tests.

## 18. CI/CD & governance

Branch protection + required status checks (unit + the comparison gates).
**CODEOWNERS** for `core/`, `cohort/gates/`, `reference_data/`. **Clinical
approval** required for gate / reference-data changes; **engineering approval**
for core / adapter changes. A Databricks integration-test **service principal** +
test-schema cleanup. Artifact promotion + release tags + a documented rollback
procedure. Reference-data and gate-change PRs **generate an impact report**
(affected patients/claims, diff) *as part of the PR*, not only after deployment.

## 19. Test strategy (three levels)

1. **Unit (local, pure R)** — helpers, config/codelist/DAG validation, manifest
   hashing, comparison rules. CI on every change.
2. **Synthetic integration (non-prod Databricks)** — real Spark pipeline over §9
   fixtures vs current-behavior expected. Per increment.
3. **Golden production regression (governed Databricks)** — frozen real cohort,
   patient-by-patient (§8, §14). Before any extraction merges.

## 20. Increment roadmap (revised sequence)

**First deliverable, before any algorithm file moves:** baseline inventory,
canonical contract draft, synthetic fixture catalog, comparison/checksum script
design, the Optum compatibility canonical views (1B).

- **0A — Baseline governance.** Freeze SHA; snapshot source + outputs (governed);
  define canonical comparison rules (§14); identify nondeterminism; define PHI
  storage + retention (§8).
- **0B — Synthetic harness.** Reviewed fixtures (§9); non-prod Databricks
  execution; regression vs spec expectations kept separate (§7).
- **1A — Contracts, typed config, manifest, run isolation.** Input/output
  contracts (§5); validated typed config (fail-fast); secret-redacted immutable
  manifest (§13); run-scoped namespaces + atomic publication + rollback (§12).
- **1B — Optum compatibility canonicalization (before extraction).** Canonical
  views over current Optum tables (§5) + parity checks vs current source reads.
  No generalized adapter framework.
- **2 — Reference-data registry** (§16) — immutable releases, promotion gates,
  impact reports; migrate one low-risk list first, verify parity, then the rest.
- **3 — Behaviour-preserving core + gate extraction.** Modules read **only
  canonical views**; `legacy|refactored|compare`; separate run namespaces; no
  redesign. Merge gate: **no core SQL references an Optum physical name** (§22).
- **4 — First-class study definitions** (§17) — base+delta, gate phases/
  dependencies (§10), resolved-study artifact.
- **5 — Operational hardening + performance** — controlled baselines (§15),
  publication/cleanup, dashboards read promoted outputs only.
- **6 — Package only at a real second consumer.**

## 21. Repository shape (end-state)
```
R/
  core/      { map/ lot1/ lot2_5/ sct/ maintenance/ }  # source-system-agnostic, Spark-native
  cohort/    { gates/ }                                # explicit phased, tested gates
  adapters/  { optum/ }                                # Optum canonicalization only
  config/                                              # one layered, validated config
  refdata/                                             # registry loader + validation CODE
  orchestration/                                       # run_pipeline + thin run_all wrapper
  reporting/                                           # dashboards (current 04-07 logic)
contracts/      { inputs/ outputs/ study.schema.json manifest.schema.json }
studies/        { ndmm_2025/ }                         # per-study config, no core edits
reference_data/ { intake/ validated/ approved/ manifest.yml }   # versioned DATA assets
tests/          { unit/ fixtures/ databricks_integration/ regression/ }  # NEVER shipped/run in prod
scripts/        { validate_config.R validate_reference_data.R
                  compare_run_outputs.R promote_reference_data.R verify_no_synthetic.R }
```
(`R/refdata/` = code; top-level `reference_data/` = data assets; `core/` includes
`maintenance/`; `orchestration/` + `reporting/` live under `R/`.)

## 22. Acceptance criteria (refactor "done")
- Frozen synthetic patients produce identical MAP and LOT results (current-behavior).
- The governed production comparison shows no unexplained patient-level changes.
- Old and new paths run side by side (`compare`) in **separate run namespaces**;
  publication is atomic; a failed run never overwrites validated output.
- **No core SQL references a source-physical (Optum) table/column name** — core
  reads only canonical views.
- Gate configurations form a valid DAG; impossible/cyclic configs are rejected.
- A study changes dates/thresholds/enabled gates without editing core; a derived
  study is an explicit, versioned, **DAG-valid** gate delta, auditable from the
  resolved-study artifact + manifest.
- Cohort-defining degraded modes are fail-closed; no unapproved pass-all gate
  reaches a primary output; degraded runs are labeled non-primary.
- A reference-data update needs no algorithm edit; releases are immutable
  snapshots with version+hash locks and a diff/impact report.
- Every output traces to all seven version axes; the manifest is secret-redacted,
  immutable, and sufficient to reproduce inputs+settings (failed runs included).
- Patient-level checksums/small counts stay governed; Git holds only
  pointers/schema/code/approval metadata.
- Core-stage performance stays within tolerance under a comparable-environment
  protocol.
- **No synthetic data or harness ships to / runs in production**; the prod
  artifact is built from an allowlist and its file manifest is verified.
- Current `run_all.R` behaviour stays available via a thin compatibility wrapper.
- Rollback to the prior algorithm version is documented and tested.

## 23. Out of scope for the first release
Generalized multi-database adapter framework; installable package / multi-repo
release; generic cohort-rule DSL; non-Spark portability; any algorithm redesign
or opportunistic cleanup during extraction.
