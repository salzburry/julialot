# The fixture the package's SQL is executed against, and the answers worked out
# by hand.
#
# Nine patients, sixteen lines. Each one is here for a metric that would
# otherwise read the same on a broken statement as on a working one:
#
#   P1  no melphalan at all - the denominators must not count it
#   P2  a melphalan-only LOT2 a medication started, and melphalan's own cover
#       is what LOT2 ran out on
#   P3  melphalan beside another agent, outlasting it
#   P4  a melphalan-only LOT2 the TRANSPLANT started - conditioning, so it is
#       not melphalan advancing a line
#   P5  melphalan given on the allograft date, in a line whose regimen is
#       blank - invisible to any test on LOT_BASE_MEDS
#   P6  a line melphalan ended as the added medication, and a CAR-T after it
#   P7  the B.2 shape: a second exposure 92 days after the first, outside the
#       previous line's induction window, starting the next line
#   P8  the same shape with another agent starting that day, so it is a B.2
#       line start but not one melphalan alone made
#   P9  melphalan in two consecutive lines, the first episode not flagged
#       discontinued - which is where an unbounded cover join reads the
#       SECOND line's date as the first line's run-out
#
# The dates are all 2020, and every length is inclusive of both ends.
EXEC_SCHEMA <- list(
  final = list(table = "LOT_LONG_FINAL", columns = c(
    PATID = "VARCHAR", LOT_NUM = "INTEGER", LOT_START_DT = "DATE",
    LOT_START_TYPE = "VARCHAR", LOT_BASE_END_DT = "DATE",
    LOT_BASE_END_REASON = "VARCHAR", LOT_BASE_LENGTH = "INTEGER",
    LOT_BASE_MEDS = "VARCHAR", LOT_MED_CNT = "INTEGER",
    LOT_TX_AUTO_FLG = "INTEGER", LOT_BASE_DISCON_DT = "DATE",
    LOT_BASE_1ST_ADD_MED = "VARCHAR")),

  # The second reading, for the patient-by-patient comparison.
  final_b = list(table = "LOT_LONG_FINAL_B", columns = c(
    PATID = "VARCHAR", LOT_NUM = "INTEGER", LOT_START_DT = "DATE",
    LOT_START_TYPE = "VARCHAR", LOT_BASE_END_DT = "DATE",
    LOT_BASE_END_REASON = "VARCHAR", LOT_BASE_LENGTH = "INTEGER",
    LOT_BASE_MEDS = "VARCHAR", LOT_MED_CNT = "INTEGER",
    LOT_TX_AUTO_FLG = "INTEGER", LOT_BASE_DISCON_DT = "DATE",
    LOT_BASE_1ST_ADD_MED = "VARCHAR")),

  map = list(table = "MAP_STACKED", columns = c(
    PATID = "VARCHAR", MAP_MED_TYPE = "VARCHAR", MAP_MED_CLASS = "VARCHAR",
    MAP_START_DT = "DATE", MAP_END_DT = "DATE", MAP_DISCON_FLG = "INTEGER")),

  attrition = list(table = "LOT_ATTRITION", columns = c(
    RUN_ID = "VARCHAR", KIND = "VARCHAR", STEP = "VARCHAR",
    N_PATIENTS = "BIGINT")))

EXEC_TABLES <- stats::setNames(
  lapply(EXEC_SCHEMA, function(x) x$table), names(EXEC_SCHEMA))

.ln <- function(pat, n, start, type, end, reason, len, meds, cnt, auto = 0L,
                discon = NA, add = NA)
  list(PATID = pat, LOT_NUM = n, LOT_START_DT = start, LOT_START_TYPE = type,
       LOT_BASE_END_DT = end, LOT_BASE_END_REASON = reason,
       LOT_BASE_LENGTH = len, LOT_BASE_MEDS = meds, LOT_MED_CNT = cnt,
       LOT_TX_AUTO_FLG = auto, LOT_BASE_DISCON_DT = discon,
       LOT_BASE_1ST_ADD_MED = add)

.mp <- function(pat, med, cls, start, end, discon = 1L)
  list(PATID = pat, MAP_MED_TYPE = med, MAP_MED_CLASS = cls,
       MAP_START_DT = start, MAP_END_DT = end, MAP_DISCON_FLG = discon)

.at <- function(step, n, run = "RUN1", kind = "progression")
  list(RUN_ID = run, KIND = kind, STEP = step, N_PATIENTS = n)

