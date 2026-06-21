# verify_no_synthetic
a <- verify_bundle_allowlist(c("R/core/map.R", "tests/fixtures/x.csv"))
ok(!a$ok && "tests/fixtures/x.csv" %in% a$offending, "denylist path blocked")
ok(verify_bundle_allowlist(c("R/core/map.R", "studies/ndmm.yml"))$ok, "allowlist paths pass")
ok(!verify_bundle_allowlist("R/../tests/secret.csv")$ok, "path traversal (..) rejected")
# manifest-vs-bundle reconciliation: an unlisted bundle file fails closed
bd <- file.path(tempdir(), "bundle"); dir.create(file.path(bd, "R"), recursive = TRUE, showWarnings = FALSE)
writeLines("x", file.path(bd, "R", "map.R")); writeLines("y", file.path(bd, "R", "sneaky.R"))
rec <- verify_manifest_matches_bundle("R/map.R", bd)
ok(!rec$ok && "R/sneaky.R" %in% rec$unlisted_in_manifest, "unlisted bundle file detected")
ok(verify_manifest_matches_bundle(c("R/map.R", "R/sneaky.R"), bd)$ok, "fully-listed bundle reconciles")
# --bundle: data files are scanned at the BUNDLE root, not cwd
ok(identical(bundle_data_files("reference_data/approved/x.csv", "/tmp/bundle"),
             "/tmp/bundle/reference_data/approved/x.csv"),
   "bundle data file resolved against bundle dir")
bsyn <- file.path(tempdir(), "bsyn"); dir.create(file.path(bsyn, "reference_data", "approved"), recursive = TRUE, showWarnings = FALSE)
writeLines(c("patient_id,x", "9000000123,1"), file.path(bsyn, "reference_data", "approved", "s.csv"))
ok(!verify_no_synthetic_data(bundle_data_files("reference_data/approved/s.csv", bsyn))$ok,
   "synthetic in BUNDLED file detected via the bundle root")
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

# canonical cell normalization: numeric tolerance + date coercion, but a
# leading-zero identifier (NDC, padded id) is NEVER coerced to a number.
ok(.cells_equal("1.0", "1"), "numeric: 1.0 == 1")
ok(.cells_equal("1.2300", "1.23"), "numeric: trailing zeros tolerated")
ok(.cells_equal("2020-06-01 00:00:00", "2020-06-01"), "date: timestamp == date")
ok(!.cells_equal("00002143380", "2143380"), "leading-zero id NOT numerically coerced")
ok(!.cells_equal("PROGRESSION", "DEATH"), "distinct tokens differ")
ok(!.cells_equal("\001NULL\001", "0"), "null is not 0")

# hive_metastore SQL builders (pure; db_q is the only unwired seam)
ok(grepl("EXCEPT", sql_membership("ns_a.LOT_LONG", "ns_b.LOT_LONG", c("patient_id", "lot_num"))),
   "membership SQL uses EXCEPT anti-join")
sv <- sql_values("a", "b", "patient_id",
                 c("patient_id", "lot_start_type", "lot_base_1st_add_med"), "lot_base_1st_add_med")
ok(grepl("<=>", sv) && grepl("UNION ALL", sv), "values SQL is null-safe per-column union")
ok(grepl("'lot_base_1st_add_med' AS column_name, true AS excluded", sv), "excluded col flagged in values SQL")
ok(!grepl("'patient_id' AS column_name", sv), "key column is not value-compared")
ok(grepl("array_sort", sql_checksum("t", "patient_id", c("patient_id", "lot_start_type"))),
   "checksum SQL is order-independent (array_sort)")
# legacy-named tables: --patid PATID remaps ONLY patient_id (Databricks folds case
# for the rest, e.g. LOT_NUM == lot_num)
ok(identical(.remap_patid(c("patient_id", "lot_num"), "PATID"), c("PATID", "lot_num")),
   "patid remap swaps only patient_id")
ok(grepl("a.`PATID` <=> b.`PATID`", sql_values("a", "b", "PATID", c("PATID", "lot_start_type"))),
   "legacy comparison joins on PATID")
# schema parity covers TYPES, not just names (review P2)
sm <- compare_schema_maps(c(patient_id = "bigint", lot_num = "int", x = "date"),
                          c(patient_id = "bigint", lot_num = "int", x = "string"))
ok(!sm$ok && "x" %in% sm$type_mismatch, "schema type drift caught (date vs string)")
ok(compare_schema_maps(c(a = "int"), c(a = "int"))$ok, "identical schema maps match")
# patient-id auto-detect (PATID legacy vs patient_id canonical) - no flag needed
ok(.detect_patid(c("PATID", "LOT_NUM")) == "PATID", "PATID auto-detected")
ok(.detect_patid(c("patient_id", "lot_num")) == "patient_id", "patient_id auto-detected")
# cross-convention bridge: normalize a legacy PATID side to canonical patient_id so a
# PATID-vs-patient_id compare does not fail schema parity on the id name alone.
nv <- sql_normalize_view("cmpnorm_MAP_STACKED_a", "ns.MAP_STACKED", c("patid", "med_abbr", "map_cnt"), "PATID")
ok(grepl("CREATE OR REPLACE TEMPORARY VIEW cmpnorm_MAP_STACKED_a", nv) &&
   grepl("`PATID` AS `patient_id`", nv) && grepl("`med_abbr`", nv) && grepl("`map_cnt`", nv),
   "sql_normalize_view aliases the side's id to patient_id and passes other cols through")
