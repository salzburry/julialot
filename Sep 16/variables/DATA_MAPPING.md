# Optum CDM data mapping and code lists

Where every criterion and variable comes from in the Optum Clinformatics Data
Mart, at table-and-column level; the caveats that change what a number means;
and every code list the package reads.

## 1. Where the data physically is

```
catalog  hive_metastore                  # DATABRICKS_CATALOG
schema   clnprw_optum                    # OPTUM_CDM_SCHEMA
table    t_<base>_<yyyy>q<n>             # cumulative quarterly tables, suffix from STUDY_END
```

So `member_enrollment` with `STUDY_END = 2026-03-31` resolves to
`hive_metastore.clnprw_optum.t_member_enrollment_2026q1`
(`USE_QUARTERLY_TABLES=FALSE` drops the prefix and suffix). The schema holds one
table per quarter back to `2016q4`; the `2026q1` vintage has the same tables and
column names as earlier ones, with data through 2026-03-31. Code lists are not
in the warehouse (§11).

## 2. Table inventory

| build name | CDM name | grain | what it carries |
|---|---|---|---|
| `member_enrollment` | MEMBER_ENROLLMENT | one row per member per coverage state | a **new row each time anything about the member changes** (state, product) |
| `member_cont_enrollment` | MEMBER_CONTINUOUS_ENROLLMENT | one row per continuous span | a rollup of the above bridging a **break of less than 30 days** |
| `medical` | MEDICAL | one row per claim line | professional (CPT/HCPCS) **and** facility claims |
| `diagnosis` → `med_diagnosis` | MED_DIAGNOSIS | one row per claim per diagnosis position | diagnoses split out of the claim |
| `procedure` → `med_procedure` | MED_PROCEDURE | one row per claim per procedure position | ICD-9/10 **procedure** codes (CPT/HCPCS live on `MEDICAL.PROC_CD`) |
| `confinement` | CONFINEMENT | one row per hospitalisation | unduplicated, with the facility detail records bundled into it |
| `rx` | RX | one row per pharmacy fill | outpatient pharmacy only |
| `lab` | LABRESULT | one row per result | only tests within certain laboratory networks |
| `dod` | DOD | one row per decedent | **month and year** of death |
| `ses` | SES | one row per member | education, income, home ownership, net worth |

The left column is the short name the modules use; for two of them the physical
table differs (`med_diagnosis`, `med_procedure`). `CDM_TABLE_NAMES` in
`R/db_utils_223926.R` holds the mapping, the test suite pins it, and the
`TBL_*` settings override a base name.

**What reads what.** This package reads `medical`, `med_diagnosis`,
`confinement`, `member_enrollment` and `rx`. Death, birth year and the
qualifying MM diagnosis date come from the cohort table (`DEATH_DT`, `YRDOB`,
`MM_DX_DT`), which the cohort build derives from `dod`,
`member_cont_enrollment` and `med_diagnosis`; transplant and CAR-T come from the
LOT engine's lines. Nothing reads `lab`, `ses` or the provider tables.

## 3. How the tables join

```
MEDICAL  ──(PATID | PAT_PLANID, CLMID, FST_DT, LOC_CD)──  MED_DIAGNOSIS
MEDICAL  ──(PATID | PAT_PLANID, CLMID, FST_DT, LOC_CD)──  MED_PROCEDURE
MEDICAL  ──(PAT_PLANID, CONF_ID)───────────────────────  CONFINEMENT
MEMBER_ENROLLMENT / MEMBER_CONTINUOUS_ENROLLMENT
         ──(PATID | PAT_PLANID*, FST_DT / ADMIT_DATE / FILL_DT between ELIGEFF and ELIGEND)──  MEDICAL / CONFINEMENT / RX
         ──(PATID)──  SES, DOD
```

`*` Continuous Enrollment: use PATID. Member Enrollment: use PAT_PLANID.

Diagnosis joins to the claim on `PATID, CLMID, FST_DT` with null-safe equality
on `PAT_PLANID` and `LOC_CD`. The documented key omits `CLMSEQ`, so the join can
fan out across a claim's detail lines. The business rules say DOD and SES are
encrypted differently and cannot be joined; for DOD that does not hold here -
all 11,509,828 of its patients match the enrolment table on `PATID` (Q8). The
SES join is untested and nothing the study uses is on SES.

## 4. Columns, verified

### MEMBER_ENROLLMENT - as deployed

`describe table hive_metastore.clnprw_optum.t_member_enrollment_2025q4` returns
**27 columns**:

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

**The deployed table is a different vintage from the V9.0 schema**, which gives
20 columns including `LIS_DUAL` and `REGION` and no `STATE`. Of V9.0's four
additions, three landed (`ETHNICITY`, `RACE` moved off SES, `RACE_SOURCE`) and
`REGION` did not, while `STATE` is still there. `describe table` before writing
any column into code. **Region** is therefore derived from `STATE` with a
50-state + DC → US Census region crosswalk (`REGION_SOURCE=state_crosswalk`);
`REGION_SOURCE=region_column` is refused at preflight (Q9).

Observed values in the MM population:

