# Code lists - what is read, what the protocol needs, what is missing

The protocol defines almost every criterion and every outcome by reference to a
code list, and puts the lists themselves in Annexes 2, 3 and 7, none of which is
available yet. This file lists every code-list file the three builds read, the
columns and code types each must carry, and what is filled and what still has
to be authored.

Code lists are **CSV files on production**, not warehouse tables, and they are
not version-controlled with the code. Each stage names the directory in its own
`CODELIST_DIR` setting. Every loader records each file's md5 and row count on
the run, so a number can be traced to the file that produced it.

| section | what it covers |
|---|---|
| §1 | the production lists the cohort build and the LOT engine read, and how codes are matched |
| §2 | the concepts the protocol needs that no list covers yet |
| §3 | production lists that need widening |
| §4 | the files this package reads - the shapes shipped in `codelists/` |
| §5 | what to ask the study team for |

## 1. The production lists the cohort build and the LOT engine read

Neither build has an embedded fallback: a missing file, an unknown filename,
missing columns or zero data rows stops the run.

### The cohort build (`../ndmm/README.md` "What this reads")

| file | required columns | code types it may carry | what it drives |
|---|---|---|---|
| `mm_dx.csv` | `dx`, `icd_family` | ICD-9-CM / ICD-10-CM diagnosis | the MM diagnosis (criterion I1) |
| `cl_mma_codelist.csv` | `CL_CODE_TYPE`, `CL_CODE`, `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR` | `HCPCS`, `CPT`, `NDC` (`NDMM_MMA_CODE_TYPES`) | the 1L index (I3), prior-therapy scan (X1), belantamab (X4) |
| `other_malig.csv` | `dx`, `icd_family`, `tumor_group` | ICD-9-CM / ICD-10-CM diagnosis | the other-cancer exclusion (X2) |
| `pregnancy.csv` | `code_type`, `code` | `ICD9DIAG`, `ICD10DIAG`, `ICD9PROC`, `ICD10PROC`, `HCPCS`, `REV` (`NDMM_PREG_CODE_TYPES`) | the pregnancy exclusion (X3) |
| `clintrial.csv` | `code`, `code_type` | the same six (`NDMM_CLINTRIAL_CODE_TYPES`) | a descriptive trial flag - **not a criterion** |

A code type outside the list a scan names loads cleanly, joins, and matches
nothing, so the guard exists to stop a rule silently doing nothing.

### The LOT engine (`../lot/FILES.md`)

| file | required columns | what it drives |
|---|---|---|
| `cl_mma_rollup.csv` | `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR`, `MONOMAINTENANCE`, `DUALMAINTENANCEWITH`, `CONDITIONING`, `USED_FOR_OTHER_CANCERS` | drug-level attributes: maintenance flags, conditioning, cross-indication use |
| `cl_mma_codelist.csv` | as above | claim → drug mapping |
| `permissible_subs.csv` | `original_med`, `substitute_med` | biosimilar substitution (`../lot/LOT_RULES.md` §4.4) |
| `cl_sct_codelist.csv` | `CL_CODE_TYPE`, `CL_CODE`, `SCT_TYPE` | SCT identification and AUTO/ALLO typing |

The rollup is specified as **27 medications**, from belantamab/BELA/ABCMA to
venetoclax/VENE/BLC21.

### What is on production

As recorded from the production directory; confirm against the files before
quoting them.

| production file | what it holds |
|---|---|
| `mm_dx.csv` | header + **8 rows** (below) |
| `clintrial.csv` | header + **17 rows** - HCPCS G0276, G0292, G0293, G0294, G2000, G8928, G9057, S9988, S9990, S9991, S9992, S9994, S9996, plus `ICD10DIAG,Z006` and `ICD9DIAG,V707` |
| `pregnancy.csv` | ≥ 5,319 rows; carries ICD10PROC, HCPCS **and REV codes 0720, 0721, 0722, 0724, 0729** |
| `other_malig.csv` | **1,643 code rows, 1,618 distinct `tumor_group`** |
| `cl_mma_codelist.csv` | includes `HCPCS,C9069,belantamab,ABCMA,BELA`; no steroid abbreviation (`OPEN_QUESTIONS.md` Q6) |
| `permissible_subs.csv` | present; row detail not held here |
| `cl_sct_codelist.csv`, `cl_mma_rollup.csv` | present; contents not held here |
| `mm_therapy.csv` | present, read by no build - a legacy asset |

