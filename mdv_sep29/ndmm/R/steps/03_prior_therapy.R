# MM therapy from MDV: the code list, what it resolves to, every act it
# matches, and criterion 6.
#
# The Optum build reads MM therapy from five claim arms - medical PROC_CD,
# BILL_PROC_CD and NDC, rx NDC, med_procedure PROC. MDV has one: every drug,
# oral or injected, inpatient or outpatient, is an act with a receipt code. So
# there is one scan, NDMM_MM_TX, and the index, the prior-therapy criterion and
# belantamab all read it - "MM treatment" means one thing here by
# construction.
#
# cl_mma_codelist.csv names a drug two ways (codelists/README.md):
#
#   RECEIPTCODE  the receipt code itself
#   NAME_ENG     a LIKE pattern over the drug master's English name,
#                '%bortezomib%', the way the OC rules find platinum
#                (receiptname_eng LIKE '%platin%')
#
# Both are resolved to receipt codes once, in NDMM_MMA_RECEIPTS, which is
# written out: it is the list of every receipt code this run treated as MM
# therapy, and the thing to read before believing a count.

# Steroid rows are dropped here, once, so every downstream query inherits the
# steroid exclusion without having to repeat it.
build_ndmm_mma_codelist <- function() {
  codelist_src <- load_codelist_csv(
    "cl_mma_codelist.csv",
    c("CL_CODE_TYPE", "CL_CODE", "CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR"))
  ster_in <- paste0("'", NDMM_STEROID_ABBRS, "'", collapse = ",")
  glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MMA_CODELIST} AS
    SELECT DISTINCT
           upper(trim(CL_CODE_TYPE)) AS code_type,
           -- A pattern keeps its wildcards and is lower-cased to meet the
           -- lower-cased master name; a receipt code is normalised like
           -- every other code here.
           CASE WHEN upper(trim(CL_CODE_TYPE)) = 'NAME_ENG'
                THEN lower(trim(CL_CODE))
                ELSE upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) END AS code,
           upper(trim(CL_MED_ABBR))  AS med_abbr
    FROM {codelist_src}
    WHERE CL_CODE      IS NOT NULL AND trim(CL_CODE)      <> ''
      AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
      -- Something to match once punctuation is gone. A receipt code of '---'
      -- would otherwise normalise to '', and a pattern of '%%' would match
      -- every drug in the master and make every patient previously treated.
      AND regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '') <> ''
      -- Compared as it is selected: trimmed and upper-cased. Untrimmed, a
      -- ' DEX ' row missed the list here and became 'DEX' in the select, so a
      -- steroid counted as MM therapy - an index, or a prior-therapy exclusion.
      AND upper(trim(coalesce(CL_MED_ABBR, ''))) NOT IN ({ster_in})
  ")
}

# The code types this build reads off cl_mma_codelist.csv. Its own list rather
# than shared with the trial or pregnancy scans - those read different sources,
# and one dropping a source must not quietly loosen this guard.
NDMM_MMA_CODE_TYPES <- c("RECEIPTCODE", "NAME_ENG")

# Every code-list row resolved to the receipt codes it stands for: a
# RECEIPTCODE row is its own code, a NAME_ENG row is every master code whose
# English name matches it. NAME_ENG is the master's name for that code, for
# the reader; a listed code missing from the master still counts, with no name.
build_ndmm_mma_receipts <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MMA_RECEIPTS} AS
    WITH m AS ({mdv_drug_select()}
    ),
    names AS (
      SELECT RECEIPTCODE, min(NAME_ENG) AS NAME_ENG FROM m GROUP BY RECEIPTCODE
    ),
    listed AS (
      SELECT c.code_type, c.code, c.med_abbr, c.code AS RECEIPTCODE
      FROM {NDMM_MMA_CODELIST} c
      WHERE c.code_type = 'RECEIPTCODE'
    ),
    matched AS (
      SELECT c.code_type, c.code, c.med_abbr, m.RECEIPTCODE
      FROM {NDMM_MMA_CODELIST} c
      INNER JOIN m ON c.code_type = 'NAME_ENG' AND m.NAME_ENG LIKE c.code
    ),
    r AS (SELECT * FROM listed UNION ALL SELECT * FROM matched)
    SELECT DISTINCT r.code_type, r.code, r.med_abbr, r.RECEIPTCODE, n.NAME_ENG
    FROM r
    LEFT JOIN names n ON n.RECEIPTCODE = r.RECEIPTCODE
  "))
}

