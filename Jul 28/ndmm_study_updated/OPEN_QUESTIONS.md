# Open questions for the study team

Twenty-seven things the Aug 26 2026 protocol, the Optum documentation and the existing
build's own record do not settle, each of which changes a count or a definition.
Ordered by how much they change. **Two are now answered** — Q4 and Q17, both by
`Jul 28/ndmm/DECISIONS.md` §6, and both are left in place with the answer.

Nothing here is a style preference. Every one of them has two defensible readings and
the build has to pick one.

---

## Blocking — a number moves

### Q26. Can `DOD` actually be joined to the claims tables on `PATID`? — **NEW, and the most serious**

The Optum business-rules document says, in a note under its own table inventory:

> "**DOD and SES tables cannot be joined since both tables are encrypted
> differently.** However the other tables name (MEMBER_ENROLLMENT, MEMBER
> CONTINUOUS ENROLLMENT, MEDICAL, MED_DIAGNOSIS, MED_PROCEDURE, CONFINEMENT,
> RX, LABRESULT, PROVIDER, PROVIDER BRIDGE) and variable names same but all are
> **encrypted differently for DOD and SES table**"

The **join diagram on page 1 of the same document** draws a `PATID` edge from
Member Enrollment to Death (DOD), and another to Socio-Economic (SES).

The document contradicts itself, and `Jul 28/ndmm/R/steps/00_mm_cohort.R:205`
takes the diagram's side:

```sql
LEFT JOIN best b ON q.PATID = b.PATID
```

Two further observations point the same way as the note. The V9.0 data
dictionary has a sheet for every table in the CDM — fifteen of them — and
**none for DOD**. And business rule 12, "Death information", names only the
column (`ymdod` from `t_dod`) and never a join key, where every other rule
spells its keys out.

**What turns on it.** `DEATH_DT` sets `FU_END`, censors overall survival,
gates the time-to-event analysis set, and is the event for OS — a secondary
objective. If the key is incompatible, every death date in both builds is
either absent or spurious, and OS is unreportable.

**Ask:** confirm with Optum or the data team whether `DOD.PATID` is in the same
encryption domain as the claims tables **in this Databricks deployment**. Note
the business-rules document is from **30-08-2022** and is provably stale on at
least one other point (Q18), so it cannot simply be taken as current either.

**This one can be costed today, before anyone answers.** Run:

```sql
SELECT count(*) AS n_cohort,
       count(DEATH_DT) AS n_with_death,
       round(100.0 * count(DEATH_DT) / count(*), 1) AS pct
FROM <prefix>NDMM_COHORT;
```

A 1L NDMM cohort followed from 2019 should show a substantial fraction dead —
tens of percent, not ~0% and not ~100%. A number near zero means the join
matches nothing and the note is right. An implausible number means it matches
the wrong people.

---

### Q1. Does the study period start 01 Jan 2016 or 01 Jan 2018?

The body text (§7.1, screen 17) says:

> "The study period will span from **01 Jan 2018** through 31 Mar 2026"

Figure 1 (screen 19) and Figure 2 (screen 37) are both labelled **"Study start
01 Jan 2016"**.

This is not cosmetic. Criterion I1 says the qualifying MM diagnosis must fall
"during the study period", so a 2018 start drops every patient whose only
qualifying diagnosis is 2016-2017 — including patients whose 1L is in 2019 and who
would otherwise be in. It also decides whether ICD-9 codes are ever in scope (ICD-10
began Oct 2015, so a 2018 start makes the ICD-9 arms of every code list dead).

The current build uses `STUDY_START = 2016-01-01`, and
`Jul 28/ndmm/DECISIONS.md` §5 records that window as **signed off** — for the June 2026
protocol. Mechanically the change is cheap: the window is a **run argument**, not a
`CONTRACT` setting (*"the algorithm is unchanged and the dates belong to the cohort"*),
and `check_cohort_window()` makes a cohort/vintage mismatch fatal rather than silent.
§5 also confirms `2026q1` is *"the same tables and column names as `2025q2` with data
extended through 2026-03-31"*, so moving the window needs no re-validation.

**Ask:** which is correct, and does the MM diagnosis have to fall inside the study
period or merely on or before the 1L index?

### Q2. Does the outpatient arm of the MM diagnosis use the broad code set?

§7.2.1.1 (screen 21):

> "At least one inpatient medical claim with a diagnosis code for MM in any position
> (any ICD-9-CM = **203.0x** or ICD-10-CM code = **C90.0x**) or ≥ 2 outpatient medical
> claims **for MM** in any position on the claim, on separate days within 90 days"

