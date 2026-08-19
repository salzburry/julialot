#!/usr/bin/env Rscript
# The study team's mid-August asks -> CSVs.
#
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
#     Rscript analysis/questions/aug15_studyteam_qs.R
#
# What this program produces, and what it does not:
#
#   1. A sizing SCREEN for the MAP-splitting rule: lines that ended MED_ADD
#      because an agent from the PREVIOUS line's regimen came back after the
#      line's induction window. Two classes, because the stored first-add
#      medication is one of possibly several same-day candidates:
#        AFFECTED            every same-day candidate is a previous-line agent,
#                            so under the proposed fold-in the boundary
#                            disappears
#        SAME_DAY_NEW_AGENT  a genuinely new agent started the same day, so
#                            the boundary would remain even under the fold-in
#      A per-patient review roster sits beside the counts: prior and current
#      regimens, the returning drug and its date, the window end, the gap from
#      the drug's last cover, same-day starters, and the next line.
#      It is a screen of current boundaries, not the line table the proposed
#      rule would build - a folded agent changes the regimen, the run-out and
#      every later window, which needs a rebuild, not arithmetic.
#      The rule itself is NOT changed here.
#
#   2. A pointer to the melphalan comparison. The three-cell package evaluates
#      the original five-branch rule; run it separately. The simplified
#      shorter-course fallback from the newer note is NOT implemented and is
#      not evaluated by anything yet.
#
#   3. Patients whose prior line ended with the recorded reason
#      DISCONTINUATION and who then hold the 12-month continuous-enrollment
#      baseline before the next line's start, for 2L and 3L. Fixed 365 days
#      over gap-merged spans - the same window the 2L/3L cohort build applies.
#      Standalone over the published lines; the chained study cohort's own
#      funnel is exported beside it when its build matches this LOT run.
#
# Reads only. Writes CSVs and a run-status file to OUTPUT_DIR.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in the path as ~+~, so a folder with one in its
  # name resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "_setup.R"))
