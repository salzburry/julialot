# Filling one table: for each column work out the population, for each row read
# the study table the shell names and compute the statistic over it.
#
# Nothing clinical is derived here. Every number comes from a table the study
# package wrote, which is what makes a shell cell and the same figure on a page
# agree by construction; the only thing this adds is which rows of that table a
# column stands for.
#
# A row that cannot be filled is never blanked. It comes back with FILLED = 0
# and the reason it could not be filled, and the runner writes those reasons
# out - a shell asking for something the study does not produce has to say so,
# or the edit that asked for it looks like a zero.

# A column of a data frame by name, whatever case the source returned it in.
col_of <- function(d, name) {
  if (is.null(d) || !ncol(d)) return(NA_character_)
  hit <- names(d)[match(toupper(chr(name)), toupper(names(d)))]
  if (!length(hit) || is.na(hit[1])) NA_character_ else hit[1]
}

has_col <- function(d, name) !is.na(col_of(d, name))

# The patients behind a selection, which is the population the floor is about.
# A table with no identifier carries its own count instead, and where it has
# neither the answer is NA: a population that cannot be counted has not been
# shown to reach the floor.
TFLS_COUNT_COLUMNS <- c("N_AT_RISK", "N_DENOM", "N_PATIENTS", "N_REMAINING", "N")

population_denom <- function(d) {
  if (is.null(d) || !nrow(d)) return(0)
  idc <- col_of(d, "PATID")
  if (!is.na(idc)) {
    v <- chr(d[[idc]])
    return(length(unique(v[nzchar(v)])))
  }
  for (cl in TFLS_COUNT_COLUMNS) {
    hit <- col_of(d, cl)
    if (is.na(hit)) next
    n <- suppressWarnings(as.numeric(d[[hit]]))
    if (any(!is.na(n))) return(max(n, na.rm = TRUE))
  }
  NA_real_
}

# The patients in a selection, for a restriction that has to be carried from
# another table.
patients_of <- function(d) {
  idc <- col_of(d, "PATID")
  if (is.na(idc)) return(character(0))
  v <- chr(d[[idc]])
  unique(v[nzchar(v)])
}

# --- the context ------------------------------------------------------------
#
# Everything a fill needs that is not the shell: a reader for the study tables,
# the class definitions, and the table of lines a regimen class is assigned
# from. Tables are read once and kept, because a table of twelve rows is read
# by forty shell rows.
#
# `reader` is a function of one table name returning a data frame or NULL. The
# runner decides what that means - files under a snapshot, or the study
# package's own connection - and nothing below knows which it got.

# Where a subgroup that is not on the table itself may be carried from. Each is
# one row per patient, so a value on it names a set of patients.
TFLS_SUBJECT_TABLES <- c("S_DEMOGRAPHICS", "S_COMORBIDITY", "S_COMORB_SUBGROUP",
                         "S_FRAILTY", "S_SOC", "S_PERIODS", "S_TTE")

# The subgroups a table of totals answers from its own rows, by the table a
# subgroup names: the rate tables are written once per AGE_GROUP, the
# protocol's two groups as S_DEMOGRAPHICS writes them (variables/R/modules,
# 06_safety, 07_hcru, 08_malignancy).
TFLS_TOTALS_PROJECTIONS <- list(S_DEMOGRAPHICS = "AGE_GROUP")

# Every per-patient table a subgroup may be read on, and what makes one of its
# rows (variables/R/modules: 00_eligibility, 01_cohorts, 02_periods,
# 03_demographics, 04_comorbidity, 05_soc, 08_malignancy, 09_tte;
# ndmm/R/build_ndmm.R for the input cohort table):
#
#   keys     what makes a row besides the patient (and the cohort). Most hold
#            one row per patient per cohort; S_COMORB_SUBGROUP holds one per
#            concept, S_SOC and S_LOT_PERIODS one per line, S_MALIGNANCY one
#            per malignancy - so two values of a column there are two rows,
#            not two patients, unless the keys are fixed.
#   cohort   whether the table is written per cohort. S_ELIGIBILITY and the
#            input cohort table are one row per patient, whatever the cohort.
#   cols     the columns a subgroup may name on it.
#   domains  every value a column can take, where that is a short list and
#            never empty - what tells a split that covers the column from one
#            that leaves patients out (suppress.R, sg_levels_exact()). The
#            'Unknown' the study writes for a missing age or sex is left out:
#            it is the patients with no value, as a NULL is for a range, and
#            is usually none. A split of <75 and 75+ is taken for the whole
#            of AGE_GROUP, as it always was - taken for less, one of its
#            levels withheld beside a withheld Overall was printed, and where
#            nobody's age is unknown the two printed levels ARE Overall.
#
# A subgroup condition is read on one of these tables, the same one by the
# fill and the suppression (subgroup_source()); a table or column not named
# here is refused when the shell loads, because what its cells add up to
# beside the other columns could not be told.
TFLS_TABLE_GRAIN <- list(
  S_DEMOGRAPHICS = list(keys = character(0), cohort = TRUE, cols = c(
    "INDEX_DATE", "AGE_YEARS", "AGE_BAND", "AGE_GROUP", "SEX", "REGION", "RACE",
    "ETHNICITY", "INSURANCE_TYPE", "ENROL_ROW_FOUND", "ATTR_SOURCE",
    "AGE_AT_DX_YEARS", "AGE_AT_DX_BAND"),
    domains = list(AGE_GROUP = c("<75", "75+"),
                   AGE_BAND = c("18-44", "45-64", "65-74", "75+"),
                   SEX = c("Male", "Female"))),
  S_COMORBIDITY = list(keys = character(0), cohort = TRUE,
    cols = c("CCI", "CCI_BAND", "N_CONDITIONS"),
    domains = list(CCI_BAND = c("0", "1", "2", "3", "4", "5+"))),
  S_FRAILTY = list(keys = character(0), cohort = TRUE,
    cols = c("CFI", "FRAIL", "N_VARIABLES"), domains = list(FRAIL = c("0", "1"))),
  S_PERIODS = list(keys = character(0), cohort = TRUE, cols = c(
    "LOT_NUM", "INDEX_DATE", "INDEX_YEAR", "BASELINE_START", "BASELINE_END",
    "COMORB_BASELINE_START", "COMORB_BASELINE_END", "FU_END", "FU_DAYS",
    "FU_MONTHS", "BASELINE_PY", "TTE_ELIGIBLE", "MM_DX_DT", "DX_DT",
    "DX_DT_SOURCE", "DX_YEAR", "DX_TO_INDEX_DAYS", "DX_TO_INDEX_MONTHS",
    "FU_FROM_DX_DAYS", "FU_FROM_DX_MONTHS"),
    domains = list(TTE_ELIGIBLE = c("0", "1"))),
  S_TTE = list(keys = character(0), cohort = TRUE, cols = c(
    "LOT_NUM", "INDEX_DATE", "TTE_ELIGIBLE", "TTNT_DT", "TTNT_DAYS", "TTNT_MONTHS",
    "TTNT_EVENT", "TTD_DT", "TTD_DAYS", "TTD_MONTHS", "TTD_EVENT", "OS_DT",
    "OS_DAYS", "OS_MONTHS", "OS_EVENT"),
    domains = list(TTE_ELIGIBLE = c("0", "1"))),
  S_COHORT = list(keys = character(0), cohort = TRUE, cols = c(
    "LOT_NUM", "INDEX_DATE", "MET_N1", "MET_N2", "MET_I5", "MET_X1", "MET_X2",
    "MET_X3", "MET_X4", "IN_COHORT", "CRITERIA_ASKED", "NESTED")),
  S_ELIGIBILITY = list(keys = character(0), cohort = FALSE, cols = c(
    "COHORT_INDEX_DATE", "MM_DX_DT", "DEATH_DT", "ENDDATE", "ENDDATE_CE",
    "YRDOB", "GDR_CD", "MET_I1", "MET_I2", "MET_I3", "MET_I4", "MET_X1",
    "MET_X2", "MET_X3", "MET_X4", "EVIDENCE")),
  INPUT_COHORT_TABLE = list(keys = character(0), cohort = FALSE, cols = c(
    "INDEX_DATE", "MM_DX_DT", "ENDDATE", "ENDDATE_CE", "DEATH_DT", "GDR_CD",
    "YRDOB", "AGE_INDEX_YR", "FU_DAYS", "FU_DAYS_CE")),
  S_COMORB_SUBGROUP = list(keys = "CONCEPT", cohort = TRUE,
    cols = c("CONCEPT", "HAS_HISTORY", "FIRST_DT"),
    domains = list(HAS_HISTORY = c("0", "1"))),
  S_SOC = list(keys = "LOT_NUM", cohort = TRUE, cols = c(
    "LOT_NUM", "LOT_START_DT", "LOT_START_YEAR", "REGIMEN", "N_AGENTS",
    "SOC_CATEGORY", "MATCHED", "AUTO_SCT", "ALLO_SCT", "CART", "AUTO_SCT_DT",
    "AUTO_SCT_YEAR"),
    domains = list(AUTO_SCT = c("0", "1"), ALLO_SCT = c("0", "1"), CART = c("0", "1"))),
  S_LOT_PERIODS = list(keys = "LOT_NUM", cohort = TRUE, cols = c(
    "LOT_NUM", "PERIOD_START", "PERIOD_END", "PERIOD_PY", "LOT_START_DT",
    "PROTOCOL_DISCON_DT", "NEXT_LOT_START_DT", "NEXT_LOT_DAYS", "NEXT_LOT_MONTHS")),
  S_MALIGNANCY = list(keys = c("CATEGORY", "SUBTYPE"), cohort = TRUE, cols = c(
    "CATEGORY", "SUBTYPE", "FIRST_DT", "CONFIRM_DT", "N_DATES", "LOT_AFTER_WHICH",
    "AFTER_INDEX", "MONTHS_FROM_DX", "MONTHS_FROM_INDEX"),
    domains = list(AFTER_INDEX = c("0", "1"))))

