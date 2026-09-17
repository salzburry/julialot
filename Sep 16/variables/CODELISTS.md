# Code lists - what exists, what the protocol needs, what is missing

The protocol defines almost every criterion and every outcome by reference to a code
list, and puts the lists themselves in Annexes 2 and 3, neither of which is available
yet. This file says which lists the build already reads, what shape they are in, and
what still has to be authored.

## 1. What the build reads today

Code lists are **CSV files on production**, not warehouse tables, and they are not
version-controlled with the code. `CODELIST_DIR` names the directory
(`lot/engine/config.csv`). Nothing loads without them: `load_codelist_csv()` stops the
run on a missing file, an unknown filename, missing columns, or zero data rows, and
records each file's checksum on the run.

### The NDMM cohort build

| file | required columns | code types it may carry | what it drives |
|---|---|---|---|
| `mm_dx.csv` | `dx`, `icd_family` | ICD-9-CM / ICD-10-CM diagnosis | the MM diagnosis (criterion I1) |
| `cl_mma_codelist.csv` | `CL_CODE_TYPE`, `CL_CODE`, `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR` | `HCPCS`, `CPT`, `NDC` (`NDMM_MMA_CODE_TYPES`) | the 1L index (I3), prior-therapy scan (X1), belantamab (X4) |
| `other_malig.csv` | `dx`, `icd_family`, `tumor_group` | ICD-9-CM / ICD-10-CM diagnosis | the other-cancer exclusion (X2) |
| `pregnancy.csv` | `code_type`, `code` | `ICD9DIAG`, `ICD10DIAG`, `ICD9PROC`, `ICD10PROC`, `HCPCS`, `REV` (`NDMM_PREG_CODE_TYPES`) | the pregnancy exclusion (X3) |
| `clintrial.csv` | `code`, `code_type` | same six as pregnancy (`NDMM_CLINTRIAL_CODE_TYPES`) | a descriptive trial flag - **not a criterion** |

A code type outside the list a scan names loads cleanly, joins, and matches nothing,
so the guard exists to stop a rule silently doing nothing.

### The LOT engine - `lot/engine/R/steps/01_codelists.R`

| file | required columns | what it drives |
|---|---|---|
| `cl_mma_rollup.csv` | `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR`, `MONOMAINTENANCE`, `DUALMAINTENANCEWITH`, `CONDITIONING`, `USED_FOR_OTHER_CANCERS` | drug-level attributes: maintenance flags, conditioning, cross-indication use |
| `cl_mma_codelist.csv` | as above | claim → drug mapping |
| `permissible_subs.csv` | `original_med`, `substitute_med` | biosimilar substitution (LOT rule §4.4) |
| `cl_sct_codelist.csv` | `CL_CODE_TYPE`, `CL_CODE`, `SCT_TYPE` | SCT identification and AUTO/ALLO typing |

The rollup is specified as **27 medications**, from belantamab/BELA/ABCMA to
venetoclax/VENE/BLC21.

### Matching conventions

- **ICD codes** - both sides normalised with `upper(regexp_replace(x,'[^A-Za-z0-9]',''))`,
  so `C90.00` and `C9000` are the same key. `icd_family` must be one of
  `9 / ICD9 / ICD-9 / ICD9DIAG` or `10 / ICD10 / ICD-10 / ICD10DIAG`; anything else
  **stops the run**, deliberately, because an unrecognised family silently reads as
  ICD-10 and then matches nothing. A **claim** whose `ICD_FLAG` names neither family
  matches nothing and is reported rather than gated - 16 such rows on the first
  production run, and `NDMM_ICD_FLAG_MAX_ROWS`, the ceiling that would stop a build,
  ships unset (`OPEN_QUESTIONS.md` Q24).
