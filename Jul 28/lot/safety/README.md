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
| `ICD_DIAG` | `MED_DIAGNOSIS`, with `icd_family` - `ICD_FLAG` is what separates ICD-9 from ICD-10 |
| `PROC` | `MED_PROCEDURE` - CPT/HCPCS `PROC_CD`, or `BILL_PROC_CD` where the client supplied it |
| `POS` | `MEDICAL.POS` - where the service was performed |
| `TOS_CD` | `MEDICAL.TOS_CD` - type of service. `TOS_EXT` is the same at its most specific |
| `CONFINEMENT` | `CONFINEMENT` - one unduplicated row per hospitalisation, and `LOS` is a column |

`REV_CD` is in the vocabulary but is not confirmed queryable. Optum derives
`ICU_IND`, `MATERNITY_IND` and `NEWBORN_IND` from revenue codes, so they exist
upstream, but no table in the dictionary surfaces a column to join on.

Draftable and runnable are different states, and the gap is where this would go
wrong quietly. An **empty** row on such a field is a placeholder and is fine -
it records where the codes will go. A **filled** one is not: it looks exactly
like a finished definition, because it has codes in it, and would read as ready
and then join to nothing. So a filled row on an unconfirmed field stops the
read, and the runner reports the two states separately - `placeholder(s)
drafted on ...` while empty, `*** FILLED against an unconfirmed field` after.
`PROC` is in the same position: a real column, but nothing in this study reads
it yet.

The tables, and how they join, from the business rules: `MEDICAL` to
`MED_DIAGNOSIS` and `MED_PROCEDURE` on `PATID`/`PAT_PLANID` + `CLMID` +
`FST_DT` + `LOC_CD`; `MEDICAL` to `CONFINEMENT` on `PAT_PLANID` + `CONF_ID`;
enrolment on `FST_DT` between `ELIGEFF` and `ELIGEND`. Continuous enrolment
joins on `PATID` and member enrolment on `PAT_PLANID` - not interchangeable.

`hcru_events.csv` ships filled for all-cause inpatient admission. `CONFINEMENT`
is the count: the dictionary describes it as a unique record for every
hospitalisation, with the facility detail bundled into one unduplicated row, so
a row is an admission and no de-duplication of claims is needed to get there.

The claim-level `POS` 21/51/61 and `TOS_CD` `FAC_IP.ACUTE` / `FAC_IP.REHSNF` /
`FAC_IP.SNF` / `PROF.INPVIS` are carried beside it as the fallback, and they are
not new: that is the rule `ndmm/R/steps/00_mm_cohort.R` already uses for
`line_inpatient`, copied rather than re-derived, so the study cannot end up with
one definition of an inpatient stay for the cohort and another for the outcome.
A test reads those codes back out of that step and fails if they drift.

Length of stay is the `LOS` column, which the table already carries -
`ADMIT_DATE` to `DISCH_DATE` is the same span computed by hand. Per visit,
assigned to the period the admit falls in, which is what the protocol asks for,
including a stay that begins before 1L baseline and overlaps into it.

Two other things worth knowing before the safety work starts. The protocol
allows some events to be defined on lab values; `LABRESULT` exists, but the
dictionary says it holds only tests performed within certain laboratory
networks, so a lab-based definition has incomplete capture in a way an
ICD-based one does not - that is a study decision, not a coding one. And
`MEMBER_CONTINUOUS_ENROLLMENT` is already a rollup of spans with less than a
30-day break, which is the protocol's own 30-day gap rule and the build's
`GAP_DAYS`; the three agree, so continuous enrolment needs no separate
treatment here.

## What is outstanding, and what it needs

| | needs |
|---|---|
| the twenty-three conditions' codes | the protocol's Annex 3 / Annex 5 |
| MM-related inpatient stay | a decision on which diagnosis position makes a stay MM-related |
| ER visit | the values on the `POS` and `TOS` tabs of the data dictionary. The field descriptions point at those tabs, but the tabs were not in the copy available when these rows were written, so they are placeholders on `POS` and `TOS_CD`. |
| a revenue-code field | the dictionary surfaces none, but Optum derives ICU/maternity/newborn flags from revenue codes upstream - is one exposed anywhere we can join to? Until then the `REV_CD` row stays empty. |

The last three are business-rule questions rather than code-list questions: they
decide what counts, not which codes spell it.
