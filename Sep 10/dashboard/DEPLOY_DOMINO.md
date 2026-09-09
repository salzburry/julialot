# Running the scenario explorer on Domino

Two pieces, the same pattern the LOT pipeline and `cohort_explorer` already
use: a **Job** builds the scenarios, an **App** serves them.

## 0. Compute environment (once)

R plus `shiny`. Nothing else is required — the plots are base graphics and the
Kaplan–Meier estimator is written out, precisely so a missing package cannot
silently produce nothing.

```r
install.packages("shiny")
install.packages("survival")   # optional: only the test cross-check uses it
install.packages("sparklyr")   # only for the Job, and only for DASH_SOURCE=warehouse
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
export DASH_SNAPSHOT_DIR=/mnt/artifacts/results
Rscript "Sep 10/dashboard/jobs/build_scenarios.R"
```

One row of `scenarios.csv` is one run. `prefix` is the `OBJECT_PREFIX` it
writes under; every other upper-case column is set as an environment variable
for that run and nothing else, so **the column name is the variable name** and
a new open question becomes available the moment the package reads it.

Each scenario runs in its own R process, and one that fails does not stop the
others — the summary at the end says which failed, because a grid that quietly
came back four-of-five would be read as five.

The Job then exports every table each run wrote to
`/mnt/artifacts/results/<prefix>/<TABLE>.csv`, and the LOT build's outputs to
`/mnt/artifacts/results/lot/<LOT_RUN_ID>/<TABLE>.csv`. LOT tables are filed by
**run**, not by scenario: scenarios normally share one LOT run, so a copy each
would waste the space and suggest they differ. A run a previous scenario
already exported is skipped. Domino persists Job artifacts there. Re-run on
each data refresh.

Cost: one full study run per scenario. Five scenarios is five runs — start with
two or three, and add rows as questions come up.

## 3. Publish the dashboard — Domino **App**

Domino launches `app.sh` from the **project root** and expects the process on
`0.0.0.0:8888`; `app.sh` does that. Either copy it to the project root or set
the App command to `bash "Sep 10/dashboard/app.sh"`.

Set the App's environment variables:

```
DASH_SOURCE=snapshot
DASH_SNAPSHOT_DIR=/mnt/artifacts/results
DASH_ALLOW_SYNTHETIC=FALSE
```

The last one matters. Without it, an App that cannot find its snapshot falls
back to generated numbers; with it, the App refuses to start and says why.
Anything a stakeholder might quote belongs behind it.

## Reading the warehouse directly instead

`DASH_SOURCE=warehouse` with `DASH_WORK_SCHEMA` and `DASH_CATALOG` set reads
the `S_*` tables live, and scenarios are discovered by looking for tables whose
name ends in `S_RUN_METADATA`. Add `DASH_LOT_PREFIX` for the LOT tabs — the
study's metadata records which LOT *run* a scenario read, not where that run
wrote, and rows are then filtered to that run id so a prefix pointing at a
different one is caught rather than drawn. It needs a cluster per viewer and re-queries on
every control change, so the snapshot is the better default for anything more
than one person.

## What the App can and cannot do

It reads. It creates, replaces and drops nothing, so an App left running cannot
affect a study run. Asking for a scenario nobody has built prints the command
rather than running it — running one writes to the warehouse, and that belongs
to whoever owns the schema.
