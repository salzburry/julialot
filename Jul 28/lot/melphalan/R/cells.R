# The two builds this package compares, and what is read off them.
#
# The rule itself is not here - it is lot/engine/R/melp_rule.R, because the
# engine builds the lines. This file is the measurement: which builds, what to
# read off them, and how to read one against the other.
#
# TWO cells. The study adopted the short-course rule, so the contract build
# carries it and the cell WITHOUT it is the one that deviates. What the pair
# measures is what the rule did to the study's numbers - which is the evidence
# the adoption rests on, kept runnable.
#
# `mode` is the deviation a cell must record, NA marking the contract build.
# `melp` is what the cell hands to APPLY_MELP_RULE - a separate thing, because
# the contract build names its value too rather than inheriting the shell.
#
# Until 2026-08-30 there was a third cell and a five-branch rule to compare
# against. That comparison is finished and the rule was not adopted; both are
# gone, and STUDY_TEAM_ASKS.md keeps the finding.
MELP_CELLS <- list(
  list(id = "reference", mode = "off", melp = "off",
       what = "no melphalan rule - what the build did before the study adopted one"),
  list(id = "simplified", mode = NA_character_, melp = "simplified",
       what = paste0("the study's rule: a short melphalan course outside ",
                     "induction does not advance a line on its own; a new ",
                     "agent starting inside the course advances it on the ",
                     "melphalan date")))

# The cell's own status row: which run owns the prefix, whether it finished,
# and when it last moved.
#
# Read once per cell and carried, rather than asked again each time a run id is
# needed. LOT_LONG_FINAL and MAP_STACKED are CREATE OR REPLACE tables under a
# bare prefix with no run column, so a rebuild landing between two questions
# gives run A's provenance, run B's attrition and whatever the final tables hold
# now - published as one consistent set. The snapshot is what makes that
# detectable, and melp_status_unchanged() is where it gets detected.
#
# STATE has to be complete. A prefix whose last status row is 'started' is being
# rebuilt right now and its tables are mid-flight; 'failed' means they are
# whatever the build got to before it died. Neither is a cell.
cell_status <- function(con, c_i) {
  # paste0, not glue. Everything else in this file builds SQL that way, and a
  # lone glue() call makes the package an attach dependency of every script that
  # sources it - a reader that does not attach it died here.
  tbl <- wrk(paste0(c_i$prefix, "LOT_BUILD_STATUS"))
  st <- tryCatch(db_q(con, paste0(
    "SELECT RUN_ID, STATE, cast(UPDATED_AT as string) AS UPDATED_AT FROM ", tbl,
    " ORDER BY UPDATED_AT DESC LIMIT 1")), error = function(e) e)
  # Not swallowed to NULL. A table that cannot be read and a prefix nothing has
  # ever built are different problems, and the second is the one an operator
  # would act on.
  if (inherits(st, "error"))
    stop("Could not read ", tbl, ", so there is no way to tell which run ",
         c_i$id, "'s tables belong to: ", conditionMessage(st), call. = FALSE)
  if (!nrow(st))
    stop("No LOT_BUILD_STATUS row under ", c_i$prefix, ", so there is no run ",
         "to read ", c_i$id, "'s numbers from.", call. = FALSE)
  state <- tolower(trimws(as.character(st$STATE[1])))
  if (!identical(state, "complete"))
    stop("The last run under ", c_i$prefix, " is '", state, "', not complete. ",
         c_i$id, "'s tables are either mid-rebuild or as far as a failed build ",
         "got, so the numbers read off them are not that cell's.", call. = FALSE)
  list(id = c_i$id, run_id = as.character(st$RUN_ID[1]), state = state,
       updated_at = as.character(st$UPDATED_AT[1]))
}

# The same rows again, immediately before anything is published. Everything read
# so far comes off tables a concurrent build can replace, so this is the only
# check standing between "these cells agreed at the start of the read" and
# "they still describe the same builds".
#
# Not a lock - a rebuild finishing inside the read still goes undetected if it
# also finishes before this runs. It closes the window rather than the door,
# which is why a cell rebuild beside a read is still not something to do.
melp_status_unchanged <- function(con, cells, before) {
  moved <- character(0)
  for (c_i in cells) {
    was <- before[[c_i$id]]
    now <- cell_status(con, c_i)
    if (!identical(was$run_id, now$run_id) ||
        !identical(was$updated_at, now$updated_at))
      moved <- c(moved, paste0("  ", c_i$id, ": was run ", was$run_id, " at ",
                               was$updated_at, ", now run ", now$run_id, " at ",
                               now$updated_at))
  }
  if (length(moved))
    stop("A cell was rebuilt while it was being read, so the numbers are a ",
         "mix of two builds:\n", paste(moved, collapse = "\n"),
         "\nNothing was written. Re-run the read once the rebuild has finished.",
         call. = FALSE)
  invisible(TRUE)
}

# Where both scripts publish.
#
# One resolver for both scripts. With two - the runner writing beside its build
# logs and the recovery read writing to the artifacts directory - a recovery can
# succeed while the CSVs it means to replace sit next to the logs, still looking
# current.
melp_out_dir <- function(script_dir) {
  d <- trimws(Sys.getenv("OUTPUT_DIR", unset = ""))
  if (nzchar(d)) d else file.path(script_dir, "out")
}

melp_cell_plan <- function(cells = MELP_CELLS, prefix_base = "melp_") {
  lapply(cells, function(c_i)
    c(c_i, list(prefix = paste0(prefix_base, c_i$id, "_"))))
}

# Refuse a plan that would write over the study's own tables. A cell is a whole
# LOT build with CREATE OR REPLACE in it, so this is the one mistake that
# cannot be undone.
check_melp_plan <- function(cells, study_prefix) {
  bad <- character(0)
  pfx <- vapply(cells, function(c_i) c_i$prefix, character(1))
  if (anyDuplicated(pfx))
    bad <- c(bad, "two cells share a prefix, so one would overwrite the other")
  if (nzchar(study_prefix) && study_prefix %in% pfx)
    bad <- c(bad, paste0("a cell writes to '", study_prefix,
                         "', which is the study's own prefix"))
  if (!all(grepl("^[A-Za-z][A-Za-z0-9_]*_$", pfx)))
    bad <- c(bad, "a cell prefix is not a valid object prefix")
  if (length(bad)) stop(paste(bad, collapse = "; "), call. = FALSE)
  invisible(TRUE)
}