The strict code set is attached to the inpatient arm. The outpatient arm says only
"for MM". The Jan-2026 program spec for the earlier study read this as inpatient =
strict `203.0x`/`C90.0x`, outpatient = broad `203.x`/`C90.x`
(`docs/Part 3/Program Spec/studypoppage_validated.csv`, INDEX_DATE). The production
`mm_dx.csv` holds only the eight strict codes (`CODELISTS.md` §1).

Broad adds 203.1x (plasma cell leukaemia), 203.8x, C90.1x, C90.2x
(extramedullary plasmacytoma) — a materially larger cohort.

**The build already has the two-arm mechanism**, so this is a code-list edit, not a code
change. `Jul 28/ndmm/README.md`, criterion 1:

> "The two arms **do not use the same codes**: strict is required only of the inpatient
> arm, and the outpatient pair accepts **any code on `mm_dx.csv`**."

Today `mm_dx.csv` carries only the eight strict codes, so both arms are strict in
practice. Widening the file is all the broad reading needs.

**Ask:** strict on both arms, or strict inpatient / broad outpatient?

### Q4. What does "with medical and pharmacy benefits" mean operationally? — **ANSWERED**

`Jul 28/ndmm/DECISIONS.md` §6 settles it, and rules out the proxy:

> "Medical and pharmacy benefits are **satisfied by construction**. The extract does
> not separate them: `member_enrollment` has 27 columns and none is a benefit
> indicator. `ASO`, `BUS`, `CDHP`, `PRODUCT`, `HEALTH_EXCH` and `GROUP_NBR` are plan
> structure and funding, not coverage type. A span carries both, so `ELIGEFF`/`ELIGEND`
> already express the requirement and **a predicate would filter on nothing**."

> "**Do not re-derive this from claims.** Enrolled patients with no pharmacy fill look
> like a coverage signal and are not: that count is dominated by short spans and by
> patients whose only MM code is a rule-out."

The same conclusion `DATA_MAPPING.md` §7 reaches from the schema, reached
independently and with the failure mode of the alternative named. The protocol's own
§7.5 agrees. **No predicate to write. Closed.**

### Q6. Do steroid-only claims count as "MM oncology therapy" for the prior-therapy exclusion?

Exclusion X1: *"≥ 1 medical or pharmacy claim for **any MM oncology therapy**"* during
the 12-month baseline.

The current build drops dexamethasone and prednisone from that scan
(`NDMM_STEROID_ABBRS`, `Jul 28/ndmm/R/ndmm_constants.R`), on the reasoning that a
steroid claim alone is supportive care and does not make someone previously treated.
The protocol does not say so. Dexamethasone is prescribed for many non-MM reasons, so
including it would exclude patients on the strength of an unrelated steroid course.

Note the LOT engine excludes steroids everywhere (`LOT_RULES.md` §2.1), so this
question is only about the exclusion scan.

**But it is moot on today's code list.** `Jul 28/ndmm/DECISIONS.md` §3, signed off:

> "On the production file: **26 agents, so 25 can set an index. The steroid drop
> removes nothing** — none of `DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE` is
> in `CL_MED_ABBR` — and stays as a guard against a later list that carries them."

So no patient is currently affected either way. The question becomes live the moment
**Annex 2's** therapy list is loaded, because the protocol's own SOC categories are
dexamethasone-containing regimens.

One thing to check when it is: the rollup tab in `docs/Part 1/codist.pdf` is titled
*"Codelist Multiple Myeloma Approved **and Steroid** Medications Rollup"* and carries
**27** medications against the code list's 26 agents. If a steroid is on the list under
an abbreviation the guard does not name, the guard silently stops guarding.
`<prefix>NDMM_INDEX_AGENTS` shows every `CL_MED_ABBR` and whether this run would let it
set an index, so the first run answers it.

**Ask:** confirm steroids alone do not trigger X1, and confirm the steroid abbreviations
against whatever list Annex 2 delivers.

### Q13. Does disenrollment censor follow-up?

§7.1 (screen 17):

> "The patient **follow-up period** will be defined as the period starting from the
> index date... until the **end of continuous enrollment** or end of study period or
> death, whichever occurs first."

`Jul 28/lot/LOT_RULES.md` §7.6 says **"Disenrollment is not censoring"**, and
`CENSOR_AT_DISENROLLMENT = FALSE` is the primary-analysis setting.

