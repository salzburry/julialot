# Extra criteria on lines of therapy.
#
# LOT itself is defined by the rules in R/steps. This is the layer on top: a
# study can require something more of a line - any line, not just L1 - without
# touching those rules.
#
# Two tables come out, the same shape the cohort build uses:
#   <prefix>LOT_LONG_ALLFLAGS  every criterion as a 0/1 column, always computed
#   <prefix>LOT_LONG_FINAL     the enabled ones applied
# So you can see what a criterion would do before you turn it on.
#
# A criterion looks like this:
#
#   list(
#     name    = "l2_started_on_med",
#     label   = "L2 started on a drug, not a transplant",
#     lines   = 2L,                       # 1L, c(2L, 3L), or "*" for every line
#     flag    = "L2_START_IS_MED",
#     sql     = "LOT_START_TYPE = 'MED'", # any expression over lot_long
#     on_fail = "flag"
#   )
#
# lines  - which LOT_NUM this is asked of. A line the criterion is not asked of
#          passes: it is not applicable, not a failure.
# sql    - evaluated per row of lot_long. {cfg$...} is interpolated, so a
#          threshold can live in config.csv.
# on_fail- what a failing line does. "flag" changes nothing, so a new criterion
#          is safe until someone deliberately picks otherwise:
#            flag         column only
#            drop_line    that line goes
#            truncate     that line and every later line for the patient go,
#                         because LOT N is defined against LOT N-1
#            drop_patient the patient goes entirely
#
# Enabled by APPLY_<NAME> in config.csv. Off is the default.

# No criteria yet - the study team has not asked for any. Add them here; the
# builders and tests below already handle them.
LINE_CRITERIA <- list()

ON_FAIL <- c("flag", "drop_line", "truncate", "drop_patient")

# A malformed criterion silently building the wrong SQL is the failure mode
# worth spending code on, so every field is checked before anything runs.
validate_line_criteria <- function(crit = LINE_CRITERIA) {
  bad <- character(0)
  seen <- character(0)
  for (i in seq_along(crit)) {
    c_i <- crit[[i]]
    at <- paste0("criterion ", i)
    need <- c("name", "label", "lines", "flag", "sql", "on_fail")
    miss <- need[!need %in% names(c_i)]
    if (length(miss)) {
      bad <- c(bad, paste0(at, ": missing ", paste(miss, collapse = ", ")))
      next
    }
    at <- paste0("'", c_i$name, "'")
    if (!is.character(c_i$name) || !nzchar(c_i$name))
      bad <- c(bad, paste0(at, ": name must be a non-empty string"))
    if (c_i$name %in% seen) bad <- c(bad, paste0(at, ": duplicate name"))
    seen <- c(seen, c_i$name)
    if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", c_i$flag))
      bad <- c(bad, paste0(at, ": flag '", c_i$flag, "' is not a column name"))
    if (!identical(c_i$lines, "*") &&
        !(is.numeric(c_i$lines) && length(c_i$lines) && all(c_i$lines >= 1)))
      bad <- c(bad, paste0(at, ": lines must be \"*\" or LOT_NUM values >= 1"))
    if (!is.character(c_i$sql) || !nzchar(trimws(c_i$sql)))
      bad <- c(bad, paste0(at, ": sql is empty"))
    if (!identical(c_i$on_fail, "flag") && !c_i$on_fail %in% ON_FAIL)
      bad <- c(bad, paste0(at, ": on_fail '", c_i$on_fail, "' is not one of ",
                           paste(ON_FAIL, collapse = ", ")))
  }
  dup_flags <- unique(vapply(crit, `[[`, character(1), "flag"))
  if (length(dup_flags) != length(crit))
    bad <- c(bad, "two criteria write the same flag column")
  if (length(bad))
    stop("Line criteria are not usable:\n  ", paste(bad, collapse = "\n  "),
         call. = FALSE)
  invisible(TRUE)
}

# APPLY_<NAME> in config.csv, off unless it says TRUE.
criterion_enabled <- function(c_i) {
  identical(toupper(Sys.getenv(paste0("APPLY_", toupper(c_i$name)), unset = "FALSE")),
            "TRUE")
}

enabled_line_criteria <- function(crit = LINE_CRITERIA) {
  Filter(criterion_enabled, crit)
}

# Which lines a criterion is asked of.
.applies_sql <- function(c_i) {
  if (identical(c_i$lines, "*")) return("1=1")
  paste0("LOT_NUM IN (", paste(as.integer(c_i$lines), collapse = ", "), ")")
}

# A line the criterion is not asked of passes. A predicate that comes out NULL
# fails: unknown is not evidence the line qualifies.
line_flag_sql <- function(c_i, cfg) {
  pred <- glue(c_i$sql, .envir = list2env(list(cfg = cfg), parent = globalenv()))
  glue("CASE WHEN NOT ({.applies_sql(c_i)}) THEN 1
                   WHEN ({pred}) THEN 1 ELSE 0 END AS {c_i$flag}")
}

# Every criterion, enabled or not, as its own column.
line_criteria_flags_sql <- function(cfg, src, out, crit = LINE_CRITERIA) {
  validate_line_criteria(crit)
  if (!length(crit))
    return(glue("CREATE OR REPLACE TEMPORARY VIEW {out} AS SELECT * FROM {src}"))
  cols <- paste(vapply(crit, line_flag_sql, character(1), cfg = cfg),
                collapse = ",\n  ")
  glue("CREATE OR REPLACE TEMPORARY VIEW {out} AS\nSELECT *,\n  {cols}\nFROM {src}")
}

# Only the enabled ones filter. Nothing enabled means a straight copy, so the
# table exists either way and downstream never branches on it.
line_criteria_final_sql <- function(cfg, src, out, crit = LINE_CRITERIA) {
  validate_line_criteria(crit)
  on <- enabled_line_criteria(crit)
  fails <- function(mode) {
    f <- Filter(function(c_i) identical(c_i$on_fail, mode), on)
    if (!length(f)) return("0")
    paste0("CASE WHEN ", paste(vapply(f, function(c_i) paste0(c_i$flag, " = 0"),
                                      character(1)), collapse = " OR "),
           " THEN 1 ELSE 0 END")
  }
  if (!length(on))
    return(glue("CREATE OR REPLACE TEMPORARY VIEW {out} AS SELECT * FROM {src}"))
  drop_line <- fails("drop_line"); trunc <- fails("truncate")
  drop_pat  <- fails("drop_patient")
  glue("
CREATE OR REPLACE TEMPORARY VIEW {out} AS
WITH marked AS (
  SELECT *,
    {drop_line} AS line_fail_drop,
    {trunc} AS line_fail_trunc,
    {drop_pat} AS line_fail_patient
  FROM {src}
),
scoped AS (
  SELECT *,
    -- the patient's first truncating failure; every line from there goes
    min(CASE WHEN line_fail_trunc = 1 THEN LOT_NUM END) OVER (PARTITION BY PATID)
      AS first_trunc_lot,
    max(line_fail_patient) OVER (PARTITION BY PATID) AS patient_fails
  FROM marked
)
SELECT * FROM scoped
WHERE patient_fails = 0
  AND line_fail_drop = 0
  AND (first_trunc_lot IS NULL OR LOT_NUM < first_trunc_lot)")
}