# Clear a cell's prefix before it is rebuilt.
#
# A rebuild is CREATE OR REPLACE table by table, which is not the same as a
# clean prefix. A table the previous build wrote and this one does not is left
# where it was, carrying the older engine's answer under the new run's prefix,
# and every guard in this file would pass: LOT_BUILD_STATUS, LOT_RUN_METADATA
# and the code fingerprint all come off tables the new build DID write. The
# stale one is only found by whichever reader happens to name it.
#
# So the prefix is emptied first and the cell rebuilt into nothing. Anything
# left behind afterwards is this build's.
#
# Scoped by check_melp_plan, which has already refused a prefix that is not a
# plain object prefix or that collides with the study's - so the LIKE below
# cannot reach a study table. It runs against the cells' own throwaway
# prefixes and nothing else.
melp_drop_cell <- function(con, c_i, study_prefix = "") {
  check_melp_plan(list(c_i), study_prefix)
  cfg <- lot_config()
  where <- paste0(cfg$catalog, ".", cfg$work_schema)
  got <- db_q(con, paste0("SHOW TABLES IN ", where,
                          " LIKE '", c_i$prefix, "*'"))
  # The column is tableName on Databricks and table_name elsewhere; take
  # whichever is there rather than a positional index, which would silently
  # pick the database column if the order ever moved.
  nm <- intersect(c("tableName", "table_name", "TABLE_NAME"), names(got))
  if (!length(nm))
    stop("SHOW TABLES returned no table-name column (",
         paste(names(got), collapse = ", "), "), so ", c_i$id,
         "'s prefix cannot be shown to be empty before it is rebuilt.",
         call. = FALSE)
  tbls <- sort(as.character(got[[nm[1]]]))
  # Belt and braces. SHOW TABLES ... LIKE is the warehouse's own matcher and
  # this does not trust it to have been anchored at the start of the name.
  tbls <- tbls[startsWith(tbls, c_i$prefix)]
  for (t in tbls) db_exec(con, paste0("DROP TABLE IF EXISTS ", where, ".", t))
  cat("  cleared ", c_i$id, ": dropped ", length(tbls), " table(s) under ",
      c_i$prefix, "\n", sep = "")
  invisible(tbls)
}

# What every cell has to agree on before any difference between them can be
# called the rule's.
#
# The runner already requires one cohort table and one cohort prefix. That is
# not enough: a table name is not a cohort attempt. Re-running the cohort build
# under the same prefix replaces NDMM_COHORT in place, so a reference built over
# attempt A and two cells built over attempt B all complete, all look right, and
# the A-to-B difference is reported as the effect of melphalan. The same goes
# for a production code list edited between cells, for the LOT code itself, and
# for the study window.
#
# LOT records all of it: the cohort attempt it read in LOT_RUN_METADATA, the
# code fingerprint and study window beside it, and every code list's md5 in
# LOT_CODELIST_METADATA. So the check is to read it back rather than to trust
# that two sequential builds saw the same world.
#
# CONTRACT_SETTINGS is not here, and is checked all the same - by
# melp_settings(), which compares it key by key. It cannot be compared as one
# value: apply_melp_rule is inside it, and that is the one thing the cells are
# built to differ on.
MELP_INPUT_FIELDS <- c(
  COHORT_RUN_ID = "the cohort build's run",
  COHORT_STAMP  = "...and its attempt, since a re-run keeps the run id",
  STUDY_START   = "the study window's start",
  STUDY_END     = "...and its end",
  CODE_MD5      = "the LOT code that built it",
  CODELIST_MD5  = "every production code list it read")

