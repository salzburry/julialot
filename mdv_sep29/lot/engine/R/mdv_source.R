# The MDV source: which tables and columns hold what, and the SQL that turns
# them into the shapes the rules read.
#
# The same file sits in ndmm/R and lot/engine/R, and a test holds the two
# copies byte-identical, so the cohort and the lines cannot read MDV two ways.
# It is the only place either package names an MDV table, column or value
# code. Every step reads the staged selects below, never a raw column.
#
# Where the names come from. The tables, and the columns marked (OC), are the
# ones a colleague's MDV ovarian cancer business rules use against this
# warehouse (reference/MDV_Ovarian_Cancer_Business_Rules.md). The rest are
# marked (confirm): they are not in that document and have to be checked
# against the MDV data dictionary before the first run. check_mdv_columns()
# asks the warehouse for every one of them before anything is built, so a
# wrong name stops the run by name rather than failing inside a step.
#
# Settings are read from the environment, which config.csv fills where a
# variable is unset or blank. So a blank setting means "the default", never
# "absent": the settings loader fills a blank variable from config.csv (Domino
# defines an unset project variable as empty) and skips a blank config.csv
# value. An optional column the delivery does not carry is written NONE, in
# the environment or in config.csv, and the rule that would read it says what
# it does instead.

.mdv_env <- function(name, default) {
  v <- trimws(Sys.getenv(name, unset = ""))
  if (nzchar(v)) v else default
}

MDV_NONE <- "NONE"
.mdv_col_opt <- function(name, default) {
  v <- .mdv_env(name, default)
  if (identical(toupper(v), MDV_NONE)) "" else v
}

# ---- tables -----------------------------------------------------------------
# Base names. With USE_QUARTERLY_TABLES=TRUE each is read as t_<name>_<vintage>
# (clnprw_mdv_all_use.t_diseasedata_2026q2), the convention the OC rules use.
MDV_TABLES <- list(
  disease = .mdv_env("MDV_TBL_DISEASE", "diseasedata"),  # (OC) diagnoses on monthly claims
  patient = .mdv_env("MDV_TBL_PATIENT", "patientdata"),  # (OC) demographics
  ff1     = .mdv_env("MDV_TBL_FF1",     "ff1data"),      # (OC) DPC Form 1 inpatient episodes
  drug    = .mdv_env("MDV_TBL_DRUG",    "m_drug"),       # (OC) drug master
  act     = .mdv_env("MDV_TBL_ACT",     "actdata")       # (OC) acts: drugs and procedures, dated
)