# Columns that are one quantity written more than one way, on one table or
# several: an age in years, the age groups and bands cut from it and the year
# of birth it is counted from; the study's sex and the enrolment sex it is
# taken from; a length in days and in months; an event date and the flag and
# year read off it. Splits on two of them are levels of one thing, and two
# columns constraining it are held to one rule (suppress.R,
# split_contract_why()). A column not listed is its own quantity.
TFLS_DIMENSIONS <- list(
  AGE = c("S_DEMOGRAPHICS:AGE_YEARS", "S_DEMOGRAPHICS:AGE_GROUP",
          "S_DEMOGRAPHICS:AGE_BAND", "S_ELIGIBILITY:YRDOB",
          "INPUT_COHORT_TABLE:YRDOB", "INPUT_COHORT_TABLE:AGE_INDEX_YR"),
  AGE_AT_DX = c("S_DEMOGRAPHICS:AGE_AT_DX_YEARS", "S_DEMOGRAPHICS:AGE_AT_DX_BAND"),
  SEX = c("S_DEMOGRAPHICS:SEX", "S_ELIGIBILITY:GDR_CD", "INPUT_COHORT_TABLE:GDR_CD"),
  INDEX = c("S_DEMOGRAPHICS:INDEX_DATE", "S_PERIODS:INDEX_DATE", "S_PERIODS:INDEX_YEAR",
            "S_TTE:INDEX_DATE", "S_COHORT:INDEX_DATE", "S_ELIGIBILITY:COHORT_INDEX_DATE",
            "INPUT_COHORT_TABLE:INDEX_DATE"),
  DIAGNOSIS = c("S_PERIODS:MM_DX_DT", "S_PERIODS:DX_DT", "S_PERIODS:DX_YEAR",
                "S_PERIODS:DX_DT_SOURCE", "S_ELIGIBILITY:MM_DX_DT",
                "INPUT_COHORT_TABLE:MM_DX_DT"),
  DX_TO_INDEX = c("S_PERIODS:DX_TO_INDEX_DAYS", "S_PERIODS:DX_TO_INDEX_MONTHS"),
  FOLLOW_UP = c("S_PERIODS:FU_END", "S_PERIODS:FU_DAYS", "S_PERIODS:FU_MONTHS",
                "INPUT_COHORT_TABLE:FU_DAYS"),
  FOLLOW_UP_CE = "INPUT_COHORT_TABLE:FU_DAYS_CE",
  FU_FROM_DX = c("S_PERIODS:FU_FROM_DX_DAYS", "S_PERIODS:FU_FROM_DX_MONTHS"),
  END = c("S_ELIGIBILITY:ENDDATE", "S_ELIGIBILITY:DEATH_DT",
          "INPUT_COHORT_TABLE:ENDDATE", "INPUT_COHORT_TABLE:DEATH_DT"),
  END_CE = c("S_ELIGIBILITY:ENDDATE_CE", "INPUT_COHORT_TABLE:ENDDATE_CE"),
  TTE_ELIGIBLE = c("S_PERIODS:TTE_ELIGIBLE", "S_TTE:TTE_ELIGIBLE"),
  TTNT = c("S_TTE:TTNT_DT", "S_TTE:TTNT_DAYS", "S_TTE:TTNT_MONTHS", "S_TTE:TTNT_EVENT"),
  TTD = c("S_TTE:TTD_DT", "S_TTE:TTD_DAYS", "S_TTE:TTD_MONTHS", "S_TTE:TTD_EVENT"),
  OS = c("S_TTE:OS_DT", "S_TTE:OS_DAYS", "S_TTE:OS_MONTHS", "S_TTE:OS_EVENT"),
  CCI = c("S_COMORBIDITY:CCI", "S_COMORBIDITY:CCI_BAND"),
  FRAILTY = c("S_FRAILTY:CFI", "S_FRAILTY:FRAIL"),
  COMORB_HISTORY = c("S_COMORB_SUBGROUP:HAS_HISTORY", "S_COMORB_SUBGROUP:FIRST_DT"),
  LOT_START = c("S_SOC:LOT_START_DT", "S_SOC:LOT_START_YEAR",
                "S_LOT_PERIODS:LOT_START_DT", "S_LOT_PERIODS:PERIOD_START"),
  AUTO_SCT = c("S_SOC:AUTO_SCT", "S_SOC:AUTO_SCT_DT", "S_SOC:AUTO_SCT_YEAR"),
  LOT_PERIOD = c("S_LOT_PERIODS:PERIOD_END", "S_LOT_PERIODS:PERIOD_PY",
                 "S_LOT_PERIODS:PROTOCOL_DISCON_DT"),
  NEXT_LOT = c("S_LOT_PERIODS:NEXT_LOT_START_DT", "S_LOT_PERIODS:NEXT_LOT_DAYS",
               "S_LOT_PERIODS:NEXT_LOT_MONTHS"),
  REGIMEN_CLASS = c("S_SOC:SOC_CATEGORY", "S_SOC:REGIMEN", "S_SOC:N_AGENTS"),
  MALIGNANCY_TIME = c("S_MALIGNANCY:FIRST_DT", "S_MALIGNANCY:CONFIRM_DT",
                      "S_MALIGNANCY:LOT_AFTER_WHICH", "S_MALIGNANCY:AFTER_INDEX",
                      "S_MALIGNANCY:MONTHS_FROM_DX", "S_MALIGNANCY:MONTHS_FROM_INDEX"))

# The quantity a condition's column is: its TFLS_DIMENSIONS name, or itself.
dimension_of <- function(var) {
  v <- toupper(chr(var))
  hit <- names(TFLS_DIMENSIONS)[vapply(TFLS_DIMENSIONS, function(x) v %in% x, logical(1))]
  if (length(hit)) hit[1] else v
}

# The name TFLS_TABLE_GRAIN knows a table by: the input cohort table goes by
# three (TFLS_COHORT_TABLE_NAMES), and is one table.
grain_name <- function(tab) {
  t <- toupper(chr(tab))
  if (t %in% TFLS_COHORT_TABLE_NAMES) "INPUT_COHORT_TABLE" else t
}

# The one table a subgroup condition on `column` is read on, by the fill and
# by the suppression alike: the table the subgroup names, or - unqualified -
# the one per-patient subject table that carries the column. A table or
# column TFLS_TABLE_GRAIN does not describe, or a column several subject
# tables carry (TTE_ELIGIBLE is on S_PERIODS and S_TTE), is refused with what
# to write instead.
subgroup_source <- function(table, column) {
  col <- toupper(chr(column))
  if (nzchar(chr(table))) {
    t <- grain_name(table)
    g <- TFLS_TABLE_GRAIN[[t]]
    if (is.null(g))
      return(list(ok = FALSE, why = paste0(chr(table), " is not a table a ",
        "subgroup is read on, so what its columns add up to beside the ",
        "others cannot be told; the tables are ",
        paste(c(setdiff(names(TFLS_TABLE_GRAIN), "INPUT_COHORT_TABLE"),
                "the input cohort table"), collapse = ", "))))
    if (!col %in% g$cols)
      return(list(ok = FALSE, why = paste0(chr(table), " carries no ", col,
                                           " a subgroup can name")))
    return(list(ok = TRUE, table = t, why = ""))
  }
  hold <- Filter(function(t) col %in% TFLS_TABLE_GRAIN[[t]]$cols,
                 intersect(TFLS_SUBJECT_TABLES, names(TFLS_TABLE_GRAIN)))
  if (length(hold) == 1L) return(list(ok = TRUE, table = hold, why = ""))
  if (!length(hold))
    return(list(ok = FALSE, why = paste0("no per-patient table a subgroup ",
      "reads unqualified carries ", col, "; name the table it is on, as ",
      "TABLE:", col)))
  list(ok = FALSE, why = paste0(col, " is on ", paste(hold, collapse = " and "),
    "; name the one it is read from, as ", hold[1], ":", col))
}

# The names a shell may use for the input cohort table. The study's own
# diagnosis date is on S_PERIODS (DX_DT, with DX_YEAR and the durations hung
# on it), so a row anchored on diagnosis reads that; these names are for a
# shell that asks for the cohort build's table itself, which only a run told
# where that table is can fill.
TFLS_COHORT_TABLE_NAMES <- c("COHORT_TABLE", "INPUT_COHORT", "INPUT_COHORT_TABLE")

