# Optum CDM data mapping — GSK 223926 (Aug 26 2026 protocol)

Where every criterion and every variable comes from in the Optum Clinformatics Data
Mart, at table-and-column level, and the caveats that change what a number means.

Sources reviewed for this document:

| document | what it gave |
|---|---|
| `docs/Part 3/Optum/optum data dict.pdf` (24 pp) | **Clinformatics Data Mart Data Dictionary, CDM V9.0**, SES view. Photographed Excel; text layer is OCR garbage, so it was read page by page as images. Sheets: TITLE NOTES, MEMBER_CONTINUOUS_ENROLLMENT, MEMBER_ENROLLMENT, MEDICAL, MED_DIAGNOSIS, MED_PROCEDURE, CONFINEMENT, RX, LABRESULT, PROVIDER, PROVIDER BRIDGE, SES, LU_DIAGNOSIS, LU_NDC, LU_PROCEDURE |
| `docs/Part 3/Optum/optum business rules.pdf` (7 pp) | `Final_Business rule doc_OPTUM_V1_30_08_2022.xlsx` — the table-join diagram, the table inventory, and the 14 "information required → variables → tables → steps" rules |
| `docs/optum enrolment.pdf` (4 pp) | Databricks screenshots: `describe table hive_metastore.clnprw_optum.t_member_enrollment_2025q4` (27 columns) and the observed value distributions of `BUS`, `CDHP`, `PRODUCT` in the MM population |
| `docs/Part 3/Program Spec/*_validated.csv` | the Jan-2026 program spec with an "Optum CDM Implementation" column naming the exact tables and columns used per variable |
| `Jul 28/ndmm/R/**`, `Jul 28/lot/engine/R/**` | the SQL actually issued today |
| `Jul 28/ndmm/DECISIONS.md`, `Jul 28/ndmm/README.md` | the build's own record of what it checked in the CDM and why each rule reads as it does. §6 is a profiling of the warehouse, and it settles two things the vendor documents leave open — see §4 and §7 below |

Identical copies of the two Optum PDFs also sit at `docs/optum *.pdf` and
`Apr 18 2026/Optum - Business Rules/`.

---

## 1. Where the data physically is

Production is Databricks. From `Jul 28/ndmm/config.csv` and
`Jul 28/ndmm/R/db_utils.R:135-143`:

```
catalog  hive_metastore
schema   clnprw_optum
table    t_<base>_<yyyy>q<n>        # cumulative quarterly tables, suffix from STUDY_END
```

so `member_enrollment` with `STUDY_END = 2026-03-31` resolves to
`hive_metastore.clnprw_optum.t_member_enrollment_2026q1`. The enrolment screenshots
in `docs/optum enrolment.pdf` show the 2025q4 vintage of the same table.

Code lists are **not** in the warehouse. They are CSVs under `CODELIST_DIR`,
defaulting to `/mnt/code/codelist` — see `CODELISTS.md`.

## 2. Table inventory

Base names as the build uses them, CDM names as the dictionary writes them.

| build name | CDM sheet | grain | what it carries |
|---|---|---|---|
| `member_enrollment` | MEMBER_ENROLLMENT | one row per member per coverage state | a **new row each time anything about the member changes** (state, product) |
| `member_cont_enrollment` | MEMBER_CONTINUOUS_ENROLLMENT | one row per continuous span | a **rollup** of the above: "one span of continuous enrollment (**less than 30 day break** in coverage) regardless of changes in coverage" |
| `medical` | MEDICAL | one row per claim line | professional (CPT/HCPCS) **and** facility claims |
| `diagnosis` **→ `med_diagnosis`** | MED_DIAGNOSIS | one row per claim per diagnosis position | diagnoses split out of the claim to keep it narrow |
| `procedure` | MED_PROCEDURE | one row per claim per procedure position | ICD-9/10 **procedure** codes (CPT/HCPCS live on MEDICAL.PROC_CD) |
| `confinement` | CONFINEMENT | one row per hospitalisation | "unique record for every hospitalization... all facility detail records are bundled and reported in a single unduplicated row" |
| `rx` | RX | one row per pharmacy fill | outpatient pharmacy only |
| `lab` | LABRESULT | one row per result | "only contains laboratory tests performed within certain laboratory networks" |
| `dod` | DOD | one row per decedent | "**month and year** of death for deceased members" |
| `ses` | SES | one row per member | education, income, home ownership, net worth |
| `provider`, `provider_bridge` | PROVIDER / PROVIDER BRIDGE | one row per provider | credentials, taxonomy, state |
| — | LU_DIAGNOSIS / LU_NDC / LU_PROCEDURE | lookups | code descriptions and groupings |

**The left column is a short name, not the physical table.** The deployed
tables are `t_<physical>_<quarter>`, and for two of them the physical name is
not the short one: **`med_diagnosis`** and **`med_procedure`**, per
`Jul 28/ndmm/R/config.R`, the build that has actually run against this
warehouse. `study223926` conflated the two and read `t_diagnosis_<q>`, which
does not exist — every module reading a diagnosis would have failed on its
first statement. `CDM_TABLE_NAMES` in `R/db_utils_223926.R` now holds the
mapping and `tests/run_tests.R` pins it.

## 3. How the tables join

From the "Table join Information: Optum CDM" diagram, business rules p.1:

```
MEDICAL  ──(PATID | PAT_PLANID, CLMID, FST_DT, LOC_CD)──  MED_DIAGNOSIS
MEDICAL  ──(PATID | PAT_PLANID, CLMID, FST_DT, LOC_CD)──  MED_PROCEDURE
MEDICAL  ──(PAT_PLANID, CONF_ID)───────────────────────  CONFINEMENT
MEMBER_ENROLLMENT / MEMBER_CONTINUOUS_ENROLLMENT
         ──(PATID | PAT_PLANID*, FST_DT between ELIGEFF and ELIGEND)──  MEDICAL
         ──(PATID | PAT_PLANID*, ADMIT_DATE between ELIGEFF and ELIGEND)── CONFINEMENT
         ──(PATID | PAT_PLANID*, FILL_DT between ELIGEFF and ELIGEND)──  RX
         ──(PATID | PAT_PLANID*, FST_DT between ELIGEFF and ELIGEND)──  LABRESULT
         ──(PATID)──  SES
         ──(PATID)──  DOD
MEDICAL / RX ──(PROV | BILL_PROV | REFER_PROV | SERVICE_PROV | Prescriber_PROV)── PROVIDER BRIDGE ──(PROV_UNIQUE)── PROVIDER
```

`*` the diagram's legend: **"Continuous Enrollment: Use PATID. Member Enrollment:
Use PAT_PLANID."**

