# Open questions for the study team

Each entry is a point the protocol and the Optum documentation do not settle
and that changes a count or a definition. Every reading the build takes
meanwhile is a setting (`config.csv`, or the environment), defaulting to the
protocol's reading where it has one, and every run records the reading it used
in `S_RUN_METADATA.OPEN_QUESTION_READINGS` (`MODULES.md` "The three things
that make it selectable"). Answered questions keep their numbers because the
code cites them.

## The index

| Q | topic | status | setting (default) |
|---|---|---|---|
| Q1 | study period start | answered: 01 Jan 2018 | `STUDY_START` (`2018-01-01`) |
| Q2 | outpatient MM diagnosis code set | **open, blocking** | `MM_DX_OUTPATIENT_CODES` (`listed`), upstream |
| Q3 | 30/60-day pairing windows as sensitivities | recorded reading | `MM_DX_OUTPATIENT_WINDOW_DAYS` (`90`), `OTHER_CANCER_PAIR_DAYS` (`30`), upstream |
| Q4 | "with medical and pharmacy benefits" | answered: satisfied by construction | — |
| Q5 | what "evidence of follow-up" excludes | answered: nobody, on the literal reading | `FU_EVIDENCE_RULE` (`claim_from_index`) |
| Q6 | steroid-only claims and the prior-therapy exclusion | **open, blocking** once Annex 2 lands | `PRIOR_TX_DROP_STEROIDS` (`TRUE`), upstream |
| Q7 | prior malignancy in the secondary 2L cohort | answered: permitted | `SEC2L_APPLY_OTHER_CANCER` (`FALSE`), `SEC2L_INPUT_IS_WIDE` (`FALSE`) |
| Q8 | does `DOD` join on `PATID` | answered: yes | — |
| Q9 | region column or state crosswalk | answered: crosswalk | `REGION_SOURCE` (`state_crosswalk`) |
| Q10 | `RACE` and `ETHNICITY` code values | answered | — |
| Q11 | how an emergency visit is identified | **open, blocking** | `ED_DEFINITION` (`revenue,pos`), `ED_ADMITTED` (`both`) |
| Q12 | the two year ranges in Table 4 | answered | — |
| Q13 | does disenrollment censor follow-up | **open, blocking** | `CENSOR_AT_DISENROLLMENT` (`TRUE`) |
| Q14 | does the baseline include the index date | answered: two windows | `BASELINE_INCLUDES_INDEX` (`FALSE`), `COMORBIDITY_BASELINE_INCLUDES_INDEX` (`TRUE`) |
| Q15 | Annexes 2, 3, 6 and 7 | **open, blocking** | `FRAILTY` (`FALSE`), `COMORBID_SUBGROUPS` (`FALSE`) |
| Q16 | enrolment attribute "at index" | answered | `ENROL_ATTR_AT` (`index_span`) |
| Q17 | `PROC_CD` versus `PROC` | answered | — |
| Q18 | is the 2022 business-rules document current | answered: no | — |
| Q19 | bridged-gap days as person-time | recorded reading | — |
| Q20 | annex numbering | answered | — |
| Q21 | calendar months or day counts | recorded reading | `MONTHS_AS` (`days`) |
| Q22 | year-only death dates | answered: none | — |
| Q23 | which pregnancy window | recorded reading | `PREGNANCY_WINDOW` (`study_period`), upstream |
| Q24 | `ICD_FLAG` naming neither family | answered: negligible | — |
| Q25 | do denied claims count | recorded reading | `CLAIM_STATUS` (`all`) |
| Q26 | `DOD` joins on `PATID` | answered, with Q8 | — |
| Q27 | which route makes a stay MM-related | **open** | `MM_HOSP_POSITION` (`confinement`), environment only |
| Q28 | `DOD.MBR_MATCH_TYPE` | **open**, needs the vendor | — |
| Q29 | does the small-cell floor exempt SOC | **open** | — (no exemption applied) |
| Q30 | which diagnosis date | **open** | `DX_DATE_SOURCE` (`cohort_mm_dx`) |
| Q31 | secondary 2L malignancy prevalence window | **open** | `MALIG_PREVALENCE_WINDOW` (`since_diagnosis`) |
| Q32 | treatment sequence among those with a malignancy | **open** | — (all readings written) |
| Q33 | the discontinuation day | **open** | — |
| Q34 | does the acute washout cross a period boundary | **open** | — |
| Q35 | malignancy confirmation and at-risk grain | **open** | — |
| Q36 | Table 3's 22 rows against the list's 23 | **open** | — |

"Upstream" settings belong to the cohort build: this package records them and
checks the ones the cohort build's metadata carries (`MODULES.md` "An upstream
reading is recorded as verified or as an assertion"). A cohort setting is
changed on the cohort side, `../ndmm/README.md` "Settings".

---

## Blocking — a number moves

### Q2. Does the outpatient arm of the MM diagnosis use the broad code set?

§7.2.1.1:

> "At least one inpatient medical claim with a diagnosis code for MM in any position
> (any ICD-9-CM = **203.0x** or ICD-10-CM code = **C90.0x**) or ≥ 2 outpatient medical
> claims **for MM** in any position on the claim, on separate days within 90 days"

The strict code set is attached to the inpatient arm; the outpatient arm says
only "for MM". Broad adds 203.1x (plasma cell leukaemia), 203.8x, C90.1x and
C90.2x (extramedullary plasmacytoma).

**Reading meanwhile:** the cohort build requires the strict `203.0x`/`C90.0x`
prefix of the inpatient arm only, and the outpatient pair accepts any code on
`mm_dx.csv`. The production file carries only the eight strict codes
(`CODELISTS.md` §1), so both arms are strict in practice, and the broad reading
is a code-list edit, not a code change.

**Worth:** forty myeloma-adjacent codes are present in the CDM. The choice that
matters most is within the strict family: 29,449 members carry C90.01 (in
remission) and 14,127 C90.02 (in relapse), and whether those qualify as the
incident diagnosis decides whether a prevalent patient enters as newly
diagnosed.

| code | patients | claim lines |
|---|---|---|
| C90.00 | 98,302 | 6,934,781 |
| C90.01 *(in remission)* | 29,449 | 755,195 |
| C90.02 *(in relapse)* | 14,127 | 611,471 |
| C88.4 | 12,278 | 239,639 |
| C88.0 | 8,899 | 385,950 |
| C90.30 | 8,702 | 148,130 |
| C88.40 | 4,617 | 43,317 |
| C88.00 | 4,608 | 81,611 |
| C90.10 | 4,371 | 55,884 |
| C90.20 | 1,804 | 30,520 |

**Ask:** strict on both arms, or strict inpatient / broad outpatient?

### Q6. Do steroid-only claims count as "MM oncology therapy" for the prior-therapy exclusion?

Exclusion X1: *"≥ 1 medical or pharmacy claim for **any MM oncology therapy**"*
during the 12-month baseline. Dexamethasone is prescribed for many non-MM
reasons, so counting it would exclude patients on the strength of an unrelated
steroid course.

**Reading meanwhile:** the cohort build drops `DEX`, `DEXA`, `DEXAMETHASONE`,
`PRED` and `PREDNISONE` from the prior-therapy scan. The LOT engine excludes
steroids everywhere (`../lot/LOT_RULES.md` §2.1), so this question is only
about the exclusion scan.

It is moot on today's production code list, which carries none of those
abbreviations in `CL_MED_ABBR`, so the drop removes nothing. It becomes live
when Annex 2's therapy list is loaded, because the protocol's SOC categories
are dexamethasone-containing regimens - and a steroid arriving under an
abbreviation the guard does not name silently passes it.
`<prefix>NDMM_INDEX_AGENTS` shows every `CL_MED_ABBR` and whether a run let it
set an index, so the first run on the new list answers that.

**Worth:** of 80,398 members with any baseline treatment claim, 12,033 have a
steroid J-code, 3,489 an unambiguous myeloma agent, and **10,466 a steroid and
no myeloma agent** - three times as many decided by the steroid reading as by
the clear-cut one.

**Ask:** confirm steroids alone do not trigger X1, and confirm the steroid
abbreviations against whatever list Annex 2 delivers.

### Q13. Does disenrollment censor follow-up?

§7.1:

> "The patient **follow-up period** will be defined as the period starting from the
> index date... until the **end of continuous enrollment** or end of study period or
> death, whichever occurs first."

`../lot/LOT_RULES.md` §7.6 says **"Disenrollment is not censoring"**, and the
LOT engine's primary columns follow it. TTNT, TTD and OS all censor "at their
follow-up end date", so every median and landmark estimate differs between the
two readings.

**Reading meanwhile:** `CENSOR_AT_DISENROLLMENT=TRUE`, the protocol's reading:
`S_PERIODS.FU_END` ends at the end of the enrolment span covering the cohort's
own index. `FALSE` gives the engine's reading as the sensitivity. The engine
computes both (`LOT_BASE_END_DT_CE_SENS` and `LOT_BASE_END_REASON_CE_SENS` carry
the censor-at-disenrollment version), so the question is only which one is the
primary analysis.

**Worth:** the setting decides the follow-up of up to 30,392 members (29%),
while the 30-day bridging rule touches only 6,221.

| | members |
|---|---|
| any myeloma patient | 105,125 |
| contiguous re-enrolment only, no real gap | 61,526 |
| **a bridged gap of 1–30 days** | **6,221** |
| **a break of more than 30 days** | **30,392** |
| mean length of those breaks | **1,361.6 days** |

A mean break of 3.7 years says what these are: people who left the plan and
came back years later, not brief administrative lapses.

These are upper bounds on the breaks. The query merged spans with
`lag(ELIGEND)` - the immediately preceding row - where the package's
`build_enroll_spans()` uses a running `max(ELIGEND)` over all prior rows, and
the two differ on nested spans: 11,986 myeloma members (11.4%) have overlapping
enrolment rows. Every nested span the `lag()` form mistakes for a gap inflates
the break count, so the true figure is at most 30,392. `RUN_ONCE_3.sql` builds
`mm_spans` with the package's own logic; one run of it replaces the bounds with
the number the build produces.

**Ask:** confirm follow-up ends at disenrollment, and that this is the primary
analysis rather than a sensitivity.

---

## Blocking — a definition is unbuildable without an answer

### Q15. Annexes 2, 3, 6 and 7 are outstanding

- **Annex 2** — eligible/expected MM therapies and SOC regimen categorisation.
  Criterion I3 and the `soc` and `patterns` modules need it.
- **Annex 3** — ICD-10-CM code lists for the Table 3 conditions, the secondary
  malignancy categories, and the healthcare-utilisation definitions.
  Objectives 1-3 cannot be computed without it.
- **Annex 6** — the LOT algorithm, to reconcile against `../lot/LOT_RULES.md`.
- **Annex 7** — the Kim CFI algorithm and code lists, or confirmation frailty is
  out. `FRAILTY` stays off until then.

The rest of Primary Objective 1's Table 4 rows and most of Primary Objective
2's are specified in the protocol but have not come through in a form that can
be read; a clean copy of that section closes it (`VARIABLES.md` §4). The exact
request is `CODELISTS.md` §5.

### Q11. How is an emergency department visit identified?

The protocol names "Emergency visits" as a healthcare-utilisation outcome
(§7.3.2, §7.8.1) and never defines it. Optum CDM has **no ED flag**.

**Reading meanwhile:** `ED_DEFINITION=revenue,pos` - revenue codes 045x/0981
or `POS = '23'`; `cpt` (99281-99285) is the third construction. The codes go
in `hcru.csv`, which is not filled. `ED_ADMITTED=both` counts an ED claim that
carries a `CONF_ID` (and so became an admission, business rule 14) as an ED
visit as well as a stay; `inpatient_only` drops it from the ED count. One ED
visit is one patient-day.

**Worth:** distinct patient-days since 2018, among myeloma patients:

| construction | visit-days |
|---|---|
| revenue code 045x / 0981 | 385,803 |
| place of service 23 | 436,495 |
| CPT 9928x | 364,272 |
| **any of the three** | **499,272** |
| revenue *and* CPT on the same day | 229,938 |
| any of the three, carrying a `CONF_ID` | **162,211** |

The widest construction is 37% above the narrowest, and the three overlap far
less than their totals suggest - revenue and CPT agree on only 229,938 of the
~400,000 each finds; the revenue arm matches facility claims and the CPT arm
professional ones. 162,211 visit-days (32.5% of the union) became admissions,
so `ED_ADMITTED` is worth one visit in three.

**Ask:** which construction, and is an ED visit that becomes an inpatient
admission counted as an ED visit, a hospitalisation, or both?

---

## Needs a decision, but does not block a first build

### Q27. Which route defines "a MM diagnosis in first or second position"?

§7.8.1 defines an MM-related hospitalisation as one with *"a MM diagnosis in
first or second position"*, without saying of what. There are two routes:

- **`CONFINEMENT.DIAG1` / `DIAG2`** — the first two diagnoses on the bundled,
  unduplicated confinement record (five positions, stay-level).
- **`MED_DIAGNOSIS.DIAG_POSITION` 1 or 2** on a claim carrying that `CONF_ID`
  (twenty-five positions, line-level) — the route business rule 13 documents
  for "diagnoses reported within a hospitalization".

**Reading meanwhile:** `MM_HOSP_POSITION=confinement`; `claim_positions` is the
other route. Both are emitted and executed by the test suite.

**Worth:** the largest unresolved swing in the package's own SQL. Over 241,362
stays belonging to myeloma patients since 2018:

| | stays |
|---|---|
| route A — MM in `CONFINEMENT.DIAG1/DIAG2` (the default) | 32,508 |
| route B — MM in `DIAG_POSITION` 1-2 on a claim carrying the `CONF_ID` | 65,206 |
| found by route A only | 1,206 |
| found by route B only | 33,904 |
| MM only in `CONFINEMENT.DIAG3-5` — neither route counts these | 33,978 |

**Ask:** confirm the confinement record's own first two diagnoses are meant.

### Q28. What is `DOD.MBR_MATCH_TYPE`, and should low-confidence deaths count?

`DOD` has five columns, one of them `MBR_MATCH_TYPE varchar(1)`, which no
Optum document covers. The name suggests how each member was linked to the
death record; if some links are lower-confidence, overall survival (a secondary
objective) is overstated by including them and understated by excluding them.
Neither build filters on it.

**Worth:** two values, no nulls - a binary flag, not a graded score. Which value
is the confident link cannot be derived from the data.

| value | rows | share |
|---|---|---|
| 2 | 6,782,785 | 58.93% |
| 1 | 4,727,043 | 41.07% |

Two death-date findings bear on the same question. 33,800 of 93,245 members
(36.2%) carry a death record; **348 have a death date before their index date**
and **up to 9,705 one before their last claim**. Both are upper bounds:
`YMDOD` is month-precision and the query imputed the 15th, so a same-month
death and claim can be flagged wrongly; the right test compares at month
granularity. If the low-confidence link value is the one carrying these, that
answers both.

**Ask (to the vendor):** what the values mean, and whether any should be
excluded.

### Q29. Does the small-cell floor exempt SOC strata?

The protocol states the 25-patient floor twice, and the two sentences differ.

> §7.2.3: "Stratifications with <25 patients will not be performed or may be
> regrouped due to low volumes."

> §7.8: "If there are less than 25 patients in a particular stratifications or
> cohort, analyses will not be conducted **(unless specific to SOC)**."

Only §7.8 carries the exemption, and it does not say which analyses are
"specific to SOC" — every SOC-keyed table, or only the SOC distribution itself.

**Reading meanwhile:** §7.2.3 - every cell under 25 is suppressed, SOC
included (`R/modules/11_release.R`). That is the conservative reading:
suppressing more than required loses a stratum the protocol may permit; the
other way round publishes one it forbids. It matters for `S_SOC` above all,
where a category held by fewer than 25 patients in a line is exactly what §7.8
might be exempting.

**Ask:** whether the SOC exemption applies, and if so to which tables.

### Q30. Which diagnosis date do the diagnosis-anchored rows hang on?

Table 4's *"Year of MM diagnosis"* and *"Time from diagnosis to follow-up
end"*, Table 5's *"Time from diagnosis to 1L initiation"* and I2's age at
diagnosis all need one date. The cohort build records the qualifying diagnosis
(`MM_DX_DT`, the claim that satisfied I1); Table 4's footnote says *"first
medical claim for MM within the baseline period on or prior to 1L"*, which is
a different claim for a patient diagnosed more than a year before therapy.

**Reading meanwhile:** `DX_DATE_SOURCE=cohort_mm_dx` - one diagnosis date for
I1, I2, Table 4 and Table 5, needing no code list. `baseline_first_claim` is
Table 4's literal reading and needs `mm_dx.csv`; `S_PERIODS.DX_DT_SOURCE`
says which supplied each row.

**Ask:** confirm the diagnosis date is the qualifying diagnosis, or that Table
4's footnote is meant to redefine it.

### Q31. Over which window is the secondary 2L cohort's malignancy prevalence taken?

§7.4.1.2 and §7.8.4: *"all malignancies occurring after diagnosis but prior to
2L will be tabulated as the background prevalence"*. §7.8.1's 2L bullet says
*"during baseline"* — the 12 months before the 2L index. For a patient
diagnosed years before 2L the two windows differ by years of person-time.

**Reading meanwhile:** `MALIG_PREVALENCE_WINDOW=since_diagnosis` (the two
sections about this cohort); `baseline` is the alternative. The person-time
follows the window.

**Ask:** which window.

### Q32. Which lines are a "treatment sequence among those with a malignancy"?

Table 4: *"Tabulation of the top 5–10 sequences among those with a malignancy
occurring after treatment"*. The sentence does not say whether the sequence is
the therapy the patient had received **when** the malignancy appeared or the
therapy given **after** it.

**Reading meanwhile:** none is chosen. `S_MALIGNANCY_SEQUENCES` carries both
readings and the whole observed sequence on `LINES` (`to_malignancy`,
`after_malignancy`, `all_observed`), each with its own denominator, in both
scopes (`after_index`, and the sensitivity `after_2l`).

**Ask:** which reading the shell should print.

### Q33. On which day is a line "discontinued" when a new agent or transplant ends it?

Table 4's footnote: *"discontinuation of a regimen occurs when all MM agents in
the LOT are stopped OR when a new agent/qualifying SCT event is introduced"*.
The LOT engine ends a line the **day before** an added agent or a line-opening
transplant (`../lot/LOT_RULES.md` §7.1), because the event opens the next line;
a run-out ends the line **on** the confirmed run-out.

**Reading meanwhile:** `PROTOCOL_DISCON_DT` on the spine is the run-out day for
`DISCONTINUATION`, and the introduction day (engine end + 1) for `MED_ADD`,
`CART_INIT`, `SCT_AUTO`, `SCT_ALLO` and `SCT_CART`, so TTD and TTNT date the
same event on the same day. `SCT_AUTO_CONT` — an autologous transplant inside
the line's own induction window, which consolidates the line and opens no
other — is taken as the *"all agents stopped"* branch, dated on the transplant,
not as a *"qualifying SCT"*.

**Ask:** confirm the introduction day, and that a planned in-window autologous
transplant is not a qualifying SCT event.

### Q34. Does the acute washout cross a period boundary?

§7.3.2: *"a ≥30 day washout between acute events of the same type will be
applied"* — a statement about events, not periods.

**Reading meanwhile:** the chain runs **once** per cohort over the patient's
timeline (baseline start → follow-up end) and each period takes the distinct
events dated inside it; the chain's own answer is kept on `S_SAFETY_COUNTED`
under `PERIOD = TIMELINE`. So an infection coded three days before the index
and again five days after it is one event, not a baseline event and a new
incident one. The chain starts at the cohort's baseline start, so a baseline
event is never suppressed by history before the window (§7.8.1 takes the
baseline *"irrespective of prior event history"*).

**Ask:** confirm the washout is measured across the index and across lines.

### Q35. At what grain is a secondary malignancy confirmed, and at what grain is a patient "not at risk"?

Table 4: *"confirmed through the presence of at least 2 diagnosis codes
occurring on separate dates"* — the unit the two codes must share is not
stated (the same code, the same Table 2 subtype, or the same category). §7.8.1
names *"malignancies"* as **one** chronic condition, while Objective 3
summarises *"according to type"*.

**Reading meanwhile:** confirmation at **subtype** grain, both codes on or
before the cohort's follow-up end; prior history treated per **category**; and
an aggregate `(any malignancy)` row - a first malignancy of any kind, with a
patient who had any before the period out of numerator and denominator - so the
one-condition reading is on the table beside the per-category one. A malignancy
is attributed to a line only inside the §7.3.2 treatment window for the rates,
and to *"the LoT after which"* it fell (`LOT_AFTER_WHICH`) on the occurrence
table.

**Ask:** the confirmation grain, and whether prior history of one category
removes a patient from the others.

### Q36. Table 3 lists 22 conditions; the code list carries 23

Table 3 as printed has 22 rows. `safety_events.csv` carries 23, with corneal
ulcer and keratopathies as two rows and Parkinson's disease and other movement
disorders as two. Two of the 23 are typed *"Acute or chronic"* /
*"Acute/Chronic"* by the protocol itself, which names two counting rules at
once, so the safety module stops on them until they are typed
(`codelists/README.md`).

Table 4's pages 33–34 are not legible in the protocol as supplied; the rows
they carry are mapped as `VARIABLES.md` §4 describes.

**Ask:** confirm the 23-row list, type the two dual-typed conditions, and
supply a legible copy of pages 33–34.

---

## Recorded readings — measured, and too small to decide

The protocol leaves these open, but the data has priced the difference and
found it small. The build takes the reading below; each is a setting that
produces the alternative where one exists.

### Q3. Are 30- and 60-day outpatient pairing windows wanted as sensitivities?

**Reading:** the MM diagnosis pairs two outpatient claims within 90 days, the
only window the protocol names (`MM_DX_OUTPATIENT_WINDOW_DAYS=90`; 30 and 60
are available). The other-cancer exclusion pairs within the protocol's 30 days
(`OTHER_CANCER_PAIR_DAYS=30`). Both are cohort-build settings.

**Worth:** widening a pairing window is small. On the other-cancer exclusion,
16,171 members have a paired other cancer within 30 days and 16,760 within 60:
589 more, and 1,108 members have at least one cancer category whose only
pairing sits in the 31-60 day band.

### Q19. Do the days inside a bridged enrolment gap count as person-time?

**Reading:** bridged gap days count as covered person-time. `BASELINE_PY` and
`PERIOD_PY` are window lengths, so no setting carves them out. The protocol and
both Optum documents are silent.

**Worth:** the bridged gaps of 30 days or fewer carry 109,679 days across the
whole myeloma population, roughly 300 person-years - an upper bound, with the
same `lag(ELIGEND)` limitation as Q13 - against denominators in the tens of
thousands of person-years. 987 gaps sit at exactly 30 days against 98 at
exactly 29, so the 30-day threshold lands on a plan-renewal boundary and moving
it by one day is not neutral.

### Q21. Are "months" calendar months or fixed day counts?

**Reading:** a month is a fixed day count (`MONTHS_AS=days`). 12 months is
`[index - 365, index - 1]` at every line and 3 months is 90 days, because
`add_months()` would give two patients indexed a day apart different windows,
and 90 is the shortest three calendar months and so the more permissive
reading. `MONTHS_AS=calendar` produces the other.

**Worth:** `add_months(index, -12)` and `index - 365` land on the same date for
73,321 members and one day apart for 19,924, never two: one day, for 21% of
members.

### Q23. Which pregnancy window?

**Reading:** the whole study period, which is what X3 says
(`PREGNANCY_WINDOW=study_period`); the alternative is the patient's own baseline
and follow-up.

**Worth:** 307 members have a proxy pregnancy code anywhere in the study period
and 99 in their own baseline year, so the wider reading excludes 270 more -
0.29%. The codes are proxies until Annex 3 arrives, so the number will move;
the reading will not.

### Q25. Should denied claims count?

**Reading:** all claims count, denied ones included (`CLAIM_STATUS=all`).
Neither the protocol nor the business rules mention `PAID_STATUS`, and the
cohort build does not filter on it, so changing it here alone would make this
package disagree with the cohort table it is built on. `paid_only` is the
sensitivity.

**The setting is narrower than its name.** It filters the ED arm of the `hcru`
module and nothing else - not the I5 follow-up claims, the MM-hospitalisation
subquery, `CONFINEMENT` (no paid status) or `RX` (no paid status, and
`STD_COST` cannot stand in for one - `DATA_MAPPING.md` §4). Denied pharmacy
claims cannot be identified in this extract at all, which belongs in the SAP as
a stated limitation. The warehouse stores `P`/`D` where the dictionary spells
`PAID`/`DENIED`; both are matched, and a null is not treated as denied.

**Worth:** 17.42% of medical lines among myeloma patients are denied, but
denials concentrate in ordinary outpatient claims and are thin in the claims
this study counts as events:

| claim shape | lines | denied | % |
|---|---|---|---|
| other outpatient | 70,523,049 | 15,266,931 | 21.65% |
| ED-shaped | 1,298,697 | 97,635 | 7.52% |
| inpatient-linked | 9,882,844 | 575,950 | 5.83% |

At the event level, 2,630 of 499,272 ED patient-days (0.53%) have every line
denied: `paid_only` removes one ED visit in 200.

**Ask (optional):** whether the study intends to include denied claims, and if
not, whether the exclusion should reach beyond emergency visits.

---

## Answered

**Q1. Study period start.** Answered by the study team on 16 September 2026:
**01 Jan 2018**, the §7.1 body text; the two figures' 01 Jan 2016 is a
leftover. `STUDY_START=2018-01-01` and the 1L index floor `2019-01-01` are the
shipped defaults of `ndmm/`, `lot/engine/` and this package, and this package
refuses a cohort built to a different window (`BINDING_UPSTREAM_SETTINGS`). The
cohort build requires the qualifying diagnosis inside the study period, which
drops patients diagnosed in 2016-2017 whose 1L starts in 2019 (17,288 members
were first diagnosed in 2016 or 2017); worth a sentence from the author
confirming that is meant.

**Q4. "With medical and pharmacy benefits".** Satisfied by construction: the
deployed `MEMBER_ENROLLMENT` has no benefit indicator, a span carries both, and
§7.5 says all patients in the database have both. No predicate
(`DATA_MAPPING.md` §7).

**Q5. Evidence of follow-up.** All 93,245 members have a medical claim on their
index date, so the literal reading of *"at least one claim from the index
date"* excludes nobody; the build takes it (`FU_EVIDENCE_RULE=claim_from_index`).
The strict reading, a claim after the index (`claim_after_index`), would exclude
1,012 members (1.1%).

**Q7. Prior malignancy in the secondary 2L cohort.** Permitted: §7.8.1 says
*"because prior history of malignancy during baseline is permitted per
eligibility criteria, the baseline prevalence of any malignancy will be
summarized"*. So X2 does not reach the secondary cohort. 17,964 members
(19.3%) carry another cancer (any C-code other than C90 and C44) in their
baseline year. The cohort cannot be built from the shipped cohort table; it
needs a wide input (`MODULES.md` "The secondary 2L cohort needs a wide input").

**Q8 / Q26. `DOD` joins on `PATID`.** All 11,509,828 `DOD` patients match the
enrolment table on `PATID` (`bigint`, same domain), so the business-rules note
that DOD cannot be joined does not hold for this deployment, and overall
survival is reportable.

**Q9. Region.** The deployed `MEMBER_ENROLLMENT` carries `STATE` and no
`REGION` (`DATA_MAPPING.md` §4), so region is a 50-state + DC → Census-region
crosswalk (`REGION_SOURCE=state_crosswalk`), read from the enrolment row Q16
selects. `region_column` is refused at preflight. 5.7% of members hold two
distinct `STATE` values across their rows and none holds three. It becomes a
question again only if a refresh brings `REGION`.

**Q10. `RACE` and `ETHNICITY` code values.** `RACE` is `W`, `B`, `A`, `U` or
null; `ETHNICITY` is `N`, `H`, `U` or null; `RACE_SOURCE` is always
`Self-Reported`. The package's mapping (`DATA_MAPPING.md` §9) is right. Race is
null or `U` on about 42% of enrolment rows and ethnicity on about 36%, so Table
4's rows will be heavily "Unknown" and should say so.

**Q12. The two year ranges in Table 4.** With the study period from 2018 and
the 1L floor at 2019, no line starts before 2019, so the 2017 and 2018 columns
of *"Types of 1L, 2L, 3L SOCs or classes by line"* are empty by construction;
the 2017 bound is a leftover. `S_SOC.LOT_START_YEAR` carries the year, so the
table is a count over it whatever range the shell prints.

**Q14. Does the baseline include the index date.** Both sentences hold, as two
windows: §7.1's baseline excludes the index day (`BASELINE_START`/`BASELINE_END`,
for safety and HCRU) and §7.8.1's comorbidity baseline includes it
(`COMORB_BASELINE_START`/`COMORB_BASELINE_END`, for Charlson). All 93,245
members have a claim on their index date, so the distinction is real; on the
12-month enrolment criterion it changes one patient.

