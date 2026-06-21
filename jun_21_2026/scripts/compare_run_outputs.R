#!/usr/bin/env Rscript
# compare_run_outputs.R
# Authoritative patient-level comparison of two LOT output sets:
#   actual   vs  expected (regression-expected, generated from legacy@baseline)
#   refactored vs legacy   (LOT_ENGINE_MODE=compare, run-scoped namespaces)
#
# The comparison LOGIC and ordering are authoritative and the warehouse SQL is
# authored as pure `sql_*` builders (Databricks SQL over the hive_metastore
# catalog). `db_q` IS wired (DBI::dbGetQuery) and `--run` connects via connect_compare;
# what remains is EXECUTING the live path against a real hive_metastore here (no
# warehouse in this environment). There is no Spark DataFrame API. Full
# patient-level comparison is the gate; checksums are only an early warning.
#
# Comparison hierarchy (run in order; stop reporting at the first decisive gap):
#   1. schema + key-uniqueness
#   2. anti-joins: rows only-in-actual / only-in-expected
#   3. column-level value comparison AFTER canonical normalization
#   4. checksums (early warning + compact audit record)

if (!exists(".lotlib")) source(local({ .find_lib <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) { p <- file.path(dirname(sub("^--file=", "", fa[1])), "lib.R"); if (file.exists(p)) return(p) }
  for (p in c("scripts/lib.R", "lib.R")) if (file.exists(p)) return(p); stop("lib.R not found") }; .find_lib() }))

# Per-table comparison keys (see contracts/outputs.md).
COMPARE_KEYS <- list(
  MAP_STACKED = c("patient_id", "med_abbr", "map_cnt"),
  LOT1_BASE   = c("patient_id"),
  LOT_LONG    = c("patient_id", "lot_num")
)
# Fields excluded from the strict value VERDICT (see
# tests/fixtures/expected/nondeterministic.md). The seeded tie-break
# (02_lot1.R:806 `row_number() ... ORDER BY MAP_START_DT, rand(42)`) selects WHICH
# med is the first-add among candidates sharing the earliest add date; the DATE is
# `date_sub(MAP_START_DT,1)`, identical across a same-date tie, so the *_DT field is
# DETERMINISTIC and the *_MED field is the nondeterministic one. We therefore
# exclude only the *_MED identity. This is still PENDING algorithmic sign-off: if
# the med choice propagates into any downstream field (lot end/reason/flags), that
# field is NOT excluded, so the strict comparison there is exactly the mechanism
# that would catch the propagation (fail-closed). Excluded diffs are SURFACED
# (compare result `excluded_diffs`), never silently dropped.
EXCLUDED_FIELDS <- list(
  LOT1_BASE = c("lot1_base_1st_add_med"),
  # lot_base_1st_add_med: a same-day tie-break can pick a different co-dated equal -
  # genuinely NONDETERMINISTIC display. Diffs are surfaced (excluded_diffs) but a
  # clean run over these is still a FULL match.
  LOT_LONG  = c("lot_base_1st_add_med")
)
# Known PARITY GAPS: DETERMINISTIC outputs the LOCAL R engine does not yet derive
# (contains_mtx_reg needs MONOMAINTENANCE/DUALMAINTENANCEWITH maintenance metadata).
# Whether they apply is the CALLER's SCOPE, not a global property of the column:
#   - LOCAL engine-vs-golden (compare_local): the engine hardcodes contains_mtx_reg=0,
#     so it passes UNIMPLEMENTED_FIELDS and the verdict is `partial_match` (a wrong
#     maintenance result can never silently pass as a full match).
#   - WAREHOUSE prior-vs-current (compare_run): BOTH sides are production and compute
#     the field, so the default is NONE - it is compared STRICTLY and a full `match`
#     is reachable. (A caller may still pass a gap map explicitly if one side lacks it.)
UNIMPLEMENTED_FIELDS <- list(
  LOT_LONG = c("contains_mtx_reg")
)
# Pure: the gap columns actually present in a table (a non-blocking diff there only
# downgrades to partial_match, never overturns an otherwise-clean comparison).
.present_gaps <- function(unimplemented, cols) intersect(tolower(unimplemented %||% character(0)), tolower(cols))

