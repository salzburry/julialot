# Cohort membership and the attrition funnel.
#
# The 1L cohort's criteria were applied by the cohort build and the LOT build
# between them - I1 to X3 by the cohort build, X4 by the LOT engine's line
# criteria - so this module does not re-apply them. What it does is:
#
#   * index each selected cohort on the right line's start date,
#   * apply the criteria that are this package's own (N1, N2, I5, and the
#     index-date floors the new protocol adds),
#   * write one funnel per cohort in the order ../IE_CRITERIA.md section 8 sets.
#
# A criterion whose evidence is not in the cohort or LOT tables is named in
# CRITERIA_UNAVAILABLE and stops the run rather than being quietly skipped.

# criterion -> where its verdict comes from. `here` is applied below; `cohort`
# and `lot` were applied upstream and are read off the cohort table's flags.
CRITERION_SOURCE <- c(
  I1_mm_dx          = "cohort", I2_age            = "cohort",
  I3_eligible_1l_tx = "cohort", I4_ce_pre         = "cohort",
  X1_prior_mm_tx    = "cohort", X2_other_cancer   = "cohort",
  # X4 is read off the cohort table like the other three exclusions: the flag
  # is NO_BELANTAMAB_PRE_LOT1, a pre-index criterion the cohort build computed.
  # The LOT engine's own belantamab rule is a different criterion - it removes
  # a patient with belantamab in ANY line, after the lines are built - so
  # rebuilding the LOT run does not recreate this flag.
  X3_pregnancy      = "cohort", X4_belantamab     = "cohort",
  I5_followup       = "here",   N1_received_line  = "here",
  N2_ce_pre         = "here"
)

# criterion -> the predicate on S_COHORT that tests it here. A criterion can be
# in both maps: I4/N2 is continuous enrolment before index, which the cohort
# build applied on ITS index date and this package re-applies on the line's,
# with the protocol's own 30-day gap allowance.
#
# Read by both membership (IN_COHORT) and the funnel, so a criterion added here
# with a `here` CRITERION_SOURCE entry is applied by both without further code.
# Its predicate is over S_COHORT's own columns, which are computed for every
# row whatever the list says.
HERE_PRED <- list(
  N1_received_line = "1 = 1",
  I4_ce_pre        = "MET_N2 = 1",
  N2_ce_pre        = "MET_N2 = 1",
  I5_followup      = "MET_I5 = 1"
)

