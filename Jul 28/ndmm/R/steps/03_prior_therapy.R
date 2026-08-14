# MM oncology therapy in the 12 months before LOT1.
#

build_ndmm_mma_codelist <- function() {
  codelist_src <- load_codelist_csv(
    "cl_mma_codelist.csv",
    c("CL_CODE_TYPE", "CL_CODE", "CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR"))
  ster_in <- paste0("'", NDMM_STEROID_ABBRS, "'", collapse = ",")
  glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MMA_CODELIST} AS
    SELECT upper(trim(CL_CODE_TYPE)) AS code_type,
           upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS code,
           upper(trim(CL_MED_ABBR))  AS med_abbr
    FROM {codelist_src}
    WHERE CL_CODE      IS NOT NULL AND trim(CL_CODE)      <> ''
      AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
      -- The two blank checks above read the raw value. A CL_CODE of '---'
      -- passes them and normalises to '', which is what a claim with a NULL
      -- PROC_CD also normalises to - so every such claim would read as prior
      -- MM therapy and the patient would be excluded. The NDC branches are
      -- worse: both sides pad to 00000000000. Check the normalised value too.
      AND regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '') <> ''
      AND (upper(trim(CL_CODE_TYPE)) <> 'NDC'
           OR regexp_replace(CL_CODE, '[^0-9]', '') <> '')
      AND upper(coalesce(CL_MED_ABBR, '')) NOT IN ({ster_in})
  ")
}

# The code types the MM-therapy scan joins on: HCPCS and CPT against
# medical.PROC_CD and med_procedure.PROC, HCPCS against BILL_PROC_CD, NDC
# against medical.NDC and rx.NDC. Its own list rather than shared with the
# trial or pregnancy scans - those read different arms, and one dropping an arm
# must not quietly loosen this guard.
NDMM_MMA_CODE_TYPES <- c("HCPCS", "CPT", "NDC")

