# Optum CDM data mapping - GSK 223926 (Aug 26 2026 protocol)

Where every criterion and every variable comes from in the Optum Clinformatics Data
Mart, at table-and-column level, and the caveats that change what a number means.

---

## 1. Where the data physically is

Production is Databricks:

```
catalog  hive_metastore
schema   clnprw_optum
table    t_<base>_<yyyy>q<n>        # cumulative quarterly tables, suffix from STUDY_END
```

so `member_enrollment` with `STUDY_END = 2026-03-31` resolves to
`hive_metastore.clnprw_optum.t_member_enrollment_2026q1`.

Code lists are **not** in the warehouse. They are CSVs in the directory named by
`CODELIST_DIR` - see `CODELISTS.md`.

## 2. Table inventory

Base names as the build uses them, CDM names as the vendor writes them.

| build name | CDM name | grain | what it carries |
|---|---|---|---|
| `member_enrollment` | MEMBER_ENROLLMENT | one row per member per coverage state | a **new row each time anything about the member changes** (state, product) |
| `member_cont_enrollment` | MEMBER_CONTINUOUS_ENROLLMENT | one row per continuous span | a **rollup** of the above: one span of continuous enrollment, bridging a **break of less than 30 days**, regardless of changes in coverage |
| `medical` | MEDICAL | one row per claim line | professional (CPT/HCPCS) **and** facility claims |
| `diagnosis` **→ `med_diagnosis`** | MED_DIAGNOSIS | one row per claim per diagnosis position | diagnoses split out of the claim to keep it narrow |
| `procedure` | MED_PROCEDURE | one row per claim per procedure position | ICD-9/10 **procedure** codes (CPT/HCPCS live on MEDICAL.PROC_CD) |
| `confinement` | CONFINEMENT | one row per hospitalisation | one unduplicated row per hospitalisation, with the facility detail records bundled into it |
| `rx` | RX | one row per pharmacy fill | outpatient pharmacy only |
| `lab` | LABRESULT | one row per result | only tests performed within certain laboratory networks |
| `dod` | DOD | one row per decedent | **month and year** of death |
| `ses` | SES | one row per member | education, income, home ownership, net worth |
| `provider`, `provider_bridge` | PROVIDER / PROVIDER BRIDGE | one row per provider | credentials, taxonomy, state |
| - | LU_DIAGNOSIS / LU_NDC / LU_PROCEDURE | lookups | code descriptions and groupings |

**The left column is a short name, not the physical table.** The deployed tables are
`t_<physical>_<quarter>`, and for two of them the physical name is not the short one:
**`med_diagnosis`** and **`med_procedure`**. `CDM_TABLE_NAMES` in
`R/db_utils_223926.R` holds the mapping and `tests/run_tests.R` pins it.

## 3. How the tables join

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

`*` **Continuous Enrollment: use PATID. Member Enrollment: use PAT_PLANID.**

The cohort build follows this exactly: diagnosis joins to the claim header on
`PATID, CLMID, FST_DT` with null-safe equality on `PAT_PLANID` and `LOC_CD`.

> **Caveat, unresolved.** The vendor states that DOD and SES are encrypted
> differently from the other tables and so cannot be joined to them, while the join
> diagram draws `PATID` edges from Member Enrollment to both, and the current build
> joins DOD on `PATID`. Confirm before any SES-derived variable is trusted.
> `OPEN_QUESTIONS.md` Q8.

## 4. Columns, verified

### MEMBER_ENROLLMENT - as deployed

`describe table hive_metastore.clnprw_optum.t_member_enrollment_2025q4` returns
**27 columns**, in this order:

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

Observed values in the MM population:

| field | values (n patients) |
|---|---|
| `BUS` | `MCR` 17,874 · `COM` 5,758 |
| `PRODUCT` | `OTH` 16,066 · `HMO` 6,726 · `POS` 3,995 · `PPO` 2,569 · `EPO` 1,054 · `IND` 241 |
| `CDHP` | `U` 16,975 · `3` 7,467 · `2` 1,121 · `1` 551 |

So the protocol's **insurance type (Medicare / Commercial Health Plan)** is
`BUS` - `MCR` / `COM`. `PRODUCT` is the plan form, a different axis.

> **The deployed table is a different CDM vintage from the documented schema.** The
> V9.0 schema gives MEMBER_ENROLLMENT **20** columns: PATID, PAT_PLANID, ASO, BUS,
> CDHP, ELIGEFF, ELIGEND, GDR_CD, GROUP_NBR, HEALTH_EXCH, **LIS_DUAL**, PRODUCT,
> YRDOB, EXTRACT_YM, VERSION, FAMILY_ID, ETHNICITY, RACE, RACE_SOURCE, **REGION**.
> The deployed 2025q4 table has **27**, and the arithmetic is exact:
> `20 − REGION − LIS_DUAL + STATE + 8 date-part columns = 27`. The warehouse is
> serving a **pre-V9.0** extract - it still has `STATE`, which V9.0 removed, and
> lacks `REGION` and `LIS_DUAL`, which V9.0 has - with `ELIGEFF_DAY/_MONTH/_YEAR/
> _SASDT` and `ELIGEND_*` decompositions added on the Databricks side. Read the V9.0
> schema as a **different** version from the one you will query, and `describe table`
> before writing any column into code.

