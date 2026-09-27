# Running the dashboard on Domino

Two pieces: a **Job** builds the scenarios and exports them to a snapshot, an
**App** serves the snapshot. What the app shows is `DASHBOARD.md`; this file is
the deployment steps and the controls the code cannot enforce.

## 0. Compute environment (once)

R plus `shiny`. Nothing else is required to serve the App — the plots are base
graphics and the Kaplan–Meier estimator is written out.

```r
install.packages("shiny")
install.packages("survival")   # optional: only the test cross-check uses it
install.packages(c("DBI", "odbc"))   # only for the Job, and for DASH_SOURCE=warehouse
install.packages("sparklyr")          # only if SPARK_METHOD names a Spark session instead of the ODBC DSN
```

Bake them into the environment's Dockerfile so the App starts fast.

## 1. Smoke test with no data

Deploy the App with nothing set. It comes up on synthetic scenarios and says so
on every page. This proves the environment, the launcher and the port before
any warehouse question is involved.

## 2. Build the scenarios — Domino **Job**

Run the cohort build and the LOT build first (`../README.md`), then:

```bash
export DATABRICKS_PWD=...              # a Domino secret, never a config file
export PROJECT_WORK_SCHEMA=...
export INPUT_COHORT_TABLE=ndmm_NDMM_COHORT     # what the study run reads -
export LOT_PREFIX=ndmm_                        #   the same three step 3 of
export COHORT_PREFIX=ndmm_                     #   ../README.md was given
export CODELIST_DIR=/mnt/code/codelist
export DASH_SNAPSHOT_DIR=/mnt/data/NDMM        # a Domino Dataset, mounted under /mnt/data
Rscript dashboard/jobs/build_scenarios.R       # from wherever the folders sit
```

`build_scenarios.R [scenarios.csv] [out_dir]` takes the grid and the snapshot
root as optional arguments; they default to `dashboard/scenarios.csv` and
`DASH_SNAPSHOT_DIR`.

**One row of `scenarios.csv` is one full study run.** `prefix` is the
`OBJECT_PREFIX` it writes under - unique, compared without case, and letters,
digits, `.`, `_` and `-` only, since it also names a directory. Every other
upper-case column is set as an environment variable for that run and nothing
else, so **the column name is the variable name** and a new open question is
available the moment the package reads it. A value that is itself a list, such
as `ED_DEFINITION`'s `revenue,pos`, is quoted in the file. The dashboard's test
suite runs every shipped row through the package's config, so a value the
package would refuse fails there rather than on the cluster.

**What every row reads is the Job's own.** `INPUT_COHORT_TABLE`, `LOT_PREFIX`
and `COHORT_PREFIX` come from the Job's environment (or a column of the same
name); without any of them the Job stops before the first build and names what
is missing, since a read prefix left blank would be each scenario's own.
Without `CODELIST_DIR`, every module whose code list is still the shipped blank
template is left out of every scenario. Anything else step 3 was given -
`LOT_CODE_MD5`, `MODULES`, `SKIP_MODULES` - is set on the Job too.

The Job connects exactly as the study run does - the study package's own
`connect_db()`, on `DATABRICKS_DSN` and `DATABRICKS_PWD` - and reads where it
wrote: `WORK_SCHEMA`, else `PROJECT_WORK_SCHEMA`, else the Domino user's own
schema, in `DATABRICKS_CATALOG`. `DASH_WORK_SCHEMA` and `DASH_CATALOG` are the
**App's** overrides, not the Job's.

**Each scenario runs in its own R process**, and one that fails does not stop
the others. The summary at the end lists each scenario as built or failed and
exported or not, and the Job exits non-zero if any failed.

**What is exported.** Each scenario's tables go to
`<DASH_SNAPSHOT_DIR>/<prefix>/<TABLE>.csv`, and the LOT build's to
`<DASH_SNAPSHOT_DIR>/lot/<LOT_RUN_ID>.<build>/<TABLE>.csv` - filed by run **and
build**, not by scenario, because scenarios normally share one LOT run and the
engine can build one run id more than once. A build already exported is
reused, and the LOT prefix is copied only while its newest status row is the
build the scenario read.

