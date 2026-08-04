#!/usr/bin/env Rscript
# The melphalan rule, held to the ask. No warehouse: the SQL is built as a
# string, and the branch decision is lifted out of it and evaluated over cases.
#
#   Rscript "lot_validation/tests/test_melphalan.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
PARENT <- dirname(ROOT)
pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok    ", what, "\n") }
  else { fail <<- fail + 1L; cat("  FAIL  ", what, "\n") }
}
stops <- function(expr, what) ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)
has   <- function(x, s) grepl(s, x, fixed = TRUE)
if (requireNamespace("glue", quietly = TRUE)) library(glue) else
  glue <- function(..., .envir = parent.frame()) {
    t <- paste0(..., collapse = "")
    m <- gregexpr("\\{[^{}]+\\}", t)[[1]]
    if (m[1] == -1L) return(t)
    len <- attr(m, "match.length"); out <- character(0); pos <- 1L
    for (i in seq_along(m)) {
      out <- c(out, substr(t, pos, m[i] - 1L),
               paste(as.character(eval(parse(
                 text = substr(t, m[i] + 1L, m[i] + len[i] - 2L)), .envir)), collapse = ""))
      pos <- m[i] + len[i]
    }
    paste0(c(out, substr(t, pos, nchar(t))), collapse = "")
  }
sql_text <- function(x) paste0("'", gsub("'", "''", as.character(x)), "'")
source(file.path(ROOT, "R", "melphalan.R"))

cat("\n-- the settings are the ask's, and a junk one stops rather than defaults --\n")
mc <- melp_cfg(function(nm, unset = "") unset)
ok(identical(mc$exposure_days, 30L), "an exposure is one administration - 30 days")
ok(identical(mc$restart_days, 60L) && identical(mc$advance_days, 180L),
   "60 and 180 days are the two thresholds the ask names")
ok(identical(mc$induction_1l, 60L) && identical(mc$induction_n, 30L),
   "the induction window is the build's own, not a second copy")
# 180 is the transplant tandem window, and that is the point of the rule.
tan <- readLines(file.path(PARENT, "lot", "config.csv"), warn = FALSE)
ok(any(grepl("^SCT_TANDEM_DAYS,180", tan)),
   "...and 180 is the same number the transplant rule already uses")
stops(melp_cfg(function(nm, unset = "") if (nm == "MELP_ADVANCE_DAYS") "soon" else unset),
      "a threshold that is not a number stops rather than falling back")
stops(melp_cfg(function(nm, unset = "") if (nm == "MELP_RULE_MODE") "whatever" else unset),
      "an unknown transplant mode stops - the two readings are not a free string")

cat("\n-- the rule itself, lifted out of the SQL and run over cases --\n")
# Restating the branches here would be a second implementation that agrees with
# whatever this file believes. The CASE the warehouse runs is the one tested.
rule_of <- function(cfg) {
  s <- melp_rule_sql("L", "M", "A", cfg, "r1")
  x <- sub("(?s)^.*?CASE\n\\s*WHEN GAP IS NULL", "CASE WHEN GAP IS NULL", s, perl = TRUE)
  x <- sub("(?s)\\s*END AS ADVANCES.*$", "", x, perl = TRUE)
  x <- gsub("\n\\s*", " ", trimws(x))
  x <- sub("^CASE\\s*", "", sub("\\s*$", "", x))
  els <- "NA"
  if (grepl("\\bELSE\\b", x)) {
    els <- trimws(sub("^.*\\bELSE\\b", "", x)); x <- sub("\\bELSE\\b.*$", "", x)
  }
  arms <- Filter(nzchar, trimws(strsplit(x, "\\bWHEN\\b")[[1]]))
  tr <- function(s) {
    s <- trimws(s)
    s <- gsub("([A-Za-z_][A-Za-z0-9_]*) IS NULL", "is.na(\\1)", s)
    s <- gsub("\\bAND\\b", "&", gsub("\\bOR\\b", "|", s))
    s <- gsub("(?<![<>!=])=(?!=)", "==", s, perl = TRUE)
    # After IS NULL, or the guard above would be rewritten into is.na(NA).
    gsub("\\bNULL\\b", "NA", s)
  }
  body <- paste0(paste(vapply(arms, function(a) {
    kv <- strsplit(a, "\\bTHEN\\b")[[1]]
    paste0("if (isTRUE(", tr(kv[1]), ")) ", tr(kv[2]), " else ")
  }, character(1)), collapse = ""), tr(els))
  function(GAP, INSIDE, HAS_AUTO = 0) {
    e <- list2env(list(GAP = GAP, INSIDE = INSIDE, HAS_AUTO = HAS_AUTO),
                  parent = environment())
    tryCatch(eval(parse(text = body), envir = e), error = function(e) "PARSE-FAIL")
  }
}
r <- rule_of(mc)
ok(!identical(r(200, 1), "PARSE-FAIL"), "the branch decision lifts out of the SQL")