> **The deployed table has `STATE`, not `REGION`.** V9.0 added `REGION` (the US
> Census Region of the member address) and removed `STATE`; the 2025q4 production
> table carries `STATE` and no `REGION`. The protocol asks for Region on the US
> Census Bureau definition (Midwest / South / West / Northeast / Unknown), so either
> `REGION` appears in the 2026q1 vintage or the build derives region from `STATE`
> with a 50-state → 4-region crosswalk. **Run `describe table` before writing that
> code.** `OPEN_QUESTIONS.md` Q9.

`RACE` is `varchar(1)`, reported as African American, Asian, Caucasian and
Other/Unknown (the last includes patients with HIPAA-restricted cell sizes). It moved
from the SES file and was renamed from `D_RACE_CODE` in V9.0. The protocol's
categories are Asian / Black / White / Unknown - a straight relabel, with African
American → Black and Caucasian → White.

`ETHNICITY` is `varchar(1)` with lookup `ETHNICITY`, described only as the member's
ethnicity flag; its code values are not published. The protocol wants Hispanic or
Latino / Not Hispanic or Latino / Unknown. **Profile the column before mapping.**
`OPEN_QUESTIONS.md` Q10.

**Medicare markers the vendor documents but the deployed table does not carry.**
`LIS_DUAL` (Low Income Subsidy or Medicaid/Medicare dual, available on Medicare
members only) would be a direct Medicare marker; it is in V9.0 and absent from the
deployed table. `RX.FORM_TYP` (formulary type, NULL for Medicare) is an indirect one
that *is* available. `ASO` is `Y`/`N` for self-funded commercial. None of these
replaces `BUS`; they are cross-checks for it.

**Lookup value sets are not published.** About 25 code tables are named - `RACE`,
`ETHNICITY`, `REGION`, `BUS_LINE`, `PRODUCT`, `CDHP`, `HEALTH_EXCH`, `LIS_DUAL`,
`POS`, `LOC_CD`, `DRG`, `DISCHSTATUS`, `ADMIT_TYPE`, `ADMIT_CHAN`, `RVNU_CD`,
`BILL_TYPE`, `PROVCAT`, `TOS_CD`, `TOS_EXT`, `PAID_STATUS`, `IPSTATUS`, `DAW`,
`FORM_TYP`, `SPECCLSS`, `AHFSCLSS` and the `D_*` socio-economic codes - without their
values. Every value mapping this study needs for a categorical variable (`RACE` →
Asian/Black/White, `ETHNICITY` → Hispanic/Not Hispanic, `BUS` → Medicare/Commercial)
has to come from the lookup tables in the warehouse or from profiling the column.
`OPEN_QUESTIONS.md` Q10.

**One tie-break is documented.** On MEMBER_CONTINUOUS_ENROLLMENT, where `GDR_CD` has
more than one value, use the latest that is not `U`. Nothing equivalent exists for
`RACE`, `ETHNICITY`, `BUS` or `STATE`. `OPEN_QUESTIONS.md` Q16.

