# =============================================================================
# cohort_sql.R -- turn a resolved cohort spec into Spark SQL
# -----------------------------------------------------------------------------
# Generates four things per run:
#
#   1. <ID>_INDEX_SEL   per-cohort index selection (index-anchored gates, then
#                       earliest QUALIFYING index date per patient)
#   2. COH_INDEX_UNION  the distinct (PATID, INDEX_DATE) set the LOT build
#                       consumes -- built ONCE for all requested cohorts
#   3. <ID>_COHORT      per-cohort final membership (adds LOT1-anchored gates)
#   4. COHORT_PLD       ONE patient-level dataset carrying every flag plus a
#                       COHORT_<ID> 0/1 column per cohort
#
# Plus a per-cohort attrition funnel.
#
# ---------------------------------------------------------------------------
# The one subtlety that makes this non-trivial
# ---------------------------------------------------------------------------
# Today's step 24 does "filter by IE, THEN take the earliest surviving index
# date" -- deliberately, so a patient whose earliest candidate index fails IE
# can still enter on a later one. That means the SELECTED INDEX DATE IS A
# FUNCTION OF THE COHORT DEFINITION. You cannot rank once and share the result
# across cohorts with different index gates.
#
# So ranking is done PER COHORT (cheap -- a window function over a materialized
# flag table, no claim re-scan), and the LOT build is fed the UNION of the
# selected (PATID, INDEX_DATE) pairs. When two cohorts pick the same index for
# a patient -- which is what happens today, since their index gates are
# identical -- the union collapses and the LOT build runs exactly once. When
# they diverge, the union grows and the numbers stay correct. Correct in both
# cases, cheap in the common one.
# =============================================================================

# ---- naming ----------------------------------------------------------------
# Every generated object is prefixed so it cannot collide with the existing
# pipeline's views (this folder adds objects; it renames nothing).
sql_obj <- function(cfg, name) {
  pre <- cfg$view_prefix %||% "coh_"
  if (nzchar(cfg$work_schema %||% "")) paste0(cfg$work_schema, ".", pre, name)
  else paste0(pre, name)
}

.and_block <- function(gates, indent = "            ") {
  if (!length(gates)) return("")
  paste0(indent, "AND ", vapply(gates, `[[`, character(1), "predicate"),
         collapse = "\n")
}

.gates_at <- function(spec, anchor) {
  Filter(function(g) identical(g$anchor, anchor), spec$resolved_gates)
}

# =============================================================================
# 1. Per-cohort index selection
# =============================================================================
# Mirrors pipeline_steps.R step 24 exactly (filter -> row_number -> rn = 1).
# For `overall` with default gates this is the same predicate set and the same
# window function as today, which is what makes Phase 1 a no-op numerically.
sql_index_sel <- function(spec, cfg) {
  g <- .gates_at(spec, "index")
  paste0(
    "CREATE OR REPLACE TEMPORARY VIEW ", sql_obj(cfg, paste0(spec$id, "_index_sel")), " AS\n",
    "-- ", spec$label, ": index-anchored IE funnel, then EARLIEST QUALIFYING index.\n",
    "-- Filter-then-rank (not rank-then-filter): a patient whose earliest\n",
    "-- candidate index fails IE may still enter on a later qualifying one.\n",
    "WITH filtered AS (\n",
    "  SELECT f.*\n",
    "  FROM ", cfg$index_flags, " f\n",
    "  WHERE 1 = 1\n",
    .and_block(g, "    "), "\n",
    "),\n",
    "ranked AS (\n",
    "  SELECT *, row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE) AS rn\n",
    "  FROM filtered\n",
    ")\n",
    "SELECT * FROM ranked WHERE rn = 1"
  )
}

# =============================================================================
# 2. Union of selected indexes -> the LOT build's input
# =============================================================================
# The LOT build (02_lot1.R / 03_lot2_5.R) currently reads ELIG_COH_FINAL. It
# needs one row per (PATID, INDEX_DATE); this view supplies exactly that for
# every requested cohort at once. Point the LOT build at this view via
# FINAL_TABLE_NAME and neither cohort has to run the other's build.
sql_index_union <- function(specs, cfg) {
  arms <- vapply(specs, function(s) paste0(
    "  SELECT PATID, INDEX_DATE FROM ", sql_obj(cfg, paste0(s$id, "_index_sel"))),
    character(1))
  paste0(
    "CREATE OR REPLACE TEMPORARY VIEW ", sql_obj(cfg, "index_union"), " AS\n",
    "-- Distinct (PATID, INDEX_DATE) across every requested cohort. This is the\n",
    "-- LOT build's input. Cohorts that agree on a patient's index collapse to\n",
    "-- one row, so the LOT build runs once for the common case.\n",
    "SELECT DISTINCT PATID, INDEX_DATE FROM (\n",
    paste(arms, collapse = "\n  UNION ALL\n"), "\n",
    ")"
  )
}

