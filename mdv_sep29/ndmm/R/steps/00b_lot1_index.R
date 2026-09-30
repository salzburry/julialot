# The 1L index date, from MDV acts.
#
# The index is the date of the first act for an eligible MM treatment on or
# after the MM diagnosis - anything but belantamab - and on or after
# NDMM_LOT1_FROM.
#
# From acts, not from a built line. A line start is an output of the
# line-building rules, and reading one would make this build wait on a LOT run
# when LOT runs over the cohort this build produces.
#
# One source - NDMM_MM_TX, every MM therapy act, built in 03_prior_therapy.R -
# where the Optum build had five claim arms. Steroids are already dropped from
# it: a steroid act alone is supportive care, not the start of a line.

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
  # cohort on an assumption nothing has checked.
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
  # What those rows found in the drug master. None is possible - belantamab
  # was not on the Japanese market for most of the study period - and then
  # criterion 9 and lot's no_belantamab remove nobody. That is a finding, not a
  # failure, so it goes on the run's row rather than stopping it.
  nr <- tryCatch(as.integer(db_q(con, glue("
    SELECT count(DISTINCT RECEIPTCODE) AS n FROM {NDMM_MMA_RECEIPTS}
    WHERE upper(trim(med_abbr)) = '{NDMM_BELANTAMAB_ABBR}'"))$n),
    error = function(e) NA_integer_)
  if (!isTRUE(nr > 0)) {
    log_msg("  WARNING: the belantamab rows resolve to no receipt code, so no ",
            "act can be belantamab and its two exclusions remove nobody.")
    options(ndmm_findings = union(getOption("ndmm_findings", character(0)),
                                  "belantamab_unresolved"))
  } else
    log_msg("  Belantamab resolves to ", nr, " receipt code(s)")
  invisible(n)
}

# Receipt codes that may not set the index: belantamab always, plus anything
# named in NDMM_INDEX_EXCLUDED_ABBRS or NDMM_INDEX_EXCLUDED_CODES. Empty beyond
# belantamab by default, because belantamab is the only therapy named as
# restricted to later lines.
#
# Resolved to receipt codes, because that is what the index scan joins on: an
# agent named by abbreviation bars every receipt code its rows resolve to, and
# a code bars that one receipt code however the list brought it in.
ndmm_split_setting <- function(x) {
  v <- trimws(strsplit(x, "[,|]")[[1]])
  v[nzchar(v)]
}
ndmm_sq <- function(x) gsub("'", "''", x, fixed = TRUE)

# The abbreviation half of the bar, one predicate per entry over a med_abbr
# column: belantamab exactly, the way build_ndmm_belantamab_codes() and lot
# both match it, then each NDMM_INDEX_EXCLUDED_ABBRS pattern, since a prefix is
# useful in a hand-typed override. NDMM_INDEX_AGENTS reads the same list, so it
# reports what the run barred - not only what the bar found receipt codes for.
ndmm_index_abbr_terms <- function() {
  c(list(list(what = paste0("abbreviation '", NDMM_BELANTAMAB_ABBR, "'"),
              sql  = sprintf("upper(trim(med_abbr)) = '%s'",
                             ndmm_sq(toupper(NDMM_BELANTAMAB_ABBR))),
              on   = NDMM_MMA_CODELIST)),
    lapply(ndmm_split_setting(NDMM_INDEX_EXCLUDED_ABBRS), function(a)
      list(what = paste0("abbreviation pattern '", a, "'"),
           sql  = sprintf("upper(trim(med_abbr)) LIKE '%s'", ndmm_sq(toupper(a))),
           on   = NDMM_MMA_CODELIST)))
}

build_ndmm_index_ineligible_codes <- function(con) {
  norm <- function(x) toupper(gsub("[^A-Za-z0-9]", "", x))
  sq   <- ndmm_sq
  codes <- ndmm_split_setting(NDMM_INDEX_EXCLUDED_CODES)

  # Each entry becomes one predicate over NDMM_MMA_RECEIPTS, and one thing to
  # check matched something.
  terms <- ndmm_index_abbr_terms()
  for (cd in codes) {
    parts <- strsplit(cd, ":", fixed = TRUE)[[1]]
    ty <- if (length(parts) >= 2L) toupper(trimws(parts[1])) else ""
    if (nzchar(ty) && ty != "RECEIPTCODE")
      stop("NDMM_INDEX_EXCLUDED_CODES entry '", cd, "' names type ", ty,
           ". Codes are barred by receipt code - RECEIPTCODE:<code>, or a bare ",
           "code; bar a NAME_ENG pattern's agent by its abbreviation instead.",
           call. = FALSE)
    code <- norm(if (nzchar(ty)) parts[2] else parts[1])
    terms[[length(terms) + 1L]] <- list(
      what = paste0("receipt code ", code),
      sql  = sprintf("RECEIPTCODE = '%s'", sq(code)),
      on   = NDMM_MMA_RECEIPTS)
  }

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_INDEX_INELIGIBLE} AS
    SELECT DISTINCT RECEIPTCODE
    FROM {NDMM_MMA_RECEIPTS}
    WHERE ", paste(vapply(terms, function(t) t$sql, character(1)),
                   collapse = "\n       OR "), "
  "))

  # Every entry after belantamab has to match something. Left unchecked, a name
  # or a code that is not on the list reads as an applied restriction and
  # applies to nothing - the failure the belantamab check already guards.
  for (t in terms[-1]) {
    n <- as.integer(db_q(con, glue(
      "SELECT count(*) AS n FROM {t$on} WHERE {t$sql}"))$n)
    if (is.na(n) || n == 0)
      stop("The 1L index exclusions name ", t$what, ", which matches no row of ",
           "cl_mma_codelist.csv or the receipt codes it resolves to. It would ",
           "read as a restriction on which agents can set the index and apply ",
           "to nothing. Check it against 'SELECT * FROM ", NDMM_MMA_RECEIPTS, "'.",
           call. = FALSE)
  }
  if (length(terms) > 1L)
    log_msg("  Barred from setting the index, beyond belantamab: ",
            paste(vapply(terms[-1], function(t) t$what, character(1)),
                  collapse = ", "))
  invisible(TRUE)
}