**Q16. Enrolment attributes "at index".** The row covering the index date
supplies race, ethnicity, region, sex and insurance; where more than one covers
it the order is `ELIGEND` descending, then `ELIGEFF` descending, then
`PAT_PLANID`, so two runs cannot disagree. Where none covers the index day the
baseline row ending nearest it stands in, and `S_DEMOGRAPHICS.ATTR_SOURCE` says
which. `ENROL_ATTR_AT=latest_span` is the comparison reading. 11,986 myeloma
members (11.4%) hold overlapping rows on different `PAT_PLANID`s; those rows
disagree on `STATE` for 473 members and on `BUS` for 388, and never on `RACE`.

**Q17. `PROC_CD` versus `PROC`.** `MED_PROCEDURE.PROC` is the ICD procedure
code and `MEDICAL.PROC_CD` is CPT/HCPCS; business rule 5, which says the
opposite, is a transcription error (`DATA_MAPPING.md` §4, MED_PROCEDURE).

**Q18. The 2022 business-rules document.** Not current: it predates the V9.0
dictionary and is wrong on two checkable points (race on SES, the DOD join).
Treat it as a 2022 statement - useful for join keys and the fourteen rules the
dictionary corroborates, not authoritative on anything the CDM has since
changed. Still worth asking whether a newer document exists and whether the
inpatient/outpatient construction has been revalidated against V9.0.

