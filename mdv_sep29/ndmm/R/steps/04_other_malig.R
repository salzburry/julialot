# Another active cancer in the 12 months before LOT1.
#

build_ndmm_other_malig_codes <- function(con) {
  src <- load_codelist_csv(
    "other_malig.csv",
    c("code_type", "code", "icd10", "tumor_group"))
  met_pred <- ndmm_metastatic_sql("om.icd10")
  met_own  <- ndmm_metastatic_own_group_sql("om.icd10")
  ovr_in <- paste(sprintf("'%s'", gsub("'", "''", ndmm_mm_adjacent_groups())),
                  collapse = ", ")
  # An empty override list is a choice, not a bug - only mm_dx.csv keeps a code
  # then. IN () is a syntax error and IN (NULL) is never true, so it stands in.
  if (!nzchar(ovr_in)) ovr_in <- "NULL"
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_OTHER_MALIG_CODES} AS
    -- Normalised first, then joined, every column qualified, so no name can
    -- bind to the wrong relation.
    WITH om AS (
      SELECT DISTINCT
             upper(tumor_group) AS tumor_group,
             upper(trim(code_type)) AS code_type,
             upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code,
             -- The ICD-10 code the row stands for: its own column, or the
             -- code itself on an ICD10 row. check_code_types() refused a
             -- DISEASECODE row without one.
             upper(regexp_replace(trim(coalesce(icd10,
                     CASE WHEN upper(trim(code_type)) = 'ICD10' THEN code END)),
                   '[^A-Za-z0-9]', '')) AS icd10
      FROM {src}
      WHERE code IS NOT NULL AND tumor_group IS NOT NULL
        -- And non-blank once normalised: '---' would otherwise match every
        -- diagnosis record with a missing code. See 03_prior_therapy.R.
        AND regexp_replace(trim(code), '[^A-Za-z0-9]', '') <> ''
    ),
    -- The criterion is another cancer, meaning other than the index MM, and
    -- anything on the diagnosis code list is the index disease by definition.
    -- Matched on the code itself, or on the ICD-10 code both lists say it is,
    -- so an MDV disease code for myeloma cannot exclude a myeloma patient
    -- because the two lists spell it with different MDV codes.
    mm AS (SELECT DISTINCT code_type, code, icd10 FROM {NDMM_MM_DX_CODES}),
    on_mm AS (
      SELECT DISTINCT om.code_type, om.code
      FROM om
      INNER JOIN mm
              ON (mm.code_type = om.code_type AND mm.code = om.code)
              OR (mm.icd10 IS NOT NULL AND mm.icd10 = om.icd10)
    )
    SELECT om.tumor_group,
           om.code_type,
           om.code,
           om.icd10,
           CASE WHEN trim(om.tumor_group) IN ({ovr_in}) OR h.code IS NOT NULL
                THEN 1 ELSE 0 END AS is_mm_adjacent_override,
           -- The group two outpatient months must share to confirm each other:
           -- the ICD-10 category - the first three characters - except that
           -- metastatic codes form one group. See 00b_lot1_index.R and
           -- DECISIONS.md #4.
           CASE WHEN {met_pred} THEN 'MET'
                ELSE substr(om.icd10, 1, 3) END AS primary_group,
           -- The counterfactuals NDMM_OTHER_MALIG_GRAIN prices.
           {met_own} AS category_group,
           CASE WHEN {met_pred} THEN {met_own} END AS met_prefix,
           CASE WHEN {met_own} = 'C77' THEN {met_own}
                WHEN {met_pred} THEN 'MET'
                ELSE substr(om.icd10, 1, 3) END AS grp_wo_nodal,
           CASE WHEN {met_own} = 'C800' THEN {met_own}
                WHEN {met_pred} THEN 'MET'
                ELSE substr(om.icd10, 1, 3) END AS grp_wo_dissem
    FROM om
    LEFT JOIN on_mm h ON h.code_type = om.code_type AND h.code = om.code
  "))
  report_metastatic_group(con)

  # The core labels THIS MODE applies, not all four of them. The remission
  # variants are a proposal rather than a contract with the code list, so their
  # absence is reported rather than fatal.
  #
  # Derived from the mode, or the two narrow modes can never pass: mgus_only
  # overrides one core label and none overrides zero, so a fixed expectation of
  # four fails exactly when the mode is doing what it was asked to do. An empty
  # requirement is the right answer for none - there is no label to go missing.
  req_labels <- intersect(NDMM_MM_ADJACENT_OVERRIDE, ndmm_mm_adjacent_groups())
  req    <- gsub("'", "''", req_labels)
  req_in <- paste(sprintf("'%s'", req), collapse = ", ")
  if (!nzchar(req_in)) req_in <- "NULL"
  n_exp     <- length(req_labels)
  n_matched <- tryCatch(as.integer(db_q(con, glue("
    SELECT count(DISTINCT tumor_group) AS n
    FROM {NDMM_OTHER_MALIG_CODES}
    WHERE is_mm_adjacent_override = 1
      AND upper(trim(tumor_group)) IN ({req_in})
  "))$n), error = function(e) NA_integer_)
  # Stopping rather than logging. An unmatched label means the
  # override is a silent no-op for that tumour group, so patients whose only
  # other cancer is MM-adjacent are excluded as having another cancer - a
  # smaller cohort, with nothing in the attrition saying why. Its own comment
  # calls that a run-review blocker, so stop rather than warn.
  if (is.na(n_matched) || n_matched < n_exp)
    stop("NDMM other-cancer override: matched ",
         if (is.na(n_matched)) "no" else n_matched, " of ", n_exp,
         " expected MM-adjacent tumor_group labels under ",
         "NDMM_MM_ADJACENT_STATES=", NDMM_MM_ADJACENT_STATES,
         ". The unmatched ones are ",
         "not overridden, so patients would be excluded for an MM-adjacent ",
         "condition. Run 'SELECT DISTINCT tumor_group FROM ",
         NDMM_OTHER_MALIG_CODES, "' on the warehouse and align ",
         "NDMM_MM_ADJACENT_OVERRIDE to the stored labels.", call. = FALSE)
  log_msg("  NDMM other-cancer override: matched all ", n_exp,
          " expected MM-adjacent tumor_group labels")
  invisible(n_matched)
}

# Patients with another active cancer in [LOT1_START - 365, LOT1_START - 1].
# Two ways to qualify:
#
#   - one inpatient diagnosis for a tumour group inside the window, or
#   - two outpatient diagnoses in claim months at most
#     NDMM_OTHER_MALIG_WINDOW_MONTHS apart for the same tumour group, both
#     inside the window - the Optum rule's two claims within 30 days, at the
#     month grain MDV dates a diagnosis to
#
# A diagnosis is dated to the first of its claim month, so the index month's
# diagnoses fall inside the baseline (unless the index is the 1st) and the
# month holding LOT1_START - 365 falls outside it. DECISIONS.md, "MDV".
#
# Inpatient is the care setting alone here, whatever NDMM_MDV_IP_RULE says:
# the FF1 conditions are about the myeloma's own treatment episode, and an
# unrelated cancer's inpatient record needs none of them.
build_ndmm_other_malig_pre_lot1 <- function(con) {
  lower <- glue("date_sub(date('{NDMM_LOT1_FROM}'), {NDMM_PRE_LOT1_DAYS})")
  upper <- glue("date('{cfg$study_end}')")
  cancer <- if (NDMM_MDV_REQUIRE_CANCERFLG) "AND d.CANCER = 1" else ""
  keep <- glue("c.is_mm_adjacent_override = 0 AND d.CONFIRMED = 1 {cancer}
        AND (d.INPT = 1 OR d.OUTPT = 1)
        AND d.DX_MONTH BETWEEN {lower} AND {upper}")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_OTHER_MALIG_EVENTS} AS
    SELECT DISTINCT m.PATID, m.tumor_group, m.primary_group, m.category_group,
           m.grp_wo_nodal, m.grp_wo_dissem,
           m.DX_MONTH AS event_dt,
           m.INPT     AS inpatient_flg
    FROM {ndmm_dx_join(NDMM_OTHER_MALIG_CODES,
                       'c.tumor_group, c.primary_group, c.category_group, c.grp_wo_nodal, c.grp_wo_dissem',
                       keep)} m"))

  # The rule, over that. Path B pairs on primary_group - the ICD category -
  # not on tumor_group. Two outpatient months for one cancer coded at different
  # subsites are one primary tumour type and confirm each other.
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_OTHER_MALIG_PATIDS} AS
    WITH inpatient_flag AS (
      SELECT DISTINCT PATID, primary_group AS grp, event_dt
      FROM {NDMM_OTHER_MALIG_EVENTS} WHERE inpatient_flg = 1
    ),
    outpatient_dates AS (
      SELECT DISTINCT PATID, primary_group AS grp, event_dt
      FROM {NDMM_OTHER_MALIG_EVENTS} WHERE inpatient_flg = 0
    ),
    with_next AS (
      SELECT PATID, grp, event_dt,
             lead(event_dt) OVER (PARTITION BY PATID, grp ORDER BY event_dt) AS next_dt
      FROM outpatient_dates
    ),
    outpatient_pairs AS (
      SELECT PATID, grp, event_dt AS first_dt, next_dt,
             {mdv_month_diff_sql('next_dt', 'event_dt')} AS diff_months
      FROM with_next WHERE next_dt IS NOT NULL
    ),
    l1 AS (
      SELECT cast(PATID as string) AS PATID, LOT1_START_DT,
             date_sub(LOT1_START_DT, {NDMM_PRE_LOT1_DAYS}) AS pre_lot1_start,
             date_sub(LOT1_START_DT, 1)                  AS pre_lot1_end
      FROM {NDMM_LOT1_STARTS}
    ),
    hits AS (
      SELECT DISTINCT l1.PATID
      FROM l1
      LEFT JOIN inpatient_flag ip
             ON cast(ip.PATID as string) = l1.PATID
            AND ip.event_dt BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end
      LEFT JOIN outpatient_pairs op
             ON cast(op.PATID as string) = l1.PATID
            AND op.diff_months <= {NDMM_OTHER_MALIG_WINDOW_MONTHS}
            AND op.first_dt BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end
            -- Both claims in the baseline, not just the first. The source
            -- bounded first_dt alone, so a claim the day before the index and
            -- its confirmation a month after it excluded the patient on one
            -- baseline claim - and the criterion is other cancer IN the 1L
            -- baseline. next_dt is always after first_dt, so the lower bound
            -- is redundant; it is written out so the pair reads as a pair.
            AND op.next_dt  BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end
      WHERE ip.PATID IS NOT NULL OR op.PATID IS NOT NULL
    )
    SELECT PATID FROM hits
  "))
}