# `absent_why` is optional and says WHY a table is not there, in the reader's
# own words: a reader bound to one run knows that a table under the prefix is a
# previous run's, and that is a different gap from a table nobody wrote. Where
# no reader says, an absent table is reported as absent and nothing more.
fill_context <- function(reader, classes, soc_table = "S_SOC",
                         subject_tables = TFLS_SUBJECT_TABLES,
                         tte_eligible_only = FALSE, absent_why = NULL) {
  cache <- new.env(parent = emptyenv())
  get_table <- function(name) {
    key <- toupper(chr(name))
    if (!nzchar(key)) return(NULL)
    if (!exists(key, envir = cache, inherits = FALSE))
      assign(key, tryCatch(reader(key), error = function(e) NULL), envir = cache)
    get(key, envir = cache, inherits = FALSE)
  }
  why_absent <- function(name) {
    if (!is.function(absent_why)) return("")
    chr(tryCatch(absent_why(toupper(chr(name))), error = function(e) ""))[1]
  }
  list(get = get_table, classes = classes, soc_table = soc_table,
       subject_tables = subject_tables,
       tte_eligible_only = isTRUE(tte_eligible_only),
       absent_why = why_absent)
}

# --- the population a column stands for -------------------------------------

column_spec <- function(col) {
  list(id = chr(col$column_id), label = chr(col$label), group = chr(col$group),
       cohort = chr(col$cohort), line = chr(col$line), class = chr(col$class),
       subgroup = chr(col$subgroup), period = chr(col$period),
       order = as_int(col$order))
}

# What a column selects, in words, for the plan and for a caption.
column_population_label <- function(col, classes = NULL) {
  s <- if (is.list(col) && !is.null(col$id)) col else column_spec(col)
  bits <- c(
    if (nzchar(s$cohort)) paste0("cohort ", s$cohort),
    if (nzchar(s$line)) paste0("line ", s$line),
    if (nzchar(s$class)) paste0("class ", if (is.null(classes)) s$class
                                else class_heading(s$class, classes)),
    if (nzchar(s$subgroup)) paste0("subgroup ", s$subgroup),
    if (nzchar(s$period)) paste0("period ", s$period))
  if (!length(bits)) "every patient in the table" else paste(bits, collapse = ", ")
}

# Why a cell could not be filled, in three kinds, because the three are
# somebody else's to close:
#
#   not_in_run      the run did not write the table, the column or the rows
#                   this needed. A module that was switched off, or a code list
#                   with no codes in it yet. The study team's to close.
#   shell           the shell does not say enough: no source, no statistic, a
#                   class mapped to no category, a filter that leaves more than
#                   one row. The shell's to close, and it is a file anyone can
#                   edit.
#   not_computable  the statistic cannot be made from what the table holds - a
#                   mean over a table of totals, a regimen class on a table of
#                   totals. Ours to close, where it can be closed at all.
TFLS_REASON_KINDS <- c("not_in_run", "shell", "not_computable")

refuse <- function(why, kind = "not_computable")
  list(ok = FALSE, why = why, kind = kind)

# A column as the numbers a range compares, from the values as the reader
# typed them. A date is its day number - 18262 is 1 January 2020 - whether it
# arrives as an R Date (the warehouse) or as ISO text (a snapshot's CSV), so
# one range selects the same rows from either; read as text first, a Date
# became "2020-06-01", no number at all, and every row fell outside. A
# number is itself, and anything else, a missing date included, is in no
# range.
range_number <- function(x) {
  if (inherits(x, "Date")) return(as.numeric(x))
  if (inherits(x, "POSIXt")) return(as.numeric(as.Date(x)))
  if (is.numeric(x)) return(as.numeric(x))
  v <- chr(x)
  out <- suppressWarnings(as.numeric(v))
  iso <- is.na(out) & grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v)
  if (any(iso)) out[iso] <- as.numeric(as.Date(v[iso], format = "%Y-%m-%d"))
  out
}

# One comparison, applied to a table.
apply_term <- function(d, term, where) {
  cl <- col_of(d, term$column)
  if (is.na(cl))
    return(refuse(paste0("column ", term$column, " is not in ", where),
                  "not_in_run"))
  if (!length(term$value)) return(list(ok = TRUE, rows = d))
  v <- d[[cl]]
  keep <- switch(term$op,
    "=" = chr(v) %in% chr(term$value),
    "!=" = !chr(v) %in% chr(term$value),
    {
      x <- range_number(v)
      y <- range_number(term$value)[1]
      if (is.na(y))
        return(refuse(paste0("'", term$raw, "' compares ", term$column,
                             " with something that is not a number"), "shell"))
      switch(term$op,
             ">" = !is.na(x) & x > y, "<" = !is.na(x) & x < y,
             ">=" = !is.na(x) & x >= y, "<=" = !is.na(x) & x <= y,
             return(refuse(paste0("'", term$raw, "' uses a comparison this ",
                                  "code does not apply"), "shell")))
    })
  list(ok = TRUE, rows = d[keep, , drop = FALSE])
}

# The rows of one study table that a column stands for.
#
# Fails closed. A selector the table cannot carry is refused with the reason,
# never ignored: publishing the whole table under a heading that names one line
# and one regimen class would be a different population under that label.
TFLS_SELECTOR_KIND <- c(COHORT = "cohort", LOT_NUM = "line", PERIOD = "period")

select_population <- function(d, spec, ctx, where) {
  keys <- list(COHORT = spec$cohort, LOT_NUM = spec$line, PERIOD = spec$period)
  for (k in names(keys)) {
    v <- keys[[k]]
    if (!nzchar(v)) next
    cl <- col_of(d, k)
    if (!is.na(cl)) {
      d <- d[selector_has(d[[cl]], v, TFLS_SELECTOR_KIND[[k]]), , drop = FALSE]
      next
    }
    # A line can still be carried, where the table is per patient and the
    # study's per-line tables say which patients have that line.
    if (identical(k, "LOT_NUM") && has_col(d, "PATID")) {
      rows <- line_rows(ctx, line = v, cohort = spec$cohort)
      if (!is.null(rows)) {
        d <- keep_carried(d, rows)
        next
      }
    }
    return(refuse(paste0(where, " carries no ", k,
                         ", so the column's ", tolower(k), " ", v,
                         " cannot be selected from it"), "not_in_run"))
  }
  named <- character(0)
  if (nzchar(spec$class)) {
    r <- restrict_to_class(d, spec, ctx, where)
    if (!isTRUE(r$ok)) return(r)
    d <- r$rows
    if (!identical(class_selection(spec$class, ctx$classes)$kind, "all"))
      named <- c(named, "SOC_CATEGORY")
  }
  if (nzchar(spec$subgroup)) {
    r <- restrict_to_subgroup(d, spec$subgroup, ctx, where, spec$cohort)
    if (!isTRUE(r$ok)) return(r)
    d <- r$rows
    named <- c(named, subgroup_columns(spec$subgroup))
  }
  list(ok = TRUE, rows = restrict_unnamed_strata(d, named))
}

# The columns a subgroup restricts, for deciding which stratifications the
# column left alone.
subgroup_columns <- function(subgroup) {
  sg <- parse_subgroup(subgroup)
  if (!isTRUE(sg$ok) || !length(sg$terms)) return(character(0))
  toupper(vapply(sg$terms, function(t) chr(t$column), character(1)))
}

# A stratification the column did not name is the table's own total row.
#
# The package writes these tables once for the line as a whole and once per
# stratum, so reading them all would be the line drawn beside its own parts. A
# column that names a regimen class takes the categories and leaves age at its
# total, and the other way round - which is also what makes the margins add up.
#
# A table that carries the column without carrying the total row is not one of
# these: SOC_CATEGORY on S_PATTERNS is the thing its rows enumerate, and is
# left alone.
restrict_unnamed_strata <- function(d, named) {
  if (is.null(d) || !nrow(d)) return(d)
  for (nm in setdiff(names(TFLS_STRATUM_TOTALS), toupper(named))) {
    cl <- col_of(d, nm)
    if (is.na(cl)) next
    tot <- TFLS_STRATUM_TOTALS[[nm]]
    hit <- soc_key(d[[cl]]) %in% soc_key(tot)
    if (!any(hit)) next
    d <- d[hit, , drop = FALSE]
  }
  d
}

