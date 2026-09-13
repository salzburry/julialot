# Open questions for the study team

Twenty-three decisions the protocol and the Optum documentation do not settle,
each of which changes a count or a definition. Ordered by how much they change.
Every one has two defensible readings and the build has to pick one; the reading
it takes meanwhile is a setting in `study223926/config.csv`.

Q8, Q10, Q22, Q24 and Q26 are closed and their numbers are recorded under
*Settled against the warehouse* below. Q4 and Q17 were settled by the cohort
build and are left in place with the answer. Q13 is answered.

Sixteen of the rest carry a measured price - how many patients the decision
moves - under *What each decision is worth*. The largest two are **Q27 (a
factor of two)** and **Q25 (17.4% of all medical claim lines)**.

Q12, Q15 and Q20 cannot be answered from the data at all; they need the
protocol author or the annexes themselves.

---

## Blocking — a number moves

### Q1. Does the study period start 01 Jan 2016 or 01 Jan 2018?

The body text (§7.1) says:

> "The study period will span from **01 Jan 2018** through 31 Mar 2026"

Figure 1 and Figure 2 are both labelled **"Study start
01 Jan 2016"**.

This is not cosmetic. Criterion I1 says the qualifying MM diagnosis must fall
"during the study period", so a 2018 start drops every patient whose only
qualifying diagnosis is 2016-2017 — including patients whose 1L is in 2019 and who
would otherwise be in. It also decides whether ICD-9 codes are ever in scope (ICD-10
began Oct 2015, so a 2018 start makes the ICD-9 arms of every code list dead).

The cohort build uses `STUDY_START = 2016-01-01`, settled against the June 2026
protocol. Mechanically the change is cheap: the window is a **run argument**,
not a `CONTRACT` setting, and `check_cohort_window()` makes a cohort/vintage
mismatch fatal rather than silent. The `2026q1` vintage is the same tables and
column names as `2025q2` with data extended through 2026-03-31, so moving the
window needs no re-validation.

**Ask:** which is correct, and does the MM diagnosis have to fall inside the study
period or merely on or before the 1L index?

### Q2. Does the outpatient arm of the MM diagnosis use the broad code set?

§7.2.1.1:

> "At least one inpatient medical claim with a diagnosis code for MM in any position
> (any ICD-9-CM = **203.0x** or ICD-10-CM code = **C90.0x**) or ≥ 2 outpatient medical
> claims **for MM** in any position on the claim, on separate days within 90 days"

The strict code set is attached to the inpatient arm. The outpatient arm says only
"for MM". An earlier reading of the same criterion took inpatient = strict
`203.0x`/`C90.0x` and outpatient = broad `203.x`/`C90.x`. The production
`mm_dx.csv` holds only the eight strict codes (`CODELISTS.md` §1).

Broad adds 203.1x (plasma cell leukaemia), 203.8x, C90.1x, C90.2x
(extramedullary plasmacytoma) — a materially larger cohort.

**The build already has the two-arm mechanism**, so this is a code-list edit, not a
code change: strict is required only of the inpatient arm, and the outpatient pair
accepts any code on `mm_dx.csv`. Today that file carries only the eight strict
codes, so both arms are strict in practice. Widening the file is all the broad
reading needs.

**Ask:** strict on both arms, or strict inpatient / broad outpatient?

### Q4. What does "with medical and pharmacy benefits" mean operationally? — **ANSWERED**

Medical and pharmacy benefits are **satisfied by construction**. The extract does
not separate them: `member_enrollment` has 27 columns and none is a benefit
indicator. `ASO`, `BUS`, `CDHP`, `PRODUCT`, `HEALTH_EXCH` and `GROUP_NBR` are plan
structure and funding, not coverage type. A span carries both, so `ELIGEFF`/`ELIGEND`
already express the requirement and a predicate would filter on nothing.

**Do not re-derive this from claims.** Enrolled patients with no pharmacy fill look
like a coverage signal and are not: that count is dominated by short spans and by
patients whose only MM code is a rule-out.

`DATA_MAPPING.md` §7 reaches the same conclusion from the schema, and the
protocol's own §7.5 agrees. **No predicate to write. Closed.**

### Q6. Do steroid-only claims count as "MM oncology therapy" for the prior-therapy exclusion?

Exclusion X1: *"≥ 1 medical or pharmacy claim for **any MM oncology therapy**"* during
the 12-month baseline.

The cohort build drops dexamethasone and prednisone from that scan, on the
reasoning that a steroid claim alone is supportive care and does not make someone
previously treated. The protocol does not say so. Dexamethasone is prescribed for
many non-MM reasons, so including it would exclude patients on the strength of an
unrelated steroid course.

The LOT engine excludes steroids everywhere (`../lot/LOT_RULES.md` §2.1), so this
question is only about the exclusion scan.

**It is moot on today's code list.** The production file carries 26 agents, so 25
can set an index, and none of `DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE`
is in `CL_MED_ABBR` — the steroid drop removes nothing. It stays as a guard
against a later list that carries them.

So no patient is currently affected either way. The question becomes live the moment
**Annex 2's** therapy list is loaded, because the protocol's own SOC categories are
dexamethasone-containing regimens. If a steroid arrives under an abbreviation the
guard does not name, the guard silently stops guarding.
`<prefix>NDMM_INDEX_AGENTS` shows every `CL_MED_ABBR` and whether this run would let it
set an index, so the first run answers it.

**Ask:** confirm steroids alone do not trigger X1, and confirm the steroid abbreviations
against whatever list Annex 2 delivers.

### Q13. Does disenrollment censor follow-up?

§7.1:

> "The patient **follow-up period** will be defined as the period starting from the
> index date... until the **end of continuous enrollment** or end of study period or
> death, whichever occurs first."

`../lot/LOT_RULES.md` §7.6 says **"Disenrollment is not censoring"**, and
`CENSOR_AT_DISENROLLMENT = FALSE` is the primary-analysis setting.