| field | values (n patients) |
|---|---|
| `BUS` | `MCR` 17,874 · `COM` 5,758 |
| `PRODUCT` | `OTH` 16,066 · `HMO` 6,726 · `POS` 3,995 · `PPO` 2,569 · `EPO` 1,054 · `IND` 241 |
| `CDHP` | `U` 16,975 · `3` 7,467 · `2` 1,121 · `1` 551 |

So insurance type (Medicare / Commercial Health Plan) is `BUS` `MCR` / `COM`;
`PRODUCT` is the plan form, a different axis. `LIS_DUAL` is absent;
`RX.FORM_TYP` (NULL for Medicare) and `ASO` (`Y`/`N`, self-funded commercial)
are cross-checks for `BUS`, not replacements.

`RACE` is `W`, `B`, `A`, `U` or null and `ETHNICITY` is `N`, `H`, `U` or null;
`RACE_SOURCE` is always `Self-Reported` (Q10). The dictionary reports race as
African American, Asian, Caucasian and Other/Unknown (the last including
HIPAA-restricted cell sizes) and publishes no ethnicity values. Race is null or
`U` on about 42% of enrolment rows and ethnicity on about 36%. About 25 lookup
code tables are named in the dictionary without their values, so every
categorical mapping comes from profiling the column.

`YRDOB` is year of birth, **capped at 89** (older extracts capped at 90). There
is no date of birth, so age is only ever `year − YRDOB` - what the protocol asks
("according to calendar year"). The age bands are unaffected, since the cap
sits above 75; a **mean or median** age is right-censored, and myeloma has a
real tail above 89.

**The attributes are time-varying.** One row per member per change of anything
makes `BUS`, `PRODUCT`, `CDHP`, `STATE` and even `GDR_CD` span-level attributes
(the three patient totals above disagree: `BUS` 23,632, `CDHP` 26,114, `PRODUCT`
30,651). The vendor documents one tie-break, for `GDR_CD` on
MEMBER_CONTINUOUS_ENROLLMENT, and nothing for the rest, so every demographic
timed "at index" is read off the enrolment row covering the index date with a
total-order tie-break (`VARIABLES.md` "4. Primary Objective 1 — baseline characteristics (Table 4)", Q16). Age comes
from the cohort table's `YRDOB`, which the cohort build ranks off its own rows
(a usable birth year first, then a known sex, then the latest `ELIGEND`).

**No medical-benefit or pharmacy-benefit flag exists** on this table (§7).

### MEMBER_CONTINUOUS_ENROLLMENT

`PATID`, `ELIGEFF`, `ELIGEND`, `GDR_CD`, `YRDOB`, `RACE`, `ETHNICITY`,
`RACE_SOURCE`, `EXTRACT_YM`, `VERSION`. The rollup bridges breaks of **less than
30 days**; the protocol allows gaps of **≤ 30 days**, so a 30-day gap is
continuous to the protocol and a break to the rollup. Both builds therefore
stitch their own spans from `MEMBER_ENROLLMENT` (`build_enroll_spans()` here,
with `GAP_DAYS`, merging on a running `max(ELIGEND)` so a nested span is not
read as a gap), as the vendor rules say the user must.

### MEDICAL

Claim-level, 62 columns. The ones this study reads:

| column | use |
|---|---|
| `PATID`, `PAT_PLANID`, `CLMID`, `FST_DT`, `LOC_CD` | identity, service date, and the diagnosis/procedure join key |
| `CONF_ID` | `varchar(21)`; links to CONFINEMENT; **null ⇒ non-inpatient** (business rule 14) |
| `POS`, `TOS_CD` | place and type of service - inpatient identification (§5), ED by POS (§6) |
| `PROC_CD`, `BILL_PROC_CD` | CPT / HCPCS Level II - where **J-codes for administered MM agents** live |
| `RVNU_CD` | revenue code, facility claims only - the pregnancy exclusion and ED identification |
| `NDC` | NDC on a medical claim; Optum writes `NONE`/`UNK` where there is none |
| `PAID_STATUS` | paid or denied (`CLAIM_STATUS`, Q25) |

Not read, and worth knowing: `LST_DT` (the service end date, so a multi-day
service is read as a point), `ENCTR` (fee-for-service vs capitated; capitated
encounters can be under-reported), `OP_VISIT_ID` (regenerated on each refresh,
so ED visits are grouped one per patient per day instead).

### MED_DIAGNOSIS

`PATID`, `PAT_PLANID`, `CLMID`, `DIAG`, `DIAG_POSITION`, `ICD_FLAG`, `LOC_CD`,
`POA`, `FST_DT`, `EXTRACT_YM`, `VERSION`.

- `DIAG` is stored **without a decimal point** (`C90.00` is `C9000`). Both sides
  are normalised with `upper(regexp_replace(x,'[^A-Za-z0-9]',''))`.
- `DIAG_POSITION` runs 1 to 25, position 1 primary, stored as a zero-padded
  string (§4, value domains). The MM criterion is "in any position"; the claim
  route of the MM-related hospitalisation test reads positions 1 and 2 (Q27).