The build follows this exactly — `Jul 28/ndmm/R/steps/00_mm_cohort.R:76-88` joins
diagnosis to the claim header on `PATID, CLMID, FST_DT` with null-safe equality on
`PAT_PLANID` and `LOC_CD`.

> **Caveat, unresolved.** The business-rules table sheet ends with: *"Note: DOD and
> SES tables cannot be joined since both tables are encrypted differently. However
> the other tables name (MEMBER_ENROLLMENT, MEMBER CONTINUOUS ENROLLMENT, MEDICAL,
> MED_DIAGNOSIS, MED_PROCEDURE, CONFINEMENT, RX, LABRESULT, PROVIDER, PROVIDER
> BRIDGE) and variable names same but all are encrypted differently for DOD and SES
> table."* The join diagram on the same page nevertheless draws `PATID` edges from
> Member Enrollment to both SES and DOD, and the current build joins DOD on `PATID`.
> Confirm before any SES-derived variable is trusted. `OPEN_QUESTIONS.md` Q8.

## 4. Columns, verified

### MEMBER_ENROLLMENT — as deployed

`describe table hive_metastore.clnprw_optum.t_member_enrollment_2025q4`,
27 columns, from `docs/optum enrolment.pdf` pp.1-3:

| # | column | type | # | column | type |
|---|---|---|---|---|---|
| 1 | `PATID` | bigint | 15 | `ELIGEND_SASDT` | int |
| 2 | `PAT_PLANID` | bigint | 16 | `FAMILY_ID` | bigint |
| 3 | `ASO` | varchar(1) | 17 | `GDR_CD` | varchar(1) |
| 4 | `BUS` | varchar(5) | 18 | `GROUP_NBR` | varchar(20) |
| 5 | `CDHP` | varchar(1) | 19 | `HEALTH_EXCH` | varchar(1) |
| 6 | `ELIGEFF` | date | 20 | `PRODUCT` | varchar(5) |
| 7 | `ELIGEFF_DAY` | smallint | 21 | `RACE` | varchar(1) |
| 8 | `ELIGEFF_MONTH` | smallint | 22 | `STATE` | varchar(2) |
| 9 | `ELIGEFF_YEAR` | smallint | 23 | `YRDOB` | smallint |
| 10 | `ELIGEFF_SASDT` | int | 24 | `EXTRACT_YM` | varchar(6) |
| 11 | `ELIGEND` | date | 25 | `VERSION` | varchar(6) |
| 12 | `ELIGEND_DAY` | smallint | 26 | `ETHNICITY` | varchar(1) |
| 13 | `ELIGEND_MONTH` | smallint | 27 | `RACE_SOURCE` | varchar(15) |
| 14 | `ELIGEND_YEAR` | smallint | | | |

Observed values in the MM population (`docs/optum enrolment.pdf` p.4):

| field | values (n patients) |
|---|---|
| `BUS` | `MCR` 17,874 · `COM` 5,758 |
| `PRODUCT` | `OTH` 16,066 · `HMO` 6,726 · `POS` 3,995 · `PPO` 2,569 · `EPO` 1,054 · `IND` 241 |
| `CDHP` | `U` 16,975 · `3` 7,467 · `2` 1,121 · `1` 551 |

So the protocol's **insurance type (Medicare / Commercial Health Plan)** is
`BUS` — `MCR` / `COM`. `PRODUCT` is the plan form, a different axis.

> **The deployed table is a different CDM vintage from the dictionary.** The V9.0
> dictionary's MEMBER_ENROLLMENT sheet lists **20** columns: PATID, PAT_PLANID, ASO,
> BUS, CDHP, ELIGEFF, ELIGEND, GDR_CD, GROUP_NBR, HEALTH_EXCH, **LIS_DUAL**, PRODUCT,
> YRDOB, EXTRACT_YM, VERSION, FAMILY_ID, ETHNICITY, RACE, RACE_SOURCE, **REGION**. The
> deployed 2025q4 table has **27**, and the arithmetic is exact:
> `20 − REGION − LIS_DUAL + STATE + 8 date-part columns = 27`. So the warehouse is
> serving a **pre-V9.0** extract (it still has `STATE`, which V9.0 removed, and lacks
> `REGION` and `LIS_DUAL`, which V9.0 has), with `ELIGEFF_DAY/_MONTH/_YEAR/_SASDT` and
> `ELIGEND_*` decompositions added on the Databricks side. Read the dictionary as
> documentation of a **different** version from the one you will query, and
> `describe table` before writing any column into code.

> **The deployed table has `STATE`, not `REGION`.** The CDM V9.0 dictionary's
> revision note says V9.0 *"Added BILL_PROC_CD, ETHNICITY, PROV_REGION, REGION,
> FAMILY_ID, RACE_SOURCE... Removed DIVISION and PROV_STATE"*, and its
> MEMBER_ENROLLMENT sheet defines `REGION` as *"The US Census Region associated with
> the member address"* (a 04-04-2025 revision changed that description "from
> provider address to member address"). The 2025q4 production table carries `STATE`
> and no `REGION`. The protocol asks for Region on the US Census Bureau definition
> (Midwest / South / West / Northeast / Unknown), so either `REGION` appears in the
> 2026q1 vintage or the build derives region from `STATE` with a 50-state → 4-region
> crosswalk. **Run `describe table` before writing that code.**
> `OPEN_QUESTIONS.md` Q9.

`RACE` is `varchar(1)`; the dictionary gives the reported values as *"African
American, Asian, Caucasian, Other/Unknown (includes patients with HIPAA-restricted
cell sizes)"*, and notes it was **moved from the SES file and renamed from
`D_RACE_CODE`** in V9.0. The protocol's categories are Asian / Black / White /
Unknown — a straight relabel, with African American → Black and Caucasian → White.

`ETHNICITY` is `varchar(1)` with lookup `ETHNICITY`; the dictionary's description
column for it reads *"Member's ethnicity flag"* and the value list is marked
**"Intentionally Blank"** — the code values are not published in this dictionary.
The protocol wants Hispanic or Latino / Not Hispanic or Latino / Unknown. **Profile
the column before mapping.** `OPEN_QUESTIONS.md` Q10.