TTNT, TTD and OS all censor "at their follow-up end date". Under the protocol's
wording that date is the disenrollment date; under the current build it is the study
end or death. Every median and every landmark estimate differs.

The engine already computes both readings — `LOT_BASE_END_DT_CE_SENS` and
`LOT_BASE_END_REASON_CE_SENS` carry the censor-at-disenrollment version. So the
question is not whether we can produce it, but **which one is the primary analysis**.
Right now the protocol's reading is the sensitivity.

The setting decides the follow-up of at most 30,392 patients (29%), while the
30-day bridging rule touches only 6,221. The numbers are below.

**Ask:** confirm follow-up ends at disenrollment, and confirm this is the primary
analysis rather than a sensitivity.

---

## Blocking — a definition is unbuildable without an answer

### Q15. Annexes 2, 3, 6 and 7 are outstanding

- **Annex 2** — eligible/expected MM therapies and SOC regimen categorisation.
  Criterion I3 cannot be applied without it.
- **Annex 3** — ICD-10-CM code lists for all 22 Table 3 conditions, the secondary
  malignancy categories, and the healthcare-utilisation definitions. Objectives 1-3
  cannot be computed without it.
- **Annex 6** — the LOT algorithm, to reconcile against `../lot/LOT_RULES.md`.
- **Annex 7** — the Kim CFI algorithm and code lists, or confirmation frailty is out.

The rest of Primary Objective 1's Table 4 rows and most of Primary Objective 2's
are specified in the protocol but have not come through in a form that can be
read — a clean version of that section closes it, not new specification.

### Q11. How is an emergency department visit identified?

The protocol names "Emergency visits" as a healthcare-utilisation outcome
(§7.3.2, §7.8.1) and never defines it. Optum CDM has **no ED flag**. The three usual
constructions — revenue codes 045x/0981, `POS = '23'`, CPT 99281-99285 — do not
agree with one another, and the choice moves the ED rate by a large margin.

**Ask:** which construction, and is an ED visit that becomes an inpatient admission
counted as an ED visit, a hospitalisation, or both?

### Q9. Region — is there a `REGION` column, or do we derive it from `STATE`?

Table 4 wants US Census Bureau regions. The CDM V9.0 dictionary documents `REGION`
("The US Census Region associated with the member address") on MEMBER_ENROLLMENT and
says `DIVISION` was removed. The deployed 2025q4 table carries `STATE varchar(2)` and
**no** `REGION` (`DATA_MAPPING.md` §4).

The two are not just different columns, they are different CDM vintages: the deployed
27-column table is **pre-V9.0** — it has `STATE`, which V9.0 removed, and lacks
`REGION` and `LIS_DUAL`, which V9.0 added — plus eight Databricks-side date-part
columns. `DATA_MAPPING.md` §4 has the arithmetic. In V9.0, Census Region is the finest
geography that survives at all: `DIVISION`, state, ZIP, county and MSA are all gone.

The deployed extract is not simply "a version behind" — it is a hybrid. Of the
four V9.0 additions to MEMBER_ENROLLMENT, **three landed** (`ETHNICITY`, `RACE`
moved off the SES file, `RACE_SOURCE` — appended at columns 26 and 27) and
**`REGION` did not**, while `STATE`, which V9.0 removed, is still there.
`LIS_DUAL` is also absent. `DATA_MAPPING.md` §4 lists all 27 columns.

So `REGION` is specifically the one missing column the region variable needs.
`REGION_SOURCE=region_column` refuses rather than reaching Spark and failing
with `UNRESOLVED_COLUMN` after the spine is built.

**Ask:** confirm we may derive region from `STATE` with a standard 50-state →
4-region crosswalk, and how to classify a patient whose `STATE` changes between
enrolment rows (take the row covering the index date?). Also worth asking when
`REGION` is expected — if a refresh brings it, the crosswalk becomes redundant
rather than wrong, and since `ETHNICITY` and `RACE_SOURCE` were appended
without disturbing `STATE`, a refresh would probably append `REGION` too rather
than swapping the columns.

---

## Needs a decision, but does not block a first build

### Q29. Does the small-cell floor exempt SOC strata?

The protocol states the 25-patient floor twice, and the two sentences differ.

> §7.2.3: "Stratifications with <25 patients will not be performed or may be
> regrouped due to low volumes."

> §7.8: "If there are less than 25 patients in a particular stratifications or
> cohort, analyses will not be conducted **(unless specific to SOC)**."

Only §7.8 carries the exemption, and it does not say which analyses are
"specific to SOC" — every SOC-keyed table, or only the SOC distribution itself.

`R/modules/11_release.R` applies §7.2.3: every cell under 25 is suppressed, SOC
included. That is the conservative reading. Suppressing more than required
loses a stratum the protocol may permit; the other way round publishes one it
forbids.

It matters for the SOC tables specifically. `S_SOC` is keyed on regimen
category, and a category held by fewer than 25 patients in a line is exactly
what §7.8 might be exempting — the rarer regimens are the ones the study is
about.

**Ask:** whether the SOC exemption applies, and if so to which tables. A one-
line change to `SUPPRESSION_SPEC` adds an exemption predicate once it is
decided.

---

### Q28. What is `DOD.MBR_MATCH_TYPE`, and should low-confidence deaths count?

`t_dod_2026q1` has five columns, and one of them is **`MBR_MATCH_TYPE
varchar(1)`**. No Optum documentation covers it: the V9.0 dictionary has a sheet
for all fifteen CDM tables and none for DOD, and the business rules name only
`YMDOD`.

The name suggests how each member was linked to the death record. Death data of
this kind is usually assembled by matching members to an external source, and
such matches are commonly graded — exact on identifiers, versus probabilistic.
If that is what this column is, then some fraction of the 11.5M deaths are
lower-confidence links, and neither build filters on it.

It matters because overall survival is a secondary objective: including
low-confidence matches overstates deaths, and excluding them understates. The
column has exactly two values, so it is a binary flag rather than a graded
score; which value is the confident link is not derivable from the data.

