#!/usr/bin/env Rscript
# The builds' SQL, run by Spark itself - ANSI mode on, no translation.
#
# The other suites run the emitted SQL in DuckDB through sqlglot, which cannot
# say what Spark does with a statement where the two engines differ. These are
# the places known to differ, run in a local SparkSession (tests/spark_sql.py):
#
#   - dates: under ANSI mode, Databricks SQL's default, to_date() raises on a
#     string that is not a calendar date (20200230, 00000000); the date helpers
#     must return NULL instead, as DuckDB always did;
#   - code keys: a code that normalises to nothing is NULL, so two blank codes
#     never join;
#   - the AUTO transplant dates at the tandem mark (lot/LOT_RULES.md 6.1): the
#     engine's own clustering statement, Spark aggregate() with a finish
#     lambda, which DuckDB cannot run at all.
#
# Needs pyspark and a Java runtime, found as SPARK_PYTHON (default python3).
# Without them it says SKIP and exits non-zero unless ALLOW_SKIPPED_TESTS=TRUE.
#
#   Rscript tests/test_spark_sql.R

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                               fixed = TRUE)))
  else getwd()
})
ROOT <- dirname(HERE)
LOT  <- file.path(ROOT, "lot", "engine")
source(file.path(LOT, "tests", "testutil.R"))

py <- Sys.getenv("SPARK_PYTHON", unset = "python3")
have_spark <- identical(0L, suppressWarnings(system2(
  py, c("-c", shQuote("import pyspark")), stdout = FALSE, stderr = FALSE))) &&
  identical(0L, suppressWarnings(system2("java", "-version", stdout = FALSE,
                                         stderr = FALSE)))
if (!have_spark) {
  skip_note(paste0("the Spark suite: ", py, " cannot import pyspark, or no Java runtime"))
  report()
}

# The builds' helpers and the engine's clustering step, loaded as a run would.
e <- new.env(parent = globalenv())
for (f in c("load_inputs.R", "config_lot.R", "db_utils_lot.R", "mdv_source.R",
            "steps/05_sct.R"))
  sys.source(file.path(LOT, "R", f), envir = e)
assign("cfg", e$cfg_defaults, envir = e)

# Steps out, results back.
spark_run <- function(steps) {
  sf <- tempfile(fileext = ".sql"); rf <- tempfile(fileext = ".txt")
  writeLines(unlist(lapply(names(steps), function(n)
    c(paste("@@step", n, if (isTRUE(attr(steps[[n]], "fetch"))) 1 else 0), steps[[n]]))), sf)
  log <- suppressWarnings(system2(py, c(shQuote(file.path(HERE, "spark_sql.py")),
                                        shQuote(sf), shQuote(rf)),
                                  stdout = TRUE, stderr = TRUE))
  if (!file.exists(rf)) stop("Spark produced no results:\n", paste(utils::tail(log, 15), collapse = "\n"))
  lines <- readLines(rf, warn = FALSE)
  res <- list(); cur <- NULL
  for (l in lines[-1]) {
    if (startsWith(l, "@@result ")) {
      p <- strsplit(sub("^@@result ", "", l), " ", fixed = TRUE)[[1]]
      cur <- p[1]
      res[[cur]] <- list(ok = identical(p[2], "ok"),
                         error = if (length(p) > 2) paste(p[-(1:2)], collapse = " ") else "",
                         rows = NULL, header = NULL)
    } else if (!is.null(cur)) {
      f <- strsplit(l, "\t", fixed = TRUE)[[1]]
      if (is.null(res[[cur]]$header)) res[[cur]]$header <- f
      else {
        # strsplit drops a trailing empty field; an empty value is a value.
        length(f) <- length(res[[cur]]$header); f[is.na(f)] <- ""
        res[[cur]]$rows <- rbind(res[[cur]]$rows, f)
      }
    }
  }
  attr(res, "spark") <- lines[1]
  res
}
fetch <- function(sql) structure(sql, fetch = TRUE)
col <- function(r, name) {
  if (is.null(r$rows)) return(character(0))
  unname(r$rows[, match(name, r$header)])
}

# ---- the statements -----------------------------------------------------------
vals <- c("20200305", "20200230", "00000000", "20201301", "20200229", "20210229",
          "2020-03-05", "2020")
months <- c("202003", "202013", "202000", "2020-03")
vtab <- function(v) paste0("(VALUES ", paste0("('", v, "')", collapse = ", "), ") AS t(v)")

# The engine's AUTO clustering statement, as run_step() would send it.
s13 <- local({
  got <- character(0)
  assign("run_step", function(con, name, sql, ...) if (name == "S13_tx_auto_dates")
    got <<- c(got, sql), envir = e)
  assign("db_q", function(...) data.frame(), envir = e)
  assign("log_msg", function(...) invisible(NULL), envir = e)
  tryCatch(e$phase_sct_cluster(NULL, list()), error = function(err) NULL)
  got[1]
})
d0 <- as.Date("2021-01-01"); tnd <- e$cfg_defaults$sct_tandem_days
win <- e$cfg_defaults$sct_auto_window_days
autos <- list(
  trace    = c(0L, 181L, 190L),                                   # the review's trace
  straddle = c(30L, 30L + tnd - 3L, 30L + tnd + 6L),              # auto_seam_straddle
  after    = c(30L, 30L + tnd + 2L, 30L + tnd + 11L),             # auto_seam_after
  far      = c(30L, 30L + tnd + win + 1L, 30L + tnd + win + 8L))  # auto_seam_far