None of the seven study lists in §4 (`charlson_quan2011.csv` to
`soc_regimen_categories.csv`) is on production.

**`mm_dx.csv` holds the strict families only:**

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

Two things follow from this file that are easy to get wrong:

- **The join is equality on the normalised code, not a prefix match.** `ICD9DIAG,2030`
  matches a claim coded exactly `203.0` and does **not** cover `203.00` - which is
  why all four codes of each family are listed separately.
- **The cohort build's `mm_dx_strict_flg` does nothing on this file.** It is a
  prefix test (`LIKE '2030%'` / `LIKE 'C900%'`) that the inpatient arm requires
  on top of the code-list match, and every code here already satisfies it. It
  starts to bite only when `mm_dx.csv` is widened, which is what the broad
  reading of `OPEN_QUESTIONS.md` Q2 would do.

Only one member since 2016 carries an ICD-9 myeloma code, so the ICD-9 rows are
dead weight for this study period (`DATA_MAPPING.md` §4).

### Matching conventions

The same wherever a build matches that kind of code:

- **ICD codes** - both sides normalised with `upper(regexp_replace(x,'[^A-Za-z0-9]',''))`,
  so `C90.00` and `C9000` are the same key, and joined on the ICD family as well.
  `icd_family` must be one of `9 / ICD9 / ICD-9 / ICD9DIAG` or
  `10 / ICD10 / ICD-10 / ICD10DIAG`; anything else, or a blank, **stops the run**,
  because an unrecognised family matches nothing. A **claim** whose `ICD_FLAG`
  names neither family matches nothing and is reported rather than gated
  (`OPEN_QUESTIONS.md` Q24); `NDMM_ICD_FLAG_MAX_ROWS`, the ceiling that would stop
  the cohort build, ships unset.
- **NDC** - keyed on digits only. Eleven digits as they stand; ten left-padded,
  which is the 4-4-2 layout; **any other digit count gets no key and does not
  join**. A ten-digit NDC written 5-3-2 or 5-4-1 pads to the wrong key, so the
  cohort build's `check_ndc_shape()` profiles both sides of the join every run
  and stops on a malformed **code-list** value (fixable at source) while only
  reporting a malformed claim value. Optum writes `NONE`/`UNK` on medical claims
  with no NDC - 1.2 bn rows - and those are never padded into a key.
- **HCPCS / CPT / revenue / place of service** - punctuation stripped,
  uppercased, exact match. Code types are compared case-insensitively.

## 2. What the protocol needs that no list covers

No codes for any of this exist, in the build or on production. §4 has the
shapes that will hold them.

### From Annex 2 - treatments

| concept | why it is needed |
|---|---|
| Eligible / expected **1L** MM therapies | criterion I3 - which agents may set the 1L index |
| Later-line-only agents to bar from the 1L index | I3 names **panobinostat** and **elotuzumab** explicitly, and leaves room for others. The cohort build bars them through `NDMM_INDEX_EXCLUDED_ABBRS`, and this package checks that it did (`COHORT_INDEX_EXCLUSIONS`) |
| SOC **regimen** categories (quadruplet / triplet / doublet / anti-CD38 backbone / CAR-T / BCMA bispecific / non-BCMA bispecific / other novel) for 1L and for later lines | §7.2.2, every stratified analysis, and the Sankey |

`cl_mma_rollup.csv` gives drug class and abbreviation, which is the input to a
regimen categoriser, but no production list carries a regimen category.

