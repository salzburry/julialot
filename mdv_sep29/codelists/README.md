# The MDV code lists

The CSVs here are the **shapes** of the eight code lists: headers, no codes.
The lists themselves live on production, in a folder of their own
(`CODELIST_DIR`, default `/mnt/code/codelist_mdv`), as the Optum lists do.
Each run records the md5 of every list it read.

They are MDV's lists, written in MDV's vocabulary. **The Optum lists cannot be
pointed at**: every HCPCS, CPT, NDC, ICD-9, ICD procedure and revenue-code row
stops the run at the code-type check. A row whose type nothing reads would
otherwise load and match nothing.

## The code types

| type | matched against | used in |
|---|---|---|
| `DISEASECODE` | `diseasedata.diseasecode`, equal after punctuation is stripped and letters upper-cased | every diagnosis list |
| `ICD10` | the ICD-10 column on `diseasedata`, the same way. **Only where the delivery has one** (`MDV_COL_ICD10`); otherwise an ICD10 row stops the run | every diagnosis list |
| `RECEIPTCODE` | `actdata.receiptcode`: a drug given, or a procedure done | drugs, pregnancy, trial, transplant |
| `NAME_ENG` | a `LIKE` pattern over `m_drug.receiptname_eng`, both sides lower-cased, resolved to receipt codes. **Drugs only** | drugs, CAR-T |

`NAME_ENG` is how the OC rules find platinum (`receiptname_eng LIKE
'%platin%'`). It finds new generics and new pack sizes without a list update.
It can also find more than was meant. Every run writes what each pattern
resolved to (`NDMM_MMA_RECEIPTS`, `MMA_RECEIPTS`), and a receipt code that two
patterns give to two different agents stops the run. **Read that table after
the first run.**

## The files

**`mm_dx.csv`**: the MM diagnosis. `code_type, code, icd10`. Every
`DISEASECODE` row needs `icd10`, the ICD-10 code it maps to. An inpatient
diagnosis qualifies only with a strict code (`icd10` starting C90.0), as on
Optum, and an MDV disease code says nothing about that on its own. Carry the
MDV disease codes for C90.0x (multiple myeloma, in remission, in relapse),
plus whatever else the Optum `mm_dx.csv` carries, mapped the same way.

**`other_malig.csv`**: the other-cancer exclusion. `code_type, code, icd10,
tumor_group`. `icd10` groups the outpatient pairs (the three-character
category; C77, C78, C79, C7B and C80.0 are one metastatic group). `tumor_group`
is the label, and **must keep the Optum list's English wording** for the four
plasma-cell labels the override names (`MONOCLONAL GAMMOPATHY`, `SOLITARY
PLASMACYTOMA NOT HAVING ACHIEVED REMISSION`, `PLASMA CELL LEUKEMIA NOT HAVING
ACHIEVED REMISSION`, `EXTRAMEDULLARY PLASMACYTOMA NOT HAVING ACHIEVED
REMISSION`), or the run stops. The simplest route is to map the Optum list's
ICD-10 codes to MDV disease codes and keep its labels.

**`pregnancy.csv`**: `code_type, code`. Pregnancy and delivery diagnoses
(`DISEASECODE` / `ICD10`; the O chapter, Z33, Z34 and others, as on Optum),
and delivery procedures as `RECEIPTCODE`: the receipt codes for K893–K898
(caesarean section and the like) and for delivery care. Japanese claims have
no revenue codes.

**`clintrial.csv`**: `code_type, code`. The trial-examination diagnosis
(Z00.6) by `DISEASECODE` / `ICD10`, and any act that marks trial participation
by `RECEIPTCODE`. The sponsor pays for an investigational drug in Japan, so it
is not on the claim.

**`cl_mma_codelist.csv`**: MM therapy, read by both the cohort and LOT.
`CL_CODE_TYPE, CL_CODE, CL_MEDICATION_FULL, CL_MED_CLASS, CL_MED_ABBR,
CL_ROUTE`.

- `CL_MED_ABBR` and `CL_MED_CLASS` must be **the Optum list's**. The rollup,
  the line rules, the belantamab exclusion (`BELA`), the melphalan rule
  (`MELP`) and the index exclusions all name agents by abbreviation. No space
  inside an abbreviation.
- `CL_ROUTE` is new and required: `ORAL` or `INJ`. It says how long an act
  covers (`../MDV_RULES.md`, section 4). A drug sold in both forms (melphalan,
  cyclophosphamide, dexamethasone) needs a row per form. List it by receipt
  code, or by a pattern narrow enough to name one form.
- A `RECEIPTCODE` is nine digits. Another length stops the LOT build unless
  `receipt_shape` is waived.
- Leave steroids out, as production does on Optum. The cohort build drops them
  by abbreviation anyway, compared trimmed and upper-cased, so `' DEX '` is
  dropped as `DEX` is.
- Carry `PANO` and `ELOT`: the cohort's contract bars both from setting the 1L
  index (protocol I3), and an entry matching no `CL_MED_ABBR` stops the build.

A starting point for `NAME_ENG` rows, to be checked against `m_drug` before
use. One row per agent the Optum rollup names and Japan markets, e.g.
`%bortezomib%`, `%carfilzomib%`, `%ixazomib%`, `%lenalidomide%`,
`%pomalidomide%`, `%thalidomide%`, `%daratumumab%`, `%isatuximab%`,
`%elotuzumab%`, `%panobinostat%`, `%elranatamab%`, `%teclistamab%`,
`%belantamab%`. Agents the rollup names that are not sold in Japan find
nothing. The LOT build reports that as `unresolved_names`, and the run may
waive it once someone has read which agents they are.

**`cl_mma_rollup.csv`**, **`permissible_subs.csv`**: the agents and their
flags, and the biosimilar pairs. They name agents, not codes, so **the Optum
files carry over unchanged**, restricted to the agents the MDV code list
carries if `uncoded_meds` is not to be waived.

**`cl_sct_codelist.csv`**: transplants and CAR-T. `CL_CODE_TYPE, CL_CODE,
SCT_TYPE` (`AUTO`, `ALLO`, `CART`). Autologous and allogeneic stem cell
transplant as the receipt codes of K922 (bone marrow, peripheral blood stem
cell, cord blood; autologous and allogeneic are separate codes). CAR-T as the
product (`NAME_ENG` `%vicleucel%`, `%autoleucel%`, or its receipt code) or as
the CAR-T administration procedure. A `NAME_ENG` pattern here that finds no
drug stops the LOT build (`sct_unresolved_names`, waivable once read): a
misspelt CAR-T pattern would otherwise lose every CAR-T event silently.
Diagnosis codes are accepted, but a
diagnosis is dated to its claim month, and a transplant-status diagnosis
recorded monthly would read as a transplant every month. **Confirm that
`actdata` carries procedures**; the OC rules describe it only as drug
administrations.