# Required output columns per table (the versioned output contract; see
# contracts/outputs.md). compare_local checks BOTH sides carry these, so two
# equally-incomplete outputs can never be called behaviourally equivalent. These
# are the ALGORITHM-DERIVED (behaviourally meaningful) columns the production
# builders emit (MAP_STACKED <- apr_30_2026/02_lot1.R:643-662; LOT1_BASE <-
# 02_lot1.R:814-823; LOT_LONG <- apr_30_2026/R/lot2_5_base.R:76-135 & 891-960).
# Two column classes are intentionally NOT enumerated here (both still covered by
# the schema-equality check, which fails any ONE-sided drop):
#   - study-specific per-drug / per-class WIDE columns (LOT1_MED_*, LOT_CLASS_*,
#     ...): their set varies by cohort, so they are not a fixed contract;
#   - cohort PASSTHROUGH demographics on LOT1_BASE (index_date, enddate,
#     obs_end_dt, death_dt, gdr_cd, yrdob, age_index_yr): governed by the
#     cohort / canonical-input contract, not the LOT-output gate.
OUTPUT_CONTRACT_VERSION <- "0.2-draft"
OUTPUT_CONTRACT <- list(
  MAP_STACKED = c("patient_id", "med_abbr", "med_class", "map_cnt", "map_start_dt",
                  "map_rx_runout_dt", "map_med_runout_dt", "map_end_dt",
                  "map_med_type", "map_med_class", "map_discon_flg"),
  LOT1_BASE   = c("patient_id", "lot1_start_dt", "lot1_med_cnt", "lot1_base_meds",
                  "lot1_base_discon_dt", "lot1_base_1st_add_med_dt", "lot1_base_1st_add_med"),
  LOT_LONG    = c("patient_id", "lot_num", "lot_start_dt", "lot_start_type",
                  "lot_base_meds", "lot_med_cnt", "lot_base_discon_dt",
                  "lot_base_1st_add_med_dt", "lot_base_1st_add_med",
                  "lot_base_end_dt", "lot_base_end_reason", "lot_base_length",
                  "lot_allo_lot_flg", "lot_cart_lot_flg", "contains_mtx_reg",
                  "lot_base_end_dt_ce_sens", "lot_base_end_reason_ce_sens",
                  "lot_tx_auto_flg", "lot_tx_auto_tand_flg", "lot_tx_auto_sing_flg",
                  "lot_tx_auto_dt_1", "lot_tx_auto_dt_2", "lot_tx_auto_max_dt")
)

# --- hive_metastore (Databricks SQL) adapter -------------------------------
# The run-scoped outputs live as tables in the hive_metastore catalog and are
# queried with Databricks SQL over ODBC (the project's DBI/odbc connection, same
# as apr_30_2026/R/db_utils.R) - there is no Spark DataFrame API here. The SQL
# builders below are pure (unit-tested); db_q executes them. Local CSV tests
# never call db_q, so DBI/odbc are needed only for the live --run path.
db_q <- function(con, sql) {
  if (is.null(con)) stop("db_q: no connection - pass a DBI/odbc handle (see connect_compare())")
  DBI::dbGetQuery(con, sql)
}
db_exec <- function(con, sql) {                              # DDL seam (normalize views)
  if (is.null(con)) stop("db_exec: no connection - pass a DBI/odbc handle (see connect_compare())")
  DBI::dbExecute(con, sql)
}

# Connect exactly like apr_30_2026 (DSN=DATABRICKS_DSN default RWDE; pwd=DATABRICKS_PWD;
# catalog hive_metastore). Used by the --run CLI.
connect_compare <- function(dsn = Sys.getenv("DATABRICKS_DSN", "RWDE"),
                            pwd = Sys.getenv("DATABRICKS_PWD", "")) {
  if (!nzchar(pwd)) stop("DATABRICKS_PWD is not set")
  # bigint = "numeric": map SQL BIGINT to R double, NOT odbc's default bit64::integer64.
  # The mismatch-count SUM()s are BIGINT; double keeps them exact (<2^53) and avoids
  # integer64 surviving unlist()/arithmetic in .tally_values. Verify in the live smoke.
  DBI::dbConnect(odbc::odbc(), dsn = dsn, pwd = pwd, timeout = 120, bigint = "numeric")
}

.bt <- function(x) paste0("`", x, "`")                       # backtick-quote an identifier
.keylist <- function(keys) paste(.bt(keys), collapse = ", ")
.key_join <- function(keys) paste(sprintf("a.%s <=> b.%s", .bt(keys), .bt(keys)), collapse = " AND ")
# Parse a CLI flag's value, REQUIRING a non-flag argument follows (so `--sample-into`
# with no prefix fails fast instead of building a `NA_<table>` destination).
.flag_val <- function(a, flag) {
  i <- which(a == flag); if (!length(i)) return(NULL)
  v <- if (i[1] < length(a)) a[i[1] + 1L] else NA_character_
  if (is.na(v) || startsWith(v, "--")) stop(flag, " requires an argument")
  v
}

# --- canonical normalization (roadmap S14) --------------------------------
# Warehouse columns are already TYPED (DATE/INT/STRING), so the null-safe `<=>`
# operator compares dates as dates and ints as ints with one null semantics; no
# string coercion is needed (unlike the local CSV path). Float tolerance would be
# emitted per float column - none exist in the current output contract.
NORMALIZATION_NOTES <- c(
  "compare with the null-safe `<=>` on typed columns (one null semantics)",
  "order checksums by array_sort so the hash is partition-independent",
  "float columns (none today) would compare within tolerance via round()")

# --- SQL builders (pure; unit-tested) -------------------------------------
sql_schema <- function(tbl) sprintf("DESCRIBE TABLE %s", tbl)   # R diffs the returned columns+types

sql_membership <- function(tbl_a, tbl_b, keys) {
  k <- .keylist(keys)
  sprintf(paste0(
    "SELECT\n",
    "  (SELECT count(*) FROM (SELECT %s FROM %s EXCEPT SELECT %s FROM %s)) AS only_in_a,\n",
    "  (SELECT count(*) FROM (SELECT %s FROM %s EXCEPT SELECT %s FROM %s)) AS only_in_b"),
    k, tbl_a, k, tbl_b, k, tbl_b, k, tbl_a)
}