# Every code type in cl_mma_codelist.csv has to be one the scan below joins on.
#
# The join is equality against a type this file names itself, so a row typed
# something no arm reads loads cleanly, passes every blank check, and matches no
# claim. Prior therapy EXCLUDES, so a rule that cannot fire does not surface as
# a missing exclusion - it surfaces as a patient in the cohort who had MM
# therapy in the baseline. The same guard 08_clintrial.R carries, over this
# scan's types.
#
# A blank medication is checked here too, the way LOT's blank_keys does. It
# still matches claims, so it does not weaken the exclusion, but it reaches
# NDMM_INDEX_AGENTS as an agent with no name.
check_ndmm_mma_code_types <- function(con) {
  want <- paste(sprintf("'%s'", NDMM_MMA_CODE_TYPES), collapse = ", ")
  bad <- tryCatch(db_q(con, glue("
    SELECT code_type, count(*) AS n
    FROM {NDMM_MMA_CODELIST}
    WHERE code_type NOT IN ({want})
    GROUP BY code_type ORDER BY code_type")), error = function(e) NULL)
  if (is.null(bad))
    stop("Could not check the code types in cl_mma_codelist.csv, so this run ",
         "cannot say whether every MM therapy code is reachable.", call. = FALSE)
  if (nrow(bad))
    stop("cl_mma_codelist.csv carries code type(s) no claim source produces: ",
         paste0(bad$code_type, " (", bad$n, " code(s))", collapse = ", "),
         ".\nThey would match nothing, so a patient treated under those codes ",
         "would read as untreated in the baseline and stay in the cohort. The ",
         "scan joins on ", paste(NDMM_MMA_CODE_TYPES, collapse = ", "),
         "; either retype the rows or add the source that reads them.",
         call. = FALSE)
  # One normalised (code_type, code) naming more than one medication. The scan
  # joins on the pair alone, so a colliding code multiplies a single claim into
  # one row per agent it names - and NDMM_INDEX_AGENTS then reports agents the
  # patient may never have had. Where one of the names is index-ineligible the
  # claim is dropped entirely and the index date moves or disappears. LOT stops
  # on the same collision in 01_codelists.R.
  dup <- tryCatch(db_q(con, glue("
    SELECT code_type, code, count(DISTINCT med_abbr) AS n_meds
    FROM {NDMM_MMA_CODELIST}
    GROUP BY code_type, code
    HAVING count(DISTINCT med_abbr) > 1
    ORDER BY code_type, code")), error = function(e) NULL)
  if (is.null(dup))
    stop("Could not check cl_mma_codelist.csv for one code naming several ",
         "medications.", call. = FALSE)
  if (nrow(dup))
    stop("cl_mma_codelist.csv has ", nrow(dup), " code(s) naming more than one ",
         "medication, e.g. ", dup$code_type[1], " ", dup$code[1], " (",
         dup$n_meds[1], " agents).\nThe scan joins on (code_type, code) alone, ",
         "so one claim becomes one row per agent named and the index can move ",
         "or vanish where one of them is index-ineligible.", call. = FALSE)
  blank <- tryCatch(db_q(con, glue("
    SELECT count(*) AS n FROM {NDMM_MMA_CODELIST}
    WHERE med_abbr IS NULL OR trim(med_abbr) = ''")), error = function(e) NULL)
  if (is.null(blank))
    stop("Could not check cl_mma_codelist.csv for blank medications.", call. = FALSE)
  if (blank$n[1] > 0)
    stop("cl_mma_codelist.csv has ", blank$n[1], " row(s) with a blank ",
         "CL_MED_ABBR. They match claims but name no agent, so they reach ",
         "NDMM_INDEX_AGENTS unnamed.", call. = FALSE)
  invisible(TRUE)
}

# Distinct PATIDs with any MM oncology therapy claim in
# Window is [LOT1_START - NDMM_PRE_LOT1_DAYS, LOT1_START - 1], per patient.
# Five sources: medical PROC_CD, medical BILL_PROC_CD, medical NDC, rx NDC and
# med_procedure PROC, with NDC11 normalisation.
#
# Read from raw claims rather than a prepared table. Those are anchored at the
# MM diagnosis, so they cannot see claims before it - and part of the baseline
# window falls there.
build_ndmm_therapy_pre_lot1 <- function(con, medical_tbl, rx_tbl, med_proc_tbl) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_THERAPY_PRE_LOT1} AS
    WITH med_proc AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type IN ('HCPCS','CPT')
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
       AND regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    med_bill AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
       AND regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    med_ndc AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type = 'NDC'
       AND {ndc_key('m.NDC')}
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    -- med_procedure.PROC: a drug given as a procedure under a HCPCS or CPT
    -- code. No ICD_FLAG condition, matching how 05_sct.R reads the same
    -- column for HCPCS.
    mproc AS (
      SELECT /*+ BROADCAST(c) */ cast(mp.PATID as string) AS PATID
      FROM {med_proc_tbl} mp
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(mp.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c ON c.code_type IN ('HCPCS','CPT')
       AND upper(regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '')) = c.code
       AND regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '') <> ''
      WHERE cast(mp.FST_DT as date) >= date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
        AND cast(mp.FST_DT as date) <= date_sub(l1.LOT1_START_DT, 1)
    ),  -- end mproc
    rx_ndc AS (
      SELECT /*+ BROADCAST(c) */ cast(r.PATID as string) AS PATID
      FROM {rx_tbl} r
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(r.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type = 'NDC'
       AND {ndc_key('r.NDC')}
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
      WHERE cast(r.FILL_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    )
    SELECT DISTINCT PATID FROM med_proc
    UNION SELECT DISTINCT PATID FROM med_bill
    UNION SELECT DISTINCT PATID FROM med_ndc
    UNION SELECT DISTINCT PATID FROM rx_ndc
    UNION SELECT DISTINCT PATID FROM mproc
  "))
}

# Other-malignancy code list, read from other_malig.csv. Built here so the
# inpatient/outpatient scan does not depend on any other build.
#
# Tags each row with is_mm_adjacent_override - 1 for the tumour groups that
# must not exclude, else 0. The exclusion scan reads only the 0 rows; the QC
# card reads all of them, so the overridden groups stay visible. Logs how many
# override labels matched: a partial match means the stored wording differs and
# the override quietly does nothing, which blocks the run review.
