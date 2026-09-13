# Running the scenario explorer on Domino

Two pieces, the same pattern the LOT pipeline already uses: a **Job** builds
the scenarios, an **App** serves them.

## 0. Compute environment (once)

R plus `shiny`. Nothing else is required — the plots are base graphics and the
Kaplan–Meier estimator is written out, precisely so a missing package cannot
silently produce nothing.

```r
install.packages("shiny")
install.packages("survival")   # optional: only the test cross-check uses it
install.packages(c("DBI", "odbc"))   # only for the Job, and for DASH_SOURCE=warehouse
install.packages("sparklyr")          # only if SPARK_METHOD names a Spark session instead of the ODBC DSN
```

Bake them into the environment's Dockerfile so the App starts fast.

## 1. Smoke test with no data

Deploy the App with nothing set. It comes up on synthetic scenarios and says so
on every page. This is worth doing first: it proves the environment, the
launcher and the port before any warehouse question is involved.

## 2. Build the scenarios — Domino **Job**

Run the cohort build and the LOT build first, then:

```bash
export DATABRICKS_PWD=...              # a Domino secret, never a config file
export INPUT_COHORT_TABLE=ndmm_NDMM_COHORT
export PROJECT_WORK_SCHEMA=...
export DASH_SNAPSHOT_DIR=/mnt/data/NDMM        # a Domino Dataset, mounted under /mnt/data
Rscript dashboard/jobs/build_scenarios.R       # from wherever the folders sit
```

One row of `scenarios.csv` is one run. `prefix` is the `OBJECT_PREFIX` it
writes under; every other upper-case column is set as an environment variable
for that run and nothing else, so **the column name is the variable name** and
a new open question becomes available the moment the package reads it. A value
that is itself a list, such as `ED_DEFINITION`'s `revenue,pos`, is quoted in
the file. The dashboard's test suite runs every row through the package's
config, so a value the package would refuse fails there rather than on the
cluster.

Each scenario runs in its own R process, and one that fails does not stop the
others — the summary at the end says which failed, because a grid that quietly
came back four-of-five would be read as five.

The Job then exports every table each run wrote to
`/mnt/data/NDMM/<prefix>/<TABLE>.csv`, and the LOT build's outputs to
`/mnt/data/NDMM/lot/<LOT_RUN_ID>.<build>/<TABLE>.csv`. LOT tables are
filed by **run and build**, not by scenario: scenarios normally share one LOT
run, so a copy each would waste the space and suggest they differ, and the
build is in the name because the engine can build one run id more than once.
A build a previous scenario already exported is reused. A scenario is
exported only from a `complete` run, pinned before its first table is read
and checked again after its last — and only the tables that run's own
metadata says it wrote, with only the rows of the cohorts it selected: what
an earlier run left under the prefix stays out of the snapshot. Re-run on each data refresh; the App reads the new snapshot on
restart.

Cost: one full study run per scenario. Five scenarios is five runs — start with
two or three, and add rows as questions come up.

## 3. Publish the dashboard — Domino **App**

Domino launches the App command from the **project root** and expects the
process on `0.0.0.0:8888`; `app.sh` does that. Set the App command to `bash
<folders>/dashboard/app.sh`, giving the path from the project root to wherever
the three folders sit. `app.sh` changes to the folder above `dashboard/`
itself, so nothing else depends on where that is.

Set the App's environment variables:

```
DASH_SOURCE=snapshot
DASH_SNAPSHOT_DIR=/mnt/data/NDMM
DASH_ALLOW_SYNTHETIC=FALSE
```

The **Tables** tab fills the requested table shells from the `TFLS/` folder
beside `dashboard/`. An App published from a checkout that carries it needs
nothing set; where that folder sits somewhere else, `DASH_TFLS_DIR` names it.
Without it, that one tab says so and every other tab is unaffected.

The snapshot lives in a Domino **Dataset** rather than in the Job's artifacts,
because an App reads a Dataset it has attached and does not see another run's
artifacts. Attach the Dataset to the App (the Data step of the publish
dialog) and to the Job that writes it; both see it under `/mnt/data/<name>`.

Create the Dataset first. The Job does not make one: it writes directories and
files into whatever is already mounted at `DASH_SNAPSHOT_DIR`, so with no
writable Dataset attached there it either writes into the run's own container,
which disappears with it, or fails on a read-only path. Create or select a
writable Dataset in the project, attach it to the Job and to the App, and point
`DASH_SNAPSHOT_DIR` at its mount; the Job then fills in the scenario
directories under it.

`/mnt/data/NDMM` is the path a **local** Dataset of this project takes. A
Dataset imported from another project, or a deployment on a different file
system, mounts somewhere else and under a name the platform chooses. So read
the mount path off the Data step of the publish dialog rather than assuming
this one, and give `DASH_SNAPSHOT_DIR` what it says. The two only have to agree
with each other: nothing in the app requires a particular path.

The last one matters. It makes an App configured for synthetic numbers refuse
to start and say why, so nobody quotes generated data because the default was
left in place. A snapshot source whose directory is missing or empty lists no
scenarios; it never falls back to synthetic data. Anything a stakeholder might
quote belongs behind it.

## Reading the warehouse directly instead

`DASH_SOURCE=warehouse` with `DASH_WORK_SCHEMA` and `DASH_CATALOG` set reads
the `S_*` tables live, and scenarios are discovered by looking for tables whose
name ends in `S_RUN_METADATA`. The connection is the study package's own, over
the Databricks ODBC DSN by default, so the App then needs `DATABRICKS_PWD` as
well. Add `DASH_LOT_PREFIX` for the LOT tabs — the
study's metadata records which LOT *run* a scenario read, not where that run
wrote, and rows are then filtered to that run id so a prefix pointing at a
different one is caught rather than drawn. The App opens one connection as it
starts and every viewer shares it, re-querying on every control change, so the
snapshot is the better default for anything more than one person.

## What the App can and cannot do

It reads. It creates, replaces and drops nothing, so an App left running cannot
affect a study run. A scenario nobody has built does not appear; the helper
that prints the command such a run needs (`scenario_command()` in
`R/scenarios.R`) is not wired to the page — running one writes to the
warehouse, and that belongs to whoever owns the schema. A run that is
`started` or `failed` is listed with its settings, and its tables are not
shown.