# The patients of one line of one cohort, for a table that is one row per
# patient and names no line of its own - the baseline characteristics.
#
# The study's regimen table says, and is read first, so a run that has it reads
# exactly what it always did. A run that skipped the SOC module - its code
# lists not yet authored - wrote no S_SOC, and every such row was refused,
# T1's demographics among them, though nothing in them is about a regimen.
# S_LOT_PERIODS holds the same lines. S_SOC keeps each line from the cohort's
# index on that starts inside the cohort's follow-up; S_LOT_PERIODS keeps the
# same lines from the index on, and a line starting after the follow-up ended
# is the one whose period is empty, PERIOD_END before PERIOD_START, so dropping
# those is S_SOC's other bound. (S_SOC also drops a line that is neither drugs
# nor a transplant; the engine does not build one.) For the line a cohort is
# indexed on - every Overall column - either table gives the whole cohort.
line_rows <- function(ctx, line = "", cohort = "") {
  rows <- soc_rows(ctx, line = line, cohort = cohort)
  if (!is.null(rows)) return(rows)
  lp <- ctx$get("S_LOT_PERIODS")
  if (is.null(lp) || !nrow(lp) || !has_col(lp, "PATID") || !has_col(lp, "LOT_NUM"))
    return(NULL)
  if (nzchar(chr(line))) {
    lp <- lp[selector_has(lp[[col_of(lp, "LOT_NUM")]], line, "line"), , drop = FALSE]
  }
  if (nzchar(chr(cohort)) && has_col(lp, "COHORT"))
    lp <- lp[selector_has(lp[[col_of(lp, "COHORT")]], cohort, "cohort"), , drop = FALSE]
  if (has_col(lp, "PERIOD_START") && has_col(lp, "PERIOD_END")) {
    st <- suppressWarnings(as.Date(lp[[col_of(lp, "PERIOD_START")]]))
    en <- suppressWarnings(as.Date(lp[[col_of(lp, "PERIOD_END")]]))
    lp <- lp[!is.na(st) & !is.na(en) & en >= st, , drop = FALSE]
  }
  lp
}

line_patients <- function(ctx, line = "", cohort = "") {
  rows <- line_rows(ctx, line = line, cohort = cohort)
  if (is.null(rows)) NULL else patients_of(rows)
}

# The patients of one line, and optionally of one regimen class, off the
# study's own per-line categorisation. NULL where that table was not read,
# which the caller reports rather than filling around.
soc_rows <- function(ctx, line = "", cohort = "", categories = NULL,
                     drug = "") {
  s <- ctx$get(ctx$soc_table)
  if (is.null(s) || !nrow(s) || !has_col(s, "PATID") || !has_col(s, "LOT_NUM"))
    return(NULL)
  if (nzchar(chr(line))) {
    s <- s[selector_has(s[[col_of(s, "LOT_NUM")]], line, "line"), , drop = FALSE]
  }
  # A patient sits in several nested cohorts with a different index date in
  # each, so the cohort narrows the lines as well as the patients.
  if (nzchar(chr(cohort)) && has_col(s, "COHORT"))
    s <- s[selector_has(s[[col_of(s, "COHORT")]], cohort, "cohort"), , drop = FALSE]
  if (!is.null(categories)) {
    if (!has_col(s, "SOC_CATEGORY")) return(NULL)
    s <- s[soc_key(s[[col_of(s, "SOC_CATEGORY")]]) %in% soc_key(categories), ,
           drop = FALSE]
  }
  # The drug narrows the study's own category to the lines whose regimen holds
  # that agent. The regimen string is the study's, read as the study writes it.
  if (nzchar(chr(drug))) {
    rc <- col_of(s, "REGIMEN")
    if (is.na(rc)) return(NULL)
    s <- s[regimen_has_drug(s[[rc]], drug), , drop = FALSE]
  }
  s
}

soc_patients <- function(ctx, line = "", cohort = "", categories = NULL,
                         drug = "") {
  rows <- soc_rows(ctx, line, cohort, categories, drug)
  if (is.null(rows)) NULL else patients_of(rows)
}

# The rows of `d` whose patient `rows` holds - in the same cohort, where both
# are written per cohort. A patient is in several nested cohorts, taken at a
# different index in each: aged 74 at 1L and 75 at 2L, under 75 in a column
# pooling the two is the 1L row, and carried as a bare patient it kept the 2L
# row too, so the 2L outcome was averaged in beside the 1L one - N 60 over 30
# patients. The pair is what qualified, so the pair is what is kept.
keep_carried <- function(d, rows) {
  pid <- chr(d[[col_of(d, "PATID")]])
  sid <- chr(rows[[col_of(rows, "PATID")]])
  if (has_col(d, "COHORT") && has_col(rows, "COHORT"))
    return(d[paste(pid, toupper(chr(d[[col_of(d, "COHORT")]])), sep = "\r") %in%
               paste(sid, toupper(chr(rows[[col_of(rows, "COHORT")]])), sep = "\r"), ,
             drop = FALSE])
  d[pid %in% sid[nzchar(sid)], , drop = FALSE]
}

# The study assigns a category to a line, so a column naming a regimen class
# has to name the line as well; the category of "the patient" is not a thing.
restrict_to_class <- function(d, spec, ctx, where) {
  sel <- class_selection(spec$class, ctx$classes)
  # An Overall column names no category, so the stratification is left for
  # restrict_unnamed_strata() to take to the line's own row.
  if (identical(sel$kind, "all")) return(list(ok = TRUE, rows = d))
  # A class the shell maps to nothing is the shell's gap to close: the study's
  # category, or that category narrowed by a drug, is how it would be closed.
  if (!identical(sel$kind, "categories")) return(refuse(sel$why, "shell"))
  cats <- sel$categories
  cl <- col_of(d, "SOC_CATEGORY")
  if (!is.na(cl)) {
    keep <- soc_key(d[[cl]]) %in% soc_key(cats)
    if (nzchar(sel$drug)) {
      rc <- col_of(d, "REGIMEN")
      if (is.na(rc))
        return(refuse(paste0(where, " carries no REGIMEN, so the class ",
          spec$class, " cannot be narrowed to the lines holding ", sel$drug),
          "not_computable"))
      keep <- keep & regimen_has_drug(d[[rc]], sel$drug)
    }
    return(list(ok = TRUE, rows = d[keep, , drop = FALSE]))
  }
  if (!has_col(d, "PATID"))
    return(refuse(paste0(where, " is aggregated and carries no SOC_CATEGORY, ",
                         "so the class ", spec$class,
                         " cannot be applied to it"), "not_in_run"))
  if (!nzchar(spec$line))
    return(refuse(paste0("the column names the regimen class ", spec$class,
                         " but no line, and the study assigns a category to ",
                         "a line"), "shell"))
  rows <- soc_rows(ctx, line = spec$line, cohort = spec$cohort,
                   categories = cats, drug = sel$drug)
  if (is.null(rows))
    return(refuse(paste0(ctx$soc_table, " was not read by this run, so the ",
                         "study's regimen class for a line is not available"),
                  "not_in_run"))
  list(ok = TRUE, rows = keep_carried(d, rows))
}

# --- subgroups --------------------------------------------------------------
#
# The three the study package can answer, each off a table it writes per
# patient. A subgroup naming anything else is looked for on the table itself
# and then on the per-patient tables, and is reported unfilled where no table
# read by the run carries it.

TFLS_SUBGROUPS <- list(
  NEUROPATHY = list(table = "S_COMORB_SUBGROUP", flag = "HAS_HISTORY",
                    concept_col = "CONCEPT", concept = "neuropathy",
                    what = "a baseline history of neuropathy"),
  FRAILTY = list(table = "S_FRAILTY", flag = "FRAIL",
                 what = "the claims-based frailty index"),
  AGE = list(table = "S_DEMOGRAPHICS", column = "AGE_YEARS",
             what = "age at index",
             bands = list(LT75 = list(op = "<", cut = 75),
                          GE75 = list(op = ">=", cut = 75))))

TFLS_SUBGROUP_YES <- c("YES", "Y", "TRUE", "T", "1")
TFLS_SUBGROUP_NO <- c("NO", "N", "FALSE", "F", "0")
TFLS_AGE_BANDS <- list(LT75 = c("LT75", "<75", "UNDER75", "LESS75"),
                       GE75 = c("GE75", ">=75", "75+", "GTE75"))

# A named subgroup is a yes or a no, or an age band, and is asked for with =.
# Any other comparison was dropped on the way in: NEUROPATHY!=YES selected the
# patients WITH a neuropathy history.
named_subgroup_op_why <- function(t)
  paste0("'", chr(t$raw), "' compares the named subgroup ", toupper(chr(t$column)),
         " with '", chr(t$op), "'; a named subgroup is asked for with = only - ",
         "the other value is its own subgroup (", toupper(chr(t$column)),
         if (identical(toupper(chr(t$column)), "AGE")) "=LT75 or =GE75" else "=YES or =NO",
         ")")

# Whether a named subgroup's value is one it has, and if not, why.
named_subgroup_value_why <- function(t) {
  def <- TFLS_SUBGROUPS[[toupper(chr(t$column))]]
  if (is.null(def)) return("")
  if (!identical(chr(t$op), "=")) return(named_subgroup_op_why(t))
  v <- chr(t$value)
  ok <- length(v) == 1L && (
    if (!is.null(def$bands)) nzchar(subgroup_band(v))
    else toupper(v) %in% c(TFLS_SUBGROUP_YES, TFLS_SUBGROUP_NO))
  if (ok) "" else paste0("'", chr(t$raw), "' is not one value the named subgroup ",
    toupper(chr(t$column)), " has: ",
    if (!is.null(def$bands)) paste(names(def$bands), collapse = " or ") else "YES or NO")
}

