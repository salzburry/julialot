# The 1L index date, from claims.
#
# The index is the date of the first claim for an eligible MM treatment on or
# after the MM diagnosis - anything but belantamab - and on or after
# NDMM_LOT1_FROM.
#
# From claims, not from a built line. A line start is an output of the
# line-building rules, and reading one would make this build wait on a LOT run
# when LOT runs over the cohort this build produces.
#
# Five sources - medical PROC_CD, BILL_PROC_CD and NDC, rx NDC, med_procedure
# PROC - against one codelist view, so "MM treatment" means one thing here.
# Steroids are already dropped from it: a steroid claim alone is supportive
# care, not the start of a line.

# Belantamab rows of the MMA code list. The 1L treatment must be "other than
# belantamab", so these are excluded from the scan that sets the index date -
# and exclusion 4 removes the patient outright, from any line.
build_ndmm_belantamab_codes <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BELANTAMAB_CODES} AS
    SELECT DISTINCT code_type, code
    FROM {NDMM_MMA_CODELIST}
    WHERE upper(trim(med_abbr)) = '{NDMM_BELANTAMAB_ABBR}'
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
    stop("No row of cl_mma_codelist.csv has CL_MED_ABBR = '",
         NDMM_BELANTAMAB_ABBR, "'.\nThat is how this build recognises ",
         "belantamab, and without it the exclusion does nothing ",
         "and belantamab claims could set the 1L index date. Run 'SELECT ",
         "DISTINCT med_abbr FROM ", NDMM_MMA_CODELIST, "' on the warehouse ",
         "and set NDMM_BELANTAMAB_ABBR to the abbreviation it uses.",
         call. = FALSE)
  # The match is exact now, which is what makes it agree with lot - and what
  # makes a second spelling invisible. A code list carrying both BELA and, say,
  # BELAMAF would have every BELAMAF row silently fall outside the exclusion,
  # and this build and lot would still agree with each other while both missed
  # it. Ask for the neighbours rather than assume there are none.
  others <- tryCatch(
    db_q(con, glue("
      SELECT DISTINCT upper(trim(med_abbr)) AS med_abbr
      FROM {NDMM_MMA_CODELIST}
      WHERE upper(trim(med_abbr)) LIKE 'BEL%'
        AND upper(trim(med_abbr)) <> '{NDMM_BELANTAMAB_ABBR}'"))$med_abbr,
    error = function(e) character(0))
  if (length(others))
    stop("cl_mma_codelist.csv carries CL_MED_ABBR = '", NDMM_BELANTAMAB_ABBR,
         "' and also ", paste0("'", others, "'", collapse = ", "),
         ".\nBelantamab is matched as a whole abbreviation, here and in the lot ",
         "package, so rows under the other spelling(s) would be missed ",
         "entirely and nothing would say so. Decide which one names ",
         "belantamab: set NDMM_BELANTAMAB_ABBR and lot's BELANTAMAB_MED_ABBR to ",
         "it, or have the code list use one abbreviation for the drug.",
         call. = FALSE)
  log_msg("  Belantamab code list: ", n, " codes under CL_MED_ABBR = '",
          NDMM_BELANTAMAB_ABBR, "', and no other BEL* abbreviation")
  invisible(n)
}

# Agents that may not set the index: belantamab always, plus anything named in
# NDMM_INDEX_EXCLUDED_ABBRS. Empty by default, because belantamab is the only
# therapy named as restricted to later lines.
build_ndmm_index_ineligible_codes <- function(con) {
  split_setting <- function(x) {
    v <- trimws(strsplit(x, "[,|]")[[1]])
    v[nzchar(v)]
  }
  # The code list's own normalisation, so a hyphenated NDC or a lowercase
  # HCPCS matches what is stored.
  norm <- function(x) toupper(gsub("[^A-Za-z0-9]", "", x))
  sq   <- function(x) gsub("'", "''", x, fixed = TRUE)

  # cl_mma_codelist.csv is the study's definition of MM therapy, so it is also
  # the eligible-1L set: any agent on it may set the index, less steroids
  # (dropped where NDMM_MMA_CODELIST is built) and less belantamab (barred
  # below). There is no separate eligibility file.
  # NDMM_INDEX_EXCLUDED_ABBRS bars a named agent if the study team asks for it.
  # Empty by default, and every entry is checked against the code list.
  abbrs <- split_setting(NDMM_INDEX_EXCLUDED_ABBRS)
  codes <- split_setting(NDMM_INDEX_EXCLUDED_CODES)

  # Each entry becomes one predicate, and one thing to check matched something.
  terms <- list()
  # Belantamab exactly, the way build_ndmm_belantamab_codes() and lot both match
  # it, so the agent barred from setting the index is the same agent the
  # exclusion removes. The operational entries below stay patterns: they are a
  # study-team override typed by hand, and a prefix is useful there.
  terms[[1L]] <- list(
    what = paste0("abbreviation '", NDMM_BELANTAMAB_ABBR, "'"),
    sql  = sprintf("upper(trim(med_abbr)) = '%s'",
                   sq(toupper(NDMM_BELANTAMAB_ABBR))))
  for (a in abbrs)
    terms[[length(terms) + 1L]] <- list(
      what = paste0("abbreviation pattern '", a, "'"),
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
build_ndmm_lot1_index <- function(con, medical_tbl, rx_tbl, med_proc_tbl) {
  # Every branch is scoped to the base cohort, dated on or after that patient's
  # own diagnosis, and inside the eligible-treatment period. Belantamab is left
  # out by the anti-join: an eligible 1L treatment is one other than
  # belantamab, so a belantamab claim cannot set the index.
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
  ndc_match <- paste0("c.code_type = 'NDC'\n       AND ", ndc_key("t.NDC"),
                      "\n         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')")
  # med_procedure.PROC, which
  # says PROC finds a drug given as a procedure under a HCPCS or CPT code.
  # No ICD_FLAG condition, as 05_sct.R does for HCPCS: a J-code carrying an
  # unexpected flag would otherwise be dropped. The join is self-limiting -
  # ICD-10-PCS is seven characters and ICD-9 procedures three or four, so only
  # a five-character PROC can equal a HCPCS or CPT code on the list.
  mproc_match <- "c.code_type IN ('HCPCS','CPT')
       AND upper(regexp_replace(coalesce(cast(t.PROC as string),''), '[^A-Za-z0-9]', '')) = c.code
       AND regexp_replace(coalesce(cast(t.PROC as string),''), '[^A-Za-z0-9]', '') <> ''"
  # One scan, kept: the index date comes out of it, and so does which agent set
  # that date. The second is what NDMM_INDEX_AGENTS reports, and re-running the
  # five arms to get it would double the most expensive step in the build.
  # "\n" after AS, and it cannot live inside the glue() above: glue trims
  # trailing newlines, so the statement came out as "...ASSELECT" and Spark
  # would not parse it.
  db_exec(con, paste0(glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_INDEX_TX} AS"), "\n",
    arm(medical_tbl, "FST_DT",  proc_match), "\n      UNION ALL\n",
    arm(medical_tbl, "FST_DT",  bill_match), "\n      UNION ALL\n",
    arm(medical_tbl, "FST_DT",  ndc_match),  "\n      UNION ALL\n",
    arm(rx_tbl,      "FILL_DT", ndc_match),   "\n      UNION ALL\n",
    arm(med_proc_tbl, "FST_DT", mproc_match)))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_LOT1_STARTS} AS
    SELECT PATID, min(tx_dt) AS LOT1_START_DT
    FROM {NDMM_INDEX_TX}
    GROUP BY PATID"))
}

# Which agent set each patient's index, and how many indexes each agent set.
#
# Nobody has written down which agents count as first-line, so this build does
# not narrow the set. It writes the sheet the decision would be made from:
# every agent on the code list, whether this run let it set an index, and how
# many it set. Bar one with NDMM_INDEX_EXCLUDED_ABBRS.
build_ndmm_index_agents <- function(con, cfg) {
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_INDEX_AGENTS')} AS
    WITH on_index AS (
      SELECT DISTINCT tx.PATID, tx.med_abbr
      FROM {NDMM_INDEX_TX} tx
      INNER JOIN {NDMM_LOT1_STARTS} l1
              ON l1.PATID = tx.PATID AND tx.tx_dt = l1.LOT1_START_DT
    ),
    -- Every agent on the code list, not only the ones that won a date. Under
    -- a narrowed set the winners are by definition the allowed ones, so a table
    -- of winners could not be used to decide the narrowing - which is what this
    -- table is for. ELIGIBLE says what this run treated each as.
    universe AS (
      SELECT DISTINCT upper(trim(c.med_abbr)) AS med_abbr
      FROM {NDMM_MMA_CODELIST} c
      WHERE c.med_abbr IS NOT NULL AND trim(c.med_abbr) <> ''
    ),
    barred AS (
      SELECT DISTINCT upper(trim(c.med_abbr)) AS med_abbr
      FROM {NDMM_MMA_CODELIST} c
      INNER JOIN {NDMM_INDEX_INELIGIBLE} i
              ON i.code_type = c.code_type AND i.code = c.code
    )
    SELECT u.med_abbr                              AS MED_ABBR,
           CASE WHEN b.med_abbr IS NULL THEN 1 ELSE 0 END AS ELIGIBLE,
           coalesce(n.N_PATIENTS, 0)               AS N_PATIENTS
    FROM universe u
    LEFT JOIN barred b ON b.med_abbr = u.med_abbr
    LEFT JOIN (SELECT coalesce(upper(trim(med_abbr)), '(none)') AS med_abbr,
                      count(DISTINCT PATID) AS N_PATIENTS
               FROM on_index
               GROUP BY coalesce(upper(trim(med_abbr)), '(none)')) n
           ON n.med_abbr = u.med_abbr
    ORDER BY N_PATIENTS DESC, MED_ABBR"))
  got <- db_q(con, glue("SELECT * FROM {wrk('NDMM_INDEX_AGENTS')}"))
  log_msg("MM agents on the code list (", nrow(got), "), and the indexes they set:")
  for (i in seq_len(nrow(got)))
    log_msg("    ", if (got$ELIGIBLE[i] == 1L) "may set " else "BARRED  ", " ",
            got$MED_ABBR[i], ": ", format(got$N_PATIENTS[i], big.mark = ","))
  log_msg("  Review these. Anything restricted to later lines belongs in ",
          "NDMM_INDEX_EXCLUDED_ABBRS.")
  invisible(got)
}

# The flags step takes its belantamab source as a parameter and looks for
# MAP_MED_TYPE LIKE 'BEL%', so this answers in that shape from raw claims.
#
# The "in any LOT" exclusion is not applied here - lines do not exist until lot
# has run over this cohort, so it is a line criterion there. What this builds
# is the flag and, below, the list of cohort members carrying a belantamab
# claim. Every claim is kept with its date.
build_ndmm_belantamab_patids <- function(con, medical_tbl, rx_tbl, med_proc_tbl) {
  # Each source only matches the code types it can carry, the same way the
  # prior-therapy and index scans do. Without it a PROC_CD could match an NDC
  # row once both are stripped to alphanumerics, and an NDC could match an
  # HCPCS row once both are stripped to digits - either way excluding a patient
  # for a belantamab claim they never had.
  txt_match <- function(col, types) paste0(
    "c.code_type IN (", types, ")",
    "\n       AND upper(regexp_replace(coalesce(cast(t.", col, " as string),''), '[^A-Za-z0-9]', '')) = c.code",
    "\n       AND regexp_replace(coalesce(cast(t.", col, " as string),''), '[^A-Za-z0-9]', '') <> ''")
  ndc_match <- function(col) paste0(
    "c.code_type = 'NDC'",
    "\n       AND lpad(regexp_replace(coalesce(cast(t.", col, " as string),''), '[^0-9]', ''), 11, '0')",
    "\n         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')",
    "\n       AND regexp_replace(coalesce(cast(t.", col, " as string),''), '[^0-9]', '') <> ''")
  # Both ends of the study period. The upper bound was always here; the lower
  # one was not, and the CDM tables reach back well before the study start of
  # 2016-01-01 - so this view could return a claim from outside the window every
  # other criterion here is bounded to. One scope for the drug, one package.
  arm <- function(tbl, dt, match_sql) glue("
      SELECT DISTINCT cast(t.PATID as string) AS PATID,
             cast(t.{dt} as date) AS bel_dt
      FROM {tbl} t
      INNER JOIN {NDMM_BELANTAMAB_CODES} c ON {match_sql}
      WHERE cast(t.{dt} as date) >= date('{NDMM_STUDY_START}')
        AND cast(t.{dt} as date) <= date('{cfg$study_end}')")
  db_exec(con, paste0(glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BELANTAMAB_TX} AS"), "\n",
    arm(medical_tbl, "FST_DT",  txt_match("PROC_CD", "'HCPCS','CPT'")), "\n      UNION\n",
    arm(medical_tbl, "FST_DT",  txt_match("BILL_PROC_CD", "'HCPCS'")),  "\n      UNION\n",
    arm(medical_tbl, "FST_DT",  ndc_match("NDC")),          "\n      UNION\n",
    arm(rx_tbl,      "FILL_DT", ndc_match("NDC")),           "\n      UNION\n",
    arm(med_proc_tbl, "FST_DT", txt_match("PROC", "'HCPCS','CPT'"))))

  # The study period, always. Widest net, because this view answers two
  # questions and one of them is a criterion.
  #
  # PRE_LOT1 marks a belantamab claim strictly before the 1L index. That half
  # is settled here because lot cannot see it - map_stacked starts at the
  # cohort's INDEX_DATE. The other half is the line criterion there. The two do
  # not overlap and together cover the rule.
  #
  # The study period, not all of history. The rule names no period, but the CDM
  # reaches back well before the study start, so an unbounded scan would act on
  # claims outside the window every other criterion is bounded to. See
  # DECISIONS.md. No date predicate of its own - NDMM_BELANTAMAB_TX already
  # carries that bound, and a second copy would be one more place to drift.
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BELANTAMAB_PATIDS} AS
    SELECT b.PATID, 'BEL' AS MAP_MED_TYPE,
           max(CASE WHEN b.bel_dt < l1.LOT1_START_DT THEN 1 ELSE 0 END) AS PRE_LOT1
    FROM {NDMM_BELANTAMAB_TX} b
    INNER JOIN {NDMM_LOT1_STARTS} l1 ON l1.PATID = b.PATID
    GROUP BY b.PATID"))
}

