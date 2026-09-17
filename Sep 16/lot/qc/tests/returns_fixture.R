# The fixture patients behind the returning-drug trace's suite and its
# rendered example: one patient per shape the trace has to tell apart, on
# the published-table columns the exec harness knows. Sourced by
# tests/test_trace_returns.R and by trace_returns_example.R, so the example
# the study team reads is rendered from exactly the rows the suite holds the
# queries to.
#
# Windows as SETTINGS below says: LOT1 60 days, later lines 30, CAR-T 45; a
# break is 90 days or more.

RETURNS_SETTINGS <- paste0(
  "allo_lot_span=single_day|apply_cart_induction_rule=TRUE|",
  "belantamab_med_abbr=BELA|cart_consolidation_days=45|",
  "catalog=hive_metastore|cdm_schema=clnprw_optum|censor_at_disenrollment=FALSE|",
  "codelist_dir=/mnt/code/codelist|dsn=RWDE|induction_window_days=60|",
  "lot_discon_confirm_days=90|lot_n_induction_window_days=30|",
  "map_discon_gap_days=90|max_lot=5|",
  "medical_day_supply=28|melp_exposure_days=30|",
  "melp_med_abbr=MELP|melp_simple_course_days=28|",
  "sct_auto_gap_days=60|sct_auto_window_days=13|sct_tandem_days=180|",
  "tbl_med_diag=med_diagnosis|tbl_med_proc=med_procedure|tbl_medical=medical|",
  "tbl_rx=rx|use_quarterly_tables=TRUE|apply_melp_rule=simplified|",
  "apply_map_foldin=TRUE|apply_own_return_fold=TRUE|",
  "cohort_status_table=")

rf_fin <- function(pat, n, start, type, meds, end, reason = "STUDY_END",
                   discon = NA, add_med = NA, add_dt = NA, auto_max = NA) list(
  PATID = pat, LOT_NUM = n, LOT_START_DT = start, LOT_START_TYPE = type,
  LOT_BASE_MEDS = meds,
  LOT_MED_CNT = if (nzchar(meds)) length(strsplit(meds, " ")[[1]]) else 0L,
  LOT_BASE_DISCON_DT = discon, LOT_BASE_1ST_ADD_MED = add_med, LOT_BASE_1ST_ADD_MED_DT = add_dt,
  LOT_BASE_END_DT = end, LOT_BASE_END_REASON = reason,
  LOT_BASE_LENGTH = as.integer(as.Date(end) - as.Date(start)) + 1L,
  LOT_BASE_END_DT_CE_SENS = end, LOT_BASE_END_REASON_CE_SENS = reason, LOT_TX_AUTO_MAX_DT = auto_max)
rf_ep <- function(pat, med, start, end, class = "NOVEL", discon = 0L, cnt = 1L) list(
  PATID = pat, MAP_MED_ABBR = med, MAP_MED_TYPE = med, MAP_MED_CLASS = class,
  MAP_START_DT = start, MAP_END_DT = end, MAP_DISCON_FLG = discon,
  MAP_MED_RUNOUT_DT = end, MAP_RX_RUNOUT_DT = NA, ELIGIBLE_END = end, MAP_CNT = cnt)
rf_auto <- function(pat, dt) list(PATID = pat, TX_DT = dt)
rf_subs <- function(orig, subst) list(original_med = orig, substitute_med = subst)
rf_allo <- function(pat, dt, type) list(PATID = pat, TX_DT = dt, SCT_TYPE = type)

