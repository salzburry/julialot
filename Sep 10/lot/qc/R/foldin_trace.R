# The fold-in trace, as functions.
#
# The study team asked to see the fold-in rule (LOT_RULES.md 4.8) on real
# patients: their raw MAP episodes beside the final lines, so a reader can
# check that a drug which came back after one other agent opened a line was
# put where the rule says. Kept apart from the runner (trace_foldin.R) so
# every piece can run without a connection.
#
# The engine does not persist a fold flag - foldin_episodes is a CTE inside the
# statement that builds each line - so a fold is recognised by its signature in
# the published tables, which is the route check C1 accepts (R/checks.R):
#
#   (a) the drug is in line n's LOT_BASE_MEDS, n >= 2, and line n-1's
#       LOT_BASE_MEDS carried it - a permissible substitute and the drug it
#       replaces being one agent in both directions (4.4);
#   (b) it has no episode starting inside line n's induction window,
#       [LOT_START_DT, ELIGIBLE_END] as qc_window_sql() computes it;
#   (c) it has an episode starting inside the line, on or after LOT_START_DT
#       and on or before LOT_BASE_END_DT.
#
# A regimen is otherwise built only from episodes starting inside the window,
# so nothing but a fold produces (a)+(b)+(c). Two shapes are deliberately not
# reported: a previous-line drug returning inside the window, which is an
# ordinary induction-window regimen drug; and a drug from two lines back,
# which 4.8 puts out of scope.
#
# Patient ids are not masked by default here, unlike every other report in this
# folder: the trace exists so a patient can be looked up. The runner masks on
# request, in R, after the reads.

`%||%` <- function(a, b) if (is.null(a)) b else a

# The R twin of MASK_PATID in R/checks.R: '...' and the last six characters,
# lower case. Two copies of a rule is how the two stop agreeing, but this one
# is R and that one is SQL, so the suite runs the SQL one through DuckDB on
# the same ids and holds this one to its answer.
mask_patid_r <- function(x) {
  x <- as.character(x)
  out <- paste0("...", tolower(substring(x, pmax(nchar(x) - 5L, 1L))))
  out[is.na(x)] <- NA_character_
  out
}

# A patient list as a SQL IN list. Ids are alphanumeric, so anything else is
# refused rather than escaped: doubling a quote is not how Spark escapes.
# Validated here and again in every query that takes ids, so a caller cannot
# get past it by building the list itself.
foldin_trace_check_patids <- function(patids) {
  patids <- unique(trimws(as.character(patids)))
  patids <- patids[!is.na(patids) & nzchar(patids)]
  if (!length(patids)) stop("No patient ids to trace.", call. = FALSE)
  bad <- patids[!grepl("^[A-Za-z0-9_-]+$", patids)]
  if (length(bad))
    stop("Patient id(s) refused - only letters, digits, '_' and '-' are ",
         "accepted, and these carry something else: ",
         paste(utils::head(bad, 3), collapse = ", "), call. = FALSE)
  patids
}

foldin_trace_in_list <- function(patids)
  paste0("(", paste0("'", foldin_trace_check_patids(patids), "'", collapse = ", "), ")")

# qc_window_sql() lives in R/checks.R and is not copied here: two copies of a
# window is how C1 and this trace stop describing the same rule.
.need_checks <- function() {
  if (!exists("qc_window_sql", mode = "function"))
    stop("R/checks.R is not sourced. The trace reads the induction window ",
         "from qc_window_sql() there rather than carrying a copy.", call. = FALSE)
}