### From Annex 3 - outcome code lists (ICD-10-CM)

The Table 3 rows, assessed at baseline and follow-up for 1L, 2L and 3L:

| group | conditions |
|---|---|
| Hepatologic | toxic liver disease · hepatic failure · acute hepatitis B · fibrosis and cirrhosis · non-alcoholic steatohepatitis |
| Renal | acute kidney injury / acute kidney disease · chronic kidney disease · moderate-to-severe renal impairment or ESRD |
| Ocular | corneal ulcer · keratopathies (including ulcerative and infective) |
| Cardiovascular | myocardial infarction / unstable angina · pulmonary hypertension · cerebrovascular events / stroke and TIA · peripheral arterial thromboembolism · DVT / pulmonary embolism |
| Neurologic | peripheral neuropathy · Parkinson's disease and other movement disorders · seizures |
| Infectious | severe infection resulting in hospitalization · lower respiratory / lung infection |
| Other | thrombocytopenia · anaemia |

`safety_events.csv` carries these as 23 rows (`OPEN_QUESTIONS.md` Q36). Plus,
for the subgroup stratifications and the secondary-malignancy objective:

| concept | source section |
|---|---|
| Lung parenchymal disease (COPD, asthma, bronchiectasis, emphysema) | §7.2.3 |
| Neuropathy, as a baseline-history subgroup flag | §7.2.3, Table 1 row 3 |
| Secondary malignancy, 10 categories | §7.2.4, Table 2 |
| All-cause inpatient hospitalisation | §7.3.2 - `CONFINEMENT`, no code list needed |
| MM-related hospitalisation | §7.8.1 - MM diagnosis in **first or second position**, read with `mm_dx.csv` |
| Emergency visits | §7.3.2 - **construction not specified**, `DATA_MAPPING.md` §6 |

### From Annex 7 - frailty

The **Kim 2018 claims-based frailty index**: its variable list, the code lists
behind each variable, and its coefficients. The protocol marks frailty
provisional, pending data and mapping, so it may be dropped - but if it is kept,
Annex 7 is the only source.

### Not from any annex - Charlson

The **Quan 2011** Charlson Comorbidity Index: ICD-9-CM **and** ICD-10 code lists
for all 17 conditions. The protocol cites Quan et al. 2011 in its reference list
but carries no annex for it, so the codes can be authored from the published
paper. The weights and hierarchy are already in `charlson_quan2011.csv` (§4); the
MM adjustment is made on the codes in `mm_dx.csv`, not by zeroing a condition
(`MODULES.md` "The MM adjustment is made on the codes").

## 3. Existing lists that need widening

| file | why |
|---|---|
| `mm_dx.csv` | the broad 203.x / C90.x codes outside the `.0` family, if the outpatient arm of I1 is meant to use them (`OPEN_QUESTIONS.md` Q2) |
| `cl_mma_codelist.csv`, `cl_mma_rollup.csv` | panobinostat and elotuzumab must be on them under their own `CL_MED_ABBR` for the cohort build to bar them from the 1L index and for this package to check it; belantamab is recognised as `BELA` (`NDMM_BELANTAMAB_ABBR`). Annex 2's list may add steroids, which Q6 then decides |

`other_malig.csv` carries 1,643 code rows but 1,618 distinct `tumor_group`
values - a label per code, not a grouping - so pairing on it would reduce to
needing the same exact code twice. The cohort build therefore pairs on the
**first three characters of the ICD code** (C50 breast, C34 lung, C79 secondary
neoplasm), which is what "same primary tumour type and/or metastatic cancer"
asks for (`OTHER_CANCER_PAIR_GRAIN=icd3`).

## 4. The files this package reads

`R/codelists.R` declares eleven files; a name it does not declare cannot be
loaded. `codelists/` ships every one of them with the right columns and **no
codes**, so the folder is complete on its own and a run pointed at it fails
loudly rather than reading an empty definition. `CODELIST_DIR` blank means that
directory; on production set it to the real one (`codelists/README.md`).