- `ICD_FLAG` is `'9'` or `'10'`.
- `POA` (present on admission) is not read; it would separate a condition
  present at admission from one acquired in hospital, which bears on "severe
  infection **resulting in** hospitalization".

### MED_PROCEDURE

`PATID`, `PAT_PLANID`, `CLMID`, `PROC`, `PROC_POSITION`, `ICD_FLAG`, `LOC_CD`,
`FST_DT`. `PROC` is the **ICD-9/10 procedure** code; CPT and HCPCS are on
`MEDICAL.PROC_CD`. Business rule 5 says the opposite and is a transcription
error (Q17): over the study period `PROC` is 43,137,224 of ~43.2M rows at
`ICD_FLAG='10'` and seven characters - ICD-10-PCS - and the five-character tail a
HCPCS or CPT code could occupy is about 15,000 rows (0.035%). The cohort build
still reads `PROC` as a medication source, because a therapy that goes unseen
lets a patient pass the no-prior-therapy criterion on missing data. Both tables
matter for SCT and CAR-T identification in the LOT engine.

### CONFINEMENT

Read: `PATID`, `CONF_ID`, `ADMIT_DATE`, `DISCH_DATE`, `DIAG1`..`DIAG5`,
`ICD_FLAG`. `ADMIT_DATE` is a real `date` as deployed, although Optum documents
`YYYYMMDD`. `ICD_FLAG` gives the family of `DIAG1`..`DIAG5`, with the admission
date (before or after 2015-10-01) as the fallback where it is null. `LOS` is the
span from the first confinement record to the last, so the package computes LOS
itself, admit (included) to discharge (excluded), and does not read it. Across
241,362 stays of myeloma patients since 2018, **no stay lacks a discharge
date**, so `N_LOS_EXCLUDED` will be 0; `LOS` equals `datediff(DISCH_DATE,
ADMIT_DATE)` on 235,733 stays and differs on 5,629 (2.3%), means 8.87 against
8.84.

### RX

Read: `PATID`, `NDC`, `FILL_DT`, `DAYS_SUP` (not `DAY_SUPPLY`). Oral MM agents
(lenalidomide, pomalidomide, ixazomib, thalidomide, cyclophosphamide,
melphalan, panobinostat, selinexor, dexamethasone) come through here; infusions
do not. There is **no `PAID_STATUS`** on the deployed pharmacy table, and
`STD_COST` and `CHK_DT` are present although not in the V9.0 field list.

### LABRESULT, DOD, SES

**LABRESULT** (`LOINC_CD`, `TST_DESC`, `RSLT_TXT`, `RSLT_NBR`, `HI_NRML`,
`LOW_NRML`, `FST_DT`) covers only tests within certain laboratory networks,
which is why the protocol marks thrombocytopenia and anaemia *"dependent on
data availability"*. Not read.

**DOD** (`PATID`, `YMDOD`, `EXTRACT_YM`, `VERSION`, `MBR_MATCH_TYPE`) is **month
and year only**: `YMDOD` is a `CCYYMM` string. The cohort build dates death on
the 15th of the month, or the month end where the 15th would fall before the
diagnosis, so every day-level survival number carries a ±15-day uncertainty.
It is a separate mortality file, not part of the V9.0 schema, whose only
in-schema death signal is a `DSTATUS` of "expired" on a confinement.
`MBR_MATCH_TYPE` is undocumented (Q28).

**SES** (`PATID`, `D_EDUCATION_LEVEL_CODE`, `D_HOME_OWNERSHIP_CODE`,
`D_HOUSEHOLD_INCOME_RANGE_CODE`, `D_NETWORTH_RANGE_CODE`) carries nothing the
protocol asks for; race moved off it in V9.0, though the 2022 business rules
still list race there (Q18).

### Value domains, as measured