# The alias CTEs, in C1's shape (R/checks.R, check C1). Every name a regimen
# drug could wear in the previous line's regimen: itself, the drug it stands
# in for, and the substitutes that stand in for it. Both directions, because
# 4.4 makes the pair one agent whichever half a line happens to report.
# prev_carried also keeps the previous line's regimen string, because the
# narrative quotes it. Written here rather than exported from checks.R so the
# QC catalogue stays frozen; a change to C1's shape belongs here too.
#
# One hop only: a substitute reaches the drug it replaces and a drug reaches
# its substitutes, never a sibling substitute of the same drug. That matches
# the engine's fold set (prior_lines_regimen_ctes in engine/R/prior_regimen.R)
# only because 01_codelists.R refuses a star - one original with several
# substitutes - under subs_star. If that check is ever
# waived, both this and C1's prev_carried have to collapse to the agent on
# both sides, coalesce(ps.original_med, MED_ABBR), instead of aliasing.
.foldin_alias_ctes <- function(t) paste0("
    w_alias AS (
      SELECT PATID, LOT_NUM, MED_ABBR, MED_ABBR AS ALIAS FROM reg
      UNION ALL
      SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, s.original_med
      FROM reg w INNER JOIN ", t$subs, " s ON s.substitute_med = w.MED_ABBR
      UNION ALL
      SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, s.substitute_med
      FROM reg w INNER JOIN ", t$subs, " s ON s.original_med = w.MED_ABBR
    ),
    prev_carried AS (
      SELECT DISTINCT a.PATID, a.LOT_NUM, a.MED_ABBR,
             pl.LOT_BASE_MEDS AS PREV_BASE_MEDS
      FROM w_alias a
      INNER JOIN ", t$final, " pl
        ON cast(pl.PATID as string) = a.PATID AND pl.LOT_NUM = a.LOT_NUM - 1
      WHERE array_contains(split(coalesce(pl.LOT_BASE_MEDS, ''), ' '), a.ALIAS)
    )")

# ---- The candidate query -----------------------------------------------------
# One row per (PATID, LOT_NUM, MED_ABBR) that carries the fold's signature.
# RETURN_DT is the first episode of the drug inside the line and after the
# window, which is the dose the rule folded. Reads only the published lines,
# the episodes, the allogeneic and CAR-T dates (for the window's transplant
# cutoff) and the substitute pairs. Masks nothing.
#
# LOT_START_TYPE comes out with the row because the signature on a line a
# transplant or CAR-T opened is not the rule's doing: 4.8 refuses a fold across
# a procedure that opened a line, and the engine's foldin_tx_opened counts the
# line's own start (engine/R/foldin_rule.R, this_tx). Such a row is a build
# defect that C1 would accept, so the narrative and the summary say so rather
# than read it as 4.8.
foldin_trace_sql <- function(t, p) {
  .need_checks()
  paste0("
    WITH ", qc_window_sql(t, p), ",", .foldin_alias_ctes(t), "
    SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, w.LOT_START_DT, w.LOT_START_TYPE,
           w.ELIGIBLE_END, w.LOT_BASE_END_DT, pc.PREV_BASE_MEDS,
           min(ms.MAP_START_DT) AS RETURN_DT
    FROM reg w
    -- (a) the previous line carried the drug, under any of its names
    INNER JOIN prev_carried pc
      ON pc.PATID = w.PATID AND pc.LOT_NUM = w.LOT_NUM AND pc.MED_ABBR = w.MED_ABBR
    -- (c) an episode inside the line, and past the window. Bounded by the
    -- line's end: a dose after LOT_BASE_END_DT could not have reached the
    -- regimen, so it is not the dose that did.
    INNER JOIN ", t$map, " ms
      ON cast(ms.PATID as string) = w.PATID
     AND ms.MAP_MED_TYPE = w.MED_ABBR
     AND ms.MAP_START_DT >= w.LOT_START_DT
     AND ms.MAP_START_DT >  w.ELIGIBLE_END
     AND ms.MAP_START_DT <= w.LOT_BASE_END_DT
    WHERE w.LOT_NUM >= 2
      -- (b) and nothing of it inside the window, or the drug is an ordinary
      -- regimen drug that happened to be in the previous line too.
      AND NOT EXISTS (
        SELECT 1 FROM ", t$map, " ms2
        WHERE cast(ms2.PATID as string) = w.PATID
          AND ms2.MAP_MED_TYPE = w.MED_ABBR
          AND ms2.MAP_START_DT >= w.LOT_START_DT
          AND ms2.MAP_START_DT <= w.ELIGIBLE_END)
    GROUP BY w.PATID, w.LOT_NUM, w.MED_ABBR, w.LOT_START_DT, w.LOT_START_TYPE,
             w.ELIGIBLE_END, w.LOT_BASE_END_DT, pc.PREV_BASE_MEDS
    ORDER BY w.PATID, w.LOT_NUM, w.MED_ABBR")
}

# The substitute pairs themselves, for the R side: the opener test and the
# previous-regimen test read a drug under every name it can wear (4.4), and
# that needs the pairs, not only the SQL that already used them.
foldin_trace_subs_sql <- function(t) paste0("
    SELECT original_med, substitute_med FROM ", t$subs)

# Which build the trace is reading, as one string to compare before and after
# the reads. The run id alone does not identify a build - the engine keeps one
# id for a session, so a rebuild can leave a second complete row under it - so
# the pin carries UPDATED_AT, which moves on every rebuild, and STATE, which
# moves while one is running.
foldin_trace_build_pin <- function(row) {
  if (is.null(row) || !nrow(row)) return("(no row)")
  g <- function(nm) if (is.null(row[[nm]])) "" else as.character(row[[nm]][1])
  paste(g("RUN_ID"), g("STATE"), g("UPDATED_AT"))
}

# How big the run is, so the summary can say what share the rule touched.
foldin_trace_totals_sql <- function(t) paste0("
    SELECT count(DISTINCT cast(PATID as string)) AS N_PATIENTS, count(*) AS N_LINES
    FROM ", t$final)

# ---- The per-patient reads ---------------------------------------------------
# Each takes a validated id list. One SELECT per call, no temp views.

# The lines, with the window each one took its regimen from. The window comes
# from qc_window_sql() again - per line this time - because the episode table
# marks 'induction' against it and a copy in R would be the third definition.
# That is why this read needs p as well as the ids.
foldin_trace_lines_sql <- function(t, patids, p) {
  .need_checks()
  paste0("
    WITH ", qc_window_sql(t, p, per_line = TRUE), "
    SELECT cast(l.PATID as string) AS PATID, l.LOT_NUM, l.LOT_START_DT,
           l.LOT_START_TYPE, l.LOT_BASE_MEDS, l.LOT_MED_CNT, l.LOT_BASE_END_DT,
           l.LOT_BASE_END_REASON, l.LOT_BASE_LENGTH, l.LOT_BASE_1ST_ADD_MED,
           l.LOT_BASE_1ST_ADD_MED_DT, l.LOT_BASE_DISCON_DT, l.LOT_TX_AUTO_MAX_DT,
           w.ELIGIBLE_END
    FROM ", t$final, " l
    INNER JOIN lines w ON w.PATID = cast(l.PATID as string) AND w.LOT_NUM = l.LOT_NUM
    WHERE cast(l.PATID as string) IN ", foldin_trace_in_list(patids), "
    ORDER BY PATID, LOT_NUM")
}

# The raw episodes, every class, steroids included: they are what the study
# team asked to see. What is NOT read is MED_ABBR - the persisted table's drug
# column is MAP_MED_TYPE, and MAP_MED_ABBR exists only in a test fixture.
foldin_trace_episodes_sql <- function(t, patids) paste0("
    SELECT cast(PATID as string) AS PATID, MAP_START_DT, MAP_END_DT,
           MAP_MED_RUNOUT_DT, MAP_MED_TYPE, MAP_MED_CLASS, MAP_CNT, MAP_DISCON_FLG
    FROM ", t$map, "
    WHERE cast(PATID as string) IN ", foldin_trace_in_list(patids), "
    ORDER BY PATID, MAP_START_DT, MAP_MED_TYPE")

# The transplant events, named the way LOT_START_TYPE names them so a reader
# can match an event to the line it opened by eye.
foldin_trace_tx_sql <- function(t, patids) {
  ids <- foldin_trace_in_list(patids)
  paste0("
    SELECT cast(PATID as string) AS PATID, TX_DT, 'SCT_AUTO' AS TX_TYPE
    FROM ", t$auto, "
    WHERE cast(PATID as string) IN ", ids, "
    UNION ALL
    SELECT cast(PATID as string) AS PATID, TX_DT,
           CASE WHEN SCT_TYPE = 'ALLO' THEN 'SCT_ALLO'
                WHEN SCT_TYPE = 'CART' THEN 'CART'
                ELSE SCT_TYPE END AS TX_TYPE
    FROM ", t$allo, "
    WHERE cast(PATID as string) IN ", ids, "
    ORDER BY PATID, TX_DT, TX_TYPE")
}

# ---- The sample ----------------------------------------------------------------
# Deterministic, and a spread rather than the first n ids: ranked within each
# (LOT_NUM, MED_ABBR) group by PATID and taken round-robin, so ten patients
# show the rule on several drugs and several lines rather than ten LEN folds at
# LOT2. A patient with two folds is taken once. An explicit list bypasses the
# sample.
#
# The orderings are radix sorts: order() on a character column collates by the
# session locale, so two machines could otherwise pick different patients.
foldin_trace_sample <- function(cands, n, patids = NULL) {
  if (!is.null(patids) && length(patids))
    return(foldin_trace_check_patids(patids))
  n <- as.integer(n)
  if (is.na(n) || n < 1L) stop("TRACE_N must be a whole number of at least 1.", call. = FALSE)
  if (is.null(cands) || !nrow(cands)) return(character(0))
  d <- data.frame(PATID = as.character(cands$PATID),
                  LOT_NUM = as.integer(cands$LOT_NUM),
                  MED_ABBR = as.character(cands$MED_ABBR),
                  stringsAsFactors = FALSE)
  d <- d[order(d$LOT_NUM, d$MED_ABBR, d$PATID, method = "radix"), , drop = FALSE]
  d <- d[!duplicated(d), , drop = FALSE]
  grp <- paste(d$LOT_NUM, d$MED_ABBR)
  d$rank <- stats::ave(seq_len(nrow(d)), grp, FUN = seq_along)
  d <- d[order(d$rank, d$LOT_NUM, d$MED_ABBR, d$PATID, method = "radix"), , drop = FALSE]
  utils::head(unique(d$PATID), n)
}

# ---- The summary ---------------------------------------------------------------
# Over every fold, never the sample: the sample is for reading, the counts are
# for scale. The published table's own totals sit beside them.
#
# A signature row on a line a transplant or CAR-T opened is not a fold (see
# foldin_trace_sql), so it is kept out of the fold counts and counted on a
# row of its own, where a non-zero is a defect to raise. A candidates frame
# without LOT_START_TYPE is read as all MED lines.
foldin_trace_summary <- function(cands, n_patients_total, n_lines_total) {
  cnt <- function(d) c(n_patients = length(unique(d$PATID)),
                       n_lines = nrow(unique(d[, c("PATID", "LOT_NUM"), drop = FALSE])),
                       n_pairs = nrow(unique(d[, c("PATID", "LOT_NUM", "MED_ABBR"), drop = FALSE])))
  empty <- data.frame(PATID = character(0), LOT_NUM = integer(0),
                      MED_ABBR = character(0), stringsAsFactors = FALSE)
  d <- if (is.null(cands) || !nrow(cands)) empty else
    data.frame(PATID = as.character(cands$PATID), LOT_NUM = as.integer(cands$LOT_NUM),
               MED_ABBR = as.character(cands$MED_ABBR), stringsAsFactors = FALSE)
  is_med <- if (nrow(d) && !is.null(cands$LOT_START_TYPE))
    as.character(cands$LOT_START_TYPE) == "MED" else rep(TRUE, nrow(d))
  is_med[is.na(is_med)] <- TRUE
  odd <- d[!is_med, , drop = FALSE]
  d <- d[is_med, , drop = FALSE]
  row <- function(level, key, v) data.frame(
    level = level, key = key, n_patients = unname(v[["n_patients"]]),
    n_lines = unname(v[["n_lines"]]), n_pairs = unname(v[["n_pairs"]]),
    stringsAsFactors = FALSE)
  out <- list(row("LOT_LONG_FINAL", "all lines",
                  c(n_patients = as.numeric(n_patients_total),
                    n_lines = as.numeric(n_lines_total), n_pairs = NA_real_)),
              row("folds", "all", cnt(d)),
              row("signature on a non-MED line (build defect, not 4.8)", "all", cnt(odd)))
  for (k in sort(unique(d$LOT_NUM)))
    out[[length(out) + 1L]] <- row("by LOT_NUM", paste0("LOT", k), cnt(d[d$LOT_NUM == k, , drop = FALSE]))
  for (m in sort(unique(d$MED_ABBR)))
    out[[length(out) + 1L]] <- row("by drug", m, cnt(d[d$MED_ABBR == m, , drop = FALSE]))
  do.call(rbind, out)
}

# ---- The episode table ---------------------------------------------------------
# One row per raw episode and per transplant event, in date order, with the
# line whose span holds it and a note saying what the engine made of it:
#
#   'FOLDED into LOT n (4.8)'  an episode of a folded drug inside line n and
#                              after its window - the dose the rule folded,
#                              and any later dose of it inside the line
#   'opens LOT n'              an episode starting on a MED line's start
#                              date, or the transplant that opened a line
#   'induction'                any other non-steroid episode inside a window
#   blank                      everything else
#
# A steroid is shown and never marked: steroids are excluded from every line
# decision by class (LOT_RULES.md 2.1), so no note applies to one.
#
# 'opens LOT n' is not every non-steroid episode on the start date: a drug of
# the previous line's regimen cannot open a line (4.3) under any of its names
# (4.4), and the engine's foldin_openers leaves it out for that reason, so an
# episode of one starting on the start date is 'induction' here.
# `subs` is the substitute pairs (original_med, substitute_med) for the name
# test; without them a drug is matched by its own name only.
#
# On a line a transplant or CAR-T opened the fold's signature is not a fold
# (see foldin_trace_sql), and the note says so instead of crediting 4.8.
.as_date <- function(x) if (inherits(x, "Date")) x else as.Date(as.character(x))

# Every name a drug can wear: itself, the drug it stands in for, and the
# substitutes that stand in for it. The R side of .foldin_alias_ctes.
.drug_aliases <- function(med, subs = NULL) {
  med <- as.character(med)
  if (is.null(subs) || !nrow(subs)) return(med)
  o <- as.character(subs$original_med); u <- as.character(subs$substitute_med)
  unique(c(med, o[u == med], u[o == med]))
}

# Whether a space-separated regimen string carries a drug, under any of its names.
.regimen_carries <- function(regimen, med, subs = NULL) {
  r <- strsplit(trimws(as.character(regimen %||% "")), " ", fixed = TRUE)[[1]]
  any(.drug_aliases(med, subs) %in% r[nzchar(r)])
}

foldin_trace_annotate <- function(lines, episodes, tx, folds, p, subs = NULL) {
  if (is.null(lines$ELIGIBLE_END))
    stop("lines carries no ELIGIBLE_END; read them with foldin_trace_lines_sql().",
         call. = FALSE)
  cols <- c("PATID", "MAP_START_DT", "MAP_END_DT", "MAP_MED_RUNOUT_DT",
            "MAP_MED_TYPE", "MAP_MED_CLASS", "MAP_CNT", "MAP_DISCON_FLG",
            "line", "note")
  ep <- data.frame(
    PATID = as.character(episodes$PATID),
    MAP_START_DT = .as_date(episodes$MAP_START_DT),
    MAP_END_DT = .as_date(episodes$MAP_END_DT),
    MAP_MED_RUNOUT_DT = .as_date(episodes$MAP_MED_RUNOUT_DT),
    MAP_MED_TYPE = as.character(episodes$MAP_MED_TYPE),
    MAP_MED_CLASS = as.character(episodes$MAP_MED_CLASS),
    MAP_CNT = if (is.null(episodes$MAP_CNT)) rep(NA_real_, nrow(episodes))
              else suppressWarnings(as.numeric(episodes$MAP_CNT)),
    MAP_DISCON_FLG = if (is.null(episodes$MAP_DISCON_FLG)) rep(NA_real_, nrow(episodes))
                     else suppressWarnings(as.numeric(episodes$MAP_DISCON_FLG)),
    stringsAsFactors = FALSE)
  if (!is.null(tx) && nrow(tx)) {
    txr <- data.frame(
      PATID = as.character(tx$PATID), MAP_START_DT = .as_date(tx$TX_DT),
      MAP_END_DT = as.Date(NA), MAP_MED_RUNOUT_DT = as.Date(NA),
      MAP_MED_TYPE = as.character(tx$TX_TYPE), MAP_MED_CLASS = "TRANSPLANT",
      MAP_CNT = NA_real_, MAP_DISCON_FLG = NA_real_, stringsAsFactors = FALSE)
    ep <- rbind(ep, txr)
  }
  ln <- data.frame(
    PATID = as.character(lines$PATID), LOT_NUM = as.integer(lines$LOT_NUM),
    LOT_START_DT = .as_date(lines$LOT_START_DT),
    LOT_BASE_END_DT = .as_date(lines$LOT_BASE_END_DT),
    LOT_START_TYPE = as.character(lines$LOT_START_TYPE),
    LOT_BASE_MEDS = if (is.null(lines$LOT_BASE_MEDS)) rep("", nrow(lines))
                    else as.character(lines$LOT_BASE_MEDS),
    ELIGIBLE_END = .as_date(lines$ELIGIBLE_END), stringsAsFactors = FALSE)
  ln$LOT_BASE_MEDS[is.na(ln$LOT_BASE_MEDS)] <- ""
  fd <- if (is.null(folds) || !nrow(folds))
    data.frame(PATID = character(0), LOT_NUM = integer(0), MED_ABBR = character(0),
               stringsAsFactors = FALSE)
  else data.frame(PATID = as.character(folds$PATID), LOT_NUM = as.integer(folds$LOT_NUM),
                  MED_ABBR = as.character(folds$MED_ABBR), stringsAsFactors = FALSE)

  ep$line <- ""; ep$note <- ""
  for (i in seq_len(nrow(ep))) {
    d <- ep$MAP_START_DT[i]
    if (is.na(d)) next
    l <- ln[ln$PATID == ep$PATID[i] & ln$LOT_START_DT <= d & ln$LOT_BASE_END_DT >= d, , drop = FALSE]
    if (!nrow(l)) next
    l <- l[1, ]
    ep$line[i] <- as.character(l$LOT_NUM)
    med <- ep$MAP_MED_TYPE[i]
    if (identical(ep$MAP_MED_CLASS[i], "TRANSPLANT")) {
      if (identical(l$LOT_START_TYPE, med) && l$LOT_START_DT == d)
        ep$note[i] <- paste0("opens LOT ", l$LOT_NUM)
      next
    }
    if (identical(toupper(trimws(ep$MAP_MED_CLASS[i])), "STEROID")) next
    folded <- any(fd$PATID == ep$PATID[i] & fd$LOT_NUM == l$LOT_NUM & fd$MED_ABBR == med)
    pl <- ln[ln$PATID == ep$PATID[i] & ln$LOT_NUM == l$LOT_NUM - 1L, , drop = FALSE]
    prev_had <- nrow(pl) > 0L && .regimen_carries(pl$LOT_BASE_MEDS[1], med, subs)
    if (folded && d > l$ELIGIBLE_END)
      ep$note[i] <- if (identical(l$LOT_START_TYPE, "MED"))
        paste0("FOLDED into LOT ", l$LOT_NUM, " (4.8)")
      else paste0("signature on LOT ", l$LOT_NUM, ", a ", l$LOT_START_TYPE,
                  " line: not a 4.8 fold, raise as a build defect")
    else if (identical(l$LOT_START_TYPE, "MED") && l$LOT_START_DT == d && !prev_had)
      ep$note[i] <- paste0("opens LOT ", l$LOT_NUM)
    else if (d <= l$ELIGIBLE_END)
      ep$note[i] <- "induction"
  }
  ep <- ep[order(ep$PATID, ep$MAP_START_DT, ep$MAP_MED_CLASS != "TRANSPLANT",
                 ep$MAP_MED_TYPE), cols, drop = FALSE]
  rownames(ep) <- NULL
  ep
}

# ---- The narrative -------------------------------------------------------------
# One paragraph per folded (line, drug), in plain sentences: where the drug
# was, what opened the line it returned in, when it came back, and what the
# reading before 4.8 would have done with it. The study team asked to see that
# these patients are classified as the rule says, which needs the alternative
# stated.
#
# The pre-rule outcome is not one sentence, because the engine has three
# readings of an agent arriving outside the window, and which one applies turns
# on where the line's own regimen had got to (engine/R/steps/10_lot2_5_base.R,
# first_add_candidates and the end-reason cascade):
#
#   - the own drugs still covered the return date: the return is an added
#     medication, the line ends MED_ADD the day before it (date_sub) and the
#     next line opens on it (7.4);
#   - the same, with a CAR-T within cart_consolidation_days of the return:
#     bridging, the line ends CART_INIT the day before the infusion (7.3);
#   - the own drugs had run out before the return: the return is no candidate
#     at all - the added-medication window closes at the raw run-out - and it
#     confirms the run-out instead (5.3), so the line ends DISCONTINUATION on
#     that date and the next line opens on the return.
#
# The persisted line cannot say which, because the fold's hold has already
# carried its run-out to the folded supply. So the own cover is read off the
# episodes shown: the own regimen is the regimen drugs with an episode inside
# the window (a folded drug has none, by the signature), and its cover is the
# last MAP_END_DT of their episodes starting in the line before the return, the
# way the engine chains cover forward - a foreign drug that would have broken
# the chain before the return would have ended the line earlier still. Where
# the read shows no own episode the paragraph says so and hedges.
#
# A line a transplant or CAR-T opened gets no such paragraph: 4.8 refuses the
# fold there, so the signature is a defect and the paragraph says that.
#
# The reading is local, so a boundary is stated once per patient. It asks what
# the engine would have made of this return in the line as built, which holds
# only up to the first return the rule folded; after that, the line holding a
# later return depends on what the engine would have done with the earlier one,
# and that is not in these tables. So `all_folds` is the patient's whole fold
# set and only the earliest return in it carries a boundary. The rest name
# where the reading stops and what settles it: a build of the same cohort with
# APPLY_MAP_FOLDIN=FALSE, differenced against this one.
#
# No paragraph claims anything about the line number. Saying the earlier return
# would have opened a line, so this one is not in LOT n, is wrong where the
# earlier return is bridged: two returns inside one CAR-T's consolidation
# window end LOT n on the infusion's eve either way (7.3), so the regimen and
# the end reason differ and the numbering does not. The paragraph says only
# that the answer is not in these tables.
#
# Returns sharing the earliest date are one divergence: the engine would have
# judged both on the one date, so its reading of that date covers them both.
# Which reading it is goes unsaid, the paragraph above having said it once.
foldin_trace_narrative <- function(fold_row, lines, episodes, p, tx = NULL, subs = NULL,
                                   all_folds = NULL) {
  f <- fold_row
  n <- as.integer(f$LOT_NUM)
  drug <- as.character(f$MED_ABBR)
  start <- .as_date(f$LOT_START_DT)
  ret <- .as_date(f$RETURN_DT)
  elig <- .as_date(f$ELIGIBLE_END)
  ln <- lines[as.character(lines$PATID) == as.character(f$PATID), , drop = FALSE]
  this <- ln[as.integer(ln$LOT_NUM) == n, , drop = FALSE]
  start_type <- if (!is.null(f$LOT_START_TYPE) && !is.na(f$LOT_START_TYPE))
    as.character(f$LOT_START_TYPE)
  else if (nrow(this)) as.character(this$LOT_START_TYPE[1]) else "MED"
  base <- if (nrow(this)) as.character(this$LOT_BASE_MEDS[1]) else ""
  prev <- as.character(f$PREV_BASE_MEDS %||% "")
  if (!nzchar(prev) || is.na(prev)) {
    pl <- ln[as.integer(ln$LOT_NUM) == n - 1L, , drop = FALSE]
    prev <- if (nrow(pl)) as.character(pl$LOT_BASE_MEDS[1]) else ""
  }
  w <- if (identical(start_type, "CART")) p$cart else if (n == 1L) p$ind1 else p$indn
  nominal_end <- start + (w - 1L)
  e <- episodes[as.character(episodes$PATID) == as.character(f$PATID), , drop = FALSE]
  e <- e[toupper(trimws(as.character(e$MAP_MED_CLASS))) != "STEROID", , drop = FALSE]
  e_start <- .as_date(e$MAP_START_DT)
  e_med <- as.character(e$MAP_MED_TYPE)
  k <- as.integer(ret - start)
  window <- paste0("outside its ", w, "-day induction window (window ended ", format(elig),
                   if (elig < nominal_end) ", cut short by a transplant" else "", ")")

  # The line a procedure opened: the signature is there, the rule is not.
  if (!identical(start_type, "MED")) {
    return(paste0(
      drug, " was in LOT ", n - 1L, "'s regimen (", prev, "). ",
      "LOT ", n, " was opened by a transplant (", start_type, ") on ", format(start), ". ",
      drug, " returned on ", format(ret), ", ", k, " days after LOT ", n,
      " opened and ", window, ", and it is in LOT ", n, "'s regimen (", base, "). ",
      "4.8 refuses a fold across a procedure that opened a line, so this drug ",
      "should not have reached LOT ", n, "'s regimen by the fold: the row carries ",
      "the fold's signature but is not the rule's doing and should be raised as a ",
      "build defect (check C1 accepts this route and will not flag it)."))
  }

  # What opened the line: the non-steroid drugs dosed on the start date that
  # the previous regimen did not carry (4.3), under any name (4.4).
  op <- e_med[e_start == start & !vapply(e_med, function(m) .regimen_carries(prev, m, subs), logical(1))]
  openers <- sort(unique(op))
  opened_by <- if (length(openers)) paste(openers, collapse = " and ")
               else "a drug whose episode is not in the read (none starts on the line's start date)"

  # The own regimen and where its cover reached before the return.
  base_drugs <- strsplit(trimws(base), " ", fixed = TRUE)[[1]]
  base_drugs <- base_drugs[nzchar(base_drugs)]
  own <- base_drugs[vapply(base_drugs, function(m)
    any(e_med == m & e_start >= start & e_start <= elig), logical(1))]
  own_eps <- e[e_med %in% own & e_start >= start & e_start < ret, , drop = FALSE]
  own_end <- if (nrow(own_eps)) max(.as_date(own_eps$MAP_END_DT), na.rm = TRUE) else as.Date(NA)
  own_txt <- if (length(own)) paste(own, collapse = " ") else "(none in the read)"

  # The first CAR-T after the line opened, for the bridging reading.
  cart_dt <- as.Date(NA)
  if (!is.null(tx) && nrow(tx)) {
    tp <- tx[as.character(tx$PATID) == as.character(f$PATID) &
               as.character(tx$TX_TYPE) == "CART", , drop = FALSE]
    td <- .as_date(tp$TX_DT); td <- td[!is.na(td) & td > start]
    if (length(td)) cart_dt <- min(td)
  }
  cart_bridge <- !is.na(cart_dt) && as.integer(cart_dt - ret) >= 0L &&
    as.integer(cart_dt - ret) <= p$cart

  # Where this patient's two histories part, and whether this return is at it.
  # Folds of this patient only; a frame without RETURN_DT (or no frame at all)
  # is read as this return being the only one.
  fr <- if (!is.null(all_folds) && nrow(all_folds) && !is.null(all_folds$RETURN_DT))
    all_folds[as.character(all_folds$PATID) == as.character(f$PATID), , drop = FALSE]
  else NULL
  first_ret <- ret; peers <- character(0); first_drugs <- drug
  if (!is.null(fr) && nrow(fr)) {
    rd <- .as_date(fr$RETURN_DT)
    keep <- !is.na(rd)
    if (any(keep)) {
      first_ret <- min(rd[keep])
      first_drugs <- sort(unique(as.character(fr$MED_ABBR)[keep & rd == first_ret]))
      peers <- setdiff(first_drugs, drug)
    }
  }
  diverged <- !is.na(first_ret) && !is.na(ret) && ret > first_ret
  # The same day as another fold: one divergence, and the other drug is named
  # so the two paragraphs read as one boundary rather than two. The boundary
  # itself has just been stated; this adds only that it covers both.
  also <- if (!diverged && length(peers))
    paste0(" ", paste(peers, collapse = " and "), " returned the same day, so the ",
           "same reading covers ", if (length(peers) > 1L) "them" else "it",
           ": one date, one boundary.") else ""

  pre <- if (diverged) {
    paste0("Without the rule this return cannot be read from these tables alone. ",
           "The earlier return of ", paste(first_drugs, collapse = " and "), " on ",
           format(first_ret), " is the first thing the rule decided for this patient, ",
           "and whatever the engine would have made of THAT one is what the line ",
           "holding this return depends on - its regimen, its end, and the lines ",
           "after it. So no boundary is stated for this return here: one computed ",
           "from a line built WITH the rule would belong to a history that may not ",
           "be the one without it. A build of the same cohort with ",
           "APPLY_MAP_FOLDIN=FALSE, differenced against this one, is what settles it.")
  } else if (is.na(own_end)) {
    paste0("Without the rule this return would not have joined LOT ", n, ". ",
           "The episodes read here show no cover for LOT ", n, "'s own regimen (", own_txt,
           "), so which end it would have had cannot be said from them: an added ",
           "medication ending LOT ", n, " MED_ADD on ", format(ret - 1L),
           " if the own drugs were still running, or a DISCONTINUATION on their ",
           "run-out if they were not. Either way a new line would have opened on ",
           format(ret), " with ", drug, ".")
  } else if (ret > own_end) {
    paste0("Without the rule this return would not have been an added medication: ",
           "LOT ", n, "'s own regimen (", own_txt, ") had run out on ", format(own_end),
           ", before the return, and the added-medication window closes at the ",
           "run-out. The return would have confirmed that run-out instead (5.3): LOT ", n,
           " would have ended DISCONTINUATION on ", format(own_end),
           ", and a new line would have opened on ", format(ret), " with ", drug, ".")
  } else if (cart_bridge) {
    paste0("Without the rule this return would have been an added medication (LOT ", n,
           "'s own regimen, ", own_txt, ", was still covered on ", format(ret),
           ", to ", format(own_end), ") followed by a CAR-T on ", format(cart_dt), ", ",
           as.integer(cart_dt - ret), " days later and inside the ", p$cart,
           "-day consolidation window, so it would have been read as bridging (7.3): LOT ", n,
           " would have ended CART_INIT on ", format(cart_dt - 1L),
           ", the day before the infusion, and the CAR-T would have opened the next line.")
  } else {
    paste0("Without the rule this return would have been an added medication: LOT ", n,
           "'s own regimen (", own_txt, ") was still covered on ", format(ret), " (cover ran to ",
           format(own_end), "), so LOT ", n, " would have ended MED_ADD on ", format(ret - 1L),
           ", the day before the return, and a new line would have opened on ",
           format(ret), " with ", drug, ".")
  }
  pre <- paste0(pre, also)

  paste0(
    drug, " was in LOT ", n - 1L, "'s regimen (", prev, "). ",
    "LOT ", n, " opened on ", format(start), " with ", opened_by, ". ",
    drug, " returned on ", format(ret), ", ", k, " days after LOT ", n,
    " opened and ", window, "; under 4.8 it joined LOT ", n, "'s regimen (",
    base, "). ", pre)
}

# ---- Rendering -----------------------------------------------------------------

# format(), not as.character(): a round total such as 100000 lines would
# otherwise print as 1e+05 in a file meant to be read.
.md_cell <- function(v) {
  v <- if (inherits(v, "Date")) format(v)
       else if (is.numeric(v)) ifelse(is.na(v), NA_character_, format(v, scientific = FALSE, trim = TRUE))
       else as.character(v)
  v[is.na(v)] <- ""
  gsub("|", "/", v, fixed = TRUE)
}

foldin_trace_md_table <- function(df, cols = names(df)) {
  if (!nrow(df)) return("(no rows)")
  hdr <- paste0("| ", paste(cols, collapse = " | "), " |")
  sep <- paste0("|", paste(rep("---", length(cols)), collapse = "|"), "|")
  body <- vapply(seq_len(nrow(df)), function(i)
    paste0("| ", paste(vapply(cols, function(cn) .md_cell(df[[cn]][i]), character(1)),
                       collapse = " | "), " |"), character(1))
  c(hdr, sep, body)
}

TRACE_LINE_COLS <- c("LOT_NUM", "LOT_START_DT", "LOT_START_TYPE", "LOT_BASE_MEDS",
                     "LOT_MED_CNT", "LOT_BASE_END_DT", "LOT_BASE_END_REASON",
                     "LOT_BASE_LENGTH", "LOT_BASE_1ST_ADD_MED", "LOT_BASE_1ST_ADD_MED_DT",
                     "LOT_BASE_DISCON_DT", "LOT_TX_AUTO_MAX_DT")
TRACE_EPISODE_COLS <- c("MAP_START_DT", "MAP_END_DT", "MAP_MED_RUNOUT_DT", "MAP_MED_TYPE",
                        "MAP_MED_CLASS", "MAP_CNT", "MAP_DISCON_FLG", "line", "note")

# One patient's section: the narratives, the lines, the episodes. `shown_id`
# is what the heading says - the real id, or the masked one when asked. An id
# with no line at all is most likely a typo in TRACE_PATIDS, and is said to
# be that rather than dressed as a patient with nothing to show.
foldin_trace_patient_md <- function(shown_id, folds_p, lines_p, episodes_p, ann_p, p,
                                    tx_p = NULL, subs = NULL) {
  ln <- c(paste0("## Patient ", shown_id), "")
  if (is.null(lines_p) || !nrow(lines_p)) {
    return(c(ln, "This id has no line in LOT_LONG_FINAL under this prefix. Check the id.", ""))
  }
  if (is.null(folds_p) || !nrow(folds_p)) {
    ln <- c(ln, "No fold found for this patient: no regimen drug of any line carries ",
            "the signature (in the previous line's regimen, no episode inside the ",
            "induction window, an episode inside the line). Listed by request; the ",
            "lines and episodes are shown as they are.", "")
  } else {
    # In return order, and each paragraph is given the patient's whole fold
    # set: the without-rule reading holds only up to the first return that
    # folded, and a paragraph has to know whether it is that one.
    ord <- order(.as_date(folds_p$RETURN_DT), as.character(folds_p$MED_ABBR),
                 method = "radix")
    for (i in ord)
      ln <- c(ln, foldin_trace_narrative(folds_p[i, , drop = FALSE], lines_p, episodes_p, p,
                                         tx = tx_p, subs = subs, all_folds = folds_p), "")
  }
  ln <- c(ln, "Lines (LOT_LONG_FINAL):", "",
          foldin_trace_md_table(lines_p, TRACE_LINE_COLS), "",
          "Episodes (MAP_STACKED) and transplant events, in date order:", "",
          foldin_trace_md_table(ann_p, TRACE_EPISODE_COLS), "")
  ln
}

# The whole report. `patients_sections` is a list of character vectors, one
# per traced patient, in the order they were traced.
foldin_trace_markdown <- function(run_id, pfx, p, summary, patients_sections, masked,
                                  n_candidates = NA, n_traced = length(patients_sections),
                                  listed = FALSE) {
  ln <- c(paste0("# Fold-in trace - ", pfx),
          "",
          paste0("Run `", run_id, "`. The fold-in rule (LOT_RULES.md 4.8) on the ",
                 "patients it touched: raw MAP episodes beside the final lines, ",
                 "the folded episode marked."),
          "",
          if (isTRUE(masked))
            paste0("Patient ids are MASKED to their last six characters, as the QC ",
                   "report masks them. To look a patient up, run the trace without ",
                   "TRACE_MASK_PATID.")
          else
            paste0("Patient ids are NOT masked. This file carries patient ",
                   "identifiers and stays inside the study environment; it exists ",
                   "so each patient can be looked up in the warehouse."),
          "",
          paste0("Windows as the run recorded them: LOT1 ", p$ind1, " days, later lines ",
                 p$indn, ", CAR-T ", p$cart, ". A fold is a regimen drug of line n ",
                 "(n >= 2) that line n-1 carried, with no episode inside line n's ",
                 "window and an episode inside line n after it. That is the route ",
                 "check C1 accepts, and nothing else produces it. On a line a ",
                 "transplant or CAR-T opened the same signature is not a fold, since ",
                 "4.8 refuses one there; such rows are counted apart as a build defect."),
          "",
          paste0("Each section also says what the reading before the rule would ",
                 "have made of the return. That is a local reading of these tables ",
                 "and it is stated only for the FIRST return the rule folded in a ",
                 "patient: what a later return would have been depends on what the ",
                 "engine would have done with the earlier one, which these tables ",
                 "do not record, so its paragraph says that rather than guess. It ",
                 "does not say the line would have been numbered differently ",
                 "either, since that is the same guess. A build of the same cohort ",
                 "with APPLY_MAP_FOLDIN=FALSE, differenced against this one, is ",
                 "what settles an alternative history."),
          "",
          paste0(if (is.na(n_candidates)) "" else paste0(n_candidates, " patient(s) carry a fold. "),
                 n_traced, " traced",
                 if (isTRUE(listed)) " (listed by TRACE_PATIDS)" else " (a round-robin sample over line and drug)",
                 "."),
          "",
          "## Summary (over every fold, not the sample)", "",
          foldin_trace_md_table(summary), "")
  for (s in patients_sections) ln <- c(ln, s)
  ln
}