mod_cohorts <- function(con, cfg, cohort) {
  unknown <- setdiff(cohort$criteria, names(CRITERION_SOURCE))
  if (length(unknown))
    stop("COHORT ERROR: ", cohort$key, " names criteria this package cannot ",
         "source: ", paste(unknown, collapse = ", "), ".", call. = FALSE)
  # A criterion this package applies has to say HOW. Declared `here` with no
  # predicate it is a funnel step that removes nobody and no membership test at
  # all, under a name the attrition table prints as if it had been applied.
  here_ks <- cohort$criteria[CRITERION_SOURCE[cohort$criteria] == "here"]
  no_pred <- setdiff(here_ks, names(HERE_PRED))
  if (length(no_pred))
    stop("COHORT ERROR: ", cohort$key, " lists ", paste(no_pred, collapse = ", "),
         " as applied by this package, but HERE_PRED gives no predicate for it. ",
         "A criterion applied here is a predicate over S_COHORT's columns; ",
         "membership and the funnel both read it from HERE_PRED.", call. = FALSE)

  floor_sql <- if (!is.na(cohort$index_from))
    sprintf("AND s.LOT_START_DT >= date('%s')", cfg[[cohort$index_from]]) else ""

  # I5. Three readings, and they are not the same criterion.
  #   claim_from_index  - the protocol's words. The index claim itself is a
  #                       claim on the index date, so this excludes nobody.
  #   claim_after_index - a claim strictly after the index, which is what the
  #                       wording is probably reaching for.
  #   enrolled_on_index - the June 2026 rule the current build implements.
  # ../OPEN_QUESTIONS.md Q5.
  fu_pred <- switch(cfg$fu_evidence_rule,
    claim_from_index  = "1 = 1",
    claim_after_index = "fu.N_CLAIMS_AFTER_INDEX > 0 OR c.DEATH_DT IS NOT NULL",
    # ce.COV_END, not c.ENDDATE_CE. ENDDATE_CE is the input cohort's own
    # enrolment episode - the 1L one - so a later cohort was tested against a
    # date belonging to a different index, and a patient who disenrolled after
    # 1L and re-enrolled before their 2L failed a test they satisfy. `ce` is
    # already joined here as the span covering THIS cohort's index date, which
    # is the span the question is about.
    enrolled_on_index = "ce.COV_END >= s.LOT_START_DT")

  # N2. Continuous enrolment before this cohort's own index date, rebuilt from
  # the raw spans because the CDM rollup bridges gaps of LESS than 30 days
  # while the protocol allows 30 or fewer - a day's difference at the boundary,
  # in the stricter direction.
  ce_pre <- sprintf("ce.COV_START <= date_sub(s.LOT_START_DT, %d)
                     AND ce.COV_END >= date_sub(s.LOT_START_DT, 1)",
                    as.integer(cfg$ce_pre_days))

  # Nesting is a SETTING, not structure. s7.2.1 read literally makes 2L the
  # subset of 1L who initiate a second line, and that is the default. But the
  # requirement is what makes a 1L index outside the window cost the patient
  # their 2L and 3L rows too, and an analysis of second-line initiators does
  # not always want that. COHORT_NESTED=FALSE lets each line stand on its own
  # index. Either way the row says which, so a number can never be read under
  # the wrong one.
  #
  # Decided HERE, before any join is built, because there is exactly one
  # `parent` and it has to answer to this. It was decided after the join was
  # already assigned, and only replaced it when nesting was ON - so under
  # COHORT_NESTED=FALSE the join survived while the row said NESTED = 0, and
  # the data and its own metadata disagreed.
  nested <- !is.na(cohort$nested_in) && isTRUE(cfg$cohort_nested)

  # The parent must be IN the parent cohort, not merely indexed in it. Without
  # IN_COHORT = 1 a patient who failed the 1L continuous-enrolment test still
  # reaches the 2L cohort, and 2L stops being a subset of 1L.
  parent <- if (nested)
    sprintf("INNER JOIN %s par ON par.PATID = s.PATID AND par.COHORT = '%s'
             AND par.IN_COHORT = 1", wrk("S_COHORT"), cohort$nested_in) else ""

  # A re-run replaces this cohort's rows rather than appending a second copy.
  # The parent join reads S_COHORT while this statement writes to it, so the
  # parent's rows are staged into a view first: Spark does not define the
  # result of reading a table an INSERT is writing.
  # CRITERIA_ASKED and NESTED are what make IN_COHORT readable on its own.
  #
  # A MET_* column is on every row of every cohort, but which of them the
  # verdict is OVER differs: 1L and SEC2L are judged on nine criteria, 2L and
  # 3L on three - N1, N2 and I5 - so MET_X1 to MET_X4 sit on a 2L row without
  # being part of its verdict. SEC2L drops X2 entirely under the shipped
  # default. An analyst who ANDed the flags would reproduce 1L and get a
  # DIFFERENT cohort at 2L, 3L and SEC2L, with nothing on the row to warn them.
  # So the row carries the list its own IN_COHORT was computed from.
  prepare_table(con, wrk("S_COHORT"),
    "PATID string, COHORT string, LOT_NUM int, INDEX_DATE date,
     MET_N1 int, MET_N2 int, MET_I5 int,
     MET_X1 int, MET_X2 int, MET_X3 int, MET_X4 int, IN_COHORT int,
     CRITERIA_ASKED string, NESTED int",
    cohort$key)
  if (nested) {
    db_exec(con, sprintf(
      "CREATE OR REPLACE TEMPORARY VIEW s_parent_cohort AS
       SELECT PATID FROM %s WHERE COHORT = '%s' AND IN_COHORT = 1",
      wrk("S_COHORT"), cohort$nested_in))
    parent <- "INNER JOIN s_parent_cohort par ON par.PATID = s.PATID"
  }

  # IN_COHORT is the funnel's last step, by construction. Every MET_* column is
  # computed in the inner query whatever the list says, so the evidence is on
  # the row; membership is then the AND of the predicates the cohort's list
  # names - HERE_PRED for what this package applies, FLAG_PRED for the
  # exclusions read off the input. That is the same map the funnel accumulates,
  # so the two cannot admit different patients.
  run_step(con, paste0("cohort_", cohort$key), sprintf("
    INSERT INTO %1$s
    SELECT PATID, COHORT, LOT_NUM, INDEX_DATE,
           MET_N1, MET_N2, MET_I5, MET_X1, MET_X2, MET_X3, MET_X4,
           CASE WHEN %12$s THEN 1 ELSE 0 END AS IN_COHORT,
           '%17$s' AS CRITERIA_ASKED, %18$d AS NESTED
    FROM (
      SELECT s.PATID, '%2$s' AS COHORT, s.LOT_NUM, s.LOT_START_DT AS INDEX_DATE,
             1 AS MET_N1,
             CASE WHEN %3$s THEN 1 ELSE 0 END AS MET_N2,
             CASE WHEN %4$s THEN 1 ELSE 0 END AS MET_I5,
             CASE WHEN %13$s THEN 1 ELSE 0 END AS MET_X1,
             CASE WHEN %14$s THEN 1 ELSE 0 END AS MET_X2,
             CASE WHEN %15$s THEN 1 ELSE 0 END AS MET_X3,
             CASE WHEN %16$s THEN 1 ELSE 0 END AS MET_X4
      FROM %5$s s
      INNER JOIN %6$s c ON c.PATID = s.PATID
      LEFT JOIN %7$s ce
             ON ce.PATID = s.PATID
            AND ce.COV_START <= s.LOT_START_DT AND ce.COV_END >= s.LOT_START_DT
      LEFT JOIN %8$s fu ON fu.PATID = s.PATID AND fu.LOT_NUM = s.LOT_NUM
      %9$s
      WHERE s.LOT_NUM = %10$d %11$s
    ) m",
    wrk("S_COHORT"), cohort$key, ce_pre, fu_pred, wrk("S_SPINE"),
    # S_ELIGIBILITY, not the upstream table. The four exclusions were decided
    # by mod_eligibility() against whatever the input carried, and are taken
    # here as given: this module combines a patient with a line, it does not
    # re-judge eligibility. One module reads INPUT_COHORT_TABLE, and it is not
    # this one.
    wrk("S_ELIGIBILITY"), wrk("S_ENROLL_SPANS"), wrk("S_FU_CLAIMS"),
    parent, cohort$lot_num, floor_sql,
    membership_predicate(cohort),
    "c.MET_X1 = 1", "c.MET_X2 = 1", "c.MET_X3 = 1", "c.MET_X4 = 1",
    paste(cohort$criteria, collapse = "; "), as.integer(nested)),
    qc = sprintf("SELECT count(*) AS n_indexed, sum(IN_COHORT) AS n_in_cohort
                  FROM %s WHERE COHORT = '%s'", wrk("S_COHORT"), cohort$key))
}

# The funnel. One row per criterion, in the order ../IE_CRITERIA.md section 8
# sets, each row applying every criterion above it plus its own - so it reads
# top to bottom and each step's loss is the difference from the row before.
#
# Criteria applied upstream (I1 to X4) are reported as counts carried in rather
# than as losses, because this package cannot re-derive them and a funnel that
# showed them as zero-loss steps would claim they cost nothing.
mod_attrition <- function(con, cfg, cohort) {
  prepare_table(con, wrk("S_ATTRITION"),
    "COHORT string, STEP int, CRITERION string, APPLIED_BY string,
     N_REMAINING int, N_LOST int", cohort$key)

  # Each step carries the population that passed every criterion at or above
  # it. A step whose verdict came from upstream adds no predicate, so it
  # repeats the count above rather than resetting - a funnel whose N_REMAINING
  # goes back up is not a funnel.
  #
  # One SQL statement, not a query per criterion per cohort: 36 round-trips
  # otherwise.
  cum <- character(0)
  arms <- character(0)
  for (i in seq_along(cohort$criteria)) {
    k <- cohort$criteria[i]
    # An exclusion applied here from a retained flag is a step this funnel can
    # show a loss at. Without it the funnel accumulates only the enrolment and
    # follow-up predicates, and its final count exceeds the cohort it describes.
    preds <- criterion_predicates(k)
    src <- CRITERION_SOURCE[[k]]
    applied_by <- if (length(preds) && src != "here") paste0(src, "+here") else src
    cum <- c(cum, preds)
    # Composed by the SAME helper membership uses. Joined bare, a predicate
    # carrying an OR - `MET_N2 = 1 OR MET_I5 = 1` - binds the cohort filter to
    # its left arm only, and the funnel's last step counts other cohorts' rows.
    where <- sprintf("COHORT = '%s'%s", cohort$key,
                     if (length(cum)) paste0(" AND ", and_predicates(cum)) else "")
    arms <- c(arms, sprintf(
      "SELECT '%s' AS COHORT, %d AS STEP, '%s' AS CRITERION,
              '%s' AS APPLIED_BY,
              (SELECT count(*) FROM %s WHERE %s) AS N_REMAINING",
      cohort$key, i, k, applied_by, wrk("S_COHORT"), where))
  }

  run_step(con, paste0("attrition_", cohort$key), sprintf("
    INSERT INTO %s
    WITH steps AS (
      %s
    )
    -- N_LOST as the difference from the row above, in the same pass. It was a
    -- MERGE, which needs a Delta table and is the only statement in the
    -- package that did.
    SELECT COHORT, STEP, CRITERION, APPLIED_BY, N_REMAINING,
           cast(lag(N_REMAINING) OVER (PARTITION BY COHORT ORDER BY STEP)
                - N_REMAINING as int) AS N_LOST
    FROM steps",
    wrk("S_ATTRITION"), paste(arms, collapse = "\n      UNION ALL\n      ")),
    qc = sprintf("SELECT count(*) AS n_steps, max(N_REMAINING) AS n_in
                  FROM %s WHERE COHORT = '%s'", wrk("S_ATTRITION"),
                 cohort$key))
  log_msg("  attrition written for ", cohort$key, ": ",
          length(cohort$criteria), " step(s)")
}

# The enrolment spans, built once from the raw table with the protocol's own
# gap allowance. Not the CDM rollup - see above.
# The columns this package reads off INPUT_COHORT_TABLE, checked before
# anything runs.
#
# Every module indexes on this table - INDEX_DATE, the end dates, DEATH_DT,
# YRDOB, GDR_CD, MM_DX_DT. Without them a module fails on an unresolved column
# naming neither the table nor the setting that chose it.
#
# It also refuses a table of patient ids and eligibility flags, which carries
# none of them and cannot drive this package or the LOT engine.
COHORT_TABLE_REQUIRED <- c("PATID", "INDEX_DATE", "ENDDATE", "ENDDATE_CE",
                           "DEATH_DT", "MM_DX_DT", "YRDOB", "GDR_CD")

# The exclusion flags a WIDE cohort table retains, and the criterion each one
# carries. Named after the cohort build's own columns.
#
# With an ordinary pre-filtered input these are absent and nothing needs them.
# With a wide input - one that keeps patients failing an exclusion so the
# secondary 2L cohort can have them - they are the only thing standing between
# a 1L cohort and a patient with a prior cancer.
CRITERION_FLAG <- c(
  X1_prior_mm_tx  = "NO_PRIOR_MM_TX",
  X2_other_cancer = "NO_OTHER_CANCER_PRE_LOT1",
  X3_pregnancy    = "NO_PREGNANCY",
  X4_belantamab   = "NO_BELANTAMAB_PRE_LOT1")

# The input's columns, as check_cohort_table() found them. The cohort SQL
# reads this to decide which exclusion flags it can apply, so a stale answer
# from a previous build would apply a flag the current input does not carry -
# or skip one it does. Cleared per build by reset_run_state().
.input_cols <- new.env(parent = emptyenv())
.cohort_cols <- function()
  get0("cols", envir = .input_cols, ifnotfound = character(0))

reset_cohort_columns <- function() {
  rm(list = ls(.input_cols), envir = .input_cols)
  invisible(TRUE)
}
# Registered rather than called by name from reset_run_state(): that runs
# before this file is sourced, so it cannot reach anything defined here.
register_run_reset("cohort_columns", reset_cohort_columns)

# criterion -> the S_COHORT column carrying its verdict, for the funnel. A
# criterion whose flag the input does not carry writes 1 for everyone, so the
# step shows no loss - which is the truth: it was applied upstream.
FLAG_PRED <- list(
  X1_prior_mm_tx  = "MET_X1 = 1",
  X2_other_cancer = "MET_X2 = 1",
  X3_pregnancy    = "MET_X3 = 1",
  X4_belantamab   = "MET_X4 = 1")

# The predicate that applies this cohort's own exclusions from the flags the
# input carries. Empty when the input has none, which is the pre-filtered case.
# One predicate per criterion, so the funnel can attribute each loss to the
# step that caused it rather than to a single lump at the end.
#
# A flag the input does not carry is `1 = 1`: with a pre-filtered input the
# criterion was applied upstream, every remaining row has passed it, and the
# funnel reports it as carried in. `coalesce(flag, 1)` treats a NULL as
# eligible, which is the upstream writer's own contract - its flags are
# non-null CASE results. check_cohort_table() enforces that contract, so the
# coalesce cannot fire on a table this package accepted.
cohort_flag_pred_one <- function(k, cols) {
  fl <- CRITERION_FLAG[[k]]
  if (is.null(fl) || !fl %in% cols) "1 = 1"
  else sprintf("coalesce(c.%s, 1) = 1", fl)
}

# The predicate that admits a patient to a cohort, over S_COHORT's own columns:
# the AND of every predicate the cohort's list names, in list order. These are
# the two maps mod_attrition() accumulates, so the funnel's last step and
# IN_COHORT are the same test.
#
# A criterion in neither map was applied upstream and has nothing to test here.
membership_predicate <- function(cohort)
  and_predicates(unlist(lapply(cohort$criteria, criterion_predicates)))

# What one criterion tests here: its HERE_PRED predicate, its retained-flag
# predicate, both or neither. The one list membership and the funnel both
# build from, so the two cannot name the maps differently.
criterion_predicates <- function(k) unname(c(HERE_PRED[[k]], FLAG_PRED[[k]]))

# Predicates ANDed, each in its own parentheses. The one place a list of
# predicates becomes SQL, for membership and the funnel alike: a predicate may
# carry an OR, and unparenthesised that OR takes everything to its left - the
# cohort filter included - as one arm.
and_predicates <- function(preds) {
  preds <- preds[preds != "1 = 1"]
  if (!length(preds)) "1 = 1" else paste0("(", preds, ")", collapse = " AND ")
}

check_cohort_table <- function(con, cfg) {
  cols <- tryCatch(describe_columns(con, input_cohort_tbl())$COL,
                   error = function(e)
    stop("INPUT ERROR: could not describe INPUT_COHORT_TABLE '",
         cfg$input_cohort_table, "': ", conditionMessage(e), call. = FALSE))
  assign("cols", cols, envir = .input_cols)
  missing <- setdiff(COHORT_TABLE_REQUIRED, cols)
  if (length(missing))
    stop("INPUT ERROR: INPUT_COHORT_TABLE '", cfg$input_cohort_table,
         "' is missing column(s) this package reads: ",
         paste(missing, collapse = ", "),
         ".\nEvery cohort is indexed on this table, so a table carrying only ",
         "patient ids and eligibility flags cannot drive the run. Point ",
         "INPUT_COHORT_TABLE at a materialised cohort with the full schema.",
         call. = FALSE)
  # Column presence is not the contract; the values matter too, and both ways
  # of breaking them are silent. A duplicated PATID multiplies that patient
  # through every join, and a NULL flag passes `coalesce(flag, 1) = 1` and
  # admits a patient the exclusion should have dropped.
  flags <- intersect(unname(CRITERION_FLAG), cols)
  flag_sel <- if (length(flags)) paste0(", ", paste(vapply(flags, function(f)
    sprintf("sum(CASE WHEN %1$s IS NULL OR %1$s NOT IN (0, 1) THEN 1 ELSE 0 END) AS bad_%1$s",
            f), character(1)), collapse = ", ")) else ""
  g <- db_q(con, sprintf(
    "SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients,
            sum(CASE WHEN PATID IS NULL THEN 1 ELSE 0 END) AS n_null_patid%s
     FROM %s", flag_sel, input_cohort_tbl()))
  # A driver that answers the aggregate with nothing usable leaves the value
  # checks unable to say anything. Reads as 0 - the preflight is not the place
  # to fail a run over a driver quirk - and the column checks above still hold.
  nm <- function(x) {
    v <- suppressWarnings(as.numeric(g[[x]]))
    if (!length(v) || is.na(v[1])) 0 else v[1]
  }
  if (nm("n_null_patid") > 0)
    stop("INPUT ERROR: INPUT_COHORT_TABLE '", cfg$input_cohort_table, "' has ",
         nm("n_null_patid"), " row(s) with a NULL PATID. Every cohort is ",
         "indexed by patient, so those rows join to nothing and are counted ",
         "by the funnel anyway.", call. = FALSE)
  if (nm("n_rows") != nm("n_patients"))
    stop("INPUT ERROR: INPUT_COHORT_TABLE '", cfg$input_cohort_table, "' holds ",
         nm("n_rows"), " rows for ", nm("n_patients"), " patients. This package ",
         "reads it as one row per patient: a duplicate multiplies that patient ",
         "through every join, so the cohort counts come out high and nothing ",
         "downstream says so.", call. = FALSE)
  bad <- Filter(function(f) nm(paste0("bad_", f)) > 0, flags)
  if (length(bad))
    stop("INPUT ERROR: INPUT_COHORT_TABLE '", cfg$input_cohort_table,
         "' carries a NULL or non-0/1 value in: ",
         paste(vapply(bad, function(f)
           sprintf("%s (%d row(s))", f, as.integer(nm(paste0("bad_", f)))),
           character(1)), collapse = ", "),
         ".\nThese are exclusion verdicts. A NULL reads as eligible, so a ",
         "patient the exclusion should have dropped enters the cohort ",
         "silently. Write 0 or 1.", call. = FALSE)

  # A wide input is one that deliberately keeps patients failing an exclusion.
  # Asserting it without the flags to filter by would let those patients into
  # every cohort, which is the opposite of what the assertion is for.
  if (isTRUE(cfg$sec2l_input_is_wide)) {
    absent <- setdiff(unname(CRITERION_FLAG), cols)
    if (length(absent))
      stop("INPUT ERROR: SEC2L_INPUT_IS_WIDE=TRUE says '",
           cfg$input_cohort_table, "' retains patients who fail an exclusion, ",
           "but it does not carry the flag(s) needed to apply that exclusion ",
           "per cohort: ", paste(absent, collapse = ", "),
           ".\nWithout them a patient with a prior cancer enters the primary ",
           "1L cohort as readily as the secondary 2L one. Supply a wide ",
           "cohort that retains its eligibility evidence.", call. = FALSE)
  }
  invisible(cols)
}

build_enroll_spans <- function(con, cfg) {
  run_step(con, "enroll_spans", sprintf("
    CREATE OR REPLACE TABLE %s AS
    WITH base AS (
      SELECT cast(PATID as string) AS PATID,
             cast(ELIGEFF as date) AS elig_eff, cast(ELIGEND as date) AS elig_end
      FROM %s WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
    ),
    ordered AS (
      SELECT *, max(elig_end) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS max_end
      FROM base
    ),
    flagged AS (
      SELECT *, CASE WHEN max_end IS NULL THEN 1
                     WHEN elig_eff <= date_add(max_end, %d + 1) THEN 0
                     ELSE 1 END AS new_grp
      FROM ordered
    ),
    grouped AS (
      SELECT *, sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp
      FROM flagged
    )
    SELECT PATID, grp AS SPAN_ID, min(elig_eff) AS COV_START,
           max(elig_end) AS COV_END
    FROM grouped GROUP BY PATID, grp",
    wrk("S_ENROLL_SPANS"), cdm_src("member_enrollment"), as.integer(cfg$gap_days)),
    qc = sprintf("SELECT count(*) AS n_spans, count(DISTINCT PATID) AS n_pat
                  FROM %s", wrk("S_ENROLL_SPANS")))
}

# Claims on and after EACH LINE'S index, for the I5 readings that need one.
#
# Per line, not per patient: counted against the 1L index alone, one claim
# falling between a patient's 1L and 2L would satisfy the after-2L test and the
# after-3L test too. The grain has to be the grain the criterion is asked at.
#
# Bounded above by STUDY_END as well - a claim after the study period is not
# evidence of follow-up within it.
build_fu_claims <- function(con, cfg) {
  run_step(con, "fu_claims", sprintf("
    CREATE OR REPLACE TABLE %1$s AS
    SELECT l.PATID, l.LOT_NUM,
           sum(CASE WHEN d.svc_dt >  l.LOT_START_DT THEN 1 ELSE 0 END) AS N_CLAIMS_AFTER_INDEX,
           sum(CASE WHEN d.svc_dt >= l.LOT_START_DT THEN 1 ELSE 0 END) AS N_CLAIMS_FROM_INDEX
    FROM (SELECT cast(PATID as string) AS PATID, cast(LOT_NUM as int) AS LOT_NUM,
                 LOT_START_DT
          FROM %2$s WHERE LOT_NUM <= %5$d) l
    LEFT JOIN (
      SELECT cast(PATID as string) AS PATID, cast(FST_DT as date) AS svc_dt
      FROM %3$s WHERE FST_DT IS NOT NULL
      UNION ALL
      SELECT cast(PATID as string) AS PATID, cast(FILL_DT as date) AS svc_dt
      FROM %4$s WHERE FILL_DT IS NOT NULL
    ) d ON d.PATID = l.PATID AND d.svc_dt <= date('%6$s')
    GROUP BY l.PATID, l.LOT_NUM",
    wrk("S_FU_CLAIMS"), lot_tbl("LOT_LONG_FINAL"),
    cdm_src("medical"), cdm_src("rx"), as.integer(cfg$max_lot),
    cfg$study_end),
    qc = sprintf("SELECT count(*) AS n_rows FROM %s", wrk("S_FU_CLAIMS")))
}