**Ask:** what the values mean, and whether any should be excluded.

---

### Q25. Should denied claims count?

`MEDICAL.PAID_STATUS` is *"the payment determination of this service line"*, and
the CDM fills it in where the source left it null:

> "PAID if Sum of all Paid Amounts >= $0 · DENIED if Sum of all Paid Amounts < $0"

A denied claim is not evidence the service happened. Neither this package nor
the cohort build filters on it, so every count built so far includes denied
lines: diagnoses that qualify a patient, ED visits, hospitalisations, and the
claims that set a line of therapy.

`CLAIM_STATUS` carries the two readings. The default is `all`, which is what
every number produced to date includes; `paid_only` excludes `DENIED`. The
default is deliberately the status quo rather than the more defensible option,
because changing it silently would make this package disagree with the cohort
table it is built on.

**Ask:** confirm whether the study intends to include denied claims. Most
claims analyses exclude them.

---

### Q27. Which route defines "a MM diagnosis in first or second position"?

§7.8.1 defines an MM-related hospitalisation as one with *"a MM diagnosis in
first or second position"*. There are two routes to that in the CDM and they
are not the same thing:

- **`CONFINEMENT.DIAG1` / `DIAG2`** — *"First ICD-X Diagnosis"* / *"Second ICD-X
  Diagnosis"* on the bundled, unduplicated confinement record. This is what the
  package implements.
- **`MED_DIAGNOSIS.DIAG_POSITION` 1 or 2** on a claim carrying that `CONF_ID` —
  which is the route business rule 13 documents: merge MED_DIAGNOSIS to MEDICAL
  on `PATID + CLMID`, then to CONFINEMENT on `PATID + CONF_ID`.

Confinement positions are stay-level and there are five of them; claim
positions are line-level and there are twenty-five. A stay can carry myeloma at
confinement position 3 and at claim position 1 on one of its lines.

**Ask:** confirm the confinement record's own first two diagnoses are meant.
That is the natural reading of "hospitalisation … diagnosis position" and is
what the package does, but the vendor documents the other route for "diagnoses
reported within a hospitalization".

---

### Q3. Are 30- and 60-day outpatient pairing windows still wanted as sensitivities?

The protocol names only 90 days. An earlier specification flagged 30- and 60-day
pairs as well, and the current build reports one cohort at 90 with 30/60 available
as sensitivities.

### Q5. Is "evidence of follow-up" meant to filter anyone?

Criterion I5 is *"at least one claim (pharmacy or medical) from index date or
death"*. The index claim is itself a medical or pharmacy claim on the index date, so
on a literal reading every indexed patient passes and the criterion excludes nobody.

**Ask:** is a claim **after** the index date meant (i.e. index excluded), or is this
intentionally a no-op that documents the follow-up requirement?

### Q7. Confirming the secondary 2L cohort permits prior malignancy

§7.4.1.1 reads *"Patients in this analysis are analysis are eligible if there is
evidence of a malignancy prior to 2L"* — a garbled sentence. §7.8.1 settles it:

> "**2L cohort**: because prior history of malignancy during baseline is permitted per
> eligibility criteria, the baseline prevalence of any malignancy will be summarized."

So exclusion X2 does **not** apply to the secondary 2L cohort. Worth one line of
written confirmation, since it is the only place the two cohorts' criteria diverge.

### Q12. Why do "Year of initiation" and "Types of SOC by line" span different years?

Table 4 gives "Year of 1L, 2L and 3L initiation" as *"from 2019 to latest data
availability"* and, in the very next row, "Types of 1L, 2L, 3L SOCs or classes by
line" as *"from 2017 to 2025 (or latest data availability)"*. 2017 precedes the study
period on either reading of Q1.

**Ask:** is 2017 a leftover from an earlier draft, or is the SOC tabulation meant to
reach back further than the cohort?

### Q14. Does the baseline period include the index date?

§7.1: *"the 12-month period prior to the index date for each LOT (**does
not include index date**)"*.
§7.8.1: *"Comorbidities will be assessed over the 12-month baseline
period, **including the index date**"*.

**Ask:** which, and does it differ between comorbidities and the key safety events?
A same-day event at index otherwise lands in both the baseline and the treatment
period, or in neither.

### Q16. How is a time-varying enrolment attribute resolved "at index"?

`BUS`, `PRODUCT`, `CDHP`, `STATE` and `GDR_CD` live on `MEMBER_ENROLLMENT`, which
carries a new row every time anything about the member changes. The observed value
distributions prove patients hold rows with different values: the three
`count(DISTINCT PATID)` totals disagree (`BUS` 23,632, `CDHP` 26,114, `PRODUCT`
30,651) against a cohort that cannot be that large three different ways.

Table 4 times race, ethnicity, region, sex and insurance type "at index". The natural
rule is **the enrolment row covering the index date**, but neither Optum document says
how to break a tie when more than one row covers it, and the cohort build uses a
different rule (most recent `ELIGEND`, after preferring a usable `YRDOB` and a known
sex).

**Ask:** confirm "the row covering the index date", and give a tie-break.

### Q17. Which way round are `PROC_CD` and `PROC`? — **ANSWERED**

Rule 5 of the Optum business rules assigns `PROC_CD` / `T_MEDICAL` to
ICD-9/ICD-10 procedure codes and `PROC` / `T_MED_PROCEDURE` to HCPCS/CPT. Rule 3,
the MEDICAL description and the CDM V9.0 dictionary all say the opposite.

The data settles it. Measured over the study period, `PROC` is **43,137,224 of
~43.2M rows at `ICD_FLAG='10'` and seven characters** — ICD-10-PCS. The
five-character tail, the only shape a HCPCS or CPT code could occupy, is about
**15,000 rows: 0.035%**.

So `MED_PROCEDURE.PROC` is the ICD procedure code and `MEDICAL.PROC_CD` is CPT/HCPCS.
Rule 5 is a transcription error. **Closed.**

