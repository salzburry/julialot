# Optum CDM data mapping - GSK 223926

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
`hive_metastore.clnprw_optum.t_member_enrollment_2026q1`. The schema holds one
table per quarter back to `2016q4`; the `2026q1` vintage has the same tables
and column names as earlier ones, with data through 2026-03-31.

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
| `procedure` **→ `med_procedure`** | MED_PROCEDURE | one row per claim per procedure position | ICD-9/10 **procedure** codes (CPT/HCPCS live on MEDICAL.PROC_CD) |
| `confinement` | CONFINEMENT | one row per hospitalisation | one unduplicated row per hospitalisation, with the facility detail records bundled into it |
| `rx` | RX | one row per pharmacy fill | outpatient pharmacy only |
| `lab` | LABRESULT | one row per result | only tests performed within certain laboratory networks |
| `dod` | DOD | one row per decedent | **month and year** of death |
| `ses` | SES | one row per member | education, income, home ownership, net worth |
| `provider`, `provider_bridge` | PROVIDER / PROVIDER BRIDGE | one row per provider | credentials, taxonomy, state |
| - | LU_DIAGNOSIS / LU_NDC / LU_PROCEDURE | lookups | code descriptions and groupings |

**The left column is a short name, not the physical table.** For two of them the
physical name differs: **`med_diagnosis`** and **`med_procedure`**.
`CDM_TABLE_NAMES` in `R/db_utils_223926.R` holds the mapping, `tests/run_tests.R`
pins it, and the `TBL_*` settings override a base name.

**What reads what.** This package reads `medical`, `med_diagnosis`,
`confinement`, `member_enrollment` and `rx`. Death, birth year and the
qualifying MM diagnosis date come from the cohort table (`DEATH_DT`, `YRDOB`,
`MM_DX_DT`), which the cohort build derives from `dod`,
`member_cont_enrollment` and `med_diagnosis`; transplant and CAR-T come from
the LOT engine's lines. Nothing reads `lab`, `ses` or the provider tables.

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

The builds follow this: diagnosis joins to the claim on `PATID, CLMID, FST_DT`
with null-safe equality on `PAT_PLANID` and `LOC_CD`.

The business rules say DOD and SES are encrypted differently from the other
tables and cannot be joined to them. For DOD that does not hold in this
deployment: every one of its 11,509,828 patients matches the enrolment table on
`PATID` (`OPEN_QUESTIONS.md` Q8/Q26). The SES join has not been tested, and
nothing the study uses is on SES.

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

**The deployed table is a different CDM vintage from the documented schema.** The
V9.0 schema gives MEMBER_ENROLLMENT 20 columns: PATID, PAT_PLANID, ASO, BUS,
CDHP, ELIGEFF, ELIGEND, GDR_CD, GROUP_NBR, HEALTH_EXCH, **LIS_DUAL**, PRODUCT,
YRDOB, EXTRACT_YM, VERSION, FAMILY_ID, ETHNICITY, RACE, RACE_SOURCE, **REGION**.
The deployed table is `20 − REGION − LIS_DUAL + STATE + 8 date-part columns = 27`:
of V9.0's four MEMBER_ENROLLMENT additions, three landed (`ETHNICITY`, `RACE`
moved off the SES file, `RACE_SOURCE`, appended at 26 and 27) and **`REGION` did
not**, while `STATE`, which V9.0 removed, is still there. `describe table` before
writing any column into code.

**Region** is therefore derived from `STATE` with a 50-state + DC → US Census
region crosswalk (`REGION_SOURCE=state_crosswalk`); `REGION_SOURCE=region_column`
is refused at preflight (`OPEN_QUESTIONS.md` Q9).

Observed values in the MM population:

| field | values (n patients) |
|---|---|
| `BUS` | `MCR` 17,874 · `COM` 5,758 |
| `PRODUCT` | `OTH` 16,066 · `HMO` 6,726 · `POS` 3,995 · `PPO` 2,569 · `EPO` 1,054 · `IND` 241 |
| `CDHP` | `U` 16,975 · `3` 7,467 · `2` 1,121 · `1` 551 |

So the protocol's **insurance type (Medicare / Commercial Health Plan)** is
`BUS` - `MCR` / `COM`. `PRODUCT` is the plan form, a different axis.