- A scenario is exported only from a `complete` run, pinned before its first
  table is read and checked again after its last; a rebuild in between stops
  the export.
- Only the tables that run's own metadata says it wrote, with only the rows of
  the cohorts it selected: what an earlier run left under the prefix stays out.
  A run that recorded no modules or no cohorts exports nothing.
- A run whose release record is not `none` is not exported
  (**Deployment controls** below).
- The tables are staged and the scenario's directory swapped whole, so a
  refresh that fails leaves the previous snapshot in place. A refresh *killed*
  mid-swap leaves the previous snapshot set aside under a name no reader lists,
  and the next export puts it back, or discards it where the swap had
  completed, before it starts.
- One export at a time into a root: an `.export.lock` directory refuses a
  second Job, and one left by a killed Job is removed by hand, as its message
  says.

Re-run the Job on each data refresh; the App reads the new snapshot on
restart. Cost: one full study run per scenario — start with two or three rows,
and add rows as questions come up.

## 3. Publish the dashboard — Domino **App**

Domino launches the App command from the **project root** and expects the
process on `0.0.0.0:8888`; `app.sh` does that. Set the App command to `bash
<folders>/dashboard/app.sh`, giving the path from the project root to wherever
the four folders sit. `app.sh` changes to the folder above `dashboard/`
itself, so nothing else depends on where that is.

Set the App's environment variables:

```
DASH_SOURCE=snapshot
DASH_SNAPSHOT_DIR=/mnt/data/NDMM
DASH_ALLOW_SYNTHETIC=FALSE
```

`DASH_ALLOW_SYNTHETIC=FALSE` makes an App left on synthetic numbers refuse to
start and say why, so nobody quotes generated data because a default was left
in place. A snapshot directory that is missing or empty lists no scenarios; it
never falls back to synthetic data.

The **Tables** tab fills the table shells from the `TFLS/` folder beside
`dashboard/`; where that folder sits somewhere else, `DASH_TFLS_DIR` names it.
Without it, that one tab says so and every other tab is unaffected.

**The snapshot lives in a Domino Dataset**, because an App reads a Dataset it
has attached and does not see another run's artifacts. Create the Dataset
first: the Job does not make one, it writes into whatever is mounted at
`DASH_SNAPSHOT_DIR`, so with no writable Dataset there it writes into the run's
own container, which disappears with it, or fails on a read-only path. Create
or select a writable Dataset in the project, attach it to the Job and to the App
(the Data step of the publish dialog), and point `DASH_SNAPSHOT_DIR` at its
mount.

`/mnt/data/NDMM` is where a **local** Dataset named `NDMM` mounts. A Dataset
imported from another project, or a deployment on a different file system,
mounts elsewhere, so read the mount path off the Data step of the publish
dialog and give `DASH_SNAPSHOT_DIR` that. The Job and the App only have to
agree with each other.

## Deployment controls

These are not visible from inside the app, and each needs a decision rather
than a default.

**The Dataset is as sensitive as the warehouse.** The snapshot job exports
every table the run wrote - the raw ones beside the released ones - because a
table with no released copy has only its raw form and the App needs it. Several
are one row per patient and carry `PATID`. The App drops identifiers and
prefers released copies, but a person with filesystem or project access to the
Dataset is not going through the App. So keep the Dataset **private to the App
and the Job**, and do not hand it out as a published extract.

A shareable extract is not a subset of it. Seven tables have an `S_*_RELEASE`
copy; the rest of what a panel draws — the attrition steps, the demographics,
the line patterns, the time-to-event summaries — has none, so an extract cut
down to the released tables is both **incomplete** for a reader and still
**unsuppressed** wherever it is not. The shareable artefact is the shells:
`TFLS/run_tfls.R` fills them from the run at a floor that may only rise, writes
tables that carry no identifier and no cell under the floor, and applies the
release verdict below, so a table the run says has a recoverable cell is not
filled from at all. Where a raw table itself has to go out, it is a disclosure
review, not a file copy.

