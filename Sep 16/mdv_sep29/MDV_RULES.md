# The Sep 16 NDMM cohort and lines of therapy, on MDV

The rules the Sep 16 build applies to Optum, translated to MDV (Medical Data
Vision, Japanese hospital-based claims) one at a time. Each row says what the
Optum rule is, what this build does on MDV instead, and why. The code is in
`ndmm/` (the cohort) and `lot/engine/` (the lines); `README.md` says how to run
it.

Three sources decide the MDV form of a rule:

- **the Sep 16 Optum rule** (`../ndmm/README.md`, `../ndmm/DECISIONS.md`,
  `../lot/LOT_RULES.md`). This is the business rule, and it is the default.
- **the MDV ovarian cancer business rules** a colleague wrote against this
  warehouse (`reference/MDV_Ovarian_Cancer_Business_Rules.md`, "the OC
  rules"). They give MDV's table and column names and this team's conventions
  for reading them. Where they add a condition that is about ovarian cancer
  rather than about MDV, the condition is offered here as a setting and its
  effect is counted on every run. It is not applied by default.
- **`../lot/PORTING.md`**, "MDV specifically", which names the three places MDV
  meets the LOT engine: drug vocabulary, observation, and day supply.

Anything none of the three settles is marked **(confirm)**. It has a default
and a named setting, and the build checks it against the warehouse before it
reads a row. No real MDV data has been read in writing this; see "What was
tested".

---

## 1. The MDV tables and columns

Every table, column and code value is a setting (`config.csv`), read in one
file, `R/mdv_source.R`. The cohort and the LOT engine each carry a copy of
that file, and a test holds the two copies identical.

| MDV table (`clnprw_mdv_all_use.t_<name>_2026q2`) | columns read | named by |
|---|---|---|
| `diseasedata`: one diagnosis on one monthly claim | `patientid`, `datamonth`, `nyugaikbn`, `diseasecode`, `utagaiflg`, `cancerflg`, `fromdate` | the OC rules |
| | an ICD-10 column: blank by default (`MDV_COL_ICD10`) | **(confirm)** |
| `patientdata` | `patientid`, `sex` | the OC rules |
| | birth year / year-month / date: `birthyearmonth` (`MDV_COL_BIRTH`) | **(confirm)** |
| `ff1data`: DPC Form 1 inpatient episodes | `patientid`, `ff1startdate`, `ff1enddate`, `cancerfirstflg`, `chemotherapyflg` | the OC rules |
| | discharge outcome: blank by default (`MDV_COL_FF1_OUTCOME`), death codes `6\|7` | **(confirm)** |
| `m_drug`: drug master | `receiptcode`, `receiptname_eng` | the OC rules |
| `actdata`: acts, dated | `patientid`, `receiptcode`, `actdate` | the OC rules |
| | care setting: `nyugaikbn` (`MDV_COL_ACT_NYUGAIKBN`) | **(confirm)** |
| | days supplied: blank by default (`MDV_COL_ACT_DAYS`) | **(confirm)** |

| value | default | named by |
|---|---|---|
| `nyugaikbn` inpatient / outpatient | `2` / `1` | the OC rules (see the note on their section 4.2) |
| `utagaiflg` confirmed | `0` | the OC rules |
| `cancerflg` cancer | `1` | the OC rules |
| `cancerfirstflg` first occurrence; `chemotherapyflg` none | `0`; `0` | the OC rules |
| `sex` female / male | `2` / `1` | female by the OC rules; male **(confirm)** |

The tables are read as `t_<name>_<vintage>` with `MDV_VINTAGE=2026q2`, the
suffix the OC rules use. The vintage is a setting of its own rather than being
derived from `STUDY_END`, because the study window (to 2026-03-31, the same as
the Optum cohort) and the MDV extract (2026q2) are different quarters.

Two checks run before any rule reads a row:

- **The columns exist.** Every configured column is looked for with
  `DESCRIBE`. A missing one stops the run and names the table and column
  (`check_upstream` in the cohort, `check_mdv_source` in LOT).
- **The value codes match.** On the MM diagnosis records and the MM therapy
  acts, the cohort build counts every value of `nyugaikbn`, `utagaiflg` and
  `cancerflg`, and whether `datamonth` and `actdate` could be read. It writes
  the counts to `NDMM_MDV_SOURCE_PROFILE`. If a configured code matches no
  record, or no date could be read, the run stops. A wrong code does not fail
  on its own; it silently matches nothing (`check_mdv_values`).

These replace the Optum build's NDC-shape and ICD_FLAG checks, which have
nothing to check on MDV: receipt codes are not padded, and there is one ICD
family.

---

## 2. The cohort, criterion by criterion

Same nine criteria, same order, same attrition table (`NDMM_ATTRITION`).

| # | Optum (Sep 16) | MDV (this build) | status |
|---|---|---|---|
| 1 | **MM diagnosis.** One inpatient claim with a strict code (C90.0x), or two outpatient claims on different days within 90 days. Any position, inside the study period. Date: the earliest qualifying claim. | A diagnosis record whose `diseasecode` (or ICD-10) is on `mm_dx.csv`. It must be **confirmed** (`utagaiflg = 0`), and by default must be flagged **cancer** (`cancerflg = 1`). It is dated to the **first day of its claim month**. One **inpatient** record (`nyugaikbn = 2`) with a strict C90.0x code, or two **outpatient** records (`nyugaikbn = 1`) in **different claim months at most 3 months apart**. The date is the earlier month. | adapted: the inpatient reading and `cancerflg` are open (section 5) |
| 2 | **Adult.** `year(diagnosis) - YRDOB >= 18`, tested at the earliest date. | Unchanged. YRDOB is the first four digits of the birth column. | birth column (confirm) |
| 3 | **Eligible 1L treatment.** The first claim for a code-list agent (five claim arms) on or after the diagnosis, on or after 2019-01-01. Steroids dropped; belantamab and barred agents cannot set it. | The first **act** for a code-list agent, on or after the diagnosis month, on or after 2019-01-01, and on or before the study end. One source, `actdata`, replaces the five arms: every drug, oral or injected, inpatient or outpatient, is an act. An agent is named by receipt code, or by an English-name pattern over `m_drug` (`'%bortezomib%'`), the way the OC rules find platinum. Steroids dropped; belantamab and barred agents cannot set it. | translated |
| 4 | **12 months continuous enrolment before the index,** gaps of 30 days bridged. | **12 months of MDV records before the index:** the patient's first record at the hospital (any act, diagnosis month or FF1 episode) is on or before `index - 365`. MDV has no enrolment, so what 12 months of enrolment bought on Optum, a year of lookback, is what is asked for. | adapted (section 5) |
| 5 | **Follow-up enrolment,** a no-gap span covering `[index, index + 0]`. | **Observed at follow-up:** the last record is on or after `index + FU_CE_DAYS` (cut at death and the study end). At 0 days the index act satisfies it, as enrolment on the index date did on Optum. | adapted |
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
| `DEATH_DT` | constructed from `dod` month and year | the discharge date of an FF1 episode whose outcome is a death code. Only **in-hospital deaths at a contributing hospital** are seen; nobody dies while the outcome column is blank |
| `GDR_CD` | M / F / U | `sex` read through `MDV_SEX_MALE` / `_FEMALE` into M / F / U |

**The descriptive clinical-trial flag** reads confirmed diagnoses and acts on
`clintrial.csv`. It says even less on MDV than on Optum: in Japan the sponsor
pays for an investigational drug, so it does not reach the claim at all.

**Review tables.** The Optum build's review tables are kept (`NDMM_INDEX_AGENTS`,
`NDMM_FU_CE_COUNTS`, `NDMM_PREG_WINDOW_COUNTS`, `NDMM_OTHER_MALIG_*`,
`NDMM_MM_ADJACENT_*`, `NDMM_BELANTAMAB_RECONCILE`). Three are new:

