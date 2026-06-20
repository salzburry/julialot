# verify_no_synthetic
a <- verify_bundle_allowlist(c("R/core/map.R", "tests/fixtures/x.csv"))
ok(!a$ok && "tests/fixtures/x.csv" %in% a$offending, "denylist path blocked")
ok(verify_bundle_allowlist(c("R/core/map.R", "studies/ndmm.yml"))$ok, "allowlist paths pass")
ok(length(scan_file_for_synthetic("tests/fixtures/synthetic/members.csv")) > 0,
   "synthetic-range PATID detected")

# compare_local: differ ONLY in the excluded nondeterministic column -> MATCH
res <- compare_local("tests/unit/cmp/legacy", "tests/unit/cmp/refactored")
eq(attr(res, "verdict"), "match", "differs only in excluded field -> match")
ok(res$LOT_LONG$value_mismatch == 0L, "no non-excluded value mismatch")

# inject a real (non-excluded) diff -> MISMATCH
tmp <- file.path(tempdir(), "ref2"); dir.create(tmp, showWarnings = FALSE)
df <- read.csv("tests/unit/cmp/refactored/LOT_LONG.csv", colClasses = "character")
df$lot_base_end_reason[1] <- "death"   # non-excluded column
write.csv(df, file.path(tmp, "LOT_LONG.csv"), row.names = FALSE)
res2 <- compare_local("tests/unit/cmp/legacy", tmp)
eq(attr(res2, "verdict"), "mismatch", "non-excluded diff -> mismatch")
ok("lot_base_end_reason" %in% res2$LOT_LONG$mismatch_cols, "mismatch column identified")

# missing row -> mismatch (membership)
df3 <- df[-3, ]; tmp3 <- file.path(tempdir(), "ref3"); dir.create(tmp3, showWarnings = FALSE)
write.csv(df3, file.path(tmp3, "LOT_LONG.csv"), row.names = FALSE)
ok(compare_local("tests/unit/cmp/legacy", tmp3)$LOT_LONG$only_in_a == 1L, "missing row detected")

# coverage matrix builds + flags gaps (informational)
m <- build_coverage_matrix("tests/fixtures/catalog.csv")
ok(nrow(m) > 0, "coverage matrix builds")