subgroup_band <- function(value) {
  v <- toupper(gsub("[[:space:]]", "", chr(value)))
  for (nm in names(TFLS_AGE_BANDS)) if (v %in% TFLS_AGE_BANDS[[nm]]) return(nm)
  ""
}

# A subgroup is read from the conditions subgroup_conditions() (suppress.R)
# makes of it - the one representation the suppression reads too - so what a
# column selects and what the suppression takes it to select cannot differ.
# Each condition is on ONE table: the table the subgroup names, a named
# subgroup's own, or - for a column it leaves unqualified - the one
# per-patient table that carries that column (subgroup_source()).
# AGE_YEARS<65 is S_DEMOGRAPHICS:AGE_YEARS<65, read the same way whichever
# row it is under.
#
# The conditions on one table are applied together, to its rows, before any
# patient is taken: S_COMORB_SUBGROUP has a row per patient and concept, and
# CONCEPT=neuropathy on one row with HAS_HISTORY=1 on another is not a history
# of neuropathy. That holds for a named subgroup and the conditions written
# beside it alike. NEUROPATHY=YES&HAS_HISTORY=0 was the patients with a
# neuropathy history and a zero on some other concept's row - every one of
# them, where each has several concepts - while the suppression read it, as
# written out, as one row with a history of 1 and of 0, which is nobody. It
# is nobody here too. And the rows are this column's cohort's: demographics
# are taken at each cohort's own index, so a patient under 75 at 1L and 75+
# at 2L is not under 75 in the 2L column.
restrict_to_subgroup <- function(d, subgroup, ctx, where, cohort = "") {
  sc <- subgroup_conditions(subgroup)
  if (!isTRUE(sc$ok))
    return(refuse(paste0("the subgroup '", subgroup, "' cannot be read: ",
                         sc$why), "shell"))
  if (!length(sc$conds)) return(list(ok = TRUE, rows = d))
  tabs <- unique(vapply(sc$conds, function(cn) sub(":.*$", "", cn$var), ""))
  for (tb in tabs) {
    cs <- Filter(function(cn) identical(sub(":.*$", "", cn$var), tb), sc$conds)
    r <- restrict_on_table(d, cs, tb, ctx, where, cohort, subgroup,
                           rows_ok = !tb %in% sc$named)
    if (!isTRUE(r$ok)) return(r)
    d <- r$rows
  }
  list(ok = TRUE, rows = d)
}

# One condition (suppress.R, sg_cond()), applied to a table's rows: a list of
# values compared as text, or one range of a number, which a value that is
# not a number is outside.
apply_cond <- function(d, cn, where) {
  col <- sub("^[^:]*:", "", cn$var)
  cl <- col_of(d, col)
  if (is.na(cl))
    return(refuse(paste0("column ", col, " is not in ", where), "not_in_run"))
  raw <- d[[cl]]
  v <- if (cn$var %in% TFLS_CASELESS) soc_key(raw) else chr(raw)
  keep <- switch(cn$kind,
    "in" = v %in% cn$vals,
    "out" = !v %in% cn$vals,
    "has" = regimen_has_drug(raw, cn$vals),
    sg_in_range(range_number(raw), cn))
  list(ok = TRUE, rows = d[keep, , drop = FALSE])
}

# The conditions a subgroup puts on one table, applied to `d`.
#
# The table is read, for the column's cohort, and selects patients - with two
# bounded exceptions, where the rows being summarised answer it themselves.
# Rows OF that table are filtered as rows, which is what T3 means: its columns
# are the interval each malignancy fell in, not the patients who had one
# there; a named subgroup is always patients, which is what T1b means - its
# lung row reads S_COMORB_SUBGROUP too (`rows_ok`). And a table of totals,
# which has no patient to look up, answers from its own rows only what it was
# written by: the rate tables are cut by the protocol's age group, taken from
# S_DEMOGRAPHICS, and nothing else a subgroup can name.
#
# Anywhere else a column of the same name is a different fact. S_TTE's
# LOT_NUM is the line its cohort is indexed on, not a later line in
# S_LOT_PERIODS, so S_LOT_PERIODS:LOT_NUM=3 read off a 2L S_TTE found nobody
# where 50 patients had gone on to a third line.
restrict_on_table <- function(d, conds, table, ctx, where, cohort, subgroup,
                              rows_ok = TRUE) {
  same <- isTRUE(rows_ok) && identical(grain_name(where), table)
  totals <- !has_col(d, "PATID")
  cols <- vapply(conds, function(cn) sub("^[^:]*:", "", cn$var), "")
  if (totals && !same) {
    proj <- TFLS_TOTALS_PROJECTIONS[[table]]
    if (is.null(proj) || !all(cols %in% proj))
      return(refuse(paste0(where, " is a table of totals, with no patient ",
        "to look up in ", table, "; the only subgroup it answers from its ",
        "own rows is ", paste(vapply(names(TFLS_TOTALS_PROJECTIONS), function(n)
          paste0(n, ":", paste(TFLS_TOTALS_PROJECTIONS[[n]], collapse = "/")), ""),
          collapse = ", "), ", which the study cuts it by"), "not_computable"))
  }
  if ((same || totals) && all(vapply(cols, function(cl) has_col(d, cl), logical(1)))) {
    for (cn in conds) {
      r <- apply_cond(d, cn, where)
      if (!isTRUE(r$ok)) return(r)
      d <- r$rows
    }
    return(list(ok = TRUE, rows = d))
  }
  s <- ctx$get(table)
  if (is.null(s) || !nrow(s))
    return(refuse(paste0(table, " was not read by this run, so the ",
                         "subgroup ", subgroup, " cannot be applied"),
                  "not_in_run"))
  if (nzchar(chr(cohort)) && has_col(s, "COHORT"))
    s <- s[selector_has(s[[col_of(s, "COHORT")]], cohort, "cohort"), , drop = FALSE]
  for (cn in conds) {
    r <- apply_cond(s, cn, table)
    if (!isTRUE(r$ok)) return(r)
    s <- r$rows
  }
  if (!nrow(s))
    return(refuse(paste0("no row of ", table, " meets ", subgroup,
      ", so this subgroup holds nobody in this run"), "not_in_run"))
  if (!has_col(d, "PATID"))
    return(refuse(paste0(where, " carries no patient, so the subgroup ",
                         subgroup, " cannot be applied to it"),
                  "not_computable"))
  list(ok = TRUE, rows = keep_carried(d, s))
}

# A shell speaks in its own column headings and a study table speaks in SOC
# categories, so a measure comparing SOC_CATEGORY with a class the shell
# defines is read as that class's categories. One vocabulary reaches the data,
# and a heading and a row cannot mean different things by the same word.
translate_class_term <- function(term, ctx) {
  if (!identical(toupper(chr(term$column)), "SOC_CATEGORY") ||
      !length(term$value)) return(list(ok = TRUE, term = term))
  ids <- chr(ctx$classes$class_id)
  if (!any(chr(term$value) %in% ids)) return(list(ok = TRUE, term = term))
  out <- character(0)
  for (v in chr(term$value)) {
    if (class_is_overall(v)) {
      # The total is every category, so it is no restriction at all.
      term$value <- character(0)
      return(list(ok = TRUE, term = term))
    }
    if (!v %in% ids) { out <- c(out, v); next }
    cats <- class_categories(v, ctx$classes)
    if (!length(cats))
      return(list(ok = FALSE, why = paste0(
        "the shell maps the class ", v, " to no SOC category, so the study's ",
        "own categories cannot separate this row yet")))
    out <- c(out, cats)
  }
  term$value <- unique(out)
  list(ok = TRUE, term = term)
}

# Several strata of one stratification under one column heading.
#
# The study writes these tables once per stratum and checks that the strata
# partition the line, so a column mapped to two of them is the two counts
# added - exactly, not approximately. Only counts: a rate is not the sum of its
# strata's rates and an interval is not the sum of theirs, so a rate over more
# than one stratum is refused rather than invented.
#
# A suppressed row arrives with its count NULL, and the sum of an unknown is
# unknown: the cell then has no denominator and is withheld, which is the safe
# way round.
TFLS_SOC_SUMMABLE <- c("N_PATIENTS", "N_EVENTS", "N_AT_RISK", "N_DENOM",
                       "N_REMAINING", "PERSON_YEARS")

# The columns that say WHICH stratum a row is. Everything else is a value, and
# values are expected to differ between categories.
TFLS_STRATUM_KEYS <- c("COHORT", "LOT_NUM", "PERIOD", "CONDITION", "MEASURE",
                       "CATEGORY", "OUTCOME", "DOMAIN", "ACUTE_CHRONIC")

# The subgroup a shell column names may be the protocol's age grouping, which
# the rate tables carry as a column of their own and the per-patient tables
# carry beside the descriptive bands. Either way the string is the same, so a
# column reads the same group whichever table answers it.