# The patients.
#
# R000001  fold (4.8): 1L BORT LEN DEX; CARF opens 2L on 2020-07-01; LEN back
#          2020-08-15, after 2L's 30-day window (ended 2020-07-30) - joined 2L.
# R000002  own return in 1L (4.3): 1L LEN DEX from 2020-01-01; LEN runs out
#          2020-04-30, nothing for 214 days, LEN back 2020-11-30 - still 1L.
#          Before the rule this made a 2L on 2020-11-30.
# R000003  own return in 2L (4.3): 1L BORT DEX; POM opens 2L 2020-09-01 with
#          DEX; POM runs out 2020-12-15, back 2021-05-01 - still 2L.
# R000004  opens a line across a transplant: 1L BORT LEN, with an autologous
#          transplant on 2020-02-15 that belongs to line 1 and a SECOND on
#          2020-09-01, 199 days later, past sct_tandem_days. 3.4: line 1's
#          first AUTO never ends line 1; the second does, the day before it, so
#          1L ends 2020-08-31 SCT_AUTO and 2L opens 2020-09-01 with no drug.
#          Not a run-out: LEN comes back in December, and under
#          apply_own_return_fold=TRUE its own gap does not break its chain
#          (5.2), so line 1 has no run-out for a lone transplant to follow.
#          LEN back 2020-12-01 - 4.8 refuses a fold across a procedure that
#          opened a line, so LEN ended 2L and opened 3L.
# R000005  opens a line from two lines back: 1L BORT LEN; CARF DEX opens 2L;
#          POM opens 3L; LEN back 2021-09-01 after the 3L window; 2L did not
#          carry LEN, so LEN is out of 4.8's scope and opened 4L.
# R000007  melphalan opens a line (4.7): 1L LEN MELP; the LEN runs out; a short
#          MELP course 2020-12-01..2020-12-28 with DARA starting inside it
#          opens 2L on the MELPHALAN's first day - the one previous-line drug
#          4.3 exempts.
# R000008  a drug two lines back arrives inside such a course: 1L BORT LEN;
#          CARF 2L; POM 3L; a short MELP course opens 4L on 2021-08-25 and LEN
#          arrives 2021-09-01 while it still covers, so 4L is dated on the
#          melphalan rather than on LEN.
# R000006  carried over: 1L LEN DEX; CARF opens 2L 2020-07-01 while LEN is
#          dosed inside 2L's window (2020-07-10) - an ordinary regimen drug of
#          both lines, counted and not traced.
RETURNS_FIXTURE <- list(
  final = list(
    rf_fin("R000001", 1L, "2020-01-01", "MED", "BORT LEN", "2020-06-30", "MED_ADD",
           add_med = "CARF", add_dt = "2020-07-01"),
    rf_fin("R000001", 2L, "2020-07-01", "MED", "CARF LEN", "2021-01-31", "STUDY_END"),
    rf_fin("R000002", 1L, "2020-01-01", "MED", "LEN", "2021-03-31", "DISCONTINUATION",
           discon = "2021-03-31"),
    rf_fin("R000003", 1L, "2020-01-01", "MED", "BORT", "2020-08-31", "MED_ADD",
           add_med = "POM", add_dt = "2020-09-01"),
    rf_fin("R000003", 2L, "2020-09-01", "MED", "POM", "2021-08-31", "STUDY_END"),
    rf_fin("R000004", 1L, "2020-01-01", "MED", "BORT LEN", "2020-08-31", "SCT_AUTO",
           auto_max = "2020-02-15"),
    rf_fin("R000004", 2L, "2020-09-01", "SCT_AUTO", "", "2020-11-30", "MED_ADD",
           add_med = "LEN", add_dt = "2020-12-01"),
    rf_fin("R000004", 3L, "2020-12-01", "MED", "LEN", "2021-06-30", "STUDY_END"),
    rf_fin("R000005", 1L, "2020-01-01", "MED", "BORT LEN", "2020-06-30", "MED_ADD",
           add_med = "CARF", add_dt = "2020-07-01"),
    rf_fin("R000005", 2L, "2020-07-01", "MED", "CARF", "2021-01-31", "MED_ADD",
           add_med = "POM", add_dt = "2021-02-01"),
    rf_fin("R000005", 3L, "2021-02-01", "MED", "POM", "2021-08-31", "MED_ADD",
           add_med = "LEN", add_dt = "2021-09-01"),
    rf_fin("R000005", 4L, "2021-09-01", "MED", "LEN", "2022-03-31", "STUDY_END"),
    rf_fin("R000006", 1L, "2020-01-01", "MED", "LEN", "2020-06-30", "MED_ADD",
           add_med = "CARF", add_dt = "2020-07-01"),
    rf_fin("R000006", 2L, "2020-07-01", "MED", "CARF LEN", "2021-01-31", "STUDY_END"),
    rf_fin("R000007", 1L, "2020-01-01", "MED", "LEN MELP", "2020-11-30", "MED_ADD",
           add_med = "MELP", add_dt = "2020-12-01"),
    rf_fin("R000007", 2L, "2020-12-01", "MED", "DARA MELP", "2021-06-30", "STUDY_END"),
    rf_fin("R000008", 1L, "2020-01-01", "MED", "BORT LEN", "2020-06-30", "MED_ADD",
           add_med = "CARF", add_dt = "2020-07-01"),
    rf_fin("R000008", 2L, "2020-07-01", "MED", "CARF", "2021-01-31", "MED_ADD",
           add_med = "POM", add_dt = "2021-02-01"),
    rf_fin("R000008", 3L, "2021-02-01", "MED", "POM", "2021-08-24", "MED_ADD",
           add_med = "MELP", add_dt = "2021-08-25"),
    rf_fin("R000008", 4L, "2021-08-25", "MED", "LEN MELP", "2022-03-31", "STUDY_END")),
  map = list(
    # R000001
    rf_ep("R000001", "BORT", "2020-01-01", "2020-07-31", discon = 1L, cnt = 7L),
    rf_ep("R000001", "LEN", "2020-01-05", "2020-04-30", discon = 1L, cnt = 4L),
    rf_ep("R000001", "DEX", "2020-01-01", "2020-06-30", class = "STEROID", cnt = 6L),
    rf_ep("R000001", "CARF", "2020-07-01", "2020-12-31", cnt = 6L),
    rf_ep("R000001", "LEN", "2020-08-15", "2021-01-31", cnt = 6L),
    rf_ep("R000001", "DEX", "2020-07-01", "2021-01-31", class = "STEROID", cnt = 7L),
    # R000002
    rf_ep("R000002", "LEN", "2020-01-01", "2020-04-30", discon = 1L, cnt = 4L),
    rf_ep("R000002", "DEX", "2020-01-01", "2020-04-30", class = "STEROID", discon = 1L, cnt = 4L),
    rf_ep("R000002", "LEN", "2020-11-30", "2021-03-31", discon = 1L, cnt = 4L),
    rf_ep("R000002", "DEX", "2020-11-30", "2021-03-31", class = "STEROID", discon = 1L, cnt = 4L),
    # R000003
    rf_ep("R000003", "BORT", "2020-01-01", "2020-09-30", discon = 1L, cnt = 9L),
    rf_ep("R000003", "DEX", "2020-01-01", "2020-06-15", class = "STEROID", cnt = 6L),
    rf_ep("R000003", "POM", "2020-09-01", "2020-12-15", discon = 1L, cnt = 4L),
    rf_ep("R000003", "DEX", "2020-09-01", "2020-12-15", class = "STEROID", cnt = 4L),
    rf_ep("R000003", "POM", "2021-05-01", "2021-08-31", cnt = 4L),
    rf_ep("R000003", "DEX", "2021-05-01", "2021-08-31", class = "STEROID", cnt = 4L),
    # R000004
    rf_ep("R000004", "BORT", "2020-01-01", "2020-05-31", discon = 1L, cnt = 5L),
    rf_ep("R000004", "LEN", "2020-01-01", "2020-06-30", discon = 1L, cnt = 6L),
    rf_ep("R000004", "DEX", "2020-01-01", "2020-06-30", class = "STEROID", cnt = 6L),
    rf_ep("R000004", "LEN", "2020-12-01", "2021-06-30", cnt = 7L),
    # R000005
    rf_ep("R000005", "BORT", "2020-01-01", "2020-07-31", discon = 1L, cnt = 7L),
    rf_ep("R000005", "LEN", "2020-01-01", "2020-04-30", discon = 1L, cnt = 4L),
    rf_ep("R000005", "CARF", "2020-07-01", "2021-02-28", discon = 1L, cnt = 8L),
    rf_ep("R000005", "DEX", "2020-07-01", "2021-01-31", class = "STEROID", cnt = 7L),
    rf_ep("R000005", "POM", "2021-02-01", "2021-09-30", discon = 1L, cnt = 8L),
    rf_ep("R000005", "LEN", "2021-09-01", "2022-03-31", cnt = 7L),
    # R000006
    rf_ep("R000006", "LEN", "2020-01-01", "2020-06-30", cnt = 6L),
    rf_ep("R000006", "DEX", "2020-01-01", "2020-06-30", class = "STEROID", cnt = 6L),
    rf_ep("R000006", "CARF", "2020-07-01", "2020-12-31", cnt = 6L),
    rf_ep("R000006", "LEN", "2020-07-10", "2021-01-31", cnt = 7L),
    rf_ep("R000006", "DEX", "2020-07-01", "2021-01-31", class = "STEROID", cnt = 7L),
    # R000007
    rf_ep("R000007", "LEN", "2020-01-01", "2020-12-31", discon = 1L, cnt = 12L),
    rf_ep("R000007", "MELP", "2020-02-01", "2020-02-28", discon = 1L, cnt = 1L),
    rf_ep("R000007", "MELP", "2020-12-01", "2020-12-28", cnt = 1L),
    rf_ep("R000007", "DARA", "2020-12-10", "2021-06-30", cnt = 7L),
    # R000008
    rf_ep("R000008", "BORT", "2020-01-01", "2020-07-31", discon = 1L, cnt = 7L),
    rf_ep("R000008", "LEN", "2020-01-01", "2020-04-30", discon = 1L, cnt = 4L),
    rf_ep("R000008", "CARF", "2020-07-01", "2021-02-28", discon = 1L, cnt = 8L),
    rf_ep("R000008", "POM", "2021-02-01", "2021-08-31", discon = 1L, cnt = 7L),
    rf_ep("R000008", "MELP", "2021-08-25", "2021-09-21", cnt = 1L),
    rf_ep("R000008", "LEN", "2021-09-01", "2022-03-31", cnt = 7L)),
  allo = list(),
  # Two autologous transplants, 199 days apart - past sct_tandem_days, so not a
  # tandem. LOT_RULES.md 3.4: line 1's FIRST auto never ends line 1, and what
  # ends it is the SECOND. That is what has to open LOT 2 here. A single auto
  # could not: it would only open a line where line 1 "has already ended on its
  # own", and line 1 cannot - under apply_own_return_fold=TRUE a drug's own gap
  # no longer breaks its chain (5.2), so LEN's return in December keeps LOT 1's
  # cover alive and there is no run-out for the transplant to follow.
  auto = list(rf_auto("R000004", "2020-02-15"), rf_auto("R000004", "2020-09-01")),
  subs = list())

