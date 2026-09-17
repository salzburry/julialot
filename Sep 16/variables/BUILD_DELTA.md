# What the existing build has to change

The cohort build already produces an NDMM 1L cohort, 2L and 3L cohorts, and a
lines-of-therapy assignment. This file is the difference between what it does today
and what the Aug 26 2026 protocol asks for — nothing else.

Read with `IE_CRITERIA.md` (the rules) and `DATA_MAPPING.md` (the fields).

Legend: **matches** · **change** · **new** · **decide first** (blocked on
`OPEN_QUESTIONS.md`).

"Today" in the tables below means **the upstream cohort build**, which this
delivery does not edit. Where the study package has since implemented one of
these, the row says so — read the row, not the heading, for what exists now.

---

## 0. How a change reaches the build

**Two of these need the cohort build's CONTRACT edited. The rest do not.**

An earlier version of this section said every change was a run-time decision
and that no line of the cohort build had to move. That was wrong, and a run on
production proved it: the settings are read from the environment, but
`check_contract()` (`ndmm/R/build_ndmm.R`) then compares the resolved config
against a pinned `CONTRACT` list and **stops** on any difference, with no
override of any kind — *"a different value here is a different cohort, so they
are checked rather than defaulted."* Editing `config.csv` does not help either;
the check is against `CONTRACT`, not the file.

There is a second guard behind the first. `check_constants()` compares the
constants the SQL actually interpolates — defined in `ndmm/R/ndmm_constants.R`
— against the resolved config, and stops if they disagree. The two are read
from **differently named** environment variables:

```r
NDMM_STUDY_START <- Sys.getenv("STUDY_START",    unset = "2016-01-01")   # plain name
NDMM_LOT1_FROM   <- Sys.getenv("NDMM_LOT1_FROM", unset = "2017-01-01")   # prefixed name
```

So `STUDY_START` reaches the SQL and `LOT1_FROM` does not. Setting `LOT1_FROM`
alone moves the config, leaves the constant at 2017-01-01, and the run halts on
`check_constants()` after `check_contract()` has already passed.

| setting | how it is changed |
|---|---|
| `STUDY_START` | **edit `CONTRACT$study_start`** in `ndmm/R/build_ndmm.R`, and export `STUDY_START` (or set it in `config.csv`) |
| `LOT1_FROM` | **edit `CONTRACT$lot1_from`**, set `LOT1_FROM` for the config, **and export `NDMM_LOT1_FROM`** for the SQL |
| `FU_CE_DAYS` | no change needed — the contract value `0` is what §2 leaves in place, since the one-claim-or-death test now runs in this package |
| `SUBSEQ_FU_CE_DAYS` | environment, but `subseq_check_windows()` refuses it unless `NDMM_SUBSEQ_OVERRIDE=TRUE`, which records the run as a named sensitivity |
| `NDMM_INDEX_EXCLUDED_ABBRS` | environment only, no contract entry — a true run-time decision |

Both guards are right to exist: one stops a cohort being silently redefined
under the study's own table names, the other stops the config and the SQL
drifting apart. The preflight order, all before any connection, is
`check_settings` → `pin_output_schema` → `pin_prefix` → `check_contract` →
`check_choices` → `check_constants`; then the connection, then
`check_no_active_run` and `check_upstream`. Nothing is written until every one
of them passes, so a refused run leaves the prefix exactly as it found it.

`CENSOR_AT_DISENROLLMENT` is the exception: it is not a cohort-build setting at
all, and nothing in that build censors. Follow-up end is computed in
this package, where the setting already exists and defaults to `TRUE`, the
protocol's reading.

### The secondary 2L cohort

