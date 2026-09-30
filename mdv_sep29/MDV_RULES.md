# The NDMM cohort and lines of therapy, on MDV

The rules the Optum build applies, translated to MDV (Medical Data
Vision, Japanese hospital-based claims) one at a time. Each row says what the
Optum rule is, what this build does on MDV instead, and why. The code is in
`ndmm/` (the cohort) and `lot/engine/` (the lines); `README.md` says how to run
it.

Three sources decide the MDV form of a rule:

- **the Optum rule**, carried in this folder: the cohort's decision register
  (`ndmm/DECISIONS.md`, sections 1 to 12) and the line rules
  (`lot/LOT_RULES.md`). This is the business rule, and it is the default.
- **the MDV ovarian cancer business rules** a colleague wrote against this
  warehouse (`reference/MDV_Ovarian_Cancer_Business_Rules.md`, "the OC
  rules"). They give MDV's table and column names and this team's conventions
  for reading them. Where they add a condition that is about ovarian cancer
  rather than about MDV, the condition is offered here as a setting and its
  effect is counted on every run. It is not applied by default.
- **`lot/PORTING.md`**, "MDV specifically", which names the three places MDV
  meets the LOT engine: drug vocabulary, observation, and day supply.

Anything none of the three settles is marked **(confirm)**. It has a default
and a named setting. The build asks the warehouse for every configured column
by name before anything is written, and profiles the value codes once the MM
records are found (below). No real MDV data has been read in writing this; see "What was
tested".

---

## 1. The MDV tables and columns

Every table, column and code value is a setting (`config.csv`), read in one
file, `R/mdv_source.R`. The cohort and the LOT engine each carry a copy of
that file, and a test holds the two copies identical. An optional column the
delivery does not carry is written `NONE`; a blank setting means the default,
because the settings loader fills a blank variable from `config.csv`.

| MDV table (`clnprw_mdv_all_use.t_<name>_2026q2`) | columns read | named by |
|---|---|---|
| `diseasedata`: one diagnosis on one monthly claim | `patientid`, `datamonth`, `nyugaikbn`, `diseasecode`, `utagaiflg`, `cancerflg`, `fromdate` | the OC rules |
| | an ICD-10 column: `NONE` by default (`MDV_COL_ICD10`) | **(confirm)** |
| `patientdata` | `patientid`, `sex` | the OC rules |
| | birth year / year-month / date: `birthyearmonth` (`MDV_COL_BIRTH`) | **(confirm)** |
| `ff1data`: DPC Form 1 inpatient episodes | `patientid`, `ff1startdate`, `ff1enddate`, `cancerfirstflg`, `chemotherapyflg` | the OC rules |
| | discharge outcome: `NONE` by default (`MDV_COL_FF1_OUTCOME`), death codes `6\|7` | **(confirm)** |
| `m_drug`: drug master | `receiptcode`, `receiptname_eng` | the OC rules |
| `actdata`: acts, dated | `patientid`, `receiptcode`, `actdate` | the OC rules |
| | care setting: `nyugaikbn` (`MDV_COL_ACT_NYUGAIKBN`; `NONE` if not carried) | **(confirm)** |
| | days supplied: `NONE` by default (`MDV_COL_ACT_DAYS`) | **(confirm)** |

| value | default | named by |
|---|---|---|
| `nyugaikbn` inpatient / outpatient | `2` / `1` | the OC rules (see the note on their section 4.2) |
| `utagaiflg` confirmed | `0` | the OC rules |
| `cancerflg` cancer | `1` | the OC rules |
| `cancerfirstflg` first occurrence; `chemotherapyflg` none | `0`; `0` | the OC rules |
| `sex` female / male | `2` / `1` | female by the OC rules; male **(confirm)** |

The tables are read as `t_<name>_<vintage>` with `MDV_VINTAGE=2026q2`, the
suffix the OC rules use. The vintage is always named, never derived from
`STUDY_END`: the study window (to 2026-03-31, the same as the Optum cohort) and
the MDV extract (2026q2) are different quarters, and a blank `MDV_VINTAGE`
takes the default like every other setting.

**How a value is read.** Every code - on the MDV tables and on the code lists
- is trimmed, stripped of punctuation and upper-cased, and a code that leaves
nothing is `NULL`, which joins nothing: a drug-master receipt code of `--`
cannot meet an act whose code is blank, and a blank ICD-10 mapping cannot
meet another. A code list's `icd10` is normalised before it falls back to the
row's own code. A date that is not a calendar date (`20200230`, `00000000`) is
`NULL`, not an error: `to_date()` raises on it under ANSI mode, Databricks
SQL's default, and one malformed record would stop the run.

Two checks guard the source, at two points:

- **The columns exist**, before anything is written. Every configured column
  is looked for with `DESCRIBE`. A missing one stops the run and names the
  table and column (`check_upstream` in the cohort, `check_mdv_source` in LOT).
- **The value codes match**, once the MM diagnosis records and MM therapy acts
  are found - after criteria 1 and 2 are staged, before the 1L index and the
  criteria that follow it. The cohort build counts every value of `nyugaikbn`,
  `utagaiflg` and `cancerflg` and the acts' care setting, and whether
  `datamonth` and `actdate` could be read, into `NDMM_MDV_SOURCE_PROFILE`. If a
  configured code matches no record, or no date could be read, the run stops.
  A wrong code does not fail on its own; it silently matches nothing
  (`check_mdv_values`). An act care-setting value that neither code reads is
  shown as `unrecognized` and recorded as the finding
  `act_setting_unrecognized`; the cohort reads no act's setting, but the LOT
  engine refuses such an oral act rather than size it as outpatient.

These replace the Optum build's NDC-shape and ICD_FLAG checks, which have
nothing to check on MDV: receipt codes are not padded, and there is one ICD
family.

---

## 2. The cohort, criterion by criterion

Same nine criteria, same order, same attrition table (`NDMM_ATTRITION`).

| # | Optum | MDV (this build) | status |
|---|---|---|---|
| 1 | **MM diagnosis.** One inpatient claim with a strict code (C90.0x), or two outpatient claims on different days within 90 days. Any position, inside the study period. Date: the earliest qualifying claim. | A diagnosis record whose `diseasecode` (or ICD-10) is on `mm_dx.csv`. It must be **confirmed** (`utagaiflg = 0`), and by default must be flagged **cancer** (`cancerflg = 1`). It is dated to the **first day of its claim month**. One **inpatient** record (`nyugaikbn = 2`) with a strict C90.0x code, or two **outpatient** records (`nyugaikbn = 1`) in **different claim months at most 3 months apart**. The date is the earlier month. | adapted: the inpatient reading and `cancerflg` are open (section 5) |
| 2 | **Adult.** `year(diagnosis) - YRDOB >= 18`, tested at the earliest date. | Unchanged. YRDOB is the first four digits of the birth column. | birth column (confirm) |
| 3 | **Eligible 1L treatment.** The first claim for a code-list agent (five claim arms) on or after the diagnosis, on or after 2019-01-01. Steroids dropped; belantamab and barred agents cannot set it. | The first **act** for a code-list agent, on or after the diagnosis month, on or after 2019-01-01, and on or before the study end. One source, `actdata`, replaces the five arms: every drug, oral or injected, inpatient or outpatient, is an act. An agent is named by receipt code, or by an English-name pattern over `m_drug` (`'%bortezomib%'`), the way the OC rules find platinum. Steroids dropped, compared trimmed and upper-cased; belantamab cannot set it, and nor can panobinostat and elotuzumab (protocol I3, `NDMM_INDEX_EXCLUDED_ABBRS=PANO\|ELOT`, pinned in the contract). | translated |
| 4 | **12 months continuous enrolment before the index,** gaps of 30 days bridged. | **12 months of MDV records before the index:** the patient's first record at the hospital (any act, diagnosis month or FF1 episode) is on or before `index - 365`. MDV has no enrolment, so what 12 months of enrolment bought on Optum, a year of lookback, is what is asked for. | adapted (section 5) |
| 5 | **Follow-up enrolment,** a no-gap span covering `[index, index + 0]`. | **Observed at follow-up:** the last record is on or after `index + FU_CE_DAYS` (cut at death and the study end), and the patient is **not recorded dead before the index**. At 0 days the index act satisfies it, as enrolment on the index date did on Optum. A 1L start after a recorded death is a contradiction in the data, and the patient fails here rather than having the death moved (section 3). | adapted |
| 6 | **No MM therapy in `[index - 365, index - 1]`,** five arms, steroids not counted. | No MM therapy act in `[index - 365, index - 1]`. Acts are dated to the day, so the window is the Optum window exactly. | translated |
| 7 | **No other cancer in the baseline.** One inpatient claim, or two outpatient claims within 30 days in the same group (three-character ICD category; metastatic codes one group). Codes on `mm_dx.csv` and the plasma-cell labels do not count. | One inpatient record, or two outpatient records in **adjacent claim months**, in the same group. The group is the ICD-10 category the code maps to (`other_malig.csv` carries an `icd10` for each MDV code). Metastatic codes are one group, ICD-10 only. Confirmed diagnoses only, `cancerflg` as in criterion 1. Codes on `mm_dx.csv` (matched by code, or by the ICD-10 code both lists give) and the plasma-cell labels do not count. | adapted: the index month counts as baseline (section 5) |
| 8 | **No pregnancy** diagnosis, procedure or revenue code in the study period. | No confirmed pregnancy diagnosis (`pregnancy.csv`, DISEASECODE / ICD10), and no delivery act (RECEIPTCODE), in the study period. Japanese claims have no revenue codes. | adapted |
| 9 | **No belantamab before the index.** | No belantamab act before the index. | translated |

**The cohort table** keeps the columns LOT reads:

| column | Optum | MDV |
|---|---|---|
| `INDEX_DATE` | the 1L start | the 1L start |
| `MM_DX_DT` | the qualifying claim date | the first day of the qualifying claim month |
| `ENDDATE` | min(death, study end) | min(death, study end) |
| `ENDDATE_CE` | end of the enrolment span covering the index | min(`ENDDATE`, **the last MDV record**) |
| `DEATH_DT` | constructed from `dod` month and year; clamped to the index when earlier | the discharge date of an FF1 episode whose outcome is a death code, **as recorded, never moved**. Only **in-hospital deaths at a contributing hospital** are seen; nobody dies while the outcome column is `NONE` |
| `GDR_CD` | M / F / U | `sex` read through `MDV_SEX_MALE` / `_FEMALE` into M / F / U |

**The descriptive clinical-trial flag** reads confirmed diagnoses and acts on
`clintrial.csv`. It says even less on MDV than on Optum: in Japan the sponsor
pays for an investigational drug, so it does not reach the claim at all.

**Review tables.** The Optum build's review tables are kept (`NDMM_INDEX_AGENTS`,
`NDMM_FU_CE_COUNTS`, `NDMM_PREG_WINDOW_COUNTS`, `NDMM_OTHER_MALIG_*`,
`NDMM_MM_ADJACENT_*`, `NDMM_BELANTAMAB_RECONCILE`). Four are new:

