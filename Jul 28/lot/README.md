# LOT

Lines of therapy, built once and run per cohort.

## Status: ported, not yet run

`R/steps/` holds the whole build - LOT1 (MMA claims, MAP, base regimen, SCT,
end date) and LOT2 onwards up to `LOT_LONG`, one row per patient per line.
All of it ported line for line from the validated source.

`tests/test_same_as_source.R` proves that: the nine LOT1 phases are compared
against line ranges of `apr_30_2026/02_lot1.R`, and `10_lot2_5_base.R` against
the whole of `lot2_5_base.R`. The executable R and SQL must match exactly.

One deviation is allowed everywhere - LOT's own outputs carry the cohort
prefix - and beyond that three files carry named safety guards, described
below. `09_lot2_5_inputs.R` is deliberately not compared: it no longer holds a
copy of the source's SQL, it calls the LOT1 phases, so what it used to carry is
checked as part of those.

Comments are compared out, so the copied review-diary comments could be tidied
without weakening the check. Change a code line and it fails; change a comment
and it does not.

For the three files that carry safety guards, each approved deviation is named
and undone one at a time - then the two sides must be **identical**. Adding an
unapproved line fails, and deleting an approved deviation - a guard line, an
edited line, or a whole added block - leaves its entry with nothing to remove,
which is reported. Both halves have been wrong before: an earlier version asked
only that every source line still be present somewhere, which let an inserted
second `WHERE` clause through, and the added blocks were not reported at all,
so deleting one whole read as a perfect match.

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

Three consistency checks are reviewable - they stop the build unless named in
`CODELIST_WAIVERS`, because each has a reading a study team can accept:

| check | what it would do |
|---|---|
| a code-list med with no rollup row | extracted, and classed, but with no rollup flags, so the maintenance and conditioning rules miss it |
| a rollup med with no codes | never matched, so patients on it look untreated |
| a code type other than NDC or HCPCS | sits in the list and matches nothing |

All of these ask only about rows extraction can reach. Every join in
`03_mma_map` is `ON c.CL_CODE_TYPE = 'NDC'` or `'HCPCS'`, so the checks read a
view of the code list filtered to those two. A medication coded only as ICD
otherwise looked coded while producing nothing, and an unused ICD code naming
two drugs failed the build over a row nothing joins. `code_types` keeps the
whole list - reporting the unread types is its job.

These stop the build outright, because `DISTINCT` cannot see them and none has
a reading worth accepting:

- one abbreviation with two classes - `min()` picks one lexically, and nothing
  downstream says which

- a code naming more than one medication - extraction joins on the code alone,
  so one claim becomes two treatments
- an all-zero NDC, which pads to the same eleven zeros as a claim with no NDC
- a rollup medication defined two ways: `DISTINCT` removes identical rows, but
  two rows for one drug that disagree on a flag both survive, and the
  enrichment joins on the abbreviation alone
- a blank medication or class, which would make the checks above meaningless
- a medication or class whose name would not survive being turned into a column:
  `sanitize_col` maps punctuation and spaces to `_`, so `CAR-T` and `CAR T`
  produce one column between them, and the value goes into a SQL string literal
  as it stands, so an apostrophe closes it early. LOT2-5 builds its columns the
  same way from the same rollup, so one check covers both.

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
makes that edit on the server. Run it without arguments first - it reports and
changes nothing. The SQL filter stays afterwards as a defensive guard.

It is a governed file shared with `apr_30_2026`, so the script is built to be
boring about it. The file is handled as raw bytes and whole lines are sliced
out of it, so every kept row - its quoting, spacing and line ending - goes back
out unchanged. The new bytes are written beside the original, given the
original's mode, and replace it by rename - so it is either the old file or the
new one and never a half-written one, and a shared file does not quietly lose
group write to the umask.

It also checks its own premise instead of asserting it: the rows are only safe
to remove because a steroid has no codes, so it refuses unless
`cl_mma_codelist.csv` is present, has a `CL_MED_CLASS` column to judge on,
carries none of the abbreviations being removed, and has no `STEROID` rows of
its own. It refuses too if the edit would leave fewer medications than
`01_codelists.R` requires.

Both files' md5s are printed and re-checked immediately before the rename, so
an edit landing in either one while the script runs stops it: a change to the
rollup would be discarded by the replacement, and a change to the code list
could make the premise untrue after it was checked. `Jul 28/tools/tests/`
covers all of that, including the byte-for-byte claim and both mid-run edits.

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

Waivable, because each has a reading the study team can accept - a medication
deliberately kept in a separate file, a code type this study does not use, a
substitution left inactive, a ten-digit NDC in a documented layout:

`orphan_meds`, `uncoded_meds`, `code_types`, `subs_substitute`,
`subs_original`, `ndc_short`.

Not waivable, because each means a claim counted twice, a code matching every
claim with no NDC, a medication with no class, or an output column that is
always zero - conditions to correct in the code list, not to accept:

`code_to_med`, `bad_ndc`, `rollup_defs`, `blank_keys`, `ndc_shape`,
`multi_class`, `class_agreement`.

Naming one of the second group is refused before the build starts, and told
why rather than "no such check". Refusing at startup is not enough on its own -
LOT2-5 can be run in a session of its own and reach the code lists without
that check - so the waiver list itself drops them too. Unknown names are
rejected. `LOT_BUILD_STATUS` records both `CODELIST_WAIVERS_REQUESTED`, the
list the run was given, and `CODELIST_WAIVERS_APPLIED`, the checks that
actually fired and were waived - a run can ask for a waiver on a condition the
code lists do not have, and only the second says what was really in them.

