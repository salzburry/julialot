# Cohort build codes: Overall + NDMM, one flag-driven PLD

**Date:** 2026-07-28
**Status:** Phases 1–2 implemented and tested offline; not yet run against the warehouse

---

## 1. Verdict

**Yes — do it, and the codebase is already most of the way there.** Both cohorts are
*already* computed as flag tables internally. The only thing that makes NDMM
dependent on Overall is that the flags get **filtered away one step too early,
twice**. Stop filtering, keep the flags as columns, and the dependency
disappears on its own.

**Two separate cohort files, two separate build scripts:**

```
cohorts/overall.R    the Overall definition, complete and self-contained
cohorts/ndmm.R       the NDMM definition, complete and self-contained

Rscript "Jul 28/build_overall.R"     # Overall only
Rscript "Jul 28/build_ndmm.R"        # NDMM only -- no Overall run, ever
Rscript "Jul 28/build_cohort.R"      # both + the shared PLD
```

Neither cohort file references the other, neither inherits from the other, and
each **spells out its own gate list in full** — there is no shared constant, so
editing one cannot change the other. Adding a third cohort is adding a file.

What is *not* duplicated is the derivation logic: both files name criteria from
one gate registry that holds the SQL. That split is what keeps NDMM's CE /
prior-therapy / other-cancer definitions from drifting further than they already
have. The definitions are separate; the machinery is shared.

The cost of separate files is real and worth naming: two gate lists that are
*meant* to agree must be kept in step by review. So the build prints an
index-gate diff on every multi-cohort run and the tests assert the current
agreement — drift is **detected**, not prevented. Diverging is a legitimate
study decision; diverging silently is not.

---

## 2. What is actually in the way today

Three facts from the current code:

**`ELIG_COH_ALLFLAGS` already carries every Overall criterion as a column.**
`apr_30_2026/R/pipeline_steps.R:963` (step 23) assembles `CE_b`, `CE_f`,
`CE_3mosf`, `MM_bl_agents`, `MM_FU_agents`, `MM_baseline_diag`,
`OTHER_MALIGN_FLAG`, `PREGNANT_FLAG`, `CLINTRIAL_BASELINE/FOLLOWUP`. Step 24
(`:1049`) then discards all of them with a `WHERE` funnel into
`ELIG_COH_FINAL`.

**`NDMM_FLAGS_ALL` already carries every NDMM criterion as a column.**
`apr_30_2026/06_ndmm_dashboard.R:646` builds `CE_pre_lot1_12mo`,
`CE_lot1_3mo_fu`, `NO_BELANTAMAB`, `NO_PRIOR_MM_TX`,
`NO_OTHER_CANCER_PRE_LOT1`, `NO_PREGNANCY` — then collapses them at `:745` with
`WHERE ... = 1` into `_ndmm_patids`.

**NDMM reads `ELIG_COH_FINAL` and lives inside a dashboard script.** That single
`FROM` at `:658` is the coupling. It is why you cannot get NDMM without running
Overall, and why the NDMM cohort definition is buried in a 1,400-line
dashboard.

So the flags exist. They are just consumed one step too early, in two different
places, by code that isn't shaped like a cohort builder.

Worth noting: the idea is already half-written down elsewhere in the repo.
`cohort_explorer/R/criteria_registry.R` says it outright — *"Overall and NDMM
are just different default flag sets"* — and `jun_21_2026/studies/*.yml`
drafted the spec files. But `jun_21_2026/studies/ndmm.yml` declares
`base: overall_2025`, which re-encodes the very dependency you want removed.
That's the one design decision I'd change.

---

## 3. The design

Four stages. Only stage 4 is cohort-specific, and it's cheap.

```
  [1] flag build (cohort-agnostic, expensive, runs ONCE)
      raw claims ──► ELIG_COH_ALLFLAGS        (index-anchored flags)   EXISTS TODAY
                                │
  [2] per-cohort index selection (cheap: window function, no claim re-scan)
      ─► coh_overall_index_sel ─┤
      ─► coh_ndmm_index_sel   ──┤
                                ▼
                     coh_index_union   (distinct PATID × INDEX_DATE)
                                │
  [3] LOT build + LOT1-anchored flag build (cohort-agnostic, expensive, ONCE)
      ─► LOT1_STARTS, LOT_LONG, LOT1_FLAGS_ALL
                                │
  [4] membership = AND(flags)   (cheap)
      ─► coh_overall_cohort, coh_ndmm_cohort
                                ▼
                          COHORT_PLD
              every criterion a column + COHORT_OVERALL / COHORT_NDMM
```