Pointing `INPUT_COHORT_TABLE` at the cohort build's `NDMM_FLAGS_ALL` does **not**
supply the wide population §7.4.1.1 asks for. `NDMM_FLAGS_ALL` projects
`ec_l1.PATID` and seven flags, with no `INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`,
`DEATH_DT`, `MM_DX_DT` or demographics: `02_periods.R` indexes every cohort on
`co.INDEX_DATE`, `windows.R` reads `ENDDATE` and `ENDDATE_CE`,
`03_demographics.R` reads `YRDOB` and `GDR_CD`, `08_malignancy.R` reads
`MM_DX_DT`, and the LOT engine's required-input check rejects it as well.
`R/modules/01_cohorts.R` refuses such a table at the first step, by
name, rather than failing five modules later on an unresolved column.

A schema fix alone would not be enough. `01_cohorts.R` computes membership from
continuous enrolment and follow-up and then joins the supplied cohort on
`PATID`; it does not read the eligibility flags in `CRITERION_SOURCE`, because
with an ordinary pre-filtered NDMM input those exclusions were already applied
before it. Against a wide input that assumption fails: a record with
`NO_PREGNANCY = 0` would enter the secondary 2L cohort, and selecting the
primary cohorts in the same run would admit records failing the prior-cancer
exclusion. The protocol keeps those criteria for every cohort except where it
specifically permits otherwise.

So the secondary 2L cohort needs a materialised wide-cohort adapter: the full
cohort schema above, correctly anchored dates, and the eligibility evidence
retained per patient so each cohort can apply its own criteria. The LOT engine
is then run over that adapter. That is a build to write, not a setting to flip,
and `SEC2L_INPUT_IS_WIDE` asserts a property of the input rather than supplying
one.

Somebody still has to *run* the cohort and LOT builds again under those
settings. The lineage guard in `R/lineage.R` refuses a LOT run whose
`STUDY_START`, `STUDY_END`, cohort table or completion state disagree with what
this package is set to, so a stale run cannot be read by accident.

---

## 1. Settings

| setting | today | protocol | verdict |
|---|---|---|---|
| `STUDY_START` | `2016-01-01` | body text says 01 Jan 2018; Figures 1 and 2 say 01 Jan 2016 | **decide first** — Q1 |
| `STUDY_END` | `2026-03-31` | 31 Mar 2026 | **matches** |
| `LOT1_FROM` | `2017-01-01` | 1L initiation **≥ 01 Jan 2019** | **change** |
| `PRE_LOT1_DAYS` | `365` | 12 months | **matches** |
| `SUBSEQ_PRE_DAYS` | `365` | 12 months before the 2L/3L index | **matches** |
| `GAP_DAYS` | `30` | gaps ≤ 30 days are continuous | **matches** |
| `OUTPATIENT_WINDOW` | `90` | 2 outpatient claims within 90 days | **matches** |
| `MIN_AGE` | `18` | ≥ 18 at MM diagnosis, calendar year | **matches** |
| `FU_CE_DAYS` | `0` (index date itself enrolled) | "at least one claim (pharmacy or medical) from index date or death" | **change** — see §2 |
| `SUBSEQ_FU_CE_DAYS` | `90` gap-free enrolment after 2L/3L | the protocol's per-cohort follow-up test is the same one-claim test; the 90-day rule it does state is an **analysis-set** restriction on TTE outcomes | **change** — see §2 |
| `CENSOR_AT_DISENROLLMENT` | `FALSE` | follow-up ends at "end of continuous enrollment or end of study period or death, whichever occurs first" | **change** — see §4 |
| `MAX_LOT` | `5` | 1L-4L needed (no 4L cohort, but a 4L start date and regimen) | **matches** |
| `INDUCTION_WINDOW_DAYS` | `60` | "1L is defined as any pre-specified MM therapies received within 60 days of the 1L start date" | **matches** |
| `INDUCTION_WINDOW_DAYS_LOT_N` | `30` | "Each subsequent LOT includes all MM therapies received within 30 days on and following the LOT start date" | **matches** |
| `NDMM_INDEX_EXCLUDED_ABBRS` | empty | panobinostat and elotuzumab may not set the 1L index | **change** |
| `APPLY_NO_BELANTAMAB` | `TRUE` | "Received belantamab mafodotin in any LOT" excludes | **matches** |

