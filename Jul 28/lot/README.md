# LOT

Lines of therapy, built once and run per cohort.

## Status: ported, not yet run

`R/steps/` holds the whole build - LOT1 (MMA claims, MAP, base regimen, SCT,
end date) and LOT2 onwards up to `LOT_LONG`, one row per patient per line.
All of it ported line for line from the validated source.

`tests/test_same_as_source.R` proves that: every phase is compared against
`apr_30_2026/02_lot1.R`, `lot2_5_inputs.R` and `lot2_5_base.R`, and the
executable R and SQL must match exactly apart from the one change the port is
allowed to make - LOT's outputs carry the cohort prefix.

Comments are compared out, so the copied review-diary comments could be tidied
without weakening the check. Change a code line and it fails; change a comment
and it does not.

For the three files that carry safety guards, each approved deviation is named
and undone one at a time - then the two sides must be **identical**. Adding an
unapproved line fails, and deleting an approved guard leaves its entry with
nothing to remove, which is reported. An earlier version asked only that every
source line still be present somewhere, which let an inserted second `WHERE`
clause through.

Three places deliberately differ from the source, all the same defect: the
code lists filter on the raw value but store the normalized one, so a
punctuation-only code survives as `""` - and the claim side turns a missing
code into `""` too, so the two match. For NDC both sides pad to eleven zeros.
The port drops codes that normalize to blank, de-duplicates the lists, and
requires digits on both NDC joins. `test_same_as_source.R` marks these as
approved differences and asserts each guard by name.

It has never been run against Databricks. Nothing here is validated output
until it has been, and compared with the source build patient for patient.

The folder is self-contained - the only outside dependencies are the R
packages `DBI`, `odbc` and `glue`, and no file resolves a path outside it.
`tests/test_selfcontained.R` checks that, so it cannot quietly stop being true.

## Run it

```
DATABRICKS_PWD=... Rscript build.R <COHORT_TABLE> <prefix_>
DATABRICKS_PWD=... Rscript build.R MY_COH_FINAL mystudy_
```

Or set `INPUT_COHORT_TABLE` and `OBJECT_PREFIX` instead of passing them.

## Running it for another cohort

Point it at a different table with a different prefix. Nothing in the folder
changes - it names no cohort of its own, and `tests/test_selfcontained.R`
keeps it that way.

```
Rscript build.R STUDY_A_FINAL study_a_
Rscript build.R STUDY_B_FINAL study_b_
```

The prefix is what keeps the two apart: LOT's own outputs go through
`lot_out()`, which prepends it, so `study_a_LOT1_BASE` and `study_b_LOT1_BASE`
sit side by side in one schema. The cohort table itself goes through `wrk()`
unprefixed, because the cohort build already named it. A run with no prefix is
rejected rather than allowed to overwrite another one.

### What a cohort table has to provide

`PATID`, `INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`, `DEATH_DT`, `GDR_CD`, `YRDOB`,
`AGE_INDEX_YR`, `FU_DAYS`, `FU_DAYS_CE`.

The build checks the real table before it starts: the columns, and also one row
per patient, no null `PATID`/`INDEX_DATE`/`ENDDATE`, and `ENDDATE` on or after
`INDEX_DATE`. The rules read this table row for row, so a repeated patient
would multiply their claims and their lines. `ENDDATE_CE` may be null.

## Extra criteria on a line

LOT is defined by the rules in `R/steps`. If a study needs to require something
more of a line - any line, not only L1 - add it to `LINE_CRITERIA` in
`R/line_criteria.R` instead of editing those rules:

```r
list(
  name    = "l2_started_on_med",
  label   = "L2 started on a drug, not a transplant",
  lines   = 2L,                        # 1L, c(2L, 3L), or "*" for every line
  flag    = "L2_START_IS_MED",
  sql     = "LOT_START_TYPE = 'MED'",  # any expression over lot_long
  on_fail = "flag"
)
```

Then turn it on with `APPLY_L2_STARTED_ON_MED,TRUE` in `config.csv`. Any value
other than `TRUE` or `FALSE` stops the build rather than quietly leaving the
criterion off.

Two tables come out of every run, whether or not any criterion is declared.
Both are real tables: Spark will not create a persistent view over a temporary
one, and these are built from temp views.

- `<prefix>LOT_LONG_ALLFLAGS` - every criterion as a 0/1 column, computed
  whether or not it is enabled. Check what a criterion would cost before
  turning it on.
