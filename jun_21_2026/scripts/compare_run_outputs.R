#!/usr/bin/env Rscript
# compare_run_outputs.R
# Authoritative patient-level comparison of two LOT output sets:
#   actual   vs  expected (regression-expected, generated from legacy@baseline)
#   refactored vs legacy   (LOT_ENGINE_MODE=compare, run-scoped namespaces)
#
# SKELETON. The comparison LOGIC and ordering are authoritative; the Spark
# queries are stubbed (`db_q`) for the live Databricks adapter. Full
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
  LOT_LONG  = c("lot_base_1st_add_med")
)

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

# --- Databricks adapter (stub) -------------------------------------------
# Replace with the project db_q/db_exec against the non-prod test connection.
db_q <- function(con, sql) stop("db_q stub: wire to the Databricks adapter; sql=\n", sql)

# --- canonical normalization (--14) ---------------------------------------
# Applied in-SQL before comparison: deterministic sort, one null representation,
# numeric coercion, float tolerance, NDC string form. Documented here, emitted
# into the comparison SQL by the adapter.
NORMALIZATION_NOTES <- c(
  "sort by the table's COMPARE_KEYS",
  "null -> a single canonical sentinel before equality",
  "dates compared as DATE (no tz); numerics coerced; floats within tolerance",
  "arrays compared as ordered unless declared unordered"
)

# --- steps ---------------------------------------------------------------

compare_schema <- function(con, tbl_a, tbl_b) {
  # TODO: DESCRIBE both; compare column names+types; key uniqueness counts.
  # Returns list(ok, detail). Decisive: a schema/key mismatch stops here.
  list(ok = NA, detail = "schema+key-uniqueness compare (stub)")
}

compare_membership <- function(con, tbl_a, tbl_b, keys) {
  # Anti-joins on `keys`: only-in-a, only-in-b counts + a bounded sample of PATIDs.
  list(only_in_a = NA_integer_, only_in_b = NA_integer_, sample = NULL)
}

compare_values <- function(con, tbl_a, tbl_b, keys, excluded = character(0)) {
  # Inner-join on keys; per-column mismatch counts (excluding `excluded`),
  # AFTER canonical normalization; returns a bounded sample of (key, column,
  # value_a, value_b). This is the authoritative gate.
  list(mismatched_columns = NULL, mismatched_rows = NA_integer_, sample = NULL)
}

table_checksum <- function(con, tbl, keys) {
  # Deterministic sorted hash AFTER canonical sort+normalize (not per-partition).
  # Early-warning only; never the release authority.
  NA_character_
}

compare_table <- function(con, tbl_a, tbl_b, table_name) {
  keys <- COMPARE_KEYS[[table_name]]
  excl <- EXCLUDED_FIELDS[[table_name]] %||% character(0)
  if (is.null(keys)) stop("no COMPARE_KEYS for ", table_name)
  list(
    table      = table_name,
    schema     = compare_schema(con, tbl_a, tbl_b),
    membership = compare_membership(con, tbl_a, tbl_b, keys),
    values     = compare_values(con, tbl_a, tbl_b, keys, excl),
    checksum_a = table_checksum(con, tbl_a, keys),
    checksum_b = table_checksum(con, tbl_b, keys)
  )
}

# --- LOCAL CSV comparison (real; the same hierarchy, runnable without Spark) --
# Used by the unit tests and for comparing exported CSVs; the db_q path above is
# the Spark equivalent for large run-scoped tables.
.norm_cell <- function(x) { x <- trimws(as.character(x)); x[is.na(x) | x == ""] <- "\001NULL\001"; x }