# ONE joined scan with per-column null-safe mismatch counts as conditional aggregates
# (positional aliases c0..c{n-1}), so a WIDE table (per-drug/class flags) needs a
# single join, not one full join per column. Excluded/gap handling is done in R
# (compare_values), keeping the SQL a single pass.
sql_values <- function(tbl_a, tbl_b, keys, compare_cols, excluded = character(0)) {
  cols <- setdiff(compare_cols, keys)
  on <- .key_join(keys)
  if (!length(cols)) return(sprintf("SELECT cast(0 as int) AS c0 FROM %s a JOIN %s b ON %s WHERE 1=0", tbl_a, tbl_b, on))
  aggs <- vapply(seq_along(cols), function(i) sprintf(
    "sum(CASE WHEN NOT (a.%s <=> b.%s) THEN 1 ELSE 0 END) AS c%d", .bt(cols[i]), .bt(cols[i]), i - 1L), character(1))
  sprintf("SELECT %s FROM %s a JOIN %s b ON %s", paste(aggs, collapse = ", "), tbl_a, tbl_b, on)
}

# Bounded diagnostic (run ONLY after a value mismatch): up to `limit` shared-key rows
# where any of the MISMATCHED `cols` differs, with both sides' values (a_<col>/b_<col>),
# so a failure is investigable without hand-written SQL. ORDER BY the keys makes the
# selected rows DETERMINISTIC across runs. `LIMIT` bounds the RETURNED rows (it does not
# bound the table scanned). PATIENT-LEVEL DATA: the caller persists this to governed
# storage (sql_value_sample_into) - it is never dumped to job logs (see the CLI).
sql_value_sample <- function(tbl_a, tbl_b, keys, cols, limit = 100L) {
  if (!length(cols)) return(NULL)
  on <- .key_join(keys)
  anydiff <- paste(sprintf("NOT (a.%s <=> b.%s)", .bt(cols), .bt(cols)), collapse = " OR ")
  ksel <- paste(sprintf("a.%s", .bt(keys)), collapse = ", ")
  vsel <- paste(unlist(lapply(cols, function(c)
    c(sprintf("a.%s AS `a_%s`", .bt(c), c), sprintf("b.%s AS `b_%s`", .bt(c), c)))), collapse = ", ")
  sprintf("SELECT %s, %s FROM %s a JOIN %s b ON %s WHERE %s ORDER BY %s LIMIT %d",
          ksel, vsel, tbl_a, tbl_b, on, anydiff, ksel, as.integer(limit))
}
# Governed persistence of the sample: CREATE the (patient-level) sample as a run-scoped
# table in an ACCESS-CONTROLLED schema, so the diagnostic never leaves governed storage
# (the CLI then prints only the table pointer + row count + columns, no patient data).
sql_value_sample_into <- function(dest_table, tbl_a, tbl_b, keys, cols, limit = 100L) {
  sel <- sql_value_sample(tbl_a, tbl_b, keys, cols, limit)
  if (is.null(sel)) return(NULL)
  sprintf("CREATE OR REPLACE TABLE %s AS %s", dest_table, sel)
}

# Per-table key integrity: a required key must be NON-NULL and UNIQUE. A duplicate
# OR a null-component key on EITHER side makes the set-based membership compare
# unsound (null `<=>` null is true), so both are checked explicitly and block the
# table verdict.
sql_key_uniqueness <- function(tbl, keys) {
  nullc <- paste(sprintf("%s IS NULL", .bt(keys)), collapse = " OR ")
  sprintf(paste0("SELECT (SELECT count(*) FROM (SELECT %s FROM %s GROUP BY %s HAVING count(*) > 1)) AS dup_keys, ",
                 "(SELECT count(*) FROM %s WHERE %s) AS null_keys"),
          .keylist(keys), tbl, .keylist(keys), tbl, nullc)
}

# Deterministic, partition-independent table hash: per-row md5 over the non-excluded
# columns, array_sort'd then joined and hashed. Nulls are coalesced to an explicit
# sentinel FIRST (concat_ws drops NULL args in Spark SQL, so without this two rows
# with nulls in different columns could hash the same). Early warning only.
sql_checksum <- function(tbl, keys, compare_cols, excluded = character(0)) {
  cols <- setdiff(compare_cols, excluded)
  parts <- sprintf("coalesce(cast(%s as string), '\\001NULL\\001')", .bt(cols))
  rowexpr <- sprintf("md5(concat_ws('\\037', %s))", paste(parts, collapse = ", "))
  sprintf("SELECT md5(array_join(array_sort(collect_list(%s)), '|')) AS checksum FROM %s", rowexpr, tbl)
}