**`RACE` and `ETHNICITY`.** The dictionary reports race as African American,
Asian, Caucasian and Other/Unknown (the last includes HIPAA-restricted cell
sizes) and publishes no ethnicity values. Measured, `RACE` is `W`, `B`, `A`, `U`
or null and `ETHNICITY` is `N`, `H`, `U` or null; `RACE_SOURCE` is always
`Self-Reported` (`OPEN_QUESTIONS.md` Q10). Race is null or `U` on about 42% of
enrolment rows and ethnicity on about 36%.

**Medicare markers the vendor documents but the deployed table does not carry.**
`LIS_DUAL` (Low Income Subsidy or Medicaid/Medicare dual) is in V9.0 and absent
here. `RX.FORM_TYP` (formulary type, NULL for Medicare) is an indirect marker
that is available, and `ASO` is `Y`/`N` for self-funded commercial. None of these
replaces `BUS`; they are cross-checks for it.

**Lookup value sets are not published.** About 25 code tables are named - `RACE`,
`ETHNICITY`, `REGION`, `BUS_LINE`, `PRODUCT`, `CDHP`, `HEALTH_EXCH`, `LIS_DUAL`,
`POS`, `LOC_CD`, `DRG`, `DISCHSTATUS`, `ADMIT_TYPE`, `ADMIT_CHAN`, `RVNU_CD`,
`BILL_TYPE`, `PROVCAT`, `TOS_CD`, `TOS_EXT`, `PAID_STATUS`, `IPSTATUS`, `DAW`,
`FORM_TYP`, `SPECCLSS`, `AHFSCLSS` and the `D_*` socio-economic codes - without
their values, so every categorical mapping has come from profiling the column.