| column | values found | consequence |
|---|---|---|
| `MEMBER_ENROLLMENT.GDR_CD` | `F` 108,308,094 · `M` 102,595,572 · `U` 88,388 | M/F mapped, the rest Unknown |
| `MEMBER_ENROLLMENT.STATE` | 53 distinct values - the 51 the crosswalk carries, plus `NULL` (3,829,750 rows / 2,570,332 members) and `PR` (14,151 / 11,795) | region Unknown is overwhelmingly missing state (2.4% of members), not territories; both belong in the Table 4 footnote. 5.7% of members hold two `STATE` values, none three |
| `MEMBER_ENROLLMENT.YRDOB` | capped: 12,769,783 members carry 1937 against ~1.4M in each neighbouring year; `0` on 614 rows | unguarded, a zero is an age of about 2026; the package returns a NULL age and an Unknown band outside a plausible range. Among the 93,236 myeloma members with an enrolment row there is no null or zero `YRDOB` and nobody with two birth years |
| `MED_DIAGNOSIS.DIAG_POSITION` | zero-padded strings `01` to `25`, plus `NULL` (1,576,237 rows) | a string comparison against `'1'` matches nothing; it is cast with `try_cast(... as int)` |
| claim `ICD_FLAG` | `10` 11,414,536,709 · `9` 4,975,563,582 · null 530 | negligible; a row naming neither family matches no code and is reported, not gated (Q24) |
| ICD-9 myeloma codes | since 2016, 105,125 members carry an ICD-10 C90 code and **one** an ICD-9 203.0x code | the ICD-9 arm of every code-list join is dead weight for this study period |
| `CONFINEMENT.ICD_FLAG` | `10` 23,453,669 · `9` 15,054,996 · null 1,666 | the admit-date fallback is for the 1,666 nulls |
| `MEDICAL.PAID_STATUS` | `P` and `D`, no nulls table-wide since 2024; among myeloma patients P 78.69% / D 17.42% / null 3.89% | the V9.0 schema spells them `PAID` and `DENIED`; `CLAIM_STATUS` matches both (Q25) |
| `MEDICAL.CONF_ID` | null or populated only - 186,547,530 lines across 2,805,263 members carry one; 182,711,199 lines across 21,932,322 members do not | `CONF_ID IS NOT NULL` is enough to tell inpatient from not |
| `RX.FILL_DT`, `NDC`, `DAYS_SUP` | zero nulls - 22,107,537 lines, 99,155 members, 2000-05-01 to 2026-03-31 | |
| `STD_COST` (both tables) | does not encode paid/denied: 14,891,418 denied medical lines carry a positive value, 1,034,482 paid lines a negative one; RX has no negative rows | a standardised price, not an amount paid. **Denied pharmacy claims cannot be identified by any column in this extract** |
| `DOD.YMDOD` | all 11,509,828 rows six characters, 200005 → 202603 | every death date has a month (Q22) |
| `DOD.MBR_MATCH_TYPE` | `2` 58.93% · `1` 41.07% | a binary flag; which value means what is undocumented (Q28) |

### What the vendor rules leave to the study

The business rules predate the V9.0 dictionary; treat them as a 2022 statement
(Q18). They do not define a valid claim (reversals, denials, duplicates,
capitated encounters, adjustments - `CLAIM_STATUS`, Q25); a person-time
convention or whether bridged gap days are covered (Q19); overlapping spans
across `PAT_PLANID`s (merged on a running `max(ELIGEND)`); gap precision beyond
"less than 30 day break"; an ICD-9 → ICD-10 cut-over (only `ICD_FLAG`); date
shifting (none documented, §10); inpatient-administered drugs (implied only by
RX being outpatient fills); Medicare Advantage against commercial capture, or a
member whose `BUS` changes; claims run-out or an incomplete recent quarter.

## 5. Identifying inpatient vs outpatient

The protocol leans on this for the MM diagnosis and the other-cancer
exclusion. The cohort build applies both documented approaches, OR'd, at the
claim-line level before `max(POS)` can hide an inpatient code:

```
approach 1:  inpatient ⇔ POS IN ('21','51','61')
                         OR TOS_CD IN ('FAC_IP.ACUTE','FAC_IP.REHSNF','PROF.INPVIS','FAC_IP.SNF')
approach 2:  inpatient ⇔ a non-null CONF_ID in CONFINEMENT (business rule 14)
```

This package's outcomes use CONFINEMENT directly: a hospitalisation is a
CONFINEMENT row, and an inpatient-defined safety condition is a diagnosis on a
medical claim carrying a `CONF_ID` that CONFINEMENT knows, dated at the
admission.

## 6. Identifying emergency department visits

The CDM has **no ED flag**, and the vendor says non-inpatient records are to be
classified as the study requires. Each construction is an `ED_DEFINITION` value
with its codes in `hcru.csv`:

| `ED_DEFINITION` | `hcru.csv` `code_type` | matched against |
|---|---|---|
| `revenue` | `RVNU` | `MEDICAL.RVNU_CD` - 045x (0450, 0451, 0452, 0456, 0459) and 0981; facility claims |
| `pos` | `POS` | `MEDICAL.POS` - `23`, emergency room - hospital |
| `cpt` | `CPT` | `MEDICAL.PROC_CD` - 99281-99285; professional claims |

The default is `revenue,pos`. One ED visit generating a facility and a
professional claim is collapsed by counting one visit per patient per day.
`ED_ADMITTED=both` (default) also counts an ED claim carrying a `CONF_ID` as an
ED visit; `inpatient_only` drops it. `MEDICAL.TOS_EXT` plausibly carries an ED
category, but its lookup values are not published (Q11).

## 7. Medical and pharmacy benefits

I4 requires 12 months of CE "with medical and pharmacy benefits". Neither the
deployed `MEMBER_ENROLLMENT` nor the V9.0 schema has a benefit-type flag (`ASO`,
`CDHP`, `HEALTH_EXCH`, `PRODUCT`, `BUS` are funding and plan attributes), and
the protocol's §7.5 says *"All patients in this database have both medical and
pharmacy coverage"*. So the requirement is satisfied by construction (Q4). Do
not re-derive it from claims: enrolled patients with no pharmacy fill look like
a coverage signal and are not - that count is dominated by short spans and by
patients whose only MM code is a rule-out.

## 8. Variable → source, criteria

Who applies each criterion is `IE_CRITERIA.md` "9. Who applies each criterion".

