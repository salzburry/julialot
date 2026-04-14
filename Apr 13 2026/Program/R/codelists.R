# ============================================================
# codelists.R — Server-side code list loading + quarterly tables
# ============================================================
# Runtime source of truth: server-side reference tables in ref_schema.
# Embedded R code lists have been removed — if a reference table is
# missing, the pipeline fails loudly rather than silently falling back.

# ---- Quarterly table helpers (Optum CDM t_<table>_YYYYqQ pattern) ----
get_quarter_suffix <- function(date_str) {
  d <- as.Date(date_str)
  paste0(format(d, "%Y"), "q", ceiling(as.integer(format(d, "%m")) / 3))
}

get_quarterly_table <- function(base_table, date_str) {
  paste0("t_", base_table, "_", get_quarter_suffix(date_str))
}

cdm_quarterly <- function(base_table) {
  cdm(get_quarterly_table(base_table, cfg$study_end))
}

# Resolve table name: quarterly if enabled, else standard CDM
cdm_src <- function(base_table) {
  if (isTRUE(cfg$use_quarterly_tables)) cdm_quarterly(base_table)
  else cdm(base_table)
}

# ---- Code-list loading ----
# Single-source loader: server-side reference tables only.
# Returns the fully-qualified table name for use in SQL FROM clauses.
get_code_source <- function(external_ref) {
  ref(external_ref)
}