# Every ICD category the other-cancer code list resolves to, and how many
# labels and codes fall in each. This is what the two-outpatient-claim rule
# pairs on, so it is where to check that a group is a primary tumour type and
# not something coarser.
build_ndmm_other_malig_groups <- function(con, cfg) {
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_OTHER_MALIG_GROUPS')} AS
    SELECT primary_group                 AS PRIMARY_GROUP,
           icd_family                    AS ICD_FAMILY,
           count(*)                      AS N_CODES,
           count(DISTINCT tumor_group)   AS N_LABELS,
           max(is_mm_adjacent_override)  AS ANY_OVERRIDDEN,
           min(tumor_group)              AS EXAMPLE_LABEL
    FROM {NDMM_OTHER_MALIG_CODES}
    GROUP BY primary_group, icd_family
    ORDER BY ICD_FAMILY, PRIMARY_GROUP"))
  got <- db_q(con, glue("
    SELECT count(*) AS n_groups, sum(N_CODES) AS n_codes,
           sum(CASE WHEN N_CODES = 1 THEN 1 ELSE 0 END) AS n_alone
    FROM {wrk('NDMM_OTHER_MALIG_GROUPS')}"))
  log_msg("Other-cancer codes: ", got$n_codes, " on the code list, pairing as ",
          got$n_groups, " ICD categor(ies); ", got$n_alone,
          " categor(ies) hold one code and can only confirm themselves -> ",
          wrk("NDMM_OTHER_MALIG_GROUPS"))
  invisible(got)
}

# What the pairing grain is costing, without needing a map to exist first.
#
# Criterion 7 Path B is two outpatient claims within 30 days for the same
# cancer. "Same" is a code-list label, and a label is a code description - one
# cancer at two subsites, or coded in remission once and not the next time, is
# two labels and the claims never pair. So the criterion under-detects.
#
# The map fixes it, but nobody can size the problem from an empty map. These
# three rows need no map, and come off the events view the criterion itself
# reads, so the claim scan does not run twice:
#
#   same code-list label - the finest grain, and what an empty map gives
#   as configured        - the same until primary_tumor_groups.csv says otherwise
#   any label at all     - the coarsest, and the upper bound on what a perfect
#                          map could add
#
# The gap between the first row and the last is the whole question. If it is
# small the grain does not matter; if it is large the map is worth writing.
build_ndmm_other_malig_grain <- function(con, cfg) {
  by <- function(label, grp) glue("
    SELECT '{label}' AS GRAIN, count(DISTINCT l1.PATID) AS N_EXCLUDED
    FROM {NDMM_LOT1_STARTS} l1
    LEFT JOIN (SELECT DISTINCT PATID, event_dt
               FROM {NDMM_OTHER_MALIG_EVENTS} WHERE inpatient_flg = 1) ip
           ON cast(ip.PATID as string) = cast(l1.PATID as string)
          AND ip.event_dt BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                              AND date_sub(l1.LOT1_START_DT, 1)
    LEFT JOIN (SELECT PATID, event_dt AS first_dt, next_dt
               FROM (SELECT PATID, event_dt,
                            lead(event_dt) OVER (PARTITION BY PATID{grp}
                                                 ORDER BY event_dt) AS next_dt
                     FROM (SELECT DISTINCT PATID, {if (nzchar(grp)) sub('^, ', '', grp) else '1 AS one'}, event_dt
                           FROM {NDMM_OTHER_MALIG_EVENTS} WHERE inpatient_flg = 0))
               WHERE next_dt IS NOT NULL AND datediff(next_dt, event_dt) <= 30) op
           ON cast(op.PATID as string) = cast(l1.PATID as string)
          AND op.first_dt BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                              AND date_sub(l1.LOT1_START_DT, 1)
          AND op.next_dt  BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                              AND date_sub(l1.LOT1_START_DT, 1)
    WHERE ip.PATID IS NOT NULL OR op.PATID IS NOT NULL")
  # The separator is outside the glue for the same reason as the two views
  # above: glue() trims a trailing newline, so "AS\n" inside it becomes "AS".
  db_exec(con, paste0(glue("CREATE OR REPLACE TABLE {wrk('NDMM_OTHER_MALIG_GRAIN')} AS"), "\n",
    by("same code-list label", ", tumor_group"), "\n    UNION ALL\n",
    by("as configured",        ", primary_group"), "\n    UNION ALL\n",
    # Metastatic codes kept apart by the prefix each matched, everything else
    # as configured. The gap against "as configured" is exactly what collapsing
    # them costs - the only difference between the two rows is the collapse.
    by("mets kept apart by prefix", ", category_group"), "\n    UNION ALL\n",
    # The two tiers the decision record says to watch, each held out of the
    # collapse while the rest stays configured. The gap against "as configured"
    # is that tier's own contribution. A code count cannot give this: it says
    # a prefix is represented, not that it excluded anybody.
    by("collapse without C77/196",   ", grp_wo_nodal"),  "\n    UNION ALL\n",
    by("collapse without C800/1990", ", grp_wo_dissem"), "\n    UNION ALL\n",
    by("any label at all",     "")))
  got <- db_q(con, glue("SELECT * FROM {wrk('NDMM_OTHER_MALIG_GRAIN')}"))
  log_msg("Other cancer (criterion 7), by pairing grain:")
  for (i in seq_len(nrow(got)))
    log_msg("    ", got$GRAIN[i], ": ",
            format(got$N_EXCLUDED[i], big.mark = ","), " excluded")
  log_msg("  The gap between the first and the last is what a primary-tumour-",
          "group map could add. See README.")
  invisible(got)
}

# What criterion 5 costs at each reading of it.
#
# This build uses one day of follow-up enrollment - the index date itself -
# because the study team asked for it, while the wider study text says three
# months. Nobody can sign one off against the other without a number, so here
# it is: how many pass criterion 5 at each window, and how many reach the final
# cohort at each.
#
# One pass over the strict spans, cross-joined to the windows, so it costs
# about what the flag costs. It does not change the cohort - the run still
# applies NDMM_FU_CE_DAYS, and that value always appears in the table.
ndmm_fu_ce_windows <- function() sort(unique(c(NDMM_FU_CE_DAYS, 0L, 30L, 60L, 90L)))

build_ndmm_fu_ce_counts <- function(con, cfg) {
  days <- ndmm_fu_ce_windows()
  # 90 days is how three months is applied, because NDMM_FU_CE_DAYS counts
  # days. add_months(.., 3) is the exact reading and lands 0-2 days later.
  # Reported so the gap is a number rather than an assumption.
  rows <- c(sprintf("(%d, '%d days', cast(NULL as int))", days, days),
            "(9999, '3 months (exact)', 3)")
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_FU_CE_COUNTS')} AS
    WITH idx AS (
      SELECT l1.PATID, l1.LOT1_START_DT, b.DEATH_DT
      FROM {NDMM_LOT1_STARTS} l1
      INNER JOIN {NDMM_BASE_COHORT} b ON b.PATID = l1.PATID
    ),
    w AS (SELECT * FROM (VALUES\n      ", paste(rows, collapse = ",\n      "), "
    ) AS t(sort_key, rule, months)),
    want AS (
      SELECT idx.PATID, w.sort_key, w.rule,
             least(CASE WHEN w.months IS NULL
                        THEN date_add(idx.LOT1_START_DT, w.sort_key)
                        ELSE add_months(idx.LOT1_START_DT, w.months) END,
                   date('{cfg$study_end}'),
                   coalesce(idx.DEATH_DT, date('{cfg$study_end}'))) AS want_end,
             idx.LOT1_START_DT
      FROM idx CROSS JOIN w
    ),
    cov AS (
      SELECT want.PATID, want.sort_key, want.rule,
             max(CASE WHEN s.cov_start <= want.LOT1_START_DT
                       AND s.cov_end   >= want.want_end
                      THEN 1 ELSE 0 END) AS CE_fu
      FROM want
      LEFT JOIN {NDMM_ENROLL_SPANS_STRICT} s ON s.PATID = want.PATID
      GROUP BY want.PATID, want.sort_key, want.rule
    )
    SELECT cov.rule                                        AS FU_CE_RULE,
           count(DISTINCT CASE WHEN cov.CE_fu = 1 THEN cov.PATID END)
                                                           AS N_PASSING_CRITERION_5,
           -- The whole conjunction, so this is the cohort size at that window
           -- rather than one criterion's count. Every criterion but the one
           -- this table varies: cov.CE_fu is the follow-up CE recomputed per
           -- window, so it stands in for CE_lot1_fu and the rest come from
           -- NDMM_CRITERIA. Add a criterion to the cohort and it lands here
           -- too, rather than leaving this row quietly too large.
           count(DISTINCT CASE WHEN cov.CE_fu = 1
                                AND {ndmm_criteria_where(except = 'CE_lot1_fu', alias = 'f.')}
                               THEN cov.PATID END)         AS N_COHORT,
           max(CASE WHEN cov.sort_key = {NDMM_FU_CE_DAYS} THEN 1 ELSE 0 END)
                                                           AS IS_THIS_RUN
    FROM cov
    INNER JOIN {NDMM_FLAGS_ALL} f ON f.PATID = cov.PATID
    GROUP BY cov.rule, cov.sort_key
    ORDER BY cov.sort_key"))
  got <- db_q(con, glue("SELECT * FROM {wrk('NDMM_FU_CE_COUNTS')}"))
  log_msg("Follow-up CE (criterion 5), by window. This run applies ",
          NDMM_FU_CE_DAYS, " day(s); three months is the wider figure.")
  for (i in seq_len(nrow(got)))
    log_msg("    ", if (got$IS_THIS_RUN[i] == 1L) "->" else "  ", " ",
            got$FU_CE_RULE[i], ": ",
            format(got$N_PASSING_CRITERION_5[i], big.mark = ","),
            " pass, cohort ", format(got$N_COHORT[i], big.mark = ","))
  log_msg("  FU_CE_DAYS=", NDMM_FU_CE_DAYS, " comes from the study team and ",
          "differs from the three months written elsewhere. See README.")
  invisible(got)
}

# The handover list: cohort members carrying a belantamab claim that lot will
# act on.
#
# Nothing here is adjudicated. The pre-index half is criterion 9, so those
# patients are already gone; the index-onward half is lot's no_belantamab.
# This is only the handover list.
#
# Read off NDMM_COHORT, so the claim is bounded by the patient's own ENDDATE
# and not just by the study end. That bound is the point: lot reads claims up
# to OBS_END_DT, so a belantamab claim after a patient died would be in the
# study period, in this table, and invisible to lot - listing it would
# overstate what the LOT run will remove.
#
# ENDDATE is lot's OBS_END_DT under the primary analysis. Under
# CENSOR_AT_DISENROLLMENT lot narrows further, which this cannot know, so on a
# sensitivity run this count is an upper bound.
build_ndmm_belantamab_reconcile <- function(con, cfg) {
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_BELANTAMAB_RECONCILE')} AS
    SELECT c.PATID                          AS PATID,
           c.INDEX_DATE                     AS INDEX_DATE,
           b.bel_dt                         AS BEL_DT,
           datediff(b.bel_dt, c.INDEX_DATE) AS DAYS_FROM_INDEX
    FROM {wrk('NDMM_COHORT')} c
    INNER JOIN {NDMM_BELANTAMAB_TX} b
            ON b.PATID = c.PATID
           AND b.bel_dt <= c.ENDDATE
    ORDER BY c.PATID, b.bel_dt"))
  got <- db_q(con, glue("
    SELECT count(DISTINCT PATID) AS n_pat, count(*) AS n_claims
    FROM {wrk('NDMM_BELANTAMAB_RECONCILE')}"))
  log_msg("Belantamab in the cohort this build writes: ",
          format(got$n_pat, big.mark = ","), " patient(s), ",
          format(got$n_claims, big.mark = ","), " claim(s) -> ",
          wrk("NDMM_BELANTAMAB_RECONCILE"))
  log_msg("  Every claim here is on or after the index and inside the ",
          "patient's follow-up, so lot's no_belantamab removes these patients: ",
          "expect the LOT population smaller by ", format(got$n_pat, big.mark = ","),
          ".")
  invisible(got)
}

# Every plasma-cell-looking tumour group the other-cancer code list carries,
# and whether the override covers it.
#
# The override exists because the criterion is another cancer "distinct from
# the index MM", and these are the index disease or its precursor. Which labels
# the production list stores is not visible from here, and the remission
# wording is where it is likely to differ - so the run writes what it found.

# Every code in an overridden group. The group table says which labels are
# kept; this says which codes that is. The labels are one per code and the
# match is on the whole string, so SECONDARY MALIGNANT NEOPLASM OF BONE keeps
# C79.51 and leaves C79.52 - whose label ends OF BONE MARROW - excluded. That
# is visible here and nowhere else.
build_ndmm_mm_adjacent_codes <- function(con, cfg) {
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_MM_ADJACENT_CODES')} AS
    SELECT dx                       AS DX,
           icd_family               AS ICD_FAMILY,
           is_mm_adjacent_override  AS OVERRIDE,
           tumor_group              AS TUMOR_GROUP
    FROM {NDMM_OTHER_MALIG_CODES}
    WHERE is_mm_adjacent_override = 1
    ORDER BY TUMOR_GROUP, ICD_FAMILY, DX"))
  n <- as.integer(db_q(con, glue(
    "SELECT count(*) AS n FROM {wrk('NDMM_MM_ADJACENT_CODES')}"))$n)
  log_msg("  ", n, " codes are kept as the index disease rather than another ",
          "cancer -> ", wrk("NDMM_MM_ADJACENT_CODES"))
  invisible(n)
}

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
