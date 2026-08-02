# Extra criteria on lines of therapy. See README.md for how to add one.
#
#   <prefix>LOT_LONG_ALLFLAGS  every criterion as a 0/1 column, always computed
#   <prefix>LOT_LONG_FINAL     the enabled ones applied

# A criterion may need patient-level facts lot_long does not carry. It declares
# `patients`, SQL creating one row per PATID, which is LEFT JOINed into the
# allflags view so the criterion's own sql can read its columns. The two names
# are built from the criterion's, so nothing has to be kept in step by hand.
criterion_patients_view <- function(c_i) paste0("lc_", c_i$name, "_patients")
criterion_alias         <- function(c_i) paste0("p_", c_i$name)

# Belantamab (an ADC) received in any LOT. It lives here rather than in the
# cohort build because lines do not exist until this package has run - a
# cohort-time rule could only be a claims proxy, and one nobody could check,
# because a patient it removed never got lines.
#
# Asked of the CLAIMS, not of the built lines, and that is what makes it exact.
# Reading LOT_BASE_MEDS and LOT_BASE_1ST_ADD_MED would bound the question by
# what the build produced, and the build produces max_lot lines: belantamab in
# a sixth line, or as a line's second added med, would be invisible. "Any LOT"
# would then mean "any of the first five, and only as a base med or the first
# addition".
#
# map_stacked is one row per (patient, drug, treatment episode), already bounded
# to the patient's observation by 03_mma_map.R. A belantamab MAP overlapping the
# patient's LOT-covered span therefore IS belantamab received in a line: inside
# a built line it is that line's, and after the last built line it is a line the
# build would have started, because a non-steroid drug that is not a permissible
# substitute of a prior line's drug triggers the next LOT. Either way the answer
# does not depend on max_lot, so nothing here is capped at five.
#
# Patient-level, not line-level. The predicate is false on EVERY line of an
# affected patient, so first_failed_lot lands on their earliest line and the
# truncate below leaves them with none - which is the exclusion.
#
# The MED_ABBR test is a whole-value match, not a LIKE: an abbreviation that
# merely contains BELA cannot match.
LINE_CRITERIA <- list(
  list(
    name    = "no_belantamab",
    label   = "No belantamab (ADC) in any LOT",
    lines   = "*",
    flag    = "NO_BELANTAMAB_ANY_LOT",
    on_fail = "truncate",
    # FIRST_LOT_DT rather than the cohort's INDEX_DATE: for this cohort they are
    # the same date, but a cohort whose index precedes its first line would
    # otherwise count pre-LOT therapy as received in a LOT.
    patients = paste0(
      "CREATE OR REPLACE TEMPORARY VIEW lc_no_belantamab_patients AS\n",
      "WITH lot_span AS (\n",
      "  SELECT PATID, min(LOT_START_DT) AS FIRST_LOT_DT FROM lot_long GROUP BY PATID\n",
      ")\n",
      "SELECT s.PATID,\n",
      "       max(CASE WHEN upper(trim(coalesce(m.MAP_MED_TYPE, \'\'))) = ",
      "\'{cfg$belantamab_med_abbr}\'\n",
      "                THEN 1 ELSE 0 END) AS HAS_BELANTAMAB\n",
      "FROM lot_span s\n",
      "INNER JOIN lot_patient_input p ON p.PATID = s.PATID\n",
      "LEFT JOIN map_stacked m\n",
      "       ON m.PATID = s.PATID\n",
      "      AND m.MAP_END_DT   >= s.FIRST_LOT_DT\n",
      "      AND m.MAP_START_DT <= p.OBS_END_DT\n",
      "GROUP BY s.PATID"),
    sql = "coalesce(p_no_belantamab.HAS_BELANTAMAB, 0) = 0"
  )
)

# flag changes nothing. truncate drops the failing line and every later one,
# because LOT N is defined against LOT N-1 - removing a middle line would
# leave L1 next to L3. Nothing else is offered until a real criterion needs it.
ON_FAIL <- c("flag", "truncate")
FIELDS  <- c("name", "label", "lines", "flag", "sql", "on_fail")
# patients is optional, so it is not in FIELDS. Validated when present.

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

    # A patient-level view is wired in by name, and both names are derived from
    # the criterion's. Written out in the criterion so the SQL reads as SQL, and
    # checked here so a renamed criterion cannot leave the statement building a
    # view nothing joins or the predicate reading an alias nothing defines -
    # either of which is a criterion that matches nobody and looks satisfied.
    if (!is.null(c_i$patients)) {
      if (!.is_str(c_i$patients))
        bad <- c(bad, paste0(at, ": patients must be one non-empty string"))
      else if (!grepl(criterion_patients_view(c_i), c_i$patients, fixed = TRUE))
        bad <- c(bad, paste0(at, ": patients must create the view ",
                             criterion_patients_view(c_i)))
      if (.is_str(c_i$sql) && !grepl(paste0(criterion_alias(c_i), "."),
                                     c_i$sql, fixed = TRUE))
        bad <- c(bad, paste0(at, ": sql declares patients but never reads ",
                             criterion_alias(c_i)))
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

# The patient-level views a criterion declares, ready to run before the flags
# view joins them.
line_criteria_patient_sql <- function(cfg, crit = LINE_CRITERIA) {
  crit <- Filter(function(c_i) !is.null(c_i$patients), lapply(crit, normalize_criterion))
  lapply(crit, function(c_i) list(
    name = criterion_patients_view(c_i),
    sql  = glue(c_i$patients, .envir = list2env(list(cfg = cfg), parent = globalenv()))))
}

# Every criterion, enabled or not, as its own column.
line_criteria_flags_sql <- function(cfg, src, out, crit = LINE_CRITERIA) {
  validate_line_criteria(crit, cfg$max_lot)
  crit <- lapply(crit, normalize_criterion)
  if (!length(crit))
    return(glue("CREATE OR REPLACE TEMPORARY VIEW {out} AS SELECT * FROM {src}"))
  cols <- paste(vapply(crit, line_flag_sql, character(1), cfg = cfg),
                collapse = ",\n  ")
  join <- Filter(function(c_i) !is.null(c_i$patients), crit)
  if (!length(join))
    return(glue("CREATE OR REPLACE TEMPORARY VIEW {out} AS\nSELECT *,\n  {cols}\nFROM {src}"))
  # s.*, not *: the joined views would otherwise add their columns to the
  # output, and PATID would appear twice.
  joins <- paste(vapply(join, function(c_i)
    glue("LEFT JOIN {criterion_patients_view(c_i)} {criterion_alias(c_i)}",
         " ON s.PATID = {criterion_alias(c_i)}.PATID"), character(1)),
    collapse = "\n")
  glue("CREATE OR REPLACE TEMPORARY VIEW {out} AS\nSELECT s.*,\n  {cols}\nFROM {src} s\n{joins}")
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
