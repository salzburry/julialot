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

Its exit status is `safety_codelist()`'s verdict, not a second opinion. The two
used to be decided separately - the loader on everything below, the command on
completeness alone - so the command could print `*** FILLED against an
unconfirmed field` and `Ready.` two lines apart and exit 0 on a list the
analysis could not then read. There is now one function that says why a list is
not fit to measure with; the loader stops on its first line, the command prints
all of them, and a test runs the real command in a real process and fails if the
two ever disagree.

## What is here and what is not

| | |
|---|---|
| the roster | `R/codelists_safety.R`. Which conditions the protocol measures - Table 2's twenty-six, in seven domains - and Table 3's utilisation events. |
| the shape | `codelists/*.csv`. Column names, the controlled vocabularies, precedence, and one row per condition with the code cell empty. |
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

The same reasoning covers the quieter versions of it, all checked:

* a `code_type` nothing joins to, or none at all;
* an `icd_family` spelled a way the family join does not recognise - the join is
  on family as well as code, so `ICD-10` and `ICD10` are not interchangeable
  unless both are named, and the cohort build names both;
* an `ICD_DIAG` row with no family at all;
* a code padded with a space, which is filled by every test and joins to
  nothing - so cells are trimmed on the way in and a cell left empty by
  trimming is empty everywhere, not blank in one check and present in the next;
* a condition or event that parses and measures the wrong thing: filed under
  another domain, relabelled acute, given a measure Table 3 does not ask of it,
  or - the one with no value at all - left blank. A blank makes `!=` return NA
  and NA drops out of the check silently, which is how an unlabelled row came
  to pass a check written to catch a mislabelled one;
* an event name Table 3 does not have. Its rows count towards nothing, so a
  misspelling empties the event it was meant to fill;
* a filled code with no `source_note`, which cannot be checked back against the
  annex - the only way anyone confirms it is right.

Each matches nothing, or matches the wrong thing, and none of them errors on
its own.

## Which rows are the definition, and which the alternative

An event can be identified more than one way, and the ways are not additive. An
admission is a `CONFINEMENT` row or, failing that, a claim carrying an inpatient
`POS` - union them and every admission is counted twice.

So `hcru_events.csv` carries a `precedence` column, `primary` or `fallback`,
required on every filled row. An event with fallback rows and no primary is
refused: a fallback with nothing to fall back from is a second definition of the
event wearing a label that hides it.

Code types are governed per event as well as per file, because a type can be
valid for the file and wrong for the row. `LOS` is a column on `CONFINEMENT` and
on no other table, so a length of stay drafted on `POS` has nothing to measure;
and an ER visit counted off `CONFINEMENT` counts admissions, since a confinement
row is a hospitalisation - the ER visits that became one are in there and the
ones that did not are not. Both parse, both join, and both answer a different
question than the one asked.

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
assigned to the period the admit date falls in.

Assigned by admit date, **with one exception the protocol states outright**: a
stay whose admit falls before 1L baseline but which overlaps 1L baseline is
considered. Table 3, on inpatient length of stay:

> LOS will be calculated per visit, and assigned to the study period in which
> the admit occurred (or if admit occurred prior to 1L baseline but overlapped
> with 1L baseline, it will be considered)

This paragraph previously said the opposite - that such a stay belongs to the
earlier period only - and recorded it as a deliberate choice. It was neither:
the rule has a stated exception and reads as a contradiction only until the
exception is read as one. A wrong rule written down as decided is worse than an
unwritten one, so the wording is corrected here rather than carried as a
divergence.

A stay can extend over several lines; the exception is about 1L baseline
specifically, which is where a patient's first observed stay is most likely to
have begun before the window opened.

Two other things worth knowing before the safety work starts. The protocol
allows some events to be defined on lab values; `LABRESULT` exists, but the
dictionary says it holds only tests performed within certain laboratory
networks, so a lab-based definition has incomplete capture in a way an
ICD-based one does not - that is a study decision, not a coding one. And
`MEMBER_CONTINUOUS_ENROLLMENT` is already a rollup of spans with less than a
30-day break, which is the protocol's own 30-day gap rule and the build's
`GAP_DAYS`; the three agree, so continuous enrolment needs no separate
treatment here.

## Acute and chronic are how a condition is counted, not a label

Table 2 gives every condition an acute/chronic classification, and the protocol
makes it operational rather than descriptive:

* a **chronic** condition counts at its FIRST occurrence only, and stops
  contributing person-time at that point;
* an **acute** condition may occur more than once, and two events of the same
  type have to be separated by a washout.

So `acute_chronic` is not a tidy-up column - it decides both the numerator and
the denominator, and a condition filed under the wrong one is a different
measurement. That is why the roster holds it beside the condition and the read
refuses a row that disagrees with Table 2 or leaves it blank.

**The washout length is an open question, and it is the protocol's own.**
Table 2's footnote says a `>30 day` washout is required; the Objective 2 text
says events of the same type should be separated by `>=30 days`. Those differ
on exactly one day - two events 30 days apart are one event under the first
reading and two under the second. Nobody here should pick; it needs the study
team.

## Which line an event belongs to

Also the protocol's, and also not implemented here yet - recorded so the
extraction is written against it rather than against a reasonable guess:

an event is attributed to a LOT if it falls between that LOT's start date and
the earlier of the next LOT's start date, or the prior LOT's discontinuation
date plus 30 days. An event more than 30 days after discontinuation is **not
counted for that LOT even if the patient later started a subsequent one**.

## What is outstanding, and what it needs

| | needs |
|---|---|
| the twenty-six conditions' codes | the protocol's Annex 3 / Annex 5 |
| `severe_infection_with_hospitalisation` | it is a diagnosis AND a hospitalisation, and `code_type` currently offers only `ICD_DIAG` and `PROC` on the safety file. Which of the two carries the hospitalisation qualifier is a definition question, not a code-list one. |
| `thrombocytopenia`, `anemia` | Table 2 heads these "Other (dependent on data availability)". They are rostered like the rest; whether the data supports them is answered when the codes are run, not by leaving them out. |
| the acute/chronic washout | the protocol says `>30 days` in one place and `>=30 days` in another - see above |
| MM-related inpatient stay | a decision on which diagnosis position makes a stay MM-related |
| ER visit | the values on the `POS` and `TOS` tabs of the data dictionary. The field descriptions point at those tabs, but the tabs were not in the copy available when these rows were written, so they are placeholders on `POS` and `TOS_CD`. |
| a revenue-code field | the dictionary surfaces none, but Optum derives ICU/maternity/newborn flags from revenue codes upstream - is one exposed anywhere we can join to? Until then the `REV_CD` row stays empty. |

The last three are business-rule questions rather than code-list questions: they
decide what counts, not which codes spell it.