TTNT, TTD and OS all censor "at their follow-up end date". Under the protocol's
wording that date is the disenrollment date; under the current build it is the study
end or death. Every median and every landmark estimate differs.

The engine already computes both readings — `LOT_BASE_END_DT_CE_SENS` and
`LOT_BASE_END_REASON_CE_SENS` carry the censor-at-disenrollment version. So the
question is not whether we can produce it, but **which one is the primary analysis**.
Right now the protocol's reading is the sensitivity.

**Ask:** confirm follow-up ends at disenrollment, and confirm this is the primary
analysis rather than a sensitivity.

---

## Blocking — a definition is unbuildable without an answer

### Q15. Please send Annexes 2, 3, 6 and 7, and document pages 31-32.

- **Annex 2** — eligible/expected MM therapies and SOC regimen categorisation.
  Criterion I3 cannot be applied without it.
- **Annex 3** — ICD-10-CM code lists for all 22 Table 3 conditions, the secondary
  malignancy categories, and the healthcare-utilisation definitions. Objectives 1-3
  cannot be computed without it.
- **Annex 6** — the LOT algorithm, to reconcile against `Jul 28/lot/LOT_RULES.md`.
- **Annex 7** — the Kim CFI algorithm and code lists, or confirmation frailty is out.
- **Document pages 31-32** are a corrupt image in the PDF; they carry the rest of
  Primary Objective 1's Table 4 rows and most of Primary Objective 2's.

The `.docx` would supply all of it at once.

### Q11. How is an emergency department visit identified?

The protocol names "Emergency visits" as a healthcare-utilisation outcome
(§7.3.2, §7.8.1) and never defines it. Optum CDM has **no ED flag**. The three usual
constructions — revenue codes 045x/0981, `POS = '23'`, CPT 99281-99285 — do not
agree with one another, and the choice moves the ED rate by a large margin.

**Ask:** which construction, and is an ED visit that becomes an inpatient admission
counted as an ED visit, a hospitalisation, or both?

### Q10. What are the `ETHNICITY` code values?

Table 4 wants Hispanic or Latino / Not Hispanic or Latino / Unknown.
`MEMBER_ENROLLMENT.ETHNICITY` is `varchar(1)` and the CDM V9.0 dictionary marks its
value list **"Intentionally Blank"**.

The reason it is blank is now clear: `ETHNICITY` is a **V9.0 addition** (the
dictionary marks it "Added"), so Optum had not published a value list when the
sheet was written. The column does exist on the deployed table — column 26,
`varchar(1)` — so this is a profiling question, not an availability one.

The same gap applies to **`RACE`**, which the dictionary describes by label
only: *"African American, Asian, Caucasian, Other/Unknown"*, in a `varchar(1)`.
The single characters behind those four labels are documented nowhere, and the
package's guess (`A`→Asian, `B`→Black, `W`/`C`→White) could silently send
African American to Asian if the coding is different.

**Ask (or profile):** the value → label mapping for **both** columns.
`SELECT RACE, ETHNICITY, count(*) FROM t_member_enrollment_2025q4 GROUP BY 1,2`
settles both in one query, and should be run before either variable is
promised.

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

**Verified against the `describe table`, column by column.** The deployed
extract is not simply "a version behind" — it is a hybrid. Of the four V9.0
additions to MEMBER_ENROLLMENT, **three landed** (`ETHNICITY`, `RACE` moved off
the SES file, `RACE_SOURCE` — appended at columns 26 and 27) and **`REGION` did
not**, while `STATE`, which V9.0 removed, is still there. `LIS_DUAL` is also
absent. `DATA_MAPPING.md` §4b lists all 27 columns.

So `REGION` is specifically the one missing column the region variable needs.
`REGION_SOURCE=region_column` now refuses rather than reaching Spark and
failing with `UNRESOLVED_COLUMN` after the spine is built.

**Ask:** confirm we may derive region from `STATE` with a standard 50-state →
4-region crosswalk, and how to classify a patient whose `STATE` changes between
enrolment rows (take the row covering the index date?). Also worth asking when
`REGION` is expected — if a refresh brings it, the crosswalk becomes redundant
rather than wrong, and since `ETHNICITY` and `RACE_SOURCE` were appended
without disturbing `STATE`, a refresh would probably append `REGION` too rather
than swapping the columns.

---

## Needs a decision, but does not block a first build

### Q25. Should denied claims count? — **NEW**

`MEDICAL.PAID_STATUS` is *"the payment determination of this service line"*, and
the CDM fills it in where the source left it null:

