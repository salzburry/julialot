#!/usr/bin/env Rscript
# The emitted chain, checked for shapes duckdb cannot refuse.
#
# The five synthetic harnesses run the engine's own SQL, which is what makes
# them worth having - but they run it through sqlglot into duckdb, and duckdb is
# more forgiving than Spark in one specific way that has already cost a build:
# it PRUNES a CTE nothing selects from, before binding it. Spark does not.
# CheckAnalysis resolves every CTE a statement defines, used or not, so a
# definition naming a relation that does not exist yet raises
# TABLE_OR_VIEW_NOT_FOUND on a clean session - and, worse, does NOT raise it
# where a relation of that name is left over from an earlier run, so the failure
# is intermittent and looks like an environment problem.
#
# That is how a helper carrying a CTE reading FROM lot1_base came to be spliced
# into the statement that CREATES lot1_base: every suite and every harness
# passed, because none of them could see it.
#
# So this reads the emitted SQL as text and asks the one question duckdb will
# never ask: does a statement name the relation it is in the middle of
# creating?

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
REPO <- dirname(dirname(HERE))
EMIT <- file.path(REPO, "validation", "synthetic", "emit_chain.R")

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  cat(if (isTRUE(cond)) "  ok     " else "  FAIL   ", what, "\n", sep = "")
  if (isTRUE(cond)) pass <<- pass + 1L else fail <<- fail + 1L
}

if (!file.exists(EMIT)) {
  cat("SKIP: no emit_chain.R beside this suite.\n")
  quit(status = 0)
}

out <- file.path(tempdir(), paste0("emitshape_", Sys.getpid()))
dir.create(out, showWarnings = FALSE, recursive = TRUE)
res <- suppressWarnings(system2("Rscript", c(shQuote(EMIT), shQuote(out)),
                                stdout = NULL, stderr = NULL))
chain <- file.path(out, "full_chain.sql")
if (!identical(res, 0L) || !file.exists(chain)) {
  cat("SKIP: the chain could not be emitted here.\n")
  quit(status = 0)
}

sql <- paste(readLines(chain, warn = FALSE), collapse = "\n")

cat("\n-- no statement reads the relation it is creating --\n")
# One statement at a time, split on the emitter's own ";;;" separator. Splitting
# on the next CREATE instead runs a statement into whatever follows it, and what
# follows a materialize() repoint is an INSERT that reads the view just
# repointed - which reads exactly like a self-reference and is not one.
head_re <- "CREATE OR REPLACE (?:TEMPORARY VIEW|TABLE)[ \t]+([^ \t\r\n]+)"
stmts <- strsplit(sql, ";;;", fixed = TRUE)[[1]]
stmts <- stmts[grepl(head_re, stmts, perl = TRUE)]

# materialize() writes the TABLE first and repoints the VIEW at it afterwards,
# so the two names differ and the dangerous read is of the VIEW. Comparing a
# statement only against its own CREATE target therefore misses the case this
# suite exists for: a CTE inside the statement building T_LOT1_BASE that reads
# lot1_base, the view that does not exist until the repoint one statement later.
#
# The pairing is taken from the repoint statements themselves rather than by
# guessing a prefix, which is configurable.
pair <- list()
for (body in stmts) {
  m <- regmatches(body, regexpr(
    "CREATE OR REPLACE TEMPORARY VIEW[ \t]+([^ \t\r\n]+)[ \t\r\n]+AS[ \t\r\n]+SELECT \\*[ \t\r\n]+FROM[ \t\r\n]+([^ \t\r\n;]+)",
    body, perl = TRUE))
  if (!length(m)) next
  v <- sub("^.*VIEW[ \t]+([^ \t\r\n]+).*$", "\\1", m, perl = TRUE)
  t <- sub("^.*FROM[ \t\r\n]+([^ \t\r\n;]+).*$", "\\1", m, perl = TRUE)
  pair[[toupper(sub("^.*\\.", "", t))]] <- sub("^.*\\.", "", v)
}

offenders <- character(0)
for (body in stmts) {
  names_at <- regmatches(body, regexpr(head_re, body, perl = TRUE))
  targets <- sub(paste0("^.*?", head_re, ".*$"), "\\1", names_at, perl = TRUE)
  short <- sub("^.*\\.", "", targets)
  # Its own name, and the view that will be repointed at it if it is a table.
  forbidden <- unique(c(short, pair[[toupper(short)]]))
  rest <- sub(paste0("^.*?", head_re), "", body, perl = TRUE)
  for (f in forbidden) {
    pat <- paste0("(?i)\\b(FROM|JOIN)[ \t\r\n]+", gsub("([.\\\\])", "\\\\\\1", f), "\\b")
    if (grepl(pat, rest, perl = TRUE))
      offenders <- c(offenders, paste0(targets, " reads ", f))
  }
}
ok(length(stmts) > 10,
   paste0("the chain emitted statements to scan (", length(stmts), ")"))
ok(!length(offenders),
   if (length(offenders))
     paste0("statement(s) reading the relation they create: ",
            paste(unique(offenders), collapse = ", "),
            " - Spark binds an unused CTE, so this fails a clean session and ",
            "passes a dirty one")
   else "no statement names the relation it is in the middle of creating")

cat("\n----------------------------------------------------\n")
cat(pass, " passed, ", fail, " failed\n", sep = "")
quit(status = if (fail > 0L) 1L else 0L)