collapse_strata <- function(d, stat) {
  if (is.null(d) || nrow(d) < 2L || !stat %in% c("n_pct", "n")) return(d)
  for (nm in names(TFLS_STRATUM_TOTALS)) {
    cl <- col_of(d, nm)
    if (is.na(cl)) next
    v <- chr(d[[cl]])
    # One row per stratum of one cell, and none of them the total, or this is
    # not a partition to add up.
    if (anyDuplicated(v) ||
        any(soc_key(v) %in% soc_key(TFLS_STRATUM_TOTALS[[nm]]))) next
    rest <- setdiff(intersect(c(TFLS_STRATUM_KEYS, names(TFLS_STRATUM_TOTALS)),
                              names(d)), nm)
    if (any(vapply(rest, function(k) length(unique(chr(d[[k]]))) > 1L,
                   logical(1)))) next
    out <- d[1, , drop = FALSE]
    for (vc in intersect(TFLS_SOC_SUMMABLE, names(d)))
      out[[vc]] <- sum(suppressWarnings(as.numeric(d[[vc]])), na.rm = FALSE)
    out[[cl]] <- paste(v, collapse = " + ")
    return(out)
  }
  d
}

# --- one cell ---------------------------------------------------------------

TFLS_NUMERATOR_COLUMNS <- c("N_PATIENTS", "N_REMAINING", "N_EVENTS", "N")
TFLS_DENOMINATOR_COLUMNS <- c("N_DENOM", "N_AT_RISK", "N_POPULATION")

num_col_value <- function(d, names_wanted) {
  for (cl in names_wanted) {
    hit <- col_of(d, cl)
    if (is.na(hit)) next
    v <- suppressWarnings(as.numeric(d[[hit]]))
    if (any(!is.na(v))) return(list(name = hit, value = v))
  }
  NULL
}

# The month a km_prob row is read at: the shell's filter, e.g. MONTHS=12.
months_from_filter <- function(terms) {
  for (t in terms)
    if (identical(toupper(t$column), "MONTHS") && length(t$value))
      return(suppressWarnings(as.numeric(t$value[1])))
  NA_real_
}

# The time and event columns behind a curve. A measure of OS means OS_MONTHS
# and OS_EVENT, which is how the study package writes them; a measure naming
# the months column directly is read the same way.
km_time_name <- function(measure) {
  base <- chr(measure$column)
  if (!nzchar(base)) return("")
  if (grepl("_MONTHS$", toupper(base))) base else paste0(base, "_MONTHS")
}
km_columns <- function(d, measure) {
  tcol <- km_time_name(measure)
  if (!nzchar(tcol)) return(NULL)
  ecol <- sub("_MONTHS$", "_EVENT", toupper(tcol))
  t <- col_of(d, tcol); e <- col_of(d, ecol)
  list(time = t, event = e, want_time = tcol, want_event = ecol)
}

# TTE_ELIGIBLE is a flag on every row of the time-to-event table, not a filter.
# The study writes the whole cohort and leaves the restriction to the reader,
# so a curve is over every row unless someone asked otherwise - a row's own
# filter saying TTE_ELIGIBLE=1, which prints in the shell, or the run being set
# to apply it, which prints in the caption. Applying it quietly would move
# every median in the table with nothing on the page to say so.
km_analysis_rows <- function(d, eligible_only = FALSE) {
  if (!isTRUE(eligible_only)) return(d)
  cl <- col_of(d, "TTE_ELIGIBLE")
  if (is.na(cl)) return(d)
  d[as_int(d[[cl]]) %in% 1L, , drop = FALSE]
}

# One cell: the statistic the row asks for, over the population the column
# names. Returns a stat_cell(), refused with a reason where it cannot be made.
compute_cell <- function(pop, stat, measure, terms, where,
                         eligible_only = FALSE) {
  if (!nrow(pop)) return(stat_refused(stat, paste0("no rows of ", where,
    " are in this column's population"), "not_in_run"))
  per_patient <- has_col(pop, "PATID")
  denom <- population_denom(pop)

  if (stat %in% TFLS_KM_STATS) {
    k <- km_columns(pop, measure)
    if (is.null(k))
      return(stat_refused(stat, "the shell names no endpoint for the curve",
                          "shell"))
    if (is.na(k$time) || is.na(k$event))
      return(stat_refused(stat, paste0(where, " carries no ", k$want_time,
                                       " and ", k$want_event), "not_in_run"))
    rows <- km_analysis_rows(pop, eligible_only)
    if (!nrow(rows))
      return(stat_refused(stat, paste0("nothing in ", where,
        " is left in this column's population for a curve"), "not_in_run"))
    tt <- suppressWarnings(as.numeric(rows[[k$time]]))
    ev <- as_int(rows[[k$event]])
    d <- population_denom(rows)
    return(switch(stat,
      km_median = stat_km_median(tt, ev, denom = d),
      km_events = stat_km_events(tt, ev, denom = d),
      km_censored = stat_km_censored(tt, ev, denom = d),
      km_prob = {
        m <- months_from_filter(terms)
        if (is.na(m))
          stat_refused(stat, paste0("km_prob needs a month: add MONTHS= to ",
                                    "the row's filter"), "shell")
        else stat_km_prob(tt, ev, m, denom = d)
      }))
  }

  # The measure picks the numerator out of the population. On a per-patient
  # table it is a value of a column; on an aggregated table it picks the row
  # the study package already counted.
  mcol <- if (nzchar(measure$column)) col_of(pop, measure$column) else NA_character_
  if (nzchar(measure$column) && is.na(mcol))
    return(stat_refused(stat, paste0(measure$column, " is not a column of ",
                                     where), "not_in_run"))

  if (per_patient) {
    if (stat %in% c("n_pct", "n")) {
      if (!nzchar(measure$column))
        return(if (identical(stat, "n_pct"))
                 stat_n_pct(denom, denom = denom) else stat_n(denom, denom = denom))
      sel <- apply_term(pop, measure, where)
      if (!isTRUE(sel$ok)) return(stat_refused(stat, sel$why))
      # A measure naming a value counts the patients holding it; a measure
      # naming only a column counts the patients the column says anything about.
      hit <- if (length(measure$value)) population_denom(sel$rows)
             else population_denom(pop[nzchar(chr(pop[[mcol]])), , drop = FALSE])
      return(if (identical(stat, "n_pct")) stat_n_pct(hit, denom = denom)
             else stat_n(hit, denom = denom))
    }
    if (identical(stat, "n_distinct")) {
      if (is.na(mcol))
        return(stat_refused(stat, paste0("the shell names no column to count ",
                                         "the distinct values of"), "shell"))
      # A measure naming a value narrows the rows first, so a row asking for
      # the regimens inside one category counts those and not all of them.
      sel <- apply_term(pop, measure, where)
      if (!isTRUE(sel$ok)) return(stat_refused(stat, sel$why))
      return(stat_n_distinct(sel$rows[[mcol]], denom = denom))
    }
    if (stat %in% TFLS_VALUE_STATS) {
      if (is.na(mcol))
        return(stat_refused(stat, "the shell names no column to summarise",
                            "shell"))
      # The identifier guard reads column NAMES, and these print a column's
      # VALUES: min_max of PATID over thirty patients was two patients' ids
      # in LOW, HIGH and the text. A shell that got past the load is refused
      # here the same way.
      if (is_identifier_column(measure$column))
        return(stat_refused(stat, paste0(measure$column, " is an identifier, ",
          "and a ", stat, " would print identifiers; count the patients ",
          "instead"), "shell"))
      # A per-patient summary is of the column as it is. A comparison in the
      # measure - AGE_YEARS>=75 - was dropped, and the mean of every age
      # printed under a heading that says 75 and over. The restriction belongs
      # in the row's filter, which is applied. (An aggregate table's measure
      # is a facet, MEASURE=ED_VISIT, and is read further down.)
      if (nzchar(chr(measure$op)))
        return(stat_refused(stat, paste0("'", measure$raw, "' compares ",
          measure$column, ", and a ", stat, " summarises a column as it is: ",
          "put the comparison in the row's filter and name the column alone"),
          "shell"))
      x <- suppressWarnings(as.numeric(pop[[mcol]]))
      if (all(is.na(x)))
        return(stat_refused(stat, paste0(mcol, " in ", where,
                                         " holds no numbers"), "not_in_run"))
      return(switch(stat,
        mean_sd = stat_mean_sd(x, denom = denom),
        median_iqr = stat_median_iqr(x, denom = denom),
        min_max = stat_min_max(x, denom = denom)))
    }
    if (identical(stat, "rate"))
      return(stat_refused(stat, paste0(where,
        " is per patient and carries no rate; a rate is read from the table ",
        "the package computed it in"), "not_computable"))
  }

  # A distinct count needs the values themselves, and a stratum table holds one
  # row per group the package already counted: the values in it are the groups
  # it wrote rather than what this population holds.
  if (identical(stat, "n_distinct"))
    return(stat_refused(stat, paste0(where, " is a table of totals, so the ",
      "distinct values in it are the strata the package wrote and not the ",
      "values this population holds"), "not_computable"))

  # Aggregated: one row of a stratum table is the answer, so the shell has to
  # pick exactly one. Two rows left is a shell that needs another filter, and
  # averaging them would average strata.
  sel <- if (nzchar(measure$column)) apply_term(pop, measure, where)
         else list(ok = TRUE, rows = pop)
  if (!isTRUE(sel$ok)) return(stat_refused(stat, sel$why))
  d <- sel$rows
  if (!nrow(d))
    return(stat_refused(stat, paste0("no row of ", where, " matches ",
                                     measure$raw), "not_in_run"))
  d <- collapse_strata(d, stat)
  if (nrow(d) > 1L) {
    if (identical(stat, "rate") &&
        any(vapply(names(TFLS_STRATUM_TOTALS),
                   function(nm) !is.na(col_of(d, nm)), logical(1))))
      return(stat_refused(stat, paste0("this column covers ", nrow(d),
        " of the study's strata and ", where, " carries a rate for each; a ",
        "rate is not the sum of theirs, so the package would have to publish ",
        "the group"), "not_computable"))
    return(stat_refused(stat, paste0(nrow(d), " rows of ", where,
      " match this column and measure; the shell needs a filter that picks one"),
      "shell"))
  }
  if (identical(stat, "rate")) {
    r <- num_col_value(d, "RATE")
    ev <- num_col_value(d, c("N_EVENTS", "N_PATIENTS"))
    py <- num_col_value(d, "PERSON_YEARS")
    dn <- num_col_value(d, TFLS_DENOMINATOR_COLUMNS)
    return(stat_rate(rate = if (is.null(r)) NA else r$value[1],
                     events = if (is.null(ev)) NA else ev$value[1],
                     person_years = if (is.null(py)) NA else py$value[1],
                     denom = if (is.null(dn)) denom else dn$value[1],
                     low = num_col_value(d, "RATE_LO")$value[1],
                     high = num_col_value(d, "RATE_HI")$value[1]))
  }
  if (stat %in% c("n_pct", "n")) {
    nm <- num_col_value(d, TFLS_NUMERATOR_COLUMNS)
    if (is.null(nm))
      return(stat_refused(stat, paste0(where, " carries no count column"),
                          "not_in_run"))
    dn <- num_col_value(d, TFLS_DENOMINATOR_COLUMNS)
    dv <- if (!is.null(dn)) dn$value[1] else {
      # A funnel carries no denominator: the population it is out of is the
      # step it started from, which is the largest count in the column.
      start <- num_col_value(pop, "N_REMAINING")
      if (!is.null(start)) max(start$value, na.rm = TRUE) else nm$value[1]
    }
    return(if (identical(stat, "n_pct")) stat_n_pct(nm$value[1], denom = dv)
           else stat_n(nm$value[1], denom = dv))
  }
  stat_refused(stat, paste0(stat, " needs per-patient values, and ", where,
                            " is a table of totals"), "not_computable")
}

