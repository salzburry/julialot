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

  # eligible_1l_agents.csv, if the study team has written one. Its deny rows
  # are the same thing as NDMM_INDEX_EXCLUDED_ABBRS and join them; its allow
  # rows turn the whole thing round - see below.
  el    <- load_eligible_agents_csv(nndm_config()$eligible_1l_csv)
  abbrs <- c(split_setting(NDMM_INDEX_EXCLUDED_ABBRS), el$deny)
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

  # An allowlist is the same view read the other way round: everything NOT
  # named is ineligible. One predicate, and the four-arm scan below needs no
  # change - it already anti-joins this view. Added last so the checks above
  # still run over the named terms one at a time.
  allow_term <- NULL
  if (length(el$allow)) {
    allow_in <- paste(sprintf("'%s'", sq(el$allow)), collapse = ", ")
    allow_term <- list(
      what = paste0("the allowlist (", length(el$allow), " agents)"),
      sql  = sprintf("upper(trim(med_abbr)) NOT IN (%s)", allow_in))
  }

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_INDEX_INELIGIBLE} AS
    SELECT DISTINCT code_type, code
    FROM {NDMM_MMA_CODELIST}
    WHERE ", paste(vapply(c(terms, list(allow_term)[!is.null(allow_term)]),
                          function(t) t$sql, character(1)),
                   collapse = "\n       OR "), "
  "))

  # Each allowed agent has to exist, and for the same reason the others do: an
  # abbreviation that matches nothing is not a permission, it is a typo, and
  # under an allowlist a typo does not read as a restriction that applies to
  # nothing - it silently bars an agent that should have been let through.
  for (a in el$allow) {
    n <- as.integer(db_q(con, glue(
      "SELECT count(*) AS n FROM {NDMM_MMA_CODELIST}
       WHERE upper(trim(med_abbr)) = '{sq(a)}'"))$n)
    if (is.na(n) || n == 0)
      stop("The eligible-1L agent list allows '", a, "', which matches no row ",
           "of cl_mma_codelist.csv. Under an allowlist that is not a ",
           "restriction applying to nothing - it is an agent that should set ",
           "an index and cannot, so its patients leave the cohort at attrition ",
           "step 3. Check it against 'SELECT DISTINCT med_abbr FROM ",
           NDMM_MMA_CODELIST, "'.", call. = FALSE)
  }
  if (!is.null(allow_term)) {
    n_barred <- as.integer(db_q(con, glue(
      "SELECT count(DISTINCT med_abbr) AS n FROM {NDMM_MMA_CODELIST}
       WHERE {allow_term$sql}"))$n)
    log_msg("  Allowlist in force: ", n_barred, " agent(s) on the code list ",
            "cannot set a 1L index")
  }

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
# eligibility rule - and it is a stand-alone document. So this build does not
# invent an allowlist. It writes the sheet one would be built from: every agent
# on the code list, whether this run let it set an index, and how many it set.
# Fill in codelists/eligible_1l_agents.csv from this and re-run.
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
    -- an allowlist the winners are by definition the allowed ones, so a table
    -- of winners could not be used to build the allowlist - which is what this
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
  log_msg("  Review these against S6.2.1.1. Anything restricted to later lines ",
          "belongs in codelists/eligible_1l_agents.csv with eligible=0, or ",
          "list the eligible ones with eligible=1 to turn it into an allowlist.")
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
  arm <- function(tbl, dt, match_sql) glue("
      SELECT DISTINCT cast(t.PATID as string) AS PATID,
             cast(t.{dt} as date) AS bel_dt
      FROM {tbl} t
      INNER JOIN {NDMM_BELANTAMAB_CODES} c ON {match_sql}
      WHERE cast(t.{dt} as date) <= date('{cfg$study_end}')")
  db_exec(con, paste0(glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BELANTAMAB_TX} AS"),
    arm(medical_tbl, "FST_DT",  txt_match("PROC_CD", "'HCPCS','CPT'")), "\n      UNION\n",
    arm(medical_tbl, "FST_DT",  txt_match("BILL_PROC_CD", "'HCPCS'")),  "\n      UNION\n",
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
# Every label on the other-cancer code list, and the group this run pairs it
# under. The sheet primary_tumor_groups.csv is filled in from: anything whose
# PRIMARY_GROUP is still its own label is a label that can only confirm itself.
build_ndmm_other_malig_groups <- function(con, cfg) {
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_OTHER_MALIG_GROUPS')} AS
    SELECT tumor_group                   AS TUMOR_GROUP,
           max(primary_group)            AS PRIMARY_GROUP,
           count(*)                      AS N_CODES,
           max(is_mm_adjacent_override)  AS OVERRIDDEN
    FROM {NDMM_OTHER_MALIG_CODES}
    GROUP BY tumor_group
    ORDER BY PRIMARY_GROUP, TUMOR_GROUP"))
  got <- db_q(con, glue("
    SELECT count(*) AS n_labels, count(DISTINCT PRIMARY_GROUP) AS n_groups,
           sum(CASE WHEN OVERRIDDEN = 0 AND PRIMARY_GROUP = TUMOR_GROUP
                    THEN 1 ELSE 0 END) AS n_alone
    FROM {wrk('NDMM_OTHER_MALIG_GROUPS')}"))
  log_msg("Other-cancer labels: ", got$n_labels, " on the code list, pairing as ",
          got$n_groups, " group(s); ", got$n_alone,
          " exclusionary label(s) can only confirm themselves -> ",
          wrk("NDMM_OTHER_MALIG_GROUPS"))
  invisible(got)
}

# What the pairing grain is costing, without needing a map to exist first.
#
# Criterion 7 Path B is two outpatient claims within 30 days for the same
# cancer. "Same" is a code-list label here, and a label is a code description:
# one cancer at two subsites, or one coded in remission and once not, is two
# labels, and the claims never pair. So the criterion under-detects and the
# cohort is too large.
#
# The map fixes it, but nobody can size the problem from an empty map. These
# three rows can be computed with no map at all, off the events view the
# criterion itself reads, so the claim scan does not run again:
#
#   same code-list label - the finest grain, and what apr_30_2026 does
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
  db_exec(con, paste0(glue("CREATE OR REPLACE TABLE {wrk('NDMM_OTHER_MALIG_GRAIN')} AS\n"),
    by("same code-list label", ", tumor_group"), "\n    UNION ALL\n",
    by("as configured",        ", primary_group"), "\n    UNION ALL\n",
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
# Protocol Rev Round 2 S6.2.1.1 asks for continuous enrollment "from index date
# until the earliest of 3-months post index or death, with no gaps". This build
# uses one day - the index date itself - because the study team said so in the
# build request. That is a relay, not a controlled document, and it is the one
# setting in this package resting on one. Nobody can sign it off against a
# number nobody has, so this is the number: how many patients pass criterion 5
# at each window, and how many reach the final cohort there.
#
# One pass over the strict spans, cross-joined to the windows, so the whole
# table costs about what the flag itself costs. It does not change the cohort:
# the run still applies NDMM_FU_CE_DAYS.
#
# The windows are derived, not listed: whatever NDMM_FU_CE_DAYS is set to is in
# the table beside the protocol's 90, so the table always contains the row this
# run actually used.
ndmm_fu_ce_windows <- function() sort(unique(c(NDMM_FU_CE_DAYS, 0L, 30L, 60L, 90L)))

build_ndmm_fu_ce_counts <- function(con, cfg) {
  days <- ndmm_fu_ce_windows()
  # 90 days is how "3 months" is applied, because NDMM_FU_CE_DAYS is a day
  # count. add_months(.., 3) is the exact reading, and it lands 0-2 days later.
  # Reported so the difference is a number rather than an assumption - this
  # build cannot currently be set to it, which the README says.
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
           -- rather than one criterion's count.
           count(DISTINCT CASE WHEN cov.CE_fu = 1
                                AND f.CE_pre_lot1_12mo         = 1
                                AND f.NO_PRIOR_MM_TX           = 1
                                AND f.NO_OTHER_CANCER_PRE_LOT1 = 1
                                AND f.NO_PREGNANCY             = 1
                                AND f.NO_BELANTAMAB            = 1
                               THEN cov.PATID END)         AS N_COHORT,
           max(CASE WHEN cov.sort_key = {NDMM_FU_CE_DAYS} THEN 1 ELSE 0 END)
                                                           AS IS_THIS_RUN
    FROM cov
    INNER JOIN {NDMM_FLAGS_ALL} f ON f.PATID = cov.PATID
    GROUP BY cov.rule, cov.sort_key
    ORDER BY cov.sort_key"))
  got <- db_q(con, glue("SELECT * FROM {wrk('NDMM_FU_CE_COUNTS')}"))
  log_msg("Follow-up CE (criterion 5), by window. This run applies ",
          NDMM_FU_CE_DAYS, " day(s); the protocol asks for 3 months.")
  for (i in seq_len(nrow(got)))
    log_msg("    ", if (got$IS_THIS_RUN[i] == 1L) "->" else "  ", " ",
            got$FU_CE_RULE[i], ": ",
            format(got$N_PASSING_CRITERION_5[i], big.mark = ","),
            " pass, cohort ", format(got$N_COHORT[i], big.mark = ","))
  log_msg("  FU_CE_DAYS=", NDMM_FU_CE_DAYS, " comes from the study team via the ",
          "build request and is not written in any controlled document. See README.")
  invisible(got)
}

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
# Every code in an overridden group, in the shape mm_adjacent_overrides.csv
# wants. The group table says which labels are kept; this says which codes that
# actually is, so deciding one of them is a copy and an edit rather than a
# research task. OVERRIDE is what this run did, so a filled-in CSV shows up here
# as the value it set.
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