RETURNS_FIXTURE_TOTALS <- list(N_PATIENTS = 8, N_LINES = 20)

# ---- The fixture has to be a build the engine could have produced -----------------
# These rows stand in for PUBLISHED tables, so nothing here is checked by the
# engine's own asserts - and a shape the engine cannot produce teaches a reader
# of the rendered example something untrue. The one gate that is easy to break
# by hand, and was: MED_ADD ends a line only when the added agent arrives at or
# before the line's run-out (engine/R/steps/06_lot1_end.R -
# 'LOT1_BASE_DISCON_DT IS NULL OR LOT1_BASE_1ST_ADD_MED_DT <= LOT1_BASE_DISCON_DT').
# Past a confirmed run-out the branch is DISCONTINUATION at the run-out instead,
# because the added agent is itself what confirms it (LOT_RULES.md 5.3).
#
# A line has a run-out only where EVERY base agent has discontinued - 5.1's
# "the line has run out when its last base agent has" - so a base agent whose
# last episode in the line carries no MAP_DISCON_FLG leaves the line with none,
# and the gate's IS NULL arm lets MED_ADD through.
#
# Returns a character vector of defects, empty where the fixture is clean.
returns_fixture_defects <- function(data = RETURNS_FIXTURE) {
  fin <- data$final; eps <- data$map
  d <- function(x) as.Date(as.character(x))
  out <- character(0)
  for (r in fin) {
    add <- r$LOT_BASE_1ST_ADD_MED_DT
    if (is.null(add) || length(add) != 1L || is.na(add)) next
    meds <- strsplit(trimws(as.character(r$LOT_BASE_MEDS)), " ")[[1]]
    meds <- meds[nzchar(meds)]
    if (!length(meds)) next
    cover <- as.Date(NA); open <- FALSE
    for (md in meds) {
      e <- Filter(function(x) identical(as.character(x$PATID), as.character(r$PATID)) &&
                    identical(as.character(x$MAP_MED_TYPE), md) &&
                    d(x$MAP_START_DT) >= d(r$LOT_START_DT) &&
                    d(x$MAP_START_DT) <= d(r$LOT_BASE_END_DT), eps)
      if (!length(e)) next
      e <- e[order(vapply(e, function(x) as.numeric(d(x$MAP_START_DT)), numeric(1)))]
      cover <- max(c(cover, vapply(e, function(x) d(x$MAP_END_DT), as.Date(NA))), na.rm = TRUE)
      if (!identical(as.integer(e[[length(e)]]$MAP_DISCON_FLG), 1L)) open <- TRUE
    }
    if (open || is.na(cover)) next          # no run-out: the gate's IS NULL arm
    if (d(add) > cover)
      out <- c(out, sprintf(
        "%s LOT %s records %s with the added agent on %s, past a run-out on %s - the engine would have ended it DISCONTINUATION on %s",
        r$PATID, r$LOT_NUM, as.character(r$LOT_BASE_END_REASON), as.character(add),
        as.character(cover), as.character(cover)))
  }
  # ...and the other way a hand-written line goes wrong: DISCONTINUATION at a
  # run-out the chain never reaches. Under apply_own_return_fold=TRUE a drug's
  # OWN gap no longer breaks its chain (LOT_RULES.md 5.2) - the episode after it
  # belongs to the line it left - so a base agent with a later episode keeps the
  # line's cover alive and the line does not end on its own. Only a different
  # agent that would end the line breaks it: not a drug of this regimen, not a
  # steroid, and transplant and CAR-T are not read here at all.
  for (r in fin) {
    if (!identical(as.character(r$LOT_BASE_END_REASON), "DISCONTINUATION")) next
    meds <- strsplit(trimws(as.character(r$LOT_BASE_MEDS)), " ")[[1]]
    meds <- meds[nzchar(meds)]
    if (!length(meds)) next
    endd <- d(r$LOT_BASE_END_DT)
    mine <- Filter(function(x) identical(as.character(x$PATID), as.character(r$PATID)), eps)
    breaker <- vapply(mine, function(x)
      !(as.character(x$MAP_MED_TYPE) %in% meds) &&
        !identical(toupper(as.character(x$MAP_MED_CLASS)), "STEROID"), logical(1))
    for (x in mine) {
      if (!(as.character(x$MAP_MED_TYPE) %in% meds)) next
      st <- d(x$MAP_START_DT)
      if (is.na(st) || st <= endd) next
      cut <- any(vapply(mine[breaker], function(y) {
        ys <- d(y$MAP_START_DT); !is.na(ys) && ys > endd && ys < st }, logical(1)))
      if (!cut)
        out <- c(out, sprintf(
          "%s LOT %s records DISCONTINUATION on %s, but %s has a later episode on %s with no line-ending agent between them - 5.2 chains its cover over that gap, so the line never ran out",
          r$PATID, r$LOT_NUM, as.character(endd), as.character(x$MAP_MED_TYPE),
          as.character(st)))
    }
  }
  out
}