# --- steps (execute the builders via the db_q seam) -----------------------
# DESCRIBE TABLE returns col_name/data_type/comment and, for partitioned tables,
# a blank row + a "# Partition Information" section - drop those. Returns a
# lower(name) -> lower(type) map so the schema compare covers TYPES, not just names.
describe_schema <- function(con, tbl) {
  d <- db_q(con, sql_schema(tbl))
  nm <- trimws(as.character(d$col_name %||% d[[1]]))
  ty <- trimws(as.character(d$data_type %||% d[[2]]))
  keep <- nzchar(nm) & !startsWith(nm, "#") & !duplicated(tolower(nm))
  setNames(tolower(ty[keep]), tolower(nm[keep]))
}
# Pure: name AND type parity. A column on one side only, OR a type drift
# (LOT_START_DT string vs date), fails schema parity.
compare_schema_maps <- function(sa, sb) {
  a_only <- setdiff(names(sa), names(sb)); b_only <- setdiff(names(sb), names(sa))
  shared <- intersect(names(sa), names(sb))
  type_mismatch <- shared[sa[shared] != sb[shared]]
  list(ok = length(a_only) == 0 && length(b_only) == 0 && length(type_mismatch) == 0,
       a_only = a_only, b_only = b_only, type_mismatch = type_mismatch)
}
# Auto-detect the patient-id column from the actual schema (PATID legacy vs
# patient_id canonical), so --run needs no flag for the apr_30 output tables.
.detect_patid <- function(cols) {
  lc <- tolower(cols)
  if ("patient_id" %in% lc) return("patient_id")
  if ("patid" %in% lc) return("PATID")
  "patient_id"
}
# Resolve side A's id column: an explicit --patid override is honored ONLY when that
# column is actually present on side A (else fall back to auto-detect). This keeps a
# wrong/stale override on a cross-convention compare from normalizing a side against
# a column it does not have. --patid is for a NONSTANDARD id name; cross-convention
# (PATID vs patient_id) needs no flag (each side is detected independently).
.resolve_patid <- function(patid, cols) {
  if (!is.null(patid) && tolower(patid) %in% tolower(cols)) patid else .detect_patid(cols)
}
# Normalize one side's id column to canonical `patient_id` (pure: returns the
# CREATE VIEW DDL). Used to bridge a CROSS-CONVENTION compare (legacy PATID on one
# side, canonical patient_id on the other). The id is CAST to the canonical type
# (STRING, per contracts/inputs.md) so a numeric legacy PATID and a string canonical
# patient_id reconcile at the key without failing schema-type parity; all OTHER
# columns pass through unchanged (genuine type drift elsewhere still blocks). Policy:
# the id is compared as the canonical STRING type on both sides.
sql_normalize_view <- function(view, tbl, cols, id_col) {
  others <- cols[tolower(cols) != tolower(id_col)]
  proj <- paste(c(sprintf("CAST(%s AS STRING) AS `patient_id`", .bt(id_col)), .bt(others)), collapse = ", ")
  sprintf("CREATE OR REPLACE TEMPORARY VIEW %s AS SELECT %s FROM %s", view, proj, tbl)
}
.cmp_view <- function(table_name, side) sprintf("cmpnorm_%s_%s", gsub("[^A-Za-z0-9_]", "_", table_name), side)
# All SHARED non-key columns to value-compare (not just the curated contract), so
# a current-vs-prior diff also catches the per-drug / per-class wide columns.
value_compare_cols <- function(cols_a, cols_b, keys)
  setdiff(intersect(tolower(cols_a), tolower(cols_b)), tolower(keys))

compare_membership <- function(con, tbl_a, tbl_b, keys) {
  r <- db_q(con, sql_membership(tbl_a, tbl_b, keys))
  list(only_in_a = r$only_in_a[1], only_in_b = r$only_in_b[1])
}
compare_key_uniqueness <- function(con, tbl, keys) {
  r <- db_q(con, sql_key_uniqueness(tbl, keys)); list(dup = r$dup_keys[1], null = r$null_keys[1])
}

# Pure: turn the one-row per-column mismatch counts (c0..c{n-1}) into the verdict
# tally, splitting blocking from excluded/gap columns (done in R, not SQL). Counts
# stay DOUBLE (the warehouse SUM is BIGINT) - as.integer would narrow to 32-bit and
# silently turn a >2^31 count into NA->0 (a missed mismatch on a large study).
.tally_values <- function(counts, cols, excluded = character(0)) {
  counts <- suppressWarnings(as.numeric(counts)); counts[is.na(counts)] <- 0
  is_excl <- tolower(cols) %in% tolower(excluded)
  blk <- counts > 0 & !is_excl
  list(mismatched_columns = cols[blk], value_mismatch = sum(counts[blk]),
       excluded_diffs = sum(counts[counts > 0 & is_excl]))
}
compare_values <- function(con, tbl_a, tbl_b, keys, compare_cols, excluded = character(0)) {
  cols <- setdiff(compare_cols, keys)
  if (!length(cols)) return(list(mismatched_columns = character(0), value_mismatch = 0L, excluded_diffs = 0L))
  r <- db_q(con, sql_values(tbl_a, tbl_b, keys, compare_cols, excluded))   # one row: c0..c{n-1} counts
  .tally_values(unlist(r[1, seq_along(cols)], use.names = FALSE), cols, excluded)
}

table_checksum <- function(con, tbl, keys, compare_cols, excluded = character(0))
  db_q(con, sql_checksum(tbl, keys, compare_cols, excluded))$checksum[1]

