# Questions

What the study team asked, and the scripts that answered it.

## Layout

| | |
|---|---|
| `*_qs.R` | the scripts that answered them, against a finished LOT run |
| `*.md` | an ask recorded against the build, where the answer is a decision rather than a number |
| `_setup.R` | shared setup - points the scripts at the engine's modules |
| `broad_studyteam_qs.R` | the two questions NDMM cannot answer, over a broad cohort |

`melphalan_lot_rule.md` is the one document: a proposed rule for when a
melphalan administration advances the line, set beside what the build does
today, branch by branch. It changes line counts in both directions, so it is
recorded with the query that sizes it rather than implemented.

Every script here is NDMM-only and reads one run's own tables - except
`broad_studyteam_qs.R`, which exists precisely because two of the asks cannot be
answered on this cohort at all.

## Running one

```
DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
  INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  Rscript lot/questions/lot1_studyteam_qs.R
```

`INPUT_COHORT_TABLE` is the whole physical name, prefix included - that is
how LOT takes it, since the cohort is named by whoever built it. Several
questions read it for observation windows, index dates and the raw-claim
bounds, so it is required rather than defaulted: a blank resolves to a name
that is only the schema, and those sections would warn and run unbounded.

`OBJECT_PREFIX` is required and names the run being asked about. Blank would
ask for unprefixed tables - usually nothing, but if an older unprefixed table is
sitting in the schema these scripts would read it and answer confidently about a
different study. A run that genuinely had no prefix says so with
`QS_ALLOW_NO_PREFIX=TRUE`.

Nothing here writes to the warehouse.

## They use the engine's modules, not their own

`_setup.R` sources `load_inputs.R`, `config_lot.R`, `codelists_lot.R`,
`db_utils_lot.R` and `line_criteria.R` from `../engine/R`, so `cdm_src()`, the
naming helpers, the code-list loaders and the line criteria have one definition
rather than a second copy that can drift.

Two things needed bridging.

`config_lot.R` builds `cfg_defaults` out of environment variables at the
moment it is sourced, so `config.csv` has to be loaded first or every setting
falls back to its hardcoded default and these scripts describe a run configured
differently from the one they are reading. `qs_setup()` loads them in the order
the build does.

`config_lot.R` then leaves the build to pin a config, so sourcing it alone
leaves no `cfg` and the first table lookup stops with "No LOT config".
`qs_setup()` does what the build does - resolves the work schema, checks it is a
schema name, requires the prefix - and `set_lot_config()` puts `cfg` where these
scripts read it from.

## Table names carry the prefix