- `NDMM_MM_DX_RULES`: criterion 1 counted under each reading. As configured;
  inpatient by `nyugaikbn` alone (the Optum rule); inside an FF1 episode; FF1
  first cancer with chemotherapy (the OC inpatient rule); outpatient months
  within 30 days of MM therapy (the OC outpatient rule); suspected diagnoses
  included; `cancerflg` required or not.
- `NDMM_MMA_RECEIPTS`: every receipt code the drug code list resolved to, with
  its English name and the row that brought it in. Read it before believing a
  count, above all where a NAME_ENG pattern did the finding.
- `NDMM_MDV_SOURCE_PROFILE`: the value-code profile above.
- `NDMM_DEATH_CONFLICTS`: every patient with an MDV act after their recorded
  death, with the death date as recorded, the first and last such act, how
  many were MM therapy, and whether the 1L start itself fell after the death
  (`DEATH_BEFORE_INDEX`: that patient fails criterion 5). A conflict also goes
  on the run's `FINDINGS` as `death_conflicts`.

---

## 3. What is new on MDV and not in the Optum build

| rule | why |
|---|---|
| Only **confirmed** diagnoses count, in every diagnosis rule (MM, other cancer, pregnancy, trial, SCT) | Japanese claims carry suspected diagnoses (疑い病名) entered to justify a test. The OC rules' base population is `utagaiflg = 0`. |
| MM and other-cancer diagnoses must carry **`cancerflg`** (default on) | The OC rules' base population is `cancerflg = 1`. A myeloma code without it is a coding slip or a record MDV itself did not class as cancer. Priced in `NDMM_MM_DX_RULES`. |
| A diagnosis is dated to the **first day of its claim month** | MDV dates a diagnosis only to its claim month. The OC rules use `diagnosis_date = first calendar day of datamonth`. |
| "Different days within N days" becomes **different claim months at most M months apart** (90 days → 3 months; 30 days → adjacent months) | Month-level dates cannot say "different days". Counted in calendar months, not `days / 30.44`. The OC rules' `gap_months = (datamonth - previous) / 30.44 >= 1` reads February 1 to March 1 (28 days, 0.92) as less than a month apart, so it would reject two consecutive months. |
| The patient key is **the hospital's** | MDV issues one ID per patient per hospital. A patient treated at two contributing hospitals is two patients, each observed at one. |
| A death is kept **as recorded**, and with two death-coded discharges the **earliest** is the death; a 1L start after it fails criterion 5, and every record after a death - an act, or a second death date - is listed (`NDMM_DEATH_CONFLICTS`) | The FF1 discharge date is exact. The Optum build clamped a death before the index to the index, which on MDV publishes a date no record carries and keeps a patient whose treatment contradicts it. Taking the latest of two death dates let the later one hide an act after the first. |
| Panobinostat and elotuzumab are barred from the 1L index **in the cohort's contract** (`PANO\|ELOT`) | On Optum the study package refuses a cohort built without the bar. Nothing reads the MDV cohort yet, so the cohort build holds itself to protocol I3. |

