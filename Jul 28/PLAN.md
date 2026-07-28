# Cohort build codes: Overall + NDMM, one flag-driven PLD

**Date:** 2026-07-28
**Status:** proposal + working selection layer (Phase 1 code in this folder, tested offline)

---

## 1. Verdict

**Yes — do it, and the codebase is already most of the way there.** Both cohorts are
*already* computed as flag tables internally. The only thing that makes NDMM
dependent on Overall is that the flags get **filtered away one step too early,
twice**. Stop filtering, keep the flags as columns, and the dependency
disappears on its own.

One correction to the framing, though. You asked for **two cohort build codes**.
I'd push back gently on *two codebases* and give you **two entry points over one
engine**:

```
Rscript "Jul 28/build_cohort.R" --cohort=overall
Rscript "Jul 28/build_cohort.R" --cohort=ndmm      # complete run, no Overall needed
Rscript "Jul 28/build_cohort.R" --cohort=both      # both + the shared PLD
```

You get exactly what you asked for from the user's side — one command per
cohort, either runnable standalone. What you *don't* get is the duplication.
Two literal scripts would re-fork the problem you already have once: NDMM today
re-implements CE, prior-therapy and other-cancer from raw claims because it is
re-anchored to LOT1, and those re-derivations have already drifted from the
Overall versions. A second full copy makes that permanent.

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

`R/cohort_specs.R` declares `overall` and `ndmm` as peers. Neither references
the other. The NDMM spec is:

```
  the ten index-anchored gates
  + lot1_from + ce_pre_lot1_12mo + ce_fu_lot1_3mo
  + no_belantamab + no_prior_mm_tx + no_other_cancer_pre_lot1 + no_pregnancy_study
```

which is exactly what `06_ndmm_dashboard.R`'s own header documents.

**Decoupling is not redefining.** The two index-gate lists are *currently
identical* — that is a fact about the study definition, not a code dependency.
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
  (`06_ndmm_dashboard.R:745`).
- Because both specs' index gates are currently identical, `coh_index_union` is
  **the same row set as today's `ELIG_COH_FINAL`** — so the LOT build's input is
  unchanged and there is **no cost increase**. (Cost grows only in proportion to
  any future divergence between the two index-gate sets.)

Acceptance for the cutover: `coh_overall_cohort` count == today's
`ELIG_COH_FINAL` count, and `coh_ndmm_cohort` count == today's `_ndmm_patids`
count. Same numbers or it doesn't ship.

---

## 6. Two upstream changes this assumes

Neither is in this folder — both touch existing pipeline code and should be a
separate, reviewed change. Both are small.

**(a) Lift the LOT1-anchored flag build out of the dashboard.**
`build_ndmm_flags()` (`06_ndmm_dashboard.R:622`) moves to its own script, and
its `FROM ELIG_COH_FINAL` becomes `FROM coh_index_union`. It must also **carry
`INDEX_DATE` alongside `PATID`** — today it's PATID-keyed only, because
`ELIG_COH_FINAL` is already one row per patient. Rename the output
`LOT1_FLAGS_ALL`: nothing about those flags is NDMM-specific, and the name is
part of why they were never reused.

**(b) Point the LOT build at the union view.**
`02_lot1.R` / `03_lot2_5.R` read `ELIG_COH_FINAL` via `FINAL_TABLE_NAME`. Repoint
that to `coh_index_union` and emit `LOT1_STARTS` keyed by
`(PATID, INDEX_DATE)`. Since the union is currently the same row set, this is
behaviour-preserving.

**(c) Minor, already known:** `NDMM_PRE_LOT1_DAYS` is hard-coded `365L` at
`06_ndmm_dashboard.R:89`. `cohort_explorer/ANALYTIC_COHORT.md` already flags this
as a one-line `Sys.getenv()` lift.

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
inheritance — that was never an NDMM decision.

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
- **Not yet run against the warehouse.** Everything here is tested offline as
  config → SQL text (49 assertions). The SQL has not executed against Databricks;
  the row-count acceptance in §5 is the gate for that.

---

## 9. Suggested sequence

| Phase | Work | Risk |
|---|---|---|
| 1 | This folder: spec + selection layer, `--dry-run` reviewed | none (no writes) |
| 2 | Upstream changes (a) + (b); run `--cohort=both`; assert §5 row counts | low — equivalence-tested |
| 3 | Persist `COHORT_PLD`; repoint `07_combined_dashboard.R` at it | low |
| 4 | Strip cohort logic from `06_ndmm_dashboard.R`; it becomes a reader | medium — biggest diff |
| 5 | Point `cohort_explorer` at `COHORT_PLD`; retire the duplicate projection | low |
| 6 | Reconcile `jun_21_2026/studies/*.yml` with the registry (drop `base:`) | none |

Phases 1–3 are where the benefit lands: NDMM standalone, one PLD, one attrition
report. 4–6 are cleanup and can wait.

---

## 10. What's in this folder

| File | |
|---|---|
| `R/cohort_specs.R` | Gate registry (17 gates, anchor + tunability) and the two cohort specs |
| `R/cohort_sql.R` | Spec → Spark SQL: index selection, union, membership, PLD, attrition |
| `build_cohort.R` | Entry point: `--cohort=overall\|ndmm\|both`, `--dry-run` |
| `tests/test_cohort_specs.R` | 49 offline assertions — no warehouse needed |

```
Rscript "Jul 28/tests/test_cohort_specs.R"                    # 49 passed, 0 failed
Rscript "Jul 28/build_cohort.R" --cohort=ndmm --dry-run       # print the SQL
```

Config-as-R rather than YAML, matching `cohort_explorer`'s reasoning: the
production R environment has no `yaml` dependency and drives everything from env
vars + `pipeline_inputs.csv`. Gate ids are 1:1 with
`jun_21_2026/cohort/gates/registry.yml` so the two can be diffed mechanically.

Nothing in this folder modifies existing pipeline code, and nothing writes to
the warehouse without `COHORT_CONNECT_FN` explicitly configured.
