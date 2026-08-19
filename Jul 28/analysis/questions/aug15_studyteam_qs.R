#!/usr/bin/env Rscript
# The study team's mid-August asks -> CSVs.
#
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
#     Rscript analysis/questions/aug15_studyteam_qs.R
#
# What this program produces, and what it does not:
#
#   1. A sizing SCREEN for the MAP-splitting rule: MED_ADD boundaries where
#      an agent from the PREVIOUS line's regimen is among the medications that
#      started on the boundary date. Every boundary is classified from the
#      engine's own candidate rule - outside-regimen starts plus released
#      restarts of the line's own drugs - not from the one randomly stored
#      first-add medication. Two classes:
#        AFFECTED            every candidate that day is a previous-line
#                            agent, so under the proposed fold-in the boundary
#                            disappears
#        SAME_DAY_NEW_AGENT  another engine-valid candidate also started that
#                            day, so the boundary would remain
#      ...each under two match bases, EXACT_TOKEN and SUBSTITUTE_FAMILY,
#      because "the drug reappears" does not settle biosimilars.
#      A per-patient review roster sits beside the counts: prior and current
#      regimens, the returning drug and its date, the window end, the gap from
#      the drug's last cover, same-day starters, and the next line.
#      It is a screen of current boundaries, not the line table the proposed
#      rule would build - a folded agent changes the regimen, the run-out and
#      every later window, which needs a rebuild, not arithmetic.
#      The rule itself is NOT changed here. The rebuild exists separately:
#      exploration/lot/run_foldin_cells.R builds the fold-in as its own
#      gated cell pair and differences it against the contract build. Scope
#      differs on purpose: this screen counts PREVIOUS-line returns only,
#      while the cell folds agents of every earlier line - so this count is
#      a lower bound on the cell's population, not its exact size.
#      In the roster, GAP_FROM_PRIOR_EPISODE_END_DAYS is one number per
#      patient and line: the gap from the MOST RECENT prior cover among the
#      returning medications, not one gap per drug.
#
#   2. A pointer to the melphalan comparison. The three-cell package evaluates
#      the original five-branch rule; run it separately. The simplified
#      shorter-course fallback from the newer note has its own two-cell
#      package, exploration/melphalan/run_melp_simple.R - also run separately.
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
  # A study-team answer needs proven lineage. No recorded run means the
  # substitution hash, the attempt recheck and the provenance stamps all have
  # nothing to hold against - refused, unless waived on the record.
  waived <- identical(toupper(trimws(Sys.getenv("AUG15_ALLOW_UNVERIFIED",
                                                unset = ""))), "TRUE")
  if (is.null(bound) && !waived)
    stop("No LOT run is recorded under this prefix, so these answers cannot ",
         "be tied to the build that made the lines. Rebuild LOT, or set ",
         "AUG15_ALLOW_UNVERIFIED=TRUE to size an ungoverned build anyway - ",
         "every row will then carry NA provenance and the run-status file ",
         "will say the lineage was waived.", call. = FALSE)
  if (is.null(bound) && waived)
    log_msg("WARNING: AUG15_ALLOW_UNVERIFIED is set - lineage unproven, ",
            "every output row carries NA provenance.")
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

  # The screen mirrors the engine's own candidate rule, not an approximation
  # of it. On each MED_ADD boundary the pool is every non-steroid episode
  # starting on the add date that the engine would accept as a first-add
  # candidate: an agent outside the line's regimen (exact token, the way the
  # engine joins it), or a regimen agent whose PREVIOUS episode of the same
  # token was flagged discontinued - the released restart. The engine exempts
  # substitute-only regimen entries from that release; the flag is
  # engine-internal, so the release here is slightly wider, which can only
  # move a line OUT of AFFECTED, never into it.
  #
  # Every boundary is classified, not just the ones whose randomly stored
  # first-add medication happens to be the returning drug - the stored pick
  # is one member of the pool and decides nothing here.
  #
  # Two match bases, because "drug B reappears" does not settle biosimilars:
  #   EXACT_TOKEN        the same recorded abbreviation returned
  #   SUBSTITUTE_FAMILY  the drug or any permissible substitute of the same
  #                      original returned
  # The truth the engine built sits between the two; both are reported.
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
    prevx AS (  -- the previous line's regimen, exact tokens
      SELECT PATID, LOT_NUM + 1 AS NEXT_LOT, MED FROM toks
    ),
    prevf AS (  -- the previous line's regimen, canonicalized to originals
      SELECT DISTINCT t.PATID, t.LOT_NUM + 1 AS NEXT_LOT,
             coalesce(sb.o, t.MED) AS CANON
      FROM toks t LEFT JOIN subs sb ON sb.s = t.MED
    ),
    boundaries AS (  -- every MED_ADD boundary, whatever medication is stored
      SELECT PATID, LOT_NUM, ADD_DT, upper(trim(LOT_BASE_1ST_ADD_MED)) AS STORED_MED
      FROM ln
      WHERE LOT_BASE_END_REASON = 'MED_ADD' AND ADD_DT IS NOT NULL
    ),
    restarts AS ( -- each episode, with whether the same token's previous
                  -- episode was flagged discontinued (the engine's release)
      SELECT cast(PATID as string) AS PATID, upper(trim(MAP_MED_TYPE)) AS MED,
             cast(MAP_START_DT as date) AS ST,
             coalesce(lag(MAP_DISCON_FLG) OVER (PARTITION BY PATID, MAP_MED_TYPE
                                                ORDER BY MAP_START_DT), 0) AS PREV_DISCON
      FROM {maps}
    ),
    pool AS (   -- the engine's candidate pool on the boundary date. The stored
                -- ADD_MED_DT is the day BEFORE the episode start (it is the
                -- line-end date), so the start is one day past it.
      SELECT b.PATID, b.LOT_NUM, upper(trim(mp.MAP_MED_TYPE)) AS MED_RAW,
             coalesce(sb.o, upper(trim(mp.MAP_MED_TYPE))) AS MED_CANON
      FROM boundaries b
      INNER JOIN {maps} mp
              ON cast(mp.PATID as string) = b.PATID
             AND cast(mp.MAP_START_DT as date) = date_add(b.ADD_DT, 1)
             AND upper(coalesce(mp.MAP_MED_CLASS, '')) <> 'STEROID'
      LEFT JOIN subs sb ON sb.s = upper(trim(mp.MAP_MED_TYPE))
      LEFT JOIN toks cx ON cx.PATID = b.PATID AND cx.LOT_NUM = b.LOT_NUM
                       AND cx.MED = upper(trim(mp.MAP_MED_TYPE))
      LEFT JOIN restarts mr ON mr.PATID = b.PATID
                           AND mr.MED = upper(trim(mp.MAP_MED_TYPE))
                           AND mr.ST = date_add(b.ADD_DT, 1)
      WHERE cx.MED IS NULL OR coalesce(mr.PREV_DISCON, 0) = 1
    ),
    poolx AS (  -- each pool member, previous-line membership by exact token
      SELECT p.PATID, p.LOT_NUM, p.MED_RAW,
             CASE WHEN px.MED IS NOT NULL THEN 1 ELSE 0 END AS IS_PREV
      FROM pool p
      LEFT JOIN (SELECT DISTINCT PATID, NEXT_LOT, MED FROM prevx) px
             ON px.PATID = p.PATID AND px.NEXT_LOT = p.LOT_NUM
            AND px.MED = p.MED_RAW
    ),
    poolf AS (  -- ...and by substitution family
      SELECT p.PATID, p.LOT_NUM, p.MED_RAW,
             CASE WHEN pf.CANON IS NOT NULL THEN 1 ELSE 0 END AS IS_PREV
      FROM pool p
      LEFT JOIN prevf pf ON pf.PATID = p.PATID AND pf.NEXT_LOT = p.LOT_NUM
                        AND pf.CANON = p.MED_CANON
    ),
    verdict AS ( -- boundaries where a previous-line agent is in the pool:
                 -- AFFECTED when the whole pool is previous-line agents,
                 -- SAME_DAY_NEW_AGENT when anything else started that day
      SELECT 'EXACT_TOKEN' AS MATCH_BASIS, PATID, LOT_NUM,
             CASE WHEN min(IS_PREV) = 1 THEN 'AFFECTED'
                  ELSE 'SAME_DAY_NEW_AGENT' END AS CLASS
      FROM poolx GROUP BY PATID, LOT_NUM HAVING max(IS_PREV) = 1
      UNION ALL
      SELECT 'SUBSTITUTE_FAMILY', PATID, LOT_NUM,
             CASE WHEN min(IS_PREV) = 1 THEN 'AFFECTED'
                  ELSE 'SAME_DAY_NEW_AGENT' END AS CLASS
      FROM poolf GROUP BY PATID, LOT_NUM HAVING max(IS_PREV) = 1
    )
    ")
  affected <- db_q(con, paste0(screen_ctes, "
    SELECT MATCH_BASIS, CLASS, cast(LOT_NUM as string) AS LINE_THAT_ENDED,
           count(*) AS N_LINES, count(DISTINCT PATID) AS N_PATIENTS
    FROM verdict GROUP BY MATCH_BASIS, CLASS, LOT_NUM
    UNION ALL
    SELECT MATCH_BASIS, CLASS, 'ALL', count(*), count(DISTINCT PATID)
    FROM verdict GROUP BY MATCH_BASIS, CLASS
    ORDER BY MATCH_BASIS, CLASS, LINE_THAT_ENDED"))
  # Zero is a result. The CSV always carries every basis-and-class total, so
  # an absent combination reads as 0 rather than as a missing file.
  full <- expand.grid(MATCH_BASIS = c("EXACT_TOKEN", "SUBSTITUTE_FAMILY"),
                      CLASS = c("AFFECTED", "SAME_DAY_NEW_AGENT"),
                      LINE_THAT_ENDED = "ALL", stringsAsFactors = FALSE)
  have_combo <- paste(affected$MATCH_BASIS, affected$CLASS,
                      affected$LINE_THAT_ENDED)
  missing <- full[!(paste(full$MATCH_BASIS, full$CLASS, full$LINE_THAT_ENDED)
                    %in% have_combo), ]
  if (nrow(missing)) {
    missing$N_LINES <- 0L; missing$N_PATIENTS <- 0L
    affected <- rbind(affected, missing)
    affected <- affected[order(affected$MATCH_BASIS, affected$CLASS,
                               affected$LINE_THAT_ENDED), ]
  }

  # The review roster: one row per counted boundary per basis, so each can be
  # judged as the clinical scenario it claims to be. The induction windows
  # shown come from the run's own recorded settings where present.
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
    SELECT v.MATCH_BASIS, v.PATID,
           v.LOT_NUM                                AS LINE_THAT_ENDED,
           v.CLASS,
           pl.LOT_BASE_MEDS                         AS PRIOR_LINE_REGIMEN,
           l.LOT_BASE_MEDS                          AS LINE_REGIMEN,
           b.STORED_MED                             AS STORED_FIRST_ADD_MED,
           rt.MEDS                                  AS RETURNING_PREV_MEDS,
           coalesce(ot.MEDS, '')                    AS OTHER_MEDS_STARTING_SAME_DAY,
           l.LOT_START_DT                           AS LINE_START_DT,
           date_add(l.LOT_START_DT,
                    CASE WHEN l.LOT_START_TYPE = 'CART'
                         THEN {cart} ELSE {indn} END - 1)
                                                    AS INDUCTION_WINDOW_END,
           date_add(l.ADD_DT, 1)                    AS BOUNDARY_MEDS_START_DT,
           gap.GAP_DAYS                             AS GAP_FROM_PRIOR_EPISODE_END_DAYS,
           nx.LOT_START_DT                          AS NEXT_LINE_START_DT,
           nx.LOT_BASE_MEDS                         AS NEXT_LINE_REGIMEN
    FROM verdict v
    INNER JOIN ln l         ON l.PATID  = v.PATID AND l.LOT_NUM  = v.LOT_NUM
    INNER JOIN boundaries b ON b.PATID  = v.PATID AND b.LOT_NUM  = v.LOT_NUM
    LEFT JOIN ln pl         ON pl.PATID = v.PATID AND pl.LOT_NUM = v.LOT_NUM - 1
    LEFT JOIN ln nx         ON nx.PATID = v.PATID AND nx.LOT_NUM = v.LOT_NUM + 1
    LEFT JOIN (  -- the pool members that ARE the previous line's, per basis
      SELECT 'EXACT_TOKEN' AS MATCH_BASIS, PATID, LOT_NUM,
             concat_ws(' ', sort_array(collect_set(MED_RAW))) AS MEDS
      FROM poolx WHERE IS_PREV = 1 GROUP BY PATID, LOT_NUM
      UNION ALL
      SELECT 'SUBSTITUTE_FAMILY', PATID, LOT_NUM,
             concat_ws(' ', sort_array(collect_set(MED_RAW)))
      FROM poolf WHERE IS_PREV = 1 GROUP BY PATID, LOT_NUM
    ) rt ON rt.MATCH_BASIS = v.MATCH_BASIS AND rt.PATID = v.PATID
        AND rt.LOT_NUM = v.LOT_NUM
    LEFT JOIN (  -- ...and the ones that are not
      SELECT 'EXACT_TOKEN' AS MATCH_BASIS, PATID, LOT_NUM,
             concat_ws(' ', sort_array(collect_set(MED_RAW))) AS MEDS
      FROM poolx WHERE IS_PREV = 0 GROUP BY PATID, LOT_NUM
      UNION ALL
      SELECT 'SUBSTITUTE_FAMILY', PATID, LOT_NUM,
             concat_ws(' ', sort_array(collect_set(MED_RAW)))
      FROM poolf WHERE IS_PREV = 0 GROUP BY PATID, LOT_NUM
    ) ot ON ot.MATCH_BASIS = v.MATCH_BASIS AND ot.PATID = v.PATID
        AND ot.LOT_NUM = v.LOT_NUM
    LEFT JOIN (  -- the returning family's latest cover end before the return
      SELECT b2.PATID, b2.LOT_NUM,
             datediff(date_add(b2.ADD_DT, 1), max(cast(mp.MAP_END_DT as date))) AS GAP_DAYS
      FROM boundaries b2
      INNER JOIN pool p2 ON p2.PATID = b2.PATID AND p2.LOT_NUM = b2.LOT_NUM
      INNER JOIN {maps} mp
              ON cast(mp.PATID as string) = b2.PATID
             AND cast(mp.MAP_END_DT as date) < date_add(b2.ADD_DT, 1)
      LEFT JOIN subs sb ON sb.s = upper(trim(mp.MAP_MED_TYPE))
      WHERE coalesce(sb.o, upper(trim(mp.MAP_MED_TYPE))) = p2.MED_CANON
      GROUP BY b2.PATID, b2.LOT_NUM, b2.ADD_DT
    ) gap ON gap.PATID = v.PATID AND gap.LOT_NUM = v.LOT_NUM
    ORDER BY v.MATCH_BASIS, v.CLASS, v.PATID, v.LOT_NUM")))
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
      SELECT STATE, ATTEMPT, SOURCE_LOT_RUN_ID, SOURCE_LOT_STAMP
      FROM {qs_cohort_side_tbl('NDMM_SUBSEQ_BUILD_STATUS')}
      ORDER BY UPDATED_AT DESC LIMIT 1"))
    if (nrow(st) == 1L &&
        identical(tolower(trimws(st$STATE[1])), "complete") &&
        identical(trimws(st$SOURCE_LOT_RUN_ID[1]), run_id) &&
        identical(trimws(st$SOURCE_LOT_STAMP[1]), run_stamp)) {
      a <- db_q(con, glue("
             SELECT COHORT, N_FROM, N_REACHED_LOT, N_CE_PRE, N_FINAL,
                    CE_PRE_DAYS, CE_FU_DAYS, SUBSEQ_ATTEMPT
             FROM {qs_cohort_side_tbl('NDMM_SUBSEQUENT_ATTRITION')}
             ORDER BY COHORT"))
      # The lineage match is not enough on its own: the attrition rows must be
      # the completed attempt's, built under the contract windows - a retry or
      # a window sensitivity carries the same run ids.
      if (!nrow(a) ||
          !all(trimws(as.character(a$SUBSEQ_ATTEMPT)) ==
               trimws(as.character(st$ATTEMPT[1]))) ||
          !all(as.integer(a$CE_PRE_DAYS) == 365L) ||
          !all(as.integer(a$CE_FU_DAYS)  == 90L)) {
        list(df = NULL,
             note = paste0("not written - the attrition rows are not the ",
                           "completed attempt's contract-window build (365/90); ",
                           "re-run ndmm/build_subsequent_cohorts.R"))
      } else {
        list(df = a,
             note = "written - the chained build matches this LOT attempt")
      }
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
      "built as its own cell - run the simplified package",
      "written"),
    WHERE = c(
      paste0("aug15_qs_map_splitting_affected_", stamp, ".csv, with the ",
             "per-patient review roster beside it; the rule itself is built ",
             "as a cell pair by exploration/lot/run_foldin_cells.R"),
      paste0("exploration/melphalan: AUG1_EXECUTE=TRUE run_aug1_melp.R (the ",
             "reference and two cells of the original five-branch rule), then ",
             "read_melp_asks.R and read_melp_decisions.R"),
      paste0("exploration/melphalan: MELP_SIMPLE_EXECUTE=TRUE ",
             "run_melp_simple.R - two builds under melp_simple_ prefixes; ",
             "the 28-vs-30-day cap is still an open question"),
      paste0("aug15_qs_discontinued_then_12mo_ce_", stamp, ".csv; chained ",
             "attrition ", attr_note)),
    stringsAsFactors = FALSE)

  # The tables must still be the attempts every number above was read from -
  # the LOT run, and the cohort whose enrollment spans the funnel just read.
  # The cohort check stops on a PROVEN mismatch by itself; here an UNPROVABLE
  # attempt is refused too, under the same waiver as the LOT lineage - a
  # study-team answer whose enrollment spans cannot be tied to the cohort the
  # lines were built over is the same problem as one with no recorded LOT run.
  qs_require_same_attempt(con, bound, "mid-August answers")
  cohort_proven <- isTRUE(qs_check_cohort_attempt(con, cfg))
  if (!cohort_proven && !waived)
    stop("The cohort attempt behind these answers could not be verified (see ",
         "the warning above), so the enrollment spans the funnel read cannot ",
         "be tied to the cohort the lines were built over. Rebuild so the ",
         "attempt is recorded, or set AUG15_ALLOW_UNVERIFIED=TRUE to publish ",
         "anyway - the run-status file will then say the lineage was waived.",
         call. = FALSE)
  if (!cohort_proven && waived)
    log_msg("WARNING: cohort attempt unproven - published under the ",
            "AUG15_ALLOW_UNVERIFIED waiver.")

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
              if (waived) "  LINEAGE WAIVED (AUG15_ALLOW_UNVERIFIED=TRUE)",
              if (!cohort_proven) "  COHORT ATTEMPT UNPROVEN (published under the waiver)",
              paste0("  LOT run:    ", run_id, " / attempt ", run_stamp),
              paste0("  population: ", pop$mode, " (", lines, ")"),
              paste0("  subs md5:   ", subs_md5),
              paste0("  chained 2L/3L attrition: ", attr_note),
              "  files:", paste0("    ", written),
              paste0("  The MAP count is a sizing screen. The primary study ",
                     "contract is unchanged;"),
              paste0("  the fold-in is built separately as a gated cell pair ",
                     "(exploration/lot/run_foldin_cells.R)."),
              paste0("  The simplified MELP fallback is built as its own ",
                     "package (exploration/melphalan/run_melp_simple.R)."))
  writeLines(status, file.path(out_dir, paste0("aug15_qs_run_status_", stamp, ".txt")))

  log_msg(SEP)
  log_msg("Mid-August sizing outputs written. The MELP comparison, the ",
          "simplified fallback and the fold-in cell pair each run separately; ",
          "the study contract is unchanged by all of them.")
  log_msg(SEP)
}

if (!interactive()) main()