- `<prefix>LOT_LONG_FINAL` - the enabled ones applied.

`on_fail` decides what a failing line does:

| value | effect |
|---|---|
| `flag` | column only, nothing removed - a true no-op |
| `truncate` | that line and every later line for the patient go |

`flag` is the default and may be left out, so a new criterion cannot change a
result until someone deliberately chooses otherwise. `truncate` is the only
removal mode offered, because LOT N is defined against LOT N-1: dropping a
middle line would leave L1 next to L3. Anything more is left until a real
criterion needs it.

Two rules worth knowing:

- A line the criterion is not asked of **passes**. It is not applicable, not a
  failure - otherwise a criterion aimed at L2 would fail every L1.
- A predicate that evaluates to NULL **fails**. Unknown is not evidence the
  line qualifies.

## The production code lists

Four files, read from `CODELIST_DIR`, named in `R/codelists_lot.R`:

```
cl_mma_rollup.csv  cl_mma_codelist.csv  permissible_subs.csv  cl_sct_codelist.csv
```

They live outside git, so each is hashed before and after being read and the
md5 goes in the run log. That is the only record of which version built a given
set of tables - keep the log with the results. A file that changes mid-read
stops the build rather than being recorded under the wrong hash.

Four consistency checks stop the build, because each one silently changes who
counts as treated:

| check | what it would do |
|---|---|
| a code-list med with no rollup row | extracted with no class, so the steroid and maintenance rules miss it |
| a rollup med with no codes | never matched, so patients on it look untreated |
| a code type other than NDC or HCPCS | sits in the list and matches nothing |
| one abbreviation with two classes | `min()` picks one without saying so |

Four more stop the build because `DISTINCT` cannot see them:

- a code naming more than one medication - extraction joins on the code alone,
  so one claim becomes two treatments
- an all-zero NDC, which pads to the same eleven zeros as a claim with no NDC
- a rollup medication defined two ways: `DISTINCT` removes identical rows, but
  two rows for one drug that disagree on a flag both survive, and the
  enrichment joins on the abbreviation alone
- a blank medication or class, which would make the checks above meaningless

Each check groups by the key extraction actually joins on, not the stored one.
That matters for NDC: the join pads to eleven digits, so `123456789` and
`0123456789` are one key there and would look like two here.

The SCT list is checked the same way - one code, one transplant type - and
again ignoring the code type, because the `med_procedure` join accepts
`ICD10PROC`, `ICD9PROC` or `HCPCS` against the same column.

### Steroids

Steroids are maintained separately, so their codes are not in
`cl_mma_codelist.csv`. Both places that build `mma_rollup` drop them too:

```sql
upper(trim(coalesce(CL_MED_CLASS, ''))) <> 'STEROID'
```

The `trim` matters: the projection trims the class but the raw column does
not, so a padded `' STEROID '` would otherwise slip through.

The file itself should not list them either. `Jul 28/tools/remove_steroids_from_rollup.R`
makes that edit on the server, keeping every remaining line byte for byte and
reporting the md5 before and after. Run it without arguments first - it reports
and changes nothing. The SQL filter stays afterwards as a defensive guard.

Without the filter the rollup lists medications whose codes are deliberately absent,
`uncoded_meds` fires on every run, and LOT1 builds always-zero
`LOT1_MED_<steroid>` columns that `LOT_LONG` does not carry. `build_lot2_5()`
already filtered this way when discovering meds and classes and its comment
claimed LOT1 did the same - now it does.

Nothing about who counts as treated changes: every join into the rollup is
keyed on a medication abbreviation that comes from the code list, and the code
list has no steroids. So no waiver is needed for this.

### Waivers

Per check, not one switch, and only for something the study team has looked at:

```
CODELIST_WAIVERS=code_types
```

Names: `orphan_meds`, `uncoded_meds`, `code_types`, `multi_class`,
`code_to_med`, `bad_ndc`. Unknown names are rejected, and whatever was waived
is recorded in `LOT_BUILD_STATUS`.

## Running LOT2-5 on its own

`prepare_lot_inputs()` rebuilds what LOT2-5 needs in a session where LOT1 did
not run. It used to hold its own copies of the code-list, cohort and SCT SQL -
"the same SQL LOT1 uses", except the copies drifted: the code-list guards never
reached them, and its cohort view ignored `censor_at_disenrollment` entirely.

