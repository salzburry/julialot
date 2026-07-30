# Quarterly table-name helpers for the Optum CDM (t_<table>_YYYYqQ).
# cdm_src()/cdm_quarterly() live in make_naming_helpers() (db_utils.R)
# because they close over cfg.

get_quarter_suffix <- function(date_str) {
  d <- as.Date(date_str)
  paste0(format(d, "%Y"), "q", ceiling(as.integer(format(d, "%m")) / 3))
}

get_quarterly_table <- function(base_table, date_str) {
  paste0("t_", base_table, "_", get_quarter_suffix(date_str))
}
