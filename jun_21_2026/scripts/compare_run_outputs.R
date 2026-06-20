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

# Per-table comparison keys (see contracts/outputs.md).
COMPARE_KEYS <- list(
  MAP_STACKED = c("patient_id", "med_abbr", "map_cnt"),
  LOT1_BASE   = c("patient_id"),
  LOT_LONG    = c("patient_id", "lot_num")
)
# Display-only fields excluded from the strict value compare (see
# tests/fixtures/expected/nondeterministic.md). State-influencing fields are
# NOT listed here and must be deterministic.
EXCLUDED_FIELDS <- list(
  LOT1_BASE = c("lot1_base_1st_add_med_dt"),
  LOT_LONG  = c("lot_base_1st_add_med_dt")
)

# --- Databricks adapter (stub) -------------------------------------------
# Replace with the project db_q/db_exec against the non-prod test connection.
db_q <- function(con, sql) stop("db_q stub: wire to the Databricks adapter; sql=\n", sql)

# --- canonical normalization (§14) ---------------------------------------
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

`%||%` <- function(a, b) if (is.null(a)) b else a

# Compare a full run (all three output tables). Returns "match" / "mismatch".
compare_run <- function(con, ns_a, ns_b, tables = names(COMPARE_KEYS)) {
  results <- lapply(tables, function(t)
    compare_table(con, paste0(ns_a, ".", t), paste0(ns_b, ".", t), t))
  names(results) <- tables
  # A run matches only if every table matches on membership AND values.
  # (Stub returns NA until db_q is wired; integration test asserts "match".)
  list(verdict = "stub", tables = results)
}

if (sys.nframe() == 0 && !interactive())
  cat("compare_run_outputs.R: skeleton loaded. Wire db_q() to the non-prod",
      "Databricks adapter, then compare run-scoped namespaces.\n")