# --- one table --------------------------------------------------------------

empty_cells <- function() data.frame(
  TABLE_ID = character(0), ROW_ORDER = integer(0), ROW_LABEL = character(0),
  INDENT = integer(0), SECTION = integer(0), SECTION_LABEL = character(0),
  NOTE = character(0), STAT = character(0), SOURCE = character(0),
  MEASURE = character(0), COLUMN_ORDER = integer(0), COLUMN_ID = character(0),
  COLUMN_LABEL = character(0), COLUMN_GROUP = character(0),
  VALUE = numeric(0), LOW = numeric(0), HIGH = numeric(0), N = numeric(0),
  DENOM = numeric(0), TEXT = character(0), FILLED = integer(0),
  SUPPRESSED = integer(0), REASON = character(0), REASON_KIND = character(0),
  ROW_KEY = character(0), POP_N = numeric(0), CURVE_KEY = character(0),
  stringsAsFactors = FALSE)

# What a row reads, as the fill reads it rather than as the shell spells it.
#
# Two keys come out, and the disclosure rules turn on both. ROW_KEY says two
# cells in different tables read the same thing over different populations -
# T5c's age columns and T4's Overall - so a split in one table can be closed
# against its total in the other. CURVE_KEY says which curve a curve's row is
# read off, so a curve's events, censored, median and probabilities are
# withheld together. Keyed on the text as written, one curve spelled two ways
# was two curves and one row two rows, closed apart - and a withheld group
# came back as the total less the published rest.
#
# So both are built from the terms the fill itself applies, after the class
# translation. The table name and a column name match whatever their case
# (fill_context(), col_of()); a curve's endpoint is the months column
# km_columns() resolves, so TTNT and TTNT_MONTHS are one curve; a filter is its
# terms in any order and spacing. A value compared with = or != is compared as
# text, case and all (apply_term()), so it is kept as written; a number
# compared with < or >=, and the month a probability is read at, are numbers.
# A term with nothing to compare restricts nothing and is left out. The run's
# own TTE_ELIGIBLE switch selects what a curve's TTE_ELIGIBLE=1 does, and is
# keyed the same. The row key keeps the statistic and the month, so different
# outputs stay apart; the curve key drops both.
shell_term_key <- function(t) {
  col <- toupper(chr(t$column))
  if (!isTRUE(t$ok)) return(paste0("?", chr(t$raw)))
  if (!nzchar(chr(t$op)) || !length(t$value)) return("")
  v <- chr(t$value)
  if (!t$op %in% c("=", "!=") || identical(col, "MONTHS")) {
    y <- suppressWarnings(as.numeric(v[1]))
    v <- if (is.na(y)) v[1] else format(y, digits = 15)
  }
  paste0(col, t$op, paste(sort(unique(v), method = "radix"), collapse = "|"))
}

row_keys <- function(stat, source, measure, terms, eligible_only = FALSE) {
  stat <- chr(stat)
  curve <- stat %in% TFLS_CURVE_STATS
  what <- if (curve) toupper(km_time_name(measure))
          else if (nzchar(chr(measure$op))) shell_term_key(measure)
          else toupper(chr(measure$column))
  keys <- function(ts) {
    k <- vapply(ts, shell_term_key, character(1))
    if (curve && isTRUE(eligible_only)) k <- c(k, "TTE_ELIGIBLE=1")
    paste(sort(unique(k[nzchar(k)]), method = "radix"), collapse = "&")
  }
  not_month <- Filter(function(t) !identical(toupper(chr(t$column)), "MONTHS"),
                      terms)
  src <- toupper(chr(source))
  list(row = paste(stat, src, what, keys(terms), sep = "\r"),
       curve = if (curve) paste(src, what, keys(not_month), sep = "\r") else "")
}

# The same two, off a shell row as written, for a caller holding no parsed
# terms.
curve_key <- function(row, eligible_only = FALSE)
  row_keys(row$stat, row$source, parse_measure(row$measure),
           parse_filter(row$filter), eligible_only)$curve
row_key <- function(row, eligible_only = FALSE)
  row_keys(row$stat, row$source, parse_measure(row$measure),
           parse_filter(row$filter), eligible_only)$row

# The cells of a table as one frame, built a column at a time: one small data
# frame per cell, bound together, was most of the time a whole fill took.
cells_frame <- function(cells) {
  if (!length(cells)) return(empty_cells())
  nm <- names(empty_cells())
  out <- lapply(nm, function(f) {
    v <- lapply(cells, `[[`, f)
    if (any(lengths(v) != 1L))
      stop("a filled cell carries no single value for ", f, call. = FALSE)
    unlist(v, use.names = FALSE)
  })
  names(out) <- nm
  as.data.frame(out, stringsAsFactors = FALSE)
}

empty_unfilled <- function() data.frame(
  TABLE_ID = character(0), ROW_ORDER = integer(0), ROW_LABEL = character(0),
  COLUMN_ID = character(0), COLUMN_LABEL = character(0), STAT = character(0),
  SOURCE = character(0), MEASURE = character(0), REASON_KIND = character(0),
  REASON = character(0), stringsAsFactors = FALSE)

unfilled_row <- function(tid, row, column_id, column_label, kind, why)
  data.frame(TABLE_ID = tid, ROW_ORDER = row$order_n,
             ROW_LABEL = chr(row$label), COLUMN_ID = column_id,
             COLUMN_LABEL = column_label, STAT = chr(row$stat),
             SOURCE = chr(row$source), MEASURE = chr(row$measure),
             REASON_KIND = kind, REASON = why, stringsAsFactors = FALSE)

# What the study's own construction means for a row, which the table has to
# carry rather than leave a reader to assume. Neither of the first two is this
# code's to fix.
fill_note <- function(row, spec, ctx) {
  out <- character(0)
  src <- toupper(chr(row$source))
  when <- toupper(paste(chr(spec$period), chr(row$filter)))
  if (identical(chr(row$stat), "rate") && grepl("BASELINE", when, fixed = TRUE))
    out <- c(out, paste0("Baseline person-time is a fixed window length ",
      "rather than observed enrolment, so a baseline rate has the window as ",
      "its denominator and not time at risk."))
  if (identical(src, "S_MALIGNANCY_RATES"))
    out <- c(out, paste0("Malignancy rates are written for the treatment ",
      "period on these cohorts, so a column asking for another period is ",
      "reported unfilled rather than as a zero."))
  if (chr(row$stat) %in% TFLS_KM_STATS)
    out <- c(out, if (isTRUE(ctx$tte_eligible_only))
      "Curves are over TTE_ELIGIBLE = 1 only, which this run was set to apply."
      else paste0("Curves are over every row of the time-to-event table: ",
        "TTE_ELIGIBLE is a flag the study leaves to the reader, and it was ",
        "applied only where a row's own filter names it."))
  out
}