Worth carrying into every new outcome scan: the build reads `PROC` as a fifth
medication source anyway, because the failure it guards is asymmetric — a therapy the
scan cannot see lets a patient pass the no-prior-therapy criterion on missing data,
and can move the index later than it belongs.

### Q18. Is the 2022 business-rules document still current? — **partly answered: no**

The Optum business rules document is dated 30 August 2022. It is being applied
to a 2025Q4/2026Q1 extract against a CDM **V9.0** dictionary released
September 2023 — a version that moved `RACE` off the SES file, added `ETHNICITY`,
`REGION`, `FAMILY_ID` and `BILL_PROC_CD`, and removed `DIVISION` and `PROV_STATE`.
No revalidation of the rules against V9.0 is recorded anywhere.

**It is demonstrably out of date on two points we can check.** It describes SES
as *"seven consumer characteristics including race, occupation, income, home
ownership, poverty status and education level"*; the V9.0 dictionary's SES
sheet carries **four**, and race is not among them — `RACE` was *"Moved from
SES file and renamed from D_RACE_CODE"* onto MEMBER_ENROLLMENT. And its note
says DOD "cannot be joined since both tables are encrypted differently", where
the warehouse returns a **100% PATID match** on 11,509,828 patients.

Treat it as a 2022 statement: useful for the join keys and the fourteen rules,
which the dictionary corroborates, and not authoritative on anything the CDM has
since changed.

**Ask:** is there a newer business-rules document, and has the inpatient/outpatient
construction been revalidated against V9.0?

### Q19. Do the days inside a bridged enrolment gap count as person-time?

Every rate in Objectives 1 and 2 has a person-year denominator. A patient with a
25-day gap in their baseline year is "continuously enrolled" by the ≤ 30-day rule —
but do those 25 days contribute person-time, or are they removed from the
denominator?

Neither Optum document addresses it, and the protocol does not either. The choice
changes every rate slightly and systematically.

**Ask:** count bridged gap days as covered person-time, or exclude them?

### Q20. Which annex numbering is right?

The protocol's contents list gives:

```
ANNEX 3   TABLES
ANNEX 4   FIGURES
ANNEX 5   CODELISTS
```

Annex 1's own table of stand-alone documents gives:

```
3.  Codelists to define study outcomes
4.  Main study table shells
5.  Main study figures
```

The body text agrees with Annex 1: §7.3.2 defines the key safety events *"according to
selected ICD-10-CM codes or healthcare visits (**Annex 3**)"*, §7.8.5 says outcomes are
defined *"according to pre-defined code lists, as specified in **Annex 3**"*, and §7.8
puts the shells in *"**Annex 4 and Annex 5**"*. So the contents list has three
entries rotated, and it will cause a wrong file to be sent. It also carries two
typos: "ALGORITHIM" and "FRAILITY".

**Ask:** confirm Annex 3 is the code lists, and fix the contents list.

---

## Inherited from the cohort build, still open

The cohort build leaves four of its own decisions open pending the study team.
The protocol resolves none of them, and two move outcome numbers.

### Q21. Are "months" calendar months or fixed day counts?

Every months window in the package is a fixed day count — 12 months is
`[index − 365, index − 1]` at 1L, 2L and 3L alike; 3 months is 90 days. The
reasoning is that `add_months()` would give two patients indexed a day apart
different windows, and 90 is the shortest three calendar months so it is the
more permissive reading. The 1L sensitivity put the two readings **seven
patients apart**.

The protocol says "12-month" and "3 months" throughout and never disambiguates.

### Q23. Which pregnancy window?

The build applies the exclusion over the **whole study period**; the narrower
reading is the patient's own baseline and follow-up. The wider window excludes
more - a pregnancy claim years from a patient's index date drops them under this
reading and would not under the other.

The protocol says "during the study period" (X3), which is the build's reading, so
this is close to settled. A second question stays open: if the narrower reading were
ever adopted, does its follow-up stop at disenrolment? That is Q13 again, in a
different place.

## What the protocol settles for the build

Four thresholds the cohort build had written down inconsistently in different
places are stated explicitly by the protocol, and every one agrees with what the
build does.

| criterion | sometimes written as | this build | the protocol |
|---|---|---|---|
| enrolment gaps | `< 30 days` | `<= 30 days` | *"gaps in enrolment of **≤ 30 days**"* ✓ |
| other cancer | `>1 IP or >2 OP` | `>=1 IP or >=2 OP` | *"either **≥ 1 inpatient or ≥ 2 outpatient**"* ✓ |
| adult age | `> 18` | `>=18` | *"Aged **≥ 18 years**"* ✓ |
| outpatient MM diagnosis | `> 2 claims` | `>=2 claims` | *"**≥ 2 outpatient** medical claims"* ✓ |

---

## Questions the build prices on every run

Four of the decisions above need no extra query to cost — the build writes the
alternative into the warehouse on **every** run:

| table | what it prices | bears on |
|---|---|---|
| `<prefix>NDMM_FU_CE_COUNTS` | cohort size at 0, 30, 60 and 90 days and at exactly three calendar months, applied row marked | the follow-up rework, `BUILD_DELTA.md` §2, and Q21 |
| `<prefix>NDMM_PREG_WINDOW_COUNTS` | both pregnancy-window readings, with the incremental exclusions separated from the raw claim counts | Q23 |
| `<prefix>NDMM_INDEX_AGENTS` | every `CL_MED_ABBR`, whether this run lets it set an index, and how many patients it set one for | the panobinostat / elotuzumab bars, and Q6 |
| `<prefix>NDMM_OTHER_MALIG_GROUPS`, `<prefix>NDMM_OTHER_MALIG_GRAIN` | the pairing-grain choice, per category, against the per-label grain | the X2 layered readings |

For the index-agent bars specifically: `NDMM_INDEX_EXCLUDED_ABBRS` checks every entry
against the code list and **stops the run on a name that matches nothing**, so a
misspelled "panobinostat" cannot quietly bar no one.