## 2. Follow-up: three different tests, currently conflated

The build has one follow-up concept per cohort. The protocol has three, and they are
not the same thing.

| protocol concept | where | test | build today |
|---|---|---|---|
| **Evidence of follow-up** (eligibility) | §7.2.1.1 | ≥ 1 medical or pharmacy claim from the index date, or death | 1L: enrolled on the index date (`FU_CE_DAYS=0`). 2L/3L: 90 days of gap-free enrolment or death (`SUBSEQ_FU_CE_DAYS=90`) |
| **Follow-up period** (the observation window) | §7.1 | index → min(end of CE, study end, death) | the cohort build's `ENDDATE = least(study_end, DEATH_DT)` does not apply end of CE. **This package does**: `fu_end_sql()` takes the end of the span covering this cohort's own index, under `CENSOR_AT_DISENROLLMENT`, which defaults to the protocol reading |
| **≥ 3 months potential follow-up** (analysis set for TTNT/TTD/OS) | §7.8.2 | `index + 90 ≤ study end`, or death before `index + 90` | **implemented** as `S_PERIODS.TTE_ELIGIBLE`, a flag rather than a filter: the whole cohort stays in `S_TTE` and the restricted analysis is the rows the flag marks |

What to build — **all three are done in this package**, and are listed here
because the upstream cohort build still has none of them:

- ~~replace the 1L `FU_CE_DAYS=0` test and the 2L/3L `SUBSEQ_FU_CE_DAYS=90` test
  with the single **one-claim-or-death** test, applied identically to all
  cohorts~~ — `build_fu_claims()` applies it as criterion `I5_followup`, the
  same test for every cohort;
- ~~add `FU_END = least(cov_end_of_the_index_span, study_end, DEATH_DT)` as a
  column on every cohort table~~ — `fu_end_sql()` writes it on `S_PERIODS`,
  under `CENSOR_AT_DISENROLLMENT`;
- ~~add a `TTE_ELIGIBLE` flag for the ≥ 3-month rule — **a flag, not a filter**,
  or the Objective 1-3 denominators shift~~ — `S_PERIODS.TTE_ELIGIBLE`, and it
  is a flag: `S_TTE` keeps the whole cohort and the restricted analysis is the
  rows the flag marks.

The 90-day number does not disappear; it moves from eligibility to the analysis set,
and it becomes a **potential**-follow-up test (calendar time in the database) rather
than an **observed**-enrolment test. On a rough reading that makes the 2L and 3L
cohorts larger than they are today.

## 3. Criteria

| criterion | today | protocol | verdict |
|---|---|---|---|
| MM diagnosis (I1) | one code list for both arms, plus a strict `203.0x`/`C90.0x` requirement on the inpatient arm; 90-day outpatient pairing | strict on the inpatient arm; outpatient arm says only "medical claims for MM" | **decide first** — Q2 |
| Age (I2) | `year(MM_DX_DT) - YRDOB >= 18`, applied to the **earliest** qualifying date | ≥ 18 at MM diagnosis by calendar year | **matches** |
| Eligible 1L treatment (I3) | first non-steroid MM agent on/after diagnosis and on/after `LOT1_FROM`, belantamab barred | same, plus panobinostat and elotuzumab barred, and `LOT1_FROM = 2019-01-01` | **change** |
| 12-month CE (I4) | own spans from `member_enrollment`, gaps ≤ 30 d | same, plus "with medical and pharmacy benefits" | **matches** — the extract does not separate the benefits, so the requirement is satisfied by construction (`OPEN_QUESTIONS.md` Q4) |
| Follow-up (I5) | see §2 | see §2 | **change** |
| Prior MM therapy (X1) | any MM agent in the 365-day baseline, **steroids dropped** — but the drop **removes nothing** on the production code list | "≥ 1 medical or pharmacy claim for any MM oncology therapy" | **matches today**; becomes a decision when Annex 2's list arrives — Q6 |
| Other cancer (X2) | ≥ 1 inpatient, or ≥ 2 outpatient on distinct days **within 30 days**, paired on the 3-character ICD category, both claims inside the baseline | ≥ 1 inpatient, or ≥ 2 outpatient **on separate days within 30 days**, same primary tumour type and/or metastatic | **matches** — but confirm the four layered readings in `IE_CRITERIA.md` §6, above all that bone metastasis excludes |
| Pregnancy (X3) | diagnosis, procedure **and revenue** codes (`ICD9DIAG, ICD10DIAG, ICD9PROC, ICD10PROC, HCPCS, REV`), whole study period | same | **matches** |
| Belantamab (X4) | flag computed in the cohort build, exclusion applied in the LOT build once lines exist | "in any LOT" | **matches** |
| 2L/3L: received the line (N1) | a LOT 2 / LOT 3 row exists | same | **matches** |
| 2L/3L: 12-month CE (N2) | `SUBSEQ_PRE_DAYS=365`, gaps ≤ 30 d | same | **matches** |
| 2L/3L: follow-up (N3) | 90 days gap-free enrolment or death | one claim from index | **change** — see §2 |