- **NDC** - keyed on digits only. Eleven digits as they stand; ten left-padded, which
  is the 4-4-2 layout; **any other digit count gets no key and does not join**. A
  ten-digit NDC written 5-3-2 or 5-4-1 pads to the wrong key, so `check_ndc_shape()`
  profiles both sides of the join every run and stops the build on a malformed
  **code-list** value (fixable at source) while only reporting a malformed claim
  value. Optum writes `NONE`/`UNK` on medical claims with no NDC - 1.2 bn rows - and
  those must never be padded into a key.
- **HCPCS / CPT / revenue** - punctuation stripped, uppercased, exact match.

### What the deployed `mm_dx.csv` holds

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

Eight codes - the **strict** 203.0x / C90.0x families only, no broad 203.x / C90.x.
Confirm against the production file before quoting it.

Two things follow from this file that are easy to get wrong:

- **The join is equality on the normalised code, not a prefix match.** `ICD9DIAG,2030`
  matches a claim coded exactly `203.0` and does **not** cover `203.00` - which is why
  all four codes of each family are listed separately.
- **The build's separate `mm_dx_strict_flg` currently does nothing.** It is a prefix
  test (`LIKE '2030%'` / `LIKE 'C900%'`) that the inpatient arm additionally requires
  on top of the code-list match. Every code in today's eight-row file already
  satisfies it. The flag only starts to bite the moment `mm_dx.csv` is widened -
  which is exactly what Q2 would do.

**This matters for `OPEN_QUESTIONS.md` Q2**: if the outpatient arm of criterion I1 is
meant to use the broad set, this file is short by every 203.x / C90.x code outside
the `.0` family.

### What is on production

| production file | what it holds |
|---|---|
| `mm_dx.csv` | header + **8 rows** (above) |
| `clintrial.csv` | header + **17 rows** - HCPCS G0276, G0292, G0293, G0294, G2000, G8928, G9057, S9988, S9990, S9991, S9992, S9994, S9996, plus `ICD10DIAG,Z006` and `ICD9DIAG,V707` |
| `pregnancy.csv` | row numbers reach **≥ 5,319**; carries ICD10PROC, HCPCS **and REV codes 0720, 0721, 0722, 0724, 0729** |
| `other_malig.csv` | **1,643 code rows, 1,618 distinct `tumor_group`** |
| `cl_mma_codelist.csv` | includes `HCPCS,C9069,belantamab,ABCMA,BELA` |
| `permissible_subs.csv` | present; row detail not held here |
| `mm_therapy.csv` | present, but read by no current build - a legacy asset |
| `cl_sct_codelist.csv`, `cl_mma_rollup.csv` | present; contents not held here |

## 2. What the protocol needs that no list covers

Nothing in this section exists today, in the build or on production.

### From Annex 2 - treatments

| concept | why it is needed |
|---|---|
| Eligible / expected **1L** MM therapies | criterion I3 - which agents may set the 1L index |
| Later-line-only agents to bar from the 1L index | I3 names **panobinostat** and **elotuzumab** explicitly, and leaves room for others |
| SOC **regimen** categories (quadruplet / triplet / doublet / anti-CD38 backbone / CAR-T / BCMA bispecific / non-BCMA bispecific / other novel) for 1L and for later lines | §7.2.2, every stratified analysis, and the Sankey |

`cl_mma_rollup.csv` gives drug class and abbreviation, which is the input to a
regimen categoriser, but **there is no regimen-category column anywhere today**.

### From Annex 3 - outcome code lists (ICD-10-CM)

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
| All-cause inpatient hospitalisation | §7.3.2 - `confinement`, no code list needed |
| MM-related hospitalisation | §7.8.1 - MM diagnosis in **first or second position** |
| Emergency visits | §7.3.2 - **construction not specified**, see `DATA_MAPPING.md` §6 |

### From Annex 7 - frailty

The **Kim 2018 claims-based frailty index**: its variable list, the code lists behind
each variable, and its coefficients. The protocol marks frailty provisional, pending
data and mapping, so it may be dropped - but if it is kept, Annex 7 is the only
source.

### Not from any annex - Charlson

