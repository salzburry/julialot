#!/usr/bin/env Rscript
# ============================================================
# GSK MM LOT - Part 2: Lines of Therapy (LOT) Analysis
# Follows from Part 1 (new_code.R) cohort attrition pipeline
# ============================================================
#
# This script implements the LOT analysis per Part 2 specifications:
#   5A. MMA_MED  - Multiple Myeloma Approved Medication claims
#   5B. MAP_MED  - Medication Available Period algorithm
#   6.  LOT1_BASE - LOT1 induction regimen identification
#   7.  SCT       - Stem Cell Transplant identification
#   8.  MONOMAINT - Mono-maintenance medication analysis
#
# Input:  ELIG_COH_FINAL from Part 1 (new_code.R)
# Output: LOT1 base dataset, MAP_STACKED, summary tables
#
# Architecture: Same as new_code.R (Databricks SQL via ODBC)
# ============================================================

library(DBI)
library(odbc)
library(glue)
library(dplyr)
library(dbplyr)

# Source GSK helper functions (same as Part 1)
tryCatch(
  source("/mnt/code/R/helperScripts/databases/personalSchemaFunctions.R"),
  error = function(e) message("NOTE: personalSchemaFunctions.R not found; materialization disabled")
)

# ============================================================
# CONFIGURATION (inherits from Part 1 where possible)
# ============================================================
lot_cfg <- list(
  # Connection (same as Part 1)
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  # Schemas (same as Part 1)
  catalog    = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  cdm_schema = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  ref_schema = Sys.getenv("PROJECT_REF_SCHEMA",
                          unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_ref")),
  work_schema = Sys.getenv("PROJECT_WORK_SCHEMA",
                           unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_work")),
  personal_schema = Sys.getenv("DOMINO_USER_NAME",
                               unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")),

  # Source tables (Optum Clinformatics)
  tbl_medical   = "medical",
  tbl_med_diag  = "med_diagnosis",
  tbl_med_proc  = "med_procedure",
  tbl_rx        = "rx",

  # Quarterly table pattern

  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),

  # Study parameters (must match Part 1)
  study_start = "2015-07-01",
  study_end   = "2025-06-30",

  # Part 2 specific parameters
  # Induction regimen window: medications started within this many days
  # of LOT1_START_DT are considered part of the induction regimen
  induction_window = 60,

  # MAP gap threshold: a new MAP starts when the gap between
  # the end of coverage and the next claim exceeds this many days
  map_gap_days = 90,

  # Medical claims default day supply (per spec: hardcode to 28)
  medical_day_supply = 28,

  # LOT discontinuation gap: if ENDDATE - LOT1_BASE_DISCON_DT < this,
  # set discontinuation date to missing (insufficient follow-up)
  lot_discon_gap = 90,

  # Input table from Part 1 (final cohort)
  input_cohort_table = Sys.getenv("INPUT_COHORT_TABLE", unset = "ELIG_COH_FINAL"),

  # Code list source
  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),
  use_embedded_codes = as.logical(Sys.getenv("USE_EMBEDDED_CODES", unset = "TRUE")),

  # Pipeline controls
  max_retries = 4,
  base_sleep  = 5,

  # Materialization
  materialize_checkpoints = TRUE,

  # Persist final LOT tables
  persist_to_schema = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE"))
)

lot_run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))

# ============================================================
# HELPER FUNCTIONS (reuse patterns from Part 1)
# ============================================================
SEP_60  <- strrep("=", 60)
DASH_60 <- strrep("-", 60)

lot_log <- function(...) {
  cat(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), ..., "\n")
  flush.console()
}

lot_full_name <- function(schema, object) {
  if (nzchar(lot_cfg$catalog)) {
    paste0(lot_cfg$catalog, ".", schema, ".", object)
  } else {
    paste0(schema, ".", object)
  }
}

lot_cdm <- function(tbl) lot_full_name(lot_cfg$cdm_schema, tbl)
lot_work <- function(tbl) tbl  # temp views

# Quarterly table helper
lot_get_quarter_suffix <- function(end_date) {
  dt <- as.Date(end_date)
  year <- as.integer(format(dt, "%Y"))
  quarter <- ceiling(as.integer(format(dt, "%m")) / 3)
  sprintf("%dq%d", year, quarter)
}

lot_cdm_src <- function(tbl_name) {
  if (isTRUE(lot_cfg$use_quarterly_tables)) {
    qsuffix <- lot_get_quarter_suffix(lot_cfg$study_end)
    lot_full_name(lot_cfg$cdm_schema, paste0("t_", tbl_name, "_", qsuffix))
  } else {
    lot_cdm(tbl_name)
  }
}

# Connection environment
lot_con_env <- new.env()
lot_con_env$con <- NULL

lot_connect <- function() {
  if (!nzchar(lot_cfg$pwd)) {
    stop("DATABRICKS_PWD environment variable is not set.")
  }
  DBI::dbConnect(odbc::odbc(), dsn = lot_cfg$dsn, pwd = lot_cfg$pwd, timeout = 120)
}

lot_db_ping <- function(con) {
  tryCatch({ DBI::dbGetQuery(con, "SELECT 1 AS ok"); TRUE }, error = function(e) FALSE)
}

lot_with_retry <- function(fn, max_retries = lot_cfg$max_retries,
                           base_sleep = lot_cfg$base_sleep) {
  attempt <- 1
  repeat {
    result <- tryCatch(fn(), error = function(e) e)
    if (!inherits(result, "error")) return(result)
    if (attempt >= max_retries) stop(result)
    sleep_s <- base_sleep * (2^(attempt - 1))
    lot_log("Retryable failure: ", conditionMessage(result))
    lot_log("Retrying in ", sleep_s, "s (attempt ", attempt + 1, "/", max_retries, ")")
    Sys.sleep(sleep_s)
    attempt <- attempt + 1
  }
}

# Step runner (same pattern as Part 1)
lot_run_step <- function(step_name, sql, qc_sql = NULL, description = NULL,
                         step_num = NULL, total_steps = NULL, source_tables = NULL) {
  started_at <- Sys.time()
  progress <- if (!is.null(step_num) && !is.null(total_steps)) {
    sprintf("[Step %d/%d] ", step_num, total_steps)
  } else ""
  step_desc <- if (!is.null(description)) description else step_name

  cat("\n", DASH_60, "\n")
  lot_log(progress, step_desc)
  if (!is.null(source_tables) && length(source_tables) > 0) {
    lot_log("  >> Reading from: ", paste(source_tables, collapse = ", "))
  }
  cat(DASH_60, "\n")
  flush.console()

  tryCatch({
    if (!lot_db_ping(lot_con_env$con)) {
      lot_log("Connection stale, reconnecting...")
      try(DBI::dbDisconnect(lot_con_env$con), silent = TRUE)
      lot_con_env$con <- lot_with_retry(function() {
        conn <- lot_connect()
        lot_log("Reconnected to Databricks")
        conn
      })
    }
    DBI::dbExecute(lot_con_env$con, sql)

    if (!is.null(qc_sql)) {
      qc <- DBI::dbGetQuery(lot_con_env$con, qc_sql)
      qc_metric <- colnames(qc)[1]
      qc_value <- as.character(qc[[1]][1])
      numeric_val <- suppressWarnings(as.numeric(qc_value))
      formatted <- if (!is.na(numeric_val)) format(numeric_val, big.mark = ",") else qc_value
      lot_log("  >> Result: ", qc_metric, " = ", formatted)
    }

    duration <- round(as.numeric(difftime(Sys.time(), started_at, units = "secs")), 1)
    lot_log("  >> Completed in ", duration, "s")
  }, error = function(e) {
    lot_log("STEP FAILED: ", step_name, " - ", conditionMessage(e))
    stop(e)
  })
}

# ============================================================
# SECTION 1: EMBEDDED MM MEDICATION CODE LISTS
# Per Tab 40 (CL MMA ROLLUP) + Tab 41 (CL MMA CODELIST)
# ============================================================

build_mma_rollup_sql <- function() {
  # CL_MMA_ROLLUP: Master list of MM-approved medications
  # Columns: CL_MEDICATION_FULL, CL_MED_CLASS, CL_MED_ABBR,
  #          MONOMAINTENANCE, DUALMAINTENANCEWITH, CONDITIONING,
  #          used_for_other_cancers
  "
  CREATE OR REPLACE TEMPORARY VIEW mma_rollup AS
  SELECT * FROM (VALUES
    -- Proteasome Inhibitors (PI)
    ('bortezomib',                'PROTINHIB',  'BORT', 0, NULL,         0, 0),
    ('carfilzomib',               'PROTINHIB',  'CARF', 0, NULL,         0, 0),
    ('ixazomib',                  'PROTINHIB',  'IXAZ', 0, NULL,         0, 0),
    -- Immunomodulatory Drugs (IMiD)
    ('lenalidomide',              'IMMUNOMOD',  'LENA', 1, 'BORT,CARF',  0, 0),
    ('pomalidomide',              'IMMUNOMOD',  'POMA', 0, NULL,         0, 0),
    ('thalidomide',               'IMMUNOMOD',  'THAL', 0, NULL,         0, 0),
    -- Anti-CD38 Monoclonal Antibodies
    ('daratumumab',               'ACD38',      'DARA', 1, NULL,         0, 0),
    ('daratumumab_hyaluronidase', 'ACD38',      'DARA', 1, NULL,         0, 0),
    ('isatuximab',                'ACD38',      'ISAT', 0, NULL,         0, 0),
    -- Anti-SLAMF7
    ('elotuzumab',                'ASLAMF7',    'ELOT', 0, NULL,         0, 0),
    -- Anti-BCMA
    ('belantamab',                'ABCMA',      'BELA', 0, NULL,         0, 0),
    ('teclistamab',               'ABCMA',      'TECL', 0, NULL,         0, 0),
    ('elranatamab',               'ABCMA',      'ELRA', 0, NULL,         0, 0),
    ('talquetamab',               'ABCMA',      'TALQ', 0, NULL,         0, 0),
    -- CAR-T Cell Therapies
    ('idecabtagene',              'ATCELL',     'IDEC', 0, NULL,         0, 0),
    ('ciltacabtagene',            'ATCELL',     'CILT', 0, NULL,         0, 0),
    -- Alkylating Agents / Mustards
    ('bendamustine',              'MUSTARD',    'BEND', 0, NULL,         1, 1),
    ('cyclophosphamide',          'MUSTARD',    'CYCL', 0, NULL,         1, 1),
    ('melphalan',                 'MELP',       'MELP', 0, NULL,         1, 0),
    ('melphalan_fluf',            'MELP',       'MELP', 0, NULL,         1, 0),
    -- Topoisomerase Inhibitors
    ('doxorubicin',               'TOPOINHIB',  'DOXO', 0, NULL,         0, 1),
    ('doxorubicin_peg_lip',       'TOPOINHIB',  'DOPL', 0, NULL,         0, 1),
    ('etoposide',                 'TOPOINHIB',  'ETOP', 0, NULL,         0, 1),
    -- Platinum
    ('cisplatin',                 'PLAT',       'CISP', 0, NULL,         0, 1),
    -- HDAC Inhibitor
    ('panobinostat',              'HIST',       'PANO', 0, NULL,         0, 0),
    -- Nuclear Export Inhibitor
    ('selinexor',                 'NUCLEAR',    'SELI', 0, NULL,         0, 0),
    -- BCL-2 Inhibitor
    ('venetoclax',                'BLC21',      'VENE', 0, NULL,         0, 0),
    -- Bispecific (newer)
    ('linvoseltamab',             'UNV',        'LINV', 0, NULL,         0, 0),
    -- Steroids (tracked but do not define LOTs on their own)
    ('dexamethasone',             'STEROID',    'DEXA', 0, NULL,         0, 0),
    ('prednisone',                'STEROID',    'PRED', 0, NULL,         0, 0)
  ) AS t(CL_MEDICATION_FULL, CL_MED_CLASS, CL_MED_ABBR,
         MONOMAINTENANCE, DUALMAINTENANCEWITH, CONDITIONING,
         used_for_other_cancers)
  "
}

