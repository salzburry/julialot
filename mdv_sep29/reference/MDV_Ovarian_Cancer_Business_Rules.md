# MDV ovarian cancer business rules (colleague's document, transcribed)

A transcription of `MDV_Ovarian_Cancer_Business_Rules.docx`, a colleague's
rules for finding ovarian cancer (OC) patients in MDV. It was read from three
photographs of screens 1-4 of the document's 5 screens on 29 September 2026;
**screen 5 was not photographed and is not here.** The document is labelled
"Proprietary" and carries the organisation's "Critical and Sensitive
Information (CSI) - Internal Only" sensitivity tip. Keep it inside the
organisation.

It is here as the reference for **how MDV is laid out and how this team
writes rules against it**. The myeloma build in this folder uses its table
names, column names and conventions. It does not adopt its OC-specific rules
(female only, platinum linkage) as they stand. `../MDV_RULES.md` says rule by
rule what was taken, what was adapted, and what was left out.

The wording below is the document's. Notes in *italics* are this
transcription's.

---

## 1. Purpose

This document defines the business rules used to identify, classify, and
count ovarian cancer diagnosis records in the MDV database.

## 2. Data Sources

| Source table | Purpose |
|---|---|
| `clnprw_mdv_all_use.t_diseasedata_2026q2` | Disease diagnosis and claim information |
| `clnprw_mdv_all_use.t_patientdata_2026q2` | Patient demographic information, including sex |
| `clnprw_mdv_all_use.t_ff1data_2026q2` | FF1 episode start and end dates and treatment flags |
| `clnprw_mdv_all_use.t_m_drug_2026q2` | Drug master data used to identify platinum-containing treatments |
| `clnprw_mdv_all_use.t_actdata_2026q2` | Drug administration/claim dates |
| `JMDC_MDV_Codelist.xlsx` | MDV disease-code reference list, sheet: "MDV disease codes" |

*The tables follow the same `t_<table>_<yyyy>q<n>` quarterly convention as
the Optum CDM tables (`clnprw_optum.t_<table>_<yyyy>q<n>`).*

## 3. Base Study Population

A record is included in the base ovarian cancer population when all of the
following conditions are met:

| Rule | Condition |
|---|---|
| Disease-code inclusion | The record's `diseasecode` is present in the MDV disease-code reference file. |
| Confirmed diagnosis only | `utagaiflg = 0` |
| Sex restriction | `sex = 2`, representing female patients |
| Cancer diagnosis restriction | `cancerflg = 1` |

## 4. Diagnosis Date and Care Setting

### 4.1 Diagnosis date

`diagnosis_date` is derived from `datamonth` using the first day of the claim
month:

```
diagnosis_date = first calendar day of datamonth
```

### 4.2 Care-setting classification

| `nyugaikbn` | Care setting |
|---|---|
| 1 | Outpatient |
| 2 | Inpatient |

Only inpatient (1) and outpatient (2) settings are used in the analysis
criteria.

*The sentence above contradicts the table: the table says 1 is outpatient and
2 inpatient, and the sentence says inpatient (1) and outpatient (2). Every rule
from section 9 onward pairs `nyugaikbn = 2` with the inpatient FF1 episode and
`nyugaikbn = 1` with outpatient claims, so the table is taken as right. Confirm
it against the MDV data dictionary.*

## 5. Index Year Assignment

For each patient:

1. Identify the earliest available `datamonth` among records meeting the base
   study-population criteria.
2. Define this value as `first_datamonth`.
3. Extract the calendar year from `first_datamonth`.
4. Define this year as `first_yr`.

All results are summarized by `first_yr`.

## 6. FF1 Episode Linkage (Inpatient Only)

Each eligible diagnosis record is linked to FF1 episode data using
`patientid`. The FF1 data provide:

- `ff1startdate`
- `ff1enddate`
- `cancerfirstflg`
- `chemotherapyflg`

These fields are used to identify qualifying inpatient records.

## 7. Platinum Treatment Identification

A platinum-related treatment record is identified when:

```
receiptname_eng LIKE '%platin%'
```

Drug records meeting this condition are linked to administration records using
`receiptcode`.