- `NDMM_MM_DX_RULES`: criterion 1 counted under each reading. As configured;
  inpatient by `nyugaikbn` alone (the Optum rule); inside an FF1 episode; FF1
  first cancer with chemotherapy (the OC inpatient rule); outpatient months
  within 30 days of MM therapy (the OC outpatient rule); suspected diagnoses
  included; `cancerflg` required or not.
- `NDMM_MMA_RECEIPTS`: every receipt code the drug code list resolved to, with
  its English name and the row that brought it in. Read it before believing a
  count, above all where a NAME_ENG pattern did the finding.
- `NDMM_MDV_SOURCE_PROFILE`: the value-code profile above.

---

## 3. What is new on MDV and not in the Optum build

| rule | why |
|---|---|
| Only **confirmed** diagnoses count, in every diagnosis rule (MM, other cancer, pregnancy, trial, SCT) | Japanese claims carry suspected diagnoses (疑い病名) entered to justify a test. The OC rules' base population is `utagaiflg = 0`. |
| MM and other-cancer diagnoses must carry **`cancerflg`** (default on) | The OC rules' base population is `cancerflg = 1`. A myeloma code without it is a coding slip or a record MDV itself did not class as cancer. Priced in `NDMM_MM_DX_RULES`. |
| A diagnosis is dated to the **first day of its claim month** | MDV dates a diagnosis only to its claim month. The OC rules use `diagnosis_date = first calendar day of datamonth`. |
| "Different days within N days" becomes **different claim months at most M months apart** (90 days → 3 months; 30 days → adjacent months) | Month-level dates cannot say "different days". Counted in calendar months, not `days / 30.44`. The OC rules' `gap_months = (datamonth - previous) / 30.44 >= 1` reads February 1 to March 1 (28 days, 0.92) as less than a month apart, so it would reject two consecutive months. |
| The patient key is **the hospital's** | MDV issues one ID per patient per hospital. A patient treated at two contributing hospitals is two patients, each observed at one. |