build_mma_codelist_sql <- function() {
  # CL_MMA_CODELIST: Maps HCPCS J-codes and NDC codes to medications
  # Combined from Tab 41a (NDC) and Tab 41b (HCPCS)
  "
  CREATE OR REPLACE TEMPORARY VIEW mma_codelist AS
  SELECT * FROM (VALUES
    -- ===== BORTEZOMIB (Velcade) =====
    ('HCPCS', 'C9207',         'bortezomib',   'PROTINHIB', 'BORT'),
    ('HCPCS', 'J9041',         'bortezomib',   'PROTINHIB', 'BORT'),
    ('HCPCS', 'J9044',         'bortezomib',   'PROTINHIB', 'BORT'),
    ('HCPCS', 'J9045',         'bortezomib',   'PROTINHIB', 'BORT'),
    ('HCPCS', 'J9046',         'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '10019007901',   'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '16729025003',   'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '16729025105',   'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '42367052025',   'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '42367052125',   'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '60505622800',   'bortezomib',   'PROTINHIB', 'BORT'),
    -- NDC 63459034804 removed: it is Bendeka (bendamustine), not bortezomib
    ('NDC',   '63459039008',   'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '63459039120',   'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '63459039502',   'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '63459039602',   'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '68001057141',   'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '68001057241',   'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '71225012001',   'bortezomib',   'PROTINHIB', 'BORT'),

    -- ===== CARFILZOMIB (Kyprolis) =====
    ('HCPCS', 'C9295',         'carfilzomib',  'PROTINHIB', 'CARF'),
    ('HCPCS', 'J9047',         'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '76075010101',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '76075010201',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '76075010301',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '00409170001',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '00409170301',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '00409170401',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '00019099101',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '25021024410',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '43598042660',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '43598086560',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '50742048401',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '05150033701',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '10505605004',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '03020004901',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '03323072110',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '03323082110',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '68001053436',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '71288011810',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '72205018301',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '72266024301',   'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '72266024401',   'carfilzomib',  'PROTINHIB', 'CARF'),

    -- ===== IXAZOMIB (Ninlaro) =====
    ('HCPCS', 'J9228',         'ixazomib',     'PROTINHIB', 'IXAZ'),
    ('NDC',   '63020007101',   'ixazomib',     'PROTINHIB', 'IXAZ'),
    ('NDC',   '63020007201',   'ixazomib',     'PROTINHIB', 'IXAZ'),
    ('NDC',   '63020007301',   'ixazomib',     'PROTINHIB', 'IXAZ'),
    ('NDC',   '63020007401',   'ixazomib',     'PROTINHIB', 'IXAZ'),

    -- ===== LENALIDOMIDE (Revlimid) =====
    ('HCPCS', 'J9223',         'lenalidomide', 'IMMUNOMOD', 'LENA'),
    ('NDC',   '59572040021',   'lenalidomide', 'IMMUNOMOD', 'LENA'),
    ('NDC',   '59572040521',   'lenalidomide', 'IMMUNOMOD', 'LENA'),
    ('NDC',   '59572041021',   'lenalidomide', 'IMMUNOMOD', 'LENA'),
    ('NDC',   '59572041521',   'lenalidomide', 'IMMUNOMOD', 'LENA'),
    ('NDC',   '59572042021',   'lenalidomide', 'IMMUNOMOD', 'LENA'),

    -- ===== POMALIDOMIDE (Pomalyst) =====
    ('HCPCS', 'J9226',         'pomalidomide', 'IMMUNOMOD', 'POMA'),
    ('NDC',   '59572050021',   'pomalidomide', 'IMMUNOMOD', 'POMA'),
    ('NDC',   '59572050121',   'pomalidomide', 'IMMUNOMOD', 'POMA'),
    ('NDC',   '59572050221',   'pomalidomide', 'IMMUNOMOD', 'POMA'),
    ('NDC',   '59572050321',   'pomalidomide', 'IMMUNOMOD', 'POMA'),

    -- ===== THALIDOMIDE (Thalomid) =====
    ('HCPCS', 'J9300',         'thalidomide',  'IMMUNOMOD', 'THAL'),
    ('NDC',   '59572020014',   'thalidomide',  'IMMUNOMOD', 'THAL'),
    ('NDC',   '59572020028',   'thalidomide',  'IMMUNOMOD', 'THAL'),
    ('NDC',   '59572010014',   'thalidomide',  'IMMUNOMOD', 'THAL'),
    ('NDC',   '59572010028',   'thalidomide',  'IMMUNOMOD', 'THAL'),

    -- ===== DARATUMUMAB (Darzalex) =====
    ('HCPCS', 'J9145',         'daratumumab',  'ACD38',     'DARA'),
    ('NDC',   '57894050205',   'daratumumab',  'ACD38',     'DARA'),
    ('NDC',   '57894050220',   'daratumumab',  'ACD38',     'DARA'),

    -- ===== DARATUMUMAB + HYALURONIDASE (Darzalex Faspro) =====
    ('HCPCS', 'J9144',         'daratumumab_hyaluronidase', 'ACD38', 'DARA'),
    ('NDC',   '57894015015',   'daratumumab_hyaluronidase', 'ACD38', 'DARA'),

    -- ===== ISATUXIMAB (Sarclisa) =====
    ('HCPCS', 'J9227',         'isatuximab',   'ACD38',     'ISAT'),
    ('NDC',   '00024592405',   'isatuximab',   'ACD38',     'ISAT'),
    ('NDC',   '00024592505',   'isatuximab',   'ACD38',     'ISAT'),

    -- ===== ELOTUZUMAB (Empliciti) =====
    ('HCPCS', 'J9176',         'elotuzumab',   'ASLAMF7',   'ELOT'),
    ('NDC',   '00003488611',   'elotuzumab',   'ASLAMF7',   'ELOT'),
    ('NDC',   '00003489311',   'elotuzumab',   'ASLAMF7',   'ELOT'),

    -- ===== BELANTAMAB MAFODOTIN (Blenrep) =====
    ('HCPCS', 'J9037',         'belantamab',   'ABCMA',     'BELA'),
    ('NDC',   '00173089801',   'belantamab',   'ABCMA',     'BELA'),

    -- ===== TECLISTAMAB (Tecvayli) =====
    ('HCPCS', 'J9348',         'teclistamab',  'ABCMA',     'TECL'),
    ('NDC',   '57894060301',   'teclistamab',  'ABCMA',     'TECL'),
    ('NDC',   '57894060401',   'teclistamab',  'ABCMA',     'TECL'),

    -- ===== ELRANATAMAB (Elrexfio) =====
    ('HCPCS', 'J9177',         'elranatamab',  'ABCMA',     'ELRA'),
    ('NDC',   '00069118201',   'elranatamab',  'ABCMA',     'ELRA'),
    ('NDC',   '00069118301',   'elranatamab',  'ABCMA',     'ELRA'),

    -- ===== TALQUETAMAB (Talvey) =====
    ('HCPCS', 'J9347',         'talquetamab',  'ABCMA',     'TALQ'),
    ('NDC',   '57894070101',   'talquetamab',  'ABCMA',     'TALQ'),
    ('NDC',   '57894070201',   'talquetamab',  'ABCMA',     'TALQ'),

    -- ===== IDECABTAGENE VICLEUCEL (Abecma / CAR-T) =====
    ('HCPCS', 'Q2055',         'idecabtagene', 'ATCELL',    'IDEC'),
    ('NDC',   '59572030101',   'idecabtagene', 'ATCELL',    'IDEC'),

    -- ===== CILTACABTAGENE AUTOLEUCEL (Carvykti / CAR-T) =====
    ('HCPCS', 'C9098',         'ciltacabtagene', 'ATCELL',  'CILT'),
    ('HCPCS', 'Q2056',         'ciltacabtagene', 'ATCELL',  'CILT'),
    ('NDC',   '57894011101',   'ciltacabtagene', 'ATCELL',  'CILT'),
    ('NDC',   '57894011102',   'ciltacabtagene', 'ATCELL',  'CILT'),

    -- ===== BENDAMUSTINE (Treanda) =====
    ('HCPCS', 'C9447',         'bendamustine', 'MUSTARD',   'BEND'),
    ('HCPCS', 'C9243',         'bendamustine', 'MUSTARD',   'BEND'),
    ('HCPCS', 'J9033',         'bendamustine', 'MUSTARD',   'BEND'),
    ('HCPCS', 'J9034',         'bendamustine', 'MUSTARD',   'BEND'),
    ('HCPCS', 'J9036',         'bendamustine', 'MUSTARD',   'BEND'),
    ('NDC',   '63459034804',   'bendamustine', 'MUSTARD',   'BEND'),

    -- ===== CYCLOPHOSPHAMIDE (Cytoxan) =====
    ('HCPCS', 'J9070',         'cyclophosphamide', 'MUSTARD', 'CYCL'),
    ('HCPCS', 'J8530',         'cyclophosphamide', 'MUSTARD', 'CYCL'),
    ('HCPCS', 'J9071',         'cyclophosphamide', 'MUSTARD', 'CYCL'),
    ('HCPCS', 'J9072',         'cyclophosphamide', 'MUSTARD', 'CYCL'),

    -- ===== MELPHALAN =====
    ('HCPCS', 'J9245',         'melphalan',    'MELP',      'MELP'),
    ('HCPCS', 'J8600',         'melphalan',    'MELP',      'MELP'),
    ('HCPCS', 'J9246',         'melphalan_fluf', 'MELP',    'MELP'),

    -- ===== DOXORUBICIN =====
    ('HCPCS', 'J9000',         'doxorubicin',  'TOPOINHIB', 'DOXO'),
    ('HCPCS', 'J9001',         'doxorubicin',  'TOPOINHIB', 'DOXO'),
    ('HCPCS', 'J9002',         'doxorubicin_peg_lip', 'TOPOINHIB', 'DOPL'),

    -- ===== ETOPOSIDE =====
    ('HCPCS', 'J9181',         'etoposide',    'TOPOINHIB', 'ETOP'),
    ('HCPCS', 'J8560',         'etoposide',    'TOPOINHIB', 'ETOP'),

    -- ===== CISPLATIN =====
    ('HCPCS', 'C9418',         'cisplatin',    'PLAT',      'CISP'),
    ('HCPCS', 'J9060',         'cisplatin',    'PLAT',      'CISP'),
    ('HCPCS', 'J9062',         'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '00143950401',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '00143950501',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '00703574711',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '00703574811',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '16729028811',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '16729028838',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '44567050901',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '44567051001',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '44567051101',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '44567053001',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '47781060925',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '47781061023',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '63323010351',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '63323010364',   'cisplatin',    'PLAT',      'CISP'),
    ('NDC',   '63323010365',   'cisplatin',    'PLAT',      'CISP'),

    -- ===== PANOBINOSTAT (Farydak) =====
    -- Note: Panobinostat is oral; no product-specific HCPCS J-code.
    -- J9295 is necitumumab (not panobinostat) and was removed.
    ('NDC',   '00078064615',   'panobinostat', 'HIST',      'PANO'),
    ('NDC',   '00078064715',   'panobinostat', 'HIST',      'PANO'),
    ('NDC',   '00078064815',   'panobinostat', 'HIST',      'PANO'),

    -- ===== SELINEXOR (Xpovio) =====
    -- Note: Selinexor is oral; no product-specific HCPCS J-code.
    -- J9176 is elotuzumab (not selinexor) and was removed.
    ('NDC',   '73607000101',   'selinexor',    'NUCLEAR',   'SELI'),
    ('NDC',   '73607000201',   'selinexor',    'NUCLEAR',   'SELI'),

    -- ===== VENETOCLAX (Venclexta) =====
    ('HCPCS', 'J9312',         'venetoclax',   'BLC21',     'VENE'),
    ('NDC',   '00074059528',   'venetoclax',   'BLC21',     'VENE'),
    ('NDC',   '00074059628',   'venetoclax',   'BLC21',     'VENE'),
    ('NDC',   '00074059728',   'venetoclax',   'BLC21',     'VENE'),
    ('NDC',   '00074059828',   'venetoclax',   'BLC21',     'VENE'),

    -- ===== LINVOSELTAMAB =====
    ('HCPCS', 'J9999',         'linvoseltamab', 'UNV',      'LINV'),

    -- ===== DEXAMETHASONE =====
    ('HCPCS', 'J1100',         'dexamethasone', 'STEROID',  'DEXA'),
    ('HCPCS', 'J8540',         'dexamethasone', 'STEROID',  'DEXA'),
    ('NDC',   '00054017925',   'dexamethasone', 'STEROID',  'DEXA'),
    ('NDC',   '00054383625',   'dexamethasone', 'STEROID',  'DEXA'),
    ('NDC',   '00054381725',   'dexamethasone', 'STEROID',  'DEXA'),
    ('NDC',   '00054817825',   'dexamethasone', 'STEROID',  'DEXA'),
    ('NDC',   '63304069001',   'dexamethasone', 'STEROID',  'DEXA'),
    ('NDC',   '63304069101',   'dexamethasone', 'STEROID',  'DEXA'),

    -- ===== PREDNISONE =====
    ('NDC',   '00054413025',   'prednisone',   'STEROID',   'PRED'),
    ('NDC',   '00054017825',   'prednisone',   'STEROID',   'PRED'),
    ('NDC',   '00054418125',   'prednisone',   'STEROID',   'PRED'),
    ('NDC',   '00781150101',   'prednisone',   'STEROID',   'PRED'),
    ('NDC',   '00781150501',   'prednisone',   'STEROID',   'PRED'),
    ('NDC',   '00781150601',   'prednisone',   'STEROID',   'PRED')

  ) AS t(CL_CODE_TYPE, CL_CODE, CL_MEDICATION_FULL, CL_MED_CLASS, CL_MED_ABBR)
  "
}

# ============================================================
# SECTION 2: PERMISSIBLE SUBSTITUTIONS
# Per LOT1_BASE spec: certain substitutions do not advance the LOT
# ============================================================

build_permissible_subs_sql <- function() {
  "
  CREATE OR REPLACE TEMPORARY VIEW permissible_subs AS
  SELECT * FROM (VALUES
    -- Daratumumab <-> Daratumumab/hyaluronidase
    ('DARA', 'DARA'),
    -- Bortezomib induction -> Ixazomib maintenance
    ('BORT', 'IXAZ'),
    ('IXAZ', 'BORT')
  ) AS t(original_med, substitute_med)
  "
}

# ============================================================
# SECTION 3: BUILD PIPELINE STEPS
# ============================================================

build_lot_steps <- function() {
  cfg <- lot_cfg
  list(

    # ----------------------------------------------------------
    # STEP L01: Register code lists
    # ----------------------------------------------------------
    list(
      name = "L01_mma_rollup",
      description = "Registering MM-approved medication rollup (CL_MMA_ROLLUP)",
      sql = build_mma_rollup_sql(),
      qc = "SELECT count(*) AS n_medications FROM mma_rollup"
    ),

    list(
      name = "L02_mma_codelist",
      description = "Registering MM medication code list (NDC + HCPCS)",
      sql = build_mma_codelist_sql(),
      qc = "SELECT count(*) AS n_codes, count(DISTINCT CL_MED_ABBR) AS n_meds FROM mma_codelist"
    ),

    list(
      name = "L03_permissible_subs",
      description = "Registering permissible substitution rules",
      sql = build_permissible_subs_sql(),
      qc = "SELECT count(*) AS n_sub_rules FROM permissible_subs"
    ),

    # ----------------------------------------------------------
    # STEP L04: Patient input from Part 1 final cohort
    # The ELIG_COH_FINAL from Part 1 provides:
    #   PATID, INDEX_DATE, ENDDATE, ENDDATE_CE, DEATH_DT, etc.
    # ----------------------------------------------------------
    list(
      name = "L04_patient_input",
      description = glue("Loading patient cohort from Part 1 ({cfg$input_cohort_table})"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW lot_patient_input AS
        SELECT
          PATID,
          INDEX_DATE,
          ENDDATE,
          ENDDATE_CE,
          DEATH_DT,
          GDR_CD,
          YRDOB,
          AGE_INDEX_YR,
          FU_DAYS,
          FU_DAYS_CE
        FROM {cfg$work_schema}.{cfg$input_cohort_table}
      "),
      qc = "SELECT count(*) AS n_patients FROM lot_patient_input"
    ),

    # ----------------------------------------------------------
    # STEP L05: MMA_MED - Extract all MM treatment claims
    # Per 5A spec: Pull all medical (HCPCS) and pharmacy (NDC)
    # claims matching MMA codelist for cohort patients.
    # Business rules:
    #   - Pharmacy: DAY_SUPPLY from claims (remove if < 1 or missing)
    #   - Medical:  DAY_SUPPLY hardcoded to 28
    #   - Date must be between INDEX_DATE and ENDDATE (inclusive)
    #   - Dedup: multiple medical lines same date -> keep one
    #   - Dedup: multiple pharmacy same date -> keep max DAY_SUPPLY
    # ----------------------------------------------------------
    list(
      name = "L05_mma_med_raw",
      description = "Extracting raw MM medication claims (medical + med_procedure + pharmacy)",
      source_tables = c("medical", "med_procedure", "rx"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW mma_med_raw AS
        -- Medical claims: match HCPCS J-codes via PROC_CD (primary procedure)
        -- Per Optum CDM v9.0, PROC_CD holds CPT/HCPCS codes
        WITH medical_claims_proc AS (
          SELECT /*+ BROADCAST(c) */
            m.PATID,
            cast(m.FST_DT AS date) AS DATE_SERVICE,
            {cfg$medical_day_supply} AS DAY_SUPPLY,
            'medical' AS CLAIM_TYPE,
            'HCPCS' AS CODE_TYPE,
            upper(regexp_replace(m.PROC_CD, '\\\\.', '')) AS CODE,
            c.CL_MEDICATION_FULL,
            c.CL_MED_CLASS,
            c.CL_MED_ABBR
          FROM {lot_cdm_src(cfg$tbl_medical)} m
          INNER JOIN mma_codelist c
            ON c.CL_CODE_TYPE = 'HCPCS'
            AND upper(regexp_replace(m.PROC_CD, '\\\\.', '')) = c.CL_CODE
          WHERE m.FST_DT IS NOT NULL
        ),
        -- Medical claims: also check BILL_PROC_CD (billing procedure code)
        -- Some J-codes may appear here instead of PROC_CD
        medical_claims_bill AS (
          SELECT /*+ BROADCAST(c) */
            m.PATID,
            cast(m.FST_DT AS date) AS DATE_SERVICE,
            {cfg$medical_day_supply} AS DAY_SUPPLY,
            'medical' AS CLAIM_TYPE,
            'HCPCS' AS CODE_TYPE,
            upper(regexp_replace(m.BILL_PROC_CD, '\\\\.', '')) AS CODE,
            c.CL_MEDICATION_FULL,
            c.CL_MED_CLASS,
            c.CL_MED_ABBR
          FROM {lot_cdm_src(cfg$tbl_medical)} m
          INNER JOIN mma_codelist c
            ON c.CL_CODE_TYPE = 'HCPCS'
            AND upper(regexp_replace(m.BILL_PROC_CD, '\\\\.', '')) = c.CL_CODE
          WHERE m.FST_DT IS NOT NULL
            AND m.BILL_PROC_CD IS NOT NULL
        ),
        -- Medical claims: also check MED_PROCEDURE table (PROC field)
        -- Per Optum business rules: PROC from T_MED_PROCEDURE can hold
        -- HCPCS codes (up to 25 procedure codes per claim)
        medical_claims_medproc AS (
          SELECT /*+ BROADCAST(c) */
            mp.PATID,
            cast(mp.FST_DT AS date) AS DATE_SERVICE,
            {cfg$medical_day_supply} AS DAY_SUPPLY,
            'medical' AS CLAIM_TYPE,
            'HCPCS' AS CODE_TYPE,
            upper(regexp_replace(mp.PROC, '\\\\.', '')) AS CODE,
            c.CL_MEDICATION_FULL,
            c.CL_MED_CLASS,
            c.CL_MED_ABBR
          FROM {lot_cdm_src(cfg$tbl_med_proc)} mp
          INNER JOIN mma_codelist c
            ON c.CL_CODE_TYPE = 'HCPCS'
            AND upper(regexp_replace(mp.PROC, '\\\\.', '')) = c.CL_CODE
          WHERE mp.FST_DT IS NOT NULL
            AND mp.PROC IS NOT NULL
        ),
        -- Combine all medical code sources (UNION dedup across sources)
        medical_claims AS (
          SELECT * FROM medical_claims_proc
          UNION
          SELECT * FROM medical_claims_bill
          UNION
          SELECT * FROM medical_claims_medproc
        ),
        -- Pharmacy claims (NDC -> MMA codelist)
        -- Per Optum CDM v9.0, DAYS_SUP = days supply on RX table
        pharmacy_claims AS (
          SELECT /*+ BROADCAST(c) */
            r.PATID,
            cast(r.FILL_DT AS date) AS DATE_SERVICE,
            cast(r.DAYS_SUP AS int) AS DAY_SUPPLY,
            'pharmacy' AS CLAIM_TYPE,
            'NDC' AS CODE_TYPE,
            upper(regexp_replace(r.NDC, '\\\\.', '')) AS CODE,
            c.CL_MEDICATION_FULL,
            c.CL_MED_CLASS,
            c.CL_MED_ABBR
          FROM {lot_cdm_src(cfg$tbl_rx)} r
          INNER JOIN mma_codelist c
            ON c.CL_CODE_TYPE = 'NDC'
            AND upper(regexp_replace(r.NDC, '\\\\.', '')) = c.CL_CODE
          WHERE r.FILL_DT IS NOT NULL
        ),
        -- Union medical + pharmacy
        all_claims AS (
          SELECT * FROM medical_claims
          UNION ALL
          SELECT * FROM pharmacy_claims
        )
        -- Filter to cohort patients and valid date range
        SELECT
          a.PATID,
          a.DATE_SERVICE,
          a.DAY_SUPPLY,
          a.CLAIM_TYPE,
          a.CODE_TYPE,
          a.CODE,
          a.CL_MEDICATION_FULL,
          a.CL_MED_CLASS AS MED_CLASS,
          a.CL_MED_ABBR AS MED_ABBR,
          -- Conditioning flag from rollup
          coalesce(r.CONDITIONING, 0) AS MED_COND,
          -- Other cancer flag from rollup
          coalesce(r.used_for_other_cancers, 0) AS MED_other_cancer
        FROM all_claims a
        INNER JOIN lot_patient_input p ON a.PATID = p.PATID
        LEFT JOIN mma_rollup r ON a.CL_MED_ABBR = r.CL_MED_ABBR
        WHERE a.DATE_SERVICE >= p.INDEX_DATE
          AND a.DATE_SERVICE <= p.ENDDATE
      "),
      qc = "SELECT count(*) AS n_raw_claims, count(DISTINCT PATID) AS n_patients FROM mma_med_raw"
    ),

    # ----------------------------------------------------------
    # STEP L06: MMA_MED processed - apply business rules
    # Per 5A spec:
    #   - Remove pharmacy claims with DAY_SUPPLY < 1 or missing
    #   - Multiple pharmacy same MED + date -> keep max DAY_SUPPLY
    #   - Multiple medical same MED + date -> keep one
    #   - Allow duplicate DATE_SERVICE if both pharmacy + medical
    # ----------------------------------------------------------
    list(
      name = "L06_mma_med_processed",
      description = "Processing MMA claims (dedup, day supply rules)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW mma_med_processed AS
        WITH filtered AS (
          -- Remove pharmacy claims with invalid day supply
          SELECT * FROM mma_med_raw
          WHERE NOT (CLAIM_TYPE = 'pharmacy' AND (DAY_SUPPLY < 1 OR DAY_SUPPLY IS NULL))
        ),
        -- Dedup pharmacy: keep max DAY_SUPPLY per PATID + MED_ABBR + DATE_SERVICE
        pharmacy_dedup AS (
          SELECT PATID, DATE_SERVICE,
                 max(DAY_SUPPLY) AS DAY_SUPPLY,
                 'pharmacy' AS CLAIM_TYPE,
                 first(CODE_TYPE) AS CODE_TYPE,
                 first(CODE) AS CODE,
                 first(CL_MEDICATION_FULL) AS CL_MEDICATION_FULL,
                 first(MED_CLASS) AS MED_CLASS,
                 MED_ABBR,
                 max(MED_COND) AS MED_COND,
                 max(MED_other_cancer) AS MED_other_cancer
          FROM filtered
          WHERE CLAIM_TYPE = 'pharmacy'
          GROUP BY PATID, MED_ABBR, DATE_SERVICE
        ),
        -- Dedup medical: keep one per PATID + MED_ABBR + DATE_SERVICE
        medical_dedup AS (
          SELECT PATID, DATE_SERVICE,
                 {cfg$medical_day_supply} AS DAY_SUPPLY,
                 'medical' AS CLAIM_TYPE,
                 first(CODE_TYPE) AS CODE_TYPE,
                 first(CODE) AS CODE,
                 first(CL_MEDICATION_FULL) AS CL_MEDICATION_FULL,
                 first(MED_CLASS) AS MED_CLASS,
                 MED_ABBR,
                 max(MED_COND) AS MED_COND,
                 max(MED_other_cancer) AS MED_other_cancer
          FROM filtered
          WHERE CLAIM_TYPE = 'medical'
          GROUP BY PATID, MED_ABBR, DATE_SERVICE
        )
        -- Allow both pharmacy and medical on same date (per spec)
        SELECT * FROM pharmacy_dedup
        UNION ALL
        SELECT * FROM medical_dedup
      "),
      qc = "SELECT count(*) AS n_processed_claims, count(DISTINCT PATID) AS n_patients,
             count(DISTINCT MED_ABBR) AS n_distinct_meds FROM mma_med_processed"
    ),

    # ----------------------------------------------------------
    # STEP L07: MAP_MED - Medication Available Period algorithm
    # Per 5B spec: For each patient + medication, create MAPs
    # using pushout/runout logic.
    #
    # MAP Algorithm (SQL approximation):
    #   1. For each claim, compute expected end date:
    #      - Pharmacy: DATE_SERVICE + DAY_SUPPLY - 1
    #      - Medical: DATE_SERVICE + 27 (28-day default)
    #   2. Track running coverage using cumulative max of end dates
    #   3. A new MAP starts when DATE_SERVICE > cummax end date
    #   4. Within each MAP, pharmacy pushout extends coverage:
    #      MAP pharmacy end = MAP_START + SUM(pharmacy DAY_SUPPLY) - 1
    #      MAP medical end = MAX(medical DATE_SERVICE) + 27
    #      MAP_END_DT = MAX(pharmacy_end, medical_end)
    # ----------------------------------------------------------
    list(
      name = "L07_map_med",
      description = "Building Medication Available Periods (MAP) per medication",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW map_med AS
        WITH claims_with_end AS (
          -- Compute each claim's individual end date
          SELECT *,
            CASE
              WHEN CLAIM_TYPE = 'pharmacy' THEN date_add(DATE_SERVICE, DAY_SUPPLY - 1)
              ELSE date_add(DATE_SERVICE, {cfg$medical_day_supply} - 1)
            END AS claim_end_dt,
            row_number() OVER (
              PARTITION BY PATID, MED_ABBR
              ORDER BY DATE_SERVICE, CLAIM_TYPE
            ) AS rn
          FROM mma_med_processed
        ),
        -- Compute cumulative max end date to detect gaps
        with_cummax AS (
          SELECT *,
            max(claim_end_dt) OVER (
              PARTITION BY PATID, MED_ABBR
              ORDER BY DATE_SERVICE, rn
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS prev_cummax_end
          FROM claims_with_end
        ),
        -- Flag new MAP starts (gap > 0 days between coverage and next claim)
        map_flagged AS (
          SELECT *,
            CASE
              WHEN prev_cummax_end IS NULL THEN 1
              WHEN DATE_SERVICE > date_add(prev_cummax_end, 0) THEN 1
              ELSE 0
            END AS new_map_flag
          FROM with_cummax
        ),
        -- Assign MAP group numbers
        map_grouped AS (
          SELECT *,
            sum(new_map_flag) OVER (
              PARTITION BY PATID, MED_ABBR
              ORDER BY DATE_SERVICE, rn
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS map_cnt
          FROM map_flagged
        ),
        -- Compute MAP-level aggregates
        map_agg AS (
          SELECT
            PATID,
            MED_ABBR,
            first(MED_CLASS) AS MED_CLASS,
            map_cnt AS MAP_CNT,
            min(DATE_SERVICE) AS MAP_START_DT,
            -- MAP end: for pharmacy claims within this MAP, apply pushout logic
            -- Effective pharmacy end = MAP_START + SUM(pharmacy supplies) - 1
            -- Effective medical end = MAX(medical claim date + 27)
            greatest(
              -- Pharmacy runout with pushout: first pharmacy date + sum of all pharmacy supplies - 1
              coalesce(
                date_add(
                  min(CASE WHEN CLAIM_TYPE = 'pharmacy' THEN DATE_SERVICE END),
                  cast(sum(CASE WHEN CLAIM_TYPE = 'pharmacy' THEN DAY_SUPPLY ELSE 0 END) - 1 AS int)
                ),
                date('1900-01-01')
              ),
              -- Medical runout: max medical date + 27
              coalesce(
                date_add(
                  max(CASE WHEN CLAIM_TYPE = 'medical' THEN DATE_SERVICE END),
                  {cfg$medical_day_supply} - 1
                ),
                date('1900-01-01')
              )
            ) AS MAP_END_DT,
            -- Track rx and medical runout separately for QC
            date_add(
              min(CASE WHEN CLAIM_TYPE = 'pharmacy' THEN DATE_SERVICE END),
              cast(sum(CASE WHEN CLAIM_TYPE = 'pharmacy' THEN DAY_SUPPLY ELSE 0 END) - 1 AS int)
            ) AS MAP_RX_RUNOUT_DT,
            date_add(
              max(CASE WHEN CLAIM_TYPE = 'medical' THEN DATE_SERVICE END),
              {cfg$medical_day_supply} - 1
            ) AS MAP_MED_RUNOUT_DT
          FROM map_grouped
          GROUP BY PATID, MED_ABBR, map_cnt
        )
        SELECT
          m.*,
          m.MED_ABBR AS MAP_MED_TYPE,
          m.MED_CLASS AS MAP_MED_CLASS,
          -- MAP_DISCON_FLG: 1 if gap > 90 days to next MAP or end of observation
          -- (gap is measured from day after MAP_END_DT, so use > not >=)
          CASE
            WHEN nxt.next_map_start IS NOT NULL
              AND datediff(nxt.next_map_start, m.MAP_END_DT) > {cfg$map_gap_days}
              THEN 1
            WHEN nxt.next_map_start IS NULL
              AND datediff(p.ENDDATE, m.MAP_END_DT) > {cfg$map_gap_days}
              THEN 1
            ELSE 0
          END AS MAP_DISCON_FLG
        FROM map_agg m
        INNER JOIN lot_patient_input p ON m.PATID = p.PATID
        LEFT JOIN (
          -- Next MAP start for this patient + medication
          SELECT PATID, MED_ABBR, MAP_CNT,
                 lead(MAP_START_DT) OVER (
                   PARTITION BY PATID, MED_ABBR ORDER BY MAP_CNT
                 ) AS next_map_start
          FROM map_agg
        ) nxt ON m.PATID = nxt.PATID AND m.MED_ABBR = nxt.MED_ABBR AND m.MAP_CNT = nxt.MAP_CNT
      "),
      qc = "SELECT count(*) AS n_maps, count(DISTINCT PATID) AS n_patients,
             count(DISTINCT MED_ABBR) AS n_meds FROM map_med"
    ),

    # ----------------------------------------------------------
    # STEP L08: MAP_STACKED
    # Per 5B spec: Stack all MAP_[MED] datasets into one combined
    # dataset at the MED-patient-MAP level
    # ----------------------------------------------------------
    list(
      name = "L08_map_stacked",
      description = "Stacking all medication MAPs into MAP_STACKED",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW map_stacked AS
        SELECT
          PATID,
          MAP_MED_TYPE,
          MAP_MED_CLASS,
          MAP_CNT,
          MAP_START_DT,
          MAP_END_DT,
          MAP_DISCON_FLG,
          MAP_RX_RUNOUT_DT,
          MAP_MED_RUNOUT_DT
        FROM map_med
        ORDER BY PATID, MAP_START_DT, MAP_MED_TYPE
      "),
      qc = "SELECT count(*) AS n_total_maps, count(DISTINCT PATID) AS n_patients,
             count(DISTINCT MAP_MED_TYPE) AS n_med_types FROM map_stacked"
    ),

    # ----------------------------------------------------------
    # STEP L09: LOT1_START_DT
    # Per LOT1_BASE spec: Earliest MAP_START_DT where
    # MAP_MED_CLASS != 'STEROID' (steroids alone don't start a LOT)
    # ----------------------------------------------------------
    list(
      name = "L09_lot1_start",
      description = "Determining LOT1 start date (earliest non-steroid MAP start)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW lot1_start AS
        SELECT
          PATID,
          min(MAP_START_DT) AS LOT1_START_DT
        FROM map_stacked
        WHERE MAP_MED_CLASS != 'STEROID'
        GROUP BY PATID
      "),
      qc = "SELECT count(*) AS n_patients_with_lot1 FROM lot1_start"
    ),

    # ----------------------------------------------------------
    # STEP L10: LOT1 induction regimen identification
    # Per LOT1_BASE spec: Medications with MAP_START_DT within
    # 60-day window of LOT1_START_DT are induction regimen meds
    # LOT1_MED_[MED] = 1 if MAP_MED_TYPE=[MED] and
    #   LOT1_START_DT <= MAP_START_DT <= LOT1_START_DT + 59
    # ----------------------------------------------------------
    list(
      name = "L10_lot1_induction_meds",
      description = glue("Identifying LOT1 induction regimen medications ({cfg$induction_window}-day window)"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW lot1_induction_meds AS
        SELECT DISTINCT
          ms.PATID,
          l1.LOT1_START_DT,
          ms.MAP_MED_TYPE AS MED_ABBR,
          ms.MAP_MED_CLASS AS MED_CLASS
        FROM map_stacked ms
        INNER JOIN lot1_start l1 ON ms.PATID = l1.PATID
        WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
          AND ms.MAP_START_DT <= date_add(l1.LOT1_START_DT, {cfg$induction_window} - 1)
      "),
      qc = "SELECT count(DISTINCT PATID) AS n_patients,
             count(DISTINCT MED_ABBR) AS n_distinct_induction_meds FROM lot1_induction_meds"
    ),

    # ----------------------------------------------------------
    # STEP L11: LOT1_BASE - Compute LOT1 base characteristics
    # Per LOT1_BASE spec:
    #   - LOT1_MED_CNT: count of induction medications
    #   - LOT1_BASE_MEDS: string of medication abbreviations
    #   - LOT1_CLASS_[CLASS]: presence of each drug class
    #   - LOT1_BASE_DISCON_DT: max MAP_END_DT among induction MAPs
    #     + permissible substitutions
    #   - If ENDDATE - LOT1_BASE_DISCON_DT < 90, set to NULL
    #   - LOT1_BASE_LENGTH: DISCON_DT - LOT1_START_DT + 1
    # ----------------------------------------------------------
    list(
      name = "L11_lot1_base",
      description = "Building LOT1 BASE dataset (induction regimen, discontinuation, length)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW lot1_base AS
        WITH induction_meds AS (
          SELECT
            PATID,
            LOT1_START_DT,
            MED_ABBR,
            MED_CLASS
          FROM lot1_induction_meds
        ),
        -- Collect all induction regimen MAPs + permissible substitution MAPs
        induction_maps AS (
          SELECT ms.PATID, ms.MAP_MED_TYPE, ms.MAP_START_DT, ms.MAP_END_DT
          FROM map_stacked ms
          INNER JOIN lot1_start l1 ON ms.PATID = l1.PATID
          WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
            AND (
              -- Induction regimen medication
              EXISTS (
                SELECT 1 FROM induction_meds im
                WHERE im.PATID = ms.PATID AND im.MED_ABBR = ms.MAP_MED_TYPE
              )
              OR
              -- Permissible substitution of an induction medication
              EXISTS (
                SELECT 1 FROM induction_meds im
                INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
                WHERE im.PATID = ms.PATID AND ms.MAP_MED_TYPE = ps.substitute_med
              )
            )
        ),
        -- LOT1 base discontinuation date = max MAP_END_DT among induction MAPs
        discon AS (
          SELECT
            PATID,
            max(MAP_END_DT) AS raw_discon_dt
          FROM induction_maps
          GROUP BY PATID
        ),
        -- Med counts and class flags
        med_summary AS (
          SELECT
            PATID,
            LOT1_START_DT,
            count(DISTINCT MED_ABBR) AS LOT1_MED_CNT,
            concat_ws(' ', sort_array(collect_set(MED_ABBR))) AS LOT1_BASE_MEDS,
            -- Class presence flags
            max(CASE WHEN MED_CLASS = 'PROTINHIB' THEN 1 ELSE 0 END) AS LOT1_CLASS_PROTINHIB,
            max(CASE WHEN MED_CLASS = 'IMMUNOMOD' THEN 1 ELSE 0 END) AS LOT1_CLASS_IMMUNOMOD,
            max(CASE WHEN MED_CLASS = 'ACD38' THEN 1 ELSE 0 END) AS LOT1_CLASS_ACD38,
            max(CASE WHEN MED_CLASS = 'ASLAMF7' THEN 1 ELSE 0 END) AS LOT1_CLASS_ASLAMF7,
            max(CASE WHEN MED_CLASS = 'ABCMA' THEN 1 ELSE 0 END) AS LOT1_CLASS_ABCMA,
            max(CASE WHEN MED_CLASS = 'ATCELL' THEN 1 ELSE 0 END) AS LOT1_CLASS_ATCELL,
            max(CASE WHEN MED_CLASS = 'MUSTARD' THEN 1 ELSE 0 END) AS LOT1_CLASS_MUSTARD,
            max(CASE WHEN MED_CLASS = 'MELP' THEN 1 ELSE 0 END) AS LOT1_CLASS_MELP,
            max(CASE WHEN MED_CLASS = 'TOPOINHIB' THEN 1 ELSE 0 END) AS LOT1_CLASS_TOPOINHIB,
            max(CASE WHEN MED_CLASS = 'STEROID' THEN 1 ELSE 0 END) AS LOT1_CLASS_STEROID,
            max(CASE WHEN MED_CLASS = 'PLAT' THEN 1 ELSE 0 END) AS LOT1_CLASS_PLAT,
            max(CASE WHEN MED_CLASS = 'HIST' THEN 1 ELSE 0 END) AS LOT1_CLASS_HIST,
            max(CASE WHEN MED_CLASS = 'NUCLEAR' THEN 1 ELSE 0 END) AS LOT1_CLASS_NUCLEAR,
            max(CASE WHEN MED_CLASS = 'BLC21' THEN 1 ELSE 0 END) AS LOT1_CLASS_BLC21,
            max(CASE WHEN MED_CLASS = 'UNV' THEN 1 ELSE 0 END) AS LOT1_CLASS_UNV
          FROM induction_meds
          GROUP BY PATID, LOT1_START_DT
        ),
        -- First medication add (non-induction med) during LOT1_BASE period
        first_add AS (
          SELECT
            ms.PATID,
            min(ms.MAP_START_DT) AS first_add_dt,
            first_value(ms.MAP_MED_TYPE) OVER (
              PARTITION BY ms.PATID
              ORDER BY ms.MAP_START_DT
            ) AS first_add_med
          FROM map_stacked ms
          INNER JOIN lot1_start l1 ON ms.PATID = l1.PATID
          LEFT JOIN induction_meds im ON ms.PATID = im.PATID AND ms.MAP_MED_TYPE = im.MED_ABBR
          LEFT JOIN permissible_subs ps ON im.MED_ABBR IS NOT NULL AND 1=0
          WHERE im.MED_ABBR IS NULL  -- Not an induction med
            AND ms.MAP_MED_CLASS != 'STEROID'  -- Steroids don't count as adds
            AND ms.MAP_START_DT >= l1.LOT1_START_DT
            -- Must be within the induction period (or open if no discon)
          GROUP BY ms.PATID, ms.MAP_MED_TYPE, ms.MAP_START_DT
        ),
        first_add_final AS (
          SELECT PATID,
                 min(first_add_dt) AS LOT1_BASE_1ST_ADD_MED_DT,
                 first_value(first_add_med) OVER (
                   PARTITION BY PATID ORDER BY first_add_dt
                 ) AS LOT1_BASE_1ST_ADD_MED
          FROM first_add
          GROUP BY PATID, first_add_med, first_add_dt
        ),
        first_add_picked AS (
          SELECT PATID,
                 min(LOT1_BASE_1ST_ADD_MED_DT) AS LOT1_BASE_1ST_ADD_MED_DT,
                 first(LOT1_BASE_1ST_ADD_MED) AS LOT1_BASE_1ST_ADD_MED
          FROM first_add_final
          GROUP BY PATID
        )
        SELECT
          p.PATID,
          p.INDEX_DATE,
          p.ENDDATE,
          p.DEATH_DT,
          p.GDR_CD,
          p.YRDOB,
          p.AGE_INDEX_YR,
          ms.LOT1_START_DT,
          ms.LOT1_MED_CNT,
          ms.LOT1_BASE_MEDS,
          -- Class flags
          ms.LOT1_CLASS_PROTINHIB,
          ms.LOT1_CLASS_IMMUNOMOD,
          ms.LOT1_CLASS_ACD38,
          ms.LOT1_CLASS_ASLAMF7,
          ms.LOT1_CLASS_ABCMA,
          ms.LOT1_CLASS_ATCELL,
          ms.LOT1_CLASS_MUSTARD,
          ms.LOT1_CLASS_MELP,
          ms.LOT1_CLASS_TOPOINHIB,
          ms.LOT1_CLASS_STEROID,
          ms.LOT1_CLASS_PLAT,
          ms.LOT1_CLASS_HIST,
          ms.LOT1_CLASS_NUCLEAR,
          ms.LOT1_CLASS_BLC21,
          ms.LOT1_CLASS_UNV,
          -- Discontinuation date (NULL if insufficient follow-up)
          CASE
            WHEN d.raw_discon_dt IS NOT NULL
              AND datediff(p.ENDDATE, d.raw_discon_dt) > {cfg$lot_discon_gap}
              THEN d.raw_discon_dt
            ELSE NULL
          END AS LOT1_BASE_DISCON_DT,
          -- LOT1 base length
          CASE
            WHEN d.raw_discon_dt IS NOT NULL
              AND datediff(p.ENDDATE, d.raw_discon_dt) > {cfg$lot_discon_gap}
              THEN datediff(d.raw_discon_dt, ms.LOT1_START_DT) + 1
            ELSE datediff(p.ENDDATE, ms.LOT1_START_DT) + 1
          END AS LOT1_BASE_LENGTH,
          -- First med add
          date_sub(fa.LOT1_BASE_1ST_ADD_MED_DT, 1) AS LOT1_BASE_1ST_ADD_MED_DT,
          fa.LOT1_BASE_1ST_ADD_MED
        FROM lot_patient_input p
        INNER JOIN med_summary ms ON p.PATID = ms.PATID
        LEFT JOIN discon d ON p.PATID = d.PATID
        LEFT JOIN first_add_picked fa ON p.PATID = fa.PATID
      "),
      qc = "SELECT count(*) AS n_lot1_patients,
             avg(LOT1_MED_CNT) AS avg_induction_meds,
             avg(LOT1_BASE_LENGTH) AS avg_lot1_length FROM lot1_base"
    ),

    # ----------------------------------------------------------
    # STEP L12: LOT1_BASE_END - Determine LOT1 Base end reason
    # Per spec: LOT1 BASE ends due to:
    #   1. All induction meds discontinue (90-day gap)
    #   2. New non-induction med added (regimen change)
    #   3. HSCT (stem cell transplant)
    #   4. Censoring (ENDDATE reached)
    #   5. Maintenance begins
    # ----------------------------------------------------------
    list(
      name = "L12_lot1_base_end",
      description = "Determining LOT1 BASE end reasons",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW lot1_base_end AS
        SELECT
          lb.*,
          CASE
            WHEN lb.LOT1_BASE_DISCON_DT IS NOT NULL
              AND lb.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
              AND lb.LOT1_BASE_1ST_ADD_MED_DT < lb.LOT1_BASE_DISCON_DT
              THEN 'MED_ADD'
            WHEN lb.LOT1_BASE_DISCON_DT IS NOT NULL
              THEN 'DISCONTINUATION'
            ELSE 'CENSORED'
          END AS LOT1_BASE_END_REASON,
          -- Effective LOT1 BASE end date
          CASE
            WHEN lb.LOT1_BASE_DISCON_DT IS NOT NULL
              AND lb.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
              AND lb.LOT1_BASE_1ST_ADD_MED_DT < lb.LOT1_BASE_DISCON_DT
              THEN lb.LOT1_BASE_1ST_ADD_MED_DT
            WHEN lb.LOT1_BASE_DISCON_DT IS NOT NULL
              THEN lb.LOT1_BASE_DISCON_DT
            ELSE lb.ENDDATE
          END AS LOT1_BASE_END_DT
        FROM lot1_base lb
      "),
      qc = "SELECT
              LOT1_BASE_END_REASON,
              count(*) AS n_patients,
              avg(LOT1_BASE_LENGTH) AS avg_length
            FROM lot1_base_end
            GROUP BY LOT1_BASE_END_REASON"
    ),

    # ----------------------------------------------------------
    # STEP L13: SCT (Stem Cell Transplant) identification
    # Per Tab 7 spec: Identify HSCT events during follow-up
    # Using HCPCS codes for autologous SCT
    # ----------------------------------------------------------
    list(
      name = "L13_sct",
      description = "Identifying stem cell transplant (HSCT) events",
      source_tables = c("medical"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW sct_events AS
        WITH sct_codes AS (
          SELECT * FROM (VALUES
            ('HCPCS', '38240'),   -- Autologous HSCT
            ('HCPCS', '38241'),   -- Allogeneic HSCT
            ('HCPCS', 'S2150'),   -- Bone marrow transplant
            ('HCPCS', 'Q2055'),   -- CAR-T (also maps to IDEC)
            ('HCPCS', 'Q2056')    -- CAR-T (also maps to CILT)
          ) AS t(code_type, code)
        )
        SELECT /*+ BROADCAST(s) */
          m.PATID,
          cast(m.FST_DT AS date) AS SCT_DT,
          upper(regexp_replace(m.PROC_CD, '\\\\.', '')) AS PROC_CD
        FROM {lot_cdm_src(cfg$tbl_medical)} m
        INNER JOIN sct_codes s ON upper(regexp_replace(m.PROC_CD, '\\\\.', '')) = s.code
        INNER JOIN lot_patient_input p ON m.PATID = p.PATID
        WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
          AND cast(m.FST_DT AS date) <= p.ENDDATE
      "),
      qc = "SELECT count(*) AS n_sct_events, count(DISTINCT PATID) AS n_sct_patients FROM sct_events"
    ),

    # ----------------------------------------------------------
    # STEP L14: MONOMAINT_MED - Mono-maintenance identification
    # Per Tab 8 spec: After LOT1_BASE_DISCON_DT, if a patient
    # continues on a single induction med, it's mono-maintenance
    # Valid mono-maintenance meds defined in CL_MMA_ROLLUP
    # (MONOMAINTENANCE = 1)
    # ----------------------------------------------------------
    list(
      name = "L14_monomaint",
      description = "Identifying mono-maintenance therapy after LOT1 BASE",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW lot1_monomaint AS
        WITH eligible_maps AS (
          -- MAPs that start after LOT1_BASE ends
          SELECT
            ms.PATID,
            ms.MAP_MED_TYPE,
            ms.MAP_MED_CLASS,
            ms.MAP_START_DT,
            ms.MAP_END_DT,
            ms.MAP_CNT
          FROM map_stacked ms
          INNER JOIN lot1_base_end le ON ms.PATID = le.PATID
          WHERE ms.MAP_START_DT > le.LOT1_BASE_END_DT
            AND ms.MAP_MED_CLASS != 'STEROID'
        ),
        -- Check if only one non-steroid med active = mono-maintenance
        post_lot1_meds AS (
          SELECT PATID, count(DISTINCT MAP_MED_TYPE) AS n_active_meds,
                 first(MAP_MED_TYPE) AS maint_med,
                 min(MAP_START_DT) AS maint_start_dt,
                 max(MAP_END_DT) AS maint_end_dt
          FROM eligible_maps
          GROUP BY PATID
        ),
        -- Validate against MONOMAINTENANCE flag in rollup
        validated AS (
          SELECT pm.*,
                 CASE
                   WHEN pm.n_active_meds = 1
                     AND EXISTS (
                       SELECT 1 FROM mma_rollup r
                       WHERE r.CL_MED_ABBR = pm.maint_med AND r.MONOMAINTENANCE = 1
                     )
                   THEN 1
                   ELSE 0
                 END AS is_monomaint
          FROM post_lot1_meds pm
        )
        SELECT
          v.PATID,
          v.maint_med AS MONOMAINT_MED,
          v.maint_start_dt AS MONOMAINT_START_DT,
          v.maint_end_dt AS MONOMAINT_END_DT,
          v.is_monomaint,
          datediff(v.maint_end_dt, v.maint_start_dt) + 1 AS MONOMAINT_LENGTH
        FROM validated v
        WHERE v.is_monomaint = 1
      "),
      qc = "SELECT count(*) AS n_monomaint_patients,
             avg(MONOMAINT_LENGTH) AS avg_monomaint_length FROM lot1_monomaint"
    ),

    # ----------------------------------------------------------
    # STEP L15: DUALMAINT_MED - Dual-maintenance identification
    # Per Tab 9 spec: Two-drug maintenance after LOT1_BASE
    # Valid combinations defined in CL_MMA_ROLLUP (DUALMAINTENANCEWITH)
    # ----------------------------------------------------------
    list(
      name = "L15_dualmaint",
      description = "Identifying dual-maintenance therapy after LOT1 BASE",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW lot1_dualmaint AS
        WITH eligible_maps AS (
          SELECT
            ms.PATID,
            ms.MAP_MED_TYPE,
            ms.MAP_MED_CLASS,
            ms.MAP_START_DT,
            ms.MAP_END_DT
          FROM map_stacked ms
          INNER JOIN lot1_base_end le ON ms.PATID = le.PATID
          WHERE ms.MAP_START_DT > le.LOT1_BASE_END_DT
            AND ms.MAP_MED_CLASS != 'STEROID'
        ),
        -- Patients with exactly 2 non-steroid meds post-LOT1
        dual_meds AS (
          SELECT PATID,
                 sort_array(collect_set(MAP_MED_TYPE)) AS med_pair,
                 count(DISTINCT MAP_MED_TYPE) AS n_meds,
                 min(MAP_START_DT) AS dual_start_dt,
                 max(MAP_END_DT) AS dual_end_dt
          FROM eligible_maps
          GROUP BY PATID
          HAVING count(DISTINCT MAP_MED_TYPE) = 2
        ),
        -- Validate against DUALMAINTENANCEWITH in rollup
        validated AS (
          SELECT dm.*,
                 dm.med_pair[0] AS med1,
                 dm.med_pair[1] AS med2,
                 CASE
                   WHEN EXISTS (
                     SELECT 1 FROM mma_rollup r
                     WHERE r.CL_MED_ABBR = dm.med_pair[0]
                       AND r.DUALMAINTENANCEWITH IS NOT NULL
                       AND array_contains(split(r.DUALMAINTENANCEWITH, ','), trim(dm.med_pair[1]))
                   ) THEN 1
                   WHEN EXISTS (
                     SELECT 1 FROM mma_rollup r
                     WHERE r.CL_MED_ABBR = dm.med_pair[1]
                       AND r.DUALMAINTENANCEWITH IS NOT NULL
                       AND array_contains(split(r.DUALMAINTENANCEWITH, ','), trim(dm.med_pair[0]))
                   ) THEN 1
                   ELSE 0
                 END AS is_dualmaint
          FROM dual_meds dm
        )
        SELECT
          PATID,
          concat(med1, '+', med2) AS DUALMAINT_MEDS,
          dual_start_dt AS DUALMAINT_START_DT,
          dual_end_dt AS DUALMAINT_END_DT,
          is_dualmaint,
          datediff(dual_end_dt, dual_start_dt) + 1 AS DUALMAINT_LENGTH
        FROM validated
        WHERE is_dualmaint = 1
      "),
      qc = "SELECT count(*) AS n_dualmaint_patients FROM lot1_dualmaint"
    ),

    # ----------------------------------------------------------
    # STEP L16: Final LOT1 summary dataset
    # Combines LOT1_BASE + SCT + maintenance into one patient-level
    # dataset ready for Tab 40/41 output
    # ----------------------------------------------------------
    list(
      name = "L16_lot1_final",
      description = "Assembling final LOT1 patient-level summary",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW lot1_final AS
        SELECT
          le.PATID,
          le.INDEX_DATE,
          le.ENDDATE,
          le.DEATH_DT,
          le.GDR_CD,
          le.YRDOB,
          le.AGE_INDEX_YR,
          -- LOT1 Base
          le.LOT1_START_DT,
          le.LOT1_MED_CNT,
          le.LOT1_BASE_MEDS,
          le.LOT1_BASE_DISCON_DT,
          le.LOT1_BASE_LENGTH,
          le.LOT1_BASE_END_DT,
          le.LOT1_BASE_END_REASON,
          le.LOT1_BASE_1ST_ADD_MED_DT,
          le.LOT1_BASE_1ST_ADD_MED,
          -- Class flags
          le.LOT1_CLASS_PROTINHIB,
          le.LOT1_CLASS_IMMUNOMOD,
          le.LOT1_CLASS_ACD38,
          le.LOT1_CLASS_ASLAMF7,
          le.LOT1_CLASS_ABCMA,
          le.LOT1_CLASS_ATCELL,
          le.LOT1_CLASS_MUSTARD,
          le.LOT1_CLASS_MELP,
          le.LOT1_CLASS_TOPOINHIB,
          le.LOT1_CLASS_STEROID,
          le.LOT1_CLASS_PLAT,
          le.LOT1_CLASS_HIST,
          le.LOT1_CLASS_NUCLEAR,
          le.LOT1_CLASS_BLC21,
          le.LOT1_CLASS_UNV,
          -- SCT
          CASE WHEN sct.PATID IS NOT NULL THEN 1 ELSE 0 END AS HAS_SCT,
          sct.SCT_DT AS FIRST_SCT_DT,
          -- Mono-maintenance
          CASE WHEN mm.PATID IS NOT NULL THEN 1 ELSE 0 END AS HAS_MONOMAINT,
          mm.MONOMAINT_MED,
          mm.MONOMAINT_START_DT,
          mm.MONOMAINT_END_DT,
          mm.MONOMAINT_LENGTH,
          -- Dual-maintenance
          CASE WHEN dm.PATID IS NOT NULL THEN 1 ELSE 0 END AS HAS_DUALMAINT,
          dm.DUALMAINT_MEDS,
          dm.DUALMAINT_START_DT,
          dm.DUALMAINT_END_DT,
          dm.DUALMAINT_LENGTH,
          -- Time to LOT1
          datediff(le.LOT1_START_DT, le.INDEX_DATE) AS DAYS_INDEX_TO_LOT1
        FROM lot1_base_end le
        LEFT JOIN (
          SELECT PATID, min(SCT_DT) AS SCT_DT
          FROM sct_events
          GROUP BY PATID
        ) sct ON le.PATID = sct.PATID
        LEFT JOIN lot1_monomaint mm ON le.PATID = mm.PATID
        LEFT JOIN lot1_dualmaint dm ON le.PATID = dm.PATID
      "),
      qc = "SELECT count(*) AS n_final_lot1,
             sum(HAS_SCT) AS n_with_sct,
             sum(HAS_MONOMAINT) AS n_monomaint,
             sum(HAS_DUALMAINT) AS n_dualmaint FROM lot1_final"
    ),

    # ----------------------------------------------------------
    # STEP L17: Persist LOT1 final to schema
    # ----------------------------------------------------------
    if (isTRUE(cfg$persist_to_schema) && nzchar(cfg$personal_schema)) list(
      name = "L17_persist_lot1",
      description = glue("Persisting LOT1_FINAL to {cfg$work_schema}"),
      sql = glue("
        CREATE OR REPLACE TABLE {cfg$catalog}.{cfg$work_schema}.LOT1_FINAL AS
        SELECT * FROM lot1_final
      "),
      qc = glue("SELECT count(*) AS n_persisted FROM {cfg$catalog}.{cfg$work_schema}.LOT1_FINAL")
    ) else NULL,

    # ----------------------------------------------------------
    # STEP L18: Persist MAP_STACKED to schema
    # ----------------------------------------------------------
    if (isTRUE(cfg$persist_to_schema) && nzchar(cfg$personal_schema)) list(
      name = "L18_persist_map_stacked",
      description = glue("Persisting MAP_STACKED to {cfg$work_schema}"),
      sql = glue("
        CREATE OR REPLACE TABLE {cfg$catalog}.{cfg$work_schema}.MAP_STACKED AS
        SELECT * FROM map_stacked
      "),
      qc = glue("SELECT count(*) AS n_persisted FROM {cfg$catalog}.{cfg$work_schema}.MAP_STACKED")
    ) else NULL

  )  # end list
}  # end build_lot_steps

# ============================================================
# SECTION 4: SUMMARY REPORTING (Tab 40 / Tab 41 style)
# ============================================================

print_lot_summary <- function(con) {
  cat("\n")
  cat(SEP_60, "\n")
  cat("        LOT1 ANALYSIS SUMMARY (Tab 40 Style)          \n")
  cat(SEP_60, "\n")

  # Overall LOT1 stats
  tryCatch({
    stats <- DBI::dbGetQuery(con, "
      SELECT
        count(*) AS n_patients,
        avg(DAYS_INDEX_TO_LOT1) AS avg_days_to_lot1,
        avg(LOT1_MED_CNT) AS avg_induction_meds,
        avg(LOT1_BASE_LENGTH) AS avg_lot1_base_length,
        sum(CASE WHEN LOT1_BASE_END_REASON = 'DISCONTINUATION' THEN 1 ELSE 0 END) AS n_discontinued,
        sum(CASE WHEN LOT1_BASE_END_REASON = 'MED_ADD' THEN 1 ELSE 0 END) AS n_med_add,
        sum(CASE WHEN LOT1_BASE_END_REASON = 'CENSORED' THEN 1 ELSE 0 END) AS n_censored,
        sum(HAS_SCT) AS n_with_sct,
        sum(HAS_MONOMAINT) AS n_monomaint,
        sum(HAS_DUALMAINT) AS n_dualmaint,
        sum(CASE WHEN DEATH_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_deaths
      FROM lot1_final
    ")

    cat(sprintf("  Total LOT1 patients:       %s\n", format(stats$n_patients, big.mark = ",")))
    cat(sprintf("  Avg days index->LOT1:      %.1f\n", stats$avg_days_to_lot1))
    cat(sprintf("  Avg induction meds:        %.1f\n", stats$avg_induction_meds))
    cat(sprintf("  Avg LOT1 BASE length:      %.1f days\n", stats$avg_lot1_base_length))
    cat(DASH_60, "\n")
    cat("  LOT1 BASE End Reasons:\n")
    cat(sprintf("    Discontinued:            %s (%.1f%%)\n",
                format(stats$n_discontinued, big.mark = ","),
                100 * stats$n_discontinued / stats$n_patients))
    cat(sprintf("    Med added:               %s (%.1f%%)\n",
                format(stats$n_med_add, big.mark = ","),
                100 * stats$n_med_add / stats$n_patients))
    cat(sprintf("    Censored:                %s (%.1f%%)\n",
                format(stats$n_censored, big.mark = ","),
                100 * stats$n_censored / stats$n_patients))
    cat(DASH_60, "\n")
    cat(sprintf("  Patients with SCT:         %s (%.1f%%)\n",
                format(stats$n_with_sct, big.mark = ","),
                100 * stats$n_with_sct / stats$n_patients))
    cat(sprintf("  Mono-maintenance:          %s (%.1f%%)\n",
                format(stats$n_monomaint, big.mark = ","),
                100 * stats$n_monomaint / stats$n_patients))
    cat(sprintf("  Dual-maintenance:          %s (%.1f%%)\n",
                format(stats$n_dualmaint, big.mark = ","),
                100 * stats$n_dualmaint / stats$n_patients))
    cat(sprintf("  Deaths during FU:          %s (%.1f%%)\n",
                format(stats$n_deaths, big.mark = ","),
                100 * stats$n_deaths / stats$n_patients))
    cat(SEP_60, "\n")

    # ----------------------------------------------------------
    # Tab 41 style: Induction regimen distribution
    # ----------------------------------------------------------
    cat("\n")
    cat(SEP_60, "\n")
    cat("    LOT1 INDUCTION REGIMENS (Tab 41 Style)            \n")
    cat(SEP_60, "\n")

    regimens <- DBI::dbGetQuery(con, "
      SELECT
        LOT1_BASE_MEDS AS regimen,
        count(*) AS n_patients,
        avg(LOT1_BASE_LENGTH) AS avg_length,
        avg(LOT1_MED_CNT) AS avg_meds
      FROM lot1_final
      GROUP BY LOT1_BASE_MEDS
      ORDER BY count(*) DESC
      LIMIT 25
    ")

    total <- stats$n_patients
    cat(sprintf("  %-40s %8s %7s %9s\n", "Regimen", "N", "%", "Avg Days"))
    cat(strrep("-", 68), "\n")
    for (i in seq_len(nrow(regimens))) {
      r <- regimens[i, ]
      cat(sprintf("  %-40s %8s %6.1f%% %8.1f\n",
                  substr(r$regimen, 1, 40),
                  format(r$n_patients, big.mark = ","),
                  100 * r$n_patients / total,
                  r$avg_length))
    }
    cat(SEP_60, "\n")

    # ----------------------------------------------------------
    # Drug class distribution
    # ----------------------------------------------------------
    cat("\n")
    cat(DASH_60, "\n")
    cat("    LOT1 DRUG CLASS DISTRIBUTION                      \n")
    cat(DASH_60, "\n")

    classes <- DBI::dbGetQuery(con, "
      SELECT
        sum(LOT1_CLASS_PROTINHIB) AS n_pi,
        sum(LOT1_CLASS_IMMUNOMOD) AS n_imid,
        sum(LOT1_CLASS_ACD38) AS n_acd38,
        sum(LOT1_CLASS_STEROID) AS n_steroid,
        sum(LOT1_CLASS_MUSTARD) AS n_mustard,
        sum(LOT1_CLASS_MELP) AS n_melp,
        sum(LOT1_CLASS_ATCELL) AS n_cart,
        sum(LOT1_CLASS_ABCMA) AS n_abcma,
        sum(LOT1_CLASS_ASLAMF7) AS n_aslamf7,
        sum(LOT1_CLASS_TOPOINHIB) AS n_topo,
        sum(LOT1_CLASS_PLAT) AS n_plat,
        count(*) AS total
      FROM lot1_final
    ")

    cat(sprintf("  %-30s %8s %7s\n", "Drug Class", "N", "%"))
    cat(strrep("-", 49), "\n")
    class_names <- c("Proteasome Inhibitor", "IMiD", "Anti-CD38", "Steroid",
                     "Alkylating/Mustard", "Melphalan", "CAR-T", "Anti-BCMA",
                     "Anti-SLAMF7", "Topo Inhibitor", "Platinum")
    class_vals <- c(classes$n_pi, classes$n_imid, classes$n_acd38, classes$n_steroid,
                    classes$n_mustard, classes$n_melp, classes$n_cart, classes$n_abcma,
                    classes$n_aslamf7, classes$n_topo, classes$n_plat)
    for (j in seq_along(class_names)) {
      cat(sprintf("  %-30s %8s %6.1f%%\n",
                  class_names[j],
                  format(class_vals[j], big.mark = ","),
                  100 * class_vals[j] / classes$total))
    }
    cat(DASH_60, "\n")

    # ----------------------------------------------------------
    # MAP-level summary by medication
    # ----------------------------------------------------------
    cat("\n")
    cat(DASH_60, "\n")
    cat("    MAP SUMMARY BY MEDICATION                         \n")
    cat(DASH_60, "\n")

    map_summary <- DBI::dbGetQuery(con, "
      SELECT
        MAP_MED_TYPE AS med,
        MAP_MED_CLASS AS class,
        count(*) AS n_maps,
        count(DISTINCT PATID) AS n_patients,
        avg(datediff(MAP_END_DT, MAP_START_DT) + 1) AS avg_map_days,
        sum(MAP_DISCON_FLG) AS n_discon
      FROM map_stacked
      GROUP BY MAP_MED_TYPE, MAP_MED_CLASS
      ORDER BY count(DISTINCT PATID) DESC
    ")

    cat(sprintf("  %-8s %-12s %6s %8s %10s %7s\n",
                "Med", "Class", "MAPs", "Patients", "Avg Days", "Discon"))
    cat(strrep("-", 55), "\n")
    for (i in seq_len(nrow(map_summary))) {
      r <- map_summary[i, ]
      cat(sprintf("  %-8s %-12s %6s %8s %9.1f %7s\n",
                  r$med, r$class,
                  format(r$n_maps, big.mark = ","),
                  format(r$n_patients, big.mark = ","),
                  r$avg_map_days,
                  format(r$n_discon, big.mark = ",")))
    }
    cat(DASH_60, "\n")

  }, error = function(e) {
    lot_log("WARN: Could not generate LOT summary report: ", conditionMessage(e))
  })
}

# ============================================================
# SECTION 5: MAIN EXECUTION
# ============================================================

lot_main <- function() {
  cat("\n")
  cat(SEP_60, "\n")
  cat("  GSK MM LOT - Part 2: Lines of Therapy Analysis      \n")
  cat("  Run ID: ", lot_run_id, "\n")
  cat(SEP_60, "\n")

  lot_log("Configuration:")
  lot_log("  CDM Schema:        ", lot_cfg$cdm_schema)
  lot_log("  Work Schema:       ", lot_cfg$work_schema)
  lot_log("  Input Cohort:      ", lot_cfg$input_cohort_table)
  lot_log("  Induction Window:  ", lot_cfg$induction_window, " days")
  lot_log("  MAP Gap Threshold: ", lot_cfg$map_gap_days, " days")
  lot_log("  Medical Day Supply:", lot_cfg$medical_day_supply, " days")
  lot_log("  LOT Discon Gap:    ", lot_cfg$lot_discon_gap, " days")

  # Connect with retry
  lot_con_env$con <- lot_with_retry(function() {
    conn <- lot_connect()
    lot_log("Connected to Databricks")
    conn
  })

  on.exit({
    if (!is.null(lot_con_env$con)) try(DBI::dbDisconnect(lot_con_env$con), silent = TRUE)
  }, add = TRUE)

  # Build and run steps
  steps <- build_lot_steps()
  steps <- Filter(Negate(is.null), steps)
  total_steps <- length(steps)

  cat("\n")
  cat(SEP_60, "\n")
  cat("  STARTING LOT PIPELINE: ", total_steps, " steps to process\n")
  cat(SEP_60, "\n")

  for (i in seq_along(steps)) {
    s <- steps[[i]]
    lot_with_retry(function() {
      lot_run_step(
        step_name = s$name,
        sql = s$sql,
        qc_sql = s$qc,
        description = s$description,
        step_num = i,
        total_steps = total_steps,
        source_tables = s$source_tables
      )
    })
  }

  # Print summary reports
  lot_log("PIPELINE COMPLETE - Generating LOT summary reports...")
  print_lot_summary(lot_con_env$con)

  lot_log("=", strrep("=", 58))
  lot_log("LOT ANALYSIS PIPELINE COMPLETE")
  lot_log("=", strrep("=", 58))
}

# Run if executed as script
if (!interactive()) {
  lot_main()
} else {
  lot_log("Source loaded. Call lot_main() to run LOT analysis pipeline.")
  lot_log("NOTE: Requires Part 1 (new_code.R) to have been run first.")
  lot_log("      The ELIG_COH_FINAL table must exist in the work schema.")
}