## 4. Follow-up end and disenrollment

`../lot/LOT_RULES.md` §7.6 says **"Disenrollment is not censoring"**, and
`CENSOR_AT_DISENROLLMENT=FALSE` is the primary-analysis setting. The protocol's §7.1
says the follow-up period runs "until the **end of continuous enrollment** or end of
study period or death, whichever occurs first".

These are opposite. Every time-to-event estimate depends on which one holds:
TTNT, TTD and OS all censor "at their follow-up end date", and that date is
different under each rule.

The engine already computes both. `LOT_RULES.md` §7.6: *"A period ending at
disenrollment is classified `STUDY_END`. There is no `DISENROLLMENT` end reason; the
`*_CE_SENS` columns carry the alternative reading."* So
`LOT_BASE_END_DT_CE_SENS` / `LOT_BASE_END_REASON_CE_SENS` already hold the
protocol's reading, capped at `ENDDATE_CE`
(`../lot/engine/R/steps/10_lot2_5_base.R`).

What has to change is **which pair is primary**. On the protocol's wording the
`_CE_SENS` columns are the analysis and the engine's primary columns are the
sensitivity — the opposite of how the engine is set up. That is a labelling and
config decision, not new code. `OPEN_QUESTIONS.md` Q13.

**Where this package stands:** `CENSOR_AT_DISENROLLMENT` defaults to `TRUE`,
the protocol's reading, so `S_PERIODS.FU_END` already ends at the end of
continuous enrolment. The engine's own columns are untouched — this is the
study package choosing which reading it computes on, not a change to how a
line is counted. Setting the config to `FALSE` gives the engine's primary
reading back as the sensitivity analysis.

## 5. The LOT engine

The protocol's LOT text is a four-sentence summary of the same GSK algorithm the engine
implements — it cites *"Development of line of therapy rules in multiple myeloma: Optum
Claims (Study no: 219870)"*, the earlier study the code lists come from. The windows
agree exactly. What differs is everything the summary does not say, and some of it
changes which patients are in a line.

| protocol statement | engine | verdict |
|---|---|---|
| 1L = therapies within 60 days of the 1L start | `induction_window_days = 60`, applied as `MAP_START_DT` in `[LOT1_START_DT, +59]` (`engine/R/steps/04_lot1_base.R:77-80`) | **window matches** |
| 2L+ starts at the earliest of: allogeneic SCT, **unplanned** autologous SCT, CAR-T, or a new agent not in the previous regimen | the engine computes exactly those four candidates and takes the earliest (`10_lot2_5_base.R:322-491`); `d_AUTO` is where "unplanned" gets its operational meaning — outside the previous line's own window and not a planned tandem (`:388-446`) | **structure matches** |
| Subsequent LOT includes therapies within 30 days on and following the start | `lot_n_induction_window_days = 30`, applied as `[LOT_n_START_DT, +29]` (`10_lot2_5_base.R:544-553`) | **window matches, with three carve-outs (below)** |
| Discontinuation = all MM agents stopped, or a new agent / qualifying SCT introduced | `DISCONTINUATION` covers only "all agents stopped"; the other two are `MED_ADD` and the `SCT_*` / `CART_INIT` reasons | **partly matches — see below** |
| 4L start date and 4L regimen, no 4L cohort | `max_lot = 5`; `LOT_LONG` carries 4L (and 5L) start, type, regimen and count; no cohort table is built in `lot/` at all | **matches**, and the engine is a superset — it also produces a 5L line |