EXEC_LINES <- list(
  .ln("P1", 1L, "2020-01-01", "MED", "2020-06-28", "DISCONTINUATION", 180L, "BORT LEN", 2L, 0L, "2020-06-28"),

  .ln("P2", 1L, "2020-01-01", "MED", "2020-04-09", "DISCONTINUATION", 100L, "BORT LEN", 2L, 0L, "2020-04-09"),
  .ln("P2", 2L, "2020-04-10", "MED", "2020-05-09", "DISCONTINUATION",  30L, "MELP",     1L, 0L, "2020-05-09"),

  .ln("P3", 1L, "2020-01-01", "MED", "2020-08-28", "DISCONTINUATION", 241L, "LEN MELP", 2L, 0L, "2020-08-28"),

  .ln("P4", 1L, "2020-01-01", "MED",      "2020-06-28", "SCT_AUTO",        180L, "BORT LEN", 2L, 1L),
  .ln("P4", 2L, "2020-06-29", "SCT_AUTO", "2020-10-29", "DISCONTINUATION", 123L, "MELP",     1L, 1L, "2020-10-29"),

  .ln("P5", 1L, "2020-01-01", "MED",      "2020-03-31", "SCT_ALLO",  91L, "BORT", 1L, 0L),
  .ln("P5", 2L, "2020-04-01", "SCT_ALLO", "2020-04-01", "STUDY_END",  1L, "",     0L, 0L),

  .ln("P6", 1L, "2020-01-01", "MED", "2020-04-09", "MED_ADD",   100L, "BORT LEN", 2L, 0L, "2020-05-01", "MELP"),
  .ln("P6", 2L, "2020-04-10", "MED", "2020-05-09", "CART_INIT",  30L, "MELP",     1L, 1L),

  .ln("P7", 1L, "2020-01-01", "MED", "2020-07-31", "DISCONTINUATION", 213L, "LEN",  1L, 0L, "2020-07-31"),
  .ln("P7", 2L, "2020-08-01", "MED", "2020-08-30", "DISCONTINUATION",  30L, "MELP", 1L, 0L, "2020-08-30"),

  .ln("P8", 1L, "2020-01-01", "MED", "2020-07-31", "DISCONTINUATION", 213L, "LEN",       1L, 0L, "2020-07-31"),
  .ln("P8", 2L, "2020-08-01", "MED", "2020-09-30", "DISCONTINUATION",  61L, "DARA MELP", 2L, 0L, "2020-09-30"),

  .ln("P9", 1L, "2020-01-01", "MED", "2020-06-28", "DISCONTINUATION", 180L, "LEN MELP", 2L, 0L, "2020-06-28"),
  .ln("P9", 2L, "2020-06-29", "MED", "2020-12-26", "DISCONTINUATION", 181L, "MELP",     1L, 0L, "2020-12-26"))

EXEC_MAP <- list(
  .mp("P1", "BORT", "PI",   "2020-01-01", "2020-06-28"),
  .mp("P1", "LEN",  "IMID", "2020-01-01", "2020-06-28"),

  .mp("P2", "BORT", "PI",   "2020-01-01", "2020-04-09"),
  .mp("P2", "LEN",  "IMID", "2020-01-01", "2020-04-09"),
  .mp("P2", "MELP", "ALKY", "2020-04-10", "2020-05-09"),

  .mp("P3", "LEN",  "IMID", "2020-01-01", "2020-06-28"),
  .mp("P3", "MELP", "ALKY", "2020-02-01", "2020-08-28"),

  .mp("P4", "BORT", "PI",   "2020-01-01", "2020-06-28"),
  .mp("P4", "LEN",  "IMID", "2020-01-01", "2020-06-28"),
  .mp("P4", "MELP", "ALKY", "2020-06-29", "2020-07-28"),

  .mp("P5", "BORT", "PI",   "2020-01-01", "2020-03-31"),
  # On the allograft date, and the allograft line carries no regimen at all.
  .mp("P5", "MELP", "ALKY", "2020-04-01", "2020-04-01", 0L),

  .mp("P6", "BORT", "PI",   "2020-01-01", "2020-05-01"),
  .mp("P6", "LEN",  "IMID", "2020-01-01", "2020-05-01"),
  .mp("P6", "MELP", "ALKY", "2020-04-10", "2020-05-09"),

  .mp("P7", "LEN",  "IMID", "2020-01-01", "2020-07-31"),
  .mp("P7", "MELP", "ALKY", "2020-05-01", "2020-05-01"),
  .mp("P7", "MELP", "ALKY", "2020-08-01", "2020-08-30"),

  .mp("P8", "LEN",  "IMID", "2020-01-01", "2020-07-31"),
  .mp("P8", "MELP", "ALKY", "2020-05-01", "2020-05-01"),
  .mp("P8", "MELP", "ALKY", "2020-08-01", "2020-08-30"),
  .mp("P8", "DARA", "MAB",  "2020-08-01", "2020-09-30"),

  .mp("P9", "LEN",  "IMID", "2020-01-01", "2020-06-28"),
  # Not flagged discontinued: this episode's cover simply ends with the line.
  .mp("P9", "MELP", "ALKY", "2020-02-01", "2020-06-28", 0L),
  .mp("P9", "MELP", "ALKY", "2020-07-01", "2020-12-26"))