**Medicare markers the dictionary documents but the deployed table does not carry.**
`LIS_DUAL` ("Indicates whether member policy is Low Income Subsidy (LIS) or
Medicaid/Medicare (DUAL). **Available on Medicare members only**") would be a direct
Medicare marker — it is in V9.0 and absent from the deployed table. `RX.FORM_TYP`
("Type of formulary used to pay a claim... **NULL for Medicare**") is an indirect one
that *is* available. `ASO` is `Y`/`N` for self-funded commercial. None of these
replaces `BUS`; they are cross-checks for it.

**The lookup value sets are not supplied.** The dictionary's LOOKUP column names about
25 code tables — `RACE`, `ETHNICITY`, `REGION`, `BUS_LINE`, `PRODUCT`, `CDHP`,
`HEALTH_EXCH`, `LIS_DUAL`, `POS`, `LOC_CD`, `DRG`, `DISCHSTATUS`, `ADMIT_TYPE`,
`ADMIT_CHAN`, `RVNU_CD`, `BILL_TYPE`, `PROVCAT`, `TOS_CD`, `TOS_EXT`, `PAID_STATUS`,
`IPSTATUS`, `DAW`, `FORM_TYP`, `SPECCLSS`, `AHFSCLSS` and the `D_*` socio-economic
codes — but only three lookup tabs are actually in the PDF: `LU_DIAGNOSIS`, `LU_NDC`
and `LU_PROCEDURE`. Every value mapping this study needs for a categorical variable
(`RACE` → Asian/Black/White, `ETHNICITY` → Hispanic/Not Hispanic, `BUS` →
Medicare/Commercial) has to come from the lookup tables in the warehouse or by
profiling the column. `OPEN_QUESTIONS.md` Q10.

**One tie-break the dictionary does give.** On MEMBER_CONTINUOUS_ENROLLMENT, `GDR_CD`
carries the note *"If more than one value exists, use latest value that is not 'U'
UNKNOWN"*. Nothing equivalent is documented for `RACE`, `ETHNICITY`, `BUS` or
`STATE`. `OPEN_QUESTIONS.md` Q16.

`YRDOB` is year of birth, **capped at 89** (dictionary revision 04-14-2025: *"Edit
YRDOB descriptions from capped 90 to capped at 89 years"*). There is no date of
birth. Age is therefore only ever `index year − YRDOB`, which is what the protocol
asks for ("according to calendar year").

**No medical-benefit or pharmacy-benefit flag exists on this table.** See §7.

### MEMBER_ENROLLMENT — the attributes are time-varying, not fixed

`MEMBER_ENROLLMENT` carries **one row per member per change of anything**, so `BUS`,
`PRODUCT`, `CDHP`, `STATE` and even `GDR_CD` are **span-level attributes**, not
patient-level ones. The distributions on `docs/optum enrolment.pdf` p.4 prove it: each
is a `count(DISTINCT PATID)` grouped by value, and the three totals disagree —
`BUS` sums to 23,632, `CDHP` to 26,114, `PRODUCT` to 30,651. A patient appearing under
two values of one field must hold two enrolment rows with different attributes.

So "is this patient Medicare or Commercial?" has no single answer. Every Table 4
demographic timed "at index" has to be read off **the enrolment row covering the index
date**, with a documented tie-break when more than one row covers it. Neither Optum
document says how to break that tie. `OPEN_QUESTIONS.md` Q16.

The existing build already faces this for sex and birth year and resolves it by
ranking rows — a usable birth year first, then a known sex, then the most recent
`ELIGEND`, then the values themselves for determinism
(`Jul 28/ndmm/R/steps/00_mm_cohort.R:144-170`). That rule is **not** "the row covering
the index date", so it will need revisiting for the new demographics.

### MEMBER_CONTINUOUS_ENROLLMENT

`PATID`, `ELIGEFF`, `ELIGEND`, `GDR_CD`, `YRDOB`, `RACE`, `ETHNICITY`,
`RACE_SOURCE`, `EXTRACT_YM`, `VERSION`. Filename `ses_mbr_co_enroll_CCYY`.
One row per continuous span, bridging breaks of **less than 30 days**.

> This rollup is **not** what the protocol asks for. The protocol allows gaps of
> **≤ 30 days**; the rollup bridges **< 30 days**. A 30-day gap is continuous to the
> protocol and a break to the rollup. The build already builds its own spans from
> `MEMBER_ENROLLMENT` for exactly this reason
> (`Jul 28/ndmm/R/steps/01_enrollment.R:1-8`). Keep doing that.

### MEDICAL

Claim-level. Columns that matter here:

| column | use |
|---|---|
| `PATID`, `PAT_PLANID`, `CLMID`, `CLMSEQ` | identity and join keys |
| `FST_DT`, `LST_DT` | first / last date of service |
| `LOC_CD` | part of the diagnosis and procedure join key |
| `CONF_ID` | links to CONFINEMENT; **null ⇒ non-inpatient** |
| `POS` | place of service |
| `TOS_CD`, `TOS_EXT` | type of service |
| `PROC_CD`, `BILL_PROC_CD`, `PROCMOD`..`PROCMOD4` | CPT / HCPCS Level II — this is where **J-codes for administered MM agents** live |
| `RVNU_CD` | revenue code — needed for the pregnancy exclusion and for ED identification |
| `NDC`, `NDC_QTY`, `NDC_UOM` | NDC on a medical claim; Optum writes `NONE`/`UNK` where there is none |
| `UNITS`, `ALT_UNITS` | units administered |
| `DRG`, `DSTATUS`, `ADMIT_TYPE`, `ADMIT_CHAN`, `BILL_TYPE` | facility detail |
| `ICD_FLAG` | `'9'` or `'10'` |
| `PROV`, `BILL_PROV`, `REFER_PROV`, `SERVICE_PROV`, `PROVCAT`, `PROV_PAR` | provider links |
| `CHARGE`, `COPAY`, `COINS`, `DEDUCT`, `COB`, `STD_COST`, `STD_COST_YR` | cost |
| `OP_VISIT_ID`, `ENCTR`, `HCCC`, `PAID_DT`, `PAID_STATUS` | admin |

### MED_DIAGNOSIS

`PATID`, `PAT_PLANID`, `CLMID`, `DIAG`, `DIAG_POSITION`, `ICD_FLAG`, `LOC_CD`,
`POA`, `FST_DT`, `EXTRACT_YM`, `VERSION`. Filename `ses_diagCCYYq#`.

- `DIAG` is the ICD-9/ICD-10-CM code **without a decimal point** — so `C90.00`
  is stored `C9000` and `203.00` is stored `20300`. The build normalises both sides
  with `upper(regexp_replace(x,'[^A-Za-z0-9]',''))`.
- `DIAG_POSITION` runs **1 to 25**; business rules: *"patients with
  DIAG_POSITION=1 can be typically considered as the primary diagnosis"*. The
  protocol's MM criterion is "in any position", so no filter. The MM-related
  hospitalisation variable is "first or second position" — that is `DIAG_POSITION IN
  (1,2)` on MED_DIAGNOSIS, or `DIAG1`/`DIAG2` on CONFINEMENT.
- `ICD_FLAG` is `'9'` for ICD-9 and `'10'` for ICD-10.
- `POA` is present-on-admission.

### MED_PROCEDURE

`PATID`, `PAT_PLANID`, `CLMID`, `PROC`, `PROC_POSITION`, `ICD_FLAG`, `LOC_CD`,
`FST_DT`, `EXTRACT_YM`, `VERSION`. Filename `ses_procCCYYq#`.
`PROC` is the **ICD-9/10 procedure** code. CPT and HCPCS are on `MEDICAL.PROC_CD`.
Both matter for SCT and CAR-T identification.

This is measured, not assumed. `Jul 28/ndmm/DECISIONS.md` §6: over the study period
`PROC` is **43,137,224 of ~43.2M rows at `ICD_FLAG='10'` and seven characters** —
ICD-10-PCS. The five-character tail, the only shape a HCPCS or CPT code could occupy,
is about **15,000 rows, 0.035%**. That settles the contradiction in the business rules
(§5 below), and it is why the build still reads `PROC` as a fifth medication source:
the failure is asymmetric — a therapy the scan cannot see lets a patient pass the
no-prior-therapy criterion on missing data.

### CONFINEMENT

`PATID`, `PAT_PLANID`, `CONF_ID`, `ADMIT_DATE`, `DISCH_DATE`, `LOS`,
`DIAG1`..`DIAG5`, `PROC1`..`PROC5`, `DRG`, `DSTATUS`, `ICD_FLAG`, `IPSTATUS`,
`POS`, `TOS_CD`, `PROV`, `CHARGE`, `COINS`, `COPAY`, `DEDUCT`, `STD_COST`,
`STD_COST_YR`, `ICU_IND`, `ICU_SURG_IND`, `MAJ_SURG_IND`, `MATERNITY_IND`,
`NEWBORN_IND`, `TOS_EXT`, `EXTRACT_YM`, `VERSION`. Filename `ses_cCCYYq#`.

This is the table for all-cause and MM-related hospitalisation: `LOS` is carried
directly, `DIAG1`/`DIAG2` give the MM-related test, `DSTATUS` gives discharge
disposition, and `ADMIT_DATE`/`DISCH_DATE` bound the stay.

### RX

`PATID`, `PAT_PLANID`, `CLMID`, `NDC`, `FILL_DT`, `DAYS_SUP`, `QUANTITY`,
`STRENGTH`, `BRND_NM`, `GNRC_NM`, `GNRC_IND`, `DAW`, `DEA`, `NPI`, `PHARM`,
`PRESCRIBER_PROV`, `PRESCRIPT_ID`, `RFL_NBR`, `FST_FILL`, `AHFSCLSS`, `SPECCLSS`,
`SPCLT_IND`, `MAIL_IND`, `FORM_IND`, `FORM_TYP`, `PRC_TYP`, `AVGWHLSL`, `CHARGE`,
`COPAY`, `DEDUCT`, `DISPFEE`, `STD_COST`, `STD_COST_YR`, `CHK_DT`, `EXTRACT_YM`,
`VERSION`. Filename `ses_rCCYYq#`.

The day-supply column is **`DAYS_SUP`**, not `DAY_SUPPLY`. Oral MM agents
(lenalidomide, pomalidomide, ixazomib, thalidomide, cyclophosphamide, melphalan,
panobinostat, selinexor, dexamethasone) come through here; infusions do not.

### LABRESULT

`LOINC_CD`, `TST_DESC`, `RSLT_TXT`, `RSLT_NBR`, `HI_NRML`, `LOW_NRML`, `FST_DT`.
Business rules: use `LOINC_CD` where present, `TST_DESC` where not
(*"tst_desc='PLATELETS'"* is their worked example). Coverage is partial —
*"only contains laboratory tests performed within certain laboratory networks"* —
which is why the protocol marks thrombocytopenia and anaemia
*"dependent on data availability"*.

### DOD

`PATID`, `YMDOD`. **Month and year only.** `YMDOD` is a `CCYYMM` string. The build
coarsens it to the 15th of the month, or the month end where the 15th would fall
before the diagnosis (`Jul 28/ndmm/R/steps/00_mm_cohort.R:172-215`). Every
day-level survival number inherits that ±15-day uncertainty. Note also that this
table is **not in the CDM V9.0 dictionary** — it is a separate mortality file.

### SES

`PATID`, `D_EDUCATION_LEVEL_CODE`, `D_HOME_OWNERSHIP_CODE`,
`D_HOUSEHOLD_INCOME_RANGE_CODE`, `D_NETWORTH_RANGE_CODE`, `EXTRACT_YM`, `VERSION`.
Filename `ses_ses_CCYY`. Nothing the protocol asks for is here — race moved off
this file in V9.0.

---

### What the business rules do NOT say

Reviewed in full and genuinely absent. Each of these is a decision the build has to
make without documentation:

| topic | status |
|---|---|
| **Valid claims / exclusions** | No definition of a valid claim, and no rule for reversals, denials, duplicates, capitated encounters or adjustments. No claim-status or payment-status filter is named anywhere. The word "unduplicated" appears once, inside the CONFINEMENT bundling description |
| **Member-months / person-time** | No denominator convention at all. In particular it is **never stated whether the days inside a bridged sub-30-day gap count as covered person-time** — which directly changes every person-year denominator the protocol asks for (`OPEN_QUESTIONS.md` Q19) |
| **Overlapping spans** | Never addressed. Sequential non-overlapping rows are implied within a `PAT_PLANID`; overlap across `PAT_PLANID`s for one `PATID` (dual coverage, mid-month switch) is neither asserted nor excluded |
| **Gap-rule precision** | "less than 30 day break in coverage" is the whole specification. Whether the boundary is `< 30` or `<= 30`, and how the break is computed, are not written |
| **ICD-9 → ICD-10 transition** | Only `ICD_FLAG` is supplied. No cut-over date, no crosswalk guidance, no instruction to specify a condition in both vocabularies |
| **Code formatting** | Decimal points, padding and justification are absent from the business rules; the convention ("Level 1 ICD-X as entered on the claim, **without decimal point**") is in the data dictionary's MED_DIAGNOSIS sheet instead |
| **Date shifting** | None documented. The only truncation is death (`YMDOD`, month + year), with no day-imputation convention supplied |
| **Inpatient-administered drugs** | The gap is implied by RX being "prescriptions filled on an **outpatient** basis" and never stated outright |
| **Medicare Advantage vs Commercial** | No caveat of any kind. Nothing on Part D vs commercial drug capture, MA encounter-data completeness, or how to assign a segment to a member whose `BUS` changes across spans |
| **Completeness by year** | No claims run-out or lag convention, and no incomplete-recent-quarter warning |

Two further points worth carrying into any implementation review:

- **An internal contradiction in the rules document.** Rule 5 (p.6) assigns `PROC_CD` /
  `T_MEDICAL` to ICD-9/ICD-10 and `PROC` / `T_MED_PROCEDURE` to HCPCS/CPT — the exact
  inverse of rule 3 (pp.4-5) and of the MEDICAL table description on p.2. Rule 3 is
  corroborated by the rest of the workbook and by the data dictionary, and is what the
  current build follows — and by that build's own profiling of 43.2M `PROC` rows (§4).
  **Rule 5 is a transcription error.** `OPEN_QUESTIONS.md` Q17.
- **Vintage.** The rules are `Final_Business rule doc_OPTUM_V1_30_08_2022.xlsx` — an
  August 2022 rule set being applied to a 2025Q4/2026Q1 extract, against a CDM V9.0
  dictionary released September 2023. No revalidation is recorded.
  `OPEN_QUESTIONS.md` Q18.

All three copies of the business rules in this repo are byte-identical
(`md5 f02f37c51797a77a408b81fea30a8f3f`): `docs/Part 3/Optum/`, `docs/`, and
`Apr 18 2026/Optum - Business Rules/`. The April folder introduced no revision.

## 4b. Read back off the source documents, page by page

Everything in this section was read from the images of
`docs/Part 3/Optum/optum data dict.pdf` (24 pages, `2025_05_CDM Data Dictionary
V9 SES.xls`, last modified 18-08-2025), `optum business rules.pdf` (7 pages,
`Final_Business rule doc_OPTUM_V1_30_08_2022.xlsx`) and the four `describe
table` screenshots in `docs/optum enrolment.pdf`. The text layers are OCR
garbage; these are the pictures.

### The deployed enrolment table, all 27 columns

`describe table hive_metastore.clnprw_optum.t_member_enrollment_2025q4` returns
**27 rows**, in this order:

| # | column | type | | # | column | type |
|---|---|---|---|---|---|---|
| 1 | `PATID` | bigint | | 15 | `ELIGEND_SASDT` | int |
| 2 | `PAT_PLANID` | bigint | | 16 | `FAMILY_ID` | bigint |
| 3 | `ASO` | varchar(1) | | 17 | `GDR_CD` | varchar(1) |
| 4 | `BUS` | varchar(5) | | 18 | `GROUP_NBR` | varchar(20) |
| 5 | `CDHP` | varchar(1) | | 19 | `HEALTH_EXCH` | varchar(1) |
| 6 | `ELIGEFF` | **date** | | 20 | `PRODUCT` | varchar(5) |
| 7 | `ELIGEFF_DAY` | smallint | | 21 | `RACE` | varchar(1) |
| 8 | `ELIGEFF_MONTH` | smallint | | 22 | `STATE` | varchar(2) |
| 9 | `ELIGEFF_YEAR` | smallint | | 23 | `YRDOB` | smallint |
| 10 | `ELIGEFF_SASDT` | int | | 24 | `EXTRACT_YM` | varchar(6) |
| 11 | `ELIGEND` | **date** | | 25 | `VERSION` | varchar(6) |
| 12 | `ELIGEND_DAY` | smallint | | 26 | `ETHNICITY` | varchar(1) |
| 13 | `ELIGEND_MONTH` | smallint | | 27 | `RACE_SOURCE` | varchar(15) |
| 14 | `ELIGEND_YEAR` | smallint | | | | |

Two things follow that the earlier reading got wrong or missed.

**`ETHNICITY` and `RACE_SOURCE` do exist** — appended at 26 and 27, after
`VERSION`, which is where a later addition lands. The ordering is source order
with Databricks date-parts interleaved, not alphabetical, so their absence
could not have been inferred from position.

**`REGION` and `LIS_DUAL` do not.** The V9.0 dictionary annotates four
MEMBER_ENROLLMENT additions — `ETHNICITY` ("Added", value list *Intentionally
Blank*), `RACE` ("**Moved from SES file and renamed from D_RACE_CODE**"),
`RACE_SOURCE` ("Added") and `REGION` ("Added"). Three landed; `REGION` did not,
and `STATE`, which V9.0 removed, is still there. So the extract is not simply
"a version behind": it is a hybrid, and `REGION` specifically is the one the
region variable would need. `REGION_SOURCE=region_column` is refused in
`R/config_223926.R` for exactly this reason.

The V9 move is also visible from the other side: the **SES** sheet
(`ses_ses_CCYY`) now carries only `PATID`, `D_EDUCATION_LEVEL_CODE`,
`D_HOME_OWNERSHIP_CODE`, `D_HOUSEHOLD_INCOME_RANGE_CODE`,
`D_NETWORTH_RANGE_CODE`, `EXTRACT_YM`, `VERSION` — **no race**. The 2022
business-rules document still describes SES as "seven consumer characteristics
**including race**", so that document is demonstrably out of date on a point we
can check. `OPEN_QUESTIONS.md` Q18.

### `YRDOB` is capped

> "The member's year of birth, **capped at 89 years**."

The TITLE NOTES change log records this being edited on 14-04-2025 *"from
capped 90 to capped at 89 years"*, so the cap value itself has moved and may
differ by extract vintage.

The age **bands** are unaffected — the cap sits above the 75 cut-point Table 4
and §7.8.1 use. A **mean or median** age is not: it is right-censored, and
myeloma has a real tail above 89. Table 4 asks for both.

### Columns the study does not use and probably should consider

| column | table | what it is | why it matters |
|---|---|---|---|
| `PAID_STATUS` | MEDICAL | *"PAID if Sum of all Paid Amounts >= $0, DENIED if Sum of all Paid Amounts < $0"* | a denied claim is not evidence a service happened; nothing here or in the cohort build filters on it. `CLAIM_STATUS` setting, `OPEN_QUESTIONS.md` Q25 |
| `POA` | MED_DIAGNOSIS | Present on Admission — *"conditions that develop during outpatient encounter, including emergency department, observation, or outpatient surgery, are considered POA"* | separates a condition present at admission from one acquired in hospital; bears directly on "severe infection **resulting in** hospitalization" |
| `CLMSEQ` | MEDICAL | *"distinguishes between the detail records for a claim. Use with CLMID"* | the documented MED_DIAGNOSIS↔MEDICAL join is `PATID + CLMID + FST_DT + LOC_CD` and omits it, so that join can fan out across a claim's detail lines |
| `RACE_SOURCE` | MEMBER_ENROLLMENT | *"Member match with race data source"* | Optum imputes race for some members; a race table that does not report the source composition is incomplete |
| `LST_DT` | MEDICAL | the service **end** date (`FST_DT` is the beginning) | multi-day services have a span this package reads as a point |
| `ENCTR` | MEDICAL | fee-for-service vs capitated | encounters under capitation can be under-reported |
| `OP_VISIT_ID` | MEDICAL | an outpatient visit grouper | would be the vendor's own visit grain for ED — but *"generated by the Standard Cost Algorithm upon each run"*, so it is not stable across refreshes. Considered and rejected; this package groups ED claims to one per patient per day instead |

### Confirmations that settle earlier uncertainty

- **`CONFINEMENT.ICD_FLAG` exists** (row 21, *"ICD Version Code – will
  distinguish between ICD-9 and ICD-10 codes"*). A comment in `07_hcru.R` once
  claimed it did not and derived the family from the admission date; the flag
  is read now, with the date kept only as a fallback.
- **`ICD_FLAG` values are `'9'` and `'10'`** — business rule 1, verbatim.
- **`DIAG_POSITION` runs 1 to 25**, and *"patients with DIAG_POSITION=1 can be
  typically considered as the primary diagnosis"* — business rule 1.
- **`DIAG` is stored without a decimal point** — MED_DIAGNOSIS row 8.
- **`MEDICAL.PROC_CD` is CPT/HCPCS**; `MED_PROCEDURE.PROC` is ICD-9/ICD-10 with
  `ICD_FLAG`. The dictionary says so directly (MEDICAL row 30, *"CPT/HCPCS
  Procedure code that describes the service provided"*) and business rule 3
  agrees. Business rule **5 says the opposite**; the dictionary wins.
  `OPEN_QUESTIONS.md` Q17.
- **`RVNU_CD` is *"Facility Claims only"*.** So the revenue-code arm of the ED
  construction can only ever match facility claims, while the CPT arm matches
  professional ones — the three constructions do not merely disagree in number,
  they select different claim types. One ED visit generating both a facility
  and a professional claim is collapsed by this package's one-per-patient-per-day
  grain.
- **`CLMID`**: *"A provider can bill multiple revenue codes for services
  rendered on one claim. Each revenue code will generate a claim line.
  Providers typically submit separate claim for each visit."*
- **`CONFINEMENT.LOS`** is *"Length of Stay from start of first confinement [to]
  last confinement record"* — a span over bundled records, not
  discharge − admit. The protocol wants admit (included) → discharge
  (excluded), which is what this package computes; it does not read `LOS`.
- **`ADMIT_DATE` / `DISCH_DATE` are documented `YYYYMMDD`**, not `DATE`. The
  deployed enrolment table shows Databricks converting Optum's `YYYYMMDD` to a
  real `date` plus `_DAY`/`_MONTH`/`_YEAR`/`_SASDT` parts, so CONFINEMENT is
  probably converted too — but that is an inference from one table. See the ask
  below.
- **Continuous enrolment**: the rollup bridges *"less than 30 day break in
  coverage"* (business rule 11 and the table description), while §7.2.1.1
  allows 30 **or fewer**. And business rule 10 says that from MEMBER_ENROLLMENT
  *"user will be required to **stitch** the data to find start and end dates for
  continuous enrollment"*, which is what `build_enroll_spans()` does.
- **Inpatient identification** — business rule 14 gives two approaches:
  `POS IN (21, 51, 61)` or `TOS_CD IN ('FAC.IP.ACUTE', 'FAC.IP.REHSNF',
  'PROF.INPVIS', 'FAC.IP.SNF')`; or `CONF_ID IS NOT NULL`, with *"all other
  records without a CONF_ID or where CONF_ID is NULL should be considered
  non-inpatient"*. This package uses CONFINEMENT directly, which is the second.
- **The CDM has no ED flag, and the vendor says so**: rule 14's own note is
  *"Non-inpatient records can be classified into various categories **as per the
  study requirements**"*. Q11 is a study decision, not a lookup.

### One ask this pass generates

There is a `describe table` for **one** of the six CDM tables this study reads.
Everything above about the deployed shape of MEDICAL, MED_DIAGNOSIS,
CONFINEMENT, RX and DOD is inferred from the dictionary plus that one example.
`describe table` on the other five costs a minute each and would settle the
date types, whether `BILL_PROC_CD` (a V9 addition) is populated, and whether
`CONFINEMENT.ICD_FLAG` is actually present in this vintage.

*Answered 07 Sep 2026, in part — see section 4c. `CONFINEMENT.ICD_FLAG` is
present and `MEDICAL.PAID_STATUS` carries `P`/`D` rather than the dictionary's
`PAID`/`DENIED`. `BILL_PROC_CD` was not profiled and is still unknown.*

## 4c. Value domains, measured 07 Sep 2026

`SQL Result 2.pdf` profiled the columns section 4b could only infer. Everything
here is a measured value, not a dictionary reading, and three of them contradict
the dictionary.

| column | values found | consequence |
|---|---|---|
| `MEMBER_ENROLLMENT.GDR_CD` | `F` 108,308,094 · `M` 102,595,572 · `U` 88,388 | `U` is 0.04%. The build maps M/F and sends the rest to Unknown, which is right |
| `MEMBER_ENROLLMENT.STATE` | **53 distinct values** | `CENSUS_REGION` carries 51 (50 states + DC), so two values fall to region Unknown. **Which two is not yet known** — the profile listed by descending count and the tail was not captured |
| `MED_DIAGNOSIS.DIAG_POSITION` | **zero-padded strings**: `01`, `02`, `03`, … 26 distinct | A string comparison against `'1'` matches nothing. Anything reading this must cast. The test fixture is now zero-padded so a regression fails rather than passing on synthetic data that does not look like the warehouse |
| `MED_DIAGNOSIS.ICD_FLAG` | `10` and `9` | as documented |
| `CONFINEMENT.ICD_FLAG` | **present** — `10` 23,453,669 · `9` 15,054,996 · null 1,666 | section 4b could not confirm this column existed. It does. The admit-date fallback still earns its place for the 1,666 nulls |
| `MEDICAL.PAID_STATUS` | **`P` and `D`** — 2 values, no nulls table-wide since 2024 | **The V9.0 dictionary spells these `PAID` and `DENIED`. The warehouse does not.** Any filter written from the dictionary is inert. Among myeloma patients specifically the split is P 78.69% / D 17.42% / null 3.89% |
| `MEDICAL.CONF_ID` | null or populated only — no `0`, no blank | Business rule 14's test is `CONF_ID IS NULL` and nothing else. 186,547,530 lines across 2,805,263 members carry one; 182,711,199 lines across 21,932,322 members do not |
| `DOD.MBR_MATCH_TYPE` | `2` 58.93% · `1` 41.07% | Two values, no nulls: a binary flag, not a graded score. Which value means what is still undocumented anywhere we hold |

### `CONFINEMENT` shape

Across 241,362 stays belonging to myeloma patients since 2018:

* **No stay is missing a discharge date.** Zero. The protocol's provision for
  excluding such stays from LOS summaries never fires, and `N_LOS_EXCLUDED`
  will be 0 on every table this study produces.
* `LOS` equals `datediff(DISCH_DATE, ADMIT_DATE)` on 235,733 stays and differs
  on 5,629 (2.3%). Means 8.87 against 8.84. The build computes its own, which
  the dictionary's note about `LOS` spanning bundled records supports.

### The ask in section 4b is now closed

`CONFINEMENT.ICD_FLAG` and `MEDICAL.PAID_STATUS` were the two columns that
`describe table` had not covered. Both exist. `PAID_STATUS` carries values the
dictionary spells differently, which is the more useful half of the answer.

## 5. Identifying inpatient vs outpatient

The protocol leans on this twice (MM diagnosis, other-cancer exclusion). The
business rules give two approaches, and the current build applies **both, OR'd**.

**Approach 1 — service codes**
```
inpatient  ⇔  POS IN ('21','51','61')
              OR TOS_CD IN ('FAC_IP.ACUTE','FAC_IP.REHSNF','PROF.INPVIS','FAC_IP.SNF')
outpatient ⇔  none of the above
```

**Approach 2 — confinement**
> *"Inpatient records should be restricted to cases where CONF_ID is not NULL, from
> the T_CONFINEMENT table, where this has associated admission and discharge dates...
> All other records without a CONF_ID or where CONF_ID is NULL should be considered
> non-inpatient."*

`Jul 28/ndmm/R/steps/00_mm_cohort.R:27-90` flags a claim inpatient if **either**
holds, and flags it at the claim-line level before `max(POS)` can hide an inpatient
code. Keep that — it is the conservative reading and it matches how the Jan-2026
program spec was validated.

## 6. Identifying emergency department visits

The protocol needs ED visits (Primary Objective 1 and 2, healthcare utilisation).
The CDM has **no ED flag**. The usual claims constructions are:

- `MEDICAL.RVNU_CD` in the 045x range (0450, 0451, 0452, 0456, 0459) and 0981;
- `MEDICAL.POS = '23'` (emergency room — hospital);
- `MEDICAL.PROC_CD` in 99281-99285.

`MEDICAL.TOS_EXT` ("the full type of service value derived by the algorithm... most
specific level of classification") plausibly carries an ED category, but its lookup
values are not in the dictionary, so it cannot be confirmed from the documentation.
`MEDICAL.OP_VISIT_ID` can group claim lines into a single outpatient visit, which is
what stops one ED encounter being counted as several events. The only place the phrase
"emergency department" appears in the whole dictionary is inside the `MED_DIAGNOSIS.POA`
description, which is not an ED identifier.

None of these is in a repo code list today. `CODELISTS.md` §3 lists it as
outstanding, and `OPEN_QUESTIONS.md` Q11 asks the study team which construction
they want, since the three disagree materially.

## 7. Medical **and** pharmacy benefits

Inclusion criterion I4 requires 12 months of CE "with medical and pharmacy
benefits". The evidence:

- `MEMBER_ENROLLMENT` as deployed has no benefit-type flag (27 columns, §4 above).
  `ASO`, `CDHP`, `HEALTH_EXCH`, `PRODUCT`, `BUS` are funding/plan attributes, not
  benefit indicators.
- The CDM V9.0 dictionary likewise shows no medical/Rx benefit column on either
  member table.
- The protocol's own §7.5 says: *"All patients in this database have both medical
  and pharmacy coverage, allowing analysis of overall healthcare utilization."*
  (screen 38)

`Jul 28/ndmm/DECISIONS.md` §6 reaches the same conclusion from the same schema, and
rules out the obvious alternative explicitly:

> "Medical and pharmacy benefits are **satisfied by construction**... A span carries
> both, so `ELIGEFF`/`ELIGEND` already express the requirement and **a predicate would
> filter on nothing**."

> "**Do not re-derive this from claims.** Enrolled patients with no pharmacy fill look
> like a coverage signal and are not: that count is dominated by short spans and by
> patients whose only MM code is a rule-out."

So there is nothing to write, and the claims proxy is a trap. `OPEN_QUESTIONS.md` Q4.

## 8. Variable → source, criteria

| criterion | tables | columns | rule |
|---|---|---|---|
| I1 MM diagnosis | `diagnosis` + `medical` + `confinement` | `DIAG`, `ICD_FLAG`, `FST_DT`, `DIAG_POSITION`(unused: any position), `POS`, `TOS_CD`, `CONF_ID`, `ADMIT_DATE`, `DISCH_DATE` | 1 IP claim with 203.0x/C90.0x, or 2 OP claims ≤ 90 d apart on separate days |
| I2 age ≥ 18 | `member_enrollment` (or `member_cont_enrollment`) | `YRDOB` | `year(MM_DX_DT) - YRDOB >= 18` |
| I3 eligible 1L treatment | `rx` + `medical` + `procedure` | `NDC`, `FILL_DT`; `PROC_CD`, `BILL_PROC_CD`, `NDC`, `FST_DT`; `PROC`, `ICD_FLAG`, `FST_DT` | earliest claim matching the eligible-1L code list, on/after `MM_DX_DT`, on/after 2019-01-01, agent not in {belantamab, panobinostat, elotuzumab} |
| I4 12-month CE | `member_enrollment` | `PATID`, `ELIGEFF`, `ELIGEND` | build spans bridging gaps ≤ 30 d; require one span covering `[index-365, index-1]` and the index date |
| I5 follow-up | `medical` + `rx`, `dod` | `FST_DT`, `FILL_DT`, `YMDOD` | ≥ 1 claim on/after index, or a death record |
| X1 prior MM therapy | `rx` + `medical` + `procedure` | as I3 | any MM oncology agent in `[index-365, index-1]` |
| X2 other cancer | `diagnosis` + `medical` + `confinement` | `DIAG`, `ICD_FLAG`, `FST_DT`, `POS`, `TOS_CD`, `CONF_ID` | ≥ 1 IP, or ≥ 2 OP on separate days ≤ 30 d apart, same tumour group and/or metastatic, in `[index-365, index-1]` |
| X3 pregnancy | `diagnosis` + `medical` + `procedure` | `DIAG`, `PROC_CD`, `BILL_PROC_CD`, `RVNU_CD`, `PROC` | ≥ 1 claim with a pregnancy/childbirth diagnosis, procedure **or revenue** code, anywhere in the study period |
| X4 belantamab | `rx` + `medical` + `procedure`, then LOT tables | as I3 | any belantamab claim; the exclusion is applied once lines exist |
| N1 received 2L/3L | LOT output | `LOT_NUM`, `LOT_START_DT` | a LOT 2 / LOT 3 row exists |
| N2 CE before 2L/3L | `member_enrollment` | as I4 | same span test against the 2L/3L index |

## 9. Variable → source, analysis variables

Grouped as `VARIABLES.md` groups them.

| variable | table.column | notes |
|---|---|---|
| Age (continuous, and 18-44/45-64/65-74/≥75) | `member_enrollment.YRDOB` | index calendar year − YRDOB; YRDOB capped at 89 |
| Sex (M/F/Unknown) | `member_enrollment.GDR_CD` | `M`/`F`/`U` |
| Region (Midwest/South/West/Northeast/Unknown) | `member_enrollment.REGION` **if present**, else `member_enrollment.STATE` + a census crosswalk | see §4 |
| Race (Asian/Black/White/Unknown) | `member_enrollment.RACE` | African American→Black, Caucasian→White |
| Ethnicity (Hispanic/Not Hispanic/Unknown) | `member_enrollment.ETHNICITY` | value list not published — profile it |
| Insurance type (Medicare / Commercial) | `member_enrollment.BUS` | `MCR` / `COM` |
| Charlson Comorbidity Index (Quan 2011), MM-adjusted | `diagnosis.DIAG`, `.ICD_FLAG`, `.FST_DT` over the 12-month baseline | needs a Quan-2011 ICD-9+ICD-10 code list and weights; MM's own weight zeroed |
| Kim Frailty Index (CFI ≥ 0.25 = frail) | `diagnosis`, `procedure`, `medical.PROC_CD`, `rx.NDC` over the baseline | Kim 2018 claims-based index; the protocol marks it *"only included pending review of data and mapping"* — Annex 7 |
| Year of MM diagnosis | derived from `MM_DX_DT` | "first medical claim for MM within the baseline period on or prior to 1L" |
| Follow-up time from diagnosis / from index | `MM_DX_DT`, index, `member_enrollment` spans, `dod.YMDOD`, study end | months, both endpoints inclusive |
| Year of 1L / 2L / 3L initiation | LOT output | 2019 → latest data availability |
| Types of 1L/2L/3L SOCs or classes by line | LOT output + `cl_mma_rollup.csv` | quadruplet / triplet / doublet / anti-CD38 backbone / class — Annex 2 |
| Key safety events (Table 3, 22 conditions) | `diagnosis.DIAG` (+ `confinement`, `medical` for the hospitalisation-based ones) | ICD-10-CM lists — **Annex 3**, not available |
| All-cause inpatient hospitalisation | `confinement` | `ADMIT_DATE`, `DISCH_DATE`, `LOS`, `CONF_ID` |
| MM-related hospitalisation | `confinement.DIAG1`/`DIAG2`, or `diagnosis` with `DIAG_POSITION IN (1,2)` | |
| Emergency visits | `medical.RVNU_CD` / `.POS` / `.PROC_CD` | see §6 — construction not yet agreed |
| Secondary malignancy (type + category) | `diagnosis.DIAG`, `.FST_DT` | "at least 2 diagnosis codes occurring on separate dates. The date of the first ICD code will be used" |
| Thrombocytopenia, anaemia | `diagnosis`, and optionally `lab` (`LOINC_CD`, `TST_DESC`, `RSLT_NBR`) | protocol marks both *"dependent on data availability"* |
| TTNT / TTD / OS / attrition | LOT output + `dod.YMDOD` + study end | see `VARIABLES.md` §5 |
| SCT and CAR-T | `procedure.PROC`, `medical.PROC_CD`, `medical.BILL_PROC_CD` | `cl_sct_codelist.csv` carries `SCT_TYPE` |
| Death | `dod.YMDOD` | month+year only |

## 10. Caveats that change a number

1. **Death is month-precision.** Every OS, TTD and follow-up figure inherits ±15 days.
   The construction rules — 15th of the month, 15 July for a year-only record, bumped to
   the period end where that would precede the diagnosis — are `Jul 28/ndmm/DECISIONS.md`
   §8 and are **still open, pending study-team sign-off** (`OPEN_QUESTIONS.md` Q22). That
   mattered less when OS was not reported; it is a primary outcome now.
2. **Enrolment rollup vs protocol gap rule** differ by one day at the boundary (§4).
3. **`YRDOB` is capped at 89** — the ≥ 75 age band is right-censored in a way that
   understates the very old.
4. **Lab coverage is partial** — network-restricted, so lab-defined outcomes are not
   population-representative.
5. **`RACE`/`ETHNICITY` are suppressed for small cells** — "includes patients with
   HIPAA-restricted cell sizes" folded into Other/Unknown.
6. **Inpatient-administered drugs are invisible to RX** and may be bundled into a DRG
   rather than itemised on MEDICAL, so in-hospital MM therapy can be missed.
7. **`NDC` on MEDICAL is frequently `NONE`/`UNK`** — 1.2 bn such rows, per the note in
   `Jul 28/ndmm/R/db_utils.R:65-76`. Never left-pad those into a join key.
8. **ICD-9 → ICD-10 transition** falls inside the study period only if the period is
   read as starting 2016 (Figure 1); on the 2018 reading, everything is ICD-10 and
   the ICD-9 arms of every code list are dead weight. Q1 decides this.
9. **No clinical staging exists.** No ISS/R-ISS, no cytogenetics or FISH, no ECOG, no
   tumour-registry linkage, no treatment intent. Transplant eligibility is why the
   protocol uses age ≥ 75 as its proxy — there is nothing better in the data.
10. **No date shifting is documented.** All claim dates are full-precision calendar
   dates; de-identification is by **encryption of identifiers** (PATID, PAT_PLANID,
   CLMID, CONF_ID, FAMILY_ID and every provider id), not by perturbing dates. The only
   deliberate coarsening is `YRDOB` (year, capped at 89) and `EXTRACT_YM`.
11. **`DOD` is not in the V9.0 dictionary at all.** Vital status is absent from it; the
   only in-dictionary death signal is a `DSTATUS` of "expired" on a confinement, and
   even that lookup's values are not supplied. The `dod` table the build reads is a
   separate mortality file — which is also why its encryption caveat (§3) matters.
12. **The quarterly tables are cumulative** — the suffix is chosen from `STUDY_END`,
   so a rerun against a newer quarter is a different denominator.
