# Safety and utilisation code lists

Placeholders for the protocol's key safety events (Table 2) and healthcare
utilisation events (Table 3). The roster is complete; the codes are not.

```
# what is still missing, against the templates here
Rscript lot/safety/run_safety_codelists.R

# the same, against the filled lists on the mounted path
CODELIST_DIR=/mnt/code/codelist Rscript lot/safety/run_safety_codelists.R
```

Exit status is `safety_codelist()`'s verdict, so the command cannot report ready
on a list the analysis would refuse. One function says why a list is not fit to
measure with: the loader stops on its first reason, the command prints them all,
and a test runs the real command in a real process and fails if the two disagree.

## What is here and what is not

| | |
|---|---|
| the roster | `R/codelists_safety.R`. Table 2's twenty-six conditions in seven domains, and Table 3's four utilisation events. |
| the shape | `codelists/*.csv`. Columns, controlled vocabularies, precedence, one row per condition with the code cell empty. |
| the codes | not here. A CSV on `CODELIST_DIR`, hashed either side of each read. |

The protocol settles WHICH conditions are measured, so the roster is in version
control where a condition cannot leave the study by leaving a spreadsheet. The
annex settles WHICH CODES, which is not settled, so it lives where every other
code list lives. Filling one is adding rows to the CSV. One row per code.

## Why an empty list refuses

A condition with no codes matches no claim, and its rate comes out zero. A zero
rate is a finding, so nothing downstream can tell it from a real one.

The same silent zero arrives several quieter ways, all checked:

* a `code_type` nothing joins to, or none at all;
* an `icd_family` the family join does not recognise - `ICD-10` and `ICD10` are
  not interchangeable unless both are named, and the cohort build names both;
* an `ICD_DIAG` row with no family;
* a code padded with a space, so cells are trimmed on read and a cell emptied by
  trimming is empty everywhere;
* a row that parses and measures the wrong thing - filed under another domain,
  relabelled acute, given a measure Table 3 does not ask of it, or left blank. A
  blank makes `!=` return NA and NA drops out of a check silently;
* an event name Table 3 does not have, whose rows count towards nothing;
* a filled code with no `source_note`, which cannot be checked back against the
  annex.

## Definition and fallback

An event can be identified more than one way and the ways are not additive. An
admission is a `CONFINEMENT` row or, failing that, a claim carrying an inpatient
`POS`; union them and every admission counts twice.

So `hcru_events.csv` carries `precedence`, `primary` or `fallback`, required on
every filled row. An event with fallbacks and no primary is refused, and so is
one whose primary row is still empty - the fallback would become the definition
by default.

Code types are governed per event as well as per file. `LOS` is a column on
`CONFINEMENT` and nowhere else, so a length of stay on `POS` has nothing to
measure. An ER visit counted off `CONFINEMENT` counts admissions instead.

## The Optum fields these land on

| `code_type` | lands on |
|---|---|
| `ICD_DIAG` | `MED_DIAGNOSIS`, with `icd_family` - `ICD_FLAG` separates ICD-9 from ICD-10 |
| `PROC` | `MED_PROCEDURE` - `PROC_CD`, or `BILL_PROC_CD` where the client supplied it |
| `POS` | `MEDICAL.POS` |
| `TOS_CD` | `MEDICAL.TOS_CD`. `TOS_EXT` is the same at its most specific |
| `CONFINEMENT` | `CONFINEMENT` - one unduplicated row per hospitalisation, `LOS` a column |

`REV_CD` is in the vocabulary but not confirmed queryable: Optum derives
`ICU_IND`, `MATERNITY_IND` and `NEWBORN_IND` from revenue codes, but no table in
the dictionary surfaces a column to join on. `PROC` is a real column nothing in
this study reads yet.

Draftable and runnable differ. An **empty** row on such a field is a
placeholder; a **filled** one looks finished and would join to nothing, so it
stops the read. The runner reports the two states separately.

Joins, from the business rules: `MEDICAL` to `MED_DIAGNOSIS` and
`MED_PROCEDURE` on `PATID`/`PAT_PLANID` + `CLMID` + `FST_DT` + `LOC_CD`;
`MEDICAL` to `CONFINEMENT` on `PAT_PLANID` + `CONF_ID`; enrolment on `FST_DT`
between `ELIGEFF` and `ELIGEND`. Continuous enrolment joins on `PATID` and
member enrolment on `PAT_PLANID`.

## What ships filled

All-cause inpatient admission. `CONFINEMENT` is the count - the dictionary
describes one unduplicated record per hospitalisation, so a row is an admission
and no claim de-duplication is needed.

`POS` 21/51/61 and `TOS_CD` `FAC_IP.ACUTE` / `FAC_IP.REHSNF` / `FAC_IP.SNF` /
`PROF.INPVIS` are the fallback, copied from the `line_inpatient` rule in
`ndmm/R/steps/00_mm_cohort.R` rather than re-derived, so the study cannot end up
with one definition of an inpatient stay for the cohort and another for the
outcome. A test reads them back out of that step and fails if they drift.

Length of stay is the `LOS` column. Per visit, assigned to the period the admit
date falls in, **with the exception Table 3 states**: a stay admitted before 1L
baseline that overlaps 1L baseline is considered.

## Acute and chronic decide counting

Table 2's classification is operational, not descriptive. A **chronic**
condition counts at its first occurrence only and stops contributing
person-time. An **acute** one may recur, with a washout between events of the
same type.

The washout length is open, and the ambiguity is the protocol's own: Table 2's
footnote says `>30 days`, the Objective 2 text says `>=30 days`. Two events
exactly 30 days apart are one event under the first and two under the second.
That needs the study team.

## Which line an event belongs to

Also the protocol's, also not implemented here - recorded so the extraction is
written against it rather than a reasonable guess. An event belongs to a LOT if
it falls between that LOT's start and the earlier of the next LOT's start or the
prior LOT's discontinuation plus 30 days. An event more than 30 days after
discontinuation is not counted for that LOT even if a subsequent one began.

## Two things to know before the safety work starts

The protocol allows some events to be defined on lab values. `LABRESULT` holds
only tests performed within certain laboratory networks, so a lab-based
definition has incomplete capture in a way an ICD-based one does not. That is a
study decision, not a coding one.

`MEMBER_CONTINUOUS_ENROLLMENT` is already a rollup of spans with less than a
30-day break, which is the protocol's own gap rule and the build's `GAP_DAYS`.
The three agree, so continuous enrolment needs no separate treatment here.

## Outstanding

| | needs |
|---|---|
| the twenty-six conditions' codes | the protocol's Annex 3 / Annex 5 |
| `severe_infection_with_hospitalisation` | it is a diagnosis AND a hospitalisation. `code_type` offers `ICD_DIAG` and `PROC` on the safety file; which carries the hospitalisation qualifier is a definition question |
| `thrombocytopenia`, `anemia` | Table 2 heads these "Other (dependent on data availability)". Rostered like the rest; availability is answered by running the codes |
| MM-related inpatient stay | which diagnosis position makes a stay MM-related |
| ER visit | the values on the `POS` and `TOS` tabs of the data dictionary, which were not in the copy available when these rows were written |
| a revenue-code field | Optum derives ICU/maternity/newborn flags from revenue codes upstream - is one exposed anywhere we can join to? |
| the acute/chronic washout | `>30` in one place, `>=30` in another |

The last four are business-rule questions, not code-list questions: they decide
what counts, not which codes spell it.