---

## 4. The lines of therapy

**Unchanged:** every line rule in `lot/LOT_RULES.md`. That covers the MAP
episode state machine, the induction windows, the run-out chain, the end
cascade, the next-line triggers, the SCT clustering and tandem rule, CAR-T,
the melphalan and fold-in rules, and the line criteria (belantamab in any
line removes the patient). PORTING.md calls this the line-assembly half. It
reads five tables and the settings, and nothing about the source.

**Rebuilt for MDV:** the extraction half, split at the seam PORTING.md
describes.

| piece | Optum | MDV |
|---|---|---|
| drug code list | NDC-11 and HCPCS, four claim arms | `RECEIPTCODE` rows and `NAME_ENG` patterns, resolved once to receipt codes (`MMA_RECEIPTS`); one act table. New column **`CL_ROUTE`**: `ORAL` or `INJ` |
| day supply | a pharmacy fill carries `DAYS_SUP` (28 if missing); a medical administration covers 28 days | **INJ**: the act covers `MEDICAL_DAY_SUPPLY` (28) days, like an Optum medical claim. **ORAL**: the act's own days supplied where the delivery has the column; otherwise 1 day for an inpatient act (DPC records inpatient drugs day by day) and `ORAL_DAYS_DEFAULT` (28) for an outpatient prescription. ORAL supply accumulates the way Optum pharmacy fills do |
| transplant / CAR-T | HCPCS/CPT, ICD procedure and diagnosis codes | `cl_sct_codelist.csv` with `RECEIPTCODE` (transplant procedures such as K922, as receipt codes, or a CAR-T product), `NAME_ENG` (a CAR-T product by name), and `DISEASECODE` / `ICD10` (confirmed diagnoses, month-dated) |
| observation | `OBS_END_DT = ENDDATE` (`CENSOR_AT_DISENROLLMENT=FALSE`) | **`OBS_END_DT = ENDDATE_CE`, the last MDV record** (`CENSOR_AT_DISENROLLMENT=TRUE`, pinned). A patient who stops attending cannot be told from one who stopped treatment. Observed to the study end, every loss to follow-up would read as a discontinuation |
| checks | NDC shape on the code list and the claims | receipt codes nine digits (waivable `receipt_shape`); a NAME_ENG pattern finding nothing (waivable `unresolved_names`, e.g. an agent not sold in Japan); `CL_ROUTE` not ORAL/INJ (fatal `route`); one code with two routes (fatal `multi_route`); one receipt code naming two drugs (fatal `code_to_med`) |