# The contract is in canonical names. Databricks identifiers are case-insensitive
# (LOT_NUM == lot_num), so only patient_id genuinely differs from the legacy tables
# (PATID). `patid` remaps it; NULL = auto-detect from the table schema.
.remap_patid <- function(v, patid) if (identical(patid, "patient_id")) v else gsub("^patient_id$", patid, v)
# Runs the hierarchy SEQUENTIALLY and STOPS at the first decisive gap (so a missing
# column never triggers an unresolved-column error in a later value/checksum query,
# and a failed table does no needless full-table work):
#   schema(name+type) + contract -> key integrity (non-null + unique) ->
#   membership -> values -> checksum (only after the authoritative checks pass).
compare_table <- function(con, tbl_a, tbl_b, table_name, patid = NULL, unimplemented = character(0),
                          sample_into = NULL) {
  if (is.null(COMPARE_KEYS[[table_name]])) stop("no COMPARE_KEYS for ", table_name)
  sa <- describe_schema(con, tbl_a); sb <- describe_schema(con, tbl_b)
  id_a <- .resolve_patid(patid, names(sa)); id_b <- .detect_patid(names(sb))
  # Cross-convention bridge: when the two sides name the patient id differently
  # (legacy PATID vs canonical patient_id - the actual legacy-vs-refactored case),
  # normalize EACH non-canonical side to `patient_id` via a temp view BEFORE schema/
  # key/value comparison, then compare on canonical keys. Same-convention runs keep
  # the legacy remap path (no view), so the existing single-name behavior is intact.
  if (tolower(id_a) != tolower(id_b)) {
    if (tolower(id_a) != "patient_id") { v <- .cmp_view(table_name, "a")
      db_exec(con, sql_normalize_view(v, tbl_a, names(sa), id_a)); tbl_a <- v; sa <- describe_schema(con, v) }
    if (tolower(id_b) != "patient_id") { v <- .cmp_view(table_name, "b")
      db_exec(con, sql_normalize_view(v, tbl_b, names(sb), id_b)); tbl_b <- v; sb <- describe_schema(con, v) }
    patid <- "patient_id"
  } else patid <- id_a
  keys <- .remap_patid(COMPARE_KEYS[[table_name]], patid)
  excl <- .remap_patid(union(EXCLUDED_FIELDS[[table_name]] %||% character(0), unimplemented), patid)
  required <- .remap_patid(OUTPUT_CONTRACT[[table_name]] %||% keys, patid)
  sch <- compare_schema_maps(sa, sb)
  miss_req <- setdiff(tolower(required), intersect(names(sa), names(sb)))
  gaps <- .present_gaps(unimplemented, intersect(names(sa), names(sb)))   # caller-scoped gap fields present
  res <- list(table = table_name, patid = patid, schema = sch, unimplemented = gaps,
              partial = length(gaps) > 0, contract_ok = length(miss_req) == 0, missing_required = miss_req)
  if (!sch$ok || length(miss_req)) return(res)                 # decisive: schema/contract
  ka <- compare_key_uniqueness(con, tbl_a, keys); kb <- compare_key_uniqueness(con, tbl_b, keys)
  res$key_unique <- ka$dup == 0 && kb$dup == 0 && ka$null == 0 && kb$null == 0
  res$dup_keys_a <- ka$dup; res$dup_keys_b <- kb$dup; res$null_keys_a <- ka$null; res$null_keys_b <- kb$null
  if (!res$key_unique) return(res)                              # decisive: null/duplicate keys
  cmpset <- value_compare_cols(names(sa), names(sb), keys)
  res$membership <- compare_membership(con, tbl_a, tbl_b, keys)
  if (!isTRUE(res$membership$only_in_a == 0) || !isTRUE(res$membership$only_in_b == 0))
    return(res)                                                # decisive: population differs - skip the per-column join
  res$values <- if (length(cmpset))
    compare_values(con, tbl_a, tbl_b, keys, c(tolower(keys), cmpset), tolower(excl))
    else list(mismatched_columns = character(0), value_mismatch = 0L, excluded_diffs = 0L)
  # On a value mismatch ONLY (never a clean run), produce a BOUNDED diagnostic sample of
  # the changed keys + a/b values. PATIENT-LEVEL: when `sample_into` is set, the sample
  # is WRITTEN to a run-scoped GOVERNED table (<sample_into>_<table>) and only its
  # pointer is kept (never returned to the caller / logs); otherwise the data.frame is
  # captured in-process for governed handling by the caller - the CLI prints neither.
  # Failure-isolated: a sample error records a warning, never aborts the verdict.
  if (length(res$values$mismatched_columns)) {
    mc <- res$values$mismatched_columns
    if (!is.null(sample_into)) {
      dest <- sprintf("%s_%s", sample_into, table_name)
      ok <- tryCatch({ db_exec(con, sql_value_sample_into(dest, tbl_a, tbl_b, keys, mc, 100L)); TRUE },
                     error = function(e) { res$sample_warning <<- conditionMessage(e); FALSE })
      if (ok) { res$value_sample_table <- dest
        res$value_sample_n <- tryCatch(as.numeric(db_q(con, sprintf("SELECT count(*) AS n FROM %s", dest))$n[1]),
                                       error = function(e) NA_real_) }
    } else {
      res$value_sample <- tryCatch(db_q(con, sql_value_sample(tbl_a, tbl_b, keys, mc, 100L)),
                                   error = function(e) { res$sample_warning <<- conditionMessage(e); NULL })
    }
  }
  # checksum is a NON-AUTHORITATIVE early-warning audit signal: computed ONLY after the
  # membership + value checks pass, and FAILURE-ISOLATED (a global aggregate that could
  # exhaust memory / hit a warehouse limit on a wide table must NOT abort the completed
  # authoritative comparison - it is recorded as a warning instead).
  if (isTRUE((res$membership$only_in_a %||% 1) == 0) && isTRUE((res$membership$only_in_b %||% 1) == 0) &&
      isTRUE((res$values$value_mismatch %||% 1) == 0)) {
    ck <- function(tbl) tryCatch(table_checksum(con, tbl, keys, c(tolower(keys), cmpset), tolower(excl)),
                                 error = function(e) { res$checksum_warning <<- conditionMessage(e); NA_character_ })
    res$checksum_a <- ck(tbl_a); res$checksum_b <- ck(tbl_b)
  }
  res
}

