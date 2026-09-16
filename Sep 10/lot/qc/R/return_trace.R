# The returning-drug trace, as functions: "drugs that come back", read off a
# finished run's published tables.
#
# The study team asked to see, on live patients, what the rules adopted on
# 30 Aug 2026 (LOT_RULES.md 4.3 and 4.8) do with a drug that comes back -
# and, for the 2L question, which returns now stay inside a line that the
# earlier reading would have split. The engine keeps no flag for any of it, so
# every kind here is recognised by its signature in LOT_LONG_FINAL and
# MAP_STACKED, the way the fold-in trace (R/foldin_trace.R) recognises a fold.
# That file is reused for the fold itself; this one adds the other shapes and
# a report that holds them side by side.
#
# Four kinds of return, per (patient, line n, drug):
#
#   fold        4.8 - the drug was in line n-1's regimen, has no episode inside
#               line n's induction window, and an episode inside line n after
#               it: exactly one agent advanced the line between its two doses,
#               so it JOINED line n. foldin_trace_sql() finds these.
#
#   own_return  4.3 - the drug is line n's own regimen (an episode inside the
#               window) and an episode of it inside line n after the window
#               follows a CONFIRMED break of its own - the immediately
#               preceding episode of that drug carries MAP_DISCON_FLG = 1, a
#               gap of map_discon_gap_days or more. The line ran on over the
#               break. Before the rule the break released the drug and this
#               return opened a new line: a 1L drug back after a holiday made
#               a 2L that no longer exists.
#
#   opens_line  the counter-example: a drug given in an EARLIER line came back
#               and OPENED line n (its episode starts on the line's start date,
#               the line is medication-started, and line n-1 did not carry it).
#               Two shapes, both outside 4.8: the drug is from two or more
#               lines back, so the fold set - the immediately previous line's
#               regimen - never held it; or a transplant or CAR-T opened line
#               n-1, and 4.8 refuses a fold across a procedure that opened a
#               line, so the return was an added medication that ended line
#               n-1 and opened line n.
#
#   carried_over  not a return: the drug was in line n-1's regimen and has an
#               episode inside line n's window, so it is an ordinary regimen
#               drug of both lines (a backbone continuing while an agent is
#               added). Counted, never traced: it is what a reader will ask
#               "why is this not a fold" about, and the answer is the window.
#
# RETURN_LINE is the line the return belongs to for the 2L question: line n
# for a fold and an own return, and line n-1 for an opens_line row - the
# drug came back after that line and opened the next. TRACE_LINES filters on
# it, so TRACE_LINES=2 is "drugs that came back in 2L": folds into 2L, own
# returns inside 2L, and returns after 2L that opened 3L.
#
# Patient ids are not masked here, like the fold-in trace: the file exists so
# a patient can be looked up. The runner masks on request, after the reads.

.need_foldin <- function() {
  if (!exists("foldin_trace_sql", mode = "function"))
    stop("R/foldin_trace.R is not sourced. The fold kind is its query, ",
         "and the episode table is its annotation.", call. = FALSE)
}

RETURN_TRACE_KINDS <- c("fold", "own_return", "opens_line")
RETURN_TRACE_ALL_KINDS <- c(RETURN_TRACE_KINDS, "carried_over")

# The columns every kind's rows are brought to, so the kinds can be stacked.
RETURN_TRACE_COLS <- c("PATID", "LOT_NUM", "MED_ABBR", "KIND", "RETURN_LINE",
                       "LOT_START_DT", "LOT_START_TYPE", "ELIGIBLE_END",
                       "LOT_BASE_END_DT", "PREV_BASE_MEDS", "RETURN_DT",
                       "PREV_EP_START", "PREV_EP_END", "FROM_LOT",
                       "PREV_LINE_START_TYPE")