**Q20. Annex numbering.** The body text settles it: §7.3.2 and §7.8.5 cite
Annex 3 for code lists and §7.8 cites Annexes 4 and 5 for the shells, agreeing
with Annex 1. The contents page has three entries rotated. Nothing in the build
turns on it; send the authors the correction, with the typos "ALGORITHIM" and
"FRAILITY".

**Q22. Year-only death dates.** None: all 11,509,828 `YMDOD` values are
`YYYYMM` (200005 → 202603). The constructed day is the 15th within a known
month, a ±15-day convention.

**Q24. An `ICD_FLAG` naming neither family.** 530 rows of ~16.4 billion.
Reported rather than gated.

---

## What each decision is worth

Measured against the CDM with the profiling queries in `RUN_ONCE_2.sql` and
`RUN_ONCE_3.sql`. The proxy population is **105,125** members with a C90 code
since 2016, of whom **93,245** have a first C90 code on or after 01 Jan 2018.
None of these is the study cohort — no age, enrolment or exclusion criteria —
so read every number as an order of magnitude, not a cohort count. The detail
is under each question.

| # | question | the readings differ by |
|---|---|---|
| Q27 | which route makes a stay MM-related | **32,508 vs 65,206 stays — 2×** |
| Q13 | does disenrollment censor follow-up | the follow-up of up to 30,392 members (29%) |
| Q11 | how an ED visit is identified | 364,272 to 499,272 visit-days (+37%) |
| Q2 | narrow or broad MM code set | 29,449 C90.01 + 14,127 C90.02 members |
| Q6 | do steroid-only claims trigger X1 | 10,466 members, once Annex 2 lands |
| Q28 | low-confidence death links | up to 41% of death records |
| Q25 | do denied claims count | 0.53% of ED visit-days |
| Q19 | person-time inside bridged gaps | 109,679 days (~300 person-years) |
| Q3 | 30-day or 60-day pairing window | 589 members net |
| Q23 | which pregnancy window | 270 members |
| Q21 | calendar months or 365 days | one day, for 21% of members |