---

## What each decision is worth

Measured against the CDM with the profiling queries in `RUN_ONCE_2.sql` and
`RUN_ONCE_3.sql`. The proxy population is **105,125** members with a C90 code
since 2016, of whom **93,245** have a first C90 code on or after 01 Jan 2018.
None of these is the study cohort — no age, enrolment or exclusion criteria —
so read every number as an order of magnitude, not a cohort count.

### Ranked by how much is at stake

| # | question | the two readings differ by |
|---|---|---|
| Q27 | which route makes a stay MM-related | **32,508 vs 65,206 stays — 2×** |
| Q25 | do denied claims count | **17.4% of all medical lines** |
| Q7  | prior malignancy in the secondary 2L cohort | 17,964 members (19.3%) |
| Q1  | study period starts 2016 or 2018 | 17,288 members first diagnosed 2016-17 |
| Q6  | do steroid-only claims trigger X1 | 10,466 members |
| Q11 | how an ED visit is identified | 364,272 to 499,272 visit-days (+37%) |
| Q2  | narrow or broad MM code set | 29,449 C90.01 + 14,127 C90.02 members |
| Q16 | overlapping enrolment rows | 473 members on STATE, 388 on BUS, 0 on RACE |
| Q19 | person-time inside bridged gaps | 109,679 days (~300 person-years) |
| Q3  | 30-day or 60-day pairing window | 589 members net |
| Q23 | which pregnancy window | 270 members |
| Q5  | what "evidence of follow-up" excludes | 1,012 members (1.1%) |
| Q21 | calendar months or 365 days | one day, for 21% of members |

### Q13 — censoring moves 29% of patients; the bridging rule moves 6%

| | members |
|---|---|
| any myeloma patient | 105,125 |
| contiguous re-enrolment only, no real gap | 61,526 |
| **a bridged gap of 1–30 days** | **6,221** |
| **a break of more than 30 days** | **30,392** |
| mean length of those breaks | **1,361.6 days** |

41,163 breaks over 30 days, which reconciles exactly with the 202,108 span
boundaries minus 160,945 in the `<= 30` bucket, confirming that bucket was
almost entirely `gap_days = 0`.

> **These are upper bounds on the breaks, and the direction is known.** The
> query merged spans with `lag(ELIGEND)` — the immediately preceding row. The
> package's `build_enroll_spans()` uses a running `max(ELIGEND)` over *all*
> prior rows, which is the difference between the two on **nested** spans: a
> short span sitting inside a longer earlier one. 11,986 myeloma members
> (11.4%) have overlapping enrolment rows, so the shape is common. Every
> nested span the `lag()` form mistakes for a gap **inflates the break count
> and deflates coverage**, so the true figures are **at most 30,392 members
> with a break** and **at least 62.1% passing continuous enrolment**. The
> 30-day threshold itself is identical in both forms
> (`elig_eff <= max_end + 31` ⟺ gap ≤ 30), so only nesting differs.
> `RUN_ONCE_3.sql` builds `mm_spans` with the package's own logic verbatim;
> one re-run replaces both bounds with the number the build will produce.

So `CENSOR_AT_DISENROLLMENT` decides the follow-up of 30,392 patients, 29% of
the population. The 30-day bridging rule itself touches only 6,221 (5.9%), so
Q19's 109,679 bridged days are spread thinly. A mean break of 3.7 years also
says what these are: people who left the plan and came back years later, not
brief administrative lapses. Bridging them would be indefensible; the rule
correctly does not.

### I4 / N2 — the largest attrition step in the study, at 38%

| | members |
|---|---|
| with a first myeloma diagnosis from 2018 | 93,245 |
| **pass 12 months of continuous enrolment before index** | **57,933 (62.1%)** |
| pass it through the index date as well | 57,932 |
| **lost to this criterion** | **35,312** |

**A lower bound** — see the note under Q13. Nested spans read as breaks here
too, so the true pass rate is at or above 62.1% and the loss at or below
35,312. It is the single biggest loss in the funnel, larger than any exclusion,
and it is a criterion this package applies itself. Whether the index day is
included changes it by **one patient**, so Q14 does not matter on this
criterion.

### Q25 — the 17.4% headline is misleading; the real cost is 0.53%

Denials by the shape of the claim, among myeloma patients since 2018:

| claim shape | lines | denied | % |
|---|---|---|---|
| other outpatient | 70,523,049 | 15,266,931 | **21.65%** |
| ED-shaped | 1,298,697 | 97,635 | 7.52% |
| inpatient-linked | 9,882,844 | 575,950 | 5.83% |

Denials concentrate in ordinary outpatient claims and are **thin in exactly the
claims this study counts as events**. And at the event level rather than the
line level:

| | ED patient-days |
|---|---|
| all | 499,272 |
| with at least one paid line | 496,642 |
| **every line denied — the visits that would vanish** | **2,630 (0.53%)** |

So `CLAIM_STATUS=paid_only` would remove **one ED visit in 200**, not one in
six. The decision is real but small, and it should be made on 0.53% rather than
on 17.4%.

Table-wide, `PAID_STATUS` among myeloma patients splits P 85,917,548 (78.69%),
D 19,018,111 (**17.42%**), null 4,243,797 (3.89%); from 2024 the whole table
runs 1,672,870,316 P against 340,788,413 D with no nulls.

**The setting is narrower than its name.** `claim_status_sql()` has one call
site — the ED arm of `07_hcru.R`. `CLAIM_STATUS=paid_only` does not touch the
I5 follow-up claim test, the MM-hospitalisation subquery, `CONFINEMENT` (which
has no paid status), or `RX`. The warehouse stores `P` and `D` where the V9.0
dictionary spells the values `PAID` and `DENIED`, so `claim_status_sql()`
matches both encodings; nulls are not treated as denied.