### Divergences that are decisions, not details

1. **"Received" means an episode STARTED, not a claim landed.** A refill arriving under
   live cover extends the existing episode rather than opening a new one
   (`03_mma_map.R:293-334`), so it is invisible to every window test. The consequence is
   spelled out in `LOT_RULES.md` §4.2: a patient continuously on lenalidomide has one
   episode starting at line 1, and it **can never be seen by a later line's window** —
   so lenalidomide will not appear in that line's regimen. The engine records this as
   its own open question. If Annex 2 reads "received" as any claim in the window, the
   engine disagrees.
2. **Steroids are excluded everywhere** (`04_lot1_base.R:81`, `10_lot2_5_base.R:555`).
   If Annex 2's "pre-specified MM therapies" includes dexamethasone, the regimens will
   not match.
3. **The induction window is truncated** at `REGIMEN_CUTOFF_DT` — the day before an
   allogeneic transplant, and before a CAR-T when the induction rule is off. A 1L
   regimen can therefore be assembled over fewer than 60 days.
4. **A CAR-T-started line uses 45 days, not 30** (`cart_consolidation_days`), and an
   **allogeneic-started line gets no regimen at all** and spans a single day.
5. **Permissible biosimilar substitutes count as the same agent in both directions** — a
   biosimilar of a previous-line drug does not start a line, and it does not appear in
   the reported regimen.
6. **Same-day ties break `SCT_ALLO > CART > SCT_AUTO > MED`.** The protocol says only
   "earliest".
7. **A CAR-T inside LOT1's 60-day window does not start LOT2** — an explicit carve-out
   from "CAR-T cellular therapy starts a line" (`cart_rule.R:57-63`).

### The two that matter most for the outcomes

**Discontinuation is not one end reason.** The protocol's footnote treats "all agents
stopped", "a new agent introduced" and "a qualifying SCT event" as three faces of one
concept, and TTD's event is "the date of treatment discontinuation (end of current
LOT)". The engine splits them: `DISCONTINUATION` is only the first;
a new agent gives `MED_ADD`; an SCT gives `SCT_AUTO` / `SCT_ALLO` / `SCT_CART` /
`CART_INIT` / `SCT_AUTO_CONT`. **So TTD's event set is the union of all of them, not the
rows whose `LOT_BASE_END_REASON` says `DISCONTINUATION`.** Reading that column literally
would undercount TTD events badly.

**The engine adds a 90-day confirmation buffer the protocol has no concept of.** A
run-out is not a discontinuation until either 90 days of observation follow it or a
line-opening trigger arrives (`lot_discon_confirm_days`, `06_lot1_end.R:220-227`).
Unconfirmed, the date is dropped and the line is censored to `DEATH` or `STUDY_END`.
This moves end reasons and end dates for **every line near the data cutoff** — which,
with a study end of 31 Mar 2026, is a large share of the 3L cohort.

### Rules in the engine that the protocol does not state

