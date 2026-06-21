# verify_no_synthetic
a <- verify_bundle_allowlist(c("R/core/map.R", "tests/fixtures/x.csv"))
ok(!a$ok && "tests/fixtures/x.csv" %in% a$offending, "denylist path blocked")
ok(verify_bundle_allowlist(c("R/core/map.R", "studies/ndmm.yml"))$ok, "allowlist paths pass")
ok(length(scan_file_for_synthetic("tests/fixtures/synthetic/members.csv")) > 0,
   "synthetic-range PATID detected")
# fail closed: a missing listed data file is a violation
ok(!verify_no_synthetic_data("/nonexistent/file.csv")$ok, "missing data file fails closed")
# TSV parsed with a tab separator (synthetic PATID still detected)
tsv <- file.path(tempdir(), "syn.tsv"); writeLines(c("patient_id\tx", "9000000007\t1"), tsv)
ok(length(scan_file_for_synthetic(tsv)) > 0, "synthetic PATID detected in TSV")

# compare_local: all three required tables present; differ ONLY in excluded col -> MATCH
res <- compare_local("tests/unit/cmp/legacy", "tests/unit/cmp/refactored")
eq(attr(res, "verdict"), "match", "all required tables present, excluded-only diff -> match")
eq(length(attr(res, "missing_tables")), 0L, "no missing required tables")
ok(res$LOT_LONG$value_mismatch == 0L, "no non-excluded value mismatch")

# a missing required output table -> blocking mismatch (fail closed)
tmpL <- file.path(tempdir(), "onlylot"); dir.create(tmpL, showWarnings = FALSE)
file.copy("tests/unit/cmp/refactored/LOT_LONG.csv", file.path(tmpL, "LOT_LONG.csv"), overwrite = TRUE)
resm <- compare_local("tests/unit/cmp/legacy", tmpL)
eq(attr(resm, "verdict"), "mismatch", "missing required table -> mismatch")
ok(all(c("MAP_STACKED", "LOT1_BASE") %in% attr(resm, "missing_tables")), "missing tables reported")

# a real (non-excluded) value diff -> MISMATCH; a missing row -> membership mismatch
tmp <- file.path(tempdir(), "ref2"); dir.create(tmp, showWarnings = FALSE)
file.copy(list.files("tests/unit/cmp/refactored", full.names = TRUE), tmp, overwrite = TRUE)
df <- read.csv(file.path(tmp, "LOT_LONG.csv"), colClasses = "character"); df$lot_base_end_reason[1] <- "death"
write.csv(df, file.path(tmp, "LOT_LONG.csv"), row.names = FALSE)
res2 <- compare_local("tests/unit/cmp/legacy", tmp)
eq(attr(res2, "verdict"), "mismatch", "non-excluded diff -> mismatch")
ok("lot_base_end_reason" %in% res2$LOT_LONG$mismatch_cols, "mismatch column identified")
write.csv(df[-3, ], file.path(tmp, "LOT_LONG.csv"), row.names = FALSE)
ok(compare_local("tests/unit/cmp/legacy", tmp)$LOT_LONG$only_in_a >= 1L, "missing row detected")

# coverage matrix builds (informational); gate mode fails on gaps (catalog is todo)
ok(nrow(build_coverage_matrix("tests/fixtures/catalog.csv")) > 0, "coverage matrix builds")
mg <- build_coverage_matrix("tests/fixtures/catalog.csv", approved_only = TRUE)
ok(all(mg$gap == "GAP"), "gate mode: all rules are gaps (no approval-ready cases yet)")