claims <- unlist(lapply(names(autos), function(p)
  sprintf("('%s', date('%s'), 'AUTO', 'x')", p, format(d0 + autos[[p]]))))

steps <- list(
  ansi_control = fetch(paste0("SELECT to_date('20200230', 'yyyyMMdd') AS d")),
  dates  = fetch(paste0("SELECT v, ", e$mdv_date_sql("v"), " AS d FROM ", vtab(vals))),
  months = fetch(paste0("SELECT v, ", e$mdv_month_sql("v"), " AS d FROM ", vtab(months))),
  codes  = fetch(paste0("SELECT v, ", e$mdv_code_sql("v"), " AS k FROM ",
                        vtab(c("--", " ", " C90.0 ", "c90.0")))),
  blank_join = fetch(paste0(
    "SELECT count(*) AS n FROM (SELECT ", e$mdv_code_sql("v"), " AS k FROM ", vtab("--"),
    ") a INNER JOIN (SELECT ", e$mdv_code_sql("v"), " AS k FROM ", vtab(" "),
    ") b ON a.k = b.k")),
  sct_claims = paste0("CREATE OR REPLACE TEMPORARY VIEW sct_claims_raw AS SELECT * FROM (VALUES ",
                      paste(claims, collapse = ", "),
                      ") AS t(PATID, DATE_SERVICE, SCT_TYPE, CODE)"),
  s13 = s13,
  auto = fetch("SELECT PATID, TX_SEQ, cast(TX_DT as string) AS TX_DT FROM tx_auto_dates ORDER BY PATID, TX_SEQ"))

res <- spark_run(steps)
cat("  ", attr(res, "spark"), "\n")

cat("\n-- the harness runs Spark with ANSI mode on --\n")
ok(isTRUE(!res$ansi_control$ok) && grepl("20200230", res$ansi_control$error, fixed = TRUE),
   "control: plain to_date() raises on 20200230 here, as on Databricks SQL")

cat("\n-- dates that are not calendar dates are NULL, not an error --\n")
ok(isTRUE(res$dates$ok), paste0("mdv_date_sql() runs over malformed dates without raising",
                                if (!isTRUE(res$dates$ok)) paste0(" [", res$dates$error, "]") else ""))
got <- setNames(col(res$dates, "d"), col(res$dates, "v"))
ok(identical(unname(got[c("20200305", "20200229", "2020-03-05")]),
             c("2020-03-05", "2020-02-29", "2020-03-05")),
   "real dates parse, 29 February 2020 included")
ok(all(got[c("20200230", "00000000", "20201301", "20210229", "2020")] == "NULL"),
   "20200230, 00000000, 20201301, 20210229 and a bare year are NULL")
ok(isTRUE(res$months$ok), "mdv_month_sql() runs over malformed months without raising")
gm <- setNames(col(res$months, "d"), col(res$months, "v"))
ok(identical(unname(gm[c("202003", "2020-03")]), c("2020-03-01", "2020-03-01")) &&
     all(gm[c("202013", "202000")] == "NULL"),
   "a claim month is its first day, and month 13 or 00 is NULL")

cat("\n-- a blank code is no code --\n")
gc <- setNames(col(res$codes, "k"), col(res$codes, "v"))
ok(identical(unname(gc[c("--", " ")]), c("NULL", "NULL")) &&
     identical(unname(gc[c(" C90.0 ", "c90.0")]), c("C900", "C900")),
   "'--' and ' ' normalise to NULL; ' C90.0 ' and 'c90.0' to C900")
ok(identical(col(res$blank_join, "n"), "0"), "so a '--' key and a ' ' key do not join")

cat("\n-- the engine's AUTO dates at the tandem mark (LOT_RULES.md 6.1) --\n")
ok(!is.na(s13) && grepl("aggregate(", s13, fixed = TRUE),
   "the clustering statement is the engine's own, aggregate() and all")
ok(isTRUE(res$s13$ok) && isTRUE(res$auto$ok),
   paste0("Spark runs it", if (!isTRUE(res$s13$ok)) paste0(" [", res$s13$error, "]") else ""))
tx <- function(p) {
  keep <- col(res$auto, "PATID") == p
  as.integer(as.Date(col(res$auto, "TX_DT")[keep]) - d0)
}
ok(identical(tx("trace"), c(0L, 181L)),
   "claims on days 0, 181, 190 give transplants on 0 and 181 - the claim nearest the mark")
ok(identical(tx("straddle"), c(30L, 30L + tnd - 3L)),
   "auto_seam_straddle: a window across the mark is dated at its claim inside it")
ok(identical(tx("after"), c(30L, 30L + tnd + 2L)),
   "auto_seam_after: a window wholly past the mark is dated at its claim nearest it")
ok(identical(tx("far"), c(30L, 30L + tnd + win + 8L)),
   "auto_seam_far: a window clear of the mark is dated at its last claim")

report()
