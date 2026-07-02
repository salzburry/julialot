#!/usr/bin/env bash
# =============================================================================
# Domino App launcher for the Cohort Explorer Shiny dashboard.
# -----------------------------------------------------------------------------
# Domino Apps run this file and expect the process to listen on 0.0.0.0:8888.
# Domino invokes app.sh with the working directory at the PROJECT ROOT, so
# runApp("cohort_explorer") resolves. If your Domino App is configured to look
# for app.sh at the project root, copy this there (or set the App command to
# `bash cohort_explorer/app.sh`).
#
# Data source (optional): point at the snapshot that warehouse/08_analytic_cohort.R
# produced (run it first as a Domino Job). If UNSET, the app runs on the built-in
# SYNTHETIC cohort (useful for a first smoke-test deploy).
#   export COHORT_EXPLORER_DATA=/mnt/artifacts/results/analytic_cohort.csv
#   export COHORT_EXPLORER_LOTLONG=/mnt/artifacts/results/analytic_lot_long.csv
# =============================================================================
set -euo pipefail

R -e "shiny::runApp('cohort_explorer', host = '0.0.0.0', port = 8888, launch.browser = FALSE)"