# --- LOCAL CSV comparison (real; the same hierarchy, runnable without a warehouse) --
# Used by the unit tests and for comparing exported CSVs; the db_q path above is
# the hive_metastore (Databricks SQL) equivalent for large run-scoped tables.
.norm_cell <- function(x) { x <- trimws(as.character(x)); x[is.na(x) | x == ""] <- "\001NULL\001"; x }

# Cell equality AFTER canonical normalization (the documented rules, applied here
# for the local CSV path): single null sentinel, numeric coercion with float
# tolerance, and date coercion (so a timestamp export equals its date). A
# leading-zero string (e.g. an 11-digit NDC, a zero-padded id) is NOT coerced to a
# number, so "00002143380" never equals "2143380".
.num_eligible <- function(s) grepl("^-?([0-9]+|[0-9]*\\.[0-9]+)([eE][-+]?[0-9]+)?$", s) & !grepl("^-?0[0-9]", s)
.date_eligible <- function(s) grepl("^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}", s)   # date or timestamp prefix
.as_date <- function(s) suppressWarnings(as.Date(ifelse(.date_eligible(s), s, NA_character_), format = "%Y-%m-%d"))
.cells_equal <- function(a, b, tol = 1e-9) {
  eq <- a == b
  cmp <- !eq & a != "\001NULL\001" & b != "\001NULL\001"     # both present, differ as strings
  an <- suppressWarnings(as.numeric(a)); bn <- suppressWarnings(as.numeric(b))
  numok <- cmp & .num_eligible(a) & .num_eligible(b) & !is.na(an) & !is.na(bn) &
           abs(an - bn) <= tol * pmax(1, abs(an), abs(bn))
  rem <- cmp & !numok
  ad <- .as_date(a); bd <- .as_date(b)                       # explicit format -> NA, never errors
  dateok <- rem & !is.na(ad) & !is.na(bd) & ad == bd
  eq | numok | dateok
}

# Canonical cell form for the CHECKSUM, so the compact audit signal uses the SAME
# normalization as the verdict (1 vs 1.0, a timestamp vs its date, hash identically).
.canon_cell <- function(x) {
  v <- .norm_cell(x)
  ne <- .num_eligible(v)
  if (any(ne)) v[ne] <- format(as.numeric(v[ne]), scientific = FALSE, trim = TRUE)
  de <- !ne & .date_eligible(v); dd <- .as_date(v[de])
  if (any(de)) v[de] <- as.character(dd)
  v
}

