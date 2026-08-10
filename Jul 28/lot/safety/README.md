# Safety and utilisation code lists

Placeholders for the protocol's key safety events and healthcare utilisation
events. The roster is complete; the codes are not.

```
# what is still missing, against the templates here
Rscript lot/safety/run_safety_codelists.R

# the same, against the filled lists on the mounted path
CODELIST_DIR=/mnt/code/codelist Rscript lot/safety/run_safety_codelists.R
```

Exits non-zero while anything is a placeholder, so it can gate the analysis
rather than let it run on a half-filled list.

## What is here and what is not

| | |
|---|---|
| the roster | `R/codelists_safety.R`. Which conditions the protocol measures - Table 2's twenty-three, in five domains - and Table 3's utilisation events. |
| the shape | `codelists/*.csv`. Column names, the controlled vocabularies, and one row per condition with the code cell empty. |
| the codes | not here, and not in this repository. |

The split is deliberate. The protocol says WHICH conditions are measured and
that is settled, so it is in version control where a condition cannot leave the
study by leaving a spreadsheet. The annex and the Optum documentation say WHICH
CODES each condition is, and that is not settled, so it lives where every other
code list lives - a CSV on `CODELIST_DIR`, hashed before and after each read so
a run records the version it used.

Filling one is adding rows to the CSV, not deciding what to measure. One row per
code, repeating the condition name.

## Why an empty list has to refuse

A condition with no codes matches no claim. Its rate comes out zero - and a zero
rate is a finding, not an error, so nothing downstream can tell it from a real
one. That is the failure this package exists to prevent, so an unfilled
condition stops the read and names itself rather than returning no rows.

The same reasoning covers three quieter versions of it, all checked:

* a `code_type` nothing joins to;
* an `icd_family` spelled a way the family join does not recognise - the join is
  on family as well as code, so `ICD-10` and `ICD10` are not interchangeable
  unless both are named, and the cohort build names both;
* an `ICD_DIAG` row with no family at all.

Each matches nothing and none of them errors on its own.

## Matched to the Optum fields this study already reads

`code_type` is a controlled vocabulary, and it is drawn from the fields the
cohort build already queries rather than from the data dictionary at large. A
code type nothing joins to is the silent-zero above wearing a different hat.

| `code_type` | lands on |
|---|---|
| `ICD_DIAG` | the diagnosis table's code, with `icd_family` |
| `POS` | medical claim `POS` |
| `TOS_CD` | medical claim `TOS_CD` |
| `CONFINEMENT` | the confinement table - `CONF_ID` is an admission, `ADMIT_DATE`/`DISCH_DATE` the stay |
| `REV_CD` | revenue code. **Not read by this study today** |
| `PROC` | CPT/HCPCS. **Not read by this study today** |

`hcru_events.csv` ships filled for all-cause inpatient admission, and the codes
in it are not new: `POS` 21/51/61, `TOS_CD` `FAC_IP.ACUTE` / `FAC_IP.REHSNF` /
`FAC_IP.SNF` / `PROF.INPVIS`, or a valid `CONF_ID`. That is the same rule
`ndmm/R/steps/00_mm_cohort.R` uses for `line_inpatient`, copied rather than
re-derived, so the study cannot end up with two definitions of an inpatient stay
- one for the cohort and another for the utilisation outcome.

Length of stay is `ADMIT_DATE` to `DISCH_DATE` from the confinement table, per
visit, assigned to the period the admit falls in. The protocol asks for exactly
that, including a stay that begins before 1L baseline and overlaps into it.

## What is outstanding, and what it needs

| | needs |
|---|---|
| the twenty-three conditions' codes | the protocol's Annex 3 / Annex 5 |
| MM-related inpatient stay | a decision on which diagnosis position makes a stay MM-related |
| ER visit | the `POS` / `TOS_CD` / revenue codes that identify one |
| `REV_CD`, `PROC` | confirmation from the data dictionary that the fields are available, and which table carries them |

The last three are business-rule questions rather than code-list questions: they
decide what counts, not which codes spell it.