> "PAID if Sum of all Paid Amounts >= $0 · DENIED if Sum of all Paid Amounts < $0"

A denied claim is not evidence the service happened. Nothing in this package,
and nothing in `Jul 28/ndmm`, has ever filtered on it — so every count built so
far includes denied lines: diagnoses that qualify a patient, ED visits,
hospitalisations, and the claims that set a line of therapy.

`CLAIM_STATUS` carries the two readings. The default is `all`, which is what
every number produced to date includes; `paid_only` excludes `DENIED`. The
default is deliberately the status quo rather than the more defensible option,
because changing it silently would make this package disagree with the cohort
table it is built on.

**Ask:** confirm whether the study intends to include denied claims. Most
claims analyses exclude them.

---

### Q27. Which route defines "a MM diagnosis in first or second position"? — **NEW**

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

The protocol names only 90 days. The Jan-2026 program spec flagged 30- and 60-day
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

### Q8. Do `DOD` and `SES` join to the claims tables on `PATID`?

The Optum business rules end with: *"DOD and SES tables cannot be joined since both
tables are encrypted differently. However the other tables... and variable names same
but all are encrypted differently for DOD and SES table."* The join diagram on the
same page nevertheless draws `PATID` edges from MEMBER_ENROLLMENT to both. The current
build joins `dod` on `PATID` and uses the result.

**Ask:** confirm the DOD join is valid as implemented. If it is not, every OS and
death-related number in this and prior deliveries is affected.

### Q12. Why do "Year of initiation" and "Types of SOC by line" span different years?

Table 4 gives "Year of 1L, 2L and 3L initiation" as *"from 2019 to latest data
availability"* and, in the very next row, "Types of 1L, 2L, 3L SOCs or classes by
line" as *"from 2017 to 2025 (or latest data availability)"*. 2017 precedes the study
period on either reading of Q1.

**Ask:** is 2017 a leftover from an earlier draft, or is the SOC tabulation meant to
reach back further than the cohort?

### Q14. Does the baseline period include the index date?

§7.1 (screen 17): *"the 12-month period prior to the index date for each LOT (**does
not include index date**)"*.
§7.8.1 (screen 42): *"Comorbidities will be assessed over the 12-month baseline
period, **including the index date**"*.

**Ask:** which, and does it differ between comorbidities and the key safety events?
A same-day event at index otherwise lands in both the baseline and the treatment
period, or in neither.

### Q16. How is a time-varying enrolment attribute resolved "at index"?

`BUS`, `PRODUCT`, `CDHP`, `STATE` and `GDR_CD` live on `MEMBER_ENROLLMENT`, which
carries a new row every time anything about the member changes. The value
distributions on `docs/optum enrolment.pdf` p.4 prove patients hold rows with
different values: the three `count(DISTINCT PATID)` totals disagree (`BUS` 23,632,
`CDHP` 26,114, `PRODUCT` 30,651) against a cohort that cannot be that large three
different ways.

Table 4 times race, ethnicity, region, sex and insurance type "at index". The natural
rule is **the enrolment row covering the index date**, but neither Optum document says
how to break a tie when more than one row covers it, and the current build uses a
different rule (most recent `ELIGEND`, after preferring a usable `YRDOB` and a known
sex).

**Ask:** confirm "the row covering the index date", and give a tie-break.

### Q17. Which way round are `PROC_CD` and `PROC`? — **ANSWERED**

Rule 5 of the Optum business rules (p.6) assigns `PROC_CD` / `T_MEDICAL` to
ICD-9/ICD-10 procedure codes and `PROC` / `T_MED_PROCEDURE` to HCPCS/CPT. Rule 3
(pp.4-5), the MEDICAL description (p.2) and the CDM V9.0 dictionary all say the
opposite.

`Jul 28/ndmm/DECISIONS.md` §6 settles it **empirically**:

> "Measured over the study period, `PROC` is **43,137,224 of ~43.2M rows at
> `ICD_FLAG='10'` and seven characters** — ICD-10-PCS. The five-character tail, the
> only shape a HCPCS or CPT code could occupy, is about **15,000 rows: 0.035%**."

So `MED_PROCEDURE.PROC` is the ICD procedure code and `MEDICAL.PROC_CD` is CPT/HCPCS.
Rule 5 is a transcription error. **Closed.**

Worth carrying into every new outcome scan: the build reads `PROC` as a fifth
medication source anyway, *"because the failure it guards is asymmetric — a therapy the
scan cannot see lets a patient pass the no-prior-therapy criterion on missing data, and
can move the index later than it belongs"*.

