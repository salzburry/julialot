# The 1L index date, from claims.
#
# Not a port. Protocol Rev Round 2 S6.2.1.1 defines it directly:
#
#   Eligible 1L treatment: Received an eligible or expected treatment for MM on
#   or after MM diagnosis (other than belantamab), occurring on or after
#   01 Jan 2017 (eligible treatment period).
#   The 1L cohort index date is the date of the first claim for MM treatment
#   within the identification period.
#
# apr_30_2026 took it from LOT_LONG instead - the start of line 1 as the LOT
# algorithm computes it. That is a different thing: LOT_LONG only exists for
# patients who already passed the parent build's criteria, and the line start
# is an output of the line-building rules rather than a claim date. Reading it
# also made this build depend on a LOT run, when the plan is the reverse - the
# LOT algorithm runs over the cohort this build produces.
#
# The scan is the same four sources as the prior-therapy scan, against the same
# codelist view, so "MM treatment" means one thing in this package. That view
# already has steroids dropped: a steroid claim alone is supportive care, not
# the start of a line.

# Belantamab rows of the MMA code list. The 1L treatment must be "other than
# belantamab", so these are excluded from the scan that sets the index date -
# and exclusion 4 removes the patient outright, from any line.
build_ndmm_belantamab_codes <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BELANTAMAB_CODES} AS
    SELECT DISTINCT code_type, code
    FROM {NDMM_MMA_CODELIST}
    WHERE upper(trim(med_abbr)) LIKE '{NDMM_BELANTAMAB_ABBR}'
  "))
  # The abbreviation is how belantamab is recognised on the code list, and this
  # package cannot see the production CSV. If it matches nothing, the exclusion
  # the whole study turns on silently does nothing, and belantamab claims would
  # also be allowed to set the index date. Stop and say so rather than build a
  # cohort on an assumption that turned out false.
  n <- tryCatch(as.integer(db_q(con, glue(
    "SELECT count(*) AS n FROM {NDMM_BELANTAMAB_CODES}"))$n),
    error = function(e) NA_integer_)
  if (is.na(n) || n == 0)
    stop("No row of cl_mma_codelist.csv has CL_MED_ABBR like '",
         NDMM_BELANTAMAB_ABBR, "'.\nThat is how this build recognises ",
         "belantamab, and without it the exclusion in S6.2.1.2 does nothing ",
         "and belantamab claims could set the 1L index date. Run 'SELECT ",
         "DISTINCT med_abbr FROM ", NDMM_MMA_CODELIST, "' on the warehouse ",
         "and set NDMM_BELANTAMAB_ABBR to the abbreviation it uses.",
         call. = FALSE)
  log_msg("  Belantamab code list: ", n, " codes matched '",
          NDMM_BELANTAMAB_ABBR, "'")
  invisible(n)
}