**Access to the Dataset is the one control not in the code.** The job writes
the files; who may read them afterwards is set on the Domino Dataset and the
project that owns it. Grant it to the App and the Job and to nobody else, and
re-check it whenever the project's collaborators change — every other control
here is downstream of that one holding. The three overrides
(`SNAPSHOT_ALLOW_RECOVERABLE`, `DASH_ALLOW_RECOVERABLE`,
`TFLS_ALLOW_RECOVERABLE`) are each deliberately settable and each says on the
run that it was set; none of them is a control against someone who can set
environment variables on the Job.

**Keep the two outputs apart.** `TFLS/run_tfls.R` writes to `TFLS/out/` (or
`TFLS_OUT_DIR`), which is not the Dataset and must not be moved into it. The
private snapshot and the shareable tables have different audiences; where they
sit in one directory, the next person to grant access grants both.

**A release that gives a withheld cell away does not leave the warehouse.**
`mod_release()` withholds every cell under the floor, then records in
`S_RUN_METADATA.RELEASE_RECOVERABLE` the groups where one withheld cell is
still the group's total less the published rest, and in
`S_RUN_METADATA.RELEASE_RECOVERABLE_TABLES` the tables those groups are in -
the second is what a refusal is decided on, the first is the sentence a person
reads. The snapshot job refuses to export any run whose record is not `none`:
a finding, `release module did not run`, or no record at all.
`SNAPSHOT_ALLOW_RECOVERABLE=TRUE` exports anyway and logs that it did. Whether
to regroup or withhold a second stratum is the analyst's call; the job only
declines to make it by default.

**A warehouse App is a second way in.** `DASH_SOURCE=warehouse` reads the
tables live, so nothing it shows has been through the job. The App applies the
same verdict on each read; it parts from the job only where the run has no
record, and says so instead:

| the run's record says | the App shows |
|---|---|
| `none` | everything |
| a named finding, e.g. `S_SAFETY_RATES_RELEASE: 3 …` | everything except the tables `RELEASE_RECOVERABLE_TABLES` lists. Where that list is absent or names anything that is not one of the seven released tables, the finding's own text decides: the released tables it names, or all seven where it names none |
| `release module did not run` | everything except the seven that would have had a released copy — they have none, so what is under the prefix is the working table the release was meant to replace |
| nothing at all | everything, with a notice: the snapshot job refuses such a run, and re-exporting through it is what settles it |

`DASH_ALLOW_RECOVERABLE=TRUE` shows the withheld tables anyway and the page
says it is doing so. That is the setting a **single analyst** reading their own
unreleased run wants; it is not one to leave on for a shared App. Prefer the
snapshot for anything more than one analyst: it has been through the job's
check, the App has not.

**Names that reach a query are quoted, not matched.** `DASH_CATALOG`,
`DASH_WORK_SCHEMA`, `DASH_PREFIXES` and `DASH_LOT_PREFIX` reach SQL, so each
goes in backtick-quoted, Spark's delimited identifier: a leading underscore, a
hyphen, an all-digit name or a reserved word reads correctly, and a prefix of
`x; DROP TABLE p; --` is one identifier no warehouse has, so the read finds
nothing instead of running it. What is refused is only what quoting cannot
hold: a backtick of its own, a control character, and an empty name.
`DASH_PREFIXES` is also pasted into a **file path** by a snapshot source, so a
prefix there has to be letters, digits, underscore, dot or hyphen, starting with
a letter or a digit; `TFLS_PREFIX` is held to the same rule for the same reason.

## Reading the warehouse directly instead

`DASH_SOURCE=warehouse` reads the `S_*` tables live from the schema the study
run wrote to (`DASH_WORK_SCHEMA` and `DASH_CATALOG` point it elsewhere).
Scenarios are the tables whose name ends in `S_RUN_METADATA`, filtered by
`DASH_PREFIX_PATTERN` (default `^s223926`) unless `DASH_PREFIXES` lists them.
The connection is the study package's own, over the Databricks ODBC DSN by
default, so the App needs `DATABRICKS_PWD` as well. Add `DASH_LOT_PREFIX` for
the LOT tabs: the study's metadata records which LOT *run* a scenario read, not
where that run wrote, and the prefix's newest status row has to be that run and
build before any of its tables is read, so a prefix pointing at a different one
is caught rather than drawn. The App opens one connection as it starts and every
viewer shares it, re-querying on every control change, so the snapshot is the
better default for anything more than one person.