# Every code type in cl_mma_codelist.csv has to be one the scan joins on, one
# receipt code may name one medication, and no row may name none.
#
# Prior therapy EXCLUDES, so a rule that cannot fire does not surface as a
# missing exclusion - it surfaces as a patient in the cohort who had MM therapy
# in the baseline. Checked on the resolved codes as well as the rows: two
# patterns that both match one master name ('%melphalan%' under MELP and a
# careless '%mel%' under another agent) make one act two agents' treatment,
# and NDMM_INDEX_AGENTS would then report an agent the patient never had.
check_ndmm_mma_code_types <- function(con) {
  want <- paste(sprintf("'%s'", NDMM_MMA_CODE_TYPES), collapse = ", ")
  bad <- db_q(con, glue("
    SELECT code_type, count(*) AS n
    FROM {NDMM_MMA_CODELIST}
    WHERE code_type NOT IN ({want})
    GROUP BY code_type ORDER BY code_type"))
  if (nrow(bad))
    stop("cl_mma_codelist.csv carries code type(s) no MDV source produces: ",
         paste0(bad$code_type, " (", bad$n, " code(s))", collapse = ", "),
         ".\nThey would match nothing, so a patient treated under those codes ",
         "would read as untreated in the baseline and stay in the cohort. The ",
         "scan joins on ", paste(NDMM_MMA_CODE_TYPES, collapse = ", "),
         "; retype the rows.", call. = FALSE)
  blank <- db_q(con, glue("
    SELECT count(*) AS n FROM {NDMM_MMA_CODELIST}
    WHERE med_abbr IS NULL OR trim(med_abbr) = ''"))
  if (blank$n[1] > 0)
    stop("cl_mma_codelist.csv has ", blank$n[1], " row(s) with a blank ",
         "CL_MED_ABBR. They match acts but name no agent, so they reach ",
         "NDMM_INDEX_AGENTS unnamed.", call. = FALSE)
  dup <- db_q(con, glue("
    SELECT RECEIPTCODE, count(DISTINCT med_abbr) AS n_meds,
           concat_ws(', ', sort_array(collect_set(med_abbr))) AS meds,
           min(NAME_ENG) AS name_eng
    FROM {NDMM_MMA_RECEIPTS}
    GROUP BY RECEIPTCODE
    HAVING count(DISTINCT med_abbr) > 1
    ORDER BY RECEIPTCODE"))
  if (nrow(dup))
    stop("cl_mma_codelist.csv resolves ", nrow(dup), " receipt code(s) to more ",
         "than one medication, e.g. ", dup$RECEIPTCODE[1], " (",
         dup$name_eng[1], ") -> ", dup$meds[1], ".\nThe scan joins on the ",
         "receipt code alone, so one act becomes one row per agent named and ",
         "the index can move or vanish where one of them is index-ineligible. ",
         "Narrow the NAME_ENG pattern(s) or list the codes outright.",
         call. = FALSE)
  n <- db_q(con, glue("SELECT count(DISTINCT RECEIPTCODE) AS n FROM {NDMM_MMA_RECEIPTS}"))$n
  if (!isTRUE(n > 0))
    stop("cl_mma_codelist.csv resolves to no receipt code at all: no listed ",
         "code, and no NAME_ENG pattern matching any name in ", mdv_tbl("drug"),
         ". Every patient would read as untreated.", call. = FALSE)
  # Patterns matching nothing are reported, not refused: the rollup names agents
  # that are not marketed in Japan, and a pattern for one of those correctly
  # finds nothing. Which ones they are is the reviewer's call.
  dead <- db_q(con, glue("
    SELECT c.med_abbr, c.code
    FROM {NDMM_MMA_CODELIST} c
    LEFT JOIN (SELECT DISTINCT code_type, code FROM {NDMM_MMA_RECEIPTS}) r
           ON r.code_type = c.code_type AND r.code = c.code
    WHERE c.code_type = 'NAME_ENG' AND r.code IS NULL
    ORDER BY c.med_abbr, c.code"))
  if (nrow(dead))
    log_msg("  NAME_ENG pattern(s) matching no drug in ", mdv_tbl("drug"), ": ",
            paste0(dead$med_abbr, " '", dead$code, "'", collapse = ", "),
            ". Right for an agent not sold in Japan; a misspelling otherwise.")
  log_msg("  MM therapy code list resolves to ", n, " receipt code(s) -> ",
          wrk("NDMM_MMA_RECEIPTS"), " (read it before believing a count)")
  invisible(TRUE)
}

# Every MM therapy act of every patient with an MM diagnosis record, over the
# widest window any reader asks for: the belantamab scan's study period, and
# the prior-therapy baseline of the earliest possible index. One scan of the
# act table rather than one per criterion.
build_ndmm_mm_tx <- function(con) {
  lower <- glue("least(date('{NDMM_STUDY_START}'), date_sub(date('{NDMM_LOT1_FROM}'), {NDMM_PRE_LOT1_DAYS}))")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MM_TX} AS
    SELECT DISTINCT a.PATID, a.ACT_DT AS tx_dt, r.med_abbr, a.RECEIPTCODE
    FROM ({mdv_act_select()}
    ) a
    INNER JOIN (SELECT DISTINCT PATID FROM {NDMM_MM_DX_EVENTS}) p ON p.PATID = a.PATID
    INNER JOIN (SELECT DISTINCT RECEIPTCODE, med_abbr FROM {NDMM_MMA_RECEIPTS}) r
            ON r.RECEIPTCODE = a.RECEIPTCODE
    WHERE a.ACT_DT BETWEEN {lower} AND date('{cfg$study_end}')
  "))
}

# Distinct PATIDs with any MM therapy act in [LOT1_START - NDMM_PRE_LOT1_DAYS,
# LOT1_START - 1]. Acts are dated to the day, so this window is the Optum
# window exactly.
build_ndmm_therapy_pre_lot1 <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_THERAPY_PRE_LOT1} AS
    SELECT DISTINCT t.PATID
    FROM {NDMM_MM_TX} t
    INNER JOIN {NDMM_LOT1_STARTS} l1 ON l1.PATID = t.PATID
    WHERE t.tx_dt BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                      AND date_sub(l1.LOT1_START_DT, 1)
  "))
}