| criterion | tables | columns | rule |
|---|---|---|---|
| I1 MM diagnosis | `med_diagnosis` + `medical` + `confinement` | `DIAG`, `ICD_FLAG`, `FST_DT`, `POS`, `TOS_CD`, `CONF_ID`, `ADMIT_DATE`, `DISCH_DATE` | 1 IP claim with 203.0x/C90.0x, or 2 OP claims ≤ 90 d apart on separate days, in the study period |
| I2 age ≥ 18 | `member_cont_enrollment` | `YRDOB` | `year(MM_DX_DT) - YRDOB >= 18` |
| I3 eligible 1L treatment | `rx` + `medical` + `med_procedure` | `NDC`, `FILL_DT`; `PROC_CD`, `BILL_PROC_CD`, `NDC`, `FST_DT`; `PROC`, `ICD_FLAG`, `FST_DT` | earliest claim matching `cl_mma_codelist.csv`, on/after `MM_DX_DT`, on/after 2019-01-01, agent not belantamab, panobinostat or elotuzumab |
| I4 12-month CE | `member_enrollment` | `PATID`, `ELIGEFF`, `ELIGEND` | own spans bridging gaps ≤ 30 d; one span covering `[index-365, index-1]` |
| I5 follow-up | `medical` + `rx`, death | `FST_DT`, `FILL_DT`, `DEATH_DT` | ≥ 1 claim from the index, or death (`FU_EVIDENCE_RULE`, Q5) |
| X1 prior MM therapy | as I3 | as I3 | any MM oncology agent in `[index-365, index-1]`, steroids dropped (Q6) |
| X2 other cancer | `med_diagnosis` + `medical` + `confinement` | `DIAG`, `ICD_FLAG`, `FST_DT`, `POS`, `TOS_CD`, `CONF_ID` | ≥ 1 IP, or ≥ 2 OP on separate days ≤ 30 d apart on the same 3-character ICD category and/or metastatic, in `[index-365, index-1]` |
| X3 pregnancy | `med_diagnosis` + `medical` + `med_procedure` | `DIAG`, `PROC_CD`, `BILL_PROC_CD`, `RVNU_CD`, `PROC` | ≥ 1 claim with a pregnancy/childbirth diagnosis, procedure **or revenue** code, anywhere in the study period |
| X4 belantamab | as I3, then the LOT tables | as I3 | any belantamab claim before the 1L index (cohort build), or in any line (LOT engine) |
| N1 received 2L/3L | LOT output | `LOT_NUM`, `LOT_START_DT` | a LOT 2 / LOT 3 row exists |
| N2 CE before 2L/3L | `member_enrollment` | as I4 | the same span test against the 2L/3L index |

## 9. Variable → source, analysis variables

| variable | source | notes |
|---|---|---|
| Age (continuous, 18-44/45-64/65-74/75+; `<75`/`75+` for stratification) | cohort table `YRDOB` | index (or diagnosis) calendar year − `YRDOB`; capped at 89 |
| Sex (M/F/Unknown) | `member_enrollment.GDR_CD` | from the enrolment row selected for the index, else the cohort table's |
| Region | `member_enrollment.STATE` + census crosswalk | anything outside the 50 states + DC is Unknown |
| Race (Asian/Black/White/Unknown) | `member_enrollment.RACE` | `A`→Asian, `B`→Black, `W` or `C`→White, anything else Unknown |
| Ethnicity | `member_enrollment.ETHNICITY` | `H`→Hispanic or Latino, `N`→Not Hispanic or Latino, anything else Unknown |
| Insurance type | `member_enrollment.BUS` | `MCR`→Medicare, `COM`→Commercial Health Plan, anything else Unknown |
| Charlson (Quan 2011), MM-adjusted | `med_diagnosis.DIAG`, `ICD_FLAG`, `FST_DT` over the comorbidity baseline | `charlson_quan2011.csv`; a code on `mm_dx.csv` supports no condition |
| Kim Frailty Index | `med_diagnosis` over the comorbidity baseline | `frailty_kim2018.csv`, Annex 7; diagnosis codes only |
| Year of MM diagnosis | cohort table `MM_DX_DT`, or the first MM claim in the 1L baseline | `DX_DATE_SOURCE` (Q30) |
| Follow-up from diagnosis / from index | diagnosis date, index, enrolment spans, `DEATH_DT`, study end | months, both endpoints inclusive (Q13) |
| Year of 1L / 2L / 3L initiation; SOC by line | LOT output (`LOT_START_DT`, `LOT_BASE_MEDS`) + `soc_regimen_categories.csv` | Annex 2 |
| Key safety events (Table 3) | `med_diagnosis.DIAG` (+ `medical.CONF_ID` and `confinement` for the inpatient-defined ones) | `safety_events.csv` (Q36) |
| All-cause inpatient hospitalisation | `confinement` | `ADMIT_DATE`, `DISCH_DATE`, `CONF_ID`; LOS computed |
| MM-related hospitalisation | `confinement.DIAG1`/`DIAG2`, or `med_diagnosis` with `DIAG_POSITION` 1-2 on a claim carrying the `CONF_ID` | `MM_HOSP_POSITION` (Q27), with `mm_dx.csv` |
| Emergency visits | `medical.RVNU_CD` / `POS` / `PROC_CD` | §6 |
| Secondary malignancy | `med_diagnosis.DIAG`, `FST_DT` | `secondary_malig.csv` (Q35) |
| Thrombocytopenia, anaemia | `med_diagnosis` | diagnosis-defined; `lab` is not read |
| TTNT / TTD / OS / attrition | LOT output + cohort table `DEATH_DT` + study end | `VARIABLES.md` "Time-to-event conventions" |
| SCT and CAR-T | LOT output (the engine reads `med_procedure.PROC`, `medical.PROC_CD`, `BILL_PROC_CD` against `cl_sct_codelist.csv`) | the engine's transplant flags, on `S_SOC` |
| Death | cohort table `DEATH_DT`, from `dod.YMDOD` | month and year only |