**Settings, in PORTING.md's three groups:**

- *Copied as they are* (the myeloma rules): `INDUCTION_WINDOW_DAYS` 60,
  `INDUCTION_WINDOW_DAYS_LOT_N` 30, `CART_CONSOLIDATION_DAYS` 45,
  `SCT_TANDEM_DAYS` 180, `ALLO_LOT_SPAN`, `APPLY_MELP_RULE`, the melphalan
  thresholds, `APPLY_MAP_FOLDIN`, `APPLY_OWN_RETURN_FOLD`,
  `APPLY_CART_INDUCTION_RULE`, `APPLY_NO_BELANTAMAB`, `MAX_LOT`.
- *Decided for MDV*, and still the study team's to confirm:
  `MEDICAL_DAY_SUPPLY` 28 and `ORAL_DAYS_DEFAULT` 28 (run them as
  sensitivity builds, section 5); `MAP_DISCON_GAP_DAYS` 90 and
  `LOT_DISCON_CONFIRM_DAYS` 90 (kept); `SCT_AUTO_WINDOW_DAYS` 13 and
  `SCT_AUTO_GAP_DAYS` 60 (kept); `CENSOR_AT_DISENROLLMENT` TRUE (above).
- *Rewritten*: `MDV_SCHEMA`, `MDV_VINTAGE`, the `MDV_TBL_*` / `MDV_COL_*` /
  value settings, and `CODELIST_DIR` (`/mnt/code/codelist_mdv`: MDV code
  lists, not the Optum ones).

