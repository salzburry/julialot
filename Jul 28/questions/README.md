# Questions

What the study team asked, and the scripts that answered it.

## Layout

| | |
|---|---|
| `asked/` | the questions as they were sent, and the specs and comments that came with them |
| `*_qs.R` | the scripts that answered them, against a finished LOT run |
| `_setup.R` | shared setup — points the scripts at the `lot` package's modules |

These were asked of the NDMM cohort, and that is what each script runs over.
Two answers need a second run named explicitly — POMA Q3's association needs
a broad-cohort LOT run, and the clinical-trial and other-cancer flags come from
the build that wrote them. Both are covered below, and both say so rather than
answering from the wrong place.

## Running one

```
DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
  INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  Rscript questions/lot1_studyteam_qs.R
```

`INPUT_COHORT_TABLE` is the **whole** physical name, prefix included — that is
how LOT takes it, since the cohort is named by whoever built it. Several
questions read it for observation windows, index dates and the raw-claim
bounds, so it is required rather than defaulted; blank used to resolve to a
name that was only the schema, and those sections warned and ran unbounded.

`OBJECT_PREFIX` is **required** and names the run being asked about. Blank would
ask for unprefixed tables — usually nothing, but if an older unprefixed table is
sitting in the schema these scripts would read it and answer confidently about a
different study. A run that genuinely had no prefix says so with
`QS_ALLOW_NO_PREFIX=TRUE`.

Nothing here writes to the warehouse.

## They use the `lot` package's modules, not their own

`_setup.R` sources `load_inputs.R`, `config_lot.R`, `codelists_lot.R`,
`db_utils_lot.R` and `line_criteria.R` from `../lot/R`, so `cdm_src()`, the
naming helpers, the code-list loaders and the line criteria have one definition
rather than a second copy that can drift.

Two things needed bridging.

`config_lot.R` builds `cfg_defaults` out of environment variables **at the
moment it is sourced**, so `config.csv` has to be loaded first or every setting
falls back to its hardcoded default and these scripts describe a run configured
differently from the one they are reading. `qs_setup()` loads them in the order
the build does.

`config_lot.R` then leaves the build to pin a config, so sourcing it alone
leaves no `cfg` and the first table lookup stops with "No LOT config".
`qs_setup()` does what the build does — resolves the work schema, checks it is a
schema name, requires the prefix — and `set_lot_config()` puts `cfg` where these
scripts read it from.

## Table names carry the prefix