| file | required columns | matched against | read by | shipped with | codes come from |
|---|---|---|---|---|---|
| `mm_dx.csv` | `dx`, `icd_family` | `MED_DIAGNOSIS.DIAG` | `comorbidity` (the MM adjustment), `hcru` (MM-related hospitalisation), `malignancy` (to refuse a myeloma code), `periods` under `DX_DATE_SOURCE=baseline_first_claim` | header only | production (§1) |
| `cl_mma_rollup.csv` | `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR` | — | the `COHORT_INDEX_EXCLUSIONS` check, which resolves agent names to abbreviations; an unusable file leaves that check logged as unverified | header only | production (§1) |
| `cl_mma_codelist.csv` | `CL_CODE_TYPE`, `CL_CODE`, `CL_MEDICATION_FULL`, `CL_MED_CLASS`, `CL_MED_ABBR` | — | declared, read by no module here | header only | production (§1) |
| `cl_sct_codelist.csv` | `CL_CODE_TYPE`, `CL_CODE`, `SCT_TYPE` | — | declared, read by no module here | header only | production (§1) |
| `charlson_quan2011.csv` | `condition`, `weight`, `code_type`, `code`, `icd_family`; optional `supersedes` | `MED_DIAGNOSIS.DIAG` over the comorbidity baseline | `comorbidity` | **Quan's 17 conditions, weights and hierarchy** | Quan et al. 2011 |
| `safety_events.csv` | `condition`, `domain`, `acute_chronic`, `code_type`, `code`, `icd_family`; optional `setting` | `MED_DIAGNOSIS.DIAG`; `setting=inpatient` rows only on claims carrying a `CONF_ID` | `safety` | **all 23 rows**, with domain, the protocol's acute/chronic typing and `setting` | Annex 3 |
| `secondary_malig.csv` | `category`, `subtype`, `code_type`, `code`, `icd_family` | `MED_DIAGNOSIS.DIAG` | `malignancy` | **Table 2's ten categories** and their example subtypes | Annex 3 |
| `comorbid_subgroups.csv` | `concept`, `code_type`, `code`, `icd_family` | `MED_DIAGNOSIS.DIAG` over the baseline | `comorbidity` with `COMORBID_SUBGROUPS=TRUE` | `neuropathy`, `lung_parenchymal_disease` | Annex 3 |
| `frailty_kim2018.csv` | `variable`, `coefficient`, `code_type`, `code`, `icd_family` | `MED_DIAGNOSIS.DIAG` | `comorbidity` with `FRAILTY=TRUE` | header only | Annex 7 |
| `hcru.csv` | `concept`, `code_type`, `code` | `MEDICAL.RVNU_CD` / `POS` / `PROC_CD` by `code_type` `RVNU` / `POS` / `CPT` | `hcru` | three `ED_VISIT` rows, one per construction | no annex - the ED construction is undecided (`OPEN_QUESTIONS.md` Q11) |
| `soc_regimen_categories.csv` | `line_scope`, `soc_category`, `CL_MED_ABBR`, `role` | the agents of `LOT_BASE_MEDS` | `soc` | **§7.2.2's categories**, both line scopes | Annex 2 |

The code column is `code`, except `dx` in `mm_dx.csv`, `CL_CODE` in the two
`cl_*_codelist` files and `CL_MED_ABBR` in `cl_mma_rollup.csv` and
`soc_regimen_categories.csv`. The diagnosis-matched lists join on the normalised
code and the ICD family; their `code_type` is carried but does not select a
source, and `frailty_kim2018.csv` refuses any `code_type` other than `ICD9DIAG` /
`ICD10DIAG`.

**Every load checks** that the file is one the package declares, that the
required columns are there, that it has data rows, that no row has a blank code
column (the unfilled-row guard, which names the concepts on those rows), and
that every `icd_family` is recognised. Each list a run reads is recorded in
`S_RUN_METADATA.CODELISTS` with its md5 and row count.