# =============================================================================
# 3. Per-cohort final membership
# =============================================================================
# A cohort with no LOT1-anchored gates (Overall) never touches the LOT1 tables:
# its membership view is a plain projection of the index selection. That keeps
# `--cohort=overall` runnable with the LOT build switched off entirely.
sql_cohort <- function(spec, cfg) {
  gl <- .gates_at(spec, "lot1")
  sel <- sql_obj(cfg, paste0(spec$id, "_index_sel"))
  head <- paste0(
    "CREATE OR REPLACE TEMPORARY VIEW ", sql_obj(cfg, paste0(spec$id, "_cohort")), " AS\n",
    "-- ", spec$label, ": final membership.\n")

  if (!length(gl)) {
    return(paste0(head,
      "-- No LOT1-anchored gates: membership is the index selection as-is.\n",
      "SELECT s.PATID, s.INDEX_DATE FROM ", sel, " s"))
  }

  paste0(head,
    "-- Index selection AND-ed with the LOT1-anchored gates.\n",
    "-- LEFT JOINs, deliberately: 'has a LOT1 start' is a declared GATE\n",
    "-- (has_lot1), not a join side-effect, so patients with no 1L regimen are\n",
    "-- dropped by a predicate the attrition funnel can count. Same row set as an\n",
    "-- INNER JOIN -- visible instead of silent.\n",
    "SELECT s.PATID, s.INDEX_DATE\n",
    "FROM ", sel, " s\n",
    "LEFT JOIN ", cfg$lot1_starts, " l1\n",
    "       ON l1.PATID = s.PATID AND l1.INDEX_DATE = s.INDEX_DATE\n",
    "LEFT JOIN ", cfg$lot1_flags, " n\n",
    "       ON n.PATID = s.PATID AND n.INDEX_DATE = s.INDEX_DATE\n",
    "WHERE 1 = 1\n",
    .and_block(gl, "  "))
}

# The lot1_from gate reads LOT1_START_DT, which lives on the LOT1 starts table
# rather than the flags table. Rewrite that one alias so the predicate binds to
# the right relation. (Kept explicit rather than adding a per-gate `relation`
# field: it is the single exception, and a silent mis-binding here would
# quietly widen the cohort.)
LOT1_STARTS_GATES <- c("lot1_from", "has_lot1")

bind_lot1_aliases <- function(spec) {
  for (i in seq_along(spec$resolved_gates)) {
    g <- spec$resolved_gates[[i]]
    if (g$id %in% LOT1_STARTS_GATES) {
      spec$resolved_gates[[i]]$predicate <- gsub("\\bn\\.", "l1.", g$predicate)
      spec$resolved_gates[[i]]$alias <- "l1"
    }
  }
  spec
}

# =============================================================================
# 4. The shared patient-level dataset
# =============================================================================
# ONE table, both cohorts. Every criterion is a column; membership is a column.
# Downstream code (dashboards, descriptives, TTE) stops re-deriving cohorts and
# just does `WHERE COHORT_NDMM = 1`.
#
# Grain: (PATID, INDEX_DATE) over the union of selected indexes -- one row per
# patient in the common case where the cohorts agree on the index.
sql_pld <- function(specs, cfg) {
  joins <- vapply(specs, function(s) paste0(
    "LEFT JOIN ", sql_obj(cfg, paste0(s$id, "_cohort")), " ", s$id, "\n",
    "       ON ", s$id, ".PATID = u.PATID AND ", s$id, ".INDEX_DATE = u.INDEX_DATE"),
    character(1))
  cols <- vapply(specs, function(s) paste0(
    "  CASE WHEN ", s$id, ".PATID IS NOT NULL THEN 1 ELSE 0 END AS ", s$flag_col),
    character(1))

  any_lot1 <- any(vapply(specs, needs_lot1, logical(1)))
  lot1_join <- if (any_lot1) paste0(
    "LEFT JOIN ", cfg$lot1_starts, " l1\n",
    "       ON l1.PATID = u.PATID AND l1.INDEX_DATE = u.INDEX_DATE\n",
    "LEFT JOIN ", cfg$lot1_flags, " n\n",
    "       ON n.PATID = u.PATID AND n.INDEX_DATE = u.INDEX_DATE\n") else ""
  # LEFT (not INNER) on purpose: the PLD is the SUPERSET. A patient who fails a
  # LOT1 gate, or has no 1L start at all, still gets a row -- with the failing
  # flag visible. Dropping them here would rebuild the exact problem this
  # design removes.
  lot1_cols <- if (any_lot1) paste0(
    "  l1.LOT1_START_DT,\n",
    "  n.CE_pre_lot1_12mo, n.CE_lot1_3mo_fu, n.NO_BELANTAMAB, n.NO_PRIOR_MM_TX,\n",
    "  n.NO_OTHER_CANCER_PRE_LOT1, n.NO_PREGNANCY,\n") else ""

  paste0(
    "CREATE OR REPLACE TEMPORARY VIEW ", sql_obj(cfg, "pld"), " AS\n",
    "-- The shared patient-level dataset: every criterion as a COLUMN, plus one\n",
    "-- membership column per cohort. Built once, read by every downstream job.\n",
    "SELECT\n",
    "  f.*,\n",
    lot1_cols,
    paste(cols, collapse = ",\n"), "\n",
    "FROM ", sql_obj(cfg, "index_union"), " u\n",
    "INNER JOIN ", cfg$index_flags, " f\n",
    "        ON f.PATID = u.PATID AND f.INDEX_DATE = u.INDEX_DATE\n",
    lot1_join,
    paste(joins, collapse = "\n")
  )
}