# ---- The shared CTEs ----------------------------------------------------------
# The lines with their windows come from qc_window_sql() in R/checks.R, per
# line, so the window is the one definition C1 and the fold-in trace read. The
# regimen is exploded from it here, with the line's end joined back on from
# the published table, because the per-line shape does not carry it.
.return_trace_base_ctes <- function(t, p) {
  .need_checks()
  paste0(qc_window_sql(t, p, per_line = TRUE), ",
    reg AS (
      SELECT w.PATID, w.LOT_NUM, w.LOT_START_DT, w.LOT_START_TYPE,
             w.LOT_BASE_MEDS, w.ELIGIBLE_END, l.LOT_BASE_END_DT, m AS MED_ABBR
      FROM lines w
      INNER JOIN ", t$final, " l
        ON cast(l.PATID as string) = w.PATID AND l.LOT_NUM = w.LOT_NUM
      LATERAL VIEW explode(split(coalesce(w.LOT_BASE_MEDS, ''), ' ')) e AS m
      WHERE m <> ''
    ),
    -- Every episode with the one before it, per patient and drug: the
    -- engine's own restart test reads lag(MAP_DISCON_FLG) the same way
    -- (engine/R/prior_regimen.R, map_restart_sql).
    ep AS (
      SELECT cast(PATID as string) AS PATID, MAP_MED_TYPE, MAP_MED_CLASS,
             MAP_START_DT, MAP_END_DT, MAP_DISCON_FLG,
             lag(MAP_DISCON_FLG) OVER (PARTITION BY cast(PATID as string), MAP_MED_TYPE
                                      ORDER BY MAP_START_DT) AS PREV_DISCON,
             lag(MAP_START_DT) OVER (PARTITION BY cast(PATID as string), MAP_MED_TYPE
                                     ORDER BY MAP_START_DT) AS PREV_START,
             lag(MAP_END_DT) OVER (PARTITION BY cast(PATID as string), MAP_MED_TYPE
                                   ORDER BY MAP_START_DT) AS PREV_END
      FROM ", t$map, "
    ),
    -- The drug's first episode inside the line's own window, where it has one.
    in_window AS (
      SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, min(e.MAP_START_DT) AS FIRST_IN_WINDOW
      FROM reg w
      INNER JOIN ep e
        ON e.PATID = w.PATID AND e.MAP_MED_TYPE = w.MED_ABBR
       AND e.MAP_START_DT >= w.LOT_START_DT AND e.MAP_START_DT <= w.ELIGIBLE_END
      GROUP BY w.PATID, w.LOT_NUM, w.MED_ABBR
    ),
    -- The line before each line, for what opened it and what it carried.
    prev_line AS (
      SELECT cast(PATID as string) AS PATID, LOT_NUM + 1 AS LOT_NUM,
             LOT_START_TYPE AS PREV_LINE_START_TYPE, LOT_BASE_MEDS AS PREV_LINE_MEDS
      FROM ", t$final, "
    )")
}

# The own return - 4.3. One row per return, so a drug that came back after
# two breaks in one line is two rows.
return_trace_own_sql <- function(t, p) {
  paste0("
    WITH ", .return_trace_base_ctes(t, p), "
    SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, 'own_return' AS KIND, w.LOT_NUM AS RETURN_LINE,
           w.LOT_START_DT, w.LOT_START_TYPE, w.ELIGIBLE_END, w.LOT_BASE_END_DT,
           cast(NULL as string) AS PREV_BASE_MEDS,
           e.MAP_START_DT AS RETURN_DT, e.PREV_START AS PREV_EP_START,
           e.PREV_END AS PREV_EP_END, cast(NULL as int) AS FROM_LOT,
           cast(NULL as string) AS PREV_LINE_START_TYPE
    FROM reg w
    -- the drug is the line's own: an episode inside the window
    INNER JOIN in_window iw
      ON iw.PATID = w.PATID AND iw.LOT_NUM = w.LOT_NUM AND iw.MED_ABBR = w.MED_ABBR
    -- ...and it came back inside the line, after the window, after a
    -- confirmed break of its own
    INNER JOIN ep e
      ON e.PATID = w.PATID AND e.MAP_MED_TYPE = w.MED_ABBR
     AND e.MAP_START_DT >= w.LOT_START_DT
     AND e.MAP_START_DT >  w.ELIGIBLE_END
     AND e.MAP_START_DT <= w.LOT_BASE_END_DT
     AND coalesce(e.PREV_DISCON, 0) = 1
    -- a steroid is excluded from every line decision by class (2.1), so its
    -- return never opened a line under either reading and is not one here
    WHERE upper(trim(coalesce(e.MAP_MED_CLASS, ''))) <> 'STEROID'
    ORDER BY w.PATID, w.LOT_NUM, w.MED_ABBR, e.MAP_START_DT")
}

# The counter-example: an earlier line's drug opening a line.
return_trace_opens_sql <- function(t, p) {
  paste0("
    WITH ", .return_trace_base_ctes(t, p), ",", .foldin_alias_ctes(t), ",
    -- any line two or more back that carried the drug, under any of its names
    earlier_carried AS (
      SELECT a.PATID, a.LOT_NUM, a.MED_ABBR, max(pl.LOT_NUM) AS FROM_LOT
      FROM w_alias a
      INNER JOIN ", t$final, " pl
        ON cast(pl.PATID as string) = a.PATID AND pl.LOT_NUM <= a.LOT_NUM - 2
      WHERE array_contains(split(coalesce(pl.LOT_BASE_MEDS, ''), ' '), a.ALIAS)
      GROUP BY a.PATID, a.LOT_NUM, a.MED_ABBR
    ),
    -- the drug's last episode before the line it opened
    before AS (
      SELECT w.PATID, w.LOT_NUM, w.MED_ABBR,
             max(e.MAP_START_DT) AS PREV_EP_START
      FROM reg w
      INNER JOIN ep e
        ON e.PATID = w.PATID AND e.MAP_MED_TYPE = w.MED_ABBR
       AND e.MAP_START_DT < w.LOT_START_DT
      GROUP BY w.PATID, w.LOT_NUM, w.MED_ABBR
    )
    SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, 'opens_line' AS KIND, w.LOT_NUM - 1 AS RETURN_LINE,
           w.LOT_START_DT, w.LOT_START_TYPE, w.ELIGIBLE_END, w.LOT_BASE_END_DT,
           pv.PREV_LINE_MEDS AS PREV_BASE_MEDS,
           w.LOT_START_DT AS RETURN_DT, b.PREV_EP_START,
           be.MAP_END_DT AS PREV_EP_END, ec.FROM_LOT, pv.PREV_LINE_START_TYPE
    FROM reg w
    INNER JOIN earlier_carried ec
      ON ec.PATID = w.PATID AND ec.LOT_NUM = w.LOT_NUM AND ec.MED_ABBR = w.MED_ABBR
    -- the drug's episode starts on the line's start date: it opened the line
    INNER JOIN ep e
      ON e.PATID = w.PATID AND e.MAP_MED_TYPE = w.MED_ABBR
     AND e.MAP_START_DT = w.LOT_START_DT
    LEFT JOIN prev_line pv ON pv.PATID = w.PATID AND pv.LOT_NUM = w.LOT_NUM
    LEFT JOIN before b
      ON b.PATID = w.PATID AND b.LOT_NUM = w.LOT_NUM AND b.MED_ABBR = w.MED_ABBR
    LEFT JOIN ep be
      ON be.PATID = w.PATID AND be.MAP_MED_TYPE = w.MED_ABBR
     AND be.MAP_START_DT = b.PREV_EP_START
    WHERE w.LOT_START_TYPE = 'MED' AND w.LOT_NUM >= 3
      AND upper(trim(coalesce(e.MAP_MED_CLASS, ''))) <> 'STEROID'
      -- and the immediately previous line did NOT carry it: that would be
      -- 4.3's drug, which cannot open a line
      AND NOT EXISTS (
        SELECT 1 FROM prev_carried pc
        WHERE pc.PATID = w.PATID AND pc.LOT_NUM = w.LOT_NUM AND pc.MED_ABBR = w.MED_ABBR)
    ORDER BY w.PATID, w.LOT_NUM, w.MED_ABBR")
}

# The carried-over drug: counted for scale, never traced.
return_trace_carried_sql <- function(t, p) {
  paste0("
    WITH ", .return_trace_base_ctes(t, p), ",", .foldin_alias_ctes(t), "
    SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, 'carried_over' AS KIND, w.LOT_NUM AS RETURN_LINE,
           w.LOT_START_DT, w.LOT_START_TYPE, w.ELIGIBLE_END, w.LOT_BASE_END_DT,
           pc.PREV_BASE_MEDS, iw.FIRST_IN_WINDOW AS RETURN_DT,
           cast(NULL as date) AS PREV_EP_START, cast(NULL as date) AS PREV_EP_END,
           cast(NULL as int) AS FROM_LOT, cast(NULL as string) AS PREV_LINE_START_TYPE
    FROM reg w
    INNER JOIN prev_carried pc
      ON pc.PATID = w.PATID AND pc.LOT_NUM = w.LOT_NUM AND pc.MED_ABBR = w.MED_ABBR
    INNER JOIN in_window iw
      ON iw.PATID = w.PATID AND iw.LOT_NUM = w.LOT_NUM AND iw.MED_ABBR = w.MED_ABBR
    WHERE w.LOT_NUM >= 2
      AND NOT EXISTS (
        SELECT 1 FROM ep s WHERE s.PATID = w.PATID AND s.MAP_MED_TYPE = w.MED_ABBR
          AND upper(trim(coalesce(s.MAP_MED_CLASS, ''))) = 'STEROID')
    ORDER BY w.PATID, w.LOT_NUM, w.MED_ABBR")
}

# All four, as one named list. The fold is the fold-in trace's own query,
# unchanged, so the two reports cannot disagree about what a fold is.
return_trace_queries <- function(t, p) {
  .need_foldin()
  list(fold = foldin_trace_sql(t, p),
       own_return = return_trace_own_sql(t, p),
       opens_line = return_trace_opens_sql(t, p),
       carried_over = return_trace_carried_sql(t, p))
}

# The kinds' rows stacked into one frame with RETURN_TRACE_COLS. `results` is
# the named list of frames the queries returned; a kind whose frame lacks a
# column (the fold query carries no PREV_EP_*) gets NA there.
return_trace_stack <- function(results) {
  out <- lapply(names(results), function(k) {
    d <- results[[k]]
    # A frame the runner could not fill carries its error and no rows; the
    # runner has already said so, and the stack must not read it as empty.
    if (is.null(d) || !is.data.frame(d) || !nrow(d)) return(NULL)
    d <- as.data.frame(d, stringsAsFactors = FALSE)
    d$KIND <- k
    if (is.null(d$RETURN_LINE)) d$RETURN_LINE <- as.integer(d$LOT_NUM)
    for (cn in RETURN_TRACE_COLS) if (is.null(d[[cn]])) d[[cn]] <- NA
    d <- d[, RETURN_TRACE_COLS, drop = FALSE]
    d$PATID <- as.character(d$PATID)
    d$LOT_NUM <- as.integer(d$LOT_NUM); d$RETURN_LINE <- as.integer(d$RETURN_LINE)
    d$FROM_LOT <- suppressWarnings(as.integer(d$FROM_LOT))
    for (dc in c("LOT_START_DT", "ELIGIBLE_END", "LOT_BASE_END_DT", "RETURN_DT",
                 "PREV_EP_START", "PREV_EP_END"))
      d[[dc]] <- .as_date(d[[dc]])
    d
  })
  out <- Filter(Negate(is.null), out)
  if (!length(out)) {
    e <- as.data.frame(stats::setNames(replicate(length(RETURN_TRACE_COLS), character(0),
                                                 simplify = FALSE), RETURN_TRACE_COLS),
                       stringsAsFactors = FALSE)
    return(e)
  }
  d <- do.call(rbind, out)
  d <- d[order(d$PATID, d$RETURN_DT, d$LOT_NUM, d$MED_ABBR, method = "radix"), , drop = FALSE]
  rownames(d) <- NULL
  d
}

# ---- Filters, the sample and the summary --------------------------------------
# A kind list or a line list from the environment, refused rather than guessed
# at when it names something this trace does not know.
return_trace_parse_kinds <- function(raw) {
  raw <- trimws(as.character(raw %||% ""))
  if (!nzchar(raw)) return(RETURN_TRACE_KINDS)
  k <- unique(trimws(strsplit(raw, ",", fixed = TRUE)[[1]]))
  k <- k[nzchar(k)]
  bad <- setdiff(k, RETURN_TRACE_KINDS)
  if (length(bad))
    stop("TRACE_KINDS names kind(s) this trace does not have: ", paste(bad, collapse = ", "),
         ". The kinds are ", paste(RETURN_TRACE_KINDS, collapse = ", "), ".", call. = FALSE)
  if (!length(k)) stop("TRACE_KINDS is empty.", call. = FALSE)
  k
}
return_trace_parse_lines <- function(raw) {
  raw <- trimws(as.character(raw %||% ""))
  if (!nzchar(raw)) return(NULL)
  v <- trimws(strsplit(raw, ",", fixed = TRUE)[[1]])
  v <- v[nzchar(v)]
  n <- suppressWarnings(as.integer(v))
  if (!length(n) || any(is.na(n)) || any(n < 1L))
    stop("TRACE_LINES='", raw, "' is not a comma-separated list of line numbers.",
         call. = FALSE)
  unique(n)
}

# The rows in scope for tracing: the kinds asked for, on the return lines
# asked for. carried_over is never in scope.
return_trace_in_scope <- function(cands, kinds = RETURN_TRACE_KINDS, lines = NULL) {
  keep <- cands$KIND %in% kinds
  if (!is.null(lines)) keep <- keep & cands$RETURN_LINE %in% lines
  cands[keep, , drop = FALSE]
}

# Deterministic and a spread: ranked within (KIND, RETURN_LINE, MED_ABBR) by
# id and taken round-robin, so twelve patients show every kind on several
# lines and drugs rather than twelve LEN folds. A listed set bypasses it.
return_trace_sample <- function(cands, n, patids = NULL) {
  if (!is.null(patids) && length(patids))
    return(foldin_trace_check_patids(patids))
  n <- as.integer(n)
  if (is.na(n) || n < 1L) stop("TRACE_N must be a whole number of at least 1.", call. = FALSE)
  if (is.null(cands) || !nrow(cands)) return(character(0))
  # Only a traced kind is ever sampled: a carried-over drug is counted, and a
  # patient with nothing but one has nothing to show.
  cands <- cands[as.character(cands$KIND) %in% RETURN_TRACE_KINDS, , drop = FALSE]
  if (!nrow(cands)) return(character(0))
  d <- data.frame(PATID = as.character(cands$PATID), KIND = as.character(cands$KIND),
                  LINE = as.integer(cands$RETURN_LINE), MED_ABBR = as.character(cands$MED_ABBR),
                  stringsAsFactors = FALSE)
  # Kinds in the order the report explains them, not alphabetical: a fold,
  # then an own return, then the counter-example.
  d$K <- match(d$KIND, RETURN_TRACE_ALL_KINDS)
  d <- d[order(d$K, d$LINE, d$MED_ABBR, d$PATID, method = "radix"), , drop = FALSE]
  d <- d[!duplicated(d[, c("PATID", "KIND", "LINE", "MED_ABBR")]), , drop = FALSE]
  grp <- paste(d$KIND, d$LINE, d$MED_ABBR)
  d$rank <- stats::ave(seq_len(nrow(d)), grp, FUN = seq_along)
  d <- d[order(d$rank, d$K, d$LINE, d$MED_ABBR, d$PATID, method = "radix"), , drop = FALSE]
  utils::head(unique(d$PATID), n)
}

# Over every candidate row, never the sample. Counts per kind, per kind and
# return line, and per kind and drug, with the table's own totals beside them.
return_trace_summary <- function(cands, n_patients_total, n_lines_total) {
  cnt <- function(d) c(n_patients = length(unique(d$PATID)),
                       n_lines = nrow(unique(d[, c("PATID", "LOT_NUM"), drop = FALSE])),
                       n_returns = nrow(d))
  row <- function(kind, level, key, v) data.frame(
    kind = kind, level = level, key = key,
    n_patients = unname(v[["n_patients"]]), n_lines = unname(v[["n_lines"]]),
    n_returns = unname(v[["n_returns"]]), stringsAsFactors = FALSE)
  out <- list(row("LOT_LONG_FINAL", "all lines", "",
                  c(n_patients = as.numeric(n_patients_total),
                    n_lines = as.numeric(n_lines_total), n_returns = NA_real_)))
  d0 <- if (is.null(cands) || !nrow(cands))
    data.frame(PATID = character(0), LOT_NUM = integer(0), KIND = character(0),
               RETURN_LINE = integer(0), MED_ABBR = character(0), stringsAsFactors = FALSE)
  else cands
  for (k in RETURN_TRACE_ALL_KINDS) {
    d <- d0[d0$KIND == k, , drop = FALSE]
    out[[length(out) + 1L]] <- row(k, "all", "", cnt(d))
    for (l in sort(unique(d$RETURN_LINE)))
      out[[length(out) + 1L]] <- row(k, "by return line", paste0("LOT", l),
                                     cnt(d[d$RETURN_LINE == l, , drop = FALSE]))
    for (m in sort(unique(d$MED_ABBR)))
      out[[length(out) + 1L]] <- row(k, "by drug", m, cnt(d[d$MED_ABBR == m, , drop = FALSE]))
  }
  do.call(rbind, out)
}

# ---- The episode table ----------------------------------------------------------
# The fold-in trace's annotation, then the notes the other kinds add:
#
#   'RETURNED to LOT n after a k-day break (4.3)'   the own return's episode
#   'break follows: k days to the return'            the episode before it
#   'opens LOT n - back from LOT k, out of 4.8's scope'
#   'opens LOT n - LOT n-1 was opened by <type>, so no fold across it'
return_trace_annotate <- function(lines, episodes, tx, cands, p, subs = NULL) {
  .need_foldin()
  folds <- cands[cands$KIND == "fold", , drop = FALSE]
  ep <- foldin_trace_annotate(lines, episodes, tx, folds, p, subs = subs)
  own <- cands[cands$KIND == "own_return", , drop = FALSE]
  for (i in seq_len(nrow(own))) {
    pid <- as.character(own$PATID[i]); med <- as.character(own$MED_ABBR[i])
    ret <- .as_date(own$RETURN_DT[i]); pe <- .as_date(own$PREV_EP_END[i]); ps <- .as_date(own$PREV_EP_START[i])
    gap <- if (is.na(pe)) NA_integer_ else as.integer(ret - pe)
    hit <- ep$PATID == pid & ep$MAP_MED_TYPE == med & !is.na(ep$MAP_START_DT) & ep$MAP_START_DT == ret
    ep$note[hit] <- paste0("RETURNED to LOT ", own$LOT_NUM[i], " after a ",
                           if (is.na(gap)) "confirmed" else paste0(gap, "-day"), " break (4.3)")
    if (!is.na(ps)) {
      before <- ep$PATID == pid & ep$MAP_MED_TYPE == med & !is.na(ep$MAP_START_DT) & ep$MAP_START_DT == ps
      ep$note[before] <- paste0("break follows: ", if (is.na(gap)) "confirmed" else paste0(gap, " days"),
                                " to the return")
    }
  }
  op <- cands[cands$KIND == "opens_line", , drop = FALSE]
  for (i in seq_len(nrow(op))) {
    pid <- as.character(op$PATID[i]); med <- as.character(op$MED_ABBR[i])
    st <- .as_date(op$LOT_START_DT[i]); n <- as.integer(op$LOT_NUM[i])
    hit <- ep$PATID == pid & ep$MAP_MED_TYPE == med & !is.na(ep$MAP_START_DT) & ep$MAP_START_DT == st
    pt <- as.character(op$PREV_LINE_START_TYPE[i])
    ep$note[hit] <- if (!is.na(pt) && nzchar(pt) && pt != "MED")
      paste0("opens LOT ", n, " - LOT ", n - 1L, " was opened by ", pt, ", so no fold across it")
    else paste0("opens LOT ", n, " - back from LOT ", op$FROM_LOT[i], ", out of 4.8's scope")
  }
  ep
}

# ---- The narratives ----------------------------------------------------------------
# One paragraph per candidate row. A fold's is the fold-in trace's own. An own
# return's says where the drug was, the break, the return, what the line did,
# and what the reading before 30 Aug 2026 would have done - the same local
# reading the fold narrative makes, stated for the patient's earliest return
# only (the caveat foldin_trace_narrative explains). An opens_line row's says
# why the return opened a line and that the rule changed nothing there.
.own_cover_before <- function(e, base, start, elig, ret) {
  e_start <- .as_date(e$MAP_START_DT); e_med <- as.character(e$MAP_MED_TYPE)
  base_drugs <- strsplit(trimws(base), " ", fixed = TRUE)[[1]]
  base_drugs <- base_drugs[nzchar(base_drugs)]
  own <- base_drugs[vapply(base_drugs, function(m)
    any(e_med == m & e_start >= start & e_start <= elig), logical(1))]
  own_eps <- e[e_med %in% own & e_start >= start & e_start < ret, , drop = FALSE]
  own_end <- if (nrow(own_eps)) max(.as_date(own_eps$MAP_END_DT), na.rm = TRUE) else as.Date(NA)
  list(own = own, own_end = own_end)
}

return_trace_narrative <- function(row, lines, episodes, p, tx = NULL, subs = NULL,
                                   all_rows = NULL) {
  .need_foldin()
  kind <- as.character(row$KIND)
  pid <- as.character(row$PATID)
  ln <- lines[as.character(lines$PATID) == pid, , drop = FALSE]
  if (identical(kind, "fold")) {
    fr <- if (is.null(all_rows)) NULL else all_rows[all_rows$PATID == pid & all_rows$KIND == "fold", , drop = FALSE]
    return(foldin_trace_narrative(row, lines, episodes, p, tx = tx, subs = subs, all_folds = fr))
  }
  n <- as.integer(row$LOT_NUM); drug <- as.character(row$MED_ABBR)
  start <- .as_date(row$LOT_START_DT); ret <- .as_date(row$RETURN_DT); elig <- .as_date(row$ELIGIBLE_END)
  this <- ln[as.integer(ln$LOT_NUM) == n, , drop = FALSE]
  base <- if (nrow(this)) as.character(this$LOT_BASE_MEDS[1]) else ""
  end <- if (nrow(this)) .as_date(this$LOT_BASE_END_DT[1]) else as.Date(NA)
  reason <- if (nrow(this)) as.character(this$LOT_BASE_END_REASON[1]) else ""
  start_type <- as.character(row$LOT_START_TYPE %||% "MED")
  w <- if (identical(start_type, "CART")) p$cart else if (n == 1L) p$ind1 else p$indn
  e <- episodes[as.character(episodes$PATID) == pid, , drop = FALSE]
  e <- e[toupper(trimws(as.character(e$MAP_MED_CLASS))) != "STEROID", , drop = FALSE]
  k <- as.integer(ret - start)
  fmt <- function(d) if (is.na(d)) "(not in the read)" else format(d)

  if (identical(kind, "own_return")) {
    ps <- .as_date(row$PREV_EP_START); pe <- .as_date(row$PREV_EP_END)
    gap <- if (is.na(pe)) NA_integer_ else as.integer(ret - pe)
    gap_txt <- if (is.na(gap)) "a confirmed break (MAP_DISCON_FLG = 1 on the episode before it)"
               else paste0("a break of ", gap, " days (MAP_DISCON_FLG = 1: at least ",
                           if (is.null(p$gap) || is.na(p$gap)) "map_discon_gap_days" else p$gap,
                           " days with no supply)")
    cover <- .own_cover_before(e, base, start, elig, ret)
    own_txt <- if (length(cover$own)) paste(cover$own, collapse = " ") else "(none in the read)"
    # Where this patient's two histories part: the earliest return of any
    # kind the rule decided. A later one cannot be read locally.
    first_ret <- ret
    if (!is.null(all_rows) && nrow(all_rows)) {
      ar <- all_rows[all_rows$PATID == pid & all_rows$KIND %in% c("fold", "own_return"), , drop = FALSE]
      rd <- .as_date(ar$RETURN_DT); rd <- rd[!is.na(rd)]
      if (length(rd)) first_ret <- min(rd)
    }
    pre <- if (!is.na(first_ret) && ret > first_ret) {
      paste0("Before 30 Aug 2026 this return cannot be read from these tables alone: an ",
             "earlier return on ", format(first_ret), " is the first thing the rules decided ",
             "for this patient, and the line holding this one depends on what the older reading ",
             "would have made of that. A build of the same cohort with APPLY_OWN_RETURN_FOLD=FALSE ",
             "and APPLY_MAP_FOLDIN=FALSE, differenced against this one, is what settles it.")
    } else if (is.na(cover$own_end)) {
      paste0("Before 30 Aug 2026 the break released the drug, and this return would have ",
             "opened a new line on ", format(ret), ". The episodes read here show no cover ",
             "for LOT ", n, "'s regimen before it, so which end LOT ", n, " would have had ",
             "cannot be said from them: MED_ADD on ", format(ret - 1L), " if another of its ",
             "drugs still ran, or DISCONTINUATION on its run-out if none did.")
    } else if (ret > cover$own_end) {
      paste0("Before 30 Aug 2026 the break released the drug, and this return would have ",
             "opened a new line on ", format(ret), ". LOT ", n, "'s regimen (", own_txt,
             ") had run out on ", format(cover$own_end), ", before the return, so the return ",
             "would have confirmed that run-out (5.3): LOT ", n, " would have ended ",
             "DISCONTINUATION on ", format(cover$own_end), " and the next line would have ",
             "started on ", format(ret), " with ", drug, ".")
    } else {
      paste0("Before 30 Aug 2026 the break released the drug, and this return would have ",
             "been an added medication: LOT ", n, "'s regimen (", own_txt, ") was still covered on ",
             format(ret), " (cover ran to ", format(cover$own_end), "), so LOT ", n,
             " would have ended MED_ADD on ", format(ret - 1L), " and a new line would have ",
             "opened on ", format(ret), " with ", drug, ".")
    }
    return(paste0(
      drug, " is in LOT ", n, "'s own regimen (", base, "): it was dosed inside the line's ",
      w, "-day induction window. Its episode of ", fmt(ps), " to ", fmt(pe), " was followed by ",
      gap_txt, ", and ", drug, " came back on ", format(ret), ", ", k, " days after LOT ", n,
      " opened and outside the window (window ended ", format(elig), "). Under 4.3 a drug of ",
      "the line's own regimen never starts a line, so the return stayed in LOT ", n,
      ", which runs on over the break: LOT ", n, " is ", format(start), " to ", fmt(end),
      if (nzchar(reason)) paste0(" (", reason, ")") else "", ". ", pre))
  }

  if (identical(kind, "opens_line")) {
    from <- as.integer(row$FROM_LOT); pt <- as.character(row$PREV_LINE_START_TYPE %||% "")
    prev_meds <- as.character(row$PREV_BASE_MEDS %||% "")
    prev_meds <- if (is.na(prev_meds) || !nzchar(prev_meds)) "no drug" else prev_meds
    pl <- ln[as.integer(ln$LOT_NUM) == n - 1L, , drop = FALSE]
    pl_end <- if (nrow(pl)) .as_date(pl$LOT_BASE_END_DT[1]) else as.Date(NA)
    pl_reason <- if (nrow(pl)) as.character(pl$LOT_BASE_END_REASON[1]) else ""
    ps <- .as_date(row$PREV_EP_START); pe <- .as_date(row$PREV_EP_END)
    away <- if (is.na(pe)) "" else paste0(" Its previous episode ran ", fmt(ps), " to ", fmt(pe),
                                          ", ", as.integer(ret - pe), " days before.")
    fl <- if (is.na(from)) NULL else ln[as.integer(ln$LOT_NUM) == from, , drop = FALSE]
    from_meds <- if (!is.null(fl) && nrow(fl)) as.character(fl$LOT_BASE_MEDS[1]) else ""
    from_txt <- paste0(drug, " was last in LOT ", if (is.na(from)) "?" else from, "'s regimen",
                       if (nzchar(from_meds) && !is.na(from_meds)) paste0(" (", from_meds, ")") else "",
                       ".")
    why <- if (!is.na(pt) && nzchar(pt) && pt != "MED")
      paste0("LOT ", n - 1L, " was opened by a transplant or CAR-T (", pt, ") and carried ",
             prev_meds, ". 4.8 refuses a fold across a procedure that opened a line, so when ",
             drug, " came back on ", format(ret), " it was an added medication, not a returning ",
             "regimen drug: LOT ", n - 1L, " ended ", if (nzchar(pl_reason)) pl_reason else "",
             " on ", fmt(pl_end), " and ", drug, " opened LOT ", n, " (", base, ").")
    else
      paste0("LOT ", n - 1L, " (", prev_meds, ") did not carry it. 4.8's fold set is the ",
             "immediately previous line's regimen only, so a drug from further back is out of ",
             "its scope and 4.3 does not hold it either: when ", drug, " came back on ", format(ret),
             " it opened LOT ", n, " like any other new agent (", base, "); LOT ", n - 1L,
             " ended ", if (nzchar(pl_reason)) pl_reason else "", " on ", fmt(pl_end), ".")
    return(paste0(from_txt, away, " ", why, " The 30 Aug 2026 rules changed nothing here: ",
                  "this return opened a line under the earlier reading too."))
  }

  paste0(drug, " in LOT ", n, ": ", kind, " on ", format(ret), ".")
}

# ---- Rendering --------------------------------------------------------------------
RETURN_TRACE_KIND_LABEL <- c(
  fold = "Folded into the line it returned in (4.8)",
  own_return = "Came back to its own line after a break (4.3)",
  opens_line = "Came back and opened a line (outside 4.8)",
  carried_over = "Carried over inside the induction window (no rule involved)")

return_trace_patient_md <- function(shown_id, rows_p, lines_p, episodes_p, ann_p, p,
                                    tx_p = NULL, subs = NULL) {
  .need_foldin()
  ln <- c(paste0("## Patient ", shown_id), "")
  if (is.null(lines_p) || !nrow(lines_p))
    return(c(ln, "This id has no line in LOT_LONG_FINAL under this prefix. Check the id.", ""))
  traced <- if (is.null(rows_p)) rows_p else rows_p[rows_p$KIND %in% RETURN_TRACE_KINDS, , drop = FALSE]
  if (is.null(traced) || !nrow(traced)) {
    ln <- c(ln, paste0("No returning drug found for this patient: no regimen drug of any line ",
                       "carries a fold's, an own return's or a line-opening return's signature. ",
                       "Listed by request; the lines and episodes are shown as they are."), "")
  } else {
    ord <- order(.as_date(traced$RETURN_DT), as.character(traced$KIND),
                 as.character(traced$MED_ABBR), method = "radix")
    for (i in ord) {
      r <- traced[i, , drop = FALSE]
      ln <- c(ln, paste0("**", RETURN_TRACE_KIND_LABEL[[as.character(r$KIND)]], " - ",
                         as.character(r$MED_ABBR), ", LOT ", as.integer(r$LOT_NUM), ".** ",
                         return_trace_narrative(r, lines_p, episodes_p, p, tx = tx_p, subs = subs,
                                                all_rows = rows_p)), "")
    }
  }
  ln <- c(ln, "Lines (LOT_LONG_FINAL):", "",
          foldin_trace_md_table(lines_p, TRACE_LINE_COLS), "",
          "Episodes (MAP_STACKED) and transplant events, in date order:", "",
          foldin_trace_md_table(ann_p, TRACE_EPISODE_COLS), "")
  ln
}

return_trace_markdown <- function(run_id, pfx, p, summary, patients_sections, masked,
                                  kinds = RETURN_TRACE_KINDS, lines = NULL,
                                  n_candidates = NA, n_traced = length(patients_sections),
                                  listed = FALSE, source_note = NULL) {
  .need_foldin()
  gap <- if (is.null(p$gap) || is.na(p$gap)) "map_discon_gap_days" else paste0(p$gap, " days")
  ln <- c(paste0("# Returning-drug trace - ", pfx),
          "",
          paste0("Run `", run_id, "`. What the rules adopted on 30 Aug 2026 (LOT_RULES.md ",
                 "4.3 and 4.8) did with drugs that came back, on the patients they touched: ",
                 "raw MAP episodes beside the final lines, the returns marked."),
          "",
          if (!is.null(source_note)) c(source_note, "") else character(0),
          if (isTRUE(masked))
            paste0("Patient ids are MASKED to their last six characters, as the QC report ",
                   "masks them. To look a patient up, run the trace without TRACE_MASK_PATID.")
          else
            paste0("Patient ids are NOT masked. This file carries patient identifiers and ",
                   "stays inside the study environment; it exists so each patient can be ",
                   "looked up in the warehouse."),
          "",
          "Three kinds of return are traced, and a fourth is counted:",
          "",
          paste0("- **fold (4.8)** - a drug of the previous line, back after exactly one new ",
                 "agent opened the next line: it JOINED that line's regimen instead of ",
                 "starting one. Signature: in line n's regimen, in line n-1's, no episode ",
                 "inside line n's induction window, an episode inside line n after it."),
          paste0("- **own return (4.3)** - a drug of the line's own regimen, back after a ",
                 "confirmed break of its own (", gap, " or more with no supply): the line ran ",
                 "on over the break. Before the rule the break released the drug and the ",
                 "return opened a new line - a 1L drug back after a holiday made a 2L that ",
                 "no longer exists. Signature: an episode inside the window, and an episode ",
                 "inside the line after it whose preceding episode carries MAP_DISCON_FLG = 1."),
          paste0("- **opened a line** - a drug from an earlier line that came back and opened ",
                 "a line, which neither rule prevents: it was two or more lines back (4.8's ",
                 "fold set is the immediately previous line only), or a transplant or CAR-T ",
                 "opened the line before it (4.8 refuses a fold across a procedure). The ",
                 "counter-example, so a reader sees where the rules stop."),
          paste0("- **carried over** (counted only) - a previous-line drug dosed inside the ",
                 "next line's induction window: an ordinary regimen drug of both lines. Not ",
                 "a return, and not a fold - the window is why."),
          "",
          paste0("RETURN_LINE is the line a return belongs to for the 2L question: the line a ",
                 "fold or an own return sits in, and the line BEFORE the one a returning drug ",
                 "opened. So \"drugs that came back in 2L\" is RETURN_LINE = 2: folds into ",
                 "LOT 2, own returns inside LOT 2, and returns after LOT 2 that opened LOT 3; ",
                 "own returns inside LOT 1 are the ones that would have made a 2L before the rule."),
          "",
          paste0("Windows as the run recorded them: LOT1 ", p$ind1, " days, later lines ", p$indn,
                 ", CAR-T ", p$cart, ". A permissible substitute and the drug it replaces are ",
                 "one agent in every test here (4.4). Each paragraph also says what the reading ",
                 "before 30 Aug 2026 would have made of the return - a local reading of these ",
                 "tables, stated for the FIRST return the rules decided in a patient; a later ",
                 "one says that it cannot be read locally. A build of the same cohort with ",
                 "APPLY_MAP_FOLDIN=FALSE and APPLY_OWN_RETURN_FOLD=FALSE, differenced against ",
                 "this one, is what settles an alternative history."),
          "",
          paste0("Traced: kinds ", paste(kinds, collapse = ", "),
                 if (is.null(lines)) ", every return line" else paste0(", return line(s) ", paste(lines, collapse = ", ")),
                 ". ",
                 if (is.na(n_candidates)) "" else paste0(n_candidates, " patient(s) carry a return in scope. "),
                 n_traced, " traced",
                 if (isTRUE(listed)) " (listed by TRACE_PATIDS)" else " (a round-robin sample over kind, line and drug)",
                 "."),
          "",
          "## Summary (over every return in the run, not the sample)", "",
          foldin_trace_md_table(summary), "")
  for (s in patients_sections) ln <- c(ln, s)
  ln
}