**The PLD is the payoff.** One table, both cohorts, nothing dropped:

```sql
SELECT * FROM COHORT_PLD WHERE COHORT_NDMM = 1;
SELECT * FROM COHORT_PLD WHERE COHORT_OVERALL = 1;
-- and, because the flags survive as columns, ad-hoc variants cost nothing:
SELECT * FROM COHORT_PLD WHERE COHORT_NDMM = 1 AND NO_BELANTAMAB = 0;  -- sensitivity
```

Every downstream consumer — `04_lot_detail_dashboard.R`,
`05_regimen_dashboard.R`, `06_ndmm_dashboard.R`, `07_combined_dashboard.R`, the
study-team question scripts — takes a `--cohort` argument and a `WHERE` clause
instead of re-deriving a cohort. `06_ndmm_dashboard.R` loses ~600 lines of
cohort logic and becomes a dashboard again.

### The one genuinely subtle bit

Step 24 does **filter-by-IE first, then take the earliest surviving index date**
— deliberately, so a patient whose earliest candidate index fails IE can still
enter on a later one. That means **the selected index date is a function of the
cohort definition.** You cannot rank once and share the result across cohorts
whose index gates differ.

So ranking is done **per cohort** (cheap — a window function over a
materialized flag table), and the LOT build is fed the **union** of the selected
`(PATID, INDEX_DATE)` pairs. When two cohorts pick the same index for a patient,
the union collapses and the LOT build runs once. When they diverge, the union
grows and the numbers stay right. Correct in both cases, cheap in the common one.

### Anchors are first-class, and that fixes a live hazard

A gate is identified by `(criterion, anchor)`, never by name alone. NDMM's
12-month CE is anchored at **LOT1 start**; Overall's 6-month CE is anchored at
**MM diagnosis**. These are *different criteria over different windows*, not one
criterion with a different parameter.

`jun_21_2026/cohort/gates/registry.yml` flagged this exact hazard in its header
comments — and then `ndmm.yml` expressed it anyway as
`override: baseline_ce: {months: 12}`, which is wrong: it would apply a 12-month
window at the **index** anchor. Encoding `anchor` on every gate makes that
mistake unrepresentable. There's a test for it.

### Not everything is a runtime knob, and the code says which

A parameter is only selection-time tunable if it filters a **raw column present
in the flag table**:

| Parameter | Tunable? | Why |
|---|---|---|
| `min_age` | yes | filters `AGE_INDEX_YR` |
| `outpatient_window` | yes | all of `outpt2_30/60/90` are materialized |
| `lot1_from` | yes | filters `LOT1_START_DT` |
| CE window months | **no** | `CE_b` is a pre-baked fixed-6-month flag |

A spec that tries to "override" a non-tunable window is **rejected at
validation**, not silently ignored. A config knob that quietly lies is worse
than no knob.

---

## 4. Two cohorts are siblings, not a chain

`cohorts/overall.R` and `cohorts/ndmm.R` are peers, loaded from disk by
`cohort_specs()`. Neither references the other. The NDMM spec is:

```
  the ten index-anchored gates
  + has_lot1                                          (see §4a)
  + lot1_from + ce_pre_lot1_12mo + ce_fu_lot1_3mo
  + no_belantamab + no_prior_mm_tx + no_other_cancer_pre_lot1 + no_pregnancy_study
```

The seven after `has_lot1` are exactly what `06_ndmm_dashboard.R`'s own header
documents.

### 4a. "A treatment start" is not the same as "a LOT1"

Worth stating explicitly, because the two are easy to conflate and the pipeline
treats them differently:

| | definition | steroids? |
|---|---|---|
| `fu_mm_agents` | any `cl_mma_codelist` claim between index and the death/study cap (`pipeline_steps.R:723`) — **no drug-class filter** | **counted** |
| `has_lot1` | `min(MAP_START_DT) WHERE MAP_MED_CLASS <> 'STEROID'` (`02_lot1.R:678`) | **excluded** |

So a patient whose only follow-up MM agents are steroids **satisfies
`fu_mm_agents` but has no LOT1 row.**

