# Code lists — what exists, what the protocol needs, what is missing

The protocol defines almost every criterion and every outcome by reference to a code
list, and puts the lists themselves in Annexes 2 and 3 — **neither of which is in the
photographs**. This file says exactly which lists the build already reads, what shape
they are in, and what still has to be authored.

## 1. What the build reads today

Code lists are **CSV files on production**, not warehouse tables. `CODELIST_DIR`
defaults to `/mnt/code/codelist` (`Jul 28/ndmm/config.csv`,
`Jul 28/lot/engine/config.csv`). Nothing loads without them: `load_codelist_csv()`
stops the run on a missing file, an unknown filename, missing columns, or zero data
rows, and records each file's md5 on the run.

### The NDMM cohort build — `Jul 28/ndmm/R/codelists.R`

| file | required columns | code types it may carry | what it drives |
|---|---|---|---|
| `mm_dx.csv` | `dx`, `icd_family` | ICD-9-CM / ICD-10-CM diagnosis | the MM diagnosis (criterion I1) |
| `cl_mma_codelist.csv` | `CL_CODE_TYPE`, `CL_CODE`, `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR` | `HCPCS`, `CPT`, `NDC` (`NDMM_MMA_CODE_TYPES`) | the 1L index (I3), prior-therapy scan (X1), belantamab (X4) |
| `other_malig.csv` | `dx`, `icd_family`, `tumor_group` | ICD-9-CM / ICD-10-CM diagnosis | the other-cancer exclusion (X2) |
| `pregnancy.csv` | `code_type`, `code` | `ICD9DIAG`, `ICD10DIAG`, `ICD9PROC`, `ICD10PROC`, `HCPCS`, `REV` (`NDMM_PREG_CODE_TYPES`) | the pregnancy exclusion (X3) |
| `clintrial.csv` | `code`, `code_type` | same six as pregnancy (`NDMM_CLINTRIAL_CODE_TYPES`) | a descriptive trial flag — **not a criterion** |

A code type outside the list a scan names loads cleanly, joins, and matches nothing —
so the guard exists to stop a rule silently doing nothing. The `overall/` build reads
the same five files (`Jul 28/overall/R/build_cohort.R:139-146`).

### The LOT engine — `Jul 28/lot/engine/R/steps/01_codelists.R`

| file | required columns | what it drives |
|---|---|---|
| `cl_mma_rollup.csv` | `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR`, `MONOMAINTENANCE`, `DUALMAINTENANCEWITH`, `CONDITIONING`, `USED_FOR_OTHER_CANCERS` | drug-level attributes: maintenance flags, conditioning, cross-indication use |
| `cl_mma_codelist.csv` | as above | claim → drug mapping |
| `permissible_subs.csv` | `original_med`, `substitute_med` | biosimilar substitution (LOT rule §4.4) |
| `cl_sct_codelist.csv` | `CL_CODE_TYPE`, `CL_CODE`, `SCT_TYPE` | SCT identification and AUTO/ALLO typing |

### Matching conventions

- **ICD codes** — both sides normalised with `upper(regexp_replace(x,'[^A-Za-z0-9]',''))`,
  so `C90.00` and `C9000` are the same key. `icd_family` must be one of
  `9 / ICD9 / ICD-9 / ICD9DIAG` or `10 / ICD10 / ICD-10 / ICD10DIAG`; anything else
  **stops the run** — deliberately, because an unrecognised family silently reads as
  ICD-10 and then matches nothing (`Jul 28/ndmm/R/codelists.R:41-65`). A **claim** whose
  `ICD_FLAG` names neither family matches nothing and is reported rather than gated — 16
  such rows on the first production run, and `NDMM_ICD_FLAG_MAX_ROWS`, the ceiling that
  would stop a build, ships unset (`OPEN_QUESTIONS.md` Q24).
- **NDC** — keyed on digits only. Eleven digits as they stand; ten left-padded, which is
  the 4-4-2 layout; **any other digit count gets no key and does not join**. A ten-digit
  NDC written 5-3-2 or 5-4-1 pads to the wrong key, so `check_ndc_shape()` profiles both
  sides of the join every run and stops the build on a malformed **code-list** value
  (fixable at source) while only reporting a malformed claim value. Optum
  writes `NONE`/`UNK` on medical claims with no NDC — 1.2 bn rows — and those must
  never be padded into a key (`Jul 28/ndmm/R/db_utils.R:65-76`).