**So the decision has three parts, not one:** whether to exclude denied claims
at all; if so, whether the exclusion reaches beyond emergency visits; and
whether pharmacy claims can join it.

### `STD_COST` cannot stand in for `PAID_STATUS` on the pharmacy side

The deployed pharmacy table has no `PAID_STATUS` at all — its columns run
`STD_COST`, `AHFSCLSS`, `CHK_DT`, `DAW`, `DAYS_SUP`. Since the dictionary's
paid/denied rule is arithmetic on money, the sign of `STD_COST` looked like a
substitute. Tested on the medical side where both exist:

| `PAID_STATUS` | `STD_COST` | lines |
|---|---|---|
| P | positive | 60,231,696 |
| **D** | **positive** | **14,891,418** |
| P | zero | 3,275,108 |
| (null) | positive | 1,221,969 |
| D | zero | 1,042,809 |
| **P** | **negative** | **1,034,482** |
| D | negative | 6,289 |
| (null) | zero | 819 |

**93% of denied lines carry a positive `STD_COST`, and a million paid lines
carry a negative one.** There is no relationship. `STD_COST` is a *standardised*
price — an imputed benchmark for the service — not the amount anyone paid, so
the dictionary's rule about "Sum of all Paid Amounts" never applied to it.

On RX the same test returns **no negative rows at all** (positive 14,230,204
lines / 91,272 members; null 726; zero 332), which is consistent.

**So denied pharmacy claims cannot be identified, and the asymmetry is
permanent.** `CLAIM_STATUS=paid_only` filters medical claims only, and that
belongs in the SAP as a stated limitation rather than a silent one.

### Q27 — the two routes differ by a factor of two

Over 241,362 stays belonging to myeloma patients since 2018:

| | stays |
|---|---|
| route A — MM in `CONFINEMENT.DIAG1/DIAG2` (the default) | 32,508 |
| route B — MM in `DIAG_POSITION` 1-2 on a claim carrying the `CONF_ID` | 65,206 |
| found by route A only | 1,206 |
| found by route B only | 33,904 |
| MM only in `CONFINEMENT.DIAG3-5` — neither route counts these | 33,978 |

Route B finds twice what route A finds, and route A is very nearly a subset of
it. This is the largest unresolved swing in the package's own SQL, so it is a
setting rather than an assumption: `MM_HOSP_POSITION` takes `confinement` (the
default, which is what every number so far used) or `claim_positions`. Both are
emitted and both are executed by the test suite.

**Still needs an answer.** §7.8.1 says "first or second position" without saying
of what. Route B is the one business rule 13 documents.

### Q11 — the three ED constructions, and a third of them became admissions

Distinct patient-days since 2018, among myeloma patients:

| construction | visit-days |
|---|---|
| revenue code 045x / 0981 | 385,803 |
| place of service 23 | 436,495 |
| CPT 9928x | 364,272 |
| **any of the three** | **499,272** |
| revenue *and* CPT on the same day | 229,938 |
| any of the three, carrying a `CONF_ID` | **162,211** |

The widest construction is 37% above the narrowest, and the three overlap far
less than their similar totals suggest — revenue and CPT agree on only 229,938
of the ~400,000 each finds. And 162,211 visit-days (32.5% of the union) are on
claims that carry a `CONF_ID`, so under business rule 14 they became
admissions and are at risk of being counted as both an ED visit and a stay.
`ED_ADMITTED` exposes that choice; the number says it is worth 1 visit in 3.

### Q1 — 17,288 members were first diagnosed in 2016 or 2017

First C90 code by year: 2015 6,963 · 2016 8,335 · 2017 8,953 · 2018 8,709 ·
2019 8,225 · 2020 8,267 · 2021 9,805 · 2022 10,187 · 2023 11,368 · 2024 10,869
· 2025 11,521 · 2026 3,212 (to 31 Mar). A 2016 start makes 17,288 more members
eligible as incident cases than a 2018 start does — roughly a fifth of the
population. The body text and the two figures still disagree.

### Q2 — what "broad" would add

Forty distinct myeloma-adjacent codes are present, every one of the top
thirteen flagged ICD-10:

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

The choice that matters is C90.01 and C90.02: 43,576 members carry a remission
or relapse code, and whether those qualify as the incident diagnosis decides
whether a prevalent patient enters as newly diagnosed.

### Q7 — 17,964 members (19.3%) carry another cancer in their baseline year

Using any C-code that is not C90 and not C44, paired within the baseline year.
That is the population the secondary 2L cohort's prior-malignancy allowance
turns on, and it is a fifth of everyone.

### Q3 — the 60-day window adds 589 members

16,171 members have a paired other-cancer within 30 days; 16,760 within 60.
1,108 members have at least one cancer category whose only pairing sits in the
31-60 day window. The sensitivity is real but small.

### Q6 — 10,466 members would be excluded on a steroid claim alone

Of 80,398 members with any baseline treatment claim, 12,033 have a steroid
J-code, 3,489 have an unambiguous myeloma agent, and **10,466 have a steroid
and no myeloma agent**. Three times as many patients are decided by the
steroid reading as by the clear-cut one, which makes this the most expensive
of the questions that need Annex 2.

### Q5 and Q14 — the follow-up rule excludes nobody; the index day is universal

Of 93,245 members, all 93,245 have a medical claim on or after their index
date, and all 93,245 have one exactly **on** it. Only 92,233 have one strictly
after, so the strict reading excludes 1,012 members (1.1%). The literal
reading of "at least one claim from the index date" excludes nobody, which is
what Q5 suspected.

### Q9 and Q16 — moving is rare, and the tiebreak matters for 0.8%

6,006,459 of 105,204,737 members — 5.7% — have two distinct `STATE` values
across their enrolment rows. Nobody has three. Among myeloma patients,
11,986 (11.4%) have enrolment rows that overlap on different `PAT_PLANID`s,
and those rows disagree on `STATE` for 473 members and on `BUS` for 388.
**They never disagree on `RACE` — not once.** The deterministic tiebreak the
package applies is therefore worth about 0.8% of patients, and race was never
at risk.

