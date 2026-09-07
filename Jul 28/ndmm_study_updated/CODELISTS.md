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

| file | required columns | what it drives |
|---|---|---|
| `mm_dx.csv` | `dx`, `icd_family` | the MM diagnosis (criterion I1) |
| `cl_mma_codelist.csv` | `CL_CODE_TYPE`, `CL_CODE`, `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR` | the 1L index (I3), prior-therapy scan (X1), belantamab (X4) |
| `other_malig.csv` | `dx`, `icd_family`, `tumor_group` | the other-cancer exclusion (X2) |
| `pregnancy.csv` | `code_type`, `code` | the pregnancy exclusion (X3) |
| `clintrial.csv` | `code`, `code_type` | a descriptive trial flag — **not a criterion** |

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
  ICD-10 and then matches nothing (`Jul 28/ndmm/R/codelists.R:39-70`).
- **NDC** — keyed on digits only. Eleven digits as they stand; ten padded under the
  4-4-2 assumption; **any other digit count gets no key and does not join**. Optum
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
The first two rows are at the limit of legibility in the photograph; the code count
and the eight descriptions in `docs/Part 1/codist.pdf` agree, so the reading is the
sensible one, but confirm against the production file before quoting it.

**This matters for `OPEN_QUESTIONS.md` Q2**: if the outpatient arm of criterion I1 is
meant to use the broad set, this file is short by every 203.x / C90.x code outside
the `.0` family.

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
| `pregnancy.csv` | criterion X3 names diagnosis, procedure **and revenue** codes. The loader takes `code_type`, `code`, so revenue codes fit the schema — confirm the production file actually carries them |
| `other_malig.csv` | already carries `tumor_group`, which is what "same primary tumor type" needs. Confirm metastatic codes form their own group and that the grouping is granular enough to distinguish "same primary tumour type" pairs |
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

In one message to the study team:

1. **Annex 2** — eligible/expected MM therapies and the SOC regimen categorisation.
2. **Annex 3** — the ICD-10-CM code lists for every Table 3 condition, the secondary
   malignancy categories, and the healthcare-utilisation definitions.
3. **Annex 7** — the Kim CFI algorithm and its code lists, or confirmation that
   frailty is dropped.
4. The **.docx itself**, which would also recover document pages 31-32 (see
   `IE_CRITERIA.md` §9).
