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

# compare_local is now CALLER-scoped like --run. DEFAULT is STRICT: the cmp fixtures
# agree on contains_mtx_reg, and the only blocking-eligible diff is the nondeterministic
# excluded col, so two "production" exports -> full `match` (the gap is NOT hardwired).
res <- compare_local("tests/unit/cmp/legacy", "tests/unit/cmp/refactored")
eq(attr(res, "verdict"), "match", "default compare_local is STRICT -> excluded-only diff is a full match")
eq(length(attr(res, "missing_tables")), 0L, "no missing required tables")
ok(res$LOT_LONG$value_mismatch == 0L && !isTRUE(res$LOT_LONG$partial), "no non-excluded value mismatch; not partial")
# the partial_match MECHANISM is retained for a FUTURE unimplemented field (none today
# - contains_mtx_reg is now computed): a present field passed as `unimplemented` becomes
# non-blocking and downgrades the table to partial_match (demonstrated with a stand-in).
resE <- compare_local("tests/unit/cmp/legacy", "tests/unit/cmp/refactored",
                      unimplemented = list(LOT_LONG = "lot_base_meds"))
eq(attr(resE, "verdict"), "partial_match", "a present `unimplemented` field -> partial_match (mechanism retained)")
ok(isTRUE(resE$LOT_LONG$partial) && "lot_base_meds" %in% resE$LOT_LONG$unimplemented,
   "the named gap field is flagged; UNIMPLEMENTED_FIELDS itself is now empty (contains_mtx_reg computed)")
ok(length(UNIMPLEMENTED_FIELDS) == 0L, "UNIMPLEMENTED_FIELDS is empty - LOT_LONG is fully derived")
ok(resE$MAP_STACKED$verdict == "match" && resE$LOT1_BASE$verdict == "match",
   "tables without a gap field are still a FULL match (partial is scoped to LOT_LONG)")
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
# membership gap STOPS the column compare (matches README + the --run path): no value
# detail or checksum is computed once populations differ (verdict is still mismatch).
tmpm <- file.path(tempdir(), "memstop"); dir.create(tmpm, showWarnings = FALSE)
file.copy(list.files("tests/unit/cmp/refactored", full.names = TRUE), tmpm, overwrite = TRUE)
dm <- read.csv(file.path(tmpm, "LOT_LONG.csv"), colClasses = "character", check.names = FALSE)
write.csv(dm[-1, ], file.path(tmpm, "LOT_LONG.csv"), row.names = FALSE)   # drop a row (membership only)
rm2 <- compare_local("tests/unit/cmp/legacy", tmpm)$LOT_LONG
ok(rm2$only_in_a >= 1L && rm2$value_mismatch == 0L && length(rm2$mismatch_cols) == 0L &&
   rm2$verdict == "mismatch" && is.null(rm2$checksum_a),
   "membership gap stops the column compare (no value detail / checksum) before the verdict")

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
ok(grepl("<=>", sv) && grepl("sum\\(CASE WHEN NOT", sv) &&
   lengths(gregexpr("\\bJOIN\\b", sv)) == 1L && !grepl("UNION", sv),
   "values SQL is ONE join with per-column null-safe conditional aggregates (not N unions)")
ok(grepl("a.`lot_start_type` <=> b.`lot_start_type`", sv) &&
   grepl("a.`lot_base_1st_add_med` <=> b.`lot_base_1st_add_med`", sv),
   "every non-key shared column is aggregated (excluded handled in R, not SQL)")
ok(!grepl("sum\\(CASE WHEN NOT \\(a.`patient_id`", sv), "key column is not value-compared (only joined on)")
# .tally_values: blocking vs excluded split from the one-row counts
tv <- .tally_values(c(0L, 3L, 5L), c("lot_start_type", "lot_base_meds", "lot_base_1st_add_med"), "lot_base_1st_add_med")
ok(tv$value_mismatch == 3L && identical(tv$mismatched_columns, "lot_base_meds") && tv$excluded_diffs == 5L,
   ".tally_values: excluded col surfaced (5) but non-blocking; the real diff (3) blocks")
# BIGINT-safe: a count above the 32-bit limit must NOT narrow to NA->0 (a missed mismatch)
tvB <- .tally_values(c(0, 3e9), c("lot_start_type", "lot_base_meds"))
ok(tvB$value_mismatch == 3e9, ".tally_values keeps counts as double (>2^31 not narrowed to NA/0)")
# sql_value_sample: bounded, mismatch-only diagnostic (keys + a_/b_ values, LIMIT)
ss <- sql_value_sample("ns.A", "ns.B", c("patient_id", "lot_num"), c("lot_base_end_reason"), 100L)
ok(grepl("a.`lot_base_end_reason` AS `a_lot_base_end_reason`", ss) &&
   grepl("b.`lot_base_end_reason` AS `b_lot_base_end_reason`", ss) &&
   grepl("WHERE NOT \\(a.`lot_base_end_reason` <=> b.`lot_base_end_reason`\\)", ss) && grepl("LIMIT 100", ss),
   "sql_value_sample returns keys + a/b values for changed rows, LIMIT-bounded")