# A. first exposure inside the induction window.
ok(is.na(r(179, 1)), "A: inside induction, next under 180 days - no advance")
ok(identical(r(180, 1), "NEXT"),
   "A: inside induction, next at 180 days - the NEXT exposure starts a line")
ok(identical(r(400, 1), "NEXT"), "...and any later one likewise")
# B. first exposure outside it.
ok(identical(r(59, 0), "FIRST"),
   "B: outside induction, next under 60 days - the FIRST exposure starts a line")
ok(is.na(r(60, 0)), "B: outside induction, next at 60 days - neither advances")
ok(is.na(r(179, 0)), "...and at 179 days likewise")
ok(identical(r(180, 0), "NEXT"),
   "B: outside induction, next at 180 days - the NEXT exposure starts a line")
# The boundaries are where the ask puts them, not one day off.
ok(is.na(r(179, 1)) && identical(r(180, 1), "NEXT"),
   "the 180-day boundary is inclusive, as '>= 180 days later' says")
ok(identical(r(59, 0), "FIRST") && is.na(r(60, 0)),
   "the 60-day boundary is exclusive, as '< 60 days later' says")
# A last exposure has nothing after it, so it decides nothing.
ok(is.na(r(NA, 1)) && is.na(r(NA, 0)), "an exposure with no next one advances nothing")

cat("\n-- the two readings of a coded transplant are both real --\n")
y <- rule_of(modifyList(mc, list(mode = "yield_to_sct")))
a <- rule_of(modifyList(mc, list(mode = "as_asked")))
ok(is.na(y(200, 1, HAS_AUTO = 1)),
   "yield_to_sct: an exposure with a coded transplant is left to the SCT rule")
ok(identical(a(200, 1, HAS_AUTO = 1), "NEXT"),
   "as_asked: the same exposure advances, because the ask does not carve it out")
ok(identical(y(200, 1, HAS_AUTO = 0), a(200, 1, HAS_AUTO = 0)),
   "...and where no transplant is coded the two readings agree")

cat("\n-- it reads a finished run and rebuilds nothing --\n")
rs <- paste(readLines(file.path(ROOT, "run_melphalan_rule.R"), warn = FALSE),
            collapse = "\n")
sq <- paste(melp_rule_sql("L", "M", "A", mc, "r1"),
            melp_impact_sql("R", "L", mc, "r1"), melp_branch_sql("R"))
ok(!has(sq, "LOT_LONG_FINAL AS") && !has(rs, "build.R"),
   "it writes no LOT table and starts no build")
ok(all(vapply(c("MELP_RULE_EXPOSURES", "MELP_RULE_BRANCHES", "MELP_RULE_IMPACT"),
              function(n) has(rs, n), logical(1))),
   "its three outputs are its own, under its own names")
ok(has(rs, "require_lot_run(con, prefix)"),
   "it holds the run to the same ownership rule the other programs use")
ok(has(rs, 'env_flag("MELP_EXECUTE")'),
   "execution is opt-in - the default prints the rule and connects to nothing")
# Every row says which reading produced it, or two runs are indistinguishable.
ok(has(sq, "AS MELP_RULE_MODE") && has(sq, "AS MELP_RUN_ID"),
   "every row carries the mode and the run that wrote it")

cat("\n-- the impact is counted in both directions, not netted --\n")
im <- melp_impact_sql("R", "L", mc, "r1")
ok(has(im, "AS N_SPLIT") && has(im, "AS N_MERGE"),
   "boundaries added and boundaries removed are separate columns")
# A merge is a line the build ended by ADDING this drug, where the rule says
# that exposure does not advance. Keying on the reason alone would count every
# add-med line, whatever drug ended it.
ok(has(im, "LOT_END_REASON = 'MED_ADD'") && has(im, "ADD_MED = upper('MELP')"),
   "a removed boundary is an add-med line ended by THIS drug, not any drug")
ok(has(im, "r.PATID IS NULL"),
   "...and only where no exposure advances at that boundary")
# A split has to be inside a line, not on its start - a date that already
# starts a line is already a boundary and would be counted twice.
ok(has(im, "r.ADVANCE_DT >  l.LOT_START_DT"),
   "an added boundary is strictly inside a line, so a line start is not doubled")
ok(has(rs, "Read the two columns, not the net"),
   "the run says the net can cancel, because the rule moves both ways")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