# Persist the PLD. One physical table is the contract every downstream consumer
# reads; without it each dashboard re-computes the flag DAG (the exact cost
# 06_ndmm_dashboard.R hit and worked around with its own materialize-and-repoint).
sql_pld_persist <- function(cfg) {
  tbl <- paste0(cfg$persist_schema, ".", cfg$pld_table)
  paste0(
    "CREATE OR REPLACE TABLE ", tbl, " AS\n",
    "SELECT * FROM ", sql_obj(cfg, "pld"))
}

# =============================================================================
# 5. Attrition funnel
# =============================================================================
# Cumulative distinct-patient counts, one row per gate, in funnel order. The
# FROM shape changes when the funnel crosses from index- to LOT1-anchored
# gates: up to that point the denominator is every candidate index row; after
# it, the index is already selected and the LOT1 tables are in scope.
sql_attrition <- function(spec, cfg) {
  gates <- spec$resolved_gates
  idx   <- .gates_at(spec, "index")
  arms  <- character(0)

  for (i in seq_along(gates)) {
    g <- gates[[i]]
    upto <- gates[seq_len(i)]
    if (identical(g$anchor, "index")) {
      from <- paste0("FROM ", cfg$index_flags, " f")
      where <- .and_block(upto, "         ")
    } else {
      # LEFT JOINs so the has_lot1 arm reports the no-LOT1 drop instead of
      # hiding it in the join, and so its denominator is the selected-index set.
      from <- paste0(
        "FROM ", sql_obj(cfg, paste0(spec$id, "_index_sel")), " s\n",
        "       LEFT JOIN ", cfg$lot1_starts, " l1 ON l1.PATID = s.PATID AND l1.INDEX_DATE = s.INDEX_DATE\n",
        "       LEFT JOIN ", cfg$lot1_flags,  " n  ON n.PATID  = s.PATID AND n.INDEX_DATE  = s.INDEX_DATE")
      where <- .and_block(Filter(function(x) identical(x$anchor, "lot1"), upto), "         ")
    }
    arms <- c(arms, paste0(
      "  SELECT '", g$attrition_id, "' AS step_id,\n",
      "         '", gsub("'", "''", g$label_resolved), "' AS label,\n",
      "         '", g$polarity, "' AS polarity,\n",
      "         count(DISTINCT PATID) AS n_patients\n",
      "  ", from, "\n",
      "  WHERE 1 = 1\n", where))
  }

  # Terminal row: the cohort as actually built. It must equal the last gate's
  # count; a mismatch means the funnel and the membership view disagree, which
  # is a build bug worth catching in the report itself.
  arms <- c(arms, paste0(
    "  SELECT '", sprintf("%02d", length(gates) + 1L), "_final' AS step_id,\n",
    "         'FINAL: ", spec$label, "' AS label,\n",
    "         'final' AS polarity,\n",
    "         count(DISTINCT PATID) AS n_patients\n",
    "  FROM ", sql_obj(cfg, paste0(spec$id, "_cohort"))))

  paste0(
    "-- Attrition funnel: ", spec$label, " (cumulative distinct patients)\n",
    paste(arms, collapse = "\n  UNION ALL\n"), "\n",
    "  ORDER BY step_id")
}

# Guard: the funnel's denominator for index gates is every candidate index ROW,
# but counts are DISTINCT PATID -- matching how run_attrition_report already
# reports. Stated here so the two reports are read on the same basis.

# =============================================================================
# Assemble a full run
# =============================================================================
build_plan <- function(specs, cfg) {
  specs <- lapply(specs, bind_lot1_aliases)
  steps <- list()
  add <- function(name, sql, desc) steps[[length(steps) + 1L]] <<-
    list(name = name, sql = sql, description = desc)

  for (s in specs)
    add(paste0(s$id, "_index_sel"), sql_index_sel(s, cfg),
        paste0("Index selection: ", s$label))

  add("index_union", sql_index_union(specs, cfg),
      "Union of selected indexes (input to the LOT build)")

  for (s in specs)
    add(paste0(s$id, "_cohort"), sql_cohort(s, cfg),
        paste0("Final membership: ", s$label))

  add("pld", sql_pld(specs, cfg), "Shared patient-level dataset with cohort flags")

  if (nzchar(cfg$persist_schema %||% "") && nzchar(cfg$pld_table %||% ""))
    add("pld_persist", sql_pld_persist(cfg),
        paste0("Persist PLD to ", cfg$persist_schema, ".", cfg$pld_table))

  list(steps = steps,
       attrition = stats::setNames(lapply(specs, sql_attrition, cfg = cfg),
                                   vapply(specs, `[[`, character(1), "id")),
       specs = specs)
}