# ---- columns ----------------------------------------------------------------
# Only the columns in MDV_OPTIONAL_COLUMNS may be absent, written NONE; each is
# then "" here, left out of the preflight, and read as NULL.
MDV_COLS <- list(
  patientid       = .mdv_env("MDV_COL_PATIENTID",       "patientid"),       # (OC) every table
  datamonth       = .mdv_env("MDV_COL_DATAMONTH",       "datamonth"),       # (OC) disease: claim month
  nyugaikbn       = .mdv_env("MDV_COL_NYUGAIKBN",       "nyugaikbn"),       # (OC) disease: 1 outpatient, 2 inpatient
  diseasecode     = .mdv_env("MDV_COL_DISEASECODE",     "diseasecode"),     # (OC) disease: MDV disease code
  icd10           = .mdv_col_opt("MDV_COL_ICD10",       ""),                # (confirm) disease: ICD-10, if the delivery carries one
  utagaiflg       = .mdv_env("MDV_COL_UTAGAIFLG",       "utagaiflg"),       # (OC) disease: 0 confirmed, else suspected
  cancerflg       = .mdv_env("MDV_COL_CANCERFLG",       "cancerflg"),       # (OC) disease: 1 cancer diagnosis
  fromdate        = .mdv_env("MDV_COL_FROMDATE",        "fromdate"),        # (OC) disease: day-level date checked against FF1
  sex             = .mdv_env("MDV_COL_SEX",             "sex"),             # (OC) patient: 2 female
  birth           = .mdv_env("MDV_COL_BIRTH",           "birthyearmonth"),  # (confirm) patient: birth year, year-month or date
  ff1startdate    = .mdv_env("MDV_COL_FF1STARTDATE",    "ff1startdate"),    # (OC) ff1: admission date
  ff1enddate      = .mdv_env("MDV_COL_FF1ENDDATE",      "ff1enddate"),      # (OC) ff1: discharge date
  cancerfirstflg  = .mdv_env("MDV_COL_CANCERFIRSTFLG",  "cancerfirstflg"),  # (OC) ff1: 0 first occurrence
  chemotherapyflg = .mdv_env("MDV_COL_CHEMOTHERAPYFLG", "chemotherapyflg"), # (OC) ff1: non-zero chemotherapy given
  ff1_outcome     = .mdv_col_opt("MDV_COL_FF1_OUTCOME", ""),                # (confirm) ff1: discharge outcome; NONE = death not observed
  receiptcode     = .mdv_env("MDV_COL_RECEIPTCODE",     "receiptcode"),     # (OC) drug master and act
  receiptname_eng = .mdv_env("MDV_COL_RECEIPTNAME_ENG", "receiptname_eng"), # (OC) drug master: English name
  actdate         = .mdv_env("MDV_COL_ACTDATE",         "actdate"),         # (OC) act: the day of the act
  act_nyugaikbn   = .mdv_col_opt("MDV_COL_ACT_NYUGAIKBN", "nyugaikbn"),     # (confirm) act: setting; NONE = not carried
  act_days        = .mdv_col_opt("MDV_COL_ACT_DAYS",    "")                 # (confirm) act: days supplied; NONE = not carried
)

MDV_OPTIONAL_COLUMNS <- c("icd10", "ff1_outcome", "act_nyugaikbn", "act_days")

# Which table each column is read from, for the preflight.
MDV_COLUMN_TABLE <- c(
  datamonth = "disease", nyugaikbn = "disease", diseasecode = "disease",
  icd10 = "disease", utagaiflg = "disease", cancerflg = "disease",
  fromdate = "disease", sex = "patient", birth = "patient",
  ff1startdate = "ff1", ff1enddate = "ff1", cancerfirstflg = "ff1",
  chemotherapyflg = "ff1", ff1_outcome = "ff1",
  receiptname_eng = "drug", actdate = "act", act_nyugaikbn = "act",
  act_days = "act")

# ---- value codes ------------------------------------------------------------
# Compared as trimmed text, so an integer column and a string one read alike.
MDV_VALUES <- list(
  inpatient   = .mdv_env("MDV_INPATIENT",      "2"),   # (OC) nyugaikbn
  outpatient  = .mdv_env("MDV_OUTPATIENT",     "1"),   # (OC) nyugaikbn
  confirmed   = .mdv_env("MDV_CONFIRMED",      "0"),   # (OC) utagaiflg
  cancer      = .mdv_env("MDV_CANCER",         "1"),   # (OC) cancerflg
  firstcancer = .mdv_env("MDV_FIRSTCANCER",    "0"),   # (OC) cancerfirstflg
  no_chemo    = .mdv_env("MDV_NO_CHEMO",       "0"),   # (OC) chemotherapyflg: chemotherapy is any other value
  male        = .mdv_env("MDV_SEX_MALE",       "1"),   # (confirm) sex
  female      = .mdv_env("MDV_SEX_FEMALE",     "2"),   # (OC) sex
  # DPC Form 1 discharge outcomes 6 and 7 are the two death codes (death from
  # the condition most resources went to, and death from another cause).
  death       = .mdv_env("MDV_DEATH_OUTCOMES", "6|7")  # (confirm) ff1_outcome
)

mdv_split <- function(x) { v <- trimws(strsplit(x, "[|,]")[[1]]); v[nzchar(v)] }