### Q19 — bridged gaps are worth about 300 person-years *(upper bound)*

202,108 span boundaries, 72,239 members. The bridged gaps of 30 days or fewer
carry **109,679 days** of person-time that is covered on paper and unobserved
in fact — roughly 300 person-years across the whole myeloma population. 987
gaps sit at exactly 30 days against 98 at exactly 29, so the threshold itself
lands on a plan-renewal boundary and moving it by a day is not neutral.

This query counted a boundary as a gap whenever the next span started after the
previous ended, so a contiguous re-enrolment (`gap_days = 0`) is in the 160,945
"bridged" count; the 109,679 days figure is unaffected, since zeros contribute
nothing. It shares the `lag(ELIGEND)` limitation described under Q13, so
**109,679 is itself an upper bound**. The corrected `mm_spans` view carries
`MAX_BRIDGED_GAP` and settles it on the next run.

### Q21 — the two readings differ by at most one day

`add_months(index, -12)` and `index - 365 days` land on the same date for
73,321 members and one day apart for 19,924. Never two. The question is real
for 21% of members and worth a single day to each of them.

### Q23 — the two pregnancy windows differ by 270 members

307 members have a proxy pregnancy code anywhere in the study period; 99 have
one in their own baseline year; 270 are caught by the study-period reading
alone. 0.29% of the population, using proxy codes because Annex 3 has not been
delivered.

### Q28 — `MBR_MATCH_TYPE` has exactly two values

| value | rows | share |
|---|---|---|
| 2 | 6,782,785 | 58.93% |
| 1 | 4,727,043 | 41.07% |

Two values, no nulls. So it is a binary flag, not a graded match score — which
narrows what it can mean but does not say which value is the confident link.
**Still needs the vendor.** If `1` marks a lower-confidence link, 41% of death
records carry it and overall survival is a secondary objective.

### Death dates — one clean finding and one that needs a better test

33,800 of 93,245 (36.2%) carry a death record. Mean gap from last claim to
death, where the order is sane, is 190.6 days.

**348 members have a death date before their index date** — before their first
myeloma diagnosis, which is not possible — and **9,705 have one before their
last claim**.

*This is an upper bound, not a finding.* `YMDOD` is month-precision and the
query imputed the 15th, so a patient who died on the 25th with a claim on the
20th is flagged wrongly. Roughly half of same-month cases would be. The right
test compares at month granularity, and until it is run the honest statement is
that **up to 9,705 patients have a death/claim ordering problem, and at least
some of that is the imputation**. The 348 pre-index deaths deserve the same
re-test and are the more troubling half. Both bear on overall survival, a
secondary objective, and on `MBR_MATCH_TYPE` (Q28) — if the low-confidence
link value is the one carrying these, that is the answer to both questions.

### Age — the guard costs nothing here, and I2 excludes 93 patients

Of 93,245 members, 93,236 have an enrolment row. Among those: **no null
`YRDOB`, no zero `YRDOB`, and not one member carrying two different birth
years.** Age is usable for 100% of them. The `YRDOB = 0` rows are real but fall
outside the myeloma population, so the guard is protection that currently costs
nothing.

| band at first diagnosis | members |
|---|---|
| under 18 — **excluded by I2** | **93** |
| 18–64 | 18,535 |
| 65–74 | 34,387 |
| 75+ | 40,221 |

### RX — `FILL_DT` confirmed, and clean

22,107,537 lines across 99,155 members, 2000-05-01 to 2026-03-31, with **zero
nulls** in `FILL_DT`, `NDC` or `DAYS_SUP`. `build_fu_claims()` is safe.

### The two truncated tails, closed

**STATE.** Exactly two values fall outside the 51-entry census crosswalk:

| | enrolment rows | members |
|---|---|---|
| `NULL` | 3,829,750 | **2,570,332** |
| `PR` | 14,151 | 11,795 |

So region Unknown is overwhelmingly **missing state**, not territories — 2.4%
of all members. Puerto Rico is a genuine gap in the crosswalk but a small one.
Neither is a bug; both belong in the Table 4 footnote.

**DIAG_POSITION.** The 26th value is `NULL` (1,576,237 rows). No junk, nothing
non-numeric, so `try_cast(... as int)` is safe and the zero-padding is the only
trap.

### ICD-9 myeloma codes — effectively none

Since 2016: 105,125 members carry an ICD-10 C90 code, **1 carries an ICD-9
203.0x code, and that 1 carries only ICD-9.** So `mm_dx.csv` can be authored
ICD-10-only with a one-line footnote, and the ICD-9 arm of every code-list join
is dead weight for this study period rather than a risk.

### Hospitalisation shape

Of 241,362 stays: **zero have a missing discharge date**. So the protocol's
provision for excluding no-discharge stays from LOS summaries never fires, and
`N_LOS_EXCLUDED` will be 0 on every table. `CONFINEMENT.LOS` equals
`datediff(discharge, admit)` for 235,733 stays and differs for 5,629 (2.3%);
the means are 8.87 against 8.84. The package computes its own rather than
reading the column, which the dictionary's note about LOS spanning bundled
records supports.

---

## Settled against the warehouse

These are out of the list above. Numbers are recorded here so nobody has to
re-run to know them.

### Q26 / Q8 — `DOD` joins on `PATID`

| dod_patients | matched in enrollment | match_pct |
|---|---|---|
| 11,509,828 | 11,509,828 | **100.0** |

Every DOD patient matches. `DOD.PATID` is `bigint`, the same type and domain as
the enrolment table's. The business-rules note — *"DOD and SES tables cannot be
joined since both tables are encrypted differently"* — does not hold for this
deployment, and the join diagram's `PATID` edge is right. The cohort build's
`LEFT JOIN best b ON q.PATID = b.PATID` is correct, death dates are real, and
overall survival is reportable.

### Q22 — every death date has a month; the year-only case does not arise

