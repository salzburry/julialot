#!/usr/bin/env bash
# Domino App launcher.
#
# Domino runs this and expects the process on 0.0.0.0:8888, with the working
# directory at the PROJECT ROOT - so the path below is from the root.
#
# Data source. Default is SYNTHETIC, so a first deploy comes up and can be
# clicked through before any scenario has been run. Point it at the snapshot
# jobs/build_scenarios.R wrote to show the study's own numbers:
#
#   export DASH_SOURCE=snapshot
#   export DASH_SNAPSHOT_DIR=/mnt/artifacts/results
#
# Set DASH_ALLOW_SYNTHETIC=FALSE on any deployment that must never show
# generated numbers - it then refuses to start rather than falling back.
set -euo pipefail

export DASH_SOURCE="${DASH_SOURCE:-synthetic}"
export DASH_SNAPSHOT_DIR="${DASH_SNAPSHOT_DIR:-/mnt/artifacts/results}"
export DASH_PACKAGE_DIR="${DASH_PACKAGE_DIR:-Jul 28/ndmm_study_updated/study223926}"

R -e "shiny::runApp('Jul 28/ndmm_study_updated/dashboard', host = '0.0.0.0', port = 8888, launch.browser = FALSE)"
