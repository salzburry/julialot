#!/usr/bin/env bash
# Domino App launcher.
#
# Domino runs this from the PROJECT ROOT and expects the process on
# 0.0.0.0:8888. The three delivery folders can sit anywhere below the root,
# so this first changes to the folder above dashboard/ - wherever this file
# is - and every path after that is relative to it.
#
# Data source. Default is SYNTHETIC, so a first deploy comes up and can be
# clicked through before any scenario has been run. Point it at the snapshot
# jobs/build_scenarios.R wrote to show the study's own numbers - a Domino
# Dataset the App has attached, mounted under /mnt/data:
#
#   export DASH_SOURCE=snapshot
#   export DASH_SNAPSHOT_DIR=/mnt/data/NDMM
#
# Set DASH_ALLOW_SYNTHETIC=FALSE on any deployment that must never show
# generated numbers - it then refuses to start rather than falling back.
set -euo pipefail
cd "$(dirname "$0")/.."

export DASH_SOURCE="${DASH_SOURCE:-synthetic}"
export DASH_SNAPSHOT_DIR="${DASH_SNAPSHOT_DIR:-/mnt/data/NDMM}"
export DASH_PACKAGE_DIR="${DASH_PACKAGE_DIR:-ndmm_study_updated/study223926}"

R -e "shiny::runApp('dashboard', host = '0.0.0.0', port = 8888, launch.browser = FALSE)"