The rule settings above, and the source's identity (`MDV_SCHEMA`,
`MDV_VINTAGE`, `CODELIST_DIR`), are pinned in `CONTRACT` in
`lot/engine/R/build_lot.R`, as on Optum. The table, column and value mappings
(`MDV_TBL_*`, `MDV_COL_*`, the value codes) are not pinned: they describe the
delivery rather than the study. Each is held to identifier shape and every
column is asked for by name from the warehouse, before anything is written;
the value codes are profiled once the records are found (section 1). All are
recorded on every run as `MDV_SOURCE`, in `NDMM_RUN_METADATA`
and `LOT_RUN_METADATA` alike, so two extractions that differ only in a column
name are told apart.

---

## 5. Decisions still open

Each has a default so the build runs. Each is either priced on every run or
named here so it is decided on purpose.

1. **What makes an inpatient MM diagnosis.** `NDMM_MDV_IP_RULE`: `none`
   (`nyugaikbn` alone, the Optum rule, default), `ff1` (and `fromdate` inside
   an FF1 episode, the OC alignment), `ff1_chemo` (and that episode is a first
   cancer given chemotherapy, the whole OC inpatient rule). Priced in
   `NDMM_MM_DX_RULES`. `ff1_chemo` also fits "newly diagnosed" well: DPC's
   first-occurrence flag says so directly.
2. **Whether `cancerflg` is required** (`NDMM_MDV_REQUIRE_CANCERFLG`, default
   TRUE). Priced.
3. **The OC outpatient treatment link** (`|datamonth - actdate| <= 30` against
   MM therapy). Priced, not applied: criterion 3 already asks for treatment on
   or after the diagnosis.
4. **Month dating in the baseline windows.** A diagnosis dated to the first of
   its month means the index month's diagnoses fall inside the 12-month
   baseline, even those recorded after the index day, and the month holding
   `index - 365` falls outside. The alternative is to use whole months before
   the index month. That is a small change in `04_other_malig.R` if chosen.
5. **The lookback reading of criterion 4.** The first record is on or before
   `index - 365`. It does not ask for records throughout the year, and a
   patient treated elsewhere before arriving is invisible, which no MDV rule
   can fix.
6. **Death.** Only in-hospital deaths (FF1 discharge outcome) are seen, and
   the outcome column's name is (confirm). With `CENSOR_AT_DISENROLLMENT=TRUE`
   most follow-up ends at the last record anyway. A 1L start after a recorded
   death fails criterion 5 (the default), and with two death-coded
   discharges the earliest is the death; the alternatives - dropping the
   death, or the contradicting acts - are the study team's, and
   `NDMM_DEATH_CONFLICTS` counts the patients each would affect, with every
   death date.
7. **Day supply.** PORTING.md: "Run the whole build at two or three values, as
   sensitivity builds, before choosing." Suggested: `MEDICAL_DAY_SUPPLY` 21,
   28, 35, each as its own prefix with `LOT_CONTRACT_OVERRIDE=TRUE`. Whether
   `actdata` carries days supplied (`MDV_COL_ACT_DAYS`) decides how much the
   oral side rests on `ORAL_DAYS_DEFAULT`.
8. **Censoring at the last record** (`CENSOR_AT_DISENROLLMENT=TRUE`) rather
   than at the study end.
9. **Japanese practice.** PORTING.md: "the regimen vocabulary, the transplant
   rate and the relevance of the melphalan rule (4.7) should be re-examined
   with a clinician." The rules are the Optum study's, unchanged.
10. **The 2L and 3L cohorts** are not ported. The Optum build derives them from
    the lines. On MDV their enrolment windows would become lookback and
    follow-up windows of the same kind as criteria 4 and 5.