compare_local_table <- function(path_a, path_b, keys, excluded = character(0), required = character(0),
                                unimplemented = character(0)) {
  a <- read.csv(path_a, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character")
  b <- read.csv(path_b, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character")
  res <- list(schema_ok = TRUE, contract_ok = TRUE, key_unique = TRUE, only_in_a = 0L,
              only_in_b = 0L, value_mismatch = 0L, excluded_diffs = 0L,
              mismatch_cols = character(0), sample = NULL, partial = FALSE,
              unimplemented = character(0), verdict = "mismatch")
  excluded <- union(excluded, unimplemented)                   # gap fields are non-blocking, like excluded
  # Output contract: BOTH sides must carry the required columns, so two equally
  # incomplete outputs cannot be called behaviourally equivalent.
  miss_a <- setdiff(required, names(a)); miss_b <- setdiff(required, names(b))
  if (length(miss_a) || length(miss_b)) {
    res$contract_ok <- FALSE; res$match <- FALSE
    res$missing_required <- list(a = miss_a, b = miss_b)
    return(res)
  }
  if (!all(keys %in% names(a)) || !all(keys %in% names(b))) {  # keys before indexing
    res$match <- FALSE; res$missing_keys <- TRUE; return(res)
  }
  if (!identical(sort(names(a)), sort(names(b)))) {
    res$schema_ok <- FALSE; res$match <- FALSE
    res$schema_detail <- sprintf("a-only:{%s} b-only:{%s}",
      paste(setdiff(names(a), names(b)), collapse = ","), paste(setdiff(names(b), names(a)), collapse = ","))
    return(res)
  }
  ka <- do.call(paste, c(a[keys], sep = "\037")); kb <- do.call(paste, c(b[keys], sep = "\037"))
  nullk <- function(df) Reduce(`|`, lapply(df[keys], function(c) is.na(c) | !nzchar(trimws(as.character(c)))))
  # parity with the live path: a missing key COMPONENT is not "unique" either
  res$key_unique <- !(any(duplicated(ka)) || any(duplicated(kb)) || any(nullk(a)) || any(nullk(b)))
  if (!res$key_unique) { res$match <- FALSE; return(res) }       # decisive: stop here
  res$only_in_a <- sum(!(ka %in% kb)); res$only_in_b <- sum(!(kb %in% ka))
  res$unimplemented <- .present_gaps(unimplemented, names(a)); res$partial <- length(res$unimplemented) > 0
  if (res$only_in_a > 0 || res$only_in_b > 0) {   # populations differ: STOP before the column compare
    res$verdict <- "mismatch"; res$match <- FALSE; return(res)   # matches README + the --run path
  }
  shared <- intersect(ka, kb); ia <- match(shared, ka); ib <- match(shared, kb)
  for (cn in setdiff(names(a), keys)) {
    va <- .norm_cell(a[[cn]][ia]); vb <- .norm_cell(b[[cn]][ib]); d <- which(!.cells_equal(va, vb))
    if (length(d)) {
      if (cn %in% excluded) {            # surfaced (not blocking), never silent
        res$excluded_diffs <- res$excluded_diffs + length(d)
      } else {
        res$value_mismatch <- res$value_mismatch + length(d)
        res$mismatch_cols <- union(res$mismatch_cols, cn)
        if (is.null(res$sample)) res$sample <- sprintf("key=%s col=%s a=%s b=%s", shared[d[1]], cn, va[d[1]], vb[d[1]])
      }
    }
  }
  keep <- setdiff(names(a), excluded)                        # checksum uses the canonical cell
  ca <- as.data.frame(lapply(a[keep], .canon_cell), stringsAsFactors = FALSE, check.names = FALSE)
  cb <- as.data.frame(lapply(b[keep], .canon_cell), stringsAsFactors = FALSE, check.names = FALSE)
  res$checksum_a <- content_hash(ca[order(ka), , drop = FALSE])
  res$checksum_b <- content_hash(cb[order(kb), , drop = FALSE])
  clean <- res$schema_ok && res$contract_ok && res$key_unique &&
           res$only_in_a == 0 && res$only_in_b == 0 && res$value_mismatch == 0
  res$match <- clean && !res$partial             # a known-gap (unimplemented) run is partial, not full
  res$verdict <- if (!clean) "mismatch" else if (res$partial) "partial_match" else "match"
  res
}

# `tables` are REQUIRED outputs: a missing one is a blocking mismatch (fail
# closed), never silently skipped. `unimplemented` is CALLER-scoped, like the
# warehouse `compare_run`: it DEFAULTS to none (strict - two production CSV exports
# compare every field), and the local engine-vs-golden caller passes the engine
# profile (`UNIMPLEMENTED_FIELDS`) so contains_mtx_reg yields partial_match.
compare_local <- function(dir_a, dir_b, tables = names(COMPARE_KEYS), unimplemented = list()) {
  out <- list(); missing <- character(0)
  for (t in tables) {
    fa <- file.path(dir_a, paste0(t, ".csv")); fb <- file.path(dir_b, paste0(t, ".csv"))
    if (!file.exists(fa) || !file.exists(fb)) {
      missing <- c(missing, t)
      out[[t]] <- list(match = FALSE, verdict = "mismatch",
                       missing = c(if (!file.exists(fa)) "a", if (!file.exists(fb)) "b"))
      next
    }
    out[[t]] <- compare_local_table(fa, fb, COMPARE_KEYS[[t]], EXCLUDED_FIELDS[[t]] %||% character(0),
                                    OUTPUT_CONTRACT[[t]] %||% character(0), unimplemented[[t]] %||% character(0))
  }
  v <- vapply(out, function(r) r$verdict %||% (if (isTRUE(r$match)) "match" else "mismatch"), character(1))
  attr(out, "missing_tables") <- missing
  # partial_match (a known unimplemented field) ranks BELOW match and ABOVE mismatch.
  attr(out, "verdict") <- if (length(missing) || any(v == "mismatch")) "mismatch" else
                          if (any(v == "partial_match")) "partial_match" else "match"
  out
}

# Compare a full run (all three output tables) in the hive_metastore catalog.
# Prior-vs-current are BOTH production, so `unimplemented` defaults to none (every
# field compared strictly; a full `match` is reachable). Pass a per-table gap map
# only when one side provably lacks a deterministic field (e.g. the local engine).
compare_run <- function(con, ns_a, ns_b, tables = names(COMPARE_KEYS), patid = NULL, unimplemented = list(),
                        sample_into = NULL) {
  results <- lapply(tables, function(t)
    compare_table(con, paste0(ns_a, ".", t), paste0(ns_b, ".", t), t, patid,
                  unimplemented[[t]] %||% character(0), sample_into))
  names(results) <- tables
  clean_one <- function(r) isTRUE(r$schema$ok) && isTRUE(r$key_unique) && isTRUE(r$contract_ok) &&
    isTRUE((r$membership$only_in_a %||% NA) == 0) && isTRUE((r$membership$only_in_b %||% NA) == 0) &&
    isTRUE((r$values$value_mismatch %||% NA) == 0)
  verdict_one <- function(r) if (!clean_one(r)) "mismatch" else if (isTRUE(r$partial)) "partial_match" else "match"
  v <- vapply(results, verdict_one, character(1))
  list(verdict = if (any(v == "mismatch")) "mismatch" else
                 if (any(v == "partial_match")) "partial_match" else "match",
       tables = results)
}

if (sys.nframe() == 0 && !interactive()) {
  a <- commandArgs(trailingOnly = TRUE)
  if (length(a) >= 3 && a[1] == "--run") {        # live: compare two hive_metastore namespaces
    patid <- .flag_val(a, "--patid"); sample_into <- .flag_val(a, "--sample-into")
    con <- connect_compare()
    on.exit(try(DBI::dbDisconnect(con), silent = TRUE))
    rr <- compare_run(con, a[2], a[3], patid = patid, sample_into = sample_into)
    for (t in names(rr$tables)) { r <- rr$tables[[t]]
      # Per-table status is METADATA ONLY - no patient-level values are printed to the
      # job log. A value-diff sample (if any) is in a governed table or the in-process
      # object; the log shows only its pointer/row count + the affected columns.
      flags <- c(
        if (!isTRUE(r$schema$ok)) sprintf("SCHEMA{a_only:%s b_only:%s type:%s}",
            paste(r$schema$a_only, collapse = ","), paste(r$schema$b_only, collapse = ","),
            paste(r$schema$type_mismatch, collapse = ",")),
        if (!isTRUE(r$contract_ok)) paste0("missing_required:", paste(r$missing_required, collapse = ",")),
        if (!isTRUE(r$key_unique)) sprintf("KEYS{dup_a:%s dup_b:%s null_a:%s null_b:%s}",
            r$dup_keys_a, r$dup_keys_b, r$null_keys_a, r$null_keys_b),
        if (length(r$values$mismatched_columns)) paste0("cols:", paste(r$values$mismatched_columns, collapse = ",")),
        if ((r$values$excluded_diffs %||% 0) > 0) sprintf("excluded_diffs=%s", r$values$excluded_diffs),
        if (!is.null(r$checksum_warning)) sprintf("CHECKSUM_FAILED(audit-only):%s", r$checksum_warning),
        if (!is.null(r$value_sample_table)) sprintf("sample_table:%s(rows=%s; cols in `cols:` above)",
            r$value_sample_table, r$value_sample_n %||% "?"),
        if (!is.null(r$value_sample) && nrow(r$value_sample)) sprintf("sample:%d_rows(in-process,not-logged)", nrow(r$value_sample)),
        if (!is.null(r$sample_warning)) sprintf("SAMPLE_FAILED(audit-only):%s", r$sample_warning),
        if (length(r$unimplemented)) sprintf("PARTIAL{unimplemented:%s}", paste(r$unimplemented, collapse = ",")))
      cat(sprintf("%-12s patid=%-10s only_in_a=%s only_in_b=%s value_mismatch=%s %s\n",
          t, r$patid, r$membership$only_in_a %||% "NA", r$membership$only_in_b %||% "NA",
          r$values$value_mismatch %||% "NA", paste(flags, collapse = " "))) }
    cat("verdict:", rr$verdict, "\n")
    if (identical(rr$verdict, "partial_match"))
      cat("  NOTE: partial_match excludes unimplemented deterministic field(s); NOT full equivalence.\n")
    quit(status = if (identical(rr$verdict, "match")) 0L else if (identical(rr$verdict, "partial_match")) 2L else 1L)
  }
  if (length(a) >= 3 && a[1] == "--local") {
    # STRICT by default (two production exports compare every field); --engine applies
    # the local-engine gap profile so contains_mtx_reg yields partial_match.
    eng <- "--engine" %in% a
    res <- compare_local(a[2], a[3], unimplemented = if (eng) UNIMPLEMENTED_FIELDS else list())
    for (t in names(res)) { r <- res[[t]]
      v <- r$verdict %||% (if (isTRUE(r$match)) "match" else "mismatch")   # 3-way, like --run
      detail <- character(0)
      if (length(r$mismatch_cols)) detail <- c(detail, paste0("cols:", paste(r$mismatch_cols, collapse = ",")))
      if (isTRUE(r$contract_ok == FALSE)) detail <- c(detail,
          sprintf("missing_required:{a:%s b:%s}", paste(r$missing_required$a, collapse = ","),
                  paste(r$missing_required$b, collapse = ",")))
      if ((r$excluded_diffs %||% 0L) > 0L) detail <- c(detail,   # surfaced, never silent
          sprintf("excluded_diffs=%d (informational)", r$excluded_diffs))
      if (length(r$unimplemented)) detail <- c(detail, sprintf("unimplemented:%s", paste(r$unimplemented, collapse = ",")))
      cat(sprintf("%-12s %s (only_in_a=%d only_in_b=%d value_mismatch=%d %s)\n",
          t, toupper(v), r$only_in_a %||% 0L, r$only_in_b %||% 0L, r$value_mismatch %||% 0L,
          paste(detail, collapse = " "))) }
    verdict <- attr(res, "verdict")
    cat("verdict:", verdict, "\n")
    if (identical(verdict, "partial_match"))
      cat("  NOTE: partial_match excludes unimplemented deterministic field(s); NOT full equivalence.\n")
    quit(status = if (identical(verdict, "match")) 0L else if (identical(verdict, "partial_match")) 2L else 1L)
  }
  cat("compare_run_outputs.R. Local CSV: --local <dir_a> <dir_b> [--engine];",
      "(both STRICT by default; --engine applies the local-engine gap profile).",
      "live hive_metastore: --run <ns_prior> <ns_current> [--patid PATID]",
      "[--sample-into <governed.table_prefix>] (patient-level diff samples are written",
      "there, NOT to the log; DATABRICKS_DSN/DATABRICKS_PWD env; ns e.g. hive_metastore.lot_prior).\n")
}