`multi_class` was briefly reviewable and is not. `min(MED_CLASS)` in
`03_mma_map` picks lexically, not clinically, and the choice reaches the class
flags and the steroid exclusion. Worse, `class_agreement` used to skip
medications that were internally ambiguous - so waiving `multi_class` left such
a medication checked by neither. `class_agreement` now compares the whole set
and skips nothing, and `multi_class` is fatal, so the gap is closed from both
sides. A study that genuinely needs two classes for one drug needs a stated
priority rule, not a waiver around `min()`.

The SCT checks in `05_sct.R` are on neither list. They stop the build
outright, because each one means a transplant is being counted twice or not at
all, and there is no version of that a run should carry on through.

Run with none of them set first. A check that fires is evidence about the
production code lists, to look at - not a reason to turn the rest on.

### Substitutions

`permissible_subs.csv` names two medications per row by abbreviation. The
substitute is unioned straight into the regimen and then matched against
`map_stacked` on `MED_ABBR`, so an abbreviation the code list never produces
matches nothing - the substitution rule quietly does not fire, and a typo
looks exactly like a drug with no claims. Both sides are checked against
`mma_codelist`: `subs_substitute` for the one that enters a regimen,
`subs_original` for the one that is only ever matched against.

### NDC shape

**The code lists must carry canonical eleven-digit NDCs.** The join pads
whatever digits it finds to eleven:

```sql
lpad(regexp_replace(CL_CODE, '[^0-9]', ''), 11, '0')
```

`bad_ndc` catches the all-zero result, which is what a claim with no NDC looks
like. Two more checks enforce the contract, separately because they need
different answers.

`ndc_shape` is for codes that cannot be an NDC in any form: letters (storage
strips punctuation but not letters, so `ABC123` arrives as `00000000123`), more
than eleven digits, fewer than ten. Fix the code list.

`ndc_short` is for ten-digit codes, and it is the subtle one. Ten digits is a
real FDA form, but one of three layouts - 4-4-2, 5-3-2 or 5-4-1 - and the
eleven-digit form is made by inserting the zero into the *short* segment, not
at the far left. `50242-040-62` is 5-3-2, so it becomes `50242004062`; the
blanket left-pad produces `05024204062`, which is a different key. S01 strips
the separators, so by the time anything can look at the code the layout is
unrecoverable - the conversion has to happen in the file, not here. Waive
`ndc_short` only once the study team has confirmed the ten-digit entries are
4-4-2, which is the one layout the pad gets right.

The two are separate names so that accepting a documented short representation
does not also accept `ABC123`.

### Class agreement

`multi_class` looks inside the code list. The two files also have to agree with
each other, and they disagree silently: every claim carries `CL_MED_CLASS` from
the **code list**, while the `LOT1_CLASS_<x>` columns are named from the classes
of the **rollup**. A medication the two spell differently gets a column named
for one spelling and values that only ever hold the other, so the column is
always zero. `class_agreement` compares them on the medications both files
carry - a medication in only one is `orphan_meds` or `uncoded_meds`, and
steroids are absent from the rollup by design.

### Transplant types

`S11` maps the spellings it knows - `ALLO%`, `AUTO%`, `CAR-T` and friends -
and passes anything else through unchanged. Nothing downstream selects
anything but `AUTO`, `ALLO` and `CART`, so an unmapped spelling is not an
error anywhere, it simply never matches and those transplants stop existing.
The build now stops on any `SCT_TYPE` outside those three and `UNKNOWN`, which
is a deliberate bucket nothing reads.

The same `CASE` has the same hole on `CL_CODE_TYPE`, and it is checked the same
way. The claim joins read exactly `HCPCS`, `ICD10PROC`, `ICD9PROC`,
`ICD10DIAG` and `ICD9DIAG`; anything else - including a blank type, which the
MM code list filters out and this one does not - sits in the view matching
nothing.

Accepted is not the same as right. The `'%PROC%'` arm sits *after* the exact
`ICD9PROC` test, so `ICD9PROCEDURE`, `ICD-9-PROC` and `ICD9 PROC` all come out
as `ICD10PROC` - which the check above accepts, because `ICD10PROC` is a real
type - and the claim join then reads ICD-10 columns for an ICD-9 code. A third
check asks the raw value instead: a code type naming 9 that is not one of the
spellings the `CASE` turns into an ICD-9 type stops the build.

None of these is waivable: a code type no branch reads, or one read as the
wrong ICD version, cannot produce a transplant, so there is no version of it
worth carrying on through.

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
- no line with a null start or end date
- no line ending before it starts
- no line number outside `1..MAX_LOT`
- every patient's lines running `1..n` with no gaps
- each line starting strictly after the previous one ended
- no line ending after the patient's observation

The null check comes first because it is what makes the others meaningful.
Every one of them compares dates, and a comparison with `NULL` is unknown
rather than true - so before it was added, a line with no start or no end
passed all of them.

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
  05b_lot1_sct.R       LOT1's SCT summary (needs lot1_base)
  06_lot1_end.R        LOT1 end date and reason
  07_qc.R              QC counts
  08_persist.R         write the LOT1 outputs, all prefixed
  09_lot2_5_inputs.R   rebuild for a fresh-session LOT2-5 run
  10_lot2_5_base.R     LOT2 onwards, and LOT_LONG
```