- **Overall** wants that patient. It is defined by "a treatment start exists"
  and never anchors on LOT1, so it takes `fu_mm_agents` and not `has_lot1`.
- **NDMM** cannot use them: every NDMM gate is anchored at `LOT1_START_DT`, so
  with no LOT1 there is nothing to anchor to.

**The existing build handles this correctly.** NDMM applies the restriction with
an `INNER JOIN NDMM_LOT1_STARTS` (`06_ndmm_dashboard.R:658`) — the right
semantic, since a patient with no LOT1 has no anchor for any NDMM criterion —
and it **already reports it**: `ndmm_counts()` computes `elig_lot1` at `:806`,
`build_ndmm_overview_card()` renders it at `:900` as *"+ has LOT1 start ≥
2017-01-01 in LOT_LONG"*, and it is logged at `:1425`. No patient is wrongly
included or excluded, and the drop is not hidden.

The only change here is **granularity**. `NDMM_LOT1_STARTS` bakes the cutoff into
its own definition (`:207`: `WHERE LOT_NUM = 1 AND LOT_START_DT >=
NDMM_LOT1_FROM`), so that single reported row fuses two distinct criteria:

- *no non-steroid regimen at all* → `has_lot1`
- *first regimen predates the cutoff* → `lot1_from`

Declaring them separately gives each its own funnel row. Same patients, same
final count (`LEFT JOIN` + `IS NOT NULL` is identical to `INNER JOIN`) — two
numbers instead of one.

It also puts a question to the study team that is currently implicit in a
codelist class filter rather than in the cohort spec: *is steroid-only follow-up
meant to count as first-line treatment?* Overall says yes, NDMM says no.

**Decoupling is not redefining.** The two index-gate lists are *currently
identical*, written out separately in each file — that is a fact about the study
definition, not a code dependency.
Phase 1 changes no numbers. Any future divergence in NDMM's index gates becomes
a one-line spec edit, reviewed by the study team, with zero effect on Overall.

---

## 5. Equivalence: Phase 1 must be a no-op

This is the property that makes the change safe to ship, and it's tested:

- Overall's generated predicates are **byte-identical, in order**, to
  `build_criteria_catalog()` + step 24's index gate
  (`criteria_attrition.R:38-88`, `pipeline_steps.R:1062`).
- Overall's index selection uses the same
  `row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE)` and `rn = 1`.
- NDMM's LOT1 predicates are identical to the `_ndmm_patids` filter
  (`06_ndmm_dashboard.R:745`), plus `has_lot1`, which restates that script's
  existing `INNER JOIN NDMM_LOT1_STARTS` as a countable predicate — same row
  set. `has_lot1` restates the existing INNER JOIN as a predicate and splits the
  cutoff out of it — same patients, one extra funnel row (§4a).
- Because both specs' index gates are currently identical, `coh_index_union` is
  **the same row set as today's `ELIG_COH_FINAL`** — so the LOT build's input is
  unchanged and there is **no cost increase**. (Cost grows only in proportion to
  any future divergence between the two index-gate sets.)

Acceptance for the cutover: `coh_overall_cohort` count == today's
`ELIG_COH_FINAL` count, and `coh_ndmm_cohort` count == today's `_ndmm_patids`
count. Same numbers or it doesn't ship.

---

## 6. The two upstream changes — DONE

Both are now made. One turned out to need no pipeline code change at all.

### (a) The LOT1 flag build is out of the dashboard

`build_ndmm_flags()` and its seven supporting builders moved from
`06_ndmm_dashboard.R` into **`apr_30_2026/R/lot1_flags.R`**, a pipeline stage
shared by two consumers: the dashboard (unchanged behaviour) and the new
standalone `build_lot1_flags.R`. The dashboard lost ~640 lines and keeps
back-compat aliases, so the ~20 downstream references to `NDMM_*` names still
resolve.

Renamed `NDMM_*` → `LOT1_*`: nothing about "12-month CE before 1L start" or "no
belantamab in any line" is NDMM-specific. They are IE criteria anchored at
`LOT1_START_DT`, and the misnomer is a good part of why they were never reused.
The persisted table is now `LOT1_FLAGS_ALL`.

Two deliberate generalizations; everything else is character-for-character the
same SQL (verified by normalized diff against the pre-change file):