compare_local_table <- function(path_a, path_b, keys, excluded = character(0), required = character(0)) {
  a <- read.csv(path_a, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character")
  b <- read.csv(path_b, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character")
  res <- list(schema_ok = TRUE, contract_ok = TRUE, key_unique = TRUE, only_in_a = 0L,
              only_in_b = 0L, value_mismatch = 0L, excluded_diffs = 0L,
              mismatch_cols = character(0), sample = NULL)
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
  res$key_unique <- !(any(duplicated(ka)) || any(duplicated(kb)))
  res$only_in_a <- sum(!(ka %in% kb)); res$only_in_b <- sum(!(kb %in% ka))
  shared <- intersect(ka, kb); ia <- match(shared, ka); ib <- match(shared, kb)
  for (cn in setdiff(names(a), keys)) {
    va <- .norm_cell(a[[cn]][ia]); vb <- .norm_cell(b[[cn]][ib]); d <- which(va != vb)
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
  res$checksum_a <- content_hash(a[order(ka), setdiff(names(a), excluded), drop = FALSE])
  res$checksum_b <- content_hash(b[order(kb), setdiff(names(b), excluded), drop = FALSE])
  res$match <- res$schema_ok && res$contract_ok && res$key_unique &&
               res$only_in_a == 0 && res$only_in_b == 0 && res$value_mismatch == 0
  res
}

# `tables` are REQUIRED outputs: a missing one is a blocking mismatch (fail
# closed), never silently skipped. Returns the per-table results plus a
# `missing_tables` attribute and a verdict that is "match" only when every
# required table is present AND matches.
compare_local <- function(dir_a, dir_b, tables = names(COMPARE_KEYS)) {
  out <- list(); overall <- TRUE; missing <- character(0)
  for (t in tables) {
    fa <- file.path(dir_a, paste0(t, ".csv")); fb <- file.path(dir_b, paste0(t, ".csv"))
    if (!file.exists(fa) || !file.exists(fb)) {
      missing <- c(missing, t); overall <- FALSE
      out[[t]] <- list(match = FALSE,
                       missing = c(if (!file.exists(fa)) "a", if (!file.exists(fb)) "b"))
      next
    }
    r <- compare_local_table(fa, fb, COMPARE_KEYS[[t]], EXCLUDED_FIELDS[[t]] %||% character(0),
                             OUTPUT_CONTRACT[[t]] %||% character(0))
    out[[t]] <- r; if (!isTRUE(r$match)) overall <- FALSE
  }
  attr(out, "missing_tables") <- missing
  attr(out, "verdict") <- if (overall) "match" else "mismatch"
  out
}

# Compare a full run (all three output tables). Returns "match" / "mismatch".
compare_run <- function(con, ns_a, ns_b, tables = names(COMPARE_KEYS)) {
  results <- lapply(tables, function(t)
    compare_table(con, paste0(ns_a, ".", t), paste0(ns_b, ".", t), t))
  names(results) <- tables
  # A run matches only if every table matches on membership AND values.
  # (Stub returns NA until db_q is wired; integration test asserts "match".)
  list(verdict = "stub", tables = results)
}

if (sys.nframe() == 0 && !interactive()) {
  a <- commandArgs(trailingOnly = TRUE)
  if (length(a) >= 3 && a[1] == "--local") {
    res <- compare_local(a[2], a[3])
    for (t in names(res)) { r <- res[[t]]
      detail <- character(0)
      if (length(r$mismatch_cols)) detail <- c(detail, paste0("cols:", paste(r$mismatch_cols, collapse = ",")))
      if (isTRUE(r$contract_ok == FALSE)) detail <- c(detail,
          sprintf("missing_required:{a:%s b:%s}", paste(r$missing_required$a, collapse = ","),
                  paste(r$missing_required$b, collapse = ",")))
      if ((r$excluded_diffs %||% 0L) > 0L) detail <- c(detail,   # surfaced, never silent
          sprintf("excluded_diffs=%d (informational)", r$excluded_diffs))
      cat(sprintf("%-12s %s (only_in_a=%d only_in_b=%d value_mismatch=%d %s)\n",
          t, if (isTRUE(r$match)) "MATCH" else "MISMATCH",
          r$only_in_a %||% 0L, r$only_in_b %||% 0L, r$value_mismatch %||% 0L,
          paste(detail, collapse = " "))) }
    cat("verdict:", attr(res, "verdict"), "\n")
    quit(status = if (identical(attr(res, "verdict"), "match")) 0L else 1L)
  }
  cat("compare_run_outputs.R loaded. Local: --local <dir_a> <dir_b>;",
      "Spark: wire db_q() for run-scoped namespaces.\n")
}