# What a row would read, in words, for the plan.
row_reads_label <- function(row) {
  if (isTRUE(row$section_flag)) return("a heading")
  if (blank(row$source)) return("nothing: the shell names no source table")
  paste0(chr(row$source),
         if (blank(row$measure)) "" else paste0(" / ", chr(row$measure)),
         if (blank(row$filter)) "" else paste0(" / ", chr(row$filter)),
         " / ", chr(row$stat))
}

# One table, filled and suppressed.
fill_table <- function(sh, tid, ctx, floor_n = TFLS_PACKAGE_MIN_N) {
  cols <- shell_columns_of(sh, tid)
  rows <- shell_rows_of(sh, tid)
  pops <- new.env(parent = emptyenv())
  cells <- list(); unfilled <- list(); notes <- character(0)
  section_label <- ""
  for (ri in seq_len(nrow(rows))) {
    row <- rows[ri, , drop = FALSE]
    if (isTRUE(row$section_flag)) section_label <- chr(row$label)
    measure <- parse_measure(row$measure)
    terms <- parse_filter(row$filter)
    class_why <- ""
    tr <- translate_class_term(measure, ctx)
    if (isTRUE(tr$ok)) measure <- tr$term else class_why <- tr$why
    terms <- lapply(terms, function(t) {
      r <- translate_class_term(t, ctx)
      if (isTRUE(r$ok)) r$term else { class_why <<- r$why; t }
    })
    # What the row reads, once for every column it is filled in.
    keys <- row_keys(row$stat, row$source, measure, terms, ctx$tte_eligible_only)
    # Read once per row, not once per cell.
    d <- if (blank(row$source)) NULL else ctx$get(row$source)
    row_why <- ""; row_kind <- ""
    if (!isTRUE(row$section_flag)) {
      if (blank(row$stat)) {
        row_why <- "the shell names no statistic for this row"
        row_kind <- "shell"
      } else if (blank(row$source)) {
        row_why <- "the shell names no source table"
        row_kind <- "shell"
      } else if (is.null(d) || !nrow(d)) {
        # Why it is absent, where the reader can say: a table this run's own
        # metadata does not claim is a previous run's, and saying so names the
        # declaration the row was read against.
        scoped <- if (is.function(ctx$absent_why))
          ctx$absent_why(row$source) else ""
        row_why <- if (nzchar(scoped)) scoped
          else if (toupper(chr(row$source)) %in% TFLS_COHORT_TABLE_NAMES)
            paste0("the input cohort table is the cohort build's, not a study ",
                   "output; in warehouse mode TFLS_COHORT_TABLE names it. The ",
                   "study's diagnosis date and the durations hung on it are on ",
                   "S_PERIODS, which a row can read instead")
          else paste0(chr(row$source), " was not read by this run, so nothing ",
                      "can fill this row")
        row_kind <- "not_in_run"
      } else if (nzchar(measure$column) && !has_col(d, measure$column) &&
                 !chr(row$stat) %in% TFLS_KM_STATS) {
        row_why <- paste0(measure$column, " is not a column of ",
                          chr(row$source))
        row_kind <- "not_in_run"
      } else if (nzchar(class_why)) {
        row_why <- class_why
        row_kind <- "shell"
      }
    }
    if (nzchar(row_why))
      unfilled[[length(unfilled) + 1L]] <-
        unfilled_row(tid, row, "(all)", "(every column)", row_kind, row_why)
    for (ci in seq_len(nrow(cols))) {
      spec <- column_spec(cols[ci, , drop = FALSE])
      if (!isTRUE(row$section_flag) && ci == 1L)
        notes <- unique(c(notes, fill_note(row, spec, ctx)))
      cell <- NULL
      why <- row_why; kind <- row_kind
      # The column's population before this row's own filter narrows it. A row
      # that leaves some of it out leaves out a number a reader can take from
      # any row that does not, and suppress_cells() floors that number.
      pop_n <- NA_real_
      if (!isTRUE(row$section_flag) && !nzchar(why)) {
        # The same column over the same table is the same population for
        # every row that reads it, so it is selected once.
        pk <- paste(toupper(chr(row$source)), ci, sep = "\r")
        pop <- pops[[pk]]
        if (is.null(pop)) {
          pop <- select_population(d, spec, ctx, chr(row$source))
          pops[[pk]] <- pop
        }
        if (!isTRUE(pop$ok)) {
          why <- pop$why; kind <- pop$kind %||% "not_computable"
        } else {
          rows_sel <- pop$rows
          pop_n <- population_denom(rows_sel)
          for (t in terms) {
            # The month a curve is read at is not a restriction on the table.
            if (identical(toupper(t$column), "MONTHS")) next
            r <- apply_term(rows_sel, t, chr(row$source))
            if (!isTRUE(r$ok)) {
              why <- r$why; kind <- r$kind %||% "not_computable"; break
            }
            rows_sel <- r$rows
          }
          if (!nzchar(why)) {
            cell <- compute_cell(rows_sel, chr(row$stat), measure, terms,
                                 chr(row$source), ctx$tte_eligible_only)
            if (!isTRUE(cell$ok)) {
              why <- cell$why
              kind <- if (nzchar(chr(cell$kind))) cell$kind else "not_computable"
              cell <- NULL
            }
          }
        }
        if (nzchar(why) && !nzchar(row_why))
          unfilled[[length(unfilled) + 1L]] <-
            unfilled_row(tid, row, spec$id, spec$label, kind, why)
      }
      is_section <- isTRUE(row$section_flag)
      cells[[length(cells) + 1L]] <- list(
        TABLE_ID = tid, ROW_ORDER = row$order_n, ROW_LABEL = chr(row$label),
        INDENT = row$indent_n, SECTION = as.integer(is_section),
        SECTION_LABEL = if (is_section) chr(row$label) else section_label,
        NOTE = chr(row$note), STAT = chr(row$stat), SOURCE = chr(row$source),
        MEASURE = chr(row$measure), COLUMN_ORDER = spec$order,
        COLUMN_ID = spec$id, COLUMN_LABEL = spec$label,
        COLUMN_GROUP = spec$group,
        VALUE = if (is.null(cell)) NA_real_ else cell$value,
        LOW = if (is.null(cell)) NA_real_ else cell$low,
        HIGH = if (is.null(cell)) NA_real_ else cell$high,
        N = if (is.null(cell)) NA_real_ else cell$n,
        DENOM = if (is.null(cell)) NA_real_ else cell$denom,
        TEXT = if (is.null(cell)) "" else cell$text,
        FILLED = as.integer(!is.null(cell)),
        SUPPRESSED = 0L,
        REASON = if (is.null(cell)) why else "",
        REASON_KIND = if (is.null(cell)) kind else "",
        # What the row reads, so the same measure over another population can
        # be found in another table: T5c's rows are T4's, over a subgroup.
        ROW_KEY = keys$row,
        POP_N = if (is.null(cell)) NA_real_ else pop_n,
        CURVE_KEY = keys$curve)
    }
  }
  out <- cells_frame(cells)
  # The shell goes with the cells: the sums a withheld cell could be read
  # off - a subtotal down a column, a total across a row - are drawn by the
  # shell's own indentation and columns.
  out <- suppress_cells(out, floor_n, sh)
  # A cell nothing could fill says so, rather than printing as an empty string
  # a reader could take for a zero.
  blankable <- out$FILLED == 0L & out$SECTION == 0L
  out$TEXT[blankable] <- "not filled"
  list(table_id = tid, cells = out, floor_n = floor_n, notes = notes,
       unfilled = if (length(unfilled)) do.call(rbind, unfilled)
                  else empty_unfilled())
}

# Every table in the shell.
# Each table is closed on its own as it is filled; then all of them together,
# because a population can be split in one table and totalled in another.
fill_all <- function(sh, ctx, floor_n = TFLS_PACKAGE_MIN_N) {
  # Every pass over these tables closes the same splits, so they are worked
  # out once, for this shell as it is now (suppress.R, split_plan()).
  if (exists("split_plan", mode = "function")) sh$split_plan <- split_plan(sh)
  out <- lapply(shell_table_ids(sh), function(tid) fill_table(sh, tid, ctx, floor_n))
  names(out) <- shell_table_ids(sh)
  suppress_across_tables(out, sh, floor_n)
}

all_unfilled <- function(filled) {
  u <- lapply(filled, `[[`, "unfilled")
  u <- Filter(function(x) !is.null(x) && nrow(x), u)
  if (!length(u)) return(empty_unfilled())
  out <- do.call(rbind, u)
  rownames(out) <- NULL
  out
}