# The decoys are the point of the last two rows: another run's numbers, and
# another KIND under this run. A progression figure read without both filters
# picks one of them up.
EXEC_ATTRITION <- list(
  .at("Reached LOT1", 9L), .at("Reached LOT2", 7L), .at("Reached LOT3", 2L),
  .at("Reached LOT2", 999L, run = "RUN2"),
  .at("Reached LOT2", 888L, kind = "cohort"))

# The second reading. P1 is missing from it, P2's LOT2 ends for a different
# reason, and P3 has a line it does not have in the first - one patient for
# each column the comparison reports.
EXEC_LINES_B <- local({
  keep <- Filter(function(l) !identical(l$PATID, "P1"), EXEC_LINES)
  keep <- lapply(keep, function(l) {
    if (identical(l$PATID, "P2") && identical(l$LOT_NUM, 2L))
      l$LOT_BASE_END_REASON <- "MED_ADD"
    l
  })
  c(keep, list(.ln("P3", 2L, "2020-08-29", "MED", "2020-11-26",
                   "DISCONTINUATION", 90L, "POMA", 1L, 0L, "2020-11-26")))
})

EXEC_DATA <- list(final = EXEC_LINES, final_b = EXEC_LINES_B,
                  map = EXEC_MAP, attrition = EXEC_ATTRITION)

# ---- what each statement must return ---------------------------------------
# Worked out by hand from the fixture above. A number here that merely echoes
# what the statement happens to return would test nothing, so each one is
# derived in the comment beside it.
EXEC_EXPECT_METRICS <- list(
  n_patients   = 9,     # every patient with a line
  n_lines      = 16,    # 1+2+1+2+2+2+2+2+2
  median_lines = 2,     # 1,1,2,2,2,2,2,2,2

  # 7 of 9 reach LOT2 and 2 reach LOT3, off LOT_ATTRITION rather than the lines
  pct_reaching_lot2 = 77.78,
  pct_reaching_lot3 = 22.22,

  median_lot1_length = 180,  # 91,100,100,180,180,180,213,213,241
  median_lot1_meds   = 2,    # 1,1,1,2,2,2,2,2,2
  n_lot1_regimens    = 4,    # BORT LEN | LEN MELP | BORT | LEN
  n_cart_init        = 1,    # P6 LOT2
  n_sct_auto_end     = 1,    # P4 LOT1
  n_melp_add         = 1,    # P6 LOT1

  # Every line naming melphalan: P2/P4/P6/P7/P9 LOT2, P3/P9 LOT1, P8 LOT2
  n_melp_lines    = 8,
  n_pat_with_melp = 7,       # P2 P3 P4 P6 P7 P8 P9

  # Melphalan alone: LOT_MED_CNT = 1 and the regimen is exactly MELP
  n_melp_mono_lines    = 5,  # P2 P4 P6 P7 P9, all at LOT2
  n_pat_melp_mono      = 5,
  n_melp_mono_adv      = 4,  # ...less P4, whose LOT2 the transplant started
  n_melp_mono_adv_auto = 1,  # P6 LOT2 carries a transplant inside the line
  median_melp_mono_len = 30, # 30,30,30,123,181

  # Melphalan's own cover is what the line ran out on. P9's LOT1 is here
  # because its melphalan episode ends with the line; reading the SECOND
  # line's episode as LOT1's cover loses it.
  n_melp_sets_runout = 5,    # P2 L2, P3 L1, P7 L2, P9 L1, P9 L2
  n_melp_holds_multi = 2,    # ...of those, P3 L1 and P9 L1 have another agent

  n_pat_melp_fu = 8,         # everyone but P1 has a melphalan claim

  n_b2_line_starts = 2,      # P7 and P8
  n_b2_melp_only   = 1)      # ...P8's line DARA would have started anyway

# By LOT_NUM, among the melphalan-exposed - eight patients, P1 excluded.
EXEC_EXPECT_BY_LINE <- list(
  "1" = list(N_LINES = 8, N_PATIENTS = 8, MEDIAN_LEN = 180,
             N_MELP_ANY = 2,        # P3, P9
             N_MONO = 0, N_MONO_MED_START = 0,
             N_MELP_DOSE = 4,       # P3, P7, P8, P9
             N_PAT_MELP_AUTO = 0, N_PAT_MELP_ALLO = 0),
  "2" = list(N_LINES = 7, N_PATIENTS = 7, MEDIAN_LEN = 30,
             N_MELP_ANY = 6,        # every LOT2 but P5's, whose regimen is blank
             N_MONO = 5, N_MONO_MED_START = 4,
             N_MELP_DOSE = 7,       # ...including P5's, found off the claims
             N_PAT_MELP_AUTO = 2,   # P4, P6
             N_PAT_MELP_ALLO = 1))  # P5 - invisible to any regimen test

