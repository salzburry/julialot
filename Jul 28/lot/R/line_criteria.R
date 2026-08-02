# Extra criteria on lines of therapy. See README.md for how to add one.
#
#   <prefix>LOT_LONG_ALLFLAGS  every criterion as a 0/1 column, always computed
#   <prefix>LOT_LONG_FINAL     the enabled ones applied

# Protocol S6.2.1.2, the fourth NDMM exclusion: "Received belantamab mafodotin
# (i.e., an ADC) in any LOT". It lives here rather than in the cohort build
# because lines do not exist until this package has run - a cohort-time rule
# could only ever be a claims proxy, and one whose over-exclusions were
# unverifiable, because a patient it removed never got lines to check. Applied
# here it is the criterion as written.
#
# Patient-level, not line-level. The predicate is false on EVERY line of an
# affected patient, so first_failed_lot lands on their earliest line and the
# truncate below leaves them with none - which is the exclusion.
#
# LOT_BASE_MEDS is concat_ws(' ', sort_array(collect_set(MED_ABBR))), so the
# test is a whole-token match, not a LIKE: an abbreviation that merely contains
# BELA would not match, and BELA as one of several meds does.
# LOT_BASE_1ST_ADD_MED is checked too - a med added mid-line was still received
# in it.
LINE_CRITERIA <- list(
  list(
    name    = "no_belantamab",
    label   = "No belantamab (ADC) in any LOT (protocol S6.2.1.2)",
    lines   = "*",
    flag    = "NO_BELANTAMAB_ANY_LOT",
    on_fail = "truncate",
    sql     = paste0(
      "max(CASE WHEN array_contains(split(coalesce(LOT_BASE_MEDS, \'\'), \' \'), ",
      "\'{cfg$belantamab_med_abbr}\')",
      " OR upper(trim(coalesce(LOT_BASE_1ST_ADD_MED, \'\'))) = ",
      "\'{cfg$belantamab_med_abbr}\' THEN 1 ELSE 0 END)",
      " OVER (PARTITION BY PATID) = 0")
  )
)

# flag changes nothing. truncate drops the failing line and every later one,
# because LOT N is defined against LOT N-1 - removing a middle line would
# leave L1 next to L3. Nothing else is offered until a real criterion needs it.
ON_FAIL <- c("flag", "truncate")
FIELDS  <- c("name", "label", "lines", "flag", "sql", "on_fail")

.is_str <- function(x) is.character(x) && length(x) == 1L && !is.na(x) && nzchar(trimws(x))

# on_fail may be left out; it means flag.
normalize_criterion <- function(c_i) {
  if (is.null(c_i$on_fail)) c_i$on_fail <- "flag"
  c_i
}