`YRDOB` is year of birth, **capped at 89** (the cap was 90 until April 2025, so it
may differ by extract vintage). There is no date of birth, so age is only ever
`index year − YRDOB`, which is what the protocol asks for ("according to calendar
year"). The age **bands** are unaffected, since the cap sits above the 75 cut-point
Table 4 and §7.8.1 use. A **mean or median** age is not: it is right-censored, and
myeloma has a real tail above 89. Table 4 asks for both.

**No medical-benefit or pharmacy-benefit flag exists on this table.** See §7.

### MEMBER_ENROLLMENT - the attributes are time-varying, not fixed

`MEMBER_ENROLLMENT` carries **one row per member per change of anything**, so `BUS`,
`PRODUCT`, `CDHP`, `STATE` and even `GDR_CD` are **span-level attributes**, not
patient-level ones. The distributions above are `count(DISTINCT PATID)` grouped by
value, and the three totals disagree - `BUS` sums to 23,632, `CDHP` to 26,114,
`PRODUCT` to 30,651. A patient appearing under two values of one field must hold two
enrolment rows with different attributes.

So "is this patient Medicare or Commercial?" has no single answer. Every Table 4
demographic timed "at index" has to be read off **the enrolment row covering the
index date**, with a documented tie-break when more than one row covers it. The
vendor documents no such tie-break. `OPEN_QUESTIONS.md` Q16.

The cohort build already faces this for sex and birth year and resolves it by ranking
rows: a usable birth year first, then a known sex, then the most recent `ELIGEND`,
then the values themselves for determinism. That rule is **not** "the row covering
the index date", so it will need revisiting for the new demographics.

### MEMBER_CONTINUOUS_ENROLLMENT

`PATID`, `ELIGEFF`, `ELIGEND`, `GDR_CD`, `YRDOB`, `RACE`, `ETHNICITY`,
`RACE_SOURCE`, `EXTRACT_YM`, `VERSION`. One row per continuous span, bridging breaks
of **less than 30 days**.

> This rollup is **not** what the protocol asks for. The protocol allows gaps of
> **≤ 30 days**; the rollup bridges **< 30 days**. A 30-day gap is continuous to the
> protocol and a break to the rollup. The cohort build therefore builds its own spans
> from `MEMBER_ENROLLMENT`. Keep doing that.

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
| `PROC_CD`, `BILL_PROC_CD`, `PROCMOD`..`PROCMOD4` | CPT / HCPCS Level II - this is where **J-codes for administered MM agents** live |
| `RVNU_CD` | revenue code - needed for the pregnancy exclusion and for ED identification |
| `NDC`, `NDC_QTY`, `NDC_UOM` | NDC on a medical claim; Optum writes `NONE`/`UNK` where there is none |
| `UNITS`, `ALT_UNITS` | units administered |
| `DRG`, `DSTATUS`, `ADMIT_TYPE`, `ADMIT_CHAN`, `BILL_TYPE` | facility detail |
| `ICD_FLAG` | `'9'` or `'10'` |
| `PROV`, `BILL_PROV`, `REFER_PROV`, `SERVICE_PROV`, `PROVCAT`, `PROV_PAR` | provider links |
| `CHARGE`, `COPAY`, `COINS`, `DEDUCT`, `COB`, `STD_COST`, `STD_COST_YR` | cost |
| `OP_VISIT_ID`, `ENCTR`, `HCCC`, `PAID_DT`, `PAID_STATUS` | admin |

### MED_DIAGNOSIS

`PATID`, `PAT_PLANID`, `CLMID`, `DIAG`, `DIAG_POSITION`, `ICD_FLAG`, `LOC_CD`,
`POA`, `FST_DT`, `EXTRACT_YM`, `VERSION`.

- `DIAG` is the ICD-9/ICD-10-CM code **without a decimal point** - so `C90.00`
  is stored `C9000` and `203.00` is stored `20300`. The build normalises both sides
  with `upper(regexp_replace(x,'[^A-Za-z0-9]',''))`.
- `DIAG_POSITION` runs **1 to 25**, and position 1 is the primary diagnosis. The
  protocol's MM criterion is "in any position", so no filter. The MM-related
  hospitalisation variable is "first or second position" - that is `DIAG_POSITION IN
  (1,2)` on MED_DIAGNOSIS, or `DIAG1`/`DIAG2` on CONFINEMENT.
- `ICD_FLAG` is `'9'` for ICD-9 and `'10'` for ICD-10.
- `POA` is present-on-admission.

### MED_PROCEDURE

`PATID`, `PAT_PLANID`, `CLMID`, `PROC`, `PROC_POSITION`, `ICD_FLAG`, `LOC_CD`,
`FST_DT`, `EXTRACT_YM`, `VERSION`.
`PROC` is the **ICD-9/10 procedure** code. CPT and HCPCS are on `MEDICAL.PROC_CD`.
Both matter for SCT and CAR-T identification.

This is measured, not assumed: over the study period `PROC` is **43,137,224 of ~43.2M
rows at `ICD_FLAG='10'` and seven characters** - ICD-10-PCS. The five-character tail,
the only shape a HCPCS or CPT code could occupy, is about **15,000 rows, 0.035%**.
The build still reads `PROC` as a fifth medication source because the failure is
asymmetric: a therapy that goes unseen lets a patient pass the no-prior-therapy
criterion on missing data.

### CONFINEMENT

`PATID`, `PAT_PLANID`, `CONF_ID`, `ADMIT_DATE`, `DISCH_DATE`, `LOS`,
`DIAG1`..`DIAG5`, `PROC1`..`PROC5`, `DRG`, `DSTATUS`, `ICD_FLAG`, `IPSTATUS`,
`POS`, `TOS_CD`, `PROV`, `CHARGE`, `COINS`, `COPAY`, `DEDUCT`, `STD_COST`,
`STD_COST_YR`, `ICU_IND`, `ICU_SURG_IND`, `MAJ_SURG_IND`, `MATERNITY_IND`,
`NEWBORN_IND`, `TOS_EXT`, `EXTRACT_YM`, `VERSION`.

This is the table for all-cause and MM-related hospitalisation: `LOS` is carried
directly, `DIAG1`/`DIAG2` give the MM-related test, `DSTATUS` gives discharge
disposition, and `ADMIT_DATE`/`DISCH_DATE` bound the stay.

### RX

`PATID`, `PAT_PLANID`, `CLMID`, `NDC`, `FILL_DT`, `DAYS_SUP`, `QUANTITY`,
`STRENGTH`, `BRND_NM`, `GNRC_NM`, `GNRC_IND`, `DAW`, `DEA`, `NPI`, `PHARM`,
`PRESCRIBER_PROV`, `PRESCRIPT_ID`, `RFL_NBR`, `FST_FILL`, `AHFSCLSS`, `SPECCLSS`,
`SPCLT_IND`, `MAIL_IND`, `FORM_IND`, `FORM_TYP`, `PRC_TYP`, `AVGWHLSL`, `CHARGE`,
`COPAY`, `DEDUCT`, `DISPFEE`, `STD_COST`, `STD_COST_YR`, `CHK_DT`, `EXTRACT_YM`,
`VERSION`.

The day-supply column is **`DAYS_SUP`**, not `DAY_SUPPLY`. Oral MM agents
(lenalidomide, pomalidomide, ixazomib, thalidomide, cyclophosphamide, melphalan,
panobinostat, selinexor, dexamethasone) come through here; infusions do not.

### LABRESULT

`LOINC_CD`, `TST_DESC`, `RSLT_TXT`, `RSLT_NBR`, `HI_NRML`, `LOW_NRML`, `FST_DT`.
Use `LOINC_CD` where present and `TST_DESC` where not. Coverage is partial - only
tests performed within certain laboratory networks - which is why the protocol marks
thrombocytopenia and anaemia *"dependent on data availability"*.

### DOD

`PATID`, `YMDOD`. **Month and year only.** `YMDOD` is a `CCYYMM` string. The cohort
build coarsens it to the 15th of the month, or the month end where the 15th would
fall before the diagnosis. Every day-level survival number inherits that ±15-day
uncertainty. This is a separate mortality file, not part of the CDM V9.0 schema.

### SES

`PATID`, `D_EDUCATION_LEVEL_CODE`, `D_HOME_OWNERSHIP_CODE`,
`D_HOUSEHOLD_INCOME_RANGE_CODE`, `D_NETWORTH_RANGE_CODE`, `EXTRACT_YM`, `VERSION`.
Nothing the protocol asks for is here - race moved off this file in V9.0.

---

### What the vendor rules do not cover

Each of these is a decision the build has to make without documentation:

| topic | status |
|---|---|
| **Valid claims / exclusions** | No definition of a valid claim, and no rule for reversals, denials, duplicates, capitated encounters or adjustments. No claim-status or payment-status filter is named anywhere |
| **Member-months / person-time** | No denominator convention at all. In particular it is **never stated whether the days inside a bridged sub-30-day gap count as covered person-time** - which directly changes every person-year denominator the protocol asks for (`OPEN_QUESTIONS.md` Q19) |
| **Overlapping spans** | Never addressed. Sequential non-overlapping rows are implied within a `PAT_PLANID`; overlap across `PAT_PLANID`s for one `PATID` (dual coverage, mid-month switch) is neither asserted nor excluded |
| **Gap-rule precision** | "less than 30 day break in coverage" is the whole specification. Whether the boundary is `< 30` or `<= 30`, and how the break is computed, are not written |
| **ICD-9 → ICD-10 transition** | Only `ICD_FLAG` is given. No cut-over date, no crosswalk guidance, no instruction to specify a condition in both vocabularies |
| **Code formatting** | Decimal points, padding and justification are absent from the rules; the convention (ICD as entered on the claim, **without decimal point**) is on the MED_DIAGNOSIS schema instead |
| **Date shifting** | None documented. The only truncation is death (`YMDOD`, month + year), with no day-imputation convention |
| **Inpatient-administered drugs** | The gap is implied by RX being prescriptions filled on an **outpatient** basis and never stated outright |
| **Medicare Advantage vs Commercial** | No caveat of any kind. Nothing on Part D vs commercial drug capture, MA encounter-data completeness, or how to assign a segment to a member whose `BUS` changes across spans |
| **Completeness by year** | No claims run-out or lag convention, and no incomplete-recent-quarter warning |

Two further points worth carrying into any implementation:

- **The vendor rules contradict themselves on procedure codes.** One rule assigns
  `PROC_CD` / `T_MEDICAL` to ICD-9/ICD-10 and `PROC` / `T_MED_PROCEDURE` to
  HCPCS/CPT - the exact inverse of the rest of the rule set and of the MEDICAL table
  description. The majority reading is what the current build follows, and the
  profiling of 43.2M `PROC` rows above confirms it. `OPEN_QUESTIONS.md` Q17.
- **Vintage.** The rules date from August 2022 and are being applied to a
  2025Q4/2026Q1 extract against a V9.0 schema released September 2023. No
  revalidation is recorded. `OPEN_QUESTIONS.md` Q18.

## 4b. What the deployed schema settles

The 27-column list in §4 answers what the V9.0 field list left open about
MEMBER_ENROLLMENT: which of V9.0's additions actually landed, and what the
extract kept that V9.0 removed.

**`ETHNICITY` and `RACE_SOURCE` do exist** - appended at 26 and 27, after `VERSION`,
which is where a later addition lands. The ordering is source order with Databricks
date-parts interleaved, not alphabetical, so their absence could not have been
inferred from position.

**`REGION` and `LIS_DUAL` do not.** V9.0 annotates four MEMBER_ENROLLMENT additions -
`ETHNICITY`, `RACE` (moved from the SES file and renamed from `D_RACE_CODE`),
`RACE_SOURCE` and `REGION`. Three landed; `REGION` did not, and `STATE`, which V9.0
removed, is still there. The extract is a hybrid rather than simply a version behind,
and `REGION` is the one column the region variable would need.
`REGION_SOURCE=region_column` is refused in `R/config_223926.R` for that reason.

The V9 move is visible from the other side too: **SES** now carries only `PATID`,
`D_EDUCATION_LEVEL_CODE`, `D_HOME_OWNERSHIP_CODE`, `D_HOUSEHOLD_INCOME_RANGE_CODE`,
`D_NETWORTH_RANGE_CODE`, `EXTRACT_YM`, `VERSION` - **no race**. The 2022 rules still
describe SES as seven consumer characteristics **including race**, so they are
demonstrably out of date on a point we can check. `OPEN_QUESTIONS.md` Q18.

Only MEMBER_ENROLLMENT has been described column by column. The deployed shape of
MEDICAL, MED_DIAGNOSIS, CONFINEMENT, RX and DOD is inferred from the V9.0 schema plus
that one example and the profiling in §4c. `describe table` on the other five would
settle the date types and whether `BILL_PROC_CD` (a V9 addition) is populated, which
is still unknown.

### Columns the study does not use and probably should consider

| column | table | what it is | why it matters |
|---|---|---|---|
| `PAID_STATUS` | MEDICAL | PAID if the sum of paid amounts is >= $0, DENIED if < $0 | a denied claim is not evidence a service happened; nothing here or in the cohort build filters on it. `CLAIM_STATUS` setting, `OPEN_QUESTIONS.md` Q25 |
| `POA` | MED_DIAGNOSIS | Present on Admission; conditions developing during an outpatient encounter, ED or observation count as POA | separates a condition present at admission from one acquired in hospital; bears directly on "severe infection **resulting in** hospitalization" |
| `CLMSEQ` | MEDICAL | distinguishes the detail records of a claim, used with `CLMID` | the documented MED_DIAGNOSIS↔MEDICAL join is `PATID + CLMID + FST_DT + LOC_CD` and omits it, so that join can fan out across a claim's detail lines |
| `RACE_SOURCE` | MEMBER_ENROLLMENT | which source the member's race was matched from | Optum imputes race for some members; a race table that does not report the source composition is incomplete |
| `LST_DT` | MEDICAL | the service **end** date (`FST_DT` is the beginning) | multi-day services have a span this package reads as a point |
| `ENCTR` | MEDICAL | fee-for-service vs capitated | encounters under capitation can be under-reported |
| `OP_VISIT_ID` | MEDICAL | an outpatient visit grouper | would be the vendor's own visit grain for ED, but it is regenerated by the Standard Cost Algorithm on each run and so is not stable across refreshes. This package groups ED claims to one per patient per day instead |

### Points the schema settles

- **`CONFINEMENT.ICD_FLAG` exists** and distinguishes ICD-9 from ICD-10 codes. It is
  read directly, with the admission date kept only as a fallback.
- **`ICD_FLAG` values are `'9'` and `'10'`.**
- **`DIAG_POSITION` runs 1 to 25**, position 1 being the primary diagnosis.
- **`DIAG` is stored without a decimal point.**
- **`MEDICAL.PROC_CD` is CPT/HCPCS**; `MED_PROCEDURE.PROC` is ICD-9/ICD-10 with
  `ICD_FLAG`. `OPEN_QUESTIONS.md` Q17.
- **`RVNU_CD` is facility claims only.** So the revenue-code arm of the ED
  construction can only ever match facility claims, while the CPT arm matches
  professional ones - the three constructions do not merely disagree in number, they
  select different claim types. One ED visit generating both a facility and a
  professional claim is collapsed by this package's one-per-patient-per-day grain.
- **`CLMID`**: a provider can bill multiple revenue codes on one claim and each
  generates a claim line; providers typically submit a separate claim per visit.
- **`CONFINEMENT.LOS`** is length of stay from the start of the first confinement
  record to the last - a span over bundled records, not discharge − admit. The
  protocol wants admit (included) → discharge (excluded), which is what this package
  computes; it does not read `LOS`.
- **`ADMIT_DATE` / `DISCH_DATE` are documented `YYYYMMDD`**, not `DATE`. The deployed
  enrolment table shows Databricks converting Optum's `YYYYMMDD` to a real `date`
  plus `_DAY`/`_MONTH`/`_YEAR`/`_SASDT` parts, so CONFINEMENT is probably converted
  too - but that is an inference from one table.
- **Continuous enrolment**: the rollup bridges a break of *less than* 30 days, while
  §7.2.1.1 allows 30 **or fewer**. The vendor rules also say that from
  MEMBER_ENROLLMENT the user must **stitch** the data to find continuous-enrollment
  start and end dates, which is what `build_enroll_spans()` does.
- **Inpatient identification** has two documented approaches: `POS IN (21, 51, 61)`
  or `TOS_CD IN ('FAC.IP.ACUTE', 'FAC.IP.REHSNF', 'PROF.INPVIS', 'FAC.IP.SNF')`; or
  `CONF_ID IS NOT NULL`, with all records lacking a `CONF_ID` considered
  non-inpatient. This package uses CONFINEMENT directly, which is the second.
- **The CDM has no ED flag, and the vendor says so**: non-inpatient records are to be
  classified **as per the study requirements**. Q11 is a study decision, not a lookup.

## 4c. Value domains, measured 07 Sep 2026

Every value here is measured, not read off a schema, and three of them contradict the
documented one.

| column | values found | consequence |
|---|---|---|
| `MEMBER_ENROLLMENT.GDR_CD` | `F` 108,308,094 · `M` 102,595,572 · `U` 88,388 | `U` is 0.04%. The build maps M/F and sends the rest to Unknown, which is right |
| `MEMBER_ENROLLMENT.STATE` | **53 distinct values** - the 51 the crosswalk carries, plus `NULL` (3,829,750 rows / **2,570,332 members**) and `PR` (14,151 / 11,795) | Region Unknown is overwhelmingly **missing state**, not territories: 2.4% of all members. Puerto Rico is a real gap in the crosswalk but a small one. Both belong in the Table 4 footnote |
| `MED_DIAGNOSIS.DIAG_POSITION` | **zero-padded strings** `01` to `25`, plus `NULL` (1,576,237 rows) - 26 distinct, nothing non-numeric | A string comparison against `'1'` matches nothing; anything reading this must cast, and `try_cast(... as int)` is safe. The test fixture is zero-padded so that it looks like the warehouse rather than like clean synthetic data |
| `MED_DIAGNOSIS.ICD_FLAG` | `10` and `9` | as documented |
| `CONFINEMENT.ICD_FLAG` | **present** - `10` 23,453,669 · `9` 15,054,996 · null 1,666 | the column exists. The admit-date fallback still earns its place for the 1,666 nulls |
| `MEDICAL.PAID_STATUS` | **`P` and `D`** - 2 values, no nulls table-wide since 2024 | **The V9.0 schema spells these `PAID` and `DENIED`. The warehouse does not.** Any filter written from the schema is inert. Among myeloma patients specifically the split is P 78.69% / D 17.42% / null 3.89% |
| `RX.FILL_DT`, `NDC`, `DAYS_SUP` | present, **zero nulls** - 22,107,537 lines, 99,155 members, 2000-05-01 to 2026-03-31 | `build_fu_claims()` reads `FILL_DT`; confirmed safe |
| `STD_COST` (both tables) | **does not encode paid/denied.** 14,891,418 denied medical lines carry a positive `STD_COST`, and 1,034,482 paid lines a negative one; on RX there are no negative rows at all | It is a *standardised* price, not an amount paid, so the "sum of all paid amounts" rule never applied to it. **Denied pharmacy claims cannot be identified by any column in this extract** |
| `RX.PAID_STATUS` | **does not exist** | The deployed pharmacy table has no paid status. Its columns include `STD_COST`, `AHFSCLSS`, `CHK_DT`, `DAW`, `DAYS_SUP` - and `STD_COST` and `CHK_DT` are absent from the V9.0 field list in `optum_cdm_fields.csv`, so that list is **incomplete for RX**, as it was for `DOD.MBR_MATCH_TYPE`. A denied pharmacy claim cannot be excluded by `CLAIM_STATUS` on any reading |
| `MEDICAL.CONF_ID` | null or populated only - no `0`, no blank | The inpatient test is `CONF_ID IS NULL` and nothing else. 186,547,530 lines across 2,805,263 members carry one; 182,711,199 lines across 21,932,322 members do not |
| `DOD.MBR_MATCH_TYPE` | `2` 58.93% · `1` 41.07% | Two values, no nulls: a binary flag, not a graded score. Which value means what is undocumented |

### `CONFINEMENT` shape

Across 241,362 stays belonging to myeloma patients since 2018:

* **No stay is missing a discharge date.** Zero. The protocol's provision for
  excluding such stays from LOS summaries never fires, and `N_LOS_EXCLUDED`
  will be 0 on every table this study produces.
* `LOS` equals `datediff(DISCH_DATE, ADMIT_DATE)` on 235,733 stays and differs
  on 5,629 (2.3%). Means 8.87 against 8.84. The build computes its own, which is
  consistent with `LOS` spanning bundled records.

### What `CLAIM_STATUS=paid_only` actually filters

Narrower than the name. `claim_status_sql()` has **one call site** - the ED arm of
`07_hcru.R`. It does not reach `build_fu_claims()` (the I5 follow-up claim test), the
MM-hospitalisation subquery under `MM_HOSP_POSITION=claim_positions`, anything
reading `CONFINEMENT` (no paid status there), or `RX` (no paid status at all). So the
setting governs emergency visits and nothing else, while recording itself on every
run as though it governed claims generally.

Whether to widen it is a decision, not a config change: a claim the payer refused is
weak evidence that an ED visit happened, and a perfectly ordinary way to observe that
a patient was still in follow-up. `OPEN_QUESTIONS.md` Q25 carries it.

## 5. Identifying inpatient vs outpatient

The protocol leans on this twice (MM diagnosis, other-cancer exclusion). Two
approaches are documented, and the current build applies **both, OR'd**.

**Approach 1 - service codes**
```
inpatient  ⇔  POS IN ('21','51','61')
              OR TOS_CD IN ('FAC_IP.ACUTE','FAC_IP.REHSNF','PROF.INPVIS','FAC_IP.SNF')
outpatient ⇔  none of the above
```

**Approach 2 - confinement**
Inpatient records are those with a non-null `CONF_ID` in CONFINEMENT carrying
admission and discharge dates; everything without a `CONF_ID` is non-inpatient.

The cohort build flags a claim inpatient if **either** holds, and flags it at the
claim-line level before `max(POS)` can hide an inpatient code. Keep that: it is the
conservative reading.

## 6. Identifying emergency department visits

The protocol needs ED visits (Primary Objective 1 and 2, healthcare utilisation).
The CDM has **no ED flag**. The usual claims constructions are:

- `MEDICAL.RVNU_CD` in the 045x range (0450, 0451, 0452, 0456, 0459) and 0981;
- `MEDICAL.POS = '23'` (emergency room - hospital);
- `MEDICAL.PROC_CD` in 99281-99285.

`MEDICAL.TOS_EXT` (the most specific level of the derived type-of-service
classification) plausibly carries an ED category, but its lookup values are not
published, so it cannot be confirmed. `MEDICAL.OP_VISIT_ID` can group claim lines
into a single outpatient visit, which is what stops one ED encounter being counted as
several events.

None of these is in a code list today. `CODELISTS.md` §3 lists it as outstanding, and
`OPEN_QUESTIONS.md` Q11 asks the study team which construction they want, since the
three disagree materially.

## 7. Medical **and** pharmacy benefits

Inclusion criterion I4 requires 12 months of CE "with medical and pharmacy
benefits". The evidence:

- `MEMBER_ENROLLMENT` as deployed has no benefit-type flag (27 columns, §4 above).
  `ASO`, `CDHP`, `HEALTH_EXCH`, `PRODUCT`, `BUS` are funding/plan attributes, not
  benefit indicators.
- The CDM V9.0 schema likewise shows no medical/Rx benefit column on either member
  table.
- The protocol's own §7.5 says: *"All patients in this database have both medical
  and pharmacy coverage, allowing analysis of overall healthcare utilization."*

The cohort build reaches the same conclusion from the same schema: the benefits are
satisfied by construction, a span carries both, so `ELIGEFF`/`ELIGEND` already
express the requirement and a predicate would filter on nothing. Do not re-derive
this from claims - enrolled patients with no pharmacy fill look like a coverage
signal and are not, since that count is dominated by short spans and by patients
whose only MM code is a rule-out. `OPEN_QUESTIONS.md` Q4.

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
| Ethnicity (Hispanic/Not Hispanic/Unknown) | `member_enrollment.ETHNICITY` | value list not published - profile it |
| Insurance type (Medicare / Commercial) | `member_enrollment.BUS` | `MCR` / `COM` |
| Charlson Comorbidity Index (Quan 2011), MM-adjusted | `diagnosis.DIAG`, `.ICD_FLAG`, `.FST_DT` over the 12-month baseline | needs a Quan-2011 ICD-9+ICD-10 code list and weights; MM's own weight zeroed |
| Kim Frailty Index (CFI ≥ 0.25 = frail) | `diagnosis`, `procedure`, `medical.PROC_CD`, `rx.NDC` over the baseline | Kim 2018 claims-based index; the protocol marks it provisional, pending data and mapping - Annex 7 |
| Year of MM diagnosis | derived from `MM_DX_DT` | "first medical claim for MM within the baseline period on or prior to 1L" |
| Follow-up time from diagnosis / from index | `MM_DX_DT`, index, `member_enrollment` spans, `dod.YMDOD`, study end | months, both endpoints inclusive |
| Year of 1L / 2L / 3L initiation | LOT output | 2019 → latest data availability |
| Types of 1L/2L/3L SOCs or classes by line | LOT output + `cl_mma_rollup.csv` | quadruplet / triplet / doublet / anti-CD38 backbone / class - Annex 2 |
| Key safety events (Table 3, 22 conditions) | `diagnosis.DIAG` (+ `confinement`, `medical` for the hospitalisation-based ones) | ICD-10-CM lists - **Annex 3**, still outstanding |
| All-cause inpatient hospitalisation | `confinement` | `ADMIT_DATE`, `DISCH_DATE`, `LOS`, `CONF_ID` |
| MM-related hospitalisation | `confinement.DIAG1`/`DIAG2`, or `diagnosis` with `DIAG_POSITION IN (1,2)` | |
| Emergency visits | `medical.RVNU_CD` / `.POS` / `.PROC_CD` | see §6 - construction not yet agreed |
| Secondary malignancy (type + category) | `diagnosis.DIAG`, `.FST_DT` | "at least 2 diagnosis codes occurring on separate dates. The date of the first ICD code will be used" |
| Thrombocytopenia, anaemia | `diagnosis`, and optionally `lab` (`LOINC_CD`, `TST_DESC`, `RSLT_NBR`) | protocol marks both *"dependent on data availability"* |
| TTNT / TTD / OS / attrition | LOT output + `dod.YMDOD` + study end | see `VARIABLES.md` §5 |
| SCT and CAR-T | `procedure.PROC`, `medical.PROC_CD`, `medical.BILL_PROC_CD` | `cl_sct_codelist.csv` carries `SCT_TYPE` |
| Death | `dod.YMDOD` | month+year only |

## 10. Caveats that change a number

1. **Death is month-precision.** Every OS, TTD and follow-up figure inherits ±15 days.
   The construction rules - 15th of the month, 15 July for a year-only record, bumped
   to the period end where that would precede the diagnosis - are still open
   (`OPEN_QUESTIONS.md` Q22). That mattered less when OS was not reported; it is a
   primary outcome now.
2. **Enrolment rollup vs protocol gap rule** differ by one day at the boundary (§4).
3. **`YRDOB` is capped at 89** - the ≥ 75 age band is right-censored in a way that
   understates the very old.
4. **Lab coverage is partial** - network-restricted, so lab-defined outcomes are not
   population-representative.
5. **`RACE`/`ETHNICITY` are suppressed for small cells** - patients with
   HIPAA-restricted cell sizes are folded into Other/Unknown.
6. **Inpatient-administered drugs are invisible to RX** and may be bundled into a DRG
   rather than itemised on MEDICAL, so in-hospital MM therapy can be missed.
7. **`NDC` on MEDICAL is frequently `NONE`/`UNK`** - 1.2 bn such rows. Never left-pad
   those into a join key.
8. **ICD-9 → ICD-10 transition** falls inside the study period only if the period is
   read as starting 2016 (Figure 1); on the 2018 reading, everything is ICD-10 and
   the ICD-9 arms of every code list are dead weight. Q1 decides this.
9. **No clinical staging exists.** No ISS/R-ISS, no cytogenetics or FISH, no ECOG, no
   tumour-registry linkage, no treatment intent. Transplant eligibility is why the
   protocol uses age ≥ 75 as its proxy - there is nothing better in the data.
10. **No date shifting is documented.** All claim dates are full-precision calendar
   dates; de-identification is by **encryption of identifiers** (PATID, PAT_PLANID,
   CLMID, CONF_ID, FAMILY_ID and every provider id), not by perturbing dates. The only
   deliberate coarsening is `YRDOB` (year, capped at 89) and `EXTRACT_YM`.
11. **`DOD` is not part of the V9.0 schema.** Vital status is absent from it; the only
   in-schema death signal is a `DSTATUS` of "expired" on a confinement, and even that
   lookup's values are not published. The `dod` table the build reads is a separate
   mortality file - which is also why its encryption caveat (§3) matters.
12. **The quarterly tables are cumulative** - the suffix is chosen from `STUDY_END`,
   so a rerun against a newer quarter is a different denominator.