EXEC_EXPECT_PATIENTS <- list(
  N_PATIENTS = 9,                    # the union of both readings
  N_ONLY_ONE_SIDE = 1,               # P1
  N_DIFFERENT = 3,                   # P1, P2, P3
  N_LINE_COUNT_DIFFERENT = 2,        # P1, P3
  N_SAME_COUNT_DIFFERENT_LINES = 1)  # P2

# ---- running them ----------------------------------------------------------
.exec_json_val <- function(n, v) {
  if (is.null(v) || (length(v) == 1L && is.na(v))) sprintf('"%s":null', n)
  else if (is.numeric(v)) sprintf('"%s":%s', n, format(v, scientific = FALSE))
  else sprintf('"%s":"%s"', n, v)
}

.exec_json_rows <- function(rows, cols)
  paste(vapply(rows, function(r)
    paste0("{", paste(vapply(names(cols), function(n) .exec_json_val(n, r[[n]]),
                             character(1)), collapse = ","), "}"),
    character(1)), collapse = ",")

.exec_json_str <- function(s)
  gsub("\n", "\\\\n", gsub('"', '\\\\"', gsub("\\\\", "\\\\\\\\", s)))

# Returns a data frame of id / row / col / value, or "skip" where duckdb and
# sqlglot are not installed. A statement that could not be run comes back with
# col = "ERROR" and is reported rather than read as an empty result.
run_exec_queries <- function(queries, root, schema = EXEC_SCHEMA,
                             data = EXEC_DATA) {
  py <- file.path(root, "tests", "run_duckdb.py")
  if (!file.exists(py)) return(NULL)
  tabs <- paste(vapply(names(schema), function(k) {
    cols <- schema[[k]]$columns
    sprintf('"%s":{"columns":{%s}}', schema[[k]]$table,
            paste(sprintf('"%s":"%s"', names(cols), cols), collapse = ","))
  }, character(1)), collapse = ",")
  rows <- paste(vapply(intersect(names(schema), names(data)), function(k)
    sprintf('"%s":[%s]', schema[[k]]$table,
            .exec_json_rows(data[[k]], schema[[k]]$columns)),
    character(1)), collapse = ",")
  qs <- paste(vapply(names(queries), function(id)
    sprintf('{"id":"%s","sql":"%s"}', id, .exec_json_str(queries[[id]])),
    character(1)), collapse = ",")
  spec <- sprintf('{"tables":{%s},"data":{%s},"queries":[%s]}', tabs, rows, qs)
  f <- tempfile(fileext = ".json"); writeLines(spec, f)
  out <- suppressWarnings(system2("python3", c(shQuote(py), shQuote(f)),
                                  stdout = TRUE, stderr = TRUE))
  if (!length(out)) return(NULL)
  if (grepl("^SKIP", out[1])) return("skip")
  # A blank line parses to four NAs, and an NA in `row` makes every later
  # comparison against it NA rather than FALSE - which is how an empty error
  # list came back as one empty error.
  out <- out[nzchar(trimws(out))]
  if (!length(out)) return(NULL)
  do.call(rbind, lapply(out, function(l) {
    p <- strsplit(l, "\t", fixed = TRUE)[[1]]
    length(p) <- 4L
    p[is.na(p)] <- ""
    data.frame(id = p[1], row = p[2], col = p[3], value = p[4],
               stringsAsFactors = FALSE)
  }))
}

# One cell out of that frame. NA where the statement returned no such column,
# which is what makes a lost alias a failure rather than a silent pass.
exec_cell <- function(res, id, col, row = "0") {
  if (is.null(res) || identical(res, "skip")) return(NA_character_)
  hit <- res$value[res$id == id & res$row == row & toupper(res$col) == toupper(col)]
  if (!length(hit)) NA_character_ else hit[1]
}

exec_num <- function(res, id, col, row = "0")
  suppressWarnings(as.numeric(exec_cell(res, id, col, row)))

# paste0() recycles a zero-length argument against a length-one one and
# returns ": " - so with no errors at all this reported one. The subset is
# taken first and its emptiness is the answer.
exec_errors <- function(res) {
  if (is.null(res) || identical(res, "skip")) return(character(0))
  bad <- res[res$row == "ERROR", , drop = FALSE]
  if (!nrow(bad)) return(character(0))
  paste0(bad$id, ": ", bad$col)
}