# A malformed criterion that quietly builds the wrong SQL is the failure worth
# spending code on, so check every field before anything runs.
validate_line_criteria <- function(crit = LINE_CRITERIA, max_lot = NULL) {
  bad <- character(0)
  names_seen <- character(0); flags_seen <- character(0)
  for (i in seq_along(crit)) {
    c_i <- crit[[i]]
    at <- paste0("criterion ", i)
    if (!is.list(c_i)) { bad <- c(bad, paste0(at, ": not a list")); next }
    c_i <- normalize_criterion(c_i)
    miss <- setdiff(FIELDS, names(c_i))
    if (length(miss)) {
      bad <- c(bad, paste0(at, ": missing ", paste(miss, collapse = ", ")))
      next
    }
    if (.is_str(c_i$name)) at <- paste0("'", c_i$name, "'")

    if (!.is_str(c_i$name))  bad <- c(bad, paste0(at, ": name must be one non-empty string"))
    if (!.is_str(c_i$label)) bad <- c(bad, paste0(at, ": label must be one non-empty string"))
    if (!.is_str(c_i$sql))   bad <- c(bad, paste0(at, ": sql must be one non-empty string"))
    if (!.is_str(c_i$flag) || !grepl("^[A-Za-z_][A-Za-z0-9_]*$", c_i$flag))
      bad <- c(bad, paste0(at, ": flag is not a column name"))
    if (!.is_str(c_i$on_fail) || !c_i$on_fail %in% ON_FAIL)
      bad <- c(bad, paste0(at, ": on_fail must be one of ",
                           paste(ON_FAIL, collapse = ", ")))

    # Whole numbers only. 1.5 would otherwise truncate to 1 and silently move
    # the criterion to LOT1; NA and Inf would reach as.integer() and vanish.
    ln <- c_i$lines
    if (!identical(ln, "*")) {
      okl <- is.numeric(ln) && length(ln) >= 1L && all(is.finite(ln)) &&
             all(ln >= 1) && all(ln == as.integer(ln))
      if (!isTRUE(okl))
        bad <- c(bad, paste0(at, ": lines must be \"*\" or whole LOT_NUM values >= 1"))
      # A line above MAX_LOT matches nothing, so the criterion is asked of no
      # row and every row passes it. That reads as "the criterion is satisfied"
      # rather than "the criterion never ran".
      if (isTRUE(okl) && !is.null(max_lot) && any(ln > max_lot))
        bad <- c(bad, paste0(at, ": lines ", paste(ln[ln > max_lot], collapse = ", "),
                             " are above MAX_LOT (", max_lot,
                             "), so the criterion would match no line at all"))
    }

    # The switch is APPLY_<NAME> and Spark folds identifier case, so names and
    # flags that differ only in case are the same thing.
    if (.is_str(c_i$name)) {
      if (toupper(c_i$name) %in% names_seen)
        bad <- c(bad, paste0(at, ": duplicate name (case does not distinguish)"))
      names_seen <- c(names_seen, toupper(c_i$name))
    }
    if (.is_str(c_i$flag)) {
      if (toupper(c_i$flag) %in% flags_seen)
        bad <- c(bad, paste0(at, ": duplicate flag (case does not distinguish)"))
      flags_seen <- c(flags_seen, toupper(c_i$flag))
    }
  }
  if (length(bad))
    stop("Line criteria are not usable:\n  ", paste(bad, collapse = "\n  "),
         call. = FALSE)
  invisible(TRUE)
}

# APPLY_<NAME> in config.csv. Anything that is not TRUE or FALSE stops the
# build: a typo that quietly drops an intended criterion is worse than a halt.
criterion_enabled <- function(c_i) {
  v <- Sys.getenv(paste0("APPLY_", toupper(c_i$name)), unset = "FALSE")
  if (!toupper(trimws(v)) %in% c("TRUE", "FALSE"))
    stop("APPLY_", toupper(c_i$name), "='", v, "' (want TRUE or FALSE)",
         call. = FALSE)
  identical(toupper(trimws(v)), "TRUE")
}

enabled_line_criteria <- function(crit = LINE_CRITERIA) {
  Filter(criterion_enabled, lapply(crit, normalize_criterion))
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
  validate_line_criteria(crit, cfg$max_lot)
  crit <- lapply(crit, normalize_criterion)
  if (!length(crit))
    return(glue("CREATE OR REPLACE TEMPORARY VIEW {out} AS SELECT * FROM {src}"))
  cols <- paste(vapply(crit, line_flag_sql, character(1), cfg = cfg),
                collapse = ",\n  ")
  glue("CREATE OR REPLACE TEMPORARY VIEW {out} AS\nSELECT *,\n  {cols}\nFROM {src}")
}

# Only criteria that actually remove rows build anything. A flag-only criterion
# is a true no-op: same rows, same columns, no window scan.
line_criteria_final_sql <- function(cfg, src, out, crit = LINE_CRITERIA) {
  validate_line_criteria(crit, cfg$max_lot)
  on <- Filter(function(c_i) identical(c_i$on_fail, "truncate"),
               enabled_line_criteria(crit))
  if (!length(on))
    return(glue("CREATE OR REPLACE TEMPORARY VIEW {out} AS SELECT * FROM {src}"))
  failed <- paste(vapply(on, function(c_i) paste0(c_i$flag, " = 0"),
                         character(1)), collapse = " OR ")
  # EXCEPT keeps first_failed_lot out of the result: it is working state, not
  # something downstream should see.
  glue("
CREATE OR REPLACE TEMPORARY VIEW {out} AS
WITH scoped AS (
  SELECT *,
    -- the patient's first failing line; that line and every later one go
    min(CASE WHEN {failed} THEN LOT_NUM END) OVER (PARTITION BY PATID)
      AS first_failed_lot
  FROM {src}
)
SELECT * EXCEPT (first_failed_lot) FROM scoped
WHERE first_failed_lot IS NULL OR LOT_NUM < first_failed_lot")
}