| YMDOD length | n | range |
|---|---|---|
| 6 | 11,509,828 | 200005 → 202603 |

All 11.5M rows are `YYYYMM`; none is year-only. So the build's constructed day
is never six months wide, and what remains is only whether the 15th is the
right day **within a known month** — a ±15 day convention, not a gap.

`DOD` has five columns: `PATID`, `YMDOD`, `EXTRACT_YM`, `VERSION`, and
**`MBR_MATCH_TYPE varchar(1)`** — see Q28.

### Q10 — the RACE and ETHNICITY code values, and the package's mapping is right

| RACE | ETHNICITY | RACE_SOURCE | n |
|---|---|---|---|
| W | N | Self-Reported | 80,804,230 |
| null | null | null | 56,625,949 |
| null | N | Self-Reported | 12,817,529 |
| B | N | Self-Reported | 11,705,159 |
| W | null | Self-Reported | 8,582,197 |
| W | H | Self-Reported | 7,796,337 |
| null | H | Self-Reported | 6,716,562 |
| B | null | Self-Reported | 5,015,804 |
| A | N | Self-Reported | 4,460,620 |
| U | N | Self-Reported | 4,029,585 |
| U | H | Self-Reported | 3,748,217 |
| W | U | Self-Reported | 3,022,908 |
| U | null | Self-Reported | 2,336,562 |

`RACE` is **W, B, A, U** or null; `ETHNICITY` is **N, H, U** or null. The
package maps `A`→Asian, `B`→Black, `W`→White, `H`→Hispanic, `N`→Not Hispanic,
everything else Unknown — **all correct**. (`C` is a dead branch; it never
occurs.) `RACE_SOURCE` is always `Self-Reported`, so the race here is not
imputed.

**One thing to carry into Table 4**: race is null or `U` on about **42%** of
enrolment rows and ethnicity on about **36%**. Those are enrolment rows across
the whole database, not this cohort, but Table 4's race and ethnicity rows will
be heavily "Unknown" and should say so rather than look like a finding.

`BUS` is confirmed as `COM` and `MCR`, which is exactly what the demographics
module maps.

### Q24 — an `ICD_FLAG` naming neither family exists, and is negligible

| ICD_FLAG | n |
|---|---|
| 10 | 11,414,536,709 |
| 9 | 4,975,563,582 |
| null | **530** |

530 rows out of ~16.4 billion. Reporting them rather than gating on them is
the right call and needs no change.

### The value domains the package assumed, now confirmed

| what | warehouse says | verdict |
|---|---|---|
| `MEMBER_ENROLLMENT.GDR_CD` | `F` 108,308,094 · `M` 102,595,572 · `U` 88,388 | package maps M/F and sends `U` to Unknown — correct |
| `MEMBER_ENROLLMENT.STATE` | **53 distinct values** | `CENSUS_REGION` carries 51 (50 + DC), so **two values fall to region Unknown** |
| `MED_DIAGNOSIS.DIAG_POSITION` | **zero-padded strings** `01`, `02`, … (26 rows) | anything comparing it as `'1'` would match nothing. Route B casts it, and the fixture carries the zero-padded form |
| `CONFINEMENT.ICD_FLAG` | **exists** — `10` 23,453,669 · `9` 15,054,996 · null 1,666 | the MM-hospitalisation join may keep reading it; the admit-date fallback stays for the 1,666 |
| `MEDICAL.PAID_STATUS` | **exists** — values `P` / `D`, not the words | `claim_status_sql()` matches both encodings |
| `MEDICAL.CONF_ID` | null (182,711,199 lines / 21,932,322 members) or populated (186,547,530 / 2,805,263). **No zero or blank sentinel** | the plain null test is enough for the non-inpatient side; the `trim(...) = ''` branch is dead but harmless |

### Also settled, without having been questions

- **`CONFINEMENT.ADMIT_DATE` is a real `date`**, with `_DAY` / `_MONTH` parts
  beside it — the same conversion Databricks applied to `ELIGEFF`. The
  documented Optum format is `YYYYMMDD`, and both builds cast to date; had it
  arrived as an integer the cast would have yielded NULL and dropped every
  hospitalisation. It did not.
- **`MEDICAL.CONF_ID` is `varchar(21)`**, so the ED-became-an-admission test
  (`ED_ADMITTED`) works as written. MEDICAL has 62 columns.
- **The `2026q1` vintage exists** — every `DESCRIBE` against it returned. The
  schema holds one table per quarter back to `2016q4`.
- **`YRDOB` is capped, exactly as the dictionary says.** 12,769,783 members
  carry 1937 against ~1.4M in each neighbouring year: 2026 − 1937 = 89.
- **`YRDOB` is `0` on 614 rows.** Unguarded, `year(index) - 0` is an age of
  about 2026, which lands every one of them in the **75+** band — the band the
  protocol uses as its transplant-eligibility proxy. `03_demographics.R`
  returns NULL age and an Unknown band outside a plausible human range, and
  `tests/fixtures` carries a patient at the cap and one at zero.

---

## Already settled elsewhere

Not questions — recorded here so nobody reopens them.

| point | where it is settled |
|---|---|
| Melphalan short-course cap is `≤ 28` days, inclusive | `../lot/LOT_RULES.md` §4.7 |
| A confirmed melphalan course beats the MAP fold-in | `../lot/LOT_RULES.md` §4.7 |
| A returning prior-line drug joins the line it returns in | `../lot/LOT_RULES.md` §4.8 |
| A drug of the previous regimen never starts a line | `../lot/LOT_RULES.md` §4.3 |
| Discontinued 1L then a 12-month baseline before 2L/3L | `IE_CRITERIA.md` |
| Melphalan mono when melphalan came with a steroid | `../lot/LOT_RULES.md` §2.1 |

Three of the engine rules (§4.3, §4.7, §4.8) are **not** in the protocol text.
They should go into Annex 6 so the protocol and the code agree on the record.