# ---- Running the queries on the fixture --------------------------------------------
# The same row runner test_foldin_trace.R uses, as a function both the suite
# and the example renderer can call: the queries transpiled to DuckDB and run
# against the fixture rows, one frame back per query. NULL where the runner
# is missing, "skip" where duckdb or sqlglot is not installed.
returns_run_rows <- function(queries, data, root) {
  py <- file.path(root, "tests", "run_duckdb_rows.py")
  if (!file.exists(py)) return(NULL)
  schema <- EXEC_SCHEMA
  schema$map$columns <- c(schema$map$columns, MAP_CNT = "INTEGER")
  sch <- paste(vapply(names(schema), function(k) {
    cols <- schema[[k]]$columns
    sprintf('"%s":{"columns":{%s}}', schema[[k]]$table,
            paste(sprintf('"%s":"%s"', names(cols), cols), collapse = ","))
  }, character(1)), collapse = ",")
  keys <- intersect(names(schema), names(data))
  dat <- paste(vapply(keys, function(k)
    sprintf('"%s":[%s]', schema[[k]]$table, .exec_json_rows(data[[k]], schema[[k]]$columns)),
    character(1)), collapse = ",")
  qs <- paste(vapply(names(queries), function(id)
    sprintf('{"id":"%s","sql":"%s"}', id, .exec_json_str(queries[[id]])), character(1)),
    collapse = ",")
  spec <- sprintf('{"tables":{%s},"data":{%s},"queries":[%s]}', sch, dat, qs)
  f <- tempfile(fileext = ".json"); writeLines(spec, f)
  out <- suppressWarnings(system2("python3", c(shQuote(py), shQuote(f)),
                                  stdout = TRUE, stderr = TRUE))
  if (!length(out)) return(NULL)
  if (grepl("^SKIP", out[1])) return("skip")
  res <- list(); id <- NULL; buf <- character(0)
  flush <- function() {
    if (is.null(id)) return()
    if (length(buf) && grepl("^!! ", buf[1])) {
      res[[id]] <<- structure(list(), error = sub("^!! ", "", buf[1]))
    } else if (!length(buf)) {
      res[[id]] <<- structure(list(), error = "no header")
    } else {
      cols <- strsplit(buf[1], "\t", fixed = TRUE)[[1]]
      rows <- lapply(buf[-1], function(l) {
        v <- strsplit(l, "\t", fixed = TRUE)[[1]]; length(v) <- length(cols); v[is.na(v)] <- ""; v
      })
      d <- as.data.frame(do.call(rbind, c(list(character(0)), rows)), stringsAsFactors = FALSE)
      if (!length(rows)) d <- as.data.frame(matrix(character(0), 0, length(cols)), stringsAsFactors = FALSE)
      names(d) <- cols
      # Empty strings are NULLs on the way back; the stack reads dates from them.
      for (cn in names(d)) d[[cn]][d[[cn]] == ""] <- NA
      res[[id]] <<- d
    }
  }
  for (l in out) {
    if (grepl("^== ", l)) { flush(); id <- sub("^== ", "", l); buf <- character(0) }
    else buf <- c(buf, l)
  }
  flush()
  res
}