## 10. Caveats that change a number

1. **Death is month-precision** - every OS, TTD and follow-up figure carries
   ±15 days, and OS is a headline figure.
2. **The enrolment rollup and the protocol's gap rule** differ by one day at the
   boundary, which is why both builds stitch their own spans.
3. **`YRDOB` is capped at 89** - a mean or median age understates the very old.
4. **Lab coverage is partial** - lab-defined outcomes would not be
   population-representative.
5. **`RACE`/`ETHNICITY`** fold small cells into Other/Unknown and are null or
   `U` on a large share of rows.
6. **Inpatient-administered drugs are invisible to RX** and may be bundled into
   a DRG rather than itemised on MEDICAL, so in-hospital MM therapy can be
   missed.
7. **`NDC` on MEDICAL is frequently `NONE`/`UNK`** - 1.2 bn such rows. Never
   left-pad those into a join key.
8. **Everything is ICD-10** - the study period starts after the October 2015
   transition.
9. **No clinical staging exists** - no ISS/R-ISS, cytogenetics or FISH, ECOG,
   tumour-registry linkage or treatment intent; hence age ≥ 75 as the
   transplant-eligibility proxy.
10. **No date shifting is documented.** De-identification is by encryption of
    identifiers (PATID, PAT_PLANID, CLMID, CONF_ID, FAMILY_ID, provider ids);
    the only deliberate coarsening is `YRDOB` and `YMDOD`.
11. **The quarterly tables are cumulative** - a rerun against a newer quarter
    is a different denominator.

## 11. Code lists

The protocol defines almost every criterion and outcome by reference to a code
list, and puts the lists in Annexes 2, 3 and 7. Code lists are **CSV files on
production**, not warehouse tables, and are not bundled with the code. Each
stage names its directory in its own `CODELIST_DIR`, and every loader records
each file's md5 and row count on the run, so a number can be traced to the file
that produced it.

**`CODELIST_DIR`** blank means this package's own `codelists/`, which holds the
shape of every file it reads with **no codes**: a run pointed there leaves out,
by name, the modules that need a list (or stops if `MODULES` names one). On
production point it at the real directory:

```
CODELIST_DIR=/mnt/code/codelist Rscript build.R
```

A blank code column is not a gap the run papers over: a rate of zero for want
of a code list is indistinguishable downstream from a rate of zero for want of
events, so the loader refuses a file with an unfilled row and names the
concepts on it. The files in `codelists/` are a to-do list the code checks, not
defaults anything could quietly run on.

### The production lists the cohort build and the LOT engine read

Neither build has an embedded fallback: a missing file, an unknown filename,
missing columns or zero data rows stops the run.

| file | read by | required columns | code types | drives |
|---|---|---|---|---|
| `mm_dx.csv` | cohort build | `dx`, `icd_family` | ICD-9-CM / ICD-10-CM diagnosis | I1 |
| `cl_mma_codelist.csv` | cohort build, LOT engine | `CL_CODE_TYPE`, `CL_CODE`, `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR` | `HCPCS`, `CPT`, `NDC` (`NDMM_MMA_CODE_TYPES`) | the 1L index (I3), prior therapy (X1), belantamab (X4); claim → drug for the engine |
| `other_malig.csv` | cohort build | `dx`, `icd_family`, `tumor_group` | ICD-9-CM / ICD-10-CM diagnosis | X2 |
| `pregnancy.csv` | cohort build | `code_type`, `code` | `ICD9DIAG`, `ICD10DIAG`, `ICD9PROC`, `ICD10PROC`, `HCPCS`, `REV` (`NDMM_PREG_CODE_TYPES`) | X3 |
| `clintrial.csv` | cohort build | `code`, `code_type` | the same six (`NDMM_CLINTRIAL_CODE_TYPES`) | a descriptive trial flag, not a criterion |
| `cl_mma_rollup.csv` | LOT engine | `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR`, `MONOMAINTENANCE`, `DUALMAINTENANCEWITH`, `CONDITIONING`, `USED_FOR_OTHER_CANCERS` | - | drug-level attributes; specified as 27 medications, belantamab/BELA/ABCMA to venetoclax/VENE/BLC21 |
| `permissible_subs.csv` | LOT engine | `original_med`, `substitute_med` | - | biosimilar substitution (`../lot/LOT_RULES.md` §4.4) |
| `cl_sct_codelist.csv` | LOT engine | `CL_CODE_TYPE`, `CL_CODE`, `SCT_TYPE` | - | SCT identification and AUTO/ALLO typing |