ok(grepl("ORDER BY a.`patient_id`, a.`lot_num` LIMIT", ss), "sql_value_sample ORDER BYs the keys (deterministic rows)")
ok(is.null(sql_value_sample("a", "b", "patient_id", character(0))), "no mismatched cols -> no sample query")
# governed persistence: CREATE the sample as a run-scoped table (patient data stays governed)
si <- sql_value_sample_into("audit.lot_diff_LOT_LONG", "ns.A", "ns.B", c("patient_id", "lot_num"), c("lot_base_end_reason"), 100L)
ok(grepl("^CREATE OR REPLACE TABLE audit.lot_diff_LOT_LONG AS SELECT", si) && grepl("ORDER BY", si),
   "sql_value_sample_into wraps the sample in CREATE TABLE AS (governed storage)")
# --sample-into must be EXACTLY catalog.schema.cmp_<run_id> (3 nonempty parts, run-scoped)
ok(.validate_sample_into("hive_metastore.audit.cmp_run1") == "hive_metastore.audit.cmp_run1", "qualified run-scoped prefix accepted")
ok(is.null(.validate_sample_into(NULL)), "NULL prefix accepted (sampling off)")
for (bad in c("unqualified_table", "catalog.schema", "catalog..cmp_run", "catalog.schema.",
              "audit.diff", "catalog.schema.cmp_", "catalog.schema.run1"))
  ok(inherits(try(.validate_sample_into(bad), silent = TRUE), "try-error"),
     sprintf("malformed/insufficient --sample-into rejected: '%s'", bad))
# key exclusion is CASE-INSENSITIVE: a legacy PATID key must NOT value-compare a `patid`
# compare column (Databricks folds case; the key is already the join condition)
svk <- sql_values("a", "b", "PATID", c("patid", "lot_start_type"))
ok(!grepl("sum\\(CASE WHEN NOT \\(a.`patid`", svk) && grepl("a.`lot_start_type` <=> b.`lot_start_type`", svk),
   "sql_values excludes the key case-insensitively (PATID key vs patid column)")
# CLI flag parsing requires an argument (a bare --sample-into must NOT build NA_<table>)
ok(.flag_val(c("--run", "x", "y", "--sample-into", "audit.diff"), "--sample-into") == "audit.diff", "--flag value parsed")
ok(is.null(.flag_val(c("--run", "x", "y"), "--sample-into")), "absent flag -> NULL")
ok(inherits(try(.flag_val(c("--run", "x", "y", "--sample-into"), "--sample-into"), silent = TRUE), "try-error"),
   "bare --sample-into (no prefix) fails fast, not NA_<table>")
ok(inherits(try(.flag_val(c("--run", "x", "y", "--sample-into", "--patid"), "--sample-into"), silent = TRUE), "try-error"),
   "--sample-into followed by another flag fails fast")
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
   grepl("CAST\\(`PATID` AS STRING\\) AS `patient_id`", nv) && grepl("`med_abbr`", nv) && grepl("`map_cnt`", nv),
   "sql_normalize_view casts the id to canonical STRING and passes other cols through")
ok(grepl("FROM ns.MAP_STACKED", nv) && !grepl("AS `patient_id`.*AS `patient_id`", nv),
   "sql_normalize_view renames exactly one column (the id) to patient_id")
ok(.cmp_view("LOT_LONG", "b") == "cmpnorm_LOT_LONG_b", "normalize view name is per-table/per-side")
# --patid override is honored ONLY when the named column is present on side A, so a
# wrong override on a cross-convention compare can't normalize a missing column.
ok(.resolve_patid("PATID", c("PATID", "lot_num")) == "PATID", "override honored when the column exists")
ok(.resolve_patid("PATID", c("patient_id", "lot_num")) == "patient_id",
   "override IGNORED (falls back to auto-detect) when side A lacks that column")
ok(.resolve_patid(NULL, c("patient_id")) == "patient_id", "no override -> auto-detect")
# the gap downgrade is CALLER-scoped: warehouse prior-vs-current passes NO gaps
# (both production compute the field -> strict, full match reachable). The mechanism is
# generic (no field uses it today); .present_gaps reports a caller-named gap iff present.
ok(length(.present_gaps(character(0), c("lot_base_meds", "lot_num"))) == 0,
   "no unimplemented -> no gap (strict; the default)")
ok(identical(.present_gaps("lot_base_meds", c("lot_base_meds", "lot_num")), "lot_base_meds"),
   "a caller-named gap present in the table is flagged")
ok(length(.present_gaps("lot_base_meds", c("patient_id", "lot_num"))) == 0,
   "a gap field absent from the table is not reported")
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