A diagnosis/claim record is considered temporally associated with platinum
treatment when the absolute difference between the claim date and the
treatment date is 30 days or less:

```
|datamonth - actdate| <= 30 days
```

## 8. Claim Count Rule

For each patient and care setting, the number of distinct claim months is
calculated as:

```
n_claims = count of distinct datamonth values
```

Grouping variables:

```
patientid + nyugaikbn
```

This count is used for outpatient eligibility. A patient must have at least
two distinct claim months in the outpatient setting:

```
n_claims >= 2
```

## 9. Qualifying Inpatient Claim Rule

A patient has a qualifying inpatient claim when at least one record meets all
of the following criteria:

| Rule | Condition |
|---|---|
| Care setting | `nyugaikbn = 2` |
| First-cancer flag | `cancerfirstflg = 0` |
| Chemotherapy | `chemotherapyflg != 0` |
| FF1 start-date alignment | `fromdate >= ff1startdate` |
| FF1 end-date alignment | `fromdate <= ff1enddate` |

A patient satisfying this rule is assigned the criterion:

```
>=1 inpatient
```

Only one qualifying record is required per patient and `first_yr`.

## 10. Qualifying Outpatient Claim Rule

A patient has qualifying outpatient claims when all of the following
requirements are met:

| Rule | Condition |
|---|---|
| Care setting | `nyugaikbn = 1` |
| Platinum treatment linkage | The patient has a platinum treatment record in Act |
| Temporal alignment | `\|datamonth - actdate\| <= 30 days` |
| Minimum outpatient claims | `n_claims >= 2` |
| Time separation | At least two qualifying outpatient claim months are at least one month apart |

The interval between consecutive claim months is calculated as:

```
gap_months = (current datamonth - previous datamonth) / 30.44
```

A patient meets the time-separation requirement when:

```
gap_months >= 1
```

A patient satisfying this rule is assigned the criterion:

```
>=2 outpatient
```

## 11. Qualifying Claim Rule in Any Care Setting

This criterion combines qualifying outpatient and inpatient records.

### 11.1 Eligible outpatient records

Outpatient records must meet:

```
nyugaikbn = 1
|datamonth - actdate| <= 30 days
```

and must be linked to a platinum treatment record.

### 11.2 Eligible inpatient records

Inpatient records must meet:

```
nyugaikbn = 2
cancerfirstflg = 0
chemotherapyflg != 0
fromdate >= ff1startdate
fromdate <= ff1enddate
```

---

*Screen 5 of 5 not transcribed.*

## What the document tells us about MDV (transcription notes)

Taken from the rules above. Anything not listed here is not in the document
and is marked "to confirm" wherever this folder relies on it.

| Table | Columns the document names | Meaning as the document uses it |
|---|---|---|
| `t_diseasedata` | `patientid`, `diseasecode`, `utagaiflg`, `cancerflg`, `datamonth`, `nyugaikbn`, `fromdate` | one diagnosis on one monthly claim. `utagaiflg = 0` is a confirmed (not suspected) diagnosis; `cancerflg = 1` marks a cancer diagnosis; `datamonth` is the claim month; `nyugaikbn` 1 outpatient, 2 inpatient; `fromdate` is a day-level date compared with the FF1 episode dates |
| `t_patientdata` | `patientid`, `sex` | `sex = 2` is female |
| `t_ff1data` | `patientid`, `ff1startdate`, `ff1enddate`, `cancerfirstflg`, `chemotherapyflg` | one DPC Form 1 inpatient episode: its admission and discharge dates, a first-cancer flag (0 read as first occurrence) and a chemotherapy flag (non-zero = chemotherapy given) |
| `t_m_drug` | `receiptcode`, `receiptname_eng` | the drug master: receipt code and English drug name |
| `t_actdata` | `receiptcode`, `actdate` (and `patientid`, implied by the linkage) | one act (administration or claim line) on a day |
| `JMDC_MDV_Codelist.xlsx` | sheet "MDV disease codes" | the disease-code list the `diseasecode` join reads |

Not in the document: a birth year or age column, a death or discharge-outcome
column, an ICD-10 column on `t_diseasedata`, a days-supplied or count column on
`t_actdata`, any column that says whether an act is oral or injected, and any
procedure table or procedure master.
