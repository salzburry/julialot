# Running the Cohort Explorer on Domino

Two pieces: a **Domino App** (the Shiny dashboard) and, for real data, a
**Domino Job** (`warehouse/08_analytic_cohort.R`) that builds the snapshot the
App reads. The apr_30 pipeline already runs on Domino as a Job — same pattern.

## 0. Compute environment (once)

Use (or extend) a Domino Compute Environment that has R plus:

```r
install.packages(c("shiny", "survival"))          # dashboard
install.packages(c("DBI", "odbc", "glue"))        # only for the warehouse Job (08)
```

Bake these into the environment's Dockerfile (recommended) so the App starts
fast, rather than installing them at launch.

## 1. (Real data only) Build the snapshot — Domino **Job**

Skip this for a first synthetic-data smoke test. For real data, run the apr_30
pipeline + `06` first (they persist `ELIG_COH_FINAL`, `LOT_LONG`,
`NDMM_FLAGS_ALL`), then run the materialization Job:

```bash
# Domino Job command:
Rscript cohort_explorer/config/emit_pipeline_env.R pipeline_env.sh
source pipeline_env.sh
export ANALYTIC_COHORT_ALLOW_PLACEHOLDER=TRUE     # remove once [B]-[E] are wired
export OUTPUT_DIR=/mnt/artifacts/results
Rscript cohort_explorer/warehouse/08_analytic_cohort.R
```

Set `DATABRICKS_PWD` as a Domino env var / secret. This writes
`analytic_cohort.csv` and `analytic_lot_long.csv` to `/mnt/artifacts/results`
(Domino persists Job artifacts there). Re-run on each data refresh.

## 2. Publish the dashboard — Domino **App**

- Domino Apps launch `app.sh` and expect the process on `0.0.0.0:8888`;
  `cohort_explorer/app.sh` already does exactly that. Put it where your App is
  configured to find it (project-root `app.sh`, or set the App command to
  `bash cohort_explorer/app.sh`).
- Set the App's environment variables to point at the snapshot from step 1:

  ```
  COHORT_EXPLORER_DATA     = /mnt/artifacts/results/analytic_cohort.csv
  COHORT_EXPLORER_LOTLONG  = /mnt/artifacts/results/analytic_lot_long.csv
  ```

  Leave them **unset** to run on the built-in synthetic cohort (a good first
  deploy to confirm the App serves before wiring real data).
- Publish: Domino UI → **App** → **Publish**. Open the App URL when it's running.

## Refresh model

The App reads a **snapshot** held in memory; every cohort switch / IE toggle /
filter / KM / Cox is instant (no query per click). To refresh, re-run the step-1
Job and restart the App — it picks up the new CSVs on launch.

## Troubleshooting

- **App starts then errors on load** — the fail-closed validators rejected the
  snapshot. The Domino App log shows exactly which column/contract check failed
  (e.g. a non-0/1 flag, a TTE beyond follow-up). Fix it in `08` and re-run.
- **Blank / "cannot connect"** — the process isn't on `0.0.0.0:8888`; confirm
  `app.sh` is the App command and wasn't overridden.
- **Commercial-only Sankey empty** — expected while payer is the `[B]`
  placeholder `'Unknown'`; wire real payer, or toggle "commercial-only" off.