Every table these scripts read is a build's own output: `LOT_LONG` and
`MAP_STACKED` from `lot`, `NDMM_FLAGS_ALL` from the cohort build. All of them
carry the prefix - of the build that wrote them, which is not always this run's
(see the trial flags and Q3's broad run below).

`wrk()` does not add it - in this package the cohort table is named by
whoever built it, so the caller passes the whole name and `wrk()` only prepends
catalog and schema. `qs_tbl()` is what these scripts use, and it prefixes.

`tests/test_setup.R` fails if any script calls `wrk()` again.

## One population, chosen once

`qs_population()` decides what every question runs over. Default
`LOT_LONG_FINAL` - the study population, after the line criteria.

```
LOT_POPULATION=PRECRITERIA   # the same run BEFORE the line criteria
```

That is the only axis. There is no second cohort to switch between: the LOT run
is over the cohort already, so its output under this prefix is the study
population, and a different cohort is a different prefix and a separate
invocation. `LOT_COHORT` stops the run and says so rather
than being quietly reinterpreted.

Pre-criteria is worth asking for when the question is what a criterion cost. It
is not a cohort, and a denominator taken from it counts patients the study
removed.

## What NDMM cannot answer, and where it went

Two of the asks need a population this cohort does not have. They are in
`broad_studyteam_qs.R`, not as sections that skip inside a workbook about a
different cohort.

The other-cancer association. "Does POMA use track with another cancer" needs
patients who have another cancer. NDMM excluded them by construction, so
measured here it is zero against zero - a tautology, not a finding.
`NDMM_FLAGS_ALL` does carry `NO_OTHER_CANCER_PRE_LOT1`, but it is an exclusion
criterion and is 1 for everybody inside the cohort, so it is no substitute.
What stays in `poma_studyteam_qs.R` is the audit: that rate must be 0, and a
non-zero value is a build bug.

The diagnosis-anchored trial flags, and `OTHER_MALIGN_FLAG` with them. Those
belong to the broad build's cohort and its own index. The prior-therapy question
is answered on this cohort by `NDMM_CLINTRIAL_FLAGS` (below); the broad pair
cannot answer it, and is kept only for `OTHER_MALIGN_FLAG`, which has no
1L-anchored equivalent.

The split is what removes the cross-cohort overlap machinery. Each script now
denominates on the population it is about, so there is no match rate to police
inside either one.

```
BROAD_PREFIX=overall_ TRIAL_PREFIX=overall_ Rscript lot/questions/broad_studyteam_qs.R
```

Without `BROAD_PREFIX` the association says so and skips; the rest of that
script still runs. `tests/test_setup.R` fails if any other script reads the
broad flags.

## The trial flags are not the cohort build's flags

The two builds write different tables, and they are not alternate names for
one contract.

`NDMM_FLAGS_ALL` is the cohort build's exclusion audit - CE, prior therapy,
other cancer, pregnancy, belantamab - one row per patient on `PATID`. It has no
`INDEX_DATE`, no `OTHER_MALIGN_FLAG` and no `CLINTRIAL_*`.

The other-cancer and clinical-trial flags live in the broad build's
`ELIG_COH_ALLFLAGS`, which has a row per candidate index date, with
`ELIG_COH_FINAL` saying which candidate that build selected. Both are needed,
and both must come from the same build.

Pointing a trial question at `NDMM_FLAGS_ALL` is worse than a missing table: it
is readable, so a `readable()` guard passes, and the query then stops on an
unresolved column part way through the workbook. `qs_trial_flags_ready()`
therefore checks the columns, and names the missing ones instead.

```
TRIAL_PREFIX=overall_                  # prefix of the build that wrote the flags
TRIAL_INDEX_TABLE=OVERALL_COH_FINAL    # that build's final cohort table (the default)
```

Two settings, because the two tables are named differently.
`ELIG_COH_ALLFLAGS` is a checkpoint, so that build writes it through its
prefixing helper and it comes out `overall_ELIG_COH_ALLFLAGS`. The final cohort
is not a checkpoint: `08_assembly.R` persists it straight from that build's
`FINAL_TABLE_NAME` with no prefix at all, and `overall/config.csv` sets that to
`OVERALL_COH_FINAL`. Deriving `<prefix>ELIG_COH_FINAL` asks for a table the
build never writes.

`TRIAL_PREFIX` blank falls back to this run's prefix, which is right when the
cohort came from the broad build itself.

Aligning those flags to the NDMM cohort does not work either, and fails
quietly: the broad build's index is a diagnosis-based candidate, while
`NDMM_COHORT.INDEX_DATE` is the LOT1 start. The join would match almost nothing
and read as nobody being flagged. So the flags join to their own final
cohort table, and the LOT population restricts the result by `PATID`.

### The question it could not answer, now answered elsewhere

The diagnosis-anchored flags never could say whether trial therapy preceded the
1L start - baseline ends before that index, follow-up starts there and runs past
1L, and the stretch in between is in neither. So the cohort build now produces
`NDMM_CLINTRIAL_FLAGS`, whose windows are cut at the 1L start and which carries
`CLINTRIAL_DX_TO_LOT1` as its own column (`ndmm/README.md`).

Q4 reads it when it is there and headlines it, with the diagnosis-anchored
table kept beside it as context. `lot1_studyteam_qs.R` Q1c reads the same
table, so the two workbooks cannot give different trial numbers for the same
POMA-1L patients.

It is checked for provenance, not just for its columns. The cohort build
writes it before its own cohort table, its attrition and its `complete`
status, so a rerun can replace it and then fail - leaving a well-formed table
from an attempt that never finished. A rerun that does finish replaces it
under the same prefix and the same physical name, which the LOT run-binding
check, comparing that name, cannot see. So it is matched against
`COHORT_RUN_ID` / `COHORT_STAMP` - what LOT recorded reading - and against
`NDMM_BUILD_STATUS`.

Evidence, not proof. A trial code identifies neither the study drug nor
the condition treated, so a positive is a patient to review, not a proven
prior line, and a zero does not establish that none occurred. The
diagnosis-to-1L interval also varies from days to years between patients, so
the fixed 12-month window is the more comparable figure across groups - the
tab says to read the two together. One prefix, one cohort - no overlap to report
and no second index to reconcile, so a LOT1 patient with no row is a broken
join and is counted as `missing_flag_rows` rather than read as a clean patient.

A cohort built before that table existed still gets the old view, labelled for
what it is. Everything below applies to that path.

### The build behind them has to have finished

The flags and the final cohort are separate writes. A run that stopped
between them leaves two tables that are individually readable and carry every
column, describing different attempts - the column check cannot see that.

So `qs_trial_build_state()` reads `<TRIAL_PREFIX>build_status` first. That
build writes it with `CREATE OR REPLACE`, so it holds one row and that row is
the last run on the prefix; anything but `complete` skips the trial sections
rather than answering from a mixed pair. `QS_IGNORE_TRIAL_BUILD_STATE=TRUE`
overrides when you know it failed before writing either. No status table warns
and continues - an older build predates it.

That row also records `final_table_name`, which settles `TRIAL_INDEX_TABLE`
properly: the default comes from a config file this package does not read, so a
disagreement names the table that build actually wrote instead of leaving you to
guess.

The two builds do not agree on column case - LOT writes `STATE`, the broad build
`state` - so both status tables are read case-insensitively. A bare `d$STATE`
returns `NULL` on the lower-case one, which reads as no state recorded rather
than as looking in the wrong place.

### What that costs, stated on the tab

The flag build is a different cohort - different index, study end, baseline
window and criteria - so some NDMM LOT1 patients simply are not in it. Q4
therefore keeps the full NDMM group as `n_pts` and reports `n_matched` /
`pct_matched` beside it, with every rate over `n_matched`. An inner join would
have dropped the unmatched patients silently, and a loss falling differently on
POMA and other-1L would make the rates a comparison of who is in the second
cohort. If `pct_matched` differs much between the groups, that row is the
finding.

And neither flag brackets the window the prior-therapy question needs.
`CLINTRIAL_BASELINE` runs to the day before that build's diagnosis index, so it
misses the whole diagnosis-to-LOT1 stretch; `CLINTRIAL_FOLLOWUP` starts on that
index and runs past LOT1, so it mixes pre-LOT1 with post-treatment evidence.
Q4 says so and headlines neither - answering "was POMA-at-LOT1 really first
line" needs trial timing relative to LOT1, which these two summary flags do not
carry.

## The cohort table is checked against the run

`INPUT_COHORT_TABLE` is validated as a name, which stops a blank from resolving
to just the schema. That does not stop a valid name for the wrong
cohort, and the questions bound their answers by the cohort's observation
windows and index dates - so the wrong one answers about a run it never saw.

`qs_check_run_binding()` compares it with what the LOT build recorded in
`LOT_BUILD_STATUS` for this prefix, and stops on a mismatch. A status table
that cannot be read warns instead: an older run may predate it, and refusing to
answer would be worse than saying the binding is unverified.

Every script calls it, not just the two that read flag tables. All five
bound raw-claim windows by `INPUT_COHORT_TABLE`, and all five read tables a
newer failed run may have replaced - a guard three scripts skip is a guard that
protects two workbooks and leaves three quoting the same wrong numbers.

It reads the latest row, whatever state it reached - not the latest
`complete` one. LOT replaces `LOT_LONG_FINAL` before it validates it, so a
rerun that replaced it and then failed leaves its own table on disk while the
previous run's complete row still looks like the newest good one. Filtering to
completed runs would bind these answers to a run whose tables have since been
overwritten, which is the case the guard exists for. An unfinished latest run
stops the script; `QS_IGNORE_BUILD_STATE=TRUE` overrides when you know it failed
before writing anything. The dashboard resolves ownership the same way.

## A criterion that removes patients changes what a question can be asked of

`MAP_STACKED` is built before the line criteria, so it still holds every
patient's drug exposure. `no_belantamab` is patient-level and truncates, so
`LOT_LONG_FINAL` holds none of an affected patient's lines.

Ask the Blenrep question across both and the two halves disagree by
construction: a count of exposed patients, and a by-line table that is empty.
Read as "the exposure never joined a regimen" that is a mapping bug; the real
reason is that the study removed those patients on purpose.

So the by-line half reads `LOT_LONG_ALLFLAGS` - the same run before the
truncate, with each criterion's flag alongside - and says how many patients
were cut. `qs_truncating_criteria()` gets the criteria and their flag names
from the `lot` package and this run's `APPLY_*` settings, so a renamed flag
cannot leave a hardcoded string here matching nothing and reporting zero.

## Q5's two anchors are one anchor

The cohort sets `INDEX_DATE` to `LOT1_START_DT`. So POMA Q5's index-anchored
columns sit on the same date as its LOT1-anchored ones: they are a longer
look-back on the same anchor, running back to the start of the covering
enrollment span, not a second window before the diagnosis.

Labelling them as the latter invites two counts that look independent being
added together, and a residual-blind-spot probe that overlaps the window it is
supposed to reach past is not one. The columns are named for what they
measure - `ce_gt_6mo_pre_index`, `len_thal_gt_6mo_pre_index` - and the
narrative says not to add them to the 12-month figures.

The computation was always right; only the label was wrong. Keeping it has a
second use: because the anchors are the same date,
`poma_1l_with_index_span` diverging from `poma_1l_with_lot1_span` means the
cohort's index and the LOT run's LOT1 start no longer agree.

## The steroid code list comes from production

`steroid_codes.csv` is read from `CODELIST_DIR`, the same directory the LOT
build reads its four from, and its md5 goes into the note beside every steroid
answer - the file is production and can be re-issued, so a count quoted from it
means little without the version that produced it.

A hash that cannot be taken stops the steroid questions rather than recording
`unknown` and answering anyway, and the file is hashed again after the read so
a version re-issued mid-run is caught. That is what `codelists_lot.R` does for
the four the build reads, and for the same reason: the count gets quoted either
way.

Nothing here tells anyone to edit it. Emptying `steroid_codes.csv` would
drop steroids from the descriptive outputs, but it is production - the same
directory the LOT build reads its four from - so it edits what other studies
read and what the recorded md5s mean, and it does not switch the displays off
cleanly anyway: the steroid sections become unavailable rather than showing
zero. The workbook says so explicitly, because anyone who has already done it
needs to know what it did.

It is deliberately not added to `CODELIST_FILES`. That list drives
`record_codelist_hashes()`, which stops the LOT build when a listed file has no
hash, and the LOT build never loads steroids - naming it there would break a
build that has nothing to do with this question.

## An unknown ICD family matches neither

`qs_icd_family_sql()` reads a raw claim's `ICD_FLAG` the way the cohort builds
do: `ICD9` for the ICD-9 spellings, `ICD10` for the ICD-10 ones, NULL for
anything else - blank, missing, or a spelling nobody expected.

Reading "not one of the ICD-9 spellings" as ICD-10 would class a genuine ICD-9
claim with a blank flag as ICD-10, where it then fails the family join silently
- so the workbook can count an other-cancer diagnosis the cohort build
deliberately did not. `raw_icd_flag` is a waivable check in the cohort build,
so a run can legitimately carry unrecognised flags, and that is exactly when
the two rules disagree.

The spellings live in `ndmm/R/codelists.R`, which this package cannot source -
it defines its own `load_codelist_csv()` and would replace `lot`'s. So they are
repeated here, and `tests/test_setup.R` parses that file and fails if the two
lists ever differ.

## Bone metastasis

`poma_studyteam_qs.R` removes MM-adjacent conditions from its de-confounded
broad-cohort analysis, and it takes that decision from
`<prefix>NDMM_OTHER_MALIG_CODES` - the code list as the cohort build resolved
it, with `is_mm_adjacent_override` already applied.

So there is no second list here to keep in step. Secondary neoplasm of bone is
excluded because the build excluded it (`C79.51`, `C79.52` and `198.5` are
metastatic cancer - `ndmm/DECISIONS.md` section 4), not because this script
agrees. Rebuilding the list from `other_malig.csv` would mean re-deciding the
rule, which is exactly how the two came to disagree.

## Not verified against the warehouse

`tests/test_setup.R` runs the setup and holds the population, the table names
and the bone-metastasis list to what the build does. It checks the ground each
question stands on, not the answers: what a question's SQL returns is not
something a test without a warehouse can hold.
