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
      x <- suppressWarnings(as.numeric(v))
      y <- suppressWarnings(as.numeric(term$value))[1]
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
select_population <- function(d, spec, ctx, where) {
  keys <- list(COHORT = spec$cohort, LOT_NUM = spec$line, PERIOD = spec$period)
  for (k in names(keys)) {
    v <- keys[[k]]
    if (!nzchar(v)) next
    cl <- col_of(d, k)
    if (!is.na(cl)) {
      d <- d[chr(d[[cl]]) %in% chr(strsplit(v, "|", fixed = TRUE)[[1]]), ,
             drop = FALSE]
      next
    }
    # A line can still be carried, where the table is per patient and the
    # study's per-line tables say which patients have that line.
    if (identical(k, "LOT_NUM") && has_col(d, "PATID")) {
      ids <- line_patients(ctx, line = v, cohort = spec$cohort)
      if (!is.null(ids)) {
        d <- d[chr(d[[col_of(d, "PATID")]]) %in% ids, , drop = FALSE]
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
line_patients <- function(ctx, line = "", cohort = "") {
  ids <- soc_patients(ctx, line = line, cohort = cohort)
  if (!is.null(ids)) return(ids)
  lp <- ctx$get("S_LOT_PERIODS")
  if (is.null(lp) || !nrow(lp) || !has_col(lp, "PATID") || !has_col(lp, "LOT_NUM"))
    return(NULL)
  if (nzchar(chr(line))) {
    want <- as_int(strsplit(chr(line), "|", fixed = TRUE)[[1]])
    lp <- lp[as_int(lp[[col_of(lp, "LOT_NUM")]]) %in% want, , drop = FALSE]
  }
  if (nzchar(chr(cohort)) && has_col(lp, "COHORT")) {
    want <- chr(strsplit(chr(cohort), "|", fixed = TRUE)[[1]])
    lp <- lp[chr(lp[[col_of(lp, "COHORT")]]) %in% want, , drop = FALSE]
  }
  if (has_col(lp, "PERIOD_START") && has_col(lp, "PERIOD_END")) {
    st <- suppressWarnings(as.Date(lp[[col_of(lp, "PERIOD_START")]]))
    en <- suppressWarnings(as.Date(lp[[col_of(lp, "PERIOD_END")]]))
    lp <- lp[!is.na(st) & !is.na(en) & en >= st, , drop = FALSE]
  }
  patients_of(lp)
}

# The patients of one line, and optionally of one regimen class, off the
# study's own per-line categorisation. NULL where that table was not read,
# which the caller reports rather than filling around.
soc_patients <- function(ctx, line = "", cohort = "", categories = NULL,
                         drug = "") {
  s <- ctx$get(ctx$soc_table)
  if (is.null(s) || !nrow(s) || !has_col(s, "PATID") || !has_col(s, "LOT_NUM"))
    return(NULL)
  if (nzchar(chr(line))) {
    want <- as_int(strsplit(chr(line), "|", fixed = TRUE)[[1]])
    s <- s[as_int(s[[col_of(s, "LOT_NUM")]]) %in% want, , drop = FALSE]
  }
  # A patient sits in several nested cohorts with a different index date in
  # each, so the cohort narrows the lines as well as the patients.
  if (nzchar(chr(cohort)) && has_col(s, "COHORT")) {
    want <- chr(strsplit(chr(cohort), "|", fixed = TRUE)[[1]])
    s <- s[chr(s[[col_of(s, "COHORT")]]) %in% want, , drop = FALSE]
  }
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
  patients_of(s)
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
  ids <- soc_patients(ctx, line = spec$line, cohort = spec$cohort,
                      categories = cats, drug = sel$drug)
  if (is.null(ids))
    return(refuse(paste0(ctx$soc_table, " was not read by this run, so the ",
                         "study's regimen class for a line is not available"),
                  "not_in_run"))
  list(ok = TRUE, rows = d[chr(d[[col_of(d, "PATID")]]) %in% ids, , drop = FALSE])
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

subgroup_band <- function(value) {
  v <- toupper(gsub("[[:space:]]", "", chr(value)))
  for (nm in names(TFLS_AGE_BANDS)) if (v %in% TFLS_AGE_BANDS[[nm]]) return(nm)
  ""
}

# The patients a named subgroup holds, within the column's cohort.
named_subgroup_patients <- function(name, value, ctx, cohort) {
  def <- TFLS_SUBGROUPS[[toupper(chr(name))]]
  if (is.null(def)) return(NULL)
  s <- ctx$get(def$table)
  if (is.null(s) || !nrow(s) || !has_col(s, "PATID")) return(list(ok = FALSE,
    why = paste0(def$table, " was not read by this run, so the subgroup ",
                 toupper(chr(name)), " (", def$what, ") cannot be applied")))
  if (nzchar(chr(cohort)) && has_col(s, "COHORT"))
    s <- s[chr(s[[col_of(s, "COHORT")]]) %in%
             chr(strsplit(chr(cohort), "|", fixed = TRUE)[[1]]), , drop = FALSE]
  if (!is.null(def$concept)) {
    cc <- col_of(s, def$concept_col)
    if (is.na(cc)) return(list(ok = FALSE, why = paste0(
      def$table, " carries no ", def$concept_col, ", so ", def$what,
      " cannot be read from it")))
    s <- s[toupper(chr(s[[cc]])) == toupper(def$concept), , drop = FALSE]
    if (!nrow(s)) return(list(ok = FALSE, why = paste0(
      def$table, " holds no '", def$concept, "' rows, so ", def$what,
      " was not computed by this run")))
  }
  if (!is.null(def$bands)) {
    band <- subgroup_band(value)
    if (!nzchar(band)) return(list(ok = FALSE, why = paste0(
      "'", chr(value), "' is not one of ", paste(names(def$bands), collapse = ", "),
      " for the ", toupper(chr(name)), " subgroup")))
    cl <- col_of(s, def$column)
    if (is.na(cl)) return(list(ok = FALSE, why = paste0(
      def$table, " carries no ", def$column, ", so ", def$what,
      " cannot be read from it")))
    x <- suppressWarnings(as.numeric(s[[cl]]))
    b <- def$bands[[band]]
    keep <- !is.na(x) & if (identical(b$op, "<")) x < b$cut else x >= b$cut
    return(list(ok = TRUE, ids = patients_of(s[keep, , drop = FALSE])))
  }
  v <- toupper(chr(value))
  want <- if (v %in% TFLS_SUBGROUP_YES) 1L else if (v %in% TFLS_SUBGROUP_NO) 0L
          else return(list(ok = FALSE, why = paste0(
            "'", chr(value), "' is not YES or NO for the ", toupper(chr(name)),
            " subgroup")))
  fl <- col_of(s, def$flag)
  if (is.na(fl)) return(list(ok = FALSE, why = paste0(
    def$table, " carries no ", def$flag, ", so ", def$what,
    " cannot be read from it")))
  list(ok = TRUE, ids = patients_of(s[as_int(s[[fl]]) %in% want, , drop = FALSE]))
}

# A subgroup is a value of a column. Where the table itself carries the column
# the restriction is a filter; where it does not, the column is looked for on
# the per-patient tables, and the subgroup becomes the set of patients holding
# that value.
restrict_to_subgroup <- function(d, subgroup, ctx, where, cohort = "") {
  sg <- parse_subgroup(subgroup)
  if (!isTRUE(sg$ok))
    return(refuse(paste0("the subgroup '", subgroup, "' cannot be read: ",
                         sg$why), "shell"))
  if (!length(sg$terms)) return(list(ok = TRUE, rows = d))
  # The column says which table the subgroup is on, because a neuropathy flag
  # and the interval a malignancy fell in are on different tables and neither
  # is on the table being summarised.
  if (nzchar(sg$table)) {
    # Where the table being summarised carries the column itself, the
    # restriction is a filter on it and no patient is needed. That is how a
    # rate table stratified by age answers an age column.
    if (all(vapply(sg$terms, function(t) has_col(d, t$column), logical(1)))) {
      for (t in sg$terms) {
        r <- apply_term(d, t, where)
        if (!isTRUE(r$ok)) return(r)
        d <- r$rows
      }
      return(list(ok = TRUE, rows = d))
    }
    s <- ctx$get(sg$table)
    if (is.null(s) || !nrow(s))
      return(refuse(paste0(sg$table, " was not read by this run, so the ",
                           "subgroup ", subgroup, " cannot be applied"),
                    "not_in_run"))
    if (nzchar(chr(cohort)) && has_col(s, "COHORT"))
      s <- s[chr(s[[col_of(s, "COHORT")]]) %in%
               chr(strsplit(chr(cohort), "|", fixed = TRUE)[[1]]), , drop = FALSE]
    for (t in sg$terms) {
      r <- apply_term(s, t, sg$table)
      if (!isTRUE(r$ok)) return(r)
      s <- r$rows
    }
    if (!nrow(s))
      return(refuse(paste0("no row of ", sg$table, " meets ", subgroup,
        ", so this subgroup holds nobody in this run"), "not_in_run"))
    return(subgroup_keep_ids(d, patients_of(s), subgroup, where))
  }
  # Unqualified, every term applies - only the first did, so
  # AGE_GROUP=<75&SEX=Male was every patient under 75 and its reverse every
  # man - and each finds its own table. A subgroup the study names is read off
  # its own table; a column of the table being summarised filters its rows.
  rest <- list()
  for (t in sg$terms) {
    named <- named_subgroup_patients(t$column, paste(t$value, collapse = "|"),
                                     ctx, cohort)
    r <- if (!is.null(named) && isTRUE(named$ok))
           subgroup_keep_ids(d, named$ids, subgroup, where)
         else if (has_col(d, t$column)) apply_term(d, t, where)
         else if (!is.null(named)) refuse(named$why, "not_in_run")
         else NULL
    if (is.null(r)) { rest[[length(rest) + 1L]] <- t; next }
    if (!isTRUE(r$ok)) return(r)
    d <- r$rows
  }
  if (!length(rest)) return(list(ok = TRUE, rows = d))
  if (!has_col(d, "PATID"))
    return(refuse(paste0(where, " carries neither ",
                         paste(vapply(rest, function(t) chr(t$column), ""),
                               collapse = " nor "),
                         " nor a patient, so the subgroup ", subgroup,
                         " cannot be applied to it"), "not_computable"))
  # The rest are read off the subject tables, and two things hold there that
  # a patient id alone loses. The terms a table carries are applied TOGETHER,
  # to its rows, before any patient is taken: S_COMORB_SUBGROUP has a row per
  # patient and concept, and CONCEPT=neuropathy on one row with HAS_HISTORY=1
  # on another is not a history of neuropathy. And the rows are this column's
  # cohort's: demographics are taken at each cohort's own index, so a patient
  # under 75 at 1L and 75+ at 2L is not under 75 in the 2L column. So the
  # table carrying the most of what is left is read first, for this cohort.
  cohorts <- chr(strsplit(chr(cohort), "|", fixed = TRUE)[[1]])
  while (length(rest)) {
    best <- ""; most <- 0L
    for (tb in ctx$subject_tables) {
      s <- ctx$get(tb)
      if (is.null(s) || !nrow(s) || !has_col(s, "PATID")) next
      k <- sum(vapply(rest, function(t) has_col(s, t$column), logical(1)))
      if (k > most) { best <- tb; most <- k }
    }
    if (!most)
      return(refuse(paste0("no table read by this run carries ",
                           paste(vapply(rest, function(t) chr(t$column), ""),
                                 collapse = " or "),
                           ", so the subgroup ", subgroup, " cannot be applied"),
                    "not_in_run"))
    s <- ctx$get(best)
    if (length(cohorts) && has_col(s, "COHORT"))
      s <- s[chr(s[[col_of(s, "COHORT")]]) %in% cohorts, , drop = FALSE]
    here <- vapply(rest, function(t) has_col(s, t$column), logical(1))
    for (t in rest[here]) {
      r <- apply_term(s, t, best)
      if (!isTRUE(r$ok)) return(r)
      s <- r$rows
    }
    r <- subgroup_keep_ids(d, patients_of(s), subgroup, where)
    if (!isTRUE(r$ok)) return(r)
    d <- r$rows
    rest <- rest[!here]
  }
  list(ok = TRUE, rows = d)
}

# The rows of `d` whose patient is one of `ids`.
subgroup_keep_ids <- function(d, ids, subgroup, where) {
  if (!has_col(d, "PATID"))
    return(refuse(paste0(where, " carries no patient, so the subgroup ",
                         subgroup, " cannot be applied to it"),
                  "not_computable"))
  list(ok = TRUE, rows = d[chr(d[[col_of(d, "PATID")]]) %in% ids, , drop = FALSE])
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
    if (stat %in% c("mean_sd", "median_iqr", "min_max")) {
      if (is.na(mcol))
        return(stat_refused(stat, "the shell names no column to summarise",
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
        pop <- select_population(d, spec, ctx, chr(row$source))
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
      cells[[length(cells) + 1L]] <- data.frame(
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
        CURVE_KEY = keys$curve,
        stringsAsFactors = FALSE)
    }
  }
  out <- if (length(cells)) do.call(rbind, cells) else empty_cells()
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