11. **The AUTO date at the tandem mark** (`lot/LOT_RULES.md` §6.1). A grouping
    window with any claim within `SCT_AUTO_WINDOW_DAYS` of the mark is dated
    at its claim closest to the mark, on either side of it, as the code does
    and its worked example (07NOV rather than 20NOV) requires. The rules text
    said "straddles", which would date a window wholly past the mark at its
    last claim instead. Past the mark the pair is excess either way; only the
    date the line ends moves. Vignettes `auto_seam_straddle`,
    `auto_seam_after` and `auto_seam_far`, marked to confirm; run in Spark by
    `tests/test_spark_sql.R`.
12. **Which ICD-10.** MDV carries Japan's ICD-10 (four characters; myeloma is
    C90.0). The inherited Optum lists are US ICD-10-CM, whose remission fifth
    characters (C90.00, C90.01, C90.02) and C7B do not exist in Japan's
    classification. `icd10` mappings should be written in Japan's codes, and
    the MDV disease code crosswalk validated against MDV's dictionary
    (`codelists/README.md`, "Which ICD-10").

**Before the first run, confirm against the MDV data dictionary:** the
birth-year column; the FF1 discharge-outcome column and its death codes;
whether `diseasedata` has an ICD-10 column; whether `actdata` carries the care
setting and days supplied; the male `sex` code; and whether `actdata` carries
procedures (transplants, deliveries) as well as drugs. The OC rules describe
it as "drug administration/claim dates". Five of these are named in
`R/mdv_source.R` as (confirm). None was found in any other repository this
account can reach (`reference/README.md`).

---

## 5a. Beyond a translation: Japan, and what MDV holds that Optum does not

This build translates the Optum rules faithfully, so an MDV cohort can sit
beside the Optum one. Two things argue against stopping there. **Finding the
right patients works differently in Japan**, so a rule that is sound on US
claims can admit the wrong patients here or miss the right ones. And **MDV
carries clinical detail that Optum claims do not**, which could confirm a
diagnosis, or date a progression, where claims can only infer one.

