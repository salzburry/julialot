#!/usr/bin/env Rscript
# Level-1 (local, pure-R) unit tests for the refactor toolkit.
# Run from the jun_21_2026 workspace root:   Rscript tests/run_unit_tests.R
# These cover everything testable WITHOUT Databricks or clinical sign-off.
stopifnot(file.exists("scripts/lib.R"))   # cwd must be the workspace root

source("scripts/lib.R")
for (f in c("validate_config.R", "validate_reference_data.R", "validate_canonical.R",
            "validate_study.R", "build_coverage_matrix.R", "verify_no_synthetic.R",
            "compare_run_outputs.R", "promote_reference_data.R", "validate_manifest.R"))
  source(file.path("scripts", f))
source("tests/testutil.R")

for (f in sort(list.files("tests/unit", pattern = "^test_.*\\.R$", full.names = TRUE))) {
  cat("##", basename(f), "\n")
  source(f)
}
test_summary()