cfg <- qs_setup(.script_dir)

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  bound <- qs_check_run_binding(con)
  if (!is.list(bound)) bound <- NULL
  run_id    <- if (is.null(bound)) NA_character_ else bound$run
  run_stamp <- if (is.null(bound)) NA_character_ else bound$stamp

  stamp   <- format(Sys.time(), "%Y%m%d_%H%M%S")
  out_dir <- cfg$output_dir
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  pop   <- qs_population()
  lines <- pop$table
  maps  <- qs_tbl("MAP_STACKED")
  log_msg(SEP)
  log_msg("Mid-August asks [", pop$mode, " population] -> CSVs")
  log_msg(SEP)

  # Every row of every CSV names the run it was read from, so a moved file
  # still says what it describes.
  prov <- function(df) {
    if (is.null(df) || !nrow(df)) return(df)
    df$SOURCE_LOT_RUN_ID <- run_id
    df$SOURCE_LOT_STAMP  <- run_stamp
    df$POPULATION        <- pop$mode
    df
  }

  # ---- 1. MAP-splitting screen ---------------------------------------------
  # The substitution pairs, and proof they are the version the run was built
  # with: the run records one MD5 per code-list file.
  log_msg("1. MAP-splitting screen: MED_ADD boundaries made by a returning agent")
  subs_src <- load_codelist_csv("permissible_subs.csv",
                                c("original_med", "substitute_med"))
  subs_md5 <- tryCatch(getOption("lot_codelist_md5")[["permissible_subs.csv"]]$md5,
                       error = function(e) NULL)
  if (is.null(subs_md5)) subs_md5 <- NA_character_
  if (!is.na(run_id)) {
    rec <- db_q(con, glue("
      SELECT MD5 FROM {qs_tbl('LOT_CODELIST_METADATA')}
      WHERE RUN_ID = '{run_id}' AND CODELIST_FILE = 'permissible_subs.csv'"))
    if (nrow(rec) != 1L || !identical(trimws(as.character(rec[[1]][1])), subs_md5))
      stop("permissible_subs.csv on disk (md5 ", subs_md5, ") is not the ",
           "version LOT run ", run_id, " recorded",
           if (nrow(rec) == 1L) paste0(" (", rec[[1]][1], ")") else "",
           ". The returning-agent match depends on these pairs, so the file ",
           "the run was built with must be used.", call. = FALSE)
  } else {
    log_msg("  WARNING: no run recorded, so the substitution file cannot be ",
            "held against the run that built the lines.")
  }

  # Substitutes are canonicalized to their original, so DARA vs its
  # biosimilar - and two different biosimilars of one original - all read as
  # the same drug, the way the engine's regimen does.
  screen_ctes <- glue("
    WITH ln AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_NUM as int) AS LOT_NUM,
             LOT_BASE_MEDS, LOT_BASE_1ST_ADD_MED,
             cast(LOT_BASE_1ST_ADD_MED_DT as date) AS ADD_DT,
             cast(LOT_START_DT as date) AS LOT_START_DT, LOT_START_TYPE,
             LOT_BASE_END_REASON
      FROM {lines}
    ),
    subs AS (
      SELECT DISTINCT upper(trim(original_med))   AS o,
                      upper(trim(substitute_med)) AS s
      FROM {subs_src}
    ),
    toks AS (   -- every regimen token, one row per line per agent
      SELECT l.PATID, l.LOT_NUM, upper(trim(m.MED)) AS MED
      FROM ln l LATERAL VIEW explode(split(trim(l.LOT_BASE_MEDS), ' ')) m AS MED
      WHERE trim(coalesce(l.LOT_BASE_MEDS, '')) <> ''
    ),
    prev AS (  -- the previous line's regimen, canonicalized
      SELECT t.PATID, t.LOT_NUM + 1 AS NEXT_LOT,
             coalesce(sb.o, t.MED) AS PREV_CANON
      FROM toks t LEFT JOIN subs sb ON sb.s = t.MED
    ),
    cur AS (   -- the ended line's own regimen, canonicalized
      SELECT t.PATID, t.LOT_NUM,
             coalesce(sb.o, t.MED) AS CUR_CANON
      FROM toks t LEFT JOIN subs sb ON sb.s = t.MED
    ),
    fired AS ( -- MED_ADD boundaries whose STORED add med is a previous-line agent
      SELECT DISTINCT f.PATID, f.LOT_NUM, f.ADD_DT, f.ADD_CANON
      FROM (SELECT l.*, coalesce(sb.o, upper(trim(l.LOT_BASE_1ST_ADD_MED))) AS ADD_CANON
            FROM ln l
            LEFT JOIN subs sb ON sb.s = upper(trim(l.LOT_BASE_1ST_ADD_MED))
            WHERE l.LOT_BASE_END_REASON = 'MED_ADD'
              AND trim(coalesce(l.LOT_BASE_1ST_ADD_MED, '')) <> '') f
      INNER JOIN prev p ON p.PATID = f.PATID AND p.NEXT_LOT = f.LOT_NUM
                       AND p.PREV_CANON = f.ADD_CANON
    ),
    cand AS (  -- every non-steroid episode starting on the add date that is
               -- outside the line's regimen: the engine's same-day pool, of
               -- which the stored add med is one random pick. The stored
               -- ADD_MED_DT is the day BEFORE the episode start (it is the
               -- line-end date), so the start is one day past it.
      SELECT f.PATID, f.LOT_NUM, upper(trim(mp.MAP_MED_TYPE)) AS MED_RAW,
             coalesce(sb.o, upper(trim(mp.MAP_MED_TYPE))) AS CAND_CANON
      FROM fired f
      INNER JOIN {maps} mp
              ON cast(mp.PATID as string) = f.PATID
             AND cast(mp.MAP_START_DT as date) = date_add(f.ADD_DT, 1)
             AND upper(coalesce(mp.MAP_MED_CLASS, '')) <> 'STEROID'
      LEFT JOIN subs sb ON sb.s = upper(trim(mp.MAP_MED_TYPE))
    ),
    outside AS ( -- ...minus the line's own (canonical) regimen
      SELECT c.PATID, c.LOT_NUM, c.MED_RAW, c.CAND_CANON
      FROM cand c
      LEFT JOIN cur x ON x.PATID = c.PATID AND x.LOT_NUM = c.LOT_NUM
                     AND x.CUR_CANON = c.CAND_CANON
      WHERE x.CUR_CANON IS NULL
    ),
    verdict AS (
      SELECT f.PATID, f.LOT_NUM,
             CASE WHEN EXISTS (
               SELECT 1 FROM outside o
               LEFT JOIN prev p ON p.PATID = o.PATID AND p.NEXT_LOT = o.LOT_NUM
                               AND p.PREV_CANON = o.CAND_CANON
               WHERE o.PATID = f.PATID AND o.LOT_NUM = f.LOT_NUM
                 AND p.PREV_CANON IS NULL)
             THEN 'SAME_DAY_NEW_AGENT' ELSE 'AFFECTED' END AS CLASS
      FROM fired f
    )
    ")
  affected <- db_q(con, paste0(screen_ctes, "
    SELECT CLASS, cast(LOT_NUM as string) AS LINE_THAT_ENDED,
           count(*) AS N_LINES, count(DISTINCT PATID) AS N_PATIENTS
    FROM verdict GROUP BY CLASS, LOT_NUM
    UNION ALL
    SELECT CLASS, 'ALL', count(*), count(DISTINCT PATID)
    FROM verdict GROUP BY CLASS
    ORDER BY CLASS, LINE_THAT_ENDED"))
  # The review roster: the same population, one row per boundary, so each
  # counted patient can be judged as the clinical scenario it claims to be.
  # The induction windows shown come from the run's own recorded settings
  # where present, this session's config otherwise.
  meta_cs <- tryCatch(db_q(con, glue("
    SELECT CONTRACT_SETTINGS FROM {qs_tbl('LOT_RUN_METADATA')}
    ORDER BY RUN_TIMESTAMP DESC LIMIT 1")), error = function(e) NULL)
  rec_setting <- function(key, fallback) {
    v <- if (!is.null(meta_cs) && nrow(meta_cs)) as.character(meta_cs[[1]][1]) else NA
    if (is.na(v)) return(as.integer(fallback))
    hit <- regmatches(v, regexpr(paste0("(^|\\|)", key, "=[^|]*"), v))
    if (!length(hit)) return(as.integer(fallback))
    n <- suppressWarnings(as.integer(sub(paste0("^\\|?", key, "="), "", hit)))
    if (is.na(n)) as.integer(fallback) else n
  }
  indn <- rec_setting("lot_n_induction_window_days", cfg$lot_n_induction_window_days)
  cart <- rec_setting("cart_consolidation_days",     cfg$cart_consolidation_days)
  roster <- db_q(con, paste0(screen_ctes, glue("
    SELECT v.PATID,
           v.LOT_NUM                                AS LINE_THAT_ENDED,
           v.CLASS,
           pl.LOT_BASE_MEDS                         AS PRIOR_LINE_REGIMEN,
           l.LOT_BASE_MEDS                          AS LINE_REGIMEN,
           upper(trim(l.LOT_BASE_1ST_ADD_MED))      AS RETURNING_MED,
           l.LOT_START_DT                           AS LINE_START_DT,
           date_add(l.LOT_START_DT,
                    CASE WHEN l.LOT_START_TYPE = 'CART'
                         THEN {cart} ELSE {indn} END - 1)
                                                    AS INDUCTION_WINDOW_END,
           date_add(l.ADD_DT, 1)                    AS RETURNING_MED_START_DT,
           gap.GAP_DAYS                             AS GAP_FROM_PRIOR_EPISODE_END_DAYS,
           coalesce(oth.OTHERS, '')                 AS OTHER_MEDS_STARTING_SAME_DAY,
           nx.LOT_START_DT                          AS NEXT_LINE_START_DT,
           nx.LOT_BASE_MEDS                         AS NEXT_LINE_REGIMEN
    FROM verdict v
    INNER JOIN ln l  ON l.PATID  = v.PATID AND l.LOT_NUM  = v.LOT_NUM
    LEFT JOIN ln pl  ON pl.PATID = v.PATID AND pl.LOT_NUM = v.LOT_NUM - 1
    LEFT JOIN ln nx  ON nx.PATID = v.PATID AND nx.LOT_NUM = v.LOT_NUM + 1
    LEFT JOIN (  -- the returning drug family's latest cover end before the return
      SELECT f.PATID, f.LOT_NUM,
             datediff(date_add(f.ADD_DT, 1), max(cast(mp.MAP_END_DT as date))) AS GAP_DAYS
      FROM fired f
      INNER JOIN {maps} mp
              ON cast(mp.PATID as string) = f.PATID
             AND cast(mp.MAP_END_DT as date) < date_add(f.ADD_DT, 1)
      LEFT JOIN subs sb ON sb.s = upper(trim(mp.MAP_MED_TYPE))
      WHERE coalesce(sb.o, upper(trim(mp.MAP_MED_TYPE))) = f.ADD_CANON
      GROUP BY f.PATID, f.LOT_NUM, f.ADD_DT
    ) gap ON gap.PATID = v.PATID AND gap.LOT_NUM = v.LOT_NUM
    LEFT JOIN (  -- every other outside-regimen agent starting the same day
      SELECT o.PATID, o.LOT_NUM,
             concat_ws(' ', sort_array(collect_set(o.MED_RAW))) AS OTHERS
      FROM outside o
      INNER JOIN fired f2 ON f2.PATID = o.PATID AND f2.LOT_NUM = o.LOT_NUM
      WHERE o.CAND_CANON <> f2.ADD_CANON
      GROUP BY o.PATID, o.LOT_NUM
    ) oth ON oth.PATID = v.PATID AND oth.LOT_NUM = v.LOT_NUM
    ORDER BY v.CLASS, v.PATID, v.LOT_NUM")))
  if (!is.null(roster) && nrow(roster)) roster$SUBS_MD5 <- subs_md5

  if (!is.null(affected) && nrow(affected)) {
    affected$WHAT_THE_CLASS_MEANS <- ifelse(
      affected$CLASS == "AFFECTED",
      "every same-day candidate is a previous-line agent - the fold-in would remove this boundary",
      "a new agent started the same day - the boundary would remain even under the fold-in")
    affected$SUBS_MD5 <- subs_md5
  }

  # ---- 3. Discontinued the prior line, then the 12-month CE baseline -------
  log_msg("3. Discontinued the prior line, then the 12mo CE baseline")
  spans <- qs_cohort_side_tbl("NDMM_ENROLL_SPANS")
  funnel <- do.call(rbind, lapply(c(2L, 3L), function(n) {
    d <- db_q(con, glue("
      WITH ln AS (
        SELECT cast(PATID as string) AS PATID, cast(LOT_NUM as int) AS LOT_NUM,
               cast(LOT_START_DT as date) AS LOT_START_DT, LOT_BASE_END_REASON
        FROM {lines}
      ),
      disc AS (
        SELECT PATID FROM ln
        WHERE LOT_NUM = {n - 1} AND LOT_BASE_END_REASON = 'DISCONTINUATION'
      ),
      nxt AS (
        SELECT l.PATID, l.LOT_START_DT
        FROM ln l INNER JOIN disc d ON d.PATID = l.PATID
        WHERE l.LOT_NUM = {n}
      ),
      ce AS (
        SELECT DISTINCT x.PATID
        FROM nxt x
        INNER JOIN {spans} s
                ON cast(s.PATID as string) = x.PATID
               AND cast(s.cov_start as date) <= date_sub(x.LOT_START_DT, 365)
               AND cast(s.cov_end as date)   >= date_sub(x.LOT_START_DT, 1)
      )
      SELECT (SELECT count(*) FROM disc) AS N_DISCONTINUED_PRIOR,
             (SELECT count(*) FROM nxt)  AS N_ALSO_HAS_NEXT_LINE,
             (SELECT count(*) FROM ce)   AS N_ALSO_12MO_CE_BEFORE_IT"))
    data.frame(COHORT = paste0(n, "L"),
               PRIOR_LINE_DISCONTINUED = paste0(n - 1, "L"),
               N_DISCONTINUED_PRIOR    = d$N_DISCONTINUED_PRIOR[1],
               N_ALSO_HAS_NEXT_LINE    = d$N_ALSO_HAS_NEXT_LINE[1],
               N_ALSO_12MO_CE_BEFORE_IT = d$N_ALSO_12MO_CE_BEFORE_IT[1],
               stringsAsFactors = FALSE)
  }))
  funnel$HOW_TO_READ <- paste0(
    "discontinued = the line's recorded end reason; the baseline is one ",
    "gap-merged span covering [next-line start - 365, start - 1] (a fixed ",
    "365 days); the discontinuation date need not precede the baseline's ",
    "start; this row is standalone over the published lines, not the chained ",
    "study cohort - the attrition CSV beside it, when written, carries the ",
    "chained build")

  # The chained build's own funnel, only when it was built from THIS LOT run.
  # An older attrition beside a fresh count would read as the same vintage.
  attr_read <- tryCatch({
    st <- db_q(con, glue("
      SELECT STATE, SOURCE_LOT_RUN_ID, SOURCE_LOT_STAMP
      FROM {qs_cohort_side_tbl('NDMM_SUBSEQ_BUILD_STATUS')}
      ORDER BY UPDATED_AT DESC LIMIT 1"))
    if (nrow(st) == 1L &&
        identical(tolower(trimws(st$STATE[1])), "complete") &&
        identical(trimws(st$SOURCE_LOT_RUN_ID[1]), run_id) &&
        identical(trimws(st$SOURCE_LOT_STAMP[1]), run_stamp)) {
      list(df = db_q(con, glue("
             SELECT COHORT, N_FROM, N_REACHED_LOT, N_CE_PRE, N_FINAL,
                    CE_PRE_DAYS, CE_FU_DAYS
             FROM {qs_cohort_side_tbl('NDMM_SUBSEQUENT_ATTRITION')}
             ORDER BY COHORT")),
           note = "written - the chained build matches this LOT attempt")
    } else {
      list(df = NULL,
           note = paste0("not written - the subsequent-cohort build on disk ",
                         "is not this LOT attempt's; re-run ",
                         "ndmm/build_subsequent_cohorts.R"))
    }
  }, error = function(e)
    list(df = NULL, note = "not written - no subsequent-cohort build readable"))
  attr_df   <- attr_read$df
  attr_note <- attr_read$note
  log_msg("  chained 2L/3L attrition: ", attr_note)

  # ---- 2. The melphalan comparison, honestly stated ------------------------
  summary <- data.frame(
    ASK = c(
      "1. Patients affected by the MAP-splitting rule",
      "2. How the MELP rules are working",
      "2b. The simplified shorter-course MELP fallback",
      "3. Discontinue the prior line, then the 12mo CE baseline"),
    STATUS = c(
      "screen written - a sizing of current boundaries, not the rebuilt line table",
      "not produced here - run the melphalan package",
      "NOT IMPLEMENTED anywhere - no cell evaluates it yet",
      "written"),
    WHERE = c(
      paste0("aug15_qs_map_splitting_affected_", stamp, ".csv, with the ",
             "per-patient review roster beside it"),
      paste0("exploration/melphalan: AUG1_EXECUTE=TRUE run_aug1_melp.R (the ",
             "reference and two cells of the original five-branch rule), then ",
             "read_melp_asks.R and read_melp_decisions.R"),
      "needs a decision to build it as its own cell",
      paste0("aug15_qs_discontinued_then_12mo_ce_", stamp, ".csv; chained ",
             "attrition ", attr_note)),
    stringsAsFactors = FALSE)

  # The tables must still be the attempt every number above was read from.
  qs_require_same_attempt(con, bound, "mid-August answers")

  write_out <- function(df, tag) {
    if (is.null(df) || nrow(df) == 0) { log_msg("  (", tag, ": no rows)"); return(invisible(NULL)) }
    f <- file.path(out_dir, paste0("aug15_qs_", tag, "_", stamp, ".csv"))
    write.csv(df, f, row.names = FALSE)
    log_msg("  wrote ", tag, " -> ", f, " (", nrow(df), " rows)")
    basename(f)
  }
  written <- c(write_out(prov(affected), "map_splitting_affected"),
               write_out(prov(roster),   "map_splitting_review_roster"),
               write_out(prov(funnel),   "discontinued_then_12mo_ce"),
               if (!is.null(attr_df)) write_out(prov(attr_df), "subsequent_cohort_attrition"),
               write_out(prov(summary),  "summary"))

  status <- c(paste0("aug15_studyteam_qs run ", stamp),
              paste0("  LOT run:    ", run_id, " / attempt ", run_stamp),
              paste0("  population: ", pop$mode, " (", lines, ")"),
              paste0("  subs md5:   ", subs_md5),
              paste0("  chained 2L/3L attrition: ", attr_note),
              "  files:", paste0("    ", written),
              "  The MAP count is a sizing screen; the rule is unchanged.",
              "  The simplified MELP fallback is not implemented anywhere.")
  writeLines(status, file.path(out_dir, paste0("aug15_qs_run_status_", stamp, ".txt")))

  log_msg(SEP)
  log_msg("Mid-August sizing outputs written. The MELP comparison runs ",
          "separately, and the simplified MELP fallback is not implemented.")
  log_msg(SEP)
}

if (!interactive()) main()