# The whole trace, run on a fixture and rendered: what trace_returns.R does
# after its reads, without a connection. Returns the markdown lines and the
# frames behind them, or NULL / "skip" as returns_run_rows does.
returns_render_fixture <- function(data, totals, p, root, run_id = "fixture",
                                   pfx = "example_", n = 12L, kinds = RETURN_TRACE_KINDS,
                                   lines = NULL, source_note = NULL) {
  qs <- return_trace_queries(EXEC_TABLES, p)
  ids_all <- unique(vapply(data$final, function(r) as.character(r$PATID), character(1)))
  rr <- returns_run_rows(c(qs, list(
    lines = foldin_trace_lines_sql(EXEC_TABLES, ids_all, p),
    eps = foldin_trace_episodes_sql(EXEC_TABLES, ids_all),
    tx = foldin_trace_tx_sql(EXEC_TABLES, ids_all),
    subs = foldin_trace_subs_sql(EXEC_TABLES))), data, root)
  if (is.null(rr) || identical(rr, "skip")) return(rr)
  for (id in names(rr)) if (!is.null(attr(rr[[id]], "error")))
    stop("query '", id, "' did not run on the fixture: ", attr(rr[[id]], "error"), call. = FALSE)
  cands <- return_trace_stack(rr[RETURN_TRACE_ALL_KINDS])
  summary <- return_trace_summary(cands, totals$N_PATIENTS, totals$N_LINES)
  scope <- return_trace_in_scope(cands, kinds, lines)
  ids <- return_trace_sample(scope, n)
  lines_df <- rr$lines; eps <- rr$eps; tx <- rr$tx; subs <- rr$subs
  rows <- cands[cands$PATID %in% ids, , drop = FALSE]
  ann <- return_trace_annotate(lines_df, eps, tx, rows, p, subs = subs)
  sections <- lapply(ids, function(id) return_trace_patient_md(
    id, rows[rows$PATID == id, , drop = FALSE],
    lines_df[as.character(lines_df$PATID) == id, , drop = FALSE],
    eps[as.character(eps$PATID) == id, , drop = FALSE],
    ann[as.character(ann$PATID) == id, , drop = FALSE], p,
    tx_p = tx[as.character(tx$PATID) == id, , drop = FALSE], subs = subs))
  md <- return_trace_markdown(run_id, pfx, p, summary, sections, masked = FALSE,
                              kinds = kinds, lines = lines,
                              n_candidates = length(unique(scope$PATID)), n_traced = length(ids),
                              source_note = source_note)
  list(md = md, cands = cands, summary = summary, ids = ids, ann = ann, lines = lines_df)
}