- **HCPCS / CPT / revenue** — punctuation stripped, uppercased, exact match.

### What the deployed `mm_dx.csv` actually holds

Visible in `Apr 18 2026/codelist.pdf` (a photograph of the Domino project
`219870_mm_optumlot` with `mm_dx.csv` open) and cross-checked against
`docs/Part 1/codist.pdf`:

```
icd_family,dx
ICD9DIAG,2030            # 203.0   Multiple myeloma
ICD9DIAG,20300           # 203.00  ...without mention of having achieved remission
ICD9DIAG,20301           # 203.01  ...in remission
ICD9DIAG,20302           # 203.02  ...in relapse
ICD10DIAG,C900           # C90.0   Multiple myeloma
ICD10DIAG,C9000          # C90.00  ...not having achieved remission
ICD10DIAG,C9001          # C90.01  ...in remission
ICD10DIAG,C9002          # C90.02  ...in relapse
```

Eight codes — the **strict** 203.0x / C90.0x families only, no broad 203.x / C90.x.
Rows 2 and 3 are at the limit of legibility in the photograph (both render as `203`),
but the eight code slots line up one-for-one with the eight descriptions on
`docs/Part 1/codist.pdf` page 1, which lists `203.0`, `203.00`, `203.01` (Remission),
`203.02` (Relapse), `C90.0`, `C90.00`, `C90.01` (Remission), `C90.02` (Relapse). Still
worth confirming against the production file before quoting it.

Two things follow from this file that are easy to get wrong:

- **The join is equality on the normalised code, not a prefix match.** `ICD9DIAG,2030`
  matches a claim coded exactly `203.0` and does **not** cover `203.00` — which is why
  all four codes of each family are listed separately.
- **The build's separate `mm_dx_strict_flg` currently does nothing.** It is a prefix
  test (`LIKE '2030%'` / `LIKE 'C900%'`) that the inpatient arm additionally requires
  (`Jul 28/ndmm/R/steps/00_mm_cohort.R:56-90`, then `WHERE inpatient_flg = 1 AND
  mm_dx_strict_flg = 1`). Every code in today's eight-row file already satisfies it.
  The flag only starts to bite the moment `mm_dx.csv` is widened — which is exactly
  what Q2 would do.

**This matters for `OPEN_QUESTIONS.md` Q2**: if the outpatient arm of criterion I1 is
meant to use the broad set, this file is short by every 203.x / C90.x code outside
the `.0` family.

### Where the production files are, and what is visible of them

Nothing in `CODELIST_DIR` is under version control — `Jul 28/RUN_ON_PROD.md` says so
outright ("Code and docs only. **No code lists**"). A sweep of the repo for any of the
eight expected filenames returns nothing. What the repo does hold is the loader
contract, and photographs of the deployed files in `Apr 18 2026/codelist.pdf` (the
Domino project `219870_mm_optumlot` with each CSV open in the editor):

| production file | what is visible | size |
|---|---|---|
| `mm_dx.csv` | the whole file | header + **8 rows** (below) |
| `clintrial.csv` | the whole file | header + **17 rows** — HCPCS G0276, G0292, G0293, G0294, G2000, G8928, G9057, S9988, S9990, S9991, S9992, S9994, S9996, plus `ICD10DIAG,Z006` and `ICD9DIAG,V707` |
| `pregnancy.csv` | partial | row numbers reach **≥ 5,319**; carries ICD10PROC, HCPCS **and REV codes 0720, 0721, 0722, 0724, 0729** |
| `other_malig.csv` | partial | **1,643 code rows, 1,618 distinct `tumor_group`** (stated in `Jul 28/ndmm/DECISIONS.md` §4) |
| `cl_mma_codelist.csv` | partial | a legible row `HCPCS,C9069,belantamab,ABCMA,BELA` |
| `permissible_subs.csv` | tab visible, rows not legible | — |
| `mm_therapy.csv` | tab visible | **on production but read by no current build** — a legacy asset |
| `cl_sct_codelist.csv`, `cl_mma_rollup.csv` | **not photographed** | — |