# The settings as one sorted string, recorded on the run so any count can be
# traced to the column names and codes that produced it.
mdv_source_settings <- function() {
  cols <- unlist(MDV_COLS)
  cols[!nzchar(cols)] <- MDV_NONE   # an absent optional column, said as such
  kv <- c(paste0("table.", names(MDV_TABLES), "=", unlist(MDV_TABLES)),
          paste0("col.", names(MDV_COLS), "=", cols),
          paste0("value.", names(MDV_VALUES), "=", unlist(MDV_VALUES)))
  paste(sort(kv, method = "radix"), collapse = "|")
}

# Everything here is pasted into SQL, so it is held to identifier and literal
# shapes before any statement is built. Returns the problems; the caller stops.
check_mdv_settings <- function() {
  bad <- character(0)
  ident <- "^[A-Za-z_][A-Za-z0-9_]*$"
  for (k in names(MDV_TABLES))
    if (!grepl(ident, MDV_TABLES[[k]]))
      bad <- c(bad, paste0("MDV table '", k, "' = '", MDV_TABLES[[k]],
                           "' is not a table name"))
  for (k in names(MDV_COLS)) {
    v <- MDV_COLS[[k]]
    if (!nzchar(v)) {
      if (!k %in% MDV_OPTIONAL_COLUMNS)
        bad <- c(bad, paste0("MDV column '", k, "' is blank, and the rules ",
                             "cannot run without it"))
    } else if (identical(toupper(v), MDV_NONE)) {
      bad <- c(bad, paste0("MDV column '", k, "' = ", MDV_NONE, ", and only ",
                           paste(MDV_OPTIONAL_COLUMNS, collapse = ", "),
                           " may be absent"))
    } else if (!grepl(ident, v))
      bad <- c(bad, paste0("MDV column '", k, "' = '", v,
                           "' is not a column name"))
  }
  for (k in names(MDV_VALUES)) {
    v <- if (k == "death") mdv_split(MDV_VALUES[[k]]) else MDV_VALUES[[k]]
    if (!length(v) || any(!grepl("^[A-Za-z0-9_.-]+$", v)))
      bad <- c(bad, paste0("MDV value '", k, "' = '", MDV_VALUES[[k]],
                           "' (want letters or digits; for death a | list)"))
  }
  if (identical(MDV_VALUES$inpatient, MDV_VALUES$outpatient))
    bad <- c(bad, paste0("MDV_INPATIENT and MDV_OUTPATIENT are both '",
                         MDV_VALUES$inpatient, "'"))
  bad
}

# ---- table names ------------------------------------------------------------
# The vintage suffix: MDV_VINTAGE, always named outright (2026q2), never
# derived from STUDY_END. The MDV extract can be a quarter later than the study
# window - the window is the study's, the vintage is the data's - and a
# derivation reached only when the setting arrived blank depended on whether
# the variable was unset or set empty, which the loader treats alike. Blank
# takes the default in config.R / config_lot.R, so a blank here is a fault.
mdv_vintage <- function(cfg) {
  v <- tolower(trimws(cfg$mdv_vintage %||% ""))
  if (!nzchar(v))
    stop("MDV_VINTAGE is blank. Name the MDV extract's quarter, e.g. 2026q2; ",
         "it is never derived from STUDY_END.", call. = FALSE)
  v
}

mdv_tbl <- function(key, cfg = mdv_config()) {
  base <- MDV_TABLES[[key]]
  if (is.null(base)) stop("No MDV table called '", key, "'.", call. = FALSE)
  name <- if (isTRUE(cfg$use_quarterly_tables))
    paste0("t_", base, "_", mdv_vintage(cfg)) else base
  paste0(cfg$catalog, ".", cfg$cdm_schema, ".", name)
}