1. **The patient input is a parameter.** `FROM ELIG_COH_FINAL` became
   `FROM {patient_input}`. Pass `coh_index_union` and the flags build with no
   Overall cohort ever selected. Default is unchanged.
2. **Views are keyed by `(PATID, INDEX_DATE)`.** The original could key on
   PATID because `ELIG_COH_FINAL` is already one row per patient. A union over
   cohorts that pick *different* index dates for the same patient would be
   silently conflated by a PATID-only key. The index-DEPENDENT scans (the two
   pre-LOT1 windows) now carry the pair; the index-INDEPENDENT ones
   (belantamab = any line, pregnancy = whole study period) stay at PATID grain
   deliberately, since adding INDEX_DATE there would only duplicate rows.

Two fixes fell out of the move:

- **Materialization order.** `LOT1_STARTS` is now materialized *before* the four
  claim scans rather than never — every scan joins it. A repoint only affects
  views created after it, so doing this late would leave the flag view on the
  old plan.
- **Fan-out in the pregnancy scan.** It joined `LOT1_STARTS` directly in four
  places; once that table can hold >1 row per patient, those joins would
  multiply claim rows before the `DISTINCT`. Now joins a `cand` CTE
  (`SELECT DISTINCT PATID`). Same answer, no fan-out.

`NDMM_PRE_LOT1_DAYS` is also no longer hard-coded `365L` — it reads the env var,
the one-line lift `cohort_explorer/ANALYTIC_COHORT.md` flagged. Default unchanged.

### (b) The LOT build needed no code change

PLAN originally assumed `02_lot1.R` had to be edited. It does not:
**`INPUT_COHORT_TABLE` already parameterises the LOT build's input**
(`config_lot.R:33`, default `ELIG_COH_FINAL`).

So the only requirement is that `coh_index_union` be a *drop-in* for
`ELIG_COH_FINAL`. `lot_patient_input` (`02_lot1.R:278`) reads `PATID`,
`INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`, `DEATH_DT`, `GDR_CD`, `YRDOB`,
`AGE_INDEX_YR`, `FU_DAYS`, `FU_DAYS_CE` — **step 23 already emits every one of
them.** The union view now projects the full flag row instead of just the key
pair, and the change is a config setting:

```
INPUT_COHORT_TABLE=coh_index_union
```

`LOT1_STARTS` likewise needs no LOT change: it is derived from `LOT_LONG`
(`LOT_NUM = 1`) joined back to the patient input, inside the flag stage.

### Run order

`--index-only` exists to break the bootstrap: the LOT build consumes the union
view, but the membership views consume flags that only exist after the LOT build
has run.

```
1. cohort pipeline through step 23              -> ELIG_COH_ALLFLAGS
2. build_ndmm.R --index-only                    -> coh_ndmm_index_sel, coh_index_union
3. LOT build, INPUT_COHORT_TABLE=coh_index_union -> LOT_LONG, MAP_STACKED
4. build_lot1_flags.R                           -> LOT1_STARTS, LOT1_FLAGS_ALL
5. build_ndmm.R                                 -> the cohort + PLD
```

Steps 1–3 are shared: run them once and **both** cohorts select from the result.
Overall alone needs only step 1 — it has no LOT1-anchored gates, so
`build_overall.R` never touches the LOT stack.

---

## 7. What this makes visible (questions for the study team)

Decoupling surfaces choices that were invisible while NDMM inherited
`ELIG_COH_FINAL` wholesale. NDMM currently applies **both** anchors for three
criteria, because it inherits the index-anchored one and then re-derives its
own:

| Criterion | index-anchored | LOT1-anchored | Both intended? |
|---|---|---|---|
| Other cancer | `OTHER_MALIGN_FLAG` | `NO_OTHER_CANCER_PRE_LOT1` | ? |
| Pregnancy | `PREGNANT_FLAG` | `NO_PREGNANCY` (study period) | ? |
| Prior MM therapy | `MM_bl_agents` | `NO_PRIOR_MM_TX` | ? |

Also: **should NDMM exclude clinical-trial patients?** It does today, purely by
inheritance — that was never an NDMM decision. And per §4a: **does steroid-only
follow-up count as a first-line treatment start?** Overall says yes, NDMM says
no — a real divergence, though it currently lives in a codelist class filter
rather than in either cohort's stated definition.