# Agents that may not set the index: belantamab always, plus anything named in
# NDMM_INDEX_EXCLUDED_ABBRS. Empty by default - S6.2.1.1 routes "excluding those
# restricted to later LOTs" through the exclusion criteria, and S6.2.1.2 names
# only belantamab, so the protocol as written restricts nothing else.
build_ndmm_index_ineligible_codes <- function(con) {
  split_setting <- function(x) {
    v <- trimws(strsplit(x, "[,|]")[[1]])
    v[nzchar(v)]
  }
  # The code list's own normalisation, so a hyphenated NDC or a lowercase
  # HCPCS matches what is stored.
  norm <- function(x) toupper(gsub("[^A-Za-z0-9]", "", x))
  sq   <- function(x) gsub("'", "''", x, fixed = TRUE)

  abbrs <- split_setting(NDMM_INDEX_EXCLUDED_ABBRS)
  codes <- split_setting(NDMM_INDEX_EXCLUDED_CODES)

  # Each entry becomes one predicate, and one thing to check matched something.
  terms <- list()
  for (a in c(NDMM_BELANTAMAB_ABBR, abbrs))
    terms[[length(terms) + 1L]] <- list(
      what = paste0("abbreviation '", a, "'"),
      sql  = sprintf("upper(trim(med_abbr)) LIKE '%s'", sq(toupper(a))))
  for (cd in codes) {
    parts <- strsplit(cd, ":", fixed = TRUE)[[1]]
    if (length(parts) >= 2L)
      terms[[length(terms) + 1L]] <- list(
        what = paste0("code ", cd),
        sql  = sprintf("(code_type = '%s' AND code = '%s')",
                       sq(toupper(trimws(parts[1]))), sq(norm(parts[2]))))
    else
      terms[[length(terms) + 1L]] <- list(
        what = paste0("code ", cd, " (any type)"),
        sql  = sprintf("code = '%s'", sq(norm(parts[1]))))
  }

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_INDEX_INELIGIBLE} AS
    SELECT DISTINCT code_type, code
    FROM {NDMM_MMA_CODELIST}
    WHERE ", paste(vapply(terms, function(t) t$sql, character(1)),
                   collapse = "\n       OR "), "
  "))

  # Every entry after belantamab has to match something. Left unchecked, a name
  # or a code that is not on the list reads as an applied restriction and
  # applies to nothing - the failure the belantamab check already guards.
  for (t in terms[-1]) {
    n <- as.integer(db_q(con, glue(
      "SELECT count(*) AS n FROM {NDMM_MMA_CODELIST} WHERE {t$sql}"))$n)
    if (is.na(n) || n == 0)
      stop("The 1L index exclusions name ", t$what, ", which matches no row of ",
           "cl_mma_codelist.csv. It would read as a restriction on which agents ",
           "can set the index and apply to nothing. Check it against 'SELECT ",
           "DISTINCT code_type, med_abbr, code FROM ", NDMM_MMA_CODELIST, "'.",
           call. = FALSE)
  }
  if (length(terms) > 1L)
    log_msg("  Barred from setting the index, beyond belantamab: ",
            paste(vapply(terms[-1], function(t) t$what, character(1)),
                  collapse = ", "))
  invisible(TRUE)
}