# Three tables, because the run does not record all of this in one place.
# CONTRACT_DEVIATIONS is a column of LOT_BUILD_STATUS and not of
# LOT_RUN_METADATA - deliberately, since the status row is the one every
# downstream reader uses to decide which run owns a prefix. Selecting it from
# the metadata table is an unresolved column, and the whole query fails.
melp_inputs_sql <- function(meta_tbl, codelist_tbl, status_tbl, run_id) {
  paste0("
    SELECT m.COHORT_RUN_ID, m.COHORT_STAMP, m.STUDY_START, m.STUDY_END,
           m.CODE_MD5, m.CONTRACT_SETTINGS,
           (SELECT concat_ws('|', sort_array(collect_list(
                     concat(c.CODELIST_FILE, ':', c.MD5))))
            FROM ", codelist_tbl, " c WHERE c.RUN_ID = '", run_id, "')
                                                            AS CODELIST_MD5,
           (SELECT max(s.CONTRACT_DEVIATIONS)
            FROM ", status_tbl, " s WHERE s.RUN_ID = '", run_id, "')
                                                            AS CONTRACT_DEVIATIONS
    FROM ", meta_tbl, " m WHERE m.RUN_ID = '", run_id, "'")
}

# Every field the same across every cell, or the comparison is not about the
# rule. Reported as a list rather than a first failure, because an operator
# fixing one and re-running only to hit the next is how a sweep gets abandoned.
melp_check_inputs <- function(rows) {
  bad <- character(0)
  for (f in names(MELP_INPUT_FIELDS)) {
    v <- vapply(rows, function(r) {
      x <- r[[f]]
      if (is.null(x) || length(x) == 0 || is.na(x[1])) "<none>" else as.character(x[1])
    }, character(1))
    if (length(unique(v)) > 1L)
      bad <- c(bad, paste0("  ", f, " (", MELP_INPUT_FIELDS[[f]], "):\n",
                           paste0("    ", names(rows), " = ", v, collapse = "\n")))
    else if (identical(unique(v), "<none>"))
      bad <- c(bad, paste0("  ", f, " (", MELP_INPUT_FIELDS[[f]],
                           "): not recorded by any cell, so it cannot be compared"))
  }
  if (length(bad))
    stop("These cells were not built over the same inputs, so the ",
         "differences between them are not the rule's:\n",
         paste(bad, collapse = "\n"),
         "\nRebuild them together without touching the cohort or the code lists.",
         call. = FALSE)
  invisible(TRUE)
}

# And each cell has to be the algorithm it says it is.
#
# Which cell deviates FLIPPED when the study adopted the rule. The cell that
# carries it is the contract build now, and must record no deviation at all: if
# it needed one it is not the contract build, and every delta is measured
# against the wrong thing. The cell built WITHOUT the rule is the deviating one,
# and must record the melphalan deviation naming what it was asked for - and
# nothing else, because the cells are separate processes and a second setting
# reaching one of them would be read as the rule's effect.
#
# The code says this generically, off each cell's own `mode`: NA is the contract
# build, a word is a deviation to expect. So the flip needed no change here.
#
# check_lot_contract() writes one entry per wrong setting as
# "key=value (contract value)", pipe-separated by write_build_status(). So the
# entries are what is counted, and the mode is matched inside its own entry
# rather than anywhere in the string.
#
# `key` is the setting the cells exist to differ on. The melphalan package
# leaves the default; the fold-in package passes apply_map_foldin, with the
# cell's mode field carrying the value it must record. A cell may deviate on
# that setting and nothing else, and the contract cell may not deviate at all:
# if it needed to, it would not be the contract build.
melp_check_deviations <- function(rows, cells, key = "apply_melp_rule") {
  mode_of <- setNames(lapply(cells, function(c_i) c_i$mode),
                      vapply(cells, function(c_i) c_i$id, character(1)))
  bad <- character(0)
  for (id in names(rows)) {
    dev <- rows[[id]]$CONTRACT_DEVIATIONS
    dev <- if (is.null(dev) || length(dev) == 0 || is.na(dev[1])) "" else trimws(dev[1])
    entries <- trimws(unlist(strsplit(dev, "|", fixed = TRUE)))
    entries <- entries[nzchar(entries)]
    want <- mode_of[[id]]
    if (is.na(want)) {
      if (length(entries))
        bad <- c(bad, paste0("  ", id, " is meant to be the contract build but ",
                             "deviates on: ", paste(entries, collapse = "; ")))
      next
    }
    melp  <- grep(paste0("^", key, "="), entries)
    other <- entries[-melp]
    if (!length(melp))
      bad <- c(bad, paste0("  ", id, " is meant to build the rule but records no ",
                           key, " deviation (",
                           if (length(entries)) paste(entries, collapse = "; ") else "none", ")"))
    else if (!any(grepl(paste0("^", key, "=", want, "\\b"), entries[melp])))
      bad <- c(bad, paste0("  ", id, " is meant to build ", want,
                           " but records: ", paste(entries[melp], collapse = "; ")))
    if (length(other))
      bad <- c(bad, paste0("  ", id, " changed something other than the rule: ",
                           paste(other, collapse = "; ")))
  }
  if (length(bad))
    stop("A cell is not the algorithm it claims:\n", paste(bad, collapse = "\n"),
         call. = FALSE)
  invisible(TRUE)
}

# The windows the numbers are read under, taken from the cells themselves.
#
# melp_metric_sql() rebuilds the exposure chain to count B.2, so it needs the
# same windows the build used. Reading them from the ambient config is right
# only while the two agree. They stop agreeing the moment the read happens
# separately from the build: a recovery run a week later with
# MELP_EXPOSURE_DAYS=31 in the environment recounts B.2 under a rule no cell was
# built with, and every provenance check still passes, because both cells
# do agree with each other.
#
# So the values come off CONTRACT_SETTINGS, which is the run's own record of
# what it used.
MELP_SETTING_KEYS <- c(abbr         = "melp_med_abbr",
                       expo_days    = "melp_exposure_days",
                       ind1         = "induction_window_days",
                       indn         = "lot_n_induction_window_days",
                       cart         = "cart_consolidation_days")

# "a=1|b=2" to a named list. Split on the first "=" only, so a value with one
# in it survives.
melp_parse_settings <- function(s) {
  s  <- if (is.null(s) || length(s) == 0 || is.na(s[1])) "" else as.character(s[1])
  kv <- trimws(unlist(strsplit(s, "|", fixed = TRUE)))
  kv <- kv[grepl("=", kv, fixed = TRUE)]
  setNames(as.list(sub("^[^=]*=", "", kv)), sub("=.*$", "", kv))
}

# `vary` names the settings the cells are allowed to differ on: the mode
# always, plus - in the simplified package - the course cap it is testing.
melp_settings <- function(rows, vary = "apply_melp_rule") {
  s <- lapply(rows, function(r) melp_parse_settings(r$CONTRACT_SETTINGS))
  empty <- names(s)[vapply(s, function(x) !length(x), logical(1))]
  if (length(empty))
    stop("These cells recorded no CONTRACT_SETTINGS: ", paste(empty, collapse = ", "),
         ". Without them there is no record of the windows the lines were built ",
         "under, so the numbers read off them cannot be shown to be the build's.",
         call. = FALSE)

  # apply_melp_rule aside - that is what the cells are - every setting has to
  # match, including ones no metric reads. A cell built with a different
  # max_lot is not the same experiment.
  bad <- character(0)
  keys <- setdiff(sort(unique(unlist(lapply(s, names)))), vary)
  for (k in keys) {
    v <- vapply(s, function(x) if (is.null(x[[k]])) "<none>" else x[[k]], character(1))
    if (length(unique(v)) > 1L)
      bad <- c(bad, paste0("  ", k, ": ",
                           paste0(names(s), "=", v, collapse = ", ")))
  }
  if (length(bad))
    stop("The cells were built under different settings, so the differences ",
         "between them are not the rule's:\n", paste(bad, collapse = "\n"),
         call. = FALSE)

  first <- s[[1]]
  gone  <- MELP_SETTING_KEYS[!(MELP_SETTING_KEYS %in% names(first))]
  if (length(gone))
    stop("The cells' CONTRACT_SETTINGS does not carry ",
         paste(gone, collapse = ", "), ", so what the B.2 count should be read ",
         "under is unknown. They were built by a version that recorded a ",
         "different set.", call. = FALSE)

  out <- lapply(MELP_SETTING_KEYS, function(k) first[[k]])
  for (nm in setdiff(names(out), "abbr")) {
    # The text, not what coercion makes of it: as.integer("30.5") is 30 and
    # as.integer("3e1") is 30, so both would pass a check on the result while
    # the message claimed a whole number was required. Same rule as
    # check_settings() in build_lot.R, on the stored value rather than the env.
    raw <- trimws(out[[nm]])
    if (!grepl("^[0-9]+$", raw))
      stop("The cells recorded ", MELP_SETTING_KEYS[[nm]], "='", out[[nm]],
           "', which is not a whole number of days.", call. = FALSE)
    out[[nm]] <- as.integer(raw)
  }
  out$abbr <- toupper(trimws(out$abbr))
  # A code-list token, and it is pasted straight into every statement below, so
  # it is checked rather than escaped - an abbreviation with a quote in it is a
  # broken code list, not a value to accommodate.
  if (!grepl("^[A-Z0-9_-]+$", out$abbr))
    stop("The cells recorded melp_med_abbr='", out$abbr, "', which is not a ",
         "medication abbreviation, so no line can be told to contain melphalan.",
         call. = FALSE)
  out
}

# What is read off each build. The same nine numbers the sensitivity harness
# uses, so a melphalan cell and a threshold cell can be read side by side, plus
# four that are about this rule in particular.
MELP_METRICS <- c(
  n_patients         = "patients with at least one line in LOT_LONG_FINAL",
  n_lines            = "lines in LOT_LONG_FINAL",
  median_lines       = "median lines per patient",
  pct_reaching_lot2  = "% of LOT1 patients who reach LOT2",
  pct_reaching_lot3  = "% of LOT1 patients who reach LOT3",
  median_lot1_length = "median LOT1 length in days (inclusive)",
  median_lot1_meds   = "median agents in a LOT1 regimen",
  n_lot1_regimens    = "distinct LOT1 regimen strings",
  n_cart_init        = "lines ending CART_INIT",
  n_melp_add         = "lines ended by melphalan as an added medication",
  n_melp_lines       = "lines whose regimen contains melphalan",
  n_sct_auto_end     = "lines ended by an autologous transplant",
  n_pat_with_melp    = "patients with any melphalan line",
  # "B.2" is the retired five-branch rule's name for the shape: a dose 60-179
  # days after the one before it, outside induction. The name is kept because
  # the count is still the sharpest measure of what the adopted rule changed -
  # these are exactly the line starts it refuses, so the figure should fall to
  # near nothing in the cell that carries the rule and not in the one without.
  n_b2_line_starts   = "MED-started lines whose start is a B.2 second dose",
  n_b2_melp_only     = "...of those, the ones no other agent would have started",
  # The population under discussion: lines that are melphalan alone among the
  # captured non-steroid agents. The rule allows some to advance a line and
  # folds others away; these count where each happened, they do not judge it.
  n_melp_mono_lines    = "lines whose whole regimen is melphalan",
  n_pat_melp_mono      = "patients with at least one melphalan-only line",
  n_melp_mono_adv      = "...of those, MED-started lines after LOT1 - melphalan alone advanced a line",
  n_melp_mono_adv_auto = "...and of those, the ones with a transplant inside the line",
  median_melp_mono_len = "median melphalan-only line length in days (inclusive)",
  # Modifying a line without advancing it: melphalan's own cover is what the
  # line ran out on, so the line is longer and no boundary moved.
  n_melp_sets_runout   = "lines whose run-out date is melphalan's own last cover",
  n_melp_holds_multi   = "...of those, the ones with another agent in the regimen - melphalan outlasted it",
  n_pat_melp_fu        = "patients given melphalan at any point in follow-up - the by-line denominator")

# What counts as melphalan on its own.
#
# LOT_MED_CNT and LOT_BASE_MEDS are the regimen the build settled on, and both
# are already the right grain for this: steroids never enter them - the
# induction scan drops MAP_MED_CLASS = 'STEROID' before the regimen is
# assembled - and permissible substitutes are not folded in either, because
# LOT{n}_MED_CNT counts lot{n}_induction_meds rather than base_meds. So a
# count of one is one observed oncology agent, and no melphalan-plus-steroid
# line is being called a doublet.
#
# LOT_MED_CNT = 0 exists - a transplant- or CART-started line with no agents -
# and is not this.
melp_mono_sql <- function(abbr = "MELP")
  paste0("LOT_MED_CNT = 1 AND upper(trim(coalesce(LOT_BASE_MEDS, ''))) = '", abbr, "'")

# Patients who received melphalan at any point in follow-up.
#
# Off MAP_STACKED, not off the regimens. A melphalan claim that never landed
# inside an induction window never reaches LOT_BASE_MEDS, and that patient has
# still received melphalan - they are exactly the kind of patient the rule is
# meant to act on. Reading the population off the regimen column would define
# the denominator using the thing being measured.
melp_exposed_sql <- function(map_tbl, abbr = "MELP")
  paste0("SELECT DISTINCT cast(PATID as string) AS PATID FROM ", map_tbl,
         " WHERE upper(trim(MAP_MED_TYPE)) = '", abbr, "'")

# A transplant inside the line.
#
# AUTO is detectable anywhere in the line - LOT_TX_AUTO_FLG is set from the
# in-LOT AUTO date, clamped to the line. ALLO is only detectable as the line's
# start type, because allo_lot_span = 'single_day' makes an ALLO line one day
# long, so there is no inside for one to sit in. The two are counted separately
# rather than being added into one number that means different things.
melp_sct_sql <- function()
  "(LOT_TX_AUTO_FLG = 1 OR LOT_START_TYPE IN ('SCT_AUTO', 'SCT_ALLO'))"

# One statement per cell. The reaching-LOTn figures come from LOT_ATTRITION,
# which already holds them, rather than being derived a second way.
#
# The four melphalan figures are where the rule shows: how many lines it ends
# by melphalan, and how many the transplant ends instead. Melphalan is
# transplant conditioning, so a melphalan claim and an AUTO code are often the
# same clinical event, and the two columns moving in opposite directions is
# what tells you the rules are firing on one event rather than two.
#
# ind1 / indn / cart are the build's own induction windows, needed to tell an
# exposure inside a line's induction from one outside it. map_tbl is the
# persisted MAP stack, which is what makes the course count exact rather than
# a proxy.
# Several statements, not one.
#
# It was one SELECT with nineteen scalar subqueries over seven CTEs, two of
# them window queries. Spark turns each scalar subquery into a join, and the
# 2026-08-12 reference run died in the optimizer - "The Spark SQL phase
# optimization failed with an internal error" - before executing anything, so
# all four retries failed the same way. Split, each plan is ordinary.
#
# Same numbers: these are independent aggregates that never needed one plan.
# The counts that shared a scan now share a CASE instead.
#
# Returns one statement per name. melp_metrics() runs them and cbinds the row.
# The 60-179 day band that identifies a "B.2" pair. It named two settings of
# the retired five-branch rule; nothing in the build reads them now, so the two
# numbers live here, beside the only thing that uses them. They describe the
# SHAPE the count is looking for, not a rule any build applies.
MELP_B2_FROM <- 60L
MELP_B2_TO   <- 180L

melp_metric_sql <- function(final_tbl, attrition_tbl, run_id, abbr = "MELP",
                            map_tbl = NULL, expo_days = 30L, ind1 = 60L, indn = 30L,
                            cart = 45L) {
  in_melp <- paste0("array_contains(split(upper(coalesce(LOT_BASE_MEDS, '')), ' '), '", abbr, "')")
  mono    <- melp_mono_sql(abbr)

  # The melphalan exposure chain, the way lot/engine/R/melp_rule.R chains it:
  # doses closer together than expo_days are one administration. Rebuilt here
  # because the engine's version is a CTE inside a build, not a table. Both B.2
  # statements need it, and it is small enough to derive twice.
  mx_with <- paste0("
    WITH mdose AS (
      SELECT PATID, MAP_START_DT AS DOSE_DT FROM ", map_tbl, "
      WHERE upper(trim(MAP_MED_TYPE)) = '", abbr, "' GROUP BY PATID, MAP_START_DT
    ),
    mrun AS (
      SELECT PATID, DOSE_DT,
             CASE WHEN datediff(DOSE_DT,
                    lag(DOSE_DT) OVER (PARTITION BY PATID ORDER BY DOSE_DT))
                       < ", expo_days, " THEN 0 ELSE 1 END AS IS_NEW
      FROM mdose
    ),
    mxe AS (
      SELECT PATID, min(DOSE_DT) AS EXPO_DT
      FROM (SELECT PATID, DOSE_DT,
                   sum(IS_NEW) OVER (PARTITION BY PATID ORDER BY DOSE_DT
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS E
            FROM mrun) r
      GROUP BY PATID, E
    ),
    -- Each exposure with the one immediately before it. The engine judges
    -- consecutive pairs, so the pair has to be consecutive here too: exposures
    -- on days 100, 160 and 250 give the engine 100-160 and 160-250, and a range
    -- join would also match 100-250 and report one line twice.
    mx AS (
      SELECT PATID, EXPO_DT,
             lag(EXPO_DT) OVER (PARTITION BY PATID ORDER BY EXPO_DT) AS PREV_EXPO_DT
      FROM mxe
    )")

  # The B.2 group. All four conditions, because any one alone lets in lines with
  # no B.2 pair at all - a line DARA started, melphalan merely joining its
  # induction window, satisfies "after a runout, melphalan in the regimen".
  #
  # Under the rule these lines should not exist: melp_hold carries the previous
  # line to the second dose, so nothing is left to start a line on it. So this
  # is a check on the hold, not the open question it was when the hold did not
  # ship - see "What B.2 does" in exploration/FILES.md.
  b2 <- function(extra, alias) paste0(mx_with, "
    SELECT count(*) AS ", alias, "
    FROM (SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_START_TYPE,
                 lag(l.LOT_NUM)             OVER w AS PREV_LOT_NUM,
                 lag(l.LOT_START_DT)        OVER w AS PREV_START_DT,
                 lag(l.LOT_START_TYPE)      OVER w AS PREV_START_TYPE,
                 lag(l.LOT_BASE_END_REASON) OVER w AS PREV_REASON
          FROM ", final_tbl, " l
          WINDOW w AS (PARTITION BY l.PATID ORDER BY l.LOT_NUM)) x
    -- One join, and the exposure carries its own immediate predecessor, so the
    -- pair is the one the engine judged and one line cannot be counted twice.
    INNER JOIN mx e ON e.PATID = x.PATID AND e.EXPO_DT = x.LOT_START_DT
    WHERE x.LOT_NUM > 1
    -- 1. the previous line ended by running out, not by melphalan
      AND x.PREV_REASON = 'DISCONTINUATION'
    -- 2. and melphalan STARTED this line. Landing on the start date is not
    -- enough: the same-day tie-break is SCT_ALLO > CART > SCT_AUTO > MED, so an
    -- AUTO coded on the melphalan date takes the start and the line is the
    -- transplant's, not the drug's.
      AND x.LOT_START_TYPE = 'MED'
    -- 3. the exposure before it sits in the previous line...
      AND e.PREV_EXPO_DT IS NOT NULL
      AND e.PREV_EXPO_DT >= x.PREV_START_DT
      AND e.PREV_EXPO_DT <  x.LOT_START_DT
    -- ...outside that line's own induction window, making it B not A
      AND datediff(e.PREV_EXPO_DT, x.PREV_START_DT) > CASE
            WHEN x.PREV_LOT_NUM = 1         THEN ", ind1 - 1L, "
            WHEN x.PREV_START_TYPE = 'CART' THEN ", cart - 1L, "
            ELSE ", indn - 1L, " END
    -- 4. and the pair 60-179 days apart, which is B.2 not B.1 or B.3
      AND datediff(x.LOT_START_DT, e.PREV_EXPO_DT)
            BETWEEN ", MELP_B2_FROM, " AND ", MELP_B2_TO - 1L, extra)

  # The same lines, less the ones another agent would have started anyway.
  # LOT_START_TYPE = 'MED' says a medication won the tie-break, not which one,
  # so a line daratumumab also started that day exists under either reading.
  #
  # A lower bound, deliberately: med_cand also passes over the previous line's
  # agents expanded by permissible substitutes, and that expansion is a session
  # view rather than a table this can read. That drops a line, not invents one.
  melp_only <- paste0("
      AND NOT EXISTS (SELECT 1 FROM ", map_tbl, " o
                      WHERE o.PATID = x.PATID
                        AND o.MAP_START_DT = x.LOT_START_DT
                        AND o.MAP_MED_CLASS <> 'STEROID'
                        AND upper(trim(o.MAP_MED_TYPE)) <> '", abbr, "')")

  no_map <- function(alias) paste0("SELECT cast(NULL as bigint) AS ", alias)

  c(core = paste0("
    WITH per_pat AS (
      SELECT PATID, count(*) AS n_lines FROM ", final_tbl, " GROUP BY PATID
    )
    SELECT count(*)                              AS n_patients,
           sum(n_lines)                          AS n_lines,
           percentile_approx(n_lines, 0.5)       AS median_lines
    FROM per_pat"),

    prog = paste0("
    SELECT round(100.0 * max(CASE WHEN STEP = 'Reached LOT2' THEN N_PATIENTS END)
                 / nullif(max(CASE WHEN STEP = 'Reached LOT1' THEN N_PATIENTS END), 0), 2)
                                                 AS pct_reaching_lot2,
           round(100.0 * max(CASE WHEN STEP = 'Reached LOT3' THEN N_PATIENTS END)
                 / nullif(max(CASE WHEN STEP = 'Reached LOT1' THEN N_PATIENTS END), 0), 2)
                                                 AS pct_reaching_lot3
    FROM ", attrition_tbl, "
    WHERE RUN_ID = '", run_id, "' AND KIND = 'progression'"),

    # One scan of the lines: every count is a CASE over the same rows rather
    # than a scalar subquery of its own.
    lines = paste0("
    SELECT percentile_approx(CASE WHEN LOT_NUM = 1 AND LOT_BASE_LENGTH IS NOT NULL
                                  THEN LOT_BASE_LENGTH END, 0.5)   AS median_lot1_length,
           percentile_approx(CASE WHEN LOT_NUM = 1
                                  THEN LOT_MED_CNT END, 0.5)       AS median_lot1_meds,
           count(DISTINCT CASE WHEN LOT_NUM = 1 AND LOT_BASE_MEDS IS NOT NULL
                                 AND trim(LOT_BASE_MEDS) <> ''
                               THEN LOT_BASE_MEDS END)             AS n_lot1_regimens,
           sum(CASE WHEN LOT_BASE_END_REASON = 'CART_INIT' THEN 1 ELSE 0 END)
                                                                   AS n_cart_init,
           sum(CASE WHEN LOT_BASE_END_REASON = 'SCT_AUTO' THEN 1 ELSE 0 END)
                                                                   AS n_sct_auto_end,
           sum(CASE WHEN LOT_BASE_END_REASON = 'MED_ADD'
                     AND upper(trim(coalesce(LOT_BASE_1ST_ADD_MED, ''))) = '", abbr, "'
                    THEN 1 ELSE 0 END)                             AS n_melp_add,
           sum(CASE WHEN ", in_melp, " THEN 1 ELSE 0 END)          AS n_melp_lines,
           count(DISTINCT CASE WHEN ", in_melp, " THEN PATID END)  AS n_pat_with_melp,
           -- Melphalan on its own. n_melp_lines counts every line it appears
           -- in, including ones another agent defines; these are the lines
           -- that are only melphalan, which is what the rule is questioned on.
           sum(CASE WHEN ", mono, " THEN 1 ELSE 0 END)             AS n_melp_mono_lines,
           count(DISTINCT CASE WHEN ", mono, " THEN PATID END)     AS n_pat_melp_mono,
           -- LOT_START_TYPE = 'MED' is the discriminator, not LOT_NUM alone. A
           -- LOT2 started by SCT_AUTO or CART can carry melphalan as its only
           -- agent - that is conditioning, and counting it here would report
           -- the transplant's boundary as the drug's.
           sum(CASE WHEN ", mono, " AND LOT_NUM > 1 AND LOT_START_TYPE = 'MED'
                    THEN 1 ELSE 0 END)                             AS n_melp_mono_adv,
           -- With an autologous transplant inside the line. High-dose
           -- melphalan is conditioning, so these are the ones most likely to
           -- be a transplant wearing a line rather than a new therapy.
           sum(CASE WHEN ", mono, " AND LOT_NUM > 1 AND LOT_START_TYPE = 'MED'
                     AND LOT_TX_AUTO_FLG = 1
                    THEN 1 ELSE 0 END)                             AS n_melp_mono_adv_auto,
           percentile_approx(CASE WHEN ", mono, " THEN LOT_BASE_LENGTH END, 0.5)
                                                                   AS median_melp_mono_len
    FROM ", final_tbl),

    # The denominator every by-line table below is restricted to, carried in the
    # headline row so the two cannot be read as the same population.
    expo    = if (is.null(map_tbl)) no_map("n_pat_melp_fu")
              else paste0("
    SELECT count(DISTINCT PATID) AS n_pat_melp_fu FROM ", map_tbl, "
    WHERE upper(trim(MAP_MED_TYPE)) = '", abbr, "'"),

    b2      = if (is.null(map_tbl)) no_map("n_b2_line_starts")
              else b2("", "n_b2_line_starts"),
    b2_only = if (is.null(map_tbl)) no_map("n_b2_melp_only")
              else b2(melp_only, "n_b2_melp_only"),

    # Melphalan modifying a line without advancing it.
    #
    # A line runs out when its last remaining base agent does, so a melphalan
    # dose late in a line can be the agent that sets the run-out date - the
    # line is longer than it would have been, and no boundary moved. The
    # advance counts above cannot see this, and neither can a line-length
    # median, which reports the effect without attributing it.
    #
    # Melphalan's cover is read from MAP_STACKED and bounded to the line, so a
    # dose in a neighbouring line cannot claim this one's date. The multi-agent
    # split is the one worth reading: on a melphalan-only line melphalan sets
    # the date by construction, and only where another agent is in the regimen
    # does this say melphalan outlasted it.
    hold    = if (is.null(map_tbl)) no_map("n_melp_sets_runout")
              else paste0("
    WITH melp_cover AS (
      SELECT cast(l.PATID as string) AS PATID, l.LOT_NUM, l.LOT_MED_CNT,
             l.LOT_BASE_DISCON_DT,
             -- The engine's own per-drug run-out (discon_per_med): the FIRST
             -- episode flagged discontinued, and only the last cover when none
             -- is. A plain max would credit a later restart with setting a
             -- run-out the build read off the earlier episode.
             coalesce(min(CASE WHEN m.MAP_DISCON_FLG = 1 THEN m.MAP_END_DT END),
                      max(m.MAP_END_DT)) AS MELP_COVER_END
      FROM ", final_tbl, " l
      INNER JOIN ", map_tbl, " m
              ON cast(m.PATID as string) = cast(l.PATID as string)
             AND upper(trim(m.MAP_MED_TYPE)) = '", abbr, "'
             AND m.MAP_START_DT >= l.LOT_START_DT
      WHERE l.LOT_BASE_DISCON_DT IS NOT NULL AND ", in_melp, "
      GROUP BY 1, 2, 3, 4
    )
    SELECT sum(CASE WHEN MELP_COVER_END = LOT_BASE_DISCON_DT
                    THEN 1 ELSE 0 END)                AS n_melp_sets_runout,
           sum(CASE WHEN MELP_COVER_END = LOT_BASE_DISCON_DT AND LOT_MED_CNT > 1
                    THEN 1 ELSE 0 END)                AS n_melp_holds_multi
    FROM melp_cover"))
}

# One row, from however many statements it takes. A statement that fails stops
# with the warehouse's own message. One that comes back empty is a NULL here,
# and the caller stops on it - the result is the comparison between both
# cells, not a best effort at one.
melp_metrics <- function(con, ...) {
  qs <- melp_metric_sql(...)
  out <- list()
  for (nm in names(qs)) {
    d <- tryCatch(db_q(con, qs[[nm]]), error = function(e) e)
    if (inherits(d, "error"))
      stop("Metrics statement ", nm, " failed: ", conditionMessage(d),
           call. = FALSE)
    if (nrow(d) != 1L) return(NULL)
    out[[nm]] <- d
  }
  do.call(cbind, unname(out))
}

# Each cell against the reference. No direction is predicted. That is the
# difference between this and the sensitivity sweep: there a threshold moves a
# number one way, so predicting the sign first is a test. Here the rule moves
# boundaries in both directions at once - B.1 adds a line, B.2 and B.3 remove
# one - and which wins is what the run is for. A written-down guess would be a
# guess.
melp_compare <- function(results, cells) {
  ref <- results[results$cell == "reference", , drop = FALSE]
  if (!nrow(ref)) stop("No reference cell in the results.", call. = FALSE)
  out <- list()
  for (i in seq_len(nrow(results))) {
    r <- results[i, , drop = FALSE]
    if (identical(r$cell, "reference")) next
    for (m in names(MELP_METRICS)) {
      # A metric named here and not selected by melp_metric_sql() would
      # otherwise come back as a zero-length column and fail inside the
      # arithmetic, several lines from the cause.
      if (is.null(ref[[m]]) || is.null(r[[m]]))
        stop("Metric '", m, "' is named in MELP_METRICS but is not a column of ",
             "the results, so melp_metric_sql() does not select it.", call. = FALSE)
      base <- suppressWarnings(as.numeric(ref[[m]][1]))
      got  <- suppressWarnings(as.numeric(r[[m]][1]))
      out[[length(out) + 1L]] <- data.frame(
        cell = r$cell, metric = m, reference = base, observed = got,
        change = if (is.na(base) || is.na(got)) NA_real_ else got - base,
        pct_change = if (is.na(base) || is.na(got) || base == 0) NA_real_
                     else round(100 * (got - base) / base, 2),
        stringsAsFactors = FALSE)
    }
  }
  do.call(rbind, out)
}

# Line by line, among the patients who received melphalan at any point in
# follow-up. Three questions in one table, all at LOT_NUM grain because the ask
# is per line and because LOT2 and LOT3 mean nothing without LOT1 beside them:
#
#   1. how long each line lasts, over ALL lines - so the reference row and a
#      rule row differ by exactly what the rule did to duration
#   2. how much of each line is melphalan alone
#   3. how many patients have a transplant inside a melphalan-containing line
#
# Restricted to the melphalan-exposed, so every row shares one denominator.
# The cohort-wide figures are in MELP_METRICS and are NOT this population -
# n_pat_melp_fu carries the size of this one into that row so the two cannot be
# read across.
#
# Aliases are upper case, which keeps them out of MELP_METRICS' namespace: the
# suite reads every lower-case n_/median_/pct_ alias out of melp_metric_sql()
# and requires the set to be exactly MELP_METRICS. This is a table, not a row.
melp_by_line_sql <- function(final_tbl, map_tbl, abbr = "MELP") {
  mono <- melp_mono_sql(abbr)
  sct  <- melp_sct_sql()
  any_melp <- paste0("array_contains(split(upper(coalesce(LOT_BASE_MEDS, '')), ' '), '",
                     abbr, "')")
  # Over all lines (question 1) and over the melphalan-only ones (question 2).
  q  <- function(p, w) paste0("percentile_approx(",
          if (nzchar(w)) paste0("CASE WHEN ", w, " THEN LOT_BASE_LENGTH END")
          else "LOT_BASE_LENGTH", ", ", p, ")")
  pat <- function(w) paste0("count(DISTINCT CASE WHEN ", w, " THEN PATID END)")
  paste0("
    WITH exposed AS (", melp_exposed_sql(map_tbl, abbr), "),
    lines0 AS (
      SELECT f.* FROM ", final_tbl, " f
      INNER JOIN exposed e ON cast(f.PATID as string) = e.PATID
    ),
    -- Melphalan actually given inside the line, from MAP_STACKED.
    --
    -- The regimen cannot answer this on its own. An ALLO-started line carries
    -- no regimen rows at all - 10_lot2_5_base.R suppresses them - so a
    -- melphalan-conditioned allograft has a blank LOT_BASE_MEDS and is
    -- invisible to any test on it. A count of melphalan-plus-ALLO built from
    -- the regimen is structurally zero, which reads as evidence of absence.
    melp_in_line AS (
      SELECT DISTINCT l.PATID, l.LOT_NUM
      FROM lines0 l
      INNER JOIN ", map_tbl, " m
              ON cast(m.PATID as string) = cast(l.PATID as string)
      WHERE upper(trim(m.MAP_MED_TYPE)) = '", abbr, "'
        AND m.MAP_START_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
    ),
    lines AS (
      SELECT l.*, CASE WHEN d.PATID IS NOT NULL THEN 1 ELSE 0 END AS HAS_MELP_DOSE
      FROM lines0 l
      LEFT JOIN melp_in_line d ON d.PATID = l.PATID AND d.LOT_NUM = l.LOT_NUM
    )
    SELECT LOT_NUM,
           count(*)                                          AS N_LINES,
           count(DISTINCT PATID)                             AS N_PATIENTS,
           -- 1. duration of every line at this LOT, not only melphalan ones
           ", q(0.25, ""), "                                 AS P25_LEN,
           ", q(0.5,  ""), "                                 AS MEDIAN_LEN,
           ", q(0.75, ""), "                                 AS P75_LEN,
           round(avg(LOT_BASE_LENGTH), 1)                    AS MEAN_LEN,
           -- 2. the regimen make-up. melp_regimens_by_line_sql() has the rest
           sum(CASE WHEN ", any_melp, " THEN 1 ELSE 0 END)   AS N_MELP_ANY,
           ", pat(any_melp), "                               AS N_PAT_MELP_ANY,
           sum(CASE WHEN ", mono, " THEN 1 ELSE 0 END)       AS N_MONO,
           ", pat(mono), "                                   AS N_PAT_MONO,
           -- Started by a medication rather than by a transplant or CART, so
           -- this is where the melphalan rule can have set the boundary.
           sum(CASE WHEN ", mono, " AND LOT_START_TYPE = 'MED' THEN 1 ELSE 0 END)
                                                             AS N_MONO_MED_START,
           ", q(0.25, mono), "                               AS P25_MONO_LEN,
           ", q(0.5,  mono), "                               AS MEDIAN_MONO_LEN,
           ", q(0.75, mono), "                               AS P75_MONO_LEN,
           round(avg(CASE WHEN ", mono, " THEN LOT_BASE_LENGTH END), 1)
                                                             AS MEAN_MONO_LEN,
           sum(CASE WHEN ", mono, " AND LOT_BASE_END_REASON = 'DISCONTINUATION'
                    THEN 1 ELSE 0 END)                       AS N_MONO_END_DISCON,
           sum(CASE WHEN ", mono, " AND LOT_BASE_END_REASON = 'MED_ADD'
                    THEN 1 ELSE 0 END)                       AS N_MONO_END_MED_ADD,
           sum(CASE WHEN ", mono, " AND LOT_BASE_END_REASON = 'SCT_AUTO'
                    THEN 1 ELSE 0 END)                       AS N_MONO_END_SCT_AUTO,
           -- Melphalan given inside the line, whether or not it reached the
           -- regimen. Wider than N_MELP_ANY and the honest denominator for the
           -- transplant question below.
           sum(HAS_MELP_DOSE)                                AS N_MELP_DOSE,
           ", pat("HAS_MELP_DOSE = 1"), "                    AS N_PAT_MELP_DOSE,
           -- 3. a transplant inside a line melphalan was given in. Dose-based,
           -- not regimen-based, or every ALLO line drops out by construction.
           -- AUTO and ALLO stay separate columns because they are found
           -- different ways - see melp_sct_sql() - and adding them hides that.
           ", pat(paste0("HAS_MELP_DOSE = 1 AND ", sct)), "  AS N_PAT_MELP_SCT,
           ", pat("HAS_MELP_DOSE = 1 AND LOT_TX_AUTO_FLG = 1"), "
                                                             AS N_PAT_MELP_AUTO,
           ", pat("HAS_MELP_DOSE = 1 AND LOT_START_TYPE = 'SCT_ALLO'"), "
                                                             AS N_PAT_MELP_ALLO,
           ", pat(paste0(mono, " AND ", sct)), "             AS N_PAT_MONO_SCT
    FROM lines
    GROUP BY LOT_NUM
    ORDER BY LOT_NUM")
}

# The two readings against each other, patient by patient rather than by
# subtracting totals.
#
# Subtracting aggregates does not answer "how many patients does the transplant
# question affect". A patient whose lines move can leave the totals where they
# were - the SCT rule may win the end-reason priority anyway, one changed
# boundary can shift several later lines, and two patients moving opposite ways
# cancel. So the two LOT_LONG_FINAL tables are compared directly: a patient
# counts as differing if their line count, or any line's start, end or end
# reason, is not the same under both readings.
melp_modes_patients_sql <- function(a_tbl, y_tbl) {
  side <- function(t) paste0("
      SELECT cast(PATID as string) AS PATID,
             concat_ws('|', sort_array(collect_list(concat_ws(':',
               cast(LOT_NUM as string), cast(LOT_START_DT as string),
               cast(LOT_BASE_END_DT as string),
               coalesce(LOT_BASE_END_REASON, ''))))) AS SHAPE,
             count(*) AS N_LINES
      FROM ", t, " GROUP BY PATID")
  paste0("
    WITH a AS (", side(a_tbl), "),
    y AS (", side(y_tbl), ")
    SELECT count(*)                                                AS N_PATIENTS,
           sum(CASE WHEN a.PATID IS NULL OR y.PATID IS NULL THEN 1
                    ELSE 0 END)                                    AS N_ONLY_ONE_SIDE,
           sum(CASE WHEN a.SHAPE <=> y.SHAPE THEN 0 ELSE 1 END)    AS N_DIFFERENT,
           sum(CASE WHEN a.N_LINES <=> y.N_LINES THEN 0 ELSE 1 END) AS N_LINE_COUNT_DIFFERENT,
           sum(CASE WHEN NOT (a.SHAPE <=> y.SHAPE)
                     AND (a.N_LINES <=> y.N_LINES) THEN 1 ELSE 0 END)
                                                                   AS N_SAME_COUNT_DIFFERENT_LINES
    FROM a FULL OUTER JOIN y ON a.PATID = y.PATID")
}

# ---- The read ---------------------------------------------------------------
# What every cell was built over, before any number is read off it.
#
# MELP_INPUT_FIELDS compares CODE_MD5 across the cells. That catches a
# cell built from different code than its sibling. It does not catch both
# being built from an engine that no longer matches this checkout, because
# the two agree with each other perfectly.
#
# So the recorded hash is also compared against the code now running. Same
# fingerprint the build writes: every .R under the engine's R/ plus build.R,
# concatenated in radix order and hashed.
#
# A mismatch stops the read. MELP_ALLOW_STALE_CODE=TRUE downgrades it to a
# warning, for reading an old cell on purpose.
melp_check_code <- function(inputs, lot_root) {
  # The build's own function, not a second implementation of it - a hash that
  # has to equal the one in the metadata cannot be computed a different way.
  # Neither script sources build_lot.R, so it is loaded into a private env.
  e <- new.env(parent = globalenv())
  ok <- tryCatch({
    sys.source(file.path(lot_root, "R", "build_lot.R"), envir = e); TRUE
  }, error = function(err) FALSE)
  fp <- if (ok && exists("code_fingerprint", envir = e, mode = "function"))
          get("code_fingerprint", envir = e, mode = "function") else NULL
  if (is.null(fp)) {
    warning("code_fingerprint() could not be loaded from ", lot_root,
            ", so there is no check that these cells were built by the code ",
            "reading them.", call. = FALSE)
    return(invisible(NA))
  }
  now <- tryCatch(fp(lot_root), error = function(e) NA_character_)
  if (is.na(now)) {
    warning("The engine's code could not be fingerprinted, so there is no ",
            "check that these cells were built by the code reading them.",
            call. = FALSE)
    return(invisible(NA))
  }
  was <- unique(vapply(inputs, function(r) {
    x <- r$CODE_MD5
    if (is.null(x) || length(x) == 0 || is.na(x[1])) "<none>" else as.character(x[1])
  }, character(1)))
  if (identical(was, now)) return(invisible(TRUE))
  # A STOP, not a warning. A warning scrolls past, and a reader that carries on
  # writes headline numbers from cells a different engine built. Numbers that
  # describe another engine are worse than no numbers, because nothing
  # downstream carries the disagreement.
  #
  # MELP_ALLOW_STALE_CODE=TRUE is the escape, for reading an old cell on
  # purpose. It downgrades this to a warning.
  msg <- paste0("These cells were built by LOT code with fingerprint ",
                paste(was, collapse = "/"), ", and the code reading them is ",
                now, ". The numbers would describe the engine as it was when ",
                "the cells were built, not as it is now. Rebuild all cells ",
                "with run_melp_simple.R. Set MELP_ALLOW_STALE_CODE=TRUE to read ",
                "them anyway.")
  if (identical(toupper(trimws(Sys.getenv("MELP_ALLOW_STALE_CODE", unset = ""))),
                "TRUE")) {
    warning(msg, " Reading anyway because MELP_ALLOW_STALE_CODE is set.",
            call. = FALSE)
    return(invisible(FALSE))
  }
  stop(msg, call. = FALSE)
}

# Provenance columns, prepended to every CSV this folder writes.
#
# A CSV that leaves the folder is on its own. Nothing in it said which cohort
# attempt, which engine code or which run produced it, so a file found on a
# desktop months later could not be told from one built by a different engine -
# which is exactly the confusion these cells exist to avoid.
melp_stamp <- function(d, inputs, status) {
  if (is.null(d) || !nrow(d)) return(d)
  one <- function(f) {
    v <- unique(vapply(inputs, function(r) {
      x <- r[[f]]
      if (is.null(x) || !length(x) || is.na(x[1])) "" else as.character(x[1])
    }, character(1)))
    paste(v, collapse = "/")
  }
  cbind(COHORT_RUN_ID = one("COHORT_RUN_ID"),
        COHORT_STAMP  = one("COHORT_STAMP"),
        CODE_MD5      = one("CODE_MD5"),
        LOT_RUN_IDS   = paste(vapply(status, function(x) x$run_id, character(1)),
                              collapse = "/"),
        READ_AT       = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
        d, stringsAsFactors = FALSE)
}

melp_read_inputs <- function(con, cells, status, key = "apply_melp_rule") {
  inputs <- list()
  for (c_i in cells) {
    # The error is kept, not swallowed. A query that failed and a run with no
    # metadata row are different problems, and reporting the first as the
    # second sends the reader after a missing row that is there.
    r <- tryCatch(db_q(con, melp_inputs_sql(
      wrk(paste0(c_i$prefix, "LOT_RUN_METADATA")),
      wrk(paste0(c_i$prefix, "LOT_CODELIST_METADATA")),
      wrk(paste0(c_i$prefix, "LOT_BUILD_STATUS")),
      status[[c_i$id]]$run_id)), error = function(e) e)
    if (inherits(r, "error"))
      stop("Could not read what ", c_i$id, " was built over: ",
           conditionMessage(r), call. = FALSE)
    if (!nrow(r))
      stop("No LOT_RUN_METADATA row for ", c_i$id, ". Without it there is no ",
           "record of which cohort attempt or code lists it was built over, and ",
           "the comparison cannot be shown to be about the rule.", call. = FALSE)
    inputs[[c_i$id]] <- r
  }
  melp_check_inputs(inputs)
  melp_check_deviations(inputs, cells, key)
  inputs
}
