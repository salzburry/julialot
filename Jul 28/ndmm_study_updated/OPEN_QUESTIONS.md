# Open questions for the study team

Twenty things the Aug 26 2026 protocol and the Optum documentation do not settle,
each of which changes a count or a definition. Ordered by how much they change.

Nothing here is a style preference. Every one of them has two defensible readings and
the build has to pick one.

---

## Blocking — a number moves

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

The current build uses `STUDY_START = 2016-01-01`.

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

**Ask:** strict on both arms, or strict inpatient / broad outpatient?

### Q4. What does "with medical and pharmacy benefits" mean operationally?

Criterion I4 requires 12 months of CE "with medical and pharmacy benefits". But:

- `MEMBER_ENROLLMENT` as deployed carries **no benefit-type flag** (27 columns,
  `DATA_MAPPING.md` §4);
- the CDM V9.0 dictionary shows none either;
- the protocol's own §7.5 says *"All patients in this database have both medical and
  pharmacy coverage"*.

So it is either automatically satisfied, or it needs a claims proxy (≥ 1 medical
claim **and** ≥ 1 pharmacy claim in the baseline) — which would be a much stricter
criterion and would drop patients with no pharmacy activity in their baseline year.

**Ask:** treat as satisfied by construction, or apply a claims proxy? If a proxy,
which one?

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

**Ask:** confirm steroids alone do not trigger X1.

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

**Ask (or profile):** the value → label mapping. A `SELECT ETHNICITY, count(*)` on the
deployed table would settle it, and should be run before this variable is promised.

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

**Ask:** confirm we may derive region from `STATE` with a standard 50-state → 4-region
crosswalk, and how to classify a patient whose `STATE` changes between enrolment rows
(take the row covering the index date?). Also worth asking whether the warehouse is due
a refresh to a true V9.0 extract, since that would swap `STATE` for `REGION` under the
same table name and silently break the crosswalk.

---

## Needs a decision, but does not block a first build

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

### Q17. Which way round are `PROC_CD` and `PROC`?

Rule 5 of the Optum business rules (p.6) assigns `PROC_CD` / `T_MEDICAL` to
ICD-9/ICD-10 procedure codes and `PROC` / `T_MED_PROCEDURE` to HCPCS/CPT. Rule 3
(pp.4-5), the MEDICAL table description (p.2) and the CDM V9.0 data dictionary all
say the opposite: `MEDICAL.PROC_CD` is CPT/HCPCS, `MED_PROCEDURE.PROC` is ICD-9/10.

The current build follows rule 3, which is almost certainly right. But a J-code
lookup pointed at the wrong table returns nothing and fails silently.

**Ask:** a one-line confirmation that rule 5 is a transcription error.

### Q18. Is the 2022 business-rules document still current?

`Final_Business rule doc_OPTUM_V1_30_08_2022.xlsx` is dated 30 August 2022. It is
being applied to a 2025Q4/2026Q1 extract against a CDM **V9.0** dictionary released
September 2023 — a version that moved `RACE` off the SES file, added `ETHNICITY`,
`REGION`, `FAMILY_ID` and `BILL_PROC_CD`, and removed `DIVISION` and `PROV_STATE`.
No revalidation of the rules against V9.0 is recorded anywhere in this repo.

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