That makes a choice the study team has to take, and it is not a coding one:
**comparability** (the Optum rules, knowingly imperfect in Japan), **validity
in Japan** (rules rewritten for Japanese practice and MDV's data), or both - the
translation as the primary definition and a Japan-adapted one priced beside it,
the way `NDMM_MM_DX_RULES` prices the readings of criterion 1 now. None of what
follows is built.

### Identifying the right patients

| the Optum rule assumes | in Japan, on MDV | what could be done |
|---|---|---|
| A confirmed diagnosis code means the disease | Japanese claims carry **reimbursement diagnoses** (保険病名): a disease name recorded so a test or a drug is paid for, not only a suspected one. `utagaiflg` catches the suspected; a myeloma name recorded to justify a myeloma drug or test is confirmed and still wrong. | Ask for more than the code: the treatment link the OC rules use (priced now, not applied), a diagnostic work-up around the diagnosis (below), or laboratory evidence. |
| The lookback sees earlier treatment | The payer follows a US member from provider to provider. MDV sees one hospital, under that hospital's patient key. Patients are commonly referred to a hospital's haematology department from clinics and other hospitals, and treatment given before the referral is invisible. Criterion 4 proves only that **this hospital** saw them a year before. | Measure how many are first seen shortly before the index; require the MM diagnosis to be first recorded at this hospital close to the 1L start; use DPC Form 1's first-occurrence flag (`cancerfirstflg`, which the OC inpatient rule reads); laboratory evidence at diagnosis. |
| The regimen universe and its dates | Approval dates and first-line practice differ between the US and Japan, and so do brand, generic and biosimilar names. | A clinician's review of the drug list, the barred agents and `LOT1_FROM` against Japanese approvals (PORTING says so too); read `NDMM_INDEX_AGENTS` and `unresolved_names` after the first run. |
| US plausibility bands | The LOT face-validity bands (transplant rate, line lengths) are US-derived; myeloma is rarer in Japan and the transplant rate and regimens differ. | Japanese benchmarks for the bands and for the line distribution (PORTING's last section). |
| Death is observed | Only in-hospital deaths at a contributing hospital (section 5, item 6). | Already handled as censoring at the last record; state it wherever survival is read. |

### What MDV holds that Optum does not

MDV is built from hospital systems, not only from bills. Which of these a
given delivery carries has to come from MDV's data dictionary. The OC rules
name none of them, and no repository this account can reach documents them.
The account's other repositories do show how the house defines myeloma from
EHR data and handles lab tables. `reference/DATASET_STRUCTURE_OTHER_REPOS.md`
sets that beside MDV.

- **Laboratory results**, where the delivery includes them (MDV holds them for
  part of its hospitals): M-protein, serum free light chains, calcium,
  creatinine, haemoglobin, beta-2 microglobulin, albumin, LDH. They could
  confirm a myeloma diagnosis against reimbursement diagnoses; separate active
  myeloma from smouldering myeloma and MGUS (CRAB and SLiM features), which
  the plasma-cell overrides now do by label; give an ISS or R-ISS stage at the
  index, which Optum cannot; and date progression from M-protein, so a line
  could end at an IMWG-style progression rather than at a gap in treatment.
- **Laboratory orders** as billed acts. Even without results, a protein
  electrophoresis, immunofixation, free light chain test or bone-marrow
  examination is a procedure with a receipt code, and a work-up around the
  diagnosis is evidence of a diagnosis made rather than a name recorded. This
  needs only `actdata` and a code list, provided `actdata` carries procedures
  (section 5, "confirm").
- **Inpatient care by the day.** DPC records inpatient drugs and procedures
  day by day, and where `actdata` carries a quantity, a dose: high-dose
  melphalan conditioning could confirm an autologous transplant, and dose per
  body-surface area needs only DPC Form 1's height and weight.
- **DPC Form 1 clinical fields**: height, weight, ADL, the first-occurrence
  flag. Its cancer staging covers a few major solid cancers, not myeloma.

**What each needs.**

- **The laboratory uses** need, from the dictionary: the lab table's name, its
  test coding (Japan's JLAC10, most likely), its units, a sample date and a
  result date, and which hospitals report results. Then one scan of every
  test, name and unit over the cohort, before any code list is written
  (`reference/DATASET_STRUCTURE_OTHER_REPOS.md`, sections 2 and 3, gives the
  query and the traps). The traps are serum against urine, a concentration
  against a percentage, and Japanese test names that no English pattern
  matches.
- **ISS** needs two results, beta-2 microglobulin and albumin, and looks
  feasible. **R-ISS** also needs FISH, a report rather than a value, and does
  not.
- **The work-up and dose uses** need `actdata`'s procedure and quantity columns
  confirmed, and a code list.

The cheapest first step is the work-up. Priced as another reading in
`NDMM_MM_DX_RULES`, it changes nothing in the cohort and shows how many myeloma
diagnoses have no work-up behind them.

**A lab-based definition changes what the comparison measures.** The Optum
build reads Clinformatics, which is claims only. Optum Market Clarity, which
links claims to EHR data, has lab results. Set a lab-confirmed MDV cohort
beside a Clinformatics one and the definition and the country differ at once.
A lab-based definition compared across the two countries would need Market
Clarity on the US side.

## 6. What the OC rules gave, and what was left

| OC rule | here |
|---|---|
| Tables `clnprw_mdv_all_use.t_*_2026q2` | taken |
| `utagaiflg = 0` | taken, in every diagnosis rule |
| `cancerflg = 1` | taken as the default for MM and other cancer; priced |
| `sex = 2` | not taken: an ovarian cancer rule |
| `diagnosis_date` = first day of `datamonth` | taken |
| `nyugaikbn` 1 outpatient, 2 inpatient | taken. Their section 4.2 contradicts its own table ("inpatient (1) and outpatient (2)"); every later rule uses 2 for inpatient, so the table is taken as right |
| FF1 linkage: `fromdate` within `ff1startdate`..`ff1enddate` | offered: `NDMM_MDV_IP_RULE=ff1` |
| `cancerfirstflg = 0`, `chemotherapyflg != 0` | offered: `NDMM_MDV_IP_RULE=ff1_chemo` |
| Platinum by `receiptname_eng LIKE '%platin%'`, linked to acts by `receiptcode` | taken as a mechanism: the `NAME_ENG` code type |
| `\|datamonth - actdate\| <= 30` treatment link | priced against MM therapy, not applied |
| Distinct claim months, `n_claims >= 2` | taken |
| `gap_months = days / 30.44 >= 1` | adapted to calendar months (section 3) |
| Results by `first_yr` | not needed: the study reports by its own periods |

---

## 7. What was tested

No real MDV data was read. The suites run the builds' own emitted SQL,
transpiled from Spark to DuckDB with sqlglot, against 26 synthetic patients
with invented codes (`tests/fixture_mdv.R`), and one suite runs the SQL where
the two engines differ in Spark itself. Each patient exists to exercise one
rule. Each fix below was first shown to fail on the code before it.

| suite | what it runs | result |
|---|---|---|
| `ndmm/tests/test_mdv_build.R` | the whole cohort build, unchanged, against the synthetic tables. It checks every attrition count, the eleven cohort members and their index and diagnosis dates, death, `ENDDATE_CE`, criterion 1 under each reading, the resolved code list, the belantamab list, the trial flag, the metadata; the bar on panobinostat; a death kept as recorded, the act after it listed and the patient out at criterion 5; dexamethasone (spelled `' DEX '`) neither indexing nor excluding; then the OC inpatient rule; a 90-day follow-up window capped at death, in criterion 5 and the final check alike; an act table with no care-setting column, refused at its default and built when declared `NONE`; act care-setting values neither code reads, shown as unrecognized and recorded as a finding; blank or punctuation-only receipt codes resolving to nothing; a second death-coded discharge listed rather than read as the death; blank ICD-10 mappings on an MM and an other-cancer row, which neither drop a myeloma patient nor pass breast cancer off as myeloma; panobinostat reported barred when its pattern finds no drug; and that a wrong value code and a wrong column name each stop the run | 86 / 86 |
| `lot/engine/tests/test_mdv_extract.R` | the cohort build, then the LOT engine's preflight, code lists, drug extraction and transplant extraction on that cohort. It checks INJ/ORAL supply, inpatient days, the default without a days column, the name-pattern drugs, CAR-T by name, and the fatal route check; that waiving `uncoded_meds` leaves `unresolved_names` standing; that a misspelt SCT name pattern stops the build unless waived; that a sensitivity build under its own prefix needs `COHORT_PREFIX`; that a blank-coded act makes neither a melphalan act nor a CAR-T; and that an oral act whose care setting neither code reads stops the run, until the column is declared `NONE` | 34 / 34 |
| `ndmm/tests/test_runner.R` | the Optum cohort runner suite, carried over, with its Optum-only tests replaced by MDV ones; how an optional column is declared `NONE`; and a blank `MDV_VINTAGE` through the real loader | 415 / 415 |
| `lot/engine/tests/test_runner.R`, `test_line_criteria.R` | the Optum LOT runner and criteria suites, the same way; that the run records its MDV mappings and checks its MDV columns before writing; and a blank `MDV_VINTAGE` through the real loader | 530 / 530, 59 / 59 |
| `lot/validation/tests/test_vignettes.R` | the rule vignettes, carried over unchanged: every setting a case derives from exists in the MDV engine's config, the boundary pairs straddle it, every source line a case quotes is still in this folder's engine, and `lot/LOT_RULES.md` and the catalogue cite each other | 38 / 38 |
| `tests/test_spark_sql.R` | the builds' own SQL in local Spark 4.0 with ANSI mode on, no translation: a control showing plain `to_date()` raises there; the date helpers returning `NULL` for `20200230`, `00000000`, month 13; blank code keys as `NULL` that never join; and the engine's AUTO clustering statement (Spark `aggregate()`) on the tandem-mark cases, the review's `[0, 181, 190]` trace among them | 16 / 16 |

`tests/run_all.R` runs all seven. The Spark suite needs `pyspark` and a Java
runtime (`SPARK_PYTHON` names the python that has pyspark).

**Not executed by any suite here:** the LOT line assembly as a whole - the
MAP state machine and everything after it. The MAP uses Spark `aggregate()`
with a finish lambda that DuckDB cannot run, and only the AUTO clustering
statement is run in Spark so far (`tests/test_spark_sql.R`). That code is the
Optum engine's, unchanged (`lot/README.md` lists the files that did change);
the suites here check its settings, its declared outputs and the rules it
cites, not the lines it returns. The next step is one small cohort-to-lines
fixture run end to end in Spark; until then its first full execution on MDV
output is the first warehouse run.

Before any number is used, `lot/PORTING.md`'s last section applies to this port too.
It needs its own planted cases on real data, its own face-validity bands, and
a reconciliation against published Japanese line-of-therapy distributions.
Until someone signs it off, this build is a deviation from the study.