I've kept all of them ON, so Phase 1 reproduces current numbers. But these are
now one-line spec edits instead of archaeology, and they're worth putting in
front of the study team. (Related and still open in the code:
`NDMM_MM_ADJACENT_OVERRIDE` at `06_ndmm_dashboard.R:109` is marked pending
confirmation.)

---

## 8. Honest limitations

- **NDMM cannot be a single flat query.** Its gates are anchored at LOT1, and
  LOT1 is derived from an index date. The staging index → LOT → LOT1-gates is
  irreducible. "Standalone" here means *one command, no Overall run, no
  `ELIG_COH_FINAL` dependency* — not *one query*.
- **PLD grain is `(PATID, INDEX_DATE)`**, which is one row per patient today
  because both cohorts select the same index. If the index gate sets ever
  diverge, a patient can hold two rows. Downstream code should join on the pair,
  not assume `PATID` is unique.
- **`cohort_explorer` overlaps this.** Its `ANALYTIC_COHORT` is the same idea
  aimed at the Shiny app, sourced from `NDMM_FLAGS_ALL` and `ELIG_COH_FINAL`. Once
  `COHORT_PLD` exists, `make_analytic_csv.R` should read it instead of
  re-projecting — otherwise there are two flagged supersets to keep in sync.
- **Not yet run against the warehouse.** This is the main caveat on Phase 2: the
  lifted SQL is verified by normalized diff against the original, and the R
  parses, but nothing has executed. Everything here is tested offline as
  config → SQL text (49 assertions). The SQL has not executed against Databricks;
  the row-count acceptance in §5 is the gate for that.

---

## 9. Suggested sequence

| Phase | Work | Risk |
|---|---|---|
| 1 | This folder: spec + selection layer, `--dry-run` reviewed | none (no writes) |
| 2 | ~~Upstream changes (a) + (b)~~ **done**; still to do: run against the warehouse and assert §5 row counts | low — equivalence-tested |
| 3 | Persist `COHORT_PLD`; repoint `07_combined_dashboard.R` at it | low |
| 4 | ~~Strip cohort logic from `06_ndmm_dashboard.R`~~ **done in Phase 2** (−640 lines); still to do: have it read `COHORT_PLD` rather than rebuild | low |
| 5 | Point `cohort_explorer` at `COHORT_PLD`; retire the duplicate projection | low |
| 6 | Reconcile `jun_21_2026/studies/*.yml` with the registry (drop `base:`) | none |

Phases 1–3 are where the benefit lands: NDMM standalone, one PLD, one attrition
report. 4–6 are cleanup and can wait.

---

## 10. What's in this folder

| File | |
|---|---|
| `cohorts/overall.R` | **The Overall cohort definition.** Gate list only, no SQL |
| `cohorts/ndmm.R` | **The NDMM cohort definition.** Gate list only, no SQL |
| `build_overall.R` | Entry point — Overall alone |
| `build_ndmm.R` | Entry point — NDMM alone |
| `build_cohort.R` | Entry point — `--cohort=overall\|ndmm\|both` (default both) |
| `R/cohort_specs.R` | Gate registry (18 gates, anchor + tunability), loader, drift check |
| `R/cohort_sql.R` | Spec → Spark SQL: index selection, union, membership, PLD, attrition |
| `R/cohort_run.R` | Shared engine: config, schema guard, execution, reporting |
| `R/bootstrap.R` | Path resolution + source order for the entry points |
| `build_lot1_flags.R` | The LOT1-anchored flag stage, standalone (§6a) |
| `tests/test_cohort_specs.R` | 75 offline assertions — no warehouse needed |

```
Rscript "Jul 28/tests/test_cohort_specs.R"           # 75 passed, 0 failed
Rscript "Jul 28/build_ndmm.R" --dry-run              # print the SQL, touch nothing
```

A cohort file contains **no SQL** — only a gate list, in funnel order, with the
parameters it overrides. It is meant to be reviewed by the study team without
reading any code.

Config-as-R rather than YAML, matching `cohort_explorer`'s reasoning: the
production R environment has no `yaml` dependency and drives everything from env
vars + `pipeline_inputs.csv`. Gate ids are 1:1 with
`jun_21_2026/cohort/gates/registry.yml` so the two can be diffed mechanically.

Nothing in this folder modifies existing pipeline code, and nothing writes to
the warehouse without `COHORT_CONNECT_FN` explicitly configured.