**Continuous enrolment is the largest attrition step.** Of 93,245 members with
a first myeloma diagnosis from 2018, 57,933 (62.1%) pass 12 months of
continuous enrolment before index, and 35,312 are lost - more than any
exclusion, and a criterion this package re-applies itself (I4/N2). The same
`lag()` limitation as Q13 makes the pass rate a lower bound.

### Priced on every run

The cohort build writes the alternative into the warehouse on every run, so
these need no extra query (`../ndmm/README.md` "The review tables"):

| table | what it prices | bears on |
|---|---|---|
| `<prefix>NDMM_FU_CE_COUNTS` | cohort size at 0, 30, 60 and 90 days and at exactly three calendar months, applied row marked | the cohort build's follow-up enrolment window, and Q21 |
| `<prefix>NDMM_PREG_WINDOW_COUNTS` | both pregnancy-window readings | Q23 |
| `<prefix>NDMM_INDEX_AGENTS` | every `CL_MED_ABBR`, whether this run let it set an index, and how many patients it set one for | the panobinostat / elotuzumab bars, and Q6 |
| `<prefix>NDMM_OTHER_MALIG_GROUPS`, `<prefix>NDMM_OTHER_MALIG_GRAIN` | the pairing-grain choice, per category | the X2 readings (`IE_CRITERIA.md` §6) |

---

## Already settled elsewhere

Not questions — recorded here so nobody reopens them.

| point | where it is settled |
|---|---|
| The thresholds are as written: gaps ≤ 30 days, ≥ 1 inpatient or ≥ 2 outpatient other-cancer claims, age ≥ 18, ≥ 2 outpatient MM claims | `IE_CRITERIA.md` §4 and §6 |
| Melphalan short-course cap is `≤ 28` days, inclusive | `../lot/LOT_RULES.md` §4.7 |
| A confirmed melphalan course beats the MAP fold-in | `../lot/LOT_RULES.md` §4.7 |
| A returning prior-line drug joins the line it returns in | `../lot/LOT_RULES.md` §4.8 |
| A drug of the previous regimen never starts a line | `../lot/LOT_RULES.md` §4.3 |
| Discontinued 1L then a 12-month baseline before 2L/3L | `IE_CRITERIA.md` |
| Melphalan mono when melphalan came with a steroid | `../lot/LOT_RULES.md` §2.1 |

Three of the engine rules (§4.3, §4.7, §4.8) are **not** in the protocol text.
They should go into Annex 6 so the protocol and the code agree on the record.