`LOT_RULES.md` §4.3 (a drug of the line's own regimen returning never starts a line),
§4.7 (a short melphalan course outside induction does not advance the line) and §4.8
(a returning prior-line drug joins the line it returns in) were agreed with the study
team between 15 and 30 August 2026. They are compatible
with "a new MM agent that was not part of the previous LOT regimen" but not derivable
from it — §4.3 in particular means a patient with a three-month treatment holiday on
one drug is **one line, not a discontinuation**.

Get all three into Annex 6, or the protocol and the code will disagree on the record.
Note also `LOT_RULES.md`'s own banner: those three rules changed on 30 August 2026 and
**LOT numbers produced before that date are superseded**.

## 6. What is entirely new

| # | what | why |
|---|---|---|
| 1 | **Secondary 2L cohort** — non-nested, index = 2L initiation ≥ 01 Jan 2020, prior malignancy permitted, 1L may fall outside the primary ascertainment period | §7.4. No equivalent exists |
| 2 | **Demographics**: race, ethnicity, region, insurance type | Table 4. Nothing reads `RACE`, `ETHNICITY`, `REGION`/`STATE` or `BUS` today |
| 3 | **Charlson Comorbidity Index (Quan 2011)**, MM-adjusted | Table 4 |
| 4 | **Kim Frailty Index** | Table 4, Table 1 row 4 — pending feasibility |
| 5 | **22 key safety events**, at baseline and during each LOT treatment period | Table 3, Objectives 1 and 2 |
| 6 | **Person-time denominators** — baseline PY and PY at risk, with the chronic/acute rules | §7.8.1 |
| 7 | **Healthcare utilisation** — all-cause hospitalisation, MM-related hospitalisation (MM dx in position 1 or 2), LOS, ED visits | §7.3.2, §7.8.1 |
| 8 | **Secondary malignancies** — 10 categories, confirmed by ≥ 2 diagnosis codes on separate dates, dated at the first | §7.2.4, Objective 3 |
| 9 | **SOC regimen categorisation** and the Sankey between categories | §7.2.2, Table 5 |
| 10 | **TTNT / TTD / OS** with Kaplan-Meier, Brookmeyer-Crowley 95% CI, landmark survival at 6/9/12/18/24 months | §7.8.2 |
| 11 | **Treatment attrition** across 1L → 4L | Table 5 |
| 12 | **Subgroup machinery** — SOC, age ≥ 75, neuropathy, frailty, with the **< 25 patients** suppression rule | §7.2.3, §7.8 |
| 13 | **`TTE_ELIGIBLE`** flag (≥ 3 months potential follow-up) | §7.8.2 |

this package in this folder builds **2 to 13**: demographics, the MM-adjusted
Charlson, frailty, the 22 safety events, person-time, HCRU, secondary
malignancies, SOC categorisation, TTNT/TTD/OS, treatment attrition, the
subgroup machinery with the < 25 suppression rule, and `TTE_ELIGIBLE`
(`02_periods.R`, `09_tte.R`). Item **1**, the secondary 2L cohort, needs the
wide-cohort adapter described in section 0. **Nothing here requires the cohort
build to be edited.**

## 7. The counting rules that will bite

These are stated once, in §7.8.1, and are easy to lose:

1. **Multiple claims on the same day are one event; claims more than 1 day apart are
   distinct events** (baseline prevalence).
2. **Acute events need a ≥ 30-day washout** between events of the same type.
3. **Chronic conditions are counted once, at first instance**, and a patient with the
   condition before the treatment period is **removed from both the numerator and the
   person-time denominator** for it. Named explicitly: chronic kidney disease,
   moderate-to-severe renal impairment or ESRD, pulmonary hypertension, peripheral
   neuropathy, Parkinson's disease, other movement disorders, malignancies,
   thrombocytopenia, anaemia.
4. **A hospitalisation due to a chronic condition is treated as an acute event** and
   may be counted more than once.
5. **Hospitalisations are assigned by admit date**, whichever period the discharge
   falls in. `LOS` runs admit (included) to discharge (**excluded**).
6. **Hospitalisations with no discharge date** count towards patient and event counts
   but are excluded from LOS summaries.
7. An event belongs to a LOT if it falls in
   `[LOT start, min(next LOT start − 1, discontinuation + 30 days)]`. Beyond
   discontinuation + 30 days it is **not counted at all**, even if a later LOT starts.
8. **Baseline characteristics are taken at the index date where possible; if missing
   at index, the value nearest the index within the baseline is used. Comorbidities
   are assessed over the 12-month baseline including the index date** — which
   contradicts §7.1's "does not include index date". `OPEN_QUESTIONS.md` Q14.
9. Rates are per person-year, scaled per 100,000 (`RATE_MULTIPLIER`, recorded on the
   run's metadata row; the TFLS shells are labelled per 100,000 and refuse a run that
   recorded another multiplier). A rate of zero events carries the exact Poisson
   limits, 0 and 3.688879 / PY.
10. **< 25 patients in a stratification ⇒ no analysis** (unless SOC-specific).
11. No imputation. Missing values are reported and dropped where necessary.
12. No p-values, no log-rank, no hypothesis tests anywhere.

## 7a. What the build already measures, so you do not have to guess

Four of the changes above have a price the build writes into the warehouse on **every**
run. None of them needs new code to cost.

| table | what it prices |
|---|---|
| `<prefix>NDMM_FU_CE_COUNTS` | cohort size at 0, 30, 60 and 90 days of follow-up CE and at exactly three calendar months, with the applied row marked. `N_COHORT` is the whole conjunction at that window — the cohort you would ship, not one criterion's count. **This is the cost of the §2 follow-up rework, already computed.** |
| `<prefix>NDMM_INDEX_AGENTS` | every `CL_MED_ABBR` on the code list, whether this run lets it set an index, and how many patients it set one for. **Read it before adding the panobinostat and elotuzumab bars** — it says what barring each one costs |
| `<prefix>NDMM_PREG_WINDOW_COUNTS` | both readings of the pregnancy window, with the incremental exclusions separated from raw claim counts |
| `<prefix>NDMM_OTHER_MALIG_GROUPS`, `<prefix>NDMM_OTHER_MALIG_GRAIN` | the other-cancer pairing grain, per category, against the per-label grain |
| `<prefix>NDMM_BELANTAMAB_RECONCILE` | which cohort members the LOT build will remove for belantamab |
| the cohort build's follow-up query | the follow-up distribution on both definitions, what ended follow-up, and the same by index year |

Two guards to lean on rather than re-implement:

- `NDMM_INDEX_EXCLUDED_ABBRS` checks every entry against the code list and **stops the
  run on a name that matches nothing**, so a misspelled "panobinostat" cannot quietly
  bar nobody.
- `check_cohort_window()` reads the cohort's actual date range and stops if it falls
  outside the window the run was given, naming the CDM vintage it would have read. So
  moving `STUDY_START` to 2018 cannot silently read the wrong quarterly tables.

Four thresholds have been written inconsistently across documents in the past —
enrolment gaps, the other-cancer counts, adult age and the outpatient MM-diagnosis
count. **The new protocol states all four, and every one agrees with what the build
does** (`OPEN_QUESTIONS.md`, "What the new protocol closes").

## 8. Suggested order of work

1. Settle Q1, Q2 and Q13 with the study team — each changes a count. (Q4 and Q17 are
   now answered; Q6 is moot until Annex 2 lands.)
2. Get Annexes 2, 3 and 7, and the missing Table 4 rows.
3. Re-run the cohort and LOT builds with the section 1 overrides in the
   environment — `LOT1_FROM`, `STUDY_START`, `FU_CE_DAYS`,
   `SUBSEQ_FU_CE_DAYS`, `NDMM_INDEX_EXCLUDED_ABBRS`. No edit to the cohort
   build; see section 0. `FU_END`, `TTE_ELIGIBLE`, the four demographic columns
   and censoring are all already built in this package.
4. Build the wide-cohort adapter the secondary 2L cohort needs — the full
   cohort schema with eligibility evidence retained — and run the LOT engine
   over it. Section 0 says why a table of ids and flags cannot stand in.
5. Code lists (`CODELISTS.md` §4) — the long pole, and blocked on Annex 3.
6. Outcomes package: baseline prevalence, incidence with person-time, HCRU,
   secondary malignancies, TTNT/TTD/OS.
7. Subgroups and SOC categorisation.
