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
# corrected nondeterminism model: the seeded tie-break picks the MED identity, so
# lot_base_1st_add_med is excluded (surfaced) while the *_DT is now STRICT.
ok(res$LOT_LONG$excluded_diffs >= 1L, "excluded med-identity diff is surfaced, not blocking")
tmpD <- file.path(tempdir(), "dtstrict"); dir.create(tmpD, showWarnings = FALSE)
file.copy(list.files("tests/unit/cmp/refactored", full.names = TRUE), tmpD, overwrite = TRUE)
dd <- read.csv(file.path(tmpD, "LOT_LONG.csv"), colClasses = "character", check.names = FALSE)
dd$lot_base_1st_add_med_dt[1] <- "2019-12-31"      # perturb the (now strict) date
write.csv(dd, file.path(tmpD, "LOT_LONG.csv"), row.names = FALSE)
resDT <- compare_local("tests/unit/cmp/legacy", tmpD)
eq(attr(resDT, "verdict"), "mismatch", "first-add-med DATE is strict (a diff blocks)")
ok("lot_base_1st_add_med_dt" %in% resDT$LOT_LONG$mismatch_cols, "strict date diff identified")

# output contract: two EQUALLY-incomplete outputs (both missing a required
# column) must NOT be called a match (P1: a missing contract column is blocking).
# Use a behaviourally-meaningful LOT_LONG field (lot_start_type) - the exact class
# the contract must protect, not just a date.
tmpC1 <- file.path(tempdir(), "contract_a"); dir.create(tmpC1, showWarnings = FALSE)
tmpC2 <- file.path(tempdir(), "contract_b"); dir.create(tmpC2, showWarnings = FALSE)
file.copy(list.files("tests/unit/cmp/legacy", full.names = TRUE), tmpC1, overwrite = TRUE)
file.copy(list.files("tests/unit/cmp/refactored", full.names = TRUE), tmpC2, overwrite = TRUE)
for (d in c(tmpC1, tmpC2)) {                       # drop a required col from BOTH sides
  dd <- read.csv(file.path(d, "LOT_LONG.csv"), colClasses = "character", check.names = FALSE)
  write.csv(dd[setdiff(names(dd), "lot_start_type")], file.path(d, "LOT_LONG.csv"), row.names = FALSE)
}
resC <- compare_local(tmpC1, tmpC2)
eq(attr(resC, "verdict"), "mismatch", "both sides missing a required column -> mismatch (not match)")
ok(isFALSE(resC$LOT_LONG$contract_ok), "contract_ok is FALSE when a required column is absent")
ok("lot_start_type" %in% resC$LOT_LONG$missing_required$a, "missing required column reported")

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