### Q18. Is the 2022 business-rules document still current? — **partly answered: no**

`Final_Business rule doc_OPTUM_V1_30_08_2022.xlsx` is dated 30 August 2022. It is
being applied to a 2025Q4/2026Q1 extract against a CDM **V9.0** dictionary released
September 2023 — a version that moved `RACE` off the SES file, added `ETHNICITY`,
`REGION`, `FAMILY_ID` and `BILL_PROC_CD`, and removed `DIVISION` and `PROV_STATE`.
No revalidation of the rules against V9.0 is recorded anywhere in this repo.

**Ask:** is there a newer business-rules document, and has the inpatient/outpatient
construction been revalidated against V9.0?

**It is demonstrably out of date on a point we can check.** It describes SES as
*"seven consumer characteristics including race, occupation, income, home
ownership, poverty status and education level"*. The V9.0 dictionary's SES
sheet carries **four**, and race is not among them — `RACE` was *"Moved from
SES file and renamed from D_RACE_CODE"* onto MEMBER_ENROLLMENT.

That matters beyond SES, because the same document is the only source for the
statement that **DOD cannot be joined** (Q26). Being stale on SES does not make
it wrong about DOD — the CDM changed underneath it — but it does mean the DOD
note cannot be taken as current without confirmation.

### Q19. Do the days inside a bridged enrolment gap count as person-time?

Every rate in Objectives 1 and 2 has a person-year denominator. A patient with a
25-day gap in their baseline year is "continuously enrolled" by the ≤ 30-day rule —
but do those 25 days contribute person-time, or are they removed from the
denominator?

Neither Optum document addresses it, and the protocol does not either. The choice
changes every rate slightly and systematically.

**Ask:** count bridged gap days as covered person-time, or exclude them?

### Q20. Which annex numbering is right?

The Table of Contents (document page 6) lists:

```
ANNEX 3   TABLES
ANNEX 4   FIGURES
ANNEX 5   CODELISTS
```

Annex 1's own table of stand-alone documents (document page 57) lists:

```
3.  Codelists to define study outcomes
4.  Main study table shells
5.  Main study figures
```

The body text agrees with Annex 1: §7.3.2 defines the key safety events *"according to
selected ICD-10-CM codes or healthcare visits (**Annex 3**)"*, §7.8.5 says outcomes are
defined *"according to pre-defined code lists, as specified in **Annex 3**"*, and §7.8
puts the shells in *"**Annex 4 and Annex 5**"*. So the ToC has three entries rotated.

Not a data question, but it will cause a wrong file to be sent. The ToC also carries two
typos: "ALGORITHIM" and "FRAILITY".

**Ask:** confirm Annex 3 is the code lists, and fix the ToC.

---

## Inherited from the build, still open, and not touched by the new protocol

`Jul 28/ndmm/DECISIONS.md` marks four of its own decisions **open, pending study-team
sign-off**. The new protocol resolves none of them, and two of them move outcome
numbers, so they belong on the same list.

### Q21. Are "months" calendar months or fixed day counts?

`DECISIONS.md` §7: every months window in the package is a fixed day count — 12 months
is `[index − 365, index − 1]` at 1L, 2L and 3L alike; 3 months is 90 days. The reasoning
is that `add_months()` would give two patients indexed a day apart different windows,
and 90 is the shortest three calendar months so it is the more permissive reading.

> "Status: **open, pending study-team sign-off**. 'Months' can be read as calendar
> months or as fixed days, and the code uses fixed days. The 1L sensitivity put the two
> readings **seven patients apart**."

The new protocol says "12-month" and "3 months" throughout and never disambiguates.

### Q22. How should a partial death date be constructed?

`DECISIONS.md` §8: `YMDOD` is year and month, sometimes year alone. The build places a
year-and-month death on the **15th** of that month, a year-only death on **15 July**,
bumps either to the period end if it would fall before the qualifying diagnosis, and
never lets it precede `MM_DX_DT`.

> "Status: **open, pending study-team sign-off**. The 15th-of-month rule does not cover
> a year-only record, or a diagnosis falling after the constructed date. Both occur in
> the CDM and needed a convention."

This one matters more under the new protocol than it did under the old: **OS is a
primary reported outcome**, and every OS estimate inherits the ±15-day construction.

### Q23. Which pregnancy window?