# The first eligible MM treatment act on or after the MM diagnosis and on or
# after the eligible-treatment cutoff. That date is the NDMM index. An act is
# dated to the day, so this is the Optum rule exactly; only the diagnosis it is
# compared with is dated to its month.
build_ndmm_lot1_index <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_INDEX_TX} AS
    SELECT t.PATID, t.tx_dt, t.med_abbr
    FROM {NDMM_MM_TX} t
    INNER JOIN {NDMM_BASE_COHORT} b ON b.PATID = t.PATID
    LEFT JOIN {NDMM_INDEX_INELIGIBLE} bl ON bl.RECEIPTCODE = t.RECEIPTCODE
    WHERE bl.RECEIPTCODE IS NULL
      AND t.tx_dt >= b.MM_DX_DT
      AND t.tx_dt >= date('{NDMM_LOT1_FROM}')
      AND t.tx_dt <= date('{cfg$study_end}')"))
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
# Every agent on the code list, whether this run let it set an index, and how
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
    -- Barred by what the run was told, not by what the bar resolved to: an
    -- agent named in the exclusions is ineligible whether or not its rows
    -- found a receipt code, and a receipt code named outright bars its agent.
    -- Read off receipts alone, a PANO pattern matching no drug reported PANO
    -- eligible while the metadata said it was barred.
    barred AS (
      SELECT med_abbr FROM universe
      WHERE {paste(vapply(ndmm_index_abbr_terms(), function(t) t$sql, character(1)),
                   collapse = ' OR ')}
      UNION
      SELECT upper(trim(r.med_abbr)) AS med_abbr
      FROM {NDMM_MMA_RECEIPTS} r
      INNER JOIN {NDMM_INDEX_INELIGIBLE} i ON i.RECEIPTCODE = r.RECEIPTCODE
    ),
    -- Mapping coverage, reported apart from eligibility: how many receipt
    -- codes each agent's rows resolved to.
    coverage AS (
      SELECT upper(trim(med_abbr)) AS med_abbr, count(DISTINCT RECEIPTCODE) AS n_codes
      FROM {NDMM_MMA_RECEIPTS}
      GROUP BY upper(trim(med_abbr))
    )
    SELECT u.med_abbr                              AS MED_ABBR,
           CASE WHEN b.med_abbr IS NULL THEN 1 ELSE 0 END AS ELIGIBLE,
           coalesce(cv.n_codes, 0)                 AS N_RECEIPT_CODES,
           coalesce(n.N_PATIENTS, 0)               AS N_PATIENTS
    FROM universe u
    LEFT JOIN barred b ON b.med_abbr = u.med_abbr
    LEFT JOIN coverage cv ON cv.med_abbr = u.med_abbr
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
# MAP_MED_TYPE LIKE 'BEL%', so this answers in that shape from MDV acts.
#
# The "in any LOT" exclusion is not applied here - lines do not exist until lot
# has run over this cohort, so it is a line criterion there. What this builds
# is the flag and, below, the list of cohort members carrying a belantamab act.
# Every act is kept with its date.
build_ndmm_belantamab_patids <- function(con) {
  # The study period, both ends, as in the Optum build. NDMM_MM_TX reaches back
  # a year further for the prior-therapy baseline, so the lower bound is
  # applied here rather than inherited.
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BELANTAMAB_TX} AS
    SELECT DISTINCT PATID, tx_dt AS bel_dt
    FROM {NDMM_MM_TX}
    WHERE upper(trim(med_abbr)) = '{NDMM_BELANTAMAB_ABBR}'
      AND tx_dt >= date('{NDMM_STUDY_START}')
      AND tx_dt <= date('{cfg$study_end}')"))

  # PRE_LOT1 marks a belantamab act strictly before the 1L index. That half is
  # settled here because lot cannot see it - map_stacked starts at the cohort's
  # INDEX_DATE. The other half is the line criterion there.
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
           count(*)                      AS N_CODES,
           count(DISTINCT tumor_group)   AS N_LABELS,
           max(is_mm_adjacent_override)  AS ANY_OVERRIDDEN,
           min(tumor_group)              AS EXAMPLE_LABEL
    FROM {NDMM_OTHER_MALIG_CODES}
    GROUP BY primary_group
    ORDER BY PRIMARY_GROUP"))
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
# Criterion 7 Path B is two outpatient claim months, adjacent, for the same
# cancer (the Optum rule's two claims within 30 days). "Same" is a code-list
# label, and a label is a code description - one
# cancer at two subsites, or coded in remission once and not the next time, is
# two labels and the claims never pair. So the criterion under-detects.
#
# The map fixes it, but nobody can size the problem from an empty map. These
# three rows need no map, and come off the events view the criterion itself
# reads, so the claim scan does not run twice:
#
#   Same code-list label - the finest grain, and what an empty map gives
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
               WHERE next_dt IS NOT NULL
                 AND {mdv_month_diff_sql('next_dt', 'event_dt')} <= {NDMM_OTHER_MALIG_WINDOW_MONTHS}) op
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
    by("collapse without C77",   ", grp_wo_nodal"),  "\n    UNION ALL\n",
    by("collapse without C800",  ", grp_wo_dissem"), "\n    UNION ALL\n",
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
# This build asks for one day of follow-up - the index date itself
# (DECISIONS.md 1) - while the wider study text says three months. On MDV the
# criterion is observation, not enrollment: the patient's last record at the
# hospital reaches the window's end, or they died before it. Here is how many
# pass at each window, and how many reach the final cohort at each.
#
# It does not change the cohort - the run still applies NDMM_FU_CE_DAYS, and
# that value always appears in the table.
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
             -- Floored at the index. The index scan does not bound on death,
             -- so a 1L start CAN fall after a recorded death; unfloored,
             -- want_end would land before the window starts and a patient last
             -- seen before the index would pass. Such a patient fails
             -- criterion 5 at every window (alive_at_index below).
             greatest(
               least(CASE WHEN w.months IS NULL
                          THEN date_add(idx.LOT1_START_DT, w.sort_key)
                          ELSE add_months(idx.LOT1_START_DT, w.months) END,
                     date('{cfg$study_end}'),
                     coalesce(idx.DEATH_DT, date('{cfg$study_end}'))),
               idx.LOT1_START_DT)                        AS want_end,
             idx.LOT1_START_DT,
             CASE WHEN idx.DEATH_DT IS NULL OR idx.DEATH_DT >= idx.LOT1_START_DT
                  THEN 1 ELSE 0 END                      AS alive_at_index
      FROM idx CROSS JOIN w
    ),
    cov AS (
      SELECT want.PATID, want.sort_key, want.rule,
             max(CASE WHEN o.OBS_START_DT <= want.LOT1_START_DT
                       AND o.OBS_END_DT   >= want.want_end
                       AND want.alive_at_index = 1
                      THEN 1 ELSE 0 END) AS CE_fu
      FROM want
      LEFT JOIN {NDMM_OBS_PERIOD} o ON o.PATID = want.PATID
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
                                                           AS IS_THIS_RUN,
           -- Which cohort attempt these are. The table is CREATE OR REPLACE,
           -- so a rebuild silently replaces it - and anything reading it
           -- beside an older attempt's cohort had no way to tell. Every other
           -- run-scoped table here carries this; this one did not.
           {sql_text(run_id)}                              AS RUN_ID,
           current_timestamp()                             AS RECORDED_AT
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

# The list passed to lot: cohort members carrying a belantamab act that lot will
# act on.
#
# Nothing here is adjudicated. The pre-index half is criterion 9, so those
# patients are already gone; the index-onward half is lot's no_belantamab.
# This is only the list passed to lot.
#
# Read off NDMM_COHORT, so the act is bounded by the patient's own ENDDATE_CE
# and not just by the study end. That bound is the point: lot reads acts up
# to OBS_END_DT, so a belantamab act after a patient was last seen would be in the
# study period, in this table, and invisible to lot - listing it would
# overstate what the LOT run will remove.
#
# ENDDATE_CE is lot's OBS_END_DT: the MDV LOT build censors at the patient's
# last record (CENSOR_AT_DISENROLLMENT=TRUE, which on MDV means exactly that).
# A belantamab act is itself a record, so in practice only death and the study
# end can put one outside it.
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
           AND b.bel_dt <= c.ENDDATE_CE
    ORDER BY c.PATID, b.bel_dt"))
  got <- db_q(con, glue("
    SELECT count(DISTINCT PATID) AS n_pat, count(*) AS n_acts
    FROM {wrk('NDMM_BELANTAMAB_RECONCILE')}"))
  log_msg("Belantamab in the cohort this build writes: ",
          format(got$n_pat, big.mark = ","), " patient(s), ",
          format(got$n_acts, big.mark = ","), " act(s) -> ",
          wrk("NDMM_BELANTAMAB_RECONCILE"))
  log_msg("  Every act here is on or after the index and inside the ",
          "patient's follow-up, so lot's no_belantamab removes these patients: ",
          "expect the LOT population smaller by ", format(got$n_pat, big.mark = ","),
          ".")
  invisible(got)
}

# Every MDV record after a recorded death, for review (DECISIONS M12): an act
# after it, or a second death-coded discharge. The death date is the earliest
# FF1 death discharge as recorded, and it is never moved: a record after it is
# a contradiction in the data - a hospital recording against the
# wrong patient, a death code on the wrong discharge, or two hospitals'
# records joined under one key - and nothing here can say which. So each
# conflict is listed, not resolved.
#
# What the build does with one: a 1L start after the death fails criterion 5
# (06_flags.R), so that patient is not in the cohort (DEATH_BEFORE_INDEX = 1).
# A death after the 1L start keeps the patient, and a LOT run over the cohort
# stops observing at the death, so the later acts reach no line.
build_ndmm_death_conflicts <- function(con, cfg) {
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_DEATH_CONFLICTS')} AS
    WITH dead AS (
      SELECT cast(PATID as string) AS PATID, DEATH_DT
      FROM {NDMM_BASE_COHORT}
      WHERE DEATH_DT IS NOT NULL
    ),
    -- Every death-coded discharge, read before any aggregate: DEATH_DT is the
    -- earliest (00_mm_cohort.R), and a second date is a conflict of its own.
    deaths AS (
      SELECT cast(f.PATID as string) AS PATID,
             count(DISTINCT f.FF1_END_DT) AS n_dates, max(f.FF1_END_DT) AS last_dt
      FROM {NDMM_FF1} f
      INNER JOIN dead d ON d.PATID = cast(f.PATID as string)
      WHERE f.DIED = 1 AND f.FF1_END_DT IS NOT NULL
      GROUP BY cast(f.PATID as string)
    ),
    acts AS ({mdv_act_select()}
    ),
    after AS (
      SELECT d.PATID, count(*) AS n_acts, min(a.ACT_DT) AS first_dt,
             max(a.ACT_DT) AS last_dt
      FROM dead d
      INNER JOIN acts a ON cast(a.PATID as string) = d.PATID AND a.ACT_DT > d.DEATH_DT
      GROUP BY d.PATID
    ),
    tx AS (
      SELECT d.PATID, count(*) AS n_tx
      FROM dead d
      INNER JOIN {NDMM_MM_TX} t ON cast(t.PATID as string) = d.PATID AND t.tx_dt > d.DEATH_DT
      GROUP BY d.PATID
    )
    SELECT d.PATID,
           d.DEATH_DT,
           dt.n_dates                               AS N_DEATH_DATES,
           dt.last_dt                               AS LAST_DEATH_DT,
           l1.LOT1_START_DT,
           CASE WHEN l1.LOT1_START_DT > d.DEATH_DT THEN 1 ELSE 0 END AS DEATH_BEFORE_INDEX,
           coalesce(af.n_acts, 0)                   AS N_ACTS_AFTER_DEATH,
           coalesce(tx.n_tx, 0)                     AS N_MM_TX_AFTER_DEATH,
           af.first_dt                              AS FIRST_ACT_AFTER_DEATH,
           af.last_dt                               AS LAST_ACT_AFTER_DEATH,
           {sql_text(run_id)}                       AS RUN_ID
    FROM dead d
    INNER JOIN deaths dt ON dt.PATID = d.PATID
    LEFT JOIN after af ON af.PATID = d.PATID
    LEFT JOIN tx ON tx.PATID = d.PATID
    LEFT JOIN (SELECT cast(PATID as string) AS PATID, min(LOT1_START_DT) AS LOT1_START_DT
               FROM {NDMM_LOT1_STARTS} GROUP BY cast(PATID as string)) l1
           ON l1.PATID = d.PATID
    -- A conflict: an act after the death, or a second death-coded date.
    WHERE af.PATID IS NOT NULL OR dt.n_dates > 1
    ORDER BY d.PATID"))
  got <- db_q(con, glue("
    SELECT count(*) AS n_pat, coalesce(sum(DEATH_BEFORE_INDEX), 0) AS n_before
    FROM {wrk('NDMM_DEATH_CONFLICTS')}"))
  if (isTRUE(got$n_pat > 0)) {
    log_msg("WARNING: ", format(got$n_pat, big.mark = ","), " patient(s) have MDV ",
            "records after their recorded death - acts, or a second death-coded ",
            "discharge; ", format(got$n_before, big.mark = ","),
            " of them started 1L after it and fail criterion 5. The death dates ",
            "are kept as recorded -> ", wrk("NDMM_DEATH_CONFLICTS"))
    options(ndmm_findings = union(getOption("ndmm_findings", character(0)),
                                  "death_conflicts"))
  } else {
    log_msg("No MDV act after a recorded death.")
  }
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
    SELECT code_type                AS CODE_TYPE,
           code                     AS CODE,
           icd10                    AS ICD10,
           is_mm_adjacent_override  AS OVERRIDE,
           tumor_group              AS TUMOR_GROUP
    FROM {NDMM_OTHER_MALIG_CODES}
    WHERE is_mm_adjacent_override = 1
    ORDER BY TUMOR_GROUP, CODE_TYPE, CODE"))
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
    -- Plasma-cell wording only. REMISSION and RELAPSE were standalone terms
    -- here, and they are a disease STATE that any leukemia or lymphoma label
    -- carries too - so this reported unrelated cancers as MM-adjacent. The
    -- states that matter are already covered by the three disorder names.
    WHERE is_mm_adjacent_override = 1
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