**Each module's own check**, run by the preflight before the connection opens:

- `safety_events.csv` - every condition §7.8.1 names as chronic is typed
  chronic; a value naming both acute and chronic is resolved by §7.8.1's chronic
  list or stops; `setting` is `any`, `inpatient` or blank (`any`); a condition
  whose name says hospitalisation must be `inpatient`; one domain, type and
  setting per condition; the suffix ` (hospitalisation)` and the name
  `(any in domain)` are reserved for the series the module derives.
- `secondary_malig.csv` - no code that `mm_dx.csv` names as myeloma.
- `soc_regimen_categories.csv` - every `soc_category` is one of §7.2.2's and
  `line_scope` is `1L` or `LATER`. `role = backbone` marks the anti-CD38
  backbone agent a category name claims.
- `hcru.csv` - `ED_VISIT` rows exist for every code type `ED_DEFINITION` asks for.
- `charlson_quan2011.csv` - a `weight` column.
- `frailty_kim2018.csv` - no `intercept` row, since every row is matched to a
  diagnosis code.

**Notes on the filled content.**

- `charlson_quan2011.csv`'s weights are Quan's published ones - including **0 for
  myocardial infarction**, the 2011 revision's weight - and `supersedes` carries
  his hierarchy: severe liver disease over mild, diabetes with complications over
  without, metastatic solid tumour over any malignancy. Without that column a
  patient with both liver conditions scores 6 where Quan gives 4.
- `safety_events.csv` types `toxic_liver_disease` and `hepatic_failure`
  **"Acute or chronic"** and **"Acute/Chronic"**, the protocol's own wording, and
  §7.8.1's chronic list resolves neither, so the safety module stops on them
  until they are typed. Counted as acute, every recurrence is an event and no
  patient ever leaves the denominator; counted as chronic, only the first
  occurrence counts and a prior history removes the patient from both
  (`OPEN_QUESTIONS.md` Q36).
- `severe_infection_resulting_in_hospitalisation` is `setting=inpatient`: it is
  read only from diagnoses on medical claims carrying a confinement id that
  `CONFINEMENT` knows (business rule 14), dated at the admission. Every `any`
  chronic condition also gets a derived `<condition> (hospitalisation)` series -
  its admissions, typed acute - which is Figure 3's note.
- `hcru.csv` covers emergency visits only. All-cause hospitalisation uses
  `CONFINEMENT`, the same inpatient definition as the cohort, so cohort and
  outcome cannot drift.
- `soc_regimen_categories.csv` keys on `CL_MED_ABBR`, not on a regimen string, so
  a new combination is categorised by its agents. Which category wins when a
  regimen's agents map to more than one is this package's own precedence,
  `SOC_PRECEDENCE` in `R/modules/05_soc.R`: modality before size, `Other` last.

`../tests/fixtures/codelists/` carries filled miniatures of all eleven files for
the test suite. Those are dummy codes chosen to exercise the loader and the SQL,
not codes to run a study on, and nothing outside `tests/` reads them.

## 5. What to ask for

Annex numbers follow the **body text** of the protocol (§7.3.2 and §7.8.5 both cite
Annex 3 for code lists). Its Table of Contents disagrees and calls the code lists
Annex 5 - say which you mean when you ask (`OPEN_QUESTIONS.md` Q20).

In one message to the study team (`OPEN_QUESTIONS.md` Q15):

1. **Annex 2** - eligible/expected MM therapies and the SOC regimen categorisation.
2. **Annex 3** - the ICD-10-CM code lists for every Table 3 condition, the
   secondary malignancy categories, the subgroup conditions, and the
   healthcare-utilisation definitions.
3. **Annex 7** - the Kim CFI algorithm and its code lists, or confirmation that
   frailty is dropped.

`charlson_quan2011.csv`'s codes need no annex - they come from the published Quan
2011 paper - and `hcru.csv` is blocked on a decision rather than a document
(`OPEN_QUESTIONS.md` Q11).