ok(grepl("FROM ns.MAP_STACKED", nv) && !grepl("AS `patient_id`.*AS `patient_id`", nv),
   "sql_normalize_view renames exactly one column (the id) to patient_id")
ok(.cmp_view("LOT_LONG", "b") == "cmpnorm_LOT_LONG_b", "normalize view name is per-table/per-side")
# --patid override is honored ONLY when the named column is present on side A, so a
# wrong override on a cross-convention compare can't normalize a missing column.
ok(.resolve_patid("PATID", c("PATID", "lot_num")) == "PATID", "override honored when the column exists")
ok(.resolve_patid("PATID", c("patient_id", "lot_num")) == "patient_id",
   "override IGNORED (falls back to auto-detect) when side A lacks that column")
ok(.resolve_patid(NULL, c("patient_id")) == "patient_id", "no override -> auto-detect")
# value compare spans ALL shared non-key cols (catches per-drug/class flags)
ok(setequal(value_compare_cols(c("PATID", "LOT_NUM", "LOT1_MED_LENA"),
                               c("patid", "lot_num", "lot1_med_lena"), "PATID"),
            c("lot_num", "lot1_med_lena")), "all shared non-key cols compared")
# duplicate-key check (review P1) + null-sentinel checksum (review P3)
ok(grepl("GROUP BY .* HAVING count\\(\\*\\) > 1", sql_key_uniqueness("t", c("PATID", "LOT_NUM"))),
   "key-uniqueness SQL uses GROUP BY ... HAVING count(*) > 1")
ok(grepl("null_keys", sql_key_uniqueness("t", c("PATID", "LOT_NUM"))) &&
   grepl("`PATID` IS NULL", sql_key_uniqueness("t", "PATID")),
   "key-integrity SQL also checks NULL keys (non-null required)")
# local CSV path: a missing key component is not "unique" either (parity with live)
nkd <- file.path(tempdir(), "nullkey"); dir.create(nkd, showWarnings = FALSE)
writeLines(c("patient_id,x", "P1,1", ",2"), file.path(nkd, "t.csv"))
nk <- compare_local_table(file.path(nkd, "t.csv"), file.path(nkd, "t.csv"), "patient_id")
ok(isFALSE(nk$key_unique), "local comparator: a NULL key component fails key-uniqueness")
ok(grepl("coalesce\\(cast", sql_checksum("t", "patient_id", c("patient_id", "x"))),
   "checksum coalesces nulls to a sentinel (no concat_ws null collision)")

# checksum uses the SAME normalization as the verdict (1 vs 1.0 -> match AND equal checksum)
da <- file.path(tempdir(), "ca"); db2 <- file.path(tempdir(), "cb")
dir.create(da, showWarnings = FALSE); dir.create(db2, showWarnings = FALSE)
writeLines(c("patient_id,n", "P1,1"), file.path(da, "t.csv"))
writeLines(c("patient_id,n", "P1,1.0"), file.path(db2, "t.csv"))
rr <- compare_local_table(file.path(da, "t.csv"), file.path(db2, "t.csv"), "patient_id")
ok(rr$value_mismatch == 0 && identical(rr$checksum_a, rr$checksum_b),
   "checksum aligns with the numeric-equivalence verdict")

# coverage matrix builds (informational); gate mode fails on gaps (catalog is todo)
ok(nrow(build_coverage_matrix("tests/fixtures/catalog.csv")) > 0, "coverage matrix builds")
mg <- build_coverage_matrix("tests/fixtures/catalog.csv", approved_only = TRUE)
ok(all(mg$gap == "GAP"), "gate mode: all rules are gaps (no approval-ready cases yet)")
# artifact-awareness: an approved catalog row pointing at a missing fixture fails
catA <- tempfile(fileext = ".csv")
write.csv(data.frame(case_id = "C1", area = "MAP", rule_name = "r", spec_section = "s",
  polarity = "positive", expected_outputs = "map_stacked", clinical_reviewer = "c",
  engineering_reviewer = "e", status = "approved",
  input_fixture = "nope/in.csv", expected_fixture = "nope/exp.csv"), catA, row.names = FALSE)
probs <- check_catalog_artifacts(read.csv(catA, stringsAsFactors = FALSE, check.names = FALSE), tempdir())
ok(any(grepl("artifact missing", probs)), "approved row with missing fixture artifact flagged")
