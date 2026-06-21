# validate_manifest: ONE gate = structural (schema) + runtime cross-rules
MF <- "tests/fixtures/manifest_example.json"
m <- read_json_file(MF)
ok(length(validate_manifest(m)$errors) == 0, "complete example manifest passes the single gate")

# STRUCTURE: a structurally-incomplete manifest now fails (was a prior gap)
m1 <- m; m1$run_id <- NULL
ok(any(grepl("missing required", validate_manifest(m1)$errors)), "missing required top-level field caught")
m1b <- m; m1b$version_axes$algorithm <- NULL
ok(any(grepl("version_axes: missing required", validate_manifest(m1b)$errors)), "missing nested required field caught")

# secrets-subtree bypass CLOSED: a value placed in secrets[] is rejected structurally
m2 <- m; m2$secrets[[1]]$password <- "hunter2"
ok(any(grepl("secrets\\[1\\]: undeclared", validate_manifest(m2)$errors)),
   "secret value inside secrets[] rejected (redaction bypass closed)")

# redaction: a secret-like key carrying a value in config.resolved is caught
m3 <- m; m3$config$resolved$db_password <- "hunter2"
ok(any(grepl("secret-like", validate_manifest(m3)$errors)), "secret value in config.resolved caught")

# cross-rules (value-level, not expressible structurally)
m4 <- m; m4$run_status <- "failed"
ok(any(grepl("failed but publication", validate_manifest(m4)$errors)), "failed + published caught")
m5 <- m; m5$comparison$result <- "mismatch"
ok(any(grepl("mismatch but publication", validate_manifest(m5)$errors)), "mismatch + published caught")
m6 <- m; m6$quality$cohort_valid_for_primary_use <- FALSE
ok(any(grepl("cohort_valid_for_primary_use=false", validate_manifest(m6)$errors)),
   "non-primary-use cohort + published blocked")
m7 <- m; m7$quality$degraded_gates <- list("baseline_ce")
ok(any(grepl("degraded cohort gate", validate_manifest(m7)$errors)), "degraded gate + published blocked")
m8 <- m; m8$reference_data[[1]]$approval_status <- "draft"
ok(any(grepl("not approved", validate_manifest(m8)$errors)), "unapproved reference_data caught")