Every table these scripts read is a build's own output: `LOT_LONG` and
`MAP_STACKED` from `lot`, `NDMM_FLAGS_ALL` from the cohort build. All of them
carry the prefix — of the build that wrote them, which is not always this run's
(see the trial flags and Q3's broad run below).

`wrk()` does **not** add it — in this package the cohort table is named by
whoever built it, so the caller passes the whole name and `wrk()` only prepends
catalog and schema. `qs_tbl()` is what these scripts use, and it prefixes.

`tests/test_setup.R` fails if any script calls `wrk()` again.

## One population, chosen once

`qs_population()` decides what every question runs over. Default
**`LOT_LONG_FINAL`** — the study population, after the line criteria.

```
LOT_POPULATION=PRECRITERIA   # the same run BEFORE the line criteria
```

That is the only axis left. The scripts used to switch between two *cohorts* —
a full LOT run and an NDMM-filtered copy persisted beside it — and that
arrangement is gone: the LOT run is over the cohort already, so its output under
this prefix **is** the study population, and a different cohort is a different
prefix and a separate invocation. `LOT_COHORT` stops the run and says so rather
than being quietly reinterpreted.

Pre-criteria is worth asking for when the question is what a criterion cost. It
is not a cohort, and a denominator taken from it counts patients the study
removed.

## Q3's broad-cohort question needs a broad-cohort run

`poma_studyteam_qs.R` Q3 has two halves. The NDMM audit runs on this cohort and
must come back zero. The **association** — whether POMA use tracks with another
cancer — is a broad-population question, and one prefix is one cohort: this
cohort has already excluded patients with a qualifying other cancer, so
answering it from this run would be near-zero by construction and mean nothing.

Set `BROAD_PREFIX` to the prefix of a LOT run over the broad cohort. Without it
that half is skipped and says so; the audit still runs.

Its index dates come from that run's own `LOT_PATIENT_INPUT`, not from this
cohort. Taking them from here would drop every broad patient the NDMM
exclusions removed out of the index join — they would stay in the denominator
and never match a diagnosis, reading as having no other cancer, which is the
opposite of the population the question recovers.

## The trial flags are not the cohort build's flags

The two builds write different tables, and they are **not** alternate names for
one contract.

`NDMM_FLAGS_ALL` is the cohort build's exclusion audit — CE, prior therapy,
other cancer, pregnancy, belantamab — one row per patient on `PATID`. It has no
`INDEX_DATE`, no `OTHER_MALIGN_FLAG` and no `CLINTRIAL_*`.

The other-cancer and clinical-trial flags live in the broad build's
`ELIG_COH_ALLFLAGS`, which has a row per **candidate** index date, with
`ELIG_COH_FINAL` saying which candidate that build selected. Both are needed,
and both must come from the same build.

Pointing a trial question at `NDMM_FLAGS_ALL` is worse than a missing table: it
is readable, so a `readable()` guard passes, and the query then stops on an
unresolved column part way through the workbook. `qs_trial_flags_ready()`
therefore checks the **columns**, and names the missing ones instead.

```
TRIAL_PREFIX=overall_    # the prefix of the build that wrote the flags
```

Blank falls back to this run's prefix, which is right when the cohort came from
the broad build itself. Otherwise the flags carry that build's prefix, not this
run's, so it has to be named.

Aligning those flags to the NDMM cohort does not work either, and fails
quietly: the broad build's index is a diagnosis-based candidate, while
`NDMM_COHORT.INDEX_DATE` is the LOT1 start. The join would match almost nothing
and read as nobody being flagged. So the flags join to their **own**
`ELIG_COH_FINAL`, and the LOT population restricts the result by `PATID`. The
consequence is stated on the Q4 tab: baseline there means pre-diagnosis-index,
not pre-LOT1.

## The cohort table is checked against the run

`INPUT_COHORT_TABLE` is validated as a name, which stops the blank that used to
resolve to just the schema. That does not stop a valid name for the wrong
cohort, and the questions bound their answers by the cohort's observation
windows and index dates — so the wrong one answers about a run it never saw.

`qs_check_run_binding()` compares it with what the LOT build recorded in
`LOT_BUILD_STATUS` for this prefix, and stops on a mismatch. A status table
that cannot be read warns instead: an older run may predate it, and refusing to
answer would be worse than saying the binding is unverified.

## A criterion that removes patients changes what a question can be asked of

`MAP_STACKED` is built before the line criteria, so it still holds every
patient's drug exposure. `no_belantamab` is patient-level and truncates, so
`LOT_LONG_FINAL` holds **none** of an affected patient's lines.

Ask the Blenrep question across both and the two halves disagree by
construction: a count of exposed patients, and a by-line table that is empty.
Read as "the exposure never joined a regimen" that is a mapping bug; the real
reason is that the study removed those patients on purpose.

So the by-line half reads `LOT_LONG_ALLFLAGS` — the same run before the
truncate, with each criterion's flag alongside — and says how many patients
were cut. `qs_truncating_criteria()` gets the criteria and their flag names
from the `lot` package and this run's `APPLY_*` settings, so a renamed flag
cannot leave a hardcoded string here matching nothing and reporting zero.

## Q5's two anchors are one anchor

The cohort sets `INDEX_DATE` to `LOT1_START_DT`. So POMA Q5's index-anchored
columns sit on the same date as its LOT1-anchored ones: they are a **longer
look-back on the same anchor**, running back to the start of the covering
enrollment span, not a second window before the diagnosis.

They used to be labelled as the latter. Two counts that look independent get
added together, and a residual-blind-spot probe that overlaps the window it is
supposed to reach past is not one. The columns are now named for what they
measure — `ce_gt_6mo_pre_index`, `len_thal_gt_6mo_pre_index` — and the
narrative says not to add them to the 12-month figures.

The computation was always right; only the label was wrong. Keeping it has a
second use: because the anchors are the same date,
`poma_1l_with_index_span` diverging from `poma_1l_with_lot1_span` means the
cohort's index and the LOT run's LOT1 start no longer agree.

## The steroid code list comes from production

`steroid_codes.csv` is read from `CODELIST_DIR`, the same directory the LOT
build reads its four from, and its md5 goes into the note beside every steroid
answer — the file is production and can be re-issued, so a count quoted from it
means little without the version that produced it.

A hash that cannot be taken stops the steroid questions rather than recording
`unknown` and answering anyway, and the file is hashed again after the read so
a version re-issued mid-run is caught. That is what `codelists_lot.R` does for
the four the build reads, and for the same reason: the count gets quoted either
way.

It is deliberately **not** added to `CODELIST_FILES`. That list drives
`record_codelist_hashes()`, which stops the LOT build when a listed file has no
hash, and the LOT build never loads steroids — naming it there would break a
build that has nothing to do with this question.

## Bone metastasis

`poma_studyteam_qs.R` removes MM-adjacent conditions from its de-confounded
broad-cohort analysis, and it takes that decision from
`<prefix>NDMM_OTHER_MALIG_CODES` — the code list as the cohort build resolved
it, with `is_mm_adjacent_override` already applied.

So there is no second list here to keep in step. Secondary neoplasm of bone is
excluded because the build excluded it (`C79.51`, `C79.52` and `198.5` are
metastatic cancer — `nndm/DECISIONS.md` section 4), not because this script
agrees. Rebuilding the list from `other_malig.csv` would mean re-deciding the
rule, which is exactly how the two came to disagree.

## Not verified against the warehouse

`tests/test_setup.R` runs the setup and holds the population, the table names
and the bone-metastasis list to what the build does. What it cannot check is
whether the question SQL returns the same answers as before — nothing here has
been executed against a warehouse.

Treat the first run of each script as a run to check, not a run to quote.

## The files in `asked/`

They are PDFs, spreadsheets and one message thread — the record of what was
asked and when. They are reference material, not inputs: no script reads them,
and nothing in the build does either.