# The first eligible MM treatment claim on or after the MM diagnosis and on or
# after the eligible-treatment cutoff. That date is the NDMM index.
build_ndmm_lot1_index <- function(con, medical_tbl, rx_tbl) {
  # Every branch is scoped to the base cohort, dated on or after that patient's
  # own diagnosis, and inside the eligible-treatment period. Belantamab is left
  # out by the anti-join: S6.2.1.1 says the eligible 1L treatment is one "other
  # than belantamab", so a belantamab claim cannot be what sets the index.
  arm <- function(tbl, dt, match_sql) glue("
      SELECT cast(t.PATID as string) AS PATID, cast(t.{dt} as date) AS tx_dt,
             c.med_abbr
      FROM {tbl} t
      INNER JOIN {NDMM_BASE_COHORT} b ON cast(t.PATID as string) = b.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c ON {match_sql}
      LEFT JOIN {NDMM_INDEX_INELIGIBLE} bl
             ON bl.code_type = c.code_type AND bl.code = c.code
      WHERE bl.code IS NULL
        AND cast(t.{dt} as date) >= b.MM_DX_DT
        AND cast(t.{dt} as date) >= date('{NDMM_LOT1_FROM}')
        AND cast(t.{dt} as date) <= date('{cfg$study_end}')")
  proc_match <- "c.code_type IN ('HCPCS','CPT')
       AND upper(regexp_replace(coalesce(cast(t.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
       AND regexp_replace(coalesce(cast(t.PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''"
  bill_match <- "c.code_type = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(t.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
       AND regexp_replace(coalesce(cast(t.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''"
  ndc_match <- "c.code_type = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(t.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
       AND regexp_replace(coalesce(cast(t.NDC as string),''), '[^0-9]', '') <> ''"
  # One scan, kept: the index date comes out of it, and so does which agent set
  # that date. The second is what NDMM_INDEX_AGENTS reports, and re-running the
  # four arms to get it would double the most expensive step in the build.
  db_exec(con, paste0(glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_INDEX_TX} AS"),
    arm(medical_tbl, "FST_DT",  proc_match), "\n      UNION ALL\n",
    arm(medical_tbl, "FST_DT",  bill_match), "\n      UNION ALL\n",
    arm(medical_tbl, "FST_DT",  ndc_match),  "\n      UNION ALL\n",
    arm(rx_tbl,      "FILL_DT", ndc_match)))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_LOT1_STARTS} AS
    SELECT PATID, min(tx_dt) AS LOT1_START_DT
    FROM {NDMM_INDEX_TX}
    GROUP BY PATID"))
}

# Which agent set each patient's index, and how many indexes each agent set.
#
# This is the list S6.2.1.1 gestures at and no document in this repository
# contains. Annex 2 is "categorization of SOC regimens", which S6.2.2 calls an
# exemplary list that may be recategorized - an analysis grouping, not an
# eligibility rule - and it is a stand-alone document. So rather than invent an
# allowlist, the build reports what actually set an index. If a later-line-only
# agent appears here, name it in NDMM_INDEX_EXCLUDED_ABBRS and re-run.
build_ndmm_index_agents <- function(con, cfg) {
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_INDEX_AGENTS')} AS
    WITH on_index AS (
      SELECT DISTINCT tx.PATID, tx.med_abbr
      FROM {NDMM_INDEX_TX} tx
      INNER JOIN {NDMM_LOT1_STARTS} l1
              ON l1.PATID = tx.PATID AND tx.tx_dt = l1.LOT1_START_DT
    )
    SELECT coalesce(med_abbr, '(none)') AS MED_ABBR,
           count(DISTINCT PATID)        AS N_PATIENTS
    FROM on_index
    GROUP BY coalesce(med_abbr, '(none)')
    ORDER BY N_PATIENTS DESC"))
  got <- db_q(con, glue("SELECT * FROM {wrk('NDMM_INDEX_AGENTS')}"))
  log_msg("Agents that set a 1L index date (", nrow(got), "):")
  for (i in seq_len(nrow(got)))
    log_msg("    ", got$MED_ABBR[i], ": ", format(got$N_PATIENTS[i], big.mark = ","))
  log_msg("  Review these against S6.2.1.1. Anything restricted to later lines ",
          "belongs in NDMM_INDEX_EXCLUDED_ABBRS.")
  invisible(got)
}

# MAP_STACKED is a LOT-build table this package no longer reads. The ported
# flags step takes its belantamab source as a parameter and looks for
# MAP_MED_TYPE LIKE 'BEL%', so this answers in that shape from raw claims.
#
# S6.2.1.2 says "in any LOT". Lines do not exist yet - the LOT algorithm runs
# over the cohort this build produces - so NDMM_BELANTAMAB_SCOPE picks the
# claims proxy, and every claim is kept here with its date so the proxy can be
# applied, and so all of them can be counted for review.
build_ndmm_belantamab_patids <- function(con, medical_tbl, rx_tbl) {
  txt_match <- function(col) paste0(
    "upper(regexp_replace(coalesce(cast(t.", col, " as string),''), '[^A-Za-z0-9]', '')) = c.code",
    "\n       AND regexp_replace(coalesce(cast(t.", col, " as string),''), '[^A-Za-z0-9]', '') <> ''")
  ndc_match <- function(col) paste0(
    "lpad(regexp_replace(coalesce(cast(t.", col, " as string),''), '[^0-9]', ''), 11, '0')",
    "\n         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')",
    "\n       AND regexp_replace(coalesce(cast(t.", col, " as string),''), '[^0-9]', '') <> ''")
  arm <- function(tbl, dt, match_sql) glue("
      SELECT DISTINCT cast(t.PATID as string) AS PATID,
             cast(t.{dt} as date) AS bel_dt
      FROM {tbl} t
      INNER JOIN {NDMM_BELANTAMAB_CODES} c ON {match_sql}
      WHERE cast(t.{dt} as date) <= date('{cfg$study_end}')")
  db_exec(con, paste0(glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BELANTAMAB_TX} AS"),
    arm(medical_tbl, "FST_DT",  txt_match("PROC_CD")),      "\n      UNION\n",
    arm(medical_tbl, "FST_DT",  txt_match("BILL_PROC_CD")), "\n      UNION\n",
    arm(medical_tbl, "FST_DT",  ndc_match("NDC")),          "\n      UNION\n",
    arm(rx_tbl,      "FILL_DT", ndc_match("NDC"))))

  scope <- switch(NDMM_BELANTAMAB_SCOPE,
    study_period = glue("b.bel_dt >= date('{NDMM_STUDY_START}')"),
    from_index   = "b.bel_dt >= l1.LOT1_START_DT",
    stop("NDMM_BELANTAMAB_SCOPE='", NDMM_BELANTAMAB_SCOPE, "' is not a scope. ",
         "Use study_period or from_index; see standalone_constants.R.",
         call. = FALSE))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BELANTAMAB_PATIDS} AS
    SELECT DISTINCT b.PATID, 'BEL' AS MAP_MED_TYPE
    FROM {NDMM_BELANTAMAB_TX} b
    INNER JOIN {NDMM_LOT1_STARTS} l1 ON l1.PATID = b.PATID
    WHERE {scope}"))
}

# How many patients each reading of "in any LOT" would exclude. The scope is a
# proxy for something this build cannot see, so the run says what the choice
# costs rather than leaving it to be guessed at.
build_ndmm_belantamab_scope_counts <- function(con, cfg) {
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_BELANTAMAB_SCOPE_COUNTS')} AS
    SELECT 'ever'         AS SCOPE, count(DISTINCT b.PATID) AS N_PATIENTS
    FROM {NDMM_BELANTAMAB_TX} b
    INNER JOIN {NDMM_LOT1_STARTS} l1 ON l1.PATID = b.PATID
    UNION ALL
    SELECT 'study_period', count(DISTINCT b.PATID)
    FROM {NDMM_BELANTAMAB_TX} b
    INNER JOIN {NDMM_LOT1_STARTS} l1 ON l1.PATID = b.PATID
    WHERE b.bel_dt >= date('{NDMM_STUDY_START}')
    UNION ALL
    SELECT 'from_index', count(DISTINCT b.PATID)
    FROM {NDMM_BELANTAMAB_TX} b
    INNER JOIN {NDMM_LOT1_STARTS} l1 ON l1.PATID = b.PATID
    WHERE b.bel_dt >= l1.LOT1_START_DT"))
  got <- db_q(con, glue("SELECT * FROM {wrk('NDMM_BELANTAMAB_SCOPE_COUNTS')}"))
  log_msg("Belantamab exclusion, by reading of \"in any LOT\" (applied: ",
          NDMM_BELANTAMAB_SCOPE, ")")
  for (i in seq_len(nrow(got)))
    log_msg("    ", got$SCOPE[i], ": ", format(got$N_PATIENTS[i], big.mark = ","),
            " of the 1L candidates")
  invisible(got)
}

# Every plasma-cell-looking tumour group the other-cancer code list carries,
# and whether the override covers it.
#
# The override exists because the criterion is another cancer "distinct from
# the index MM", and these are the index disease or its precursor. Which
# labels the production list actually stores is not visible from here, and the
# remission wording is exactly where it is likely to differ - so the run writes
# what it found rather than leaving the question to a comment.
build_ndmm_mm_adjacent_groups <- function(con, cfg) {
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_MM_ADJACENT_GROUPS')} AS
    SELECT tumor_group                    AS TUMOR_GROUP,
           max(is_mm_adjacent_override)   AS OVERRIDDEN,
           count(*)                       AS N_CODES
    FROM {NDMM_OTHER_MALIG_CODES}
    WHERE is_mm_adjacent_override = 1
       OR upper(tumor_group) LIKE '%REMISSION%'
       OR upper(tumor_group) LIKE '%RELAPSE%'
       OR upper(tumor_group) LIKE '%PLASMACYTOMA%'
       OR upper(tumor_group) LIKE '%PLASMA CELL%'
       OR upper(tumor_group) LIKE '%GAMMOPATHY%'
       OR upper(tumor_group) LIKE '%MYELOMA%'
    GROUP BY tumor_group
    ORDER BY OVERRIDDEN DESC, TUMOR_GROUP"))
  got <- db_q(con, glue("SELECT * FROM {wrk('NDMM_MM_ADJACENT_GROUPS')}"))
  log_msg("MM-adjacent tumour groups on the code list (remission handling: ",
          NDMM_MM_ADJACENT_STATES, ")")
  for (i in seq_len(nrow(got)))
    log_msg("    ", if (got$OVERRIDDEN[i] == 1L) "kept    " else "EXCLUDES",
            "  ", got$TUMOR_GROUP[i], " (", got$N_CODES[i], " codes)")
  miss <- setdiff(toupper(NDMM_MM_ADJACENT_STATE_LABELS),
                  toupper(got$TUMOR_GROUP))
  if (length(miss))
    log_msg("  Not on this code list, so nothing to override: ",
            paste(miss, collapse = "; "))
  # Anything left excluding that reads as the index disease is the open
  # question, and this is where it surfaces.
  still <- got$TUMOR_GROUP[got$OVERRIDDEN == 0L]
  if (length(still))
    log_msg("  Review: these still exclude a patient as having another cancer - ",
            paste(still, collapse = "; "))
  invisible(got)
}