It calls the LOT1 phases now, and holds only what is genuinely different -
rebinding the tables LOT1 persisted, and materializing the SCT views. Every
step is defined exactly once, and `tests/test_selfcontained.R` fails if that
stops being true.

`phase_sct()` stops at the SCT date views; LOT1's own `lot1_sct` summary is
`phase_lot1_sct()`, which needs `lot1_base` and so is not part of the rebuild.

## Why the run materializes the SCT views

LOT1 leaves `sct_claims_raw`, `tx_auto_dates` and `tx_allo_cart_dates` as views
over raw medical, procedure and diagnosis. LOT2-5 reads them once per line, so
left alone Spark re-runs those scans every time - the source puts it at roughly
8 AUTO aggregates and 20 SCT scans across LOT2..LOT5.

`prepare_lot_inputs()` exists for a fresh session: it rebuilds those views and
then materializes them. In a combined run the rebuild is work LOT1 already did,
so the run does only the half that matters - materialize what is already there
and repoint the views at the tables. `sct_claims_raw` goes first, so the other
two write from a table instead of re-running the CDM scan.

Whether the views exist is asked of the catalogue (`SHOW VIEWS`), not by
selecting from them: a `SELECT 1` on a lazy view runs the view, which is the
cost being avoided. If the catalogue cannot answer, the run rebuilds - slower,
but never wrong.

Each materialization logs its own duration, so the first run says what this
actually costs rather than leaving it an assumption.

## Knowing a run finished

LOT1's tables are replaced before LOT2-5 starts, so a failure in between would
leave new LOT1 output beside an older `LOT_LONG`. Every run therefore writes
`<prefix>LOT_BUILD_STATUS`: `started` at the beginning, then `complete`, or
`failed` if it stops anywhere. Read that before trusting a set of tables.

LOT1 is checked too, before LOT2-5 starts: MAP ending before it starts, a MAP
end that is not the later runout, LOT1 ending after observation, an AUTO
transplant flagged both tandem and single, and an AUTO before LOT1 began. The
QC phase reports these and carries on; these stop the build.

`LOT_LONG` is checked before anything is derived from it and before the run is
called complete:

- no duplicate `(PATID, LOT_NUM)`
- no line ending before it starts
- no line number outside `1..MAX_LOT`
- every patient's lines running `1..n` with no gaps
- each line starting strictly after the previous one ended
- no line ending after the patient's observation

The last two are the chain the iterative builder is supposed to produce: every
LOT N candidate is taken strictly after the previous line's end, and every
branch of the end-date rule is bounded by `OBS_END_DT`. So neither can fail
unless something went wrong upstream. All of them stop the build rather than
printing a warning.

`LOT_LONG_FINAL` inherits these: `truncate` is the only removal mode, and it
drops a trailing run of lines per patient, so what is left is a prefix of a
chain that already passed.

## Tests

```
Rscript tests/test_runner.R          # cohort input, contract, settings
Rscript tests/test_line_criteria.R   # the per-line criteria layer
Rscript tests/test_selfcontained.R   # no outside paths, everything resolves
Rscript tests/test_same_as_source.R  # the steps match apr_30_2026 exactly
```

No warehouse needed. They run offline; `glue` is stubbed if absent. The last
one skips when `apr_30_2026` is not beside this folder, so a copied-out package
still runs green.

## Layout

```
build.R              entry point, takes a cohort table and prefix
config.csv           pinned settings, no cohort named here
R/build_lot.R        CONTRACT, cohort input, guards
R/config_lot.R       settings
R/db_utils_lot.R     logging, retry, naming (wrk / lot_out)
R/codelists_lot.R    code list loading
R/line_criteria.R    per-line criteria
R/load_inputs.R      config.csv reader
R/steps/             the rules, in order:
  01_codelists.R       code lists, and the rollup consistency checks
  02_patient_input.R   the cohort, and OBS_END_DT
  03_mma_map.R         MM/steroid claims, then Medication Available Period
  04_lot1_base.R       LOT1 start, induction meds, base regimen
  05_sct.R             transplant dates: AUTO, ALLO, CAR-T
  06_lot1_end.R        LOT1 end date and reason
  07_qc.R              QC counts
  08_persist.R         write the LOT1 outputs, all prefixed
  05b_lot1_sct.R       LOT1's SCT summary (needs lot1_base)
  09_lot2_5_inputs.R   rebuild for a fresh-session LOT2-5 run
  10_lot2_5_base.R     LOT2 onwards, and LOT_LONG
```