---

## 4. The lines of therapy

**Unchanged:** every line rule in `../lot/LOT_RULES.md`. That covers the MAP
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

All of these are pinned in `CONTRACT` in `lot/engine/R/build_lot.R`, as on
Optum.

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
   most follow-up ends at the last record anyway.
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
10. **The 2L and 3L cohorts** (`../ndmm/build_subsequent_cohorts.R`) are not
    ported. On MDV their enrolment windows would become lookback and
    follow-up windows of the same kind as criteria 4 and 5.

**Before the first run, confirm against the MDV data dictionary:** the
birth-year column; the FF1 discharge-outcome column and its death codes;
whether `diseasedata` has an ICD-10 column; whether `actdata` carries the care
setting and days supplied; the male `sex` code; and whether `actdata` carries
procedures (transplants, deliveries) as well as drugs. The OC rules describe
it as "drug administration/claim dates". Five of these are named in
`R/mdv_source.R` as (confirm). None was found in any other repository this
account can reach (`reference/README.md`).

---

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
transpiled from Spark to DuckDB with sqlglot, against 23 synthetic patients
with invented codes (`tests/fixture_mdv.R`). Each patient exists to exercise
one rule.

| suite | what it runs | result |
|---|---|---|
| `ndmm/tests/test_mdv_build.R` | the whole cohort build, unchanged, against the synthetic tables. It checks every attrition count, the ten cohort members and their index and diagnosis dates, death, `ENDDATE_CE`, criterion 1 under each reading, the resolved code list, the belantamab list, the trial flag, the metadata; then the OC inpatient rule; and that a wrong value code and a wrong column name each stop the run | 57 / 57 |
| `lot/engine/tests/test_mdv_extract.R` | the cohort build, then the LOT engine's preflight, code lists, drug extraction and transplant extraction on that cohort. It checks INJ/ORAL supply, inpatient days, the default without a days column, the name-pattern drugs, CAR-T by name, and the fatal route check | 23 / 23 |
| `ndmm/tests/test_runner.R` | the Sep 16 cohort runner suite, carried over, with its Optum-only tests replaced by MDV ones | 407 / 407 |
| `lot/engine/tests/test_runner.R`, `test_line_criteria.R` | the Sep 16 LOT runner and criteria suites, the same way | 532 / 532, 59 / 59 |

**Not run here:** the LOT line assembly on MDV-shaped data. The MAP state
machine and SCT clustering use Spark higher-order functions (`aggregate` with
a finish lambda) that DuckDB cannot run through sqlglot. That code is
unchanged from Sep 16, so its behaviour is what the Sep 16 suites establish.
Its first run on MDV output is the warehouse run.

Before any number is used, PORTING.md's last section applies to this port too.
It needs its own planted cases on real data, its own face-validity bands, and
a reconciliation against published Japanese line-of-therapy distributions.
Until someone signs it off, this build is a deviation from the study.