The **Quan 2011** Charlson Comorbidity Index: ICD-9-CM **and** ICD-10 code lists for
all 17 conditions plus the Quan weights, with the myeloma condition zeroed so that
"a value of 0 indicates no additional comorbidities beyond MM". The protocol cites
Quan et al. 2011 in its reference list but carries no annex for it.

## 3. Existing lists that need widening

| file | why |
|---|---|
| `other_malig.csv` | 1,643 code rows but **1,618 distinct `tumor_group` values** - the label is one per code, not a grouping, so pairing on it would reduce to needing the same exact code twice. The build therefore pairs on the **first three characters of the ICD code** (C50 breast, C34 lung, C79 secondary neoplasm), which is what "same primary tumour type and/or metastatic cancer" asks for. What still has to change is the **window**: 30 days, not the baseline year |
| `mm_dx.csv` | see §1 - depends on Q2 |
| `cl_mma_codelist.csv` | must cover panobinostat and elotuzumab as named `CL_MED_ABBR` values so they can be barred from setting the index; and belantamab as `BELA` (already assumed, `NDMM_BELANTAMAB_ABBR`) |

## 4. Recommended new files

Keeping the existing loader conventions, so nothing about matching has to change:

| proposed file | columns | covers |
|---|---|---|
| `safety_events.csv` | `condition`, `domain`, `acute_chronic`, `setting` (`any`, or `inpatient` for a condition defined by an admission — the study's `severe_infection_resulting_in_hospitalisation`), `code_type`, `code`, `icd_family` | all 23 Table 3 conditions (Q36) |
| `secondary_malig.csv` | `category`, `subtype`, `code_type`, `code`, `icd_family` | Table 2's 10 categories |
| `comorbid_subgroups.csv` | `concept`, `code_type`, `code`, `icd_family` | neuropathy, lung parenchymal disease, any other subgroup condition |
| `charlson_quan2011.csv` | `condition`, `weight`, `code_type`, `code`, `icd_family` | CCI |
| `frailty_kim2018.csv` | `variable`, `coefficient`, `code_type`, `code`, `icd_family` | CFI, if kept |
| `hcru.csv` | `concept` (`ED_VISIT`), `code_type` (`RVNU`/`POS`/`CPT`), `code` | emergency visits |
| `soc_regimen_categories.csv` | `line_scope` (`1L`/`LATER`), `soc_category`, `CL_MED_ABBR`, `role` | SOC categorisation |
| `eligible_1l_agents.csv` | `CL_MED_ABBR`, `eligible_1l` (Y/N), `reason` | which agents may set the 1L index |

Two shape decisions worth making before the content arrives:

- `hcru.csv` covers emergency visits only. All-cause hospitalisation must keep using
  the same inpatient definition as the cohort (`CONFINEMENT`/`CONF_ID`, with `POS`
  21/51/61 and `TOS_CD` as fallbacks) so that cohort and outcome cannot drift.
- `soc_regimen_categories.csv` keys on `CL_MED_ABBR`, not on a regimen string, so
  that a new drug spelling does not silently fall out of a category.

Every one of these is blocked on Annex 2, Annex 3 or Annex 7 - except
`charlson_quan2011.csv`, which can be built from the published Quan 2011 paper, and
`hcru.csv`, which is blocked on a decision rather than a document
(`OPEN_QUESTIONS.md` Q11).

## 5. What to ask for

Annex numbers follow the **body text** of the protocol (§7.3.2 and §7.8.5 both cite
Annex 3 for code lists). Its Table of Contents disagrees and calls the code lists
Annex 5 - say which you mean when you ask. `OPEN_QUESTIONS.md` Q20.

In one message to the study team (`OPEN_QUESTIONS.md` Q15):

1. **Annex 2** - eligible/expected MM therapies and the SOC regimen categorisation.
2. **Annex 3** - the ICD-10-CM code lists for every Table 3 condition, the secondary
   malignancy categories, and the healthcare-utilisation definitions.
3. **Annex 7** - the Kim CFI algorithm and its code lists, or confirmation that
   frailty is dropped.
