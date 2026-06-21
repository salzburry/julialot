# validate_manifest (runtime checks JSON Schema cannot express)
mok <- list(run_status = "success", publication = list(status = "published"),
            comparison = list(result = "match"),
            reference_data = list(list(id = "steroid", approval_status = "approved")),
            config = list(resolved = list(database = "prod", max_lot = 5L)))
ok(length(validate_manifest(mok)$errors) == 0, "clean manifest passes")

# redaction: a secret-like key carrying a value anywhere is blocked
mleak <- mok; mleak$config$resolved$db_password <- "hunter2"
ok(any(grepl("secret-like", validate_manifest(mleak)$errors)), "secret value in config.resolved caught")
# a secret-like REFERENCE (in the secrets array) is allowed, not flagged
mref <- mok; mref$secrets <- list(list(reference = "kv://db_password", resolved = TRUE))
ok(length(validate_manifest(mref)$errors) == 0, "secret reference (no value) allowed")

# cross-rules
mf <- mok; mf$run_status <- "failed"
ok(any(grepl("failed but publication", validate_manifest(mf)$errors)), "failed+published caught")
mm <- mok; mm$comparison$result <- "mismatch"
ok(any(grepl("mismatch but publication", validate_manifest(mm)$errors)), "mismatch+published caught")

# reproducibility: reference data must be present and approved
me <- mok; me$reference_data <- list()
ok(any(grepl("reference_data is empty", validate_manifest(me)$errors)), "empty reference_data caught")
md <- mok; md$reference_data <- list(list(id = "x", approval_status = "draft"))
ok(any(grepl("not approved", validate_manifest(md)$errors)), "unapproved reference_data caught")