`YRDOB` is year of birth, **capped at 89** (the cap was 90 until April 2025, so it
may differ by extract vintage). There is no date of birth, so age is only ever
`year − YRDOB`, which is what the protocol asks for ("according to calendar
year"). The age **bands** are unaffected, since the cap sits above the 75
cut-point. A **mean or median** age is not: it is right-censored, and myeloma
has a real tail above 89.

**No medical-benefit or pharmacy-benefit flag exists on this table.** See §7.

### MEMBER_ENROLLMENT - the attributes are time-varying

`MEMBER_ENROLLMENT` carries **one row per member per change of anything**, so
`BUS`, `PRODUCT`, `CDHP`, `STATE` and even `GDR_CD` are span-level attributes,
not patient-level ones: the three `count(DISTINCT PATID)` totals above disagree
(`BUS` 23,632, `CDHP` 26,114, `PRODUCT` 30,651). The vendor documents one
tie-break, for `GDR_CD` on MEMBER_CONTINUOUS_ENROLLMENT (the latest that is not
`U`), and nothing for `RACE`, `ETHNICITY`, `BUS` or `STATE`.

So every Table 4 demographic timed "at index" is read off **the enrolment row
covering the index date**, with a total-order tie-break; the rule and its
measured cost are `OPEN_QUESTIONS.md` Q16. Age is the exception: it is computed
from the cohort table's `YRDOB`, which the cohort build ranks off its own rows
(a usable birth year first, then a known sex, then the most recent `ELIGEND`).

### MEMBER_CONTINUOUS_ENROLLMENT

`PATID`, `ELIGEFF`, `ELIGEND`, `GDR_CD`, `YRDOB`, `RACE`, `ETHNICITY`,
`RACE_SOURCE`, `EXTRACT_YM`, `VERSION`. One row per continuous span, bridging
breaks of **less than 30 days**.

This rollup is **not** what the protocol asks for. The protocol allows gaps of
**≤ 30 days**; the rollup bridges **< 30 days**, so a 30-day gap is continuous to
the protocol and a break to the rollup. Both builds therefore build their own
spans from `MEMBER_ENROLLMENT` (`build_enroll_spans()` here, with `GAP_DAYS`) -
the vendor rules say the user must stitch that table to find
continuous-enrollment start and end dates.

### MEDICAL

Claim-level, 62 columns. Columns that matter here:

| column | use |
|---|---|
| `PATID`, `PAT_PLANID`, `CLMID`, `CLMSEQ` | identity and join keys |
| `FST_DT`, `LST_DT` | first / last date of service |
| `LOC_CD` | part of the diagnosis and procedure join key |
| `CONF_ID` | `varchar(21)`; links to CONFINEMENT; **null ⇒ non-inpatient** |
| `POS` | place of service |
| `TOS_CD`, `TOS_EXT` | type of service |
| `PROC_CD`, `BILL_PROC_CD`, `PROCMOD`..`PROCMOD4` | CPT / HCPCS Level II - this is where **J-codes for administered MM agents** live |
| `RVNU_CD` | revenue code, facility claims only - needed for the pregnancy exclusion and for ED identification |
| `NDC`, `NDC_QTY`, `NDC_UOM` | NDC on a medical claim; Optum writes `NONE`/`UNK` where there is none |
| `UNITS`, `ALT_UNITS` | units administered |
| `DRG`, `DSTATUS`, `ADMIT_TYPE`, `ADMIT_CHAN`, `BILL_TYPE` | facility detail |
| `ICD_FLAG` | `'9'` or `'10'` |
| `PROV`, `BILL_PROV`, `REFER_PROV`, `SERVICE_PROV`, `PROVCAT`, `PROV_PAR` | provider links |
| `CHARGE`, `COPAY`, `COINS`, `DEDUCT`, `COB`, `STD_COST`, `STD_COST_YR` | cost |
| `OP_VISIT_ID`, `ENCTR`, `HCCC`, `PAID_DT`, `PAID_STATUS` | admin |

A provider can bill multiple revenue codes on one claim and each generates a
claim line; providers typically submit a separate claim per visit.

### MED_DIAGNOSIS

`PATID`, `PAT_PLANID`, `CLMID`, `DIAG`, `DIAG_POSITION`, `ICD_FLAG`, `LOC_CD`,
`POA`, `FST_DT`, `EXTRACT_YM`, `VERSION`.

- `DIAG` is the ICD-9/ICD-10-CM code **without a decimal point** - so `C90.00`
  is stored `C9000` and `203.00` is stored `20300`. Both sides are normalised
  with `upper(regexp_replace(x,'[^A-Za-z0-9]',''))`.
- `DIAG_POSITION` runs **1 to 25**, position 1 being the primary diagnosis, and
  is stored as a **zero-padded string** (below). The MM criterion is "in any
  position", so no filter; the claim route of the MM-related hospitalisation
  test reads positions 1 and 2 (`OPEN_QUESTIONS.md` Q27).
- `ICD_FLAG` is `'9'` for ICD-9 and `'10'` for ICD-10.
- `POA` is present-on-admission.

### MED_PROCEDURE

`PATID`, `PAT_PLANID`, `CLMID`, `PROC`, `PROC_POSITION`, `ICD_FLAG`, `LOC_CD`,
`FST_DT`, `EXTRACT_YM`, `VERSION`.

`PROC` is the **ICD-9/10 procedure** code; CPT and HCPCS are on
`MEDICAL.PROC_CD`. Business rule 5 says the opposite and is a transcription
error (`OPEN_QUESTIONS.md` Q17): over the study period `PROC` is **43,137,224 of
~43.2M rows at `ICD_FLAG='10'` and seven characters** - ICD-10-PCS - and the
five-character tail a HCPCS or CPT code could occupy is about **15,000 rows,
0.035%**. The cohort build still reads `PROC` as a fifth medication source,
because the failure is asymmetric: a therapy that goes unseen lets a patient
pass the no-prior-therapy criterion on missing data. Both tables matter for SCT
and CAR-T identification in the LOT engine.

### CONFINEMENT

`PATID`, `PAT_PLANID`, `CONF_ID`, `ADMIT_DATE`, `DISCH_DATE`, `LOS`,
`DIAG1`..`DIAG5`, `PROC1`..`PROC5`, `DRG`, `DSTATUS`, `ICD_FLAG`, `IPSTATUS`,
`POS`, `TOS_CD`, `PROV`, `CHARGE`, `COINS`, `COPAY`, `DEDUCT`, `STD_COST`,
`STD_COST_YR`, `ICU_IND`, `ICU_SURG_IND`, `MAJ_SURG_IND`, `MATERNITY_IND`,
`NEWBORN_IND`, `TOS_EXT`, `EXTRACT_YM`, `VERSION`.

The table for all-cause and MM-related hospitalisation. `ADMIT_DATE` is a real
`date` as deployed, with `_DAY` / `_MONTH` parts beside it, although Optum
documents `YYYYMMDD`. `ICD_FLAG` exists and is read for the family of `DIAG1`..
`DIAG5`, with the admission date as a fallback where it is null. `LOS` is the
length from the first confinement record to the last - a span over bundled
records - so the package computes LOS itself, admit (included) to discharge
(excluded), as the protocol asks, and does not read `LOS`.

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
There is **no `PAID_STATUS`** on the deployed pharmacy table, and `STD_COST` and
`CHK_DT` are absent from the V9.0 field list in `optum_cdm_fields.csv`, so that
list is incomplete for RX.

### LABRESULT

`LOINC_CD`, `TST_DESC`, `RSLT_TXT`, `RSLT_NBR`, `HI_NRML`, `LOW_NRML`, `FST_DT`.
Coverage is partial - only tests performed within certain laboratory networks -
which is why the protocol marks thrombocytopenia and anaemia *"dependent on data
availability"*. This package does not read it (§9).

### DOD

`PATID`, `YMDOD`, `EXTRACT_YM`, `VERSION`, `MBR_MATCH_TYPE`. **Month and year
only**: `YMDOD` is a `CCYYMM` string. The cohort build coarsens it to the 15th of
the month, or the month end where the 15th would fall before the diagnosis, so
every day-level survival number inherits a ±15-day uncertainty. This is a
separate mortality file, not part of the CDM V9.0 schema. `MBR_MATCH_TYPE` is
undocumented (`OPEN_QUESTIONS.md` Q28).

### SES

`PATID`, `D_EDUCATION_LEVEL_CODE`, `D_HOME_OWNERSHIP_CODE`,
`D_HOUSEHOLD_INCOME_RANGE_CODE`, `D_NETWORTH_RANGE_CODE`, `EXTRACT_YM`, `VERSION`.
Nothing the protocol asks for is here - race moved off this file in V9.0. The
2022 business rules still describe SES as seven characteristics including race
(`OPEN_QUESTIONS.md` Q18).

### Value domains, measured 07 Sep 2026

| column | values found | consequence |
|---|---|---|
| `MEMBER_ENROLLMENT.GDR_CD` | `F` 108,308,094 · `M` 102,595,572 · `U` 88,388 | the build maps M/F and sends the rest to Unknown |
| `MEMBER_ENROLLMENT.STATE` | **53 distinct values** - the 51 the crosswalk carries, plus `NULL` (3,829,750 rows / **2,570,332 members**) and `PR` (14,151 / 11,795) | region Unknown is overwhelmingly **missing state**, not territories: 2.4% of all members. Puerto Rico is a real gap in the crosswalk but a small one. Both belong in the Table 4 footnote. 5.7% of members hold two distinct `STATE` values; none holds three |
| `MEMBER_ENROLLMENT.YRDOB` | capped as documented: 12,769,783 members carry 1937 against ~1.4M in each neighbouring year; **`0` on 614 rows** | unguarded, a zero is an age of about 2026 and lands in the 75+ band. `03_demographics.R` returns a NULL age and an Unknown band outside a plausible range. Among the 93,236 myeloma members with an enrolment row there is no null or zero `YRDOB` and nobody with two birth years |
| `MED_DIAGNOSIS.DIAG_POSITION` | **zero-padded strings** `01` to `25`, plus `NULL` (1,576,237 rows) - nothing non-numeric | a string comparison against `'1'` matches nothing; anything reading it casts, and `try_cast(... as int)` is safe. The test fixture is zero-padded like the warehouse |
| `MED_DIAGNOSIS.ICD_FLAG` | `10` and `9` | as documented |
| claim `ICD_FLAG` naming neither family | `10` 11,414,536,709 · `9` 4,975,563,582 · null **530** | negligible; such a row matches no code and is reported, not gated (`OPEN_QUESTIONS.md` Q24) |
| ICD-9 myeloma codes | since 2016, 105,125 members carry an ICD-10 C90 code and **one** carries an ICD-9 203.0x code | the ICD-9 arm of every code-list join is dead weight for this study period |
| `CONFINEMENT.ICD_FLAG` | **present** - `10` 23,453,669 · `9` 15,054,996 · null 1,666 | the admit-date fallback is for the 1,666 nulls |
| `MEDICAL.PAID_STATUS` | **`P` and `D`**, no nulls table-wide since 2024; among myeloma patients P 78.69% / D 17.42% / null 3.89% | **The V9.0 schema spells these `PAID` and `DENIED`. The warehouse does not**, so a filter written from the schema is inert; `CLAIM_STATUS` matches both (`OPEN_QUESTIONS.md` Q25) |
| `MEDICAL.CONF_ID` | null or populated only - no `0`, no blank. 186,547,530 lines across 2,805,263 members carry one; 182,711,199 lines across 21,932,322 members do not | business rule 14's `CONF_ID IS NOT NULL` is enough to tell inpatient from not |
| `RX.FILL_DT`, `NDC`, `DAYS_SUP` | **zero nulls** - 22,107,537 lines, 99,155 members, 2000-05-01 to 2026-03-31 | |
| `STD_COST` (both tables) | **does not encode paid/denied.** 14,891,418 denied medical lines carry a positive `STD_COST`, and 1,034,482 paid lines a negative one; on RX there are no negative rows at all | it is a *standardised* price, not an amount paid. **Denied pharmacy claims cannot be identified by any column in this extract** |
| `DOD.YMDOD` | all 11,509,828 rows six characters, 200005 → 202603 | every death date has a month (`OPEN_QUESTIONS.md` Q22) |
| `DOD.MBR_MATCH_TYPE` | `2` 58.93% · `1` 41.07% | a binary flag; which value means what is undocumented (`OPEN_QUESTIONS.md` Q28) |

**`CONFINEMENT` shape.** Across 241,362 stays belonging to myeloma patients
since 2018, **no stay is missing a discharge date**, so the protocol's provision
for excluding such stays from LOS summaries never fires and `N_LOS_EXCLUDED`
will be 0. `LOS` equals `datediff(DISCH_DATE, ADMIT_DATE)` on 235,733 stays and
differs on 5,629 (2.3%); means 8.87 against 8.84.

### What the vendor rules do not cover

Each of these is a decision the build makes without documentation:

| topic | status |
|---|---|
| **Valid claims / exclusions** | No definition of a valid claim, and no rule for reversals, denials, duplicates, capitated encounters or adjustments. No claim-status filter is named anywhere (`OPEN_QUESTIONS.md` Q25) |
| **Member-months / person-time** | No denominator convention; never stated whether the days inside a bridged gap count as covered person-time (`OPEN_QUESTIONS.md` Q19) |
| **Overlapping spans** | Never addressed. Overlap across `PAT_PLANID`s for one `PATID` (dual coverage, mid-month switch) is neither asserted nor excluded; `build_enroll_spans()` merges on a running `max(ELIGEND)` so a nested span is not read as a gap |
| **Gap-rule precision** | "less than 30 day break in coverage" is the whole specification |
| **ICD-9 → ICD-10 transition** | Only `ICD_FLAG` is given. No cut-over date and no crosswalk guidance |
| **Code formatting** | The convention (ICD as entered, **without decimal point**) is on the MED_DIAGNOSIS schema, not in the rules |
| **Date shifting** | None documented (§10) |
| **Inpatient-administered drugs** | The gap is implied by RX being prescriptions filled on an **outpatient** basis and never stated outright |
| **Medicare Advantage vs Commercial** | No caveat of any kind: nothing on Part D vs commercial drug capture, MA encounter-data completeness, or a member whose `BUS` changes across spans |
| **Completeness by year** | No claims run-out or lag convention, and no incomplete-recent-quarter warning |

The business rules date from August 2022 and predate the V9.0 dictionary
(September 2023); treat them as a 2022 statement (`OPEN_QUESTIONS.md` Q18).

### Columns the study does not use and should consider

| column | table | what it is | why it matters |
|---|---|---|---|
| `POA` | MED_DIAGNOSIS | Present on Admission; conditions developing during an outpatient encounter, ED or observation count as POA | separates a condition present at admission from one acquired in hospital; bears directly on "severe infection **resulting in** hospitalization" |
| `CLMSEQ` | MEDICAL | distinguishes the detail records of a claim, used with `CLMID` | the documented MED_DIAGNOSIS↔MEDICAL join is `PATID + CLMID + FST_DT + LOC_CD` and omits it, so that join can fan out across a claim's detail lines |
| `RACE_SOURCE` | MEMBER_ENROLLMENT | which source the member's race came from | a race table that does not report the source composition is incomplete; measured, it is always `Self-Reported` |
| `LST_DT` | MEDICAL | the service **end** date (`FST_DT` is the beginning) | multi-day services have a span this package reads as a point |
| `ENCTR` | MEDICAL | fee-for-service vs capitated | encounters under capitation can be under-reported |
| `OP_VISIT_ID` | MEDICAL | an outpatient visit grouper | would be the vendor's own visit grain for ED, but it is regenerated by the Standard Cost Algorithm on each run and so is not stable across refreshes. This package groups ED claims to one per patient per day instead |

## 5. Identifying inpatient vs outpatient

The protocol leans on this twice (MM diagnosis, other-cancer exclusion). Two
approaches are documented, and the cohort build applies **both, OR'd**, at the
claim-line level before `max(POS)` can hide an inpatient code - the
conservative reading.

**Approach 1 - service codes**, as the build spells them:
```
inpatient  ⇔  POS IN ('21','51','61')
              OR TOS_CD IN ('FAC_IP.ACUTE','FAC_IP.REHSNF','PROF.INPVIS','FAC_IP.SNF')
outpatient ⇔  none of the above
```

**Approach 2 - confinement**: inpatient records are those with a non-null
`CONF_ID` in CONFINEMENT; everything without a `CONF_ID` is non-inpatient
(business rule 14).

This package's outcomes use CONFINEMENT directly: a hospitalisation is a
CONFINEMENT row, and an inpatient-defined safety condition is a diagnosis on a
medical claim carrying a `CONF_ID` that CONFINEMENT knows, dated at the
admission.

## 6. Identifying emergency department visits

The CDM has **no ED flag**, and the vendor says non-inpatient records are to be
classified as per the study requirements. The usual claims constructions,
each an `ED_DEFINITION` value with its codes in `hcru.csv`:

| `ED_DEFINITION` | `hcru.csv` `code_type` | matched against |
|---|---|---|
| `revenue` | `RVNU` | `MEDICAL.RVNU_CD` - 045x (0450, 0451, 0452, 0456, 0459) and 0981; facility claims only |
| `pos` | `POS` | `MEDICAL.POS` - `23`, emergency room - hospital |
| `cpt` | `CPT` | `MEDICAL.PROC_CD` - 99281-99285; professional claims |

The default is `revenue,pos`; `hcru.csv` carries the three code types with no
codes yet. The constructions select different claim types, and one ED visit
generating both a facility and a professional claim is collapsed by counting
one visit per patient per day. `ED_ADMITTED` decides whether an ED claim
carrying a `CONF_ID` also counts as an ED visit. `MEDICAL.TOS_EXT` plausibly
carries an ED category, but its lookup values are not published.
`OPEN_QUESTIONS.md` Q11 has the choice and what it moves.

## 7. Medical **and** pharmacy benefits

Inclusion criterion I4 requires 12 months of CE "with medical and pharmacy
benefits". `MEMBER_ENROLLMENT` as deployed has no benefit-type flag (§4) -
`ASO`, `CDHP`, `HEALTH_EXCH`, `PRODUCT`, `BUS` are funding and plan attributes -
and neither does the V9.0 schema. The protocol's own §7.5 says: *"All patients
in this database have both medical and pharmacy coverage, allowing analysis of
overall healthcare utilization."* So the requirement is satisfied by
construction: a span carries both, and `ELIGEFF`/`ELIGEND` already express it.

Do not re-derive it from claims: enrolled patients with no pharmacy fill look
like a coverage signal and are not, since that count is dominated by short
spans and by patients whose only MM code is a rule-out. `OPEN_QUESTIONS.md` Q4.

## 8. Variable → source, criteria

I1-I4 and X1-X3 are applied by the cohort build, X4 by the cohort build (before
the 1L index) and the LOT engine (from it onward), and N1, N2 and I5 by this
package (`IE_CRITERIA_APPLIED.md` §2).

| criterion | tables | columns | rule |
|---|---|---|---|
| I1 MM diagnosis | `med_diagnosis` + `medical` + `confinement` | `DIAG`, `ICD_FLAG`, `FST_DT`, `POS`, `TOS_CD`, `CONF_ID`, `ADMIT_DATE`, `DISCH_DATE` | 1 IP claim with 203.0x/C90.0x, or 2 OP claims ≤ 90 d apart on separate days, in the study period |
| I2 age ≥ 18 | `member_cont_enrollment` | `YRDOB` | `year(MM_DX_DT) - YRDOB >= 18` |
| I3 eligible 1L treatment | `rx` + `medical` + `med_procedure` | `NDC`, `FILL_DT`; `PROC_CD`, `BILL_PROC_CD`, `NDC`, `FST_DT`; `PROC`, `ICD_FLAG`, `FST_DT` | earliest claim matching `cl_mma_codelist.csv`, on/after `MM_DX_DT`, on/after 2019-01-01, agent not in {belantamab, panobinostat, elotuzumab} |
| I4 12-month CE | `member_enrollment` | `PATID`, `ELIGEFF`, `ELIGEND` | own spans bridging gaps ≤ 30 d; one span covering `[index-365, index-1]` |
| I5 follow-up | `medical` + `rx`, death | `FST_DT`, `FILL_DT`, `DEATH_DT` | ≥ 1 claim from the index, or death (`FU_EVIDENCE_RULE`, `OPEN_QUESTIONS.md` Q5) |
| X1 prior MM therapy | `rx` + `medical` + `med_procedure` | as I3 | any MM oncology agent in `[index-365, index-1]`, steroids dropped (`OPEN_QUESTIONS.md` Q6) |
| X2 other cancer | `med_diagnosis` + `medical` + `confinement` | `DIAG`, `ICD_FLAG`, `FST_DT`, `POS`, `TOS_CD`, `CONF_ID` | ≥ 1 IP, or ≥ 2 OP on separate days ≤ 30 d apart on the same 3-character ICD category and/or metastatic, in `[index-365, index-1]` |
| X3 pregnancy | `med_diagnosis` + `medical` + `med_procedure` | `DIAG`, `PROC_CD`, `BILL_PROC_CD`, `RVNU_CD`, `PROC` | ≥ 1 claim with a pregnancy/childbirth diagnosis, procedure **or revenue** code, anywhere in the study period |
| X4 belantamab | `rx` + `medical` + `med_procedure`, then the LOT tables | as I3 | any belantamab claim before the 1L index (cohort build, `NO_BELANTAMAB_PRE_LOT1`), or in any line (LOT engine) |
| N1 received 2L/3L | LOT output | `LOT_NUM`, `LOT_START_DT` | a LOT 2 / LOT 3 row exists |
| N2 CE before 2L/3L | `member_enrollment` | as I4 | the same span test against the 2L/3L index |

## 9. Variable → source, analysis variables

Grouped as `VARIABLES.md` groups them.

| variable | source | notes |
|---|---|---|
| Age (continuous, and 18-44/45-64/65-74/75+; `<75`/`75+` for stratification) | cohort table `YRDOB` | index (or diagnosis) calendar year − `YRDOB`; capped at 89 |
| Sex (M/F/Unknown) | `member_enrollment.GDR_CD` | from the enrolment row selected for the index, else the cohort table's |
| Region (Midwest/South/West/Northeast/Unknown) | `member_enrollment.STATE` + a census crosswalk | `REGION` is not on the deployed table (§4) |
| Race (Asian/Black/White/Unknown) | `member_enrollment.RACE` | `A`→Asian, `B`→Black, `W`→White, anything else Unknown |
| Ethnicity (Hispanic/Not Hispanic/Unknown) | `member_enrollment.ETHNICITY` | `H`→Hispanic or Latino, `N`→Not Hispanic or Latino, anything else Unknown |
| Insurance type (Medicare / Commercial) | `member_enrollment.BUS` | `MCR` / `COM` |
| Charlson Comorbidity Index (Quan 2011), MM-adjusted | `med_diagnosis.DIAG`, `.ICD_FLAG`, `.FST_DT` over the comorbidity baseline | `charlson_quan2011.csv`; a code on `mm_dx.csv` supports no condition |
| Kim Frailty Index (CFI ≥ 0.25 = frail) | `med_diagnosis` over the baseline | `frailty_kim2018.csv`, Annex 7; this implementation matches diagnosis codes only |
| Year of MM diagnosis | cohort table `MM_DX_DT`, or the first MM claim in the 1L baseline | `DX_DATE_SOURCE` (`OPEN_QUESTIONS.md` Q30) |
| Follow-up time from diagnosis / from index | diagnosis date, index, enrolment spans, `DEATH_DT`, study end | months, both endpoints inclusive; follow-up ends at disenrollment under `CENSOR_AT_DISENROLLMENT` (`OPEN_QUESTIONS.md` Q13) |
| Year of 1L / 2L / 3L initiation | LOT output | 2019 → latest data availability |
| Types of 1L/2L/3L SOCs or classes by line | LOT output (`LOT_BASE_MEDS`) + `soc_regimen_categories.csv` | categorised by the agents on `CL_MED_ABBR` - Annex 2 |
| Key safety events (Table 3) | `med_diagnosis.DIAG` (+ `medical.CONF_ID` and `confinement` for the inpatient-defined ones) | `safety_events.csv`, 23 rows - Annex 3 (`OPEN_QUESTIONS.md` Q36) |
| All-cause inpatient hospitalisation | `confinement` | `ADMIT_DATE`, `DISCH_DATE`, `CONF_ID`; LOS computed, not read |
| MM-related hospitalisation | `confinement.DIAG1`/`DIAG2`, or `med_diagnosis` with `DIAG_POSITION` 1-2 on a claim carrying the `CONF_ID` | `MM_HOSP_POSITION` (`OPEN_QUESTIONS.md` Q27) |
| Emergency visits | `medical.RVNU_CD` / `.POS` / `.PROC_CD` | §6 |
| Secondary malignancy (type + category) | `med_diagnosis.DIAG`, `.FST_DT` | `secondary_malig.csv`; "at least 2 diagnosis codes occurring on separate dates. The date of the first ICD code will be used" (`OPEN_QUESTIONS.md` Q35) |
| Thrombocytopenia, anaemia | `med_diagnosis` | diagnosis-defined; the protocol marks both *"dependent on data availability"*, and `lab` is not read |
| TTNT / TTD / OS / attrition | LOT output + cohort table `DEATH_DT` + study end | `VARIABLES.md` §7 |
| SCT and CAR-T | LOT output (the engine reads `med_procedure.PROC`, `medical.PROC_CD`, `medical.BILL_PROC_CD` against `cl_sct_codelist.csv`) | the engine's transplant flags, on `S_SOC` |
| Death | cohort table `DEATH_DT`, from `dod.YMDOD` | month+year only |

## 10. Caveats that change a number

1. **Death is month-precision.** Every OS, TTD and follow-up figure inherits ±15
   days from the constructed day (§4 DOD). OS is an outcome the protocol reports,
   so the imprecision reaches a headline figure.
2. **Enrolment rollup vs protocol gap rule** differ by one day at the boundary,
   which is why both builds stitch their own spans (§4).
3. **`YRDOB` is capped at 89** - a mean or median age is right-censored in a way
   that understates the very old.
4. **Lab coverage is partial** - network-restricted, so lab-defined outcomes
   would not be population-representative.
5. **`RACE`/`ETHNICITY` are suppressed for small cells** - patients with
   HIPAA-restricted cell sizes are folded into Other/Unknown - and are null or
   `U` on a large share of rows (§4).
6. **Inpatient-administered drugs are invisible to RX** and may be bundled into a
   DRG rather than itemised on MEDICAL, so in-hospital MM therapy can be missed.
7. **`NDC` on MEDICAL is frequently `NONE`/`UNK`** - 1.2 bn such rows. Never
   left-pad those into a join key.
8. **Everything is ICD-10.** The study period starts in 2018, after the October
   2015 transition, so the ICD-9 arms of every code list are dead weight (§4).
9. **No clinical staging exists.** No ISS/R-ISS, no cytogenetics or FISH, no ECOG,
   no tumour-registry linkage, no treatment intent. That is why the protocol uses
   age ≥ 75 as its transplant-eligibility proxy.
10. **No date shifting is documented.** Claim dates are full-precision calendar
    dates; de-identification is by **encryption of identifiers** (PATID,
    PAT_PLANID, CLMID, CONF_ID, FAMILY_ID and every provider id). The only
    deliberate coarsening is `YRDOB` (year, capped at 89) and death (`YMDOD`).
11. **`DOD` is not part of the V9.0 schema.** The only in-schema death signal is a
    `DSTATUS` of "expired" on a confinement, whose lookup values are not
    published. The `dod` table is a separate mortality file.
12. **The quarterly tables are cumulative** - the suffix is chosen from
    `STUDY_END`, so a rerun against a newer quarter is a different denominator.
