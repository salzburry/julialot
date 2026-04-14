# ============================================================
# codelists.R — Quarterly table helpers
# ============================================================
# Pure functions for Optum CDM quarterly table naming.
# cdm_src() and cdm_quarterly() live in make_naming_helpers()
# (db_utils.R) since they close over cfg.
# get_code_source() was a trivial ref() wrapper — inlined at call sites.

# ---- Quarterly table helpers (Optum CDM t_<table>_YYYYqQ pattern) ----
get_quarter_suffix <- function(date_str) {
  d <- as.Date(date_str)
  paste0(format(d, "%Y"), "q", ceiling(as.integer(format(d, "%m")) / 3))
}

get_quarterly_table <- function(base_table, date_str) {
  paste0("t_", base_table, "_", get_quarter_suffix(date_str))
}
