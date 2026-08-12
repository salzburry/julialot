#!/usr/bin/env Rscript
# Every SQL fragment spliced tight against other text is one that could weld.
#
#   Rscript validation/hygiene/sql_splices.R
#
# A glue template that reads "...{fn(x)}" with no space or newline at the seam
# takes whatever fn() returns and butts it straight onto the character before
# it. That is fine for a name or a number. It is not fine for a multi-line SQL
# fragment, because glue() trims a template's leading blank line - so a
# fragment that does not open with its own newline welds.
#
# melp_allo_guard() was the one that did not, and every melphalan cell died in
# Spark on
#   AND i.INJECT_DT <= lot2_start.OBS_END_DTAND lot2_start.LOT2_START_TYPE ...
# which parses as an identifier followed by a table name nobody asked for.
#
# So every tight splice in the folder is classified here, once, by what the
# call returns. A new one that is neither a known single-token helper nor a
# known fragment fails this suite and has to be classified rather than
# discovered on a warehouse run.

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
REPO   <- dirname(dirname(HERE))
FOLDER <- Sys.getenv("STUDY_FOLDER", unset = "Jul 28")
ROOT   <- file.path(REPO, FOLDER)
if (!dir.exists(ROOT)) {
  cat("SKIP: no ", FOLDER, " folder beside this one.\n", sep = "")
  quit(status = 3L)
}

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}

# Returns one token - a table name, a literal, a column alias. Butting one
# against the text around it is the point of it.
TOKEN <- c("work", "wrk", "lot_out", "cdm_src", "full_name", "lotn_table",
           "work_tbl_fn", "sql_text", "sql_count", "paste", "paste0",
           "as.integer", "pct_of", "subseq_row", "vqs_in_list",
           "criterion_alias", "criterion_patients_view", "melp_abbr",
           "icd_family_sql", "qs_icd_family_sql", "sanitize_col",
           ".lot_sanitize_col")

# Returns SQL that can span lines. Each one is safe for a stated reason, and
# the reason is the thing to re-check if the call site moves.
FRAGMENT <- c(
  melp_lot1_ctes          = "opens with its own newline",
  melp_decision_ctes      = "opens with its own newline",
  melp_lotn_ctes          = "delegates to melp_decision_ctes",
  melp_suppress_predicate = "opens with its own newline",
  melp_inject_arm         = "opens with its own newline",
  melp_allo_guard         = "opens with its own newline",
  melp_branch_sql         = "spliced after a space, at end of line",
  hits                    = "spliced after WHERE and a space",
  ndmm_criteria_where     = "spliced after WHERE and a space",
  preg_hit_sql            = "wrapped in parentheses at the call site",
  .applies_sql            = "wrapped in parentheses at the call site",
  has                     = "wrapped in parentheses at the call site")

files <- Filter(function(f) !grepl("/tests?/", f),
                list.files(ROOT, pattern = "\\.R$", recursive = TRUE, full.names = TRUE))
PAT <- "(.?)\\{([A-Za-z_.][A-Za-z0-9_.]*)\\([^{}]*\\)\\}(.?)"
seen <- list()
for (f in files) {
  for (ln in readLines(f, warn = FALSE)) {
    m <- gregexpr(PAT, ln, perl = TRUE)[[1]]
    if (m[1] == -1L) next
    for (piece in regmatches(ln, gregexpr(PAT, ln, perl = TRUE))[[1]]) {
      g <- regmatches(piece, regexec(PAT, piece, perl = TRUE))[[1]]
      before <- g[2]; fn <- g[3]; after <- g[4]
      tight <- !(before %in% c("", " ", "\t")) || !(after %in% c("", " ", "\t", ",", ")"))
      if (tight) seen[[fn]] <- c(seen[[fn]], sub(paste0("^", ROOT, "/"), "", f))
    }
  }
}

cat("\n-- every tight SQL splice is classified --\n")
ok(length(seen) > 0L,
   paste0("the scan found splice sites to classify (", length(seen), " distinct call(s))"))
unknown <- setdiff(names(seen), c(TOKEN, names(FRAGMENT)))
ok(!length(unknown),
   if (length(unknown))
     paste0("unclassified call spliced tight against other text: ",
            paste(vapply(unknown, function(n)
              paste0(n, "() in ", paste(unique(seen[[n]]), collapse = ", ")),
              character(1)), collapse = "; "),
            " - say whether it returns one token or a multi-line fragment")
   else "no call is spliced tight without being classified first")

cat("\n-- and the ones that rely on a newline actually open with one --\n")
# Parsed, not pattern-matched: parse() gives the function's own expression
# without evaluating anything, so this suite still loads nothing from the
# folder it is checking.
need_nl <- names(FRAGMENT)[FRAGMENT == "opens with its own newline"]
want <- c(need_nl, names(FRAGMENT)[grepl("^delegates to ", FRAGMENT)])
defs <- list(); defs2 <- list()
for (f in files) {
  exprs <- tryCatch(parse(f, keep.source = FALSE), error = function(e) NULL)
  for (e in exprs) {
    # length() first: a top-level `pkg::fn(...)` has a call, not a symbol, in
    # e[[1]], and as.character() of that is three elements - which turns the
    # %in% into a length-3 condition and errors out of the whole scan rather
    # than skipping one expression.
    if (!is.call(e) || length(e[[1]]) != 1L ||
        !as.character(e[[1]]) %in% c("<-", "=")) next
    nm <- tryCatch(as.character(e[[2]]), error = function(x) "")
    if (length(nm) == 1L && nm %in% want) {
      src1 <- paste(deparse(e[[3]]), collapse = "\n")
      if (nm %in% need_nl) defs[[nm]] <- src1 else defs2[[nm]] <- src1
    }
  }
}
ok(setequal(names(defs), need_nl),
   paste0("every fragment that relies on a leading newline was found (",
          length(defs), " of ", length(need_nl), ")"))
for (fn in need_nl) {
  d <- defs[[fn]]
  ok(!is.null(d) && grepl('paste0("\\n"', d, fixed = TRUE),
     paste0(fn, "() opens its fragment with a newline"))
}
# A delegating hook is safe only while what it delegates to is checked above.
deleg <- names(FRAGMENT)[grepl("^delegates to ", FRAGMENT)]
for (fn in deleg) {
  to <- sub("^delegates to ", "", FRAGMENT[[fn]])
  d  <- defs2[[fn]]
  ok(!is.null(d) && grepl(paste0(to, "("), d, fixed = TRUE) && to %in% need_nl,
     paste0(fn, "() delegates to ", to, "(), which is checked above"))
}

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