A code type outside the list a scan names loads cleanly and matches nothing;
the code-type settings exist to stop a rule silently doing nothing. What is on
production, as recorded from the directory (confirm against the files before
quoting):

| production file | what it holds |
|---|---|
| `mm_dx.csv` | header + **8 rows**: `ICD9DIAG` `2030`, `20300`, `20301`, `20302`; `ICD10DIAG` `C900`, `C9000`, `C9001`, `C9002` - the strict families only |
| `clintrial.csv` | header + 17 rows - HCPCS G0276, G0292, G0293, G0294, G2000, G8928, G9057, S9988, S9990, S9991, S9992, S9994, S9996, plus `ICD10DIAG,Z006` and `ICD9DIAG,V707` |
| `pregnancy.csv` | ≥ 5,319 rows; carries ICD10PROC, HCPCS and REV codes 0720, 0721, 0722, 0724, 0729 |
| `other_malig.csv` | 1,643 code rows, 1,618 distinct `tumor_group` - a label per code, not a grouping, which is why the cohort build pairs on the first three ICD characters (`OTHER_CANCER_PAIR_GRAIN=icd3`) |
| `cl_mma_codelist.csv` | includes `HCPCS,C9069,belantamab,ABCMA,BELA`; no steroid abbreviation (Q6) |
| `permissible_subs.csv`, `cl_sct_codelist.csv`, `cl_mma_rollup.csv` | present |
| `mm_therapy.csv` | present, read by no build |

None of the seven study lists (`charlson_quan2011.csv` to
`soc_regimen_categories.csv`, below) is on production.

On `mm_dx.csv`: the join is **equality on the normalised code, not a prefix
match** - `2030` matches a claim coded exactly `203.0` and does not cover
`203.00`, which is why all four codes of each family are listed. The cohort
build's `mm_dx_strict_flg` prefix test on the inpatient arm does nothing on this
file, since every code already satisfies it; it bites only if the file is
widened, which is the broad reading of Q2.

### Matching conventions

- **ICD codes** - both sides normalised with
  `upper(regexp_replace(x,'[^A-Za-z0-9]',''))` and joined on the ICD family as
  well. `icd_family` must be one of `9 / ICD9 / ICD-9 / ICD9DIAG` or
  `10 / ICD10 / ICD-10 / ICD10DIAG`; anything else, or a blank, stops the run. A
  claim whose `ICD_FLAG` names neither family matches nothing and is reported
  (Q24); the cohort build's ceiling `NDMM_ICD_FLAG_MAX_ROWS` is unset by default.
- **NDC** - digits only. Eleven digits as they stand; ten left-padded (the 4-4-2
  layout); any other count gets no key. A ten-digit NDC written 5-3-2 or 5-4-1
  pads to the wrong key, so the cohort build's `check_ndc_shape()` profiles both
  sides every run, stops on a malformed code-list value and reports a
  malformed claim value.
- **HCPCS / CPT / revenue / place of service** - punctuation stripped,
  uppercased, exact match. Code types compare case-insensitively.

### The files this package reads

`R/codelists.R` declares eleven files; a name it does not declare cannot be
loaded.

| file | required columns | matched against | read by | included | codes come from |
|---|---|---|---|---|---|
| `mm_dx.csv` | `dx`, `icd_family` | `MED_DIAGNOSIS.DIAG`, `CONFINEMENT.DIAG1-2` | `comorbidity` (MM adjustment), `hcru` (MM-related hospitalisation), `malignancy` (to refuse a myeloma code), `periods` under `DX_DATE_SOURCE=baseline_first_claim` | header only | production |
| `cl_mma_rollup.csv` | `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR` | - | the `COHORT_INDEX_EXCLUSIONS` check, resolving agent names to abbreviations; unusable, the check is logged unverified | header only | production |
| `cl_mma_codelist.csv` | `CL_CODE_TYPE`, `CL_CODE`, `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR` | - | declared, read by no module | header only | production |
| `cl_sct_codelist.csv` | `CL_CODE_TYPE`, `CL_CODE`, `SCT_TYPE` | - | declared, read by no module | header only | production |
| `charlson_quan2011.csv` | `condition`, `weight`, `code_type`, `code`, `icd_family`; optional `supersedes` | `MED_DIAGNOSIS.DIAG` | `comorbidity` | **Quan's 17 conditions, weights and hierarchy** | Quan et al. 2011 - no annex; authored from the published paper |
| `safety_events.csv` | `condition`, `domain`, `acute_chronic`, `code_type`, `code`, `icd_family`; optional `setting` | `MED_DIAGNOSIS.DIAG`; `setting=inpatient` rows only on claims carrying a `CONF_ID` | `safety` | **all 23 rows**, with domain, the protocol's acute/chronic typing and `setting` | Annex 3 |
| `secondary_malig.csv` | `category`, `subtype`, `code_type`, `code`, `icd_family` | `MED_DIAGNOSIS.DIAG` | `malignancy` | **Table 2's ten categories** and their example subtypes | Annex 3 |
| `comorbid_subgroups.csv` | `concept`, `code_type`, `code`, `icd_family` | `MED_DIAGNOSIS.DIAG` | `comorbidity` with `COMORBID_SUBGROUPS=TRUE` | `neuropathy`, `lung_parenchymal_disease` | Annex 3 |
| `frailty_kim2018.csv` | `variable`, `coefficient`, `code_type`, `code`, `icd_family` | `MED_DIAGNOSIS.DIAG` | `comorbidity` with `FRAILTY=TRUE` | header only | Annex 7 |
| `hcru.csv` | `concept`, `code_type`, `code` | `MEDICAL.RVNU_CD` / `POS` / `PROC_CD` by `code_type` `RVNU` / `POS` / `CPT` | `hcru` | three `ED_VISIT` rows, one per construction | a study decision (Q11) |
| `soc_regimen_categories.csv` | `line_scope`, `soc_category`, `CL_MED_ABBR`, `role` | the agents of `LOT_BASE_MEDS` | `soc` | **§7.2.2's categories**, both line scopes | Annex 2 |