# Both packages call their config differently; this finds whichever is loaded.
mdv_config <- function() {
  if (exists("ndmm_config", mode = "function")) return(ndmm_config())
  lot_config()
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# ---- SQL expressions --------------------------------------------------------

# The digits of a value, whatever type the column is. A DATE casts to
# 2020-03-05, an integer to 20200305, a string may carry either.
mdv_digits_sql <- function(expr)
  paste0("regexp_replace(coalesce(cast(", expr, " as string), ''), '[^0-9]', '')")

# Eight digits, yyyyMMdd, as a date - or NULL where they are not a calendar
# date (20200230, 00000000, 20201301). to_date() raises on those under ANSI
# mode, Databricks SQL's default, so one malformed record would stop the run;
# try_to_timestamp() returns NULL instead (Spark 3.5+, Databricks Runtime
# 11.3+). tests/test_spark_sql.R runs this in Spark itself.
mdv_ymd_sql <- function(s)
  paste0("cast(try_to_timestamp(", s, ", 'yyyyMMdd') as date)")

# A day-level date from a DATE, a TIMESTAMP, yyyyMMdd as a number or a string,
# or yyyy-MM-dd. Anything with fewer than eight digits, or that is not a
# calendar date, is NULL, not a guess.
mdv_date_sql <- function(expr) {
  d <- mdv_digits_sql(expr)
  paste0("(CASE WHEN ", d, " RLIKE '^[0-9]{8}' THEN ",
         mdv_ymd_sql(paste0("substr(", d, ", 1, 8)")), " END)")
}

# The first day of a claim month, from yyyyMM, yyyy-MM, or any full date. The
# OC rules date a diagnosis this way (diagnosis_date = first calendar day of
# datamonth), and so does every diagnosis rule here.
mdv_month_sql <- function(expr) {
  d <- mdv_digits_sql(expr)
  paste0("(CASE WHEN ", d, " RLIKE '^[0-9]{6}' THEN ",
         mdv_ymd_sql(paste0("concat(substr(", d, ", 1, 6), '01')")), " END)")
}

# A code, the way every code here is normalised - on the MDV tables and on the
# code lists alike: trimmed, punctuation gone, letters upper-cased, so C90.0 and
# C900 are one code. And NULL where nothing is left. An empty key is not a
# code: '' equals '', so a receipt code of '--' in the drug master would meet
# every act whose code is blank, and a blank ICD-10 mapping would meet every
# other blank one. NULL joins nothing.
mdv_code_sql <- function(expr)
  paste0("nullif(upper(regexp_replace(trim(cast(", expr,
         " as string)), '[^A-Za-z0-9]', '')), '')")

# A value compared with one of MDV_VALUES, as text.
mdv_is_sql <- function(expr, value)
  paste0("trim(cast(", expr, " as string)) = '", value, "'")

mdv_in_sql <- function(expr, values)
  paste0("trim(cast(", expr, " as string)) IN (",
         paste0("'", values, "'", collapse = ", "), ")")

# Months between two first-of-month dates, as whole months.
mdv_month_diff_sql <- function(later, earlier)
  paste0("((year(", later, ") * 12 + month(", later, ")) - (year(", earlier,
         ") * 12 + month(", earlier, ")))")

# ---- the staged selects -----------------------------------------------------
# Each returns a SELECT with fixed, upper-case output names, so the steps read
# one shape whatever the delivery calls its columns. None filters rows: every
# rule applies its own window and its own conditions, where they can be read.
#
# Each opens with its own newline, paste0("\n", ...), because the steps splice
# them straight after an open parenthesis and glue() trims a template's
# leading blank line.

# One diagnosis on one monthly claim.
#   DX_MONTH    first day of the claim month - the diagnosis date
#   FROM_DT     the record's fromdate, for the FF1 alignment
#   DX_CODE     the MDV disease code, normalised
#   ICD10       the ICD-10 code, normalised, or NULL where the delivery has none
#   CONFIRMED   1 where utagaiflg is the confirmed value
#   CANCER      1 where cancerflg is the cancer value
#   INPT, OUTPT 1 where nyugaikbn is the inpatient / outpatient value
#   *_RAW       the three coded columns as text, for the value profile
mdv_dx_select <- function() {
  c <- MDV_COLS; v <- MDV_VALUES
  icd <- if (nzchar(c$icd10)) mdv_code_sql(paste0("d.", c$icd10)) else "cast(NULL as string)"
  paste0("
", "    SELECT cast(d.", c$patientid, " as string) AS PATID,
           ", mdv_month_sql(paste0("d.", c$datamonth)), " AS DX_MONTH,
           ", mdv_date_sql(paste0("d.", c$fromdate)), " AS FROM_DT,
           ", mdv_code_sql(paste0("d.", c$diseasecode)), " AS DX_CODE,
           ", icd, " AS ICD10,
           CASE WHEN ", mdv_is_sql(paste0("d.", c$utagaiflg), v$confirmed), " THEN 1 ELSE 0 END AS CONFIRMED,
           CASE WHEN ", mdv_is_sql(paste0("d.", c$cancerflg), v$cancer), " THEN 1 ELSE 0 END AS CANCER,
           CASE WHEN ", mdv_is_sql(paste0("d.", c$nyugaikbn), v$inpatient), " THEN 1 ELSE 0 END AS INPT,
           CASE WHEN ", mdv_is_sql(paste0("d.", c$nyugaikbn), v$outpatient), " THEN 1 ELSE 0 END AS OUTPT,
           trim(cast(d.", c$nyugaikbn, " as string)) AS INOUT_RAW,
           trim(cast(d.", c$utagaiflg, " as string)) AS SUSPECT_RAW,
           trim(cast(d.", c$cancerflg, " as string)) AS CANCER_RAW
    FROM ", mdv_tbl("disease"), " d")
}

# One act on one day: a drug given or dispensed, or a procedure.
#   ACT_DT       the act's date
#   RECEIPTCODE  the receipt code, normalised
#   INPT         1 inpatient, 0 outpatient, NULL where the delivery does not say
#                - or says with a value that is neither code (SETTING_RAW)
#   SETTING_RAW  the care-setting value as text; NULL only where the column is
#                declared NONE. Kept so a value neither MDV_INPATIENT nor
#                MDV_OUTPATIENT can be told from a column the delivery lacks.
#   ACT_DAYS     days supplied where the delivery carries it, else NULL
mdv_act_select <- function() {
  c <- MDV_COLS; v <- MDV_VALUES
  inpt <- if (nzchar(c$act_nyugaikbn))
    paste0("CASE WHEN ", mdv_is_sql(paste0("a.", c$act_nyugaikbn), v$inpatient),
           " THEN 1 WHEN ", mdv_is_sql(paste0("a.", c$act_nyugaikbn), v$outpatient),
           " THEN 0 END") else "cast(NULL as int)"
  raw <- if (nzchar(c$act_nyugaikbn))
    paste0("coalesce(trim(cast(a.", c$act_nyugaikbn, " as string)), '<null>')")
  else "cast(NULL as string)"
  days <- if (nzchar(c$act_days))
    paste0("cast(a.", c$act_days, " as int)") else "cast(NULL as int)"
  paste0("
", "    SELECT cast(a.", c$patientid, " as string) AS PATID,
           ", mdv_date_sql(paste0("a.", c$actdate)), " AS ACT_DT,
           ", mdv_code_sql(paste0("a.", c$receiptcode)), " AS RECEIPTCODE,
           ", inpt, " AS INPT,
           ", raw, " AS SETTING_RAW,
           ", days, " AS ACT_DAYS
    FROM ", mdv_tbl("act"), " a")
}

# The drug master, one row per receipt code and name.
mdv_drug_select <- function() {
  c <- MDV_COLS
  paste0("
", "    SELECT DISTINCT ", mdv_code_sql(paste0("m.", c$receiptcode)), " AS RECEIPTCODE,
           lower(trim(cast(m.", c$receiptname_eng, " as string))) AS NAME_ENG
    FROM ", mdv_tbl("drug"), " m
    WHERE ", mdv_code_sql(paste0("m.", c$receiptcode)), " IS NOT NULL")
}

# Demographics. GDR_CD is M, F or U, the way the Optum cohort carries it, so
# nothing downstream of the cohort has to know it came from MDV. YRDOB is the
# first four digits of the birth column, which may hold a year, a year-month
# or a date.
mdv_patient_select <- function() {
  c <- MDV_COLS; v <- MDV_VALUES
  b <- mdv_digits_sql(paste0("p.", c$birth))
  paste0("
", "    SELECT cast(p.", c$patientid, " as string) AS PATID,
           CASE WHEN ", mdv_is_sql(paste0("p.", c$sex), v$male), " THEN 'M'
                WHEN ", mdv_is_sql(paste0("p.", c$sex), v$female), " THEN 'F'
                ELSE 'U' END AS GDR_CD,
           CASE WHEN ", b, " RLIKE '^[0-9]{4}' THEN cast(substr(", b, ", 1, 4) as int) END AS YRDOB
    FROM ", mdv_tbl("patient"), " p")
}

# DPC Form 1 inpatient episodes.
#   CANCERFIRST 1 where cancerfirstflg is the first-occurrence value
#   CHEMO       1 where chemotherapyflg is anything but the no-chemotherapy value
#   DIED        1 where the discharge outcome is a death code; NULL where the
#               delivery has no outcome column, which is "not observed"
mdv_ff1_select <- function() {
  c <- MDV_COLS; v <- MDV_VALUES
  died <- if (nzchar(c$ff1_outcome))
    paste0("CASE WHEN ", mdv_in_sql(paste0("f.", c$ff1_outcome), mdv_split(v$death)),
           " THEN 1 ELSE 0 END") else "cast(NULL as int)"
  paste0("
", "    SELECT cast(f.", c$patientid, " as string) AS PATID,
           ", mdv_date_sql(paste0("f.", c$ff1startdate)), " AS FF1_START_DT,
           ", mdv_date_sql(paste0("f.", c$ff1enddate)), " AS FF1_END_DT,
           CASE WHEN ", mdv_is_sql(paste0("f.", c$cancerfirstflg), v$firstcancer), " THEN 1 ELSE 0 END AS CANCERFIRST,
           CASE WHEN f.", c$chemotherapyflg, " IS NOT NULL
                 AND NOT (", mdv_is_sql(paste0("f.", c$chemotherapyflg), v$no_chemo), ") THEN 1 ELSE 0 END AS CHEMO,
           ", died, " AS DIED
    FROM ", mdv_tbl("ff1"), " f")
}

# Every column the configured build reads, by table, for the preflight. Blank
# optional columns are not asked for.
mdv_required_columns <- function(tables = names(MDV_TABLES)) {
  out <- list()
  for (t in tables) {
    cols <- c(MDV_COLS$patientid[t != "drug"],
              if (t %in% c("drug", "act")) MDV_COLS$receiptcode,
              unlist(MDV_COLS[names(MDV_COLUMN_TABLE)[MDV_COLUMN_TABLE == t]]))
    out[[t]] <- unique(cols[nzchar(cols)])
  }
  out
}

# Ask the warehouse for every column the build reads. DESCRIBE, not a SELECT,
# so nothing is scanned. Returns "table: col, col" for each table missing any.
check_mdv_columns <- function(con, tables = names(MDV_TABLES), q = db_q) {
  want <- mdv_required_columns(tables)
  bad <- character(0)
  for (t in names(want)) {
    tbl <- mdv_tbl(t)
    d <- tryCatch(q(con, paste0("DESCRIBE ", tbl)), error = function(e) e)
    if (inherits(d, "condition")) {
      bad <- c(bad, paste0(tbl, ": cannot be described (", conditionMessage(d), ")"))
      next
    }
    cn <- intersect(c("col_name", "COL_NAME", "column_name", "name", "NAME"), names(d))
    have <- if (length(cn)) tolower(trimws(as.character(d[[cn[1]]]))) else character(0)
    miss <- setdiff(tolower(want[[t]]), have)
    if (length(miss))
      bad <- c(bad, paste0(tbl, ": no column ", paste(miss, collapse = ", ")))
  }
  bad
}