`docs/Part 1/codist.pdf` adds two spec-workbook tabs: the MM diagnosis sheet, and tab
**`40.CL MMA ROLLUP`** — "Codelist Multiple Myeloma Approved and Steroid Medications
Rollup", columns `CL_MEDICATION_FULL, CL_MED_CLASS, CL_MED_ABBR, MONOMAINTENANCE,
DUALMAINTENANCE.WITH, CONDITIONING`, **27 medications** from belantamab/BELA/ABCMA to
venetoclax/VENE/BLC21.

The `dx_codes`, `mm_therapy_ndc`, `mm_therapy_hcpcs` and `permissible_subs` sheets of
`docs/Part 3/Program Spec/Program_Spec_Workbook.xlsx` are all headed
**"STATUS: TO BE BUILT"** with every cell `[TO BE BUILT]` — no codes.

### Scaffolding that already exists in the `Aug 14/` fork

`Aug 14/` is a fork of `Jul 28/`, not its successor, and it is the only place in the
repo carrying safety and HCRU code-list structure:

| file | rows | state |
|---|---|---|
| `Aug 14/lot/safety/codelists/safety_events.csv` | 26 | columns `domain, condition, acute_chronic, code_type, code, icd_family, source_note`. **Every code cell is empty** |
| `Aug 14/lot/safety/codelists/hcru_events.csv` | 13 | columns `event, measure, precedence, code_type, code, source_note`. **9 rows filled** — all-cause hospitalisation via `CONFINEMENT`/`CONF_ID` with `POS` 21/51/61 and `TOS_CD` fallbacks copied verbatim from `00_mm_cohort.R` so cohort and outcome cannot drift, and LOS via `CONFINEMENT`/`LOS`. `inpatient_length_of_stay_mm_related` and `er_visit` are placeholders |

Its loader, `Aug 14/lot/safety/R/codelists_safety.R`, refuses to return anything while
any condition is unfilled — *"23 of 26 conditions still have no codes, so a rate for
them would be zero for want of a code list rather than for want of events"*.
`Jul 28/lot/` has no `safety/` directory at all.

`apr_30_2026/regimen_categories.csv` (47 rows, `regimen,category`, e.g.
`DARA BORT LENA` → *Quadruplet with anti-CD38 backbone (1L NDMM)*) is the closest
thing in the repo to the protocol's §7.2.2 categorisation — but it belongs to a
superseded baseline and keys on a regimen string rather than on `CL_MED_ABBR`.

**These three files are the right starting points for the new lists in §4.** They are
structure without content; Annexes 2 and 3 are the content.

## 2. What the protocol needs that no list covers

Nothing in this section exists in the repo or on the production code-list directory
today.

### From Annex 2 — treatments

| concept | why it is needed |
|---|---|
| Eligible / expected **1L** MM therapies | criterion I3 — which agents may set the 1L index |
| Later-line-only agents to bar from the 1L index | I3 names **panobinostat** and **elotuzumab** explicitly, "other potential therapies pending review of data may be considered" |
| SOC **regimen** categories (quadruplet / triplet / doublet / anti-CD38 backbone / CAR-T / BCMA bispecific / non-BCMA bispecific / other novel) for 1L and for later lines | §7.2.2, every stratified analysis, and the Sankey |

`cl_mma_rollup.csv` gives drug class and abbreviation, which is the input to a
regimen categoriser, but **there is no regimen-category column anywhere today**.

### From Annex 3 — outcome code lists (ICD-10-CM)

All 22 Table 3 rows, assessed at baseline and follow-up for 1L, 2L and 3L:

| group | conditions |
|---|---|
| Hepatologic | toxic liver disease · hepatic failure · acute hepatitis B · fibrosis and cirrhosis · non-alcoholic steatohepatitis |
| Renal | acute kidney injury / acute kidney disease · chronic kidney disease · moderate-to-severe renal impairment or ESRD |
| Ocular | corneal ulcer · keratopathies (including ulcerative and infective) |
| Cardiovascular | myocardial infarction / unstable angina · pulmonary hypertension · cerebrovascular events / stroke and TIA · peripheral arterial thromboembolism · DVT / pulmonary embolism |
| Neurologic | peripheral neuropathy · Parkinson's disease and other movement disorders · seizures |
| Infectious | severe infection resulting in hospitalization · lower respiratory / lung infection |
| Other | thrombocytopenia · anaemia |

Plus, for the subgroup stratifications and the secondary-malignancy objective:

| concept | source section |
|---|---|
| Lung parenchymal disease (COPD, asthma, bronchiectasis, emphysema) | §7.2.3 |
| Neuropathy, as a baseline-history subgroup flag | §7.2.3, Table 1 row 3 |
| Secondary malignancy, 10 categories | §7.2.4, Table 2 |
| All-cause inpatient hospitalisation | §7.3.2 — `confinement`, no code list needed |
| MM-related hospitalisation | §7.8.1 — MM diagnosis in **first or second position** |
| Emergency visits | §7.3.2 — **construction not specified**, see `DATA_MAPPING.md` §6 |

### From Annex 7 — frailty

The **Kim 2018 claims-based frailty index**: its variable list, the code lists behind
each variable, and the regression coefficients. Marked in the protocol as *"only
included pending review of data and mapping"* and *"dependent on data use and mapping
availability"*, so it may be dropped — but if it is kept, Annex 7 is the only source.

### Not from any annex — Charlson

The **Quan 2011** Charlson Comorbidity Index: ICD-9-CM **and** ICD-10 code lists for
all 17 conditions plus the Quan weights, with the myeloma condition zeroed so that
"a value of 0 indicates no additional comorbidities beyond MM". The protocol cites
Quan et al. 2011 in its reference list but supplies no annex for it.

## 3. Existing lists that need widening

| file | why |
|---|---|
| `other_malig.csv` | 1,643 code rows but **1,618 distinct `tumor_group` values** — the label is one per code, not a grouping, so pairing on it would reduce to needing the same exact code twice. The build therefore pairs on the **first three characters of the ICD code** (C50 breast, C34 lung, C79 secondary neoplasm), which is what "same primary tumour type and/or metastatic cancer" asks for (`Jul 28/ndmm/DECISIONS.md` §4). What still has to change is the **window**: 30 days, not the baseline year |
| `mm_dx.csv` | see §1 — depends on Q2 |
| `cl_mma_codelist.csv` | must cover panobinostat and elotuzumab as named `CL_MED_ABBR` values so they can be barred from setting the index; and belantamab as `BELA` (already assumed, `NDMM_BELANTAMAB_ABBR`) |

## 4. Recommended new files

Keeping the existing loader conventions, so nothing about matching has to change:

| proposed file | columns | covers |
|---|---|---|
| `safety_events.csv` | `event_key`, `event_label`, `event_group`, `acute_chronic`, `code_type`, `code`, `icd_family` | all 22 Table 3 conditions |
| `secondary_malig.csv` | `category`, `subtype`, `code_type`, `code`, `icd_family` | Table 2's 10 categories |
| `comorbid_subgroups.csv` | `concept`, `code_type`, `code`, `icd_family` | neuropathy, lung parenchymal disease, any other subgroup condition |
| `charlson_quan2011.csv` | `condition`, `weight`, `code_type`, `code`, `icd_family` | CCI |
| `frailty_kim2018.csv` | `variable`, `coefficient`, `code_type`, `code`, `icd_family` | CFI, if kept |
| `hcru.csv` | `concept` (`ED_VISIT`), `code_type` (`RVNU`/`POS`/`CPT`), `code` | emergency visits |
| `soc_regimen_categories.csv` | `line_scope` (`1L`/`LATER`), `soc_category`, `CL_MED_ABBR`, `role` | SOC categorisation |
| `eligible_1l_agents.csv` | `CL_MED_ABBR`, `eligible_1l` (Y/N), `reason` | which agents may set the 1L index |

Every one of these is blocked on Annex 2, Annex 3 or Annex 7 — except
`charlson_quan2011.csv`, which can be built from the published Quan 2011 paper, and
`hcru.csv`, which is blocked on a decision rather than a document
(`OPEN_QUESTIONS.md` Q11).

## 5. What to ask for

Annex numbers follow the **body text** of the protocol (§7.3.2 and §7.8.5 both cite
Annex 3 for code lists). Its Table of Contents disagrees and calls the code lists
Annex 5 — say which you mean when you ask. `OPEN_QUESTIONS.md` Q20.

In one message to the study team (`OPEN_QUESTIONS.md` Q15):

1. **Annex 2** — eligible/expected MM therapies and the SOC regimen categorisation.
2. **Annex 3** — the ICD-10-CM code lists for every Table 3 condition, the secondary
   malignancy categories, and the healthcare-utilisation definitions.
3. **Annex 7** — the Kim CFI algorithm and its code lists, or confirmation that
   frailty is dropped.
4. The **.docx itself**, which would also recover document pages 31-32 (see
   `IE_CRITERIA.md` §9).