The code column is `code`, except `dx` in `mm_dx.csv`, `CL_CODE` in the two
`cl_*_codelist` files and `CL_MED_ABBR` in `cl_mma_rollup.csv` and
`soc_regimen_categories.csv`. The diagnosis lists join on the normalised code
and the ICD family; their `code_type` is carried but does not select a source.

**Every load checks** that the file is declared, has the required columns and
data rows, has no row with a blank code column (naming the concepts on those
rows), and that every `icd_family` is recognised. **Each module's own check**,
run by the preflight before the connection opens:

- `safety_events.csv` - every condition §7.8.1 names as chronic is typed
  chronic; a value naming both acute and chronic is resolved by §7.8.1's chronic
  list or stops the run (so `toxic_liver_disease` and `hepatic_failure`, typed
  *"Acute or chronic"* and *"Acute/Chronic"* as the protocol types them, stop
  the safety module until typed, Q36); `setting` is `any`, `inpatient` or blank
  (`any`); a condition whose name says hospitalisation must be `inpatient`; one
  domain, type and setting per condition; the suffix ` (hospitalisation)` and
  the name `(any in domain)` are reserved.
- `secondary_malig.csv` - no code that `mm_dx.csv` names as myeloma.
- `soc_regimen_categories.csv` - every `soc_category` is one of §7.2.2's and
  `line_scope` is `1L` or `LATER`; `role = backbone` marks the anti-CD38 backbone
  agent.
- `hcru.csv` - `ED_VISIT` rows for every code type `ED_DEFINITION` asks for.
- `charlson_quan2011.csv` - a `weight` column.

`frailty_kim2018.csv` is checked when the module runs: an `intercept` row, or a
`code_type` other than `ICD9DIAG` / `ICD10DIAG`, stops it, because every row is
matched to a diagnosis code.

`charlson_quan2011.csv`'s weights are Quan's published ones - including **0 for
myocardial infarction** - and `supersedes` carries his hierarchy; without that
column a patient with both liver conditions scores 6 where Quan gives 4.
`hcru.csv` covers emergency visits only: all-cause hospitalisation uses
`CONFINEMENT`, the same inpatient definition as the cohort.

### What is still to be authored

In one message to the study team (Q15; Annex numbers follow the body text -
the contents page calls the code lists Annex 5, so say which you mean, Q20):

| from | what | why it is needed |
|---|---|---|
| **Annex 2** | eligible/expected 1L therapies, later-line-only agents to bar from the 1L index, and the SOC regimen categories for 1L and later lines | I3, `soc_regimen_categories.csv`, every SOC-stratified analysis and the Sankey |
| **Annex 3** | ICD-10-CM lists for every Table 3 condition, the secondary malignancy categories, the subgroup conditions (lung parenchymal disease, neuropathy), and the healthcare-utilisation definitions | `safety_events.csv`, `secondary_malig.csv`, `comorbid_subgroups.csv` |
| **Annex 7** | the Kim CFI variables, their code lists and coefficients - or confirmation that frailty is dropped | `frailty_kim2018.csv` |
| Quan et al. 2011 | ICD-9-CM and ICD-10 codes for the 17 conditions | `charlson_quan2011.csv` |
| a decision | the ED construction (Q11) | `hcru.csv` |

Two production lists may need widening: `mm_dx.csv`, with the broad 203.x /
C90.x codes outside the `.0` family, if the outpatient arm of I1 is meant to use
them (Q2); and `cl_mma_codelist.csv` / `cl_mma_rollup.csv`, which must carry
panobinostat and elotuzumab under their own `CL_MED_ABBR` for the cohort build
to bar them and this package to check it (belantamab is `BELA`,
`NDMM_BELANTAMAB_ABBR`). Annex 2's list may add steroids, which Q6 then decides.

`tests/fixtures/codelists/` carries filled miniatures of all eleven files for
the test suite - dummy codes, not codes to run a study on.
