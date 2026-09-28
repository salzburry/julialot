# Open questions for the study team

Each entry is a point the protocol and the Optum documentation do not settle
and that changes a count or a definition. Every reading the build takes
meanwhile is a setting (`config.csv`, or the environment), defaulting to the
protocol's reading where it has one, and every run records the reading it
used in `S_RUN_METADATA.OPEN_QUESTION_READINGS` (`MODULES.md` "What a run
records"). Q-numbers are stable because the code cites them. "Upstream"
settings are the cohort build's (`IE_CRITERIA.md` "Settings the cohort build
owns"); a cohort setting is changed on the cohort side, `../ndmm/README.md`
"Settings".

| Q | topic | status | setting (default) |
|---|---|---|---|
| Q2 | outpatient MM diagnosis code set | **open, blocking** | `MM_DX_OUTPATIENT_CODES` (`listed`), upstream |
| Q6 | steroid-only claims and the prior-therapy exclusion | **open, blocking** once Annex 2 lands | `PRIOR_TX_DROP_STEROIDS` (`TRUE`), upstream |
| Q11 | how an emergency visit is identified | **open, blocking** | `ED_DEFINITION` (`revenue,pos`), `ED_ADMITTED` (`both`) |
| Q13 | does disenrollment censor follow-up | **open, blocking** | `CENSOR_AT_DISENROLLMENT` (`TRUE`) |
| Q15 | Annexes 2, 3, 6 and 7 | **open, blocking** | `FRAILTY` (`FALSE`), `COMORBID_SUBGROUPS` (`FALSE`) |
| Q27 | which route makes a stay MM-related | open | `MM_HOSP_POSITION` (`confinement`), environment only |
| Q28 | `DOD.MBR_MATCH_TYPE` | open, needs the vendor | - |
| Q29 | does the small-cell floor exempt SOC | open | - (no exemption applied) |
| Q30 | which diagnosis date | open | `DX_DATE_SOURCE` (`cohort_mm_dx`) |
| Q31 | secondary 2L malignancy prevalence window | open | `MALIG_PREVALENCE_WINDOW` (`since_diagnosis`) |
| Q32 | treatment sequence among those with a malignancy | open | - (all readings written) |
| Q33 | the discontinuation day | open | - |
| Q34 | does the acute washout cross a period boundary | open | - |
| Q35 | malignancy confirmation and at-risk grain | open | - |
| Q36 | Table 3's 22 rows against the list's 23 | open | - |
| Q3 | 30/60-day pairing windows as sensitivities | reading recorded | `MM_DX_OUTPATIENT_WINDOW_DAYS` (`90`), `OTHER_CANCER_PAIR_DAYS` (`30`), upstream |
| Q19 | bridged-gap days as person-time | reading recorded | - |
| Q21 | calendar months or day counts | reading recorded | `MONTHS_AS` (`days`) |
| Q23 | which pregnancy window | reading recorded | `PREGNANCY_WINDOW` (`study_period`), upstream |
| Q25 | do denied claims count | reading recorded | `CLAIM_STATUS` (`all`) |

The answered questions (Q1, Q4, Q5, Q7-Q10, Q12, Q14, Q16-Q18, Q20, Q22, Q24,
Q26) are under "Answered".

## Blocking - a number moves

### Q2. Does the outpatient arm of the MM diagnosis use the broad code set?

> "At least one inpatient medical claim with a diagnosis code for MM in any position
> (any ICD-9-CM = **203.0x** or ICD-10-CM code = **C90.0x**) or ≥ 2 outpatient medical
> claims **for MM** in any position on the claim, on separate days within 90 days" — §7.2.1.1

The strict set is attached to the inpatient arm; the outpatient arm says only
"for MM". Broad adds 203.1x (plasma cell leukaemia), 203.8x, C90.1x and C90.2x
(extramedullary plasmacytoma).

**Reading meanwhile:** the cohort build requires the strict prefix on the
inpatient arm only, and the outpatient pair accepts any code on `mm_dx.csv`.
The production file carries only the eight strict codes, so both arms are
strict in practice and the broad reading is a code-list edit.

**Worth:** forty myeloma-adjacent codes are present in the CDM. The choice that
matters most is within the strict family: whether C90.01 (in remission) and
C90.02 (in relapse) qualify as the incident diagnosis decides whether a
prevalent patient enters as newly diagnosed.

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

X1 excludes *"≥ 1 medical or pharmacy claim for **any MM oncology therapy**"* in
the 12-month baseline. Dexamethasone is prescribed for many non-MM reasons.

**Reading meanwhile:** the cohort build drops `DEX`, `DEXA`, `DEXAMETHASONE`,
`PRED` and `PREDNISONE` from the prior-therapy scan. The LOT engine excludes
steroids everywhere (`../lot/LOT_RULES.md` §2.1), so the question is only about
the exclusion scan. It is moot on the production code list, which carries none
of those abbreviations; it becomes live when Annex 2's list is loaded, because
the SOC categories are dexamethasone-containing regimens and a steroid under an
abbreviation the guard does not name passes it silently.
`<prefix>NDMM_INDEX_AGENTS` shows every `CL_MED_ABBR` and whether a run let it
set an index, so the first run on the new list answers that.

**Worth:** of 80,398 members with any baseline treatment claim, 12,033 have a
steroid J-code, 3,489 an unambiguous myeloma agent, and **10,466 a steroid and
no myeloma agent** - three times as many decided by the steroid reading as by
the clear-cut one.

**Ask:** confirm steroids alone do not trigger X1, and confirm the steroid
abbreviations against the list Annex 2 supplies.

### Q13. Does disenrollment censor follow-up?

> "The patient **follow-up period** will be defined as the period starting from the
> index date... until the **end of continuous enrollment** or end of study period or
> death, whichever occurs first." — §7.1

`../lot/LOT_RULES.md` §7.6 says "Disenrollment is not censoring", and the LOT
engine's primary columns follow it. TTNT, TTD and OS censor "at their follow-up
end date", so every median and landmark estimate differs between the readings.

**Reading meanwhile:** `CENSOR_AT_DISENROLLMENT=TRUE`, the protocol's reading:
`S_PERIODS.FU_END` ends at the end of the enrolment span covering the cohort's
own index. `FALSE` gives the engine's reading as the sensitivity. The engine
computes both (`LOT_BASE_END_DT_CE_SENS`, `LOT_BASE_END_REASON_CE_SENS`), so the
question is only which is primary.

**Worth:** the setting decides the follow-up of up to 30,392 members (29%),
while the 30-day bridging rule touches only 6,221.

| | members |
|---|---|
| any myeloma patient | 105,125 |
| contiguous re-enrolment only, no real gap | 61,526 |
| **a bridged gap of 1–30 days** | **6,221** |
| **a break of more than 30 days** | **30,392** |
| mean length of those breaks | **1,361.6 days** |

A mean break of 3.7 years says these are people who left the plan and came back
years later, not administrative lapses. The break counts are upper bounds: the
measurement merged spans on the immediately preceding row, where
`build_enroll_spans()` merges on a running `max(ELIGEND)`, and 11,986 myeloma
members (11.4%) have overlapping enrolment rows, each nested span of which the
simpler merge reads as a gap.

**Ask:** confirm follow-up ends at disenrollment, and that this is the primary
analysis rather than a sensitivity.

## Blocking - a definition cannot be built without an answer

### Q15. Annexes 2, 3, 6 and 7 are outstanding

- **Annex 2** - eligible/expected MM therapies and SOC regimen categorisation.
  I3 and the `soc` and `patterns` modules need it.
- **Annex 3** - ICD-10-CM code lists for the Table 3 conditions, the secondary
  malignancy categories, the subgroup conditions and the
  healthcare-utilisation definitions. Objectives 1-3 cannot be computed without
  it.
- **Annex 6** - the LOT algorithm, to reconcile against `../lot/LOT_RULES.md`.
- **Annex 7** - the Kim CFI algorithm and code lists, or confirmation frailty is
  out. `FRAILTY` stays off until then.

The rest of Primary Objective 1's Table 4 rows and the head of Primary
Objective 2 cannot be read in the protocol (`VARIABLES.md` "4. Primary
Objective 1 — baseline characteristics (Table 4)"); a legible copy of that section closes it. The file-by-file ask
is `DATA_MAPPING.md` "What is still to be authored".

### Q11. How is an emergency department visit identified?

The protocol names "Emergency visits" as an outcome (§7.3.2, §7.8.1) and never
defines it, and the CDM has **no ED flag**.

**Reading meanwhile:** `ED_DEFINITION=revenue,pos` - revenue codes 045x/0981 or
`POS = '23'`; `cpt` (99281-99285) is the third construction. The codes go in
`hcru.csv`, which is not filled. `ED_ADMITTED=both` counts an ED claim that
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

The widest construction is 37% above the narrowest, and they overlap far less
than their totals suggest - revenue and CPT agree on 229,938 of the ~400,000
each finds (facility against professional claims). 162,211 visit-days (32.5%
of the union) became admissions, so `ED_ADMITTED` is worth one visit in three.

**Ask:** which construction, and is an ED visit that becomes an admission
counted as an ED visit, a hospitalisation, or both?

## Needs a decision, but does not block a first build

### Q27. Which route defines "a MM diagnosis in first or second position"?

§7.8.1 defines an MM-related hospitalisation by *"a MM diagnosis in first or
second position"* without saying of what: **`CONFINEMENT.DIAG1` / `DIAG2`**
(the bundled stay record, five positions), or **`MED_DIAGNOSIS.DIAG_POSITION` 1
or 2** on a claim carrying that `CONF_ID` (twenty-five positions, line-level;
the route business rule 13 documents for "diagnoses reported within a
hospitalization").

**Reading meanwhile:** `MM_HOSP_POSITION=confinement`; `claim_positions` is the
other route. Both are emitted and executed by the test suite.

**Worth:** the largest unresolved swing in the package's own SQL. Over 241,362
stays of myeloma patients since 2018:

| | stays |
|---|---|
| route A - MM in `CONFINEMENT.DIAG1/DIAG2` (the default) | 32,508 |
| route B - MM in `DIAG_POSITION` 1-2 on a claim carrying the `CONF_ID` | 65,206 |
| found by route A only | 1,206 |
| found by route B only | 33,904 |
| MM only in `CONFINEMENT.DIAG3-5` - neither route counts these | 33,978 |

**Ask:** confirm the confinement record's own first two diagnoses are meant.

### Q28. What is `DOD.MBR_MATCH_TYPE`, and should low-confidence deaths count?

`MBR_MATCH_TYPE varchar(1)` is covered by no Optum document. If it grades how a
member was linked to the death record, overall survival is overstated by
including low-confidence links and understated by excluding them. Neither build
filters on it. It has two values, no nulls: `2` 6,782,785 rows (58.93%), `1`
4,727,043 (41.07%) - a binary flag; which is the confident link cannot be
derived from the data. Two findings bear on it: 33,800 of 93,245 members
(36.2%) carry a death record, **348 have a death date before their index date**
and **up to 9,705 one before their last claim** - upper bounds, since the
measurement imputed the 15th and a same-month death and claim can be flagged
wrongly.

**Ask (to the vendor):** what the values mean, and whether any should be
excluded.

### Q29. Does the small-cell floor exempt SOC strata?

> §7.2.3: "Stratifications with <25 patients will not be performed or may be
> regrouped due to low volumes."

> §7.8: "If there are less than 25 patients in a particular stratifications or
> cohort, analyses will not be conducted **(unless specific to SOC)**."

§7.8 does not say which analyses are "specific to SOC". **Reading meanwhile:**
§7.2.3 - every cell under 25 is suppressed, SOC included
(`R/modules/11_release.R`). Suppressing more than required loses a stratum the
protocol may permit; the other way round publishes one it forbids. It matters
most for `S_SOC`. An exemption would be one predicate in `SUPPRESSION_SPEC`,
mirrored in TFLS.

**Ask:** whether the SOC exemption applies, and if so to which tables.

### Q30. Which diagnosis date do the diagnosis-anchored rows hang on?

Table 4's year of diagnosis and time from diagnosis to follow-up end, Table 5's
time from diagnosis to 1L and I2's age at diagnosis need one date. The cohort
build records the qualifying diagnosis (`MM_DX_DT`, the claim that satisfied
I1); Table 4's footnote says *"first medical claim for MM within the baseline
period on or prior to 1L"* - a different claim for a patient diagnosed more than
a year before therapy.

**Reading meanwhile:** `DX_DATE_SOURCE=cohort_mm_dx` - one date for I1, I2,
Table 4 and Table 5, needing no code list. `baseline_first_claim` is Table 4's
literal reading and needs `mm_dx.csv` (`VARIABLES.md` "1. Cohort and exposure
variables").

**Ask:** confirm the qualifying diagnosis, or that Table 4's footnote is meant
to redefine it.

### Q31. Over which window is the secondary 2L cohort's malignancy prevalence taken?

§7.4.1.2 and §7.8.4: *"all malignancies occurring after diagnosis but prior to
2L will be tabulated as the background prevalence"*; §7.8.1's 2L bullet says
*"during baseline"* - the 12 months before the 2L index. **Reading meanwhile:**
`MALIG_PREVALENCE_WINDOW=since_diagnosis`; `baseline` is the alternative. The
person-time follows the window.

**Ask:** which window.

### Q32. Which lines are a "treatment sequence among those with a malignancy"?

Table 4: *"Tabulation of the top 5–10 sequences among those with a malignancy
occurring after treatment"* - the therapy received **when** the malignancy
appeared, or given **after** it? **Reading meanwhile:** none is chosen;
`S_MALIGNANCY_SEQUENCES` carries `to_malignancy`, `after_malignancy` and
`all_observed` on `LINES`, each with its own denominator, in scopes
`after_index` and `after_2l`.

**Ask:** which reading the shell should print.

### Q33. On which day is a line "discontinued" when a new agent or transplant ends it?

The engine ends a line the **day before** an added agent or a line-opening
transplant (`../lot/LOT_RULES.md` §7.1), because the event opens the next line;
a run-out ends the line **on** the confirmed run-out. **Reading meanwhile:**
`PROTOCOL_DISCON_DT` is the run-out day for `DISCONTINUATION` and the
introduction day (engine end + 1) for `MED_ADD`, `CART_INIT`, `SCT_AUTO`,
`SCT_ALLO` and `SCT_CART`, so TTD and TTNT date the same event on the same day.
`SCT_AUTO_CONT` - an autologous transplant inside the line's own induction
window, which consolidates the line and opens no other - is taken as the "all
agents stopped" branch, dated on the transplant, not as a "qualifying SCT".

**Ask:** confirm the introduction day, and that a planned in-window autologous
transplant is not a qualifying SCT event.

### Q34. Does the acute washout cross a period boundary?

§7.3.2: *"a ≥30 day washout between acute events of the same type will be
applied"* - a statement about events, not periods. **Reading meanwhile:** the
chain runs once per cohort over the patient's timeline (baseline start →
follow-up end) and each period takes the counted events dated inside it, kept
on `S_SAFETY_COUNTED` under `PERIOD = TIMELINE`. An infection coded three days
before the index and again five days after it is one event. The chain starts at
the baseline start, so a baseline event is never suppressed by history before
the window.

**Ask:** confirm the washout is measured across the index and across lines.

### Q35. At what grain is a secondary malignancy confirmed, and at what grain is a patient "not at risk"?

Table 4: *"confirmed through the presence of at least 2 diagnosis codes
occurring on separate dates"* - the shared unit (code, Table 2 subtype or
category) is not stated. §7.8.1 names *"malignancies"* as one chronic
condition, while Objective 3 summarises *"according to type"*. **Reading
meanwhile:** confirmation at subtype grain, both codes on or before the
cohort's follow-up end; prior history per category; plus an `(any malignancy)`
row (`VARIABLES.md` "6. Primary Objective 3 — secondary malignancies (Table 4 cont.)"). A malignancy is attributed to a
line only inside the treatment window for the rates, and to *"the LoT after
which"* it fell (`LOT_AFTER_WHICH`) on the occurrence table.

**Ask:** the confirmation grain, and whether prior history of one category
removes a patient from the others.

### Q36. Table 3 lists 22 conditions; the code list carries 23

`safety_events.csv` carries corneal ulcer and keratopathies, and Parkinson's
disease and other movement disorders, as two rows each. Two rows are typed
*"Acute or chronic"* / *"Acute/Chronic"* by the protocol itself, which names
two counting rules at once, so the safety module stops on them until they are
typed. Table 3 also types more conditions chronic than §7.8.1's list; the code
list's own column governs. Table 4's pages 33–34 cannot be read in the protocol
(`VARIABLES.md` "4. Primary Objective 1 — baseline characteristics (Table 4)").

**Ask:** confirm the 23-row list, type the two dual-typed conditions, and supply
a legible copy of pages 33–34.

## Readings recorded - measured, and too small to decide

The protocol leaves these open, but the data has priced the difference and
found it small. Each is a setting that produces the alternative where one
exists.

**Q3. 30- and 60-day outpatient pairing windows.** The MM diagnosis pairs two
outpatient claims within 90 days, the only window the protocol names
(`MM_DX_OUTPATIENT_WINDOW_DAYS=90`, the cohort build's `OUTPATIENT_WINDOW`
setting, so 30 or 60 is a cohort rebuild). The other-cancer exclusion pairs within the protocol's 30 days,
fixed in the cohort build's code (recorded as `OTHER_CANCER_PAIR_DAYS=30`).
**Worth:** 16,171 members have a paired other cancer within 30 days and 16,760
within 60 - 589 more; 1,108 members have a cancer category whose only pairing
sits in the 31-60 day band.

**Q19. Bridged enrolment-gap days as person-time.** Counted as covered
person-time: `BASELINE_PY` and `PERIOD_PY` are window lengths, so no setting
carves them out. The protocol and both Optum documents are silent. **Worth:**
bridged gaps of 30 days or fewer carry 109,679 days across the myeloma
population, about 300 person-years (an upper bound, as for Q13), against
denominators in the tens of thousands. 987 gaps sit at exactly 30 days against
98 at 29, so the threshold lands on a plan-renewal boundary and moving it by a
day is not neutral.

**Q21. Calendar months or fixed day counts.** A month is a fixed day count
(`MONTHS_AS=days`): 12 months is `[index - 365, index - 1]` and 3 months is 90
days, because `add_months()` gives two patients indexed a day apart different
windows, and 90 is the shortest three calendar months and so the more
permissive reading. `MONTHS_AS=calendar` produces the other. **Worth:**
`add_months(index, -12)` and `index - 365` land on the same date for 73,321
members and one day apart for 19,924, never two.

**Q23. Which pregnancy window.** The whole study period, as X3 says
(`PREGNANCY_WINDOW=study_period`); the alternative is the patient's own baseline
and follow-up. **Worth:** 307 members have a proxy pregnancy code anywhere in
the study period and 99 in their own baseline year - 270 more, 0.29%. The codes
are proxies until Annex 3, so the number will move; the reading will not.

**Q25. Do denied claims count.** All claims count (`CLAIM_STATUS=all`). Neither
the protocol nor the business rules mention `PAID_STATUS`, and the cohort build
does not filter on it, so filtering here alone would make this package disagree
with its own cohort table. `paid_only` is the sensitivity, and it is narrower
than its name: it filters the ED arm of `hcru` and nothing else - not the I5
follow-up claims, the MM-hospitalisation subquery, `CONFINEMENT` or `RX` (no
paid status, and `STD_COST` cannot stand in). Denied pharmacy claims cannot be
identified in this extract at all, which belongs in the SAP as a limitation.
`P`/`D` and `PAID`/`DENIED` are both matched, and a null is not treated as
denied. **Worth:** 17.42% of medical lines among myeloma patients are denied,
but denials concentrate in ordinary outpatient claims - 21.65% of 70,523,049
other outpatient lines, 7.52% of 1,298,697 ED-shaped lines, 5.83% of 9,882,844
inpatient-linked lines. 2,630 of 499,272 ED patient-days (0.53%) have every line
denied: `paid_only` removes one ED visit in 200. **Ask (optional):** whether the
study intends to include denied claims, and if not, whether the exclusion
should reach beyond emergency visits.

## What each decision is worth

Measured on the CDM. The proxy population is **105,125** members with a C90 code
since 2016, of whom **93,245** have a first C90 code on or after 01 Jan 2018 -
no age, enrolment or exclusion criteria, so read every number as an order of
magnitude, not a cohort count.

| # | question | the readings differ by |
|---|---|---|
| Q27 | which route makes a stay MM-related | **32,508 vs 65,206 stays - 2×** |
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

**Continuous enrolment is the largest attrition step.** Of the 93,245, 57,933
(62.1%) pass 12 months of continuous enrolment before index and 35,312 are
lost - more than any exclusion, and a criterion this package re-applies itself
(I4/N2). The pass rate is a lower bound, for the reason given under Q13.

The cohort build writes these alternatives into the warehouse on every run
(`../ndmm/README.md` "The sensitivity tables"):

| table | what it prices | bears on |
|---|---|---|
| `<prefix>NDMM_FU_CE_COUNTS` | cohort size at 0, 30, 60 and 90 days and at three calendar months of follow-up enrolment, applied row marked | the cohort build's follow-up window, and Q21 |
| `<prefix>NDMM_PREG_WINDOW_COUNTS` | both pregnancy-window readings | Q23 |
| `<prefix>NDMM_INDEX_AGENTS` | every `CL_MED_ABBR`, whether the run let it set an index, and how many patients it set one for | the panobinostat / elotuzumab bars, and Q6 |
| `<prefix>NDMM_OTHER_MALIG_GROUPS`, `<prefix>NDMM_OTHER_MALIG_GRAIN` | the pairing grain, per category | the X2 readings (`IE_CRITERIA.md` "X2. Another cancer in the 1L baseline") |

## Answered

| Q | answer | the setting or rule it fixed |
|---|---|---|
| Q1 | The study period starts **01 Jan 2018**, the §7.1 body text; the figures' 01 Jan 2016 is a leftover. The cohort build requires the qualifying diagnosis inside the study period, which drops patients diagnosed in 2016-2017 whose 1L starts in 2019 (17,288 members were first diagnosed then) - worth the author's confirmation | `STUDY_START=2018-01-01` and the 1L floor `2019-01-01`, the bundled defaults of `ndmm/`, `lot/engine/` and this package; a cohort built to another window is refused (`BINDING_UPSTREAM_SETTINGS`) |
| Q4 | "With medical and pharmacy benefits" is satisfied by construction: no benefit indicator exists, and §7.5 says all patients have both | no predicate (`DATA_MAPPING.md` "7. Medical and pharmacy benefits") |
| Q5 | All 93,245 members have a medical claim on their index date, so *"at least one claim from the index date"* excludes nobody; a claim after the index would exclude 1,012 (1.1%) | `FU_EVIDENCE_RULE=claim_from_index` |
| Q7 | Prior malignancy is permitted in the secondary 2L cohort (§7.8.1: *"because prior history of malignancy during baseline is permitted per eligibility criteria, the baseline prevalence of any malignancy will be summarized"*). 17,964 members (19.3%) carry another cancer (any C-code other than C90 and C44) in their baseline year | SEC2L drops X2 (`SEC2L_APPLY_OTHER_CANCER=FALSE`); it needs a wide input (`SEC2L_INPUT_IS_WIDE`) |
| Q8 / Q26 | `DOD` joins on `PATID`: all 11,509,828 `DOD` patients match the enrolment table (`bigint`, same domain), so the business-rules note does not hold here | overall survival is reportable |
| Q9 | The deployed `MEMBER_ENROLLMENT` carries `STATE` and no `REGION`; 5.7% of members hold two `STATE` values, none three. Reopen only if a refresh brings `REGION` | `REGION_SOURCE=state_crosswalk`, read from the row Q16 selects; `region_column` refused at preflight |
| Q10 | `RACE` is `W`, `B`, `A`, `U` or null; `ETHNICITY` `N`, `H`, `U` or null; `RACE_SOURCE` always `Self-Reported`. Race is null or `U` on about 42% of rows, ethnicity 36%, so Table 4 will be heavily Unknown and should say so | the demographics mapping (`DATA_MAPPING.md` "9. Variable → source, analysis variables") |
| Q12 | No line starts before 2019, so the 2017 and 2018 columns of "Types of SOCs by line" are empty by construction; the 2017 bound is a leftover | `S_SOC.LOT_START_YEAR`; the table is a count over it |
| Q14 | Both sentences hold, as two windows: §7.1's baseline excludes the index day (safety, HCRU), §7.8.1's comorbidity baseline includes it (Charlson). Every member has an index-date claim, so the distinction is real; on the 12-month enrolment criterion it changes one patient | `BASELINE_INCLUDES_INDEX=FALSE`, `COMORBIDITY_BASELINE_INCLUDES_INDEX=TRUE` |
| Q16 | "At index" is the enrolment row covering the index date, ties to `ELIGEND` desc, `ELIGEFF` desc, `PAT_PLANID`; else the baseline row ending nearest it. 11,986 myeloma members (11.4%) hold overlapping rows on different `PAT_PLANID`s, which disagree on `STATE` for 473 and on `BUS` for 388, never on `RACE` | `ENROL_ATTR_AT=index_span` (`latest_span` the comparison); `S_DEMOGRAPHICS.ATTR_SOURCE` |
| Q17 | `MED_PROCEDURE.PROC` is the ICD procedure code and `MEDICAL.PROC_CD` CPT/HCPCS; business rule 5 is a transcription error | `DATA_MAPPING.md` "MED_PROCEDURE" |
| Q18 | The 2022 business rules are not current: they predate the V9.0 dictionary and are wrong on race-on-SES and the DOD join. Use them for join keys and the fourteen rules the dictionary corroborates. Worth asking whether a newer document exists and whether the inpatient/outpatient construction has been revalidated against V9.0 | - |
| Q20 | Annex numbering: §7.3.2 and §7.8.5 cite Annex 3 for code lists and §7.8 Annexes 4 and 5 for the shells, agreeing with Annex 1; the contents page has three entries rotated. Send the authors the correction, with the typos "ALGORITHIM" and "FRAILITY" | the docs follow the body text |
| Q22 | No year-only death dates: all 11,509,828 `YMDOD` values are `YYYYMM` (200005 → 202603) | death dated on the 15th of a known month, ±15 days |
| Q24 | 530 claim rows of ~16.4 billion carry an `ICD_FLAG` naming neither family | reported, not gated |

## Settled, not questions

| point | where it is settled |
|---|---|
| The thresholds are as written: gaps ≤ 30 days, ≥ 1 inpatient or ≥ 2 outpatient other-cancer claims, age ≥ 18, ≥ 2 outpatient MM claims | `IE_CRITERIA.md` |
| Discontinued 1L, then a 12-month baseline before 2L/3L | `IE_CRITERIA.md` "2. Study periods and windows" |
| The melphalan short-course cap is `≤ 28` days, inclusive; a confirmed melphalan course beats the MAP fold-in | `../lot/LOT_RULES.md` §4.7 |
| Melphalan mono when melphalan came with a steroid | `../lot/LOT_RULES.md` §2.1 |

## Known deviations and gaps

Where the build does not simply do what the protocol, the Optum dictionary or
the business rules say: what the source says, what the build does, and what
governs it. Rows marked "no question yet" are readings not yet put to the study
team. Everything not listed here matches, as `IE_CRITERIA.md` and
`VARIABLES.md` state it.

| item | the source says | the build does | governed by |
|---|---|---|---|
| I3 therapy list | Annex 2 lists the eligible 1L therapies | Annex 2 is outstanding; the production `cl_mma_codelist.csv` stands in, and anything Annex 2 restricts to later lines has to be barred through the cohort build's `NDMM_INDEX_EXCLUDED_ABBRS` | Q15 |
| X1 steroids | any MM oncology therapy | the cohort build drops steroid rows from the scan (nothing on the production list) | `PRIOR_TX_DROP_STEROIDS`, Q6 (upstream) |
| "Inpatient medical claim" | never defined | the cohort build uses vendor approach 1 (POS/TOS) OR approach 2 (a confinement) | `DATA_MAPPING.md` "5. Identifying inpatient vs outpatient" (upstream) |
| N2 enrolment on the index day | 12 months of CE before the 2L/3L index | N2 (and I4 re-applied) needs the span covering the index date itself, so a patient enrolled through the day before the index but not on it fails | no question yet: test a span ending on or after index − 1, or make index-day enrolment its own funnel step |
| Months under `MONTHS_AS=calendar` | 12 months, 3 months | every window follows the setting except the N2 enrolment test, which stays in days | `MONTHS_AS`, Q21 |
| Secondary 2L cohort | all 2L initiators ≥ 2020 whenever their 1L fell, prior malignancy permitted | not buildable from the bundled cohort; needs a wide cohort and LOT run; X2 is waived only over one | `SEC2L_INPUT_IS_WIDE`, `SEC2L_APPLY_OTHER_CANCER`, Q7 |
| Secondary 2L in the shells | all objectives apply to the secondary cohort | the T1, T2 and T4-type shells have no SEC2L column | TFLS shells |
| Overall attrition | patient attrition depicted and tabulated | `S_ATTRITION` opens where the cohort build's funnel ends; no table stitches `NDMM_ATTRITION`, `LOT_ATTRITION` and `S_ATTRITION` into one funnel with the protocol's labels | - |
| Time-to-event analysis set | ≥ 3 months of potential follow-up | read as time in the database (index + 90 ≤ `STUDY_END`, or death before), not observed enrolment; the alternative is one more arm in `tte_eligible_sql()` | no question yet |
| Diagnosis date | Table 4: first MM claim in the baseline on or before 1L | the cohort's qualifying diagnosis by default | `DX_DATE_SOURCE`, Q30 |
| Charlson | Quan 2011, MM-adjusted | conditions, weights and hierarchy come without codes; the ICD-9-CM and ICD-10 codes, to the full-code level the CDM stores, are to be written; whether C90.1-C90.3 count as MM for the adjustment is undecided | `charlson_quan2011.csv`, `mm_dx.csv` |
| Frailty | Kim CFI, ≥ 0.25 frail | waits on Annex 7; matches diagnosis codes only, so the intercept (an all-patient constant) and non-diagnosis features (`MED_PROCEDURE.PROC`, `MEDICAL.PROC_CD`/`BILL_PROC_CD`, `RX.NDC`) must be added first | `FRAILTY`, `FRAILTY_FRAIL_CUTOFF`, Q15 |
| SOC categories | §7.2.2's categories, Annex 2's regimens | the categories come without agents; the precedence between categories (`SOC_PRECEDENCE`) is this package's own, for the study team to confirm | Q15 |
| SOC strata | results by SOC category | wait on Annex 2 | Q15, Q29 |
| Age strata | Table 1 row 2 names 1L and 2L | by-age strata are written for every cohort, 3L included, and every stratified table; either skip them for 3L or report them as produced and not published | - |
| Neuropathy and frailty strata | Table 1 rows 3-4 | wait on Annexes 3 and 7, both switches off; the T5c neuropathy and frailty columns cannot be filled | `COMORBID_SUBGROUPS`, `FRAILTY`, Q15 |
| Lung and any-event subgroups | §7.2.3 lists lung parenchymal disease and any event of interest | Table 1 has neither; which governs is open. If §7.2.3, T5c needs a lung column and an any-domain baseline flag from `S_SAFETY_COUNTED` (`PERIOD = BASELINE`); the any-event subgroup needs Annex 3 | Q15 |
| Hospitalisation and ER-visit bands | the shells band them 0, 1, 2, 3, 4+ | `S_HCRU_RATES` carries no bands; per-patient counts are in `S_HCRU_EVENTS` | - |
| Safety and malignancy codes | Annex 3's ICD-10-CM lists | outstanding; the lists come with the concepts and no codes, and a run stops on an empty list rather than reporting zero | Q15 |
| Dual-typed conditions | toxic liver disease "Acute or chronic", hepatic failure "Acute/Chronic" | the safety module stops until they are typed | Q36 |
| Chronic set | §7.8.1 names nine chronic conditions; Table 3 types more | the list's own column governs; the §7.8.1 names are cross-checked | Q36 |
| Baseline numerator | same-day claims one event, > 1 day apart distinct | the acute washout applies at baseline too; the other reading counts every distinct service day | no question yet |
| Severe infection | "resulting in hospitalization" | read from admissions (`setting=inpatient`, a `CONF_ID`); present-on-admission, and `CONF_ID` alone against POS/TOS, are readings not yet put | no question yet |
| MM-related hospitalisation | "first or second position" | the confinement record's `DIAG1`/`DIAG2` | `MM_HOSP_POSITION`, Q27 |
| Emergency visits | "Emergency visits", undefined | revenue code or POS 23; an admitted ED claim counts as both | `ED_DEFINITION`, `ED_ADMITTED`, Q11 |
| Stays overlapping the baseline start | stays beginning before the baseline or ending after it are counted at the visit level | assigned by admit date only, so a stay admitted before the baseline start is not a baseline event; the alternative counts a stay whose admit-discharge span meets the baseline | no question yet |
| Denied claims | silent | `CLAIM_STATUS=paid_only` filters only the ED arm; the safety, malignancy, comorbidity and follow-up-claim reads ignore it | `CLAIM_STATUS`, Q25 |
| Illegible Table 4 rows | pages 33-34 | read from §7.8.1's counting rules | Q15, Q36 |
| Bridged gap days | person-time in the baseline | counted as person-time | Q19 |
| Malignancy confirmation | two codes on separate dates, unit unstated, "follow-up period" | subtype grain, both codes by `FU_END`; prior history per category plus `(any malignancy)`; attributed to a line only inside its treatment window for the rates | Q35 |
| Secondary 2L malignancy prevalence | after diagnosis and before 2L (§7.4.1.2, §7.8.4) vs during baseline (§7.8.1) | since diagnosis | `MALIG_PREVALENCE_WINDOW`, Q31 |
| Treatment sequences | top 5-10 among those with a malignancy | three readings written, none chosen | Q32 |
| In-window autologous transplant | a qualifying SCT event ends a regimen | `SCT_AUTO_CONT` is the "all agents stopped" branch, dated on the transplant | Q33 |
| Unconfirmed run-out | discontinuation ends TTD | a run-out within 90 days of the end of observation with no later trigger is not `DISCONTINUATION`; the line ends `DEATH` or `STUDY_END` (`../lot/LOT_RULES.md` §5.3). It moves end reasons and dates, most in lines nearest the data cutoff | LOT engine |
| Follow-up end | ends at disenrolment (§7.1) | this package ends it there by default; the LOT engine's primary reading does not | `CENSOR_AT_DISENROLLMENT`, Q13 |
| LOT regimen: "received" | therapies received within the window | an agent joins only when an episode starts in the window, so an agent taken without a break since an earlier line never appears in a later regimen; open in the engine | `../lot/LOT_RULES.md` §2.3, §4.2 |
| LOT regimen: "pre-specified MM therapies" | Annex 2's therapies | steroids are excluded everywhere; if Annex 2 counts dexamethasone, the regimens will not match it | `../lot/LOT_RULES.md` §2.1 |
| LOT window length | 60 days (1L), 30 days (later) | the window closes early at `REGIMEN_CUTOFF_DT`, the day before an allogeneic transplant (any line) or a CAR-T (lines 2-5; line 1 only with `apply_cart_induction_rule` off) | `../lot/LOT_RULES.md` §3.3 |
| LOT window on special lines | 30 days for each subsequent line | 45 days on a CAR-T-started line (`cart_consolidation_days`); an allogeneic-started line spans one day and carries no regimen | `../lot/LOT_RULES.md` §4.2, §4.6 |
| Biosimilars | "a new MM agent that was not part of the previous LOT regimen" | a permissible substitute is the same agent both ways and never starts a line; one received in the window is listed under its own abbreviation, and whether the pair should collapse is open | `../lot/LOT_RULES.md` §4.4, §3.2 |
| Same-day line starts | "the earliest of" | the date decides; same-day starts break `SCT_ALLO > CART > SCT_AUTO > MED`, which sets only the line's start type | `../lot/LOT_RULES.md` §4.5 |
| CAR-T in line 1 | CAR-T starts a line | a CAR-T inside line 1's 60-day window, while line 1 runs, is part of line 1 | `../lot/LOT_RULES.md` §6.4 |
| A drug of the previous regimen | not stated | never starts a line, so a same-drug re-challenge after any gap - a three-month holiday included - is one line and not a discontinuation; agreed with the study team, belongs in Annex 6 | `../lot/LOT_RULES.md` §4.3 |
| Short melphalan course | not stated | a short melphalan course outside induction does not start a line; agreed, belongs in Annex 6 | `../lot/LOT_RULES.md` §4.7 |
| A drug returning from the previous line | not stated | joins the line it returns in; agreed, belongs in Annex 6 | `../lot/LOT_RULES.md` §4.8 |
| Days supply | line construction delegated to Annex 6 | neither vendor document states a days-supply rule | Q15 (Annex 6) |
| CDM columns | the data source (§7.5) | no preflight describes the CDM tables a run reads (bar `REGION_SOURCE=region_column`, refused), so a missing column is found by Spark mid-run | - |
| `YRDOB = 0` | age ≥ 18 by calendar year; missing data dropped | the dictionary documents no sentinel and 614 rows carry 0; this package returns a NULL age and an Unknown band; I2 is the cohort build's | upstream |
| Death date | death ends follow-up | the V9.0 dictionary has no death table; the date is the cohort build's, from `YMDOD`, month precision | upstream, Q28 |
| Thrombocytopenia, anaemia | "dependent on data availability"; lab values may be used | diagnosis-defined only; `LABRESULT` is not read | - |
| Rate interval in the cell | a 95% interval with each rate | TFLS writes it to the filled table's `LOW`/`HIGH` columns, not the cell text (`stat_rate()`), and no footnote names the method | TFLS |
| HCRU rate intervals | intervals with the utilisation incidence rates | HCRU rates carry none (`R/modules/07_hcru.R` does not apply `rate_ci_sql()`); add them, or drop the interval wording from the HCRU shell notes | - |
| LOS statistics | mean, SD, median, IQR, min, max for continuous variables | `S_HCRU_RATES` carries mean and median LOS only | - |
| Missing values | the number with unknown/missing values reported | the shells have Unknown rows for race, ethnicity and region but none for sex, age band or insurance, although the tables carry Unknown there, and no "Missing, n" row under a continuous variable | TFLS shells |
| KM landmarks | at risk, with an event and censored, and survival at landmarks | survival, events and censored are reported (`km_prob`, `km_events`, `km_censored`); the number at risk at each landmark is not | TFLS |
| KM curves | tables with KM curves | the dashboard draws them (`plot_km()`); TFLS writes tables only | - |
| Time-to-event by SOC | by SOC category | TFLS groups regimens by its `regimen_classes.csv`, not aligned with §7.2.2's categories; align it or record the regrouping as an Annex 2 decision | Q15 |
| Sankey | a Sankey of switches between regimen categories | `S_SWITCH` carries the transitions with `(died)` and `(no further therapy)` as terminal nodes; no Sankey renderer is included, it has no percentage column, and the terminal node does not separate discontinued from censored | - |
| Treatment attrition | received next, discontinued, lost to follow-up, died | `lost_to_followup` holds both patients censored at study end on therapy and patients who disenrolled on therapy | - |
| SOC floor exemption | "(unless specific to SOC)" (§7.8) | every stratum under 25 is suppressed, SOC included | Q29 |
| Floor basis | fewer than 25 patients in a stratification or cohort | a rate is suppressed on `N_AT_RISK`, patients still at risk, which is stricter than the stratum's size | - |
| Cell floor | as above | TFLS also floors cell statistics (`TFLS_COUNT_FLOOR_STATS`), stricter than the package's denominator floor; open whether a cell-level rule is a data-licence requirement | - |
| R version | analysis in R 4.5.2 | the R version is not recorded in `S_RUN_METADATA` or the TFLS caption | - |