`DECISIONS.md` §9: the build applies the exclusion over the **whole study period**;
the narrower reading is the patient's own baseline and follow-up. The wider window
excludes more — *"a pregnancy claim years from a patient's index date drops them under
this reading and would not under the other"*.

> "Status: **open, pending sign-off on the window**."

The new protocol says "during the study period" (X3), which is the build's reading — so
this is close to settled, but §9 raises a second question the protocol does not answer:
if the narrower reading were ever adopted, does its follow-up stop at disenrolment?
That is `Q13` again, in a different place.

### Q24. Should the `ICD_FLAG` finding be gated?

`DECISIONS.md` §11: 16 rows across two CDM tables carried a blank `ICD_FLAG` on the
first production run. Those rows match no code list, so the cohort does not change — but
the miss cuts both ways, and `NDMM_ICD_FLAG_MAX_ROWS` (a ceiling that stops the build)
ships **unset**.

> "Status: **ACCEPTED for 2026q1, unbounded by default. Re-read on each refresh.**
> Setting `NDMM_ICD_FLAG_MAX_ROWS` is the study team's call and the number is theirs —
> it is a governance decision, not a coding one, which is why the code ships with none."

---

## What the new protocol closes for the build

`Jul 28/ndmm/README.md` has a section headed "Thresholds worth double-checking" —
four thresholds *"written down inconsistently in different places"*. **The Aug 2026
protocol states all four explicitly, and every one agrees with what the build does.**

| criterion | sometimes written as | this build | the new protocol |
|---|---|---|---|
| enrolment gaps | `< 30 days` | `<= 30 days` | *"gaps in enrolment of **≤ 30 days**"* ✓ |
| other cancer | `>1 IP or >2 OP` | `>=1 IP or >=2 OP` | *"either **≥ 1 inpatient or ≥ 2 outpatient**"* ✓ |
| adult age | `> 18` | `>=18` | *"Aged **≥ 18 years**"* ✓ |
| outpatient MM diagnosis | `> 2 claims` | `>=2 claims` | *"**≥ 2 outpatient** medical claims"* ✓ |

That section can be struck once the protocol is the reference.

---

## Questions that already have a price on them

Four of the decisions above do not need a new run to cost — the build writes the
alternative into the warehouse on **every** run:

| table | what it prices | bears on |
|---|---|---|
| `<prefix>NDMM_FU_CE_COUNTS` | cohort size at 0, 30, 60 and 90 days and at exactly three calendar months, applied row marked | the follow-up rework, `BUILD_DELTA.md` §2, and Q21 |
| `<prefix>NDMM_PREG_WINDOW_COUNTS` | both pregnancy-window readings, with the incremental exclusions separated from the raw claim counts | Q23 |
| `<prefix>NDMM_INDEX_AGENTS` | every `CL_MED_ABBR`, whether this run lets it set an index, and how many patients it set one for | the panobinostat / elotuzumab bars, and Q6 |
| `<prefix>NDMM_OTHER_MALIG_GROUPS`, `<prefix>NDMM_OTHER_MALIG_GRAIN` | the pairing-grain choice, per category, against the per-label grain | the X2 layered readings |

`Jul 28/ndmm/followup_days.sql` is the follow-up distribution on both definitions,
paste-and-run against this build's own output.

For the index-agent bars specifically: `NDMM_INDEX_EXCLUDED_ABBRS` checks every entry
against the code list and **stops the run on a name that matches nothing**, so a
misspelled "panobinostat" cannot quietly bar no one.

---

## Already answered by the repo's own record

Not questions — recorded here so nobody reopens them.

| point | where it was settled |
|---|---|
| Melphalan short-course cap is `≤ 28` days, inclusive | `Jul 28/STUDY_TEAM_ASKS.md` #1, confirmed 30 Aug 2026 |
| A confirmed melphalan course beats the MAP fold-in | same, settled 30 Aug 2026 |
| A returning prior-line drug joins the line it returns in | `STUDY_TEAM_ASKS.md` #2, `LOT_RULES.md` §4.8 |
| A drug of the previous regimen never starts a line | `STUDY_TEAM_ASKS.md` #6, `LOT_RULES.md` §4.3 |
| Discontinued 1L then a 12-month baseline before 2L/3L | `STUDY_TEAM_ASKS.md` #4 |
| Melphalan mono when melphalan came with a steroid | `STUDY_TEAM_ASKS.md` #5, `LOT_RULES.md` §2.1 |

These three engine rules (§4.3, §4.7, §4.8) are **not** in the protocol text. They
should go into Annex 6 so the protocol and the code agree on the record.
