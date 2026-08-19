#!/usr/bin/env Rscript
# One plain-text summary of the study-team answers, filled from the files the
# runs already wrote. Reads only; no connection.
#
#   Rscript reporting/summarize_results.R [results_dir]
#
# results_dir defaults to OUTPUT_DIR, then /mnt/artifacts/results. The
# melphalan, fold-in and audit outputs are also looked for in their own out/
# folders, so it works whether or not OUTPUT_DIR was set for those runs.
# A section whose files are missing says so instead of stopping.
#
# Writes results_summary_<stamp>.txt next to the August answers and prints
# the same text.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
STUDY <- dirname(.script_dir)

argv <- commandArgs(trailingOnly = TRUE)
res_dir <- if (length(argv)) argv[1] else {
  d <- trimws(Sys.getenv("OUTPUT_DIR", unset = ""))
  if (nzchar(d)) d else "/mnt/artifacts/results"
}
DIRS <- unique(c(res_dir,
                 file.path(STUDY, "exploration", "melphalan", "out"),
                 file.path(STUDY, "exploration", "lot", "out")))

# Newest file matching the pattern across the candidate dirs, or NULL.
find_file <- function(pattern) {
  hits <- unlist(lapply(DIRS[dir.exists(DIRS)], function(d)
    list.files(d, pattern, full.names = TRUE)))
  if (!length(hits)) return(NULL)
  hits[order(file.mtime(hits), decreasing = TRUE)][1]
}
read_any <- function(pattern) {
  f <- find_file(pattern)
  if (is.null(f)) return(NULL)
  tryCatch(utils::read.csv(f, stringsAsFactors = FALSE), error = function(e) NULL)
}
n1 <- function(x) if (is.null(x) || !length(x) || is.na(x[1])) "?" else
  format(as.numeric(x[1]), big.mark = ",")

out <- character(0)
say <- function(...) out <<- c(out, paste0(...))

say("NDMM lines of therapy - results")
say(format(Sys.time(), "%d %b %Y %H:%M"))
say("")

# ---- which run this all comes from ------------------------------------------
status_f <- find_file("^aug15_qs_run_status_.*\\.txt$")
stamp <- if (!is.null(status_f))
  sub("^aug15_qs_run_status_(.*)\\.txt$", "\\1", basename(status_f)) else
  format(Sys.time(), "%Y%m%d_%H%M%S")
if (!is.null(status_f)) {
  st <- readLines(status_f, warn = FALSE)
  run_ln <- grep("LOT run:", st, value = TRUE)
  if (length(run_ln)) say("Built on", sub(".*LOT run:", " LOT run", run_ln[1]), ".")
  waived <- grep("WAIVED|UNPROVEN", st, value = TRUE)
  for (w in waived)
    say("WARNING: ", trimws(w), " - fix this before sending numbers out.")
} else {
  say("NOTE: no aug15 run-status file found under ", res_dir,
      " - run analysis/questions/aug15_studyteam_qs.R first.")
}
say("")

# ---- 1. the MAP splitting rule ----------------------------------------------
say("1) MAP-splitting rule - how many patients")
aff <- read_any("^aug15_qs_map_splitting_affected_.*\\.csv$")
if (is.null(aff)) {
  say("   No screen file yet - run aug15_studyteam_qs.R first.")
} else {
  all_rows <- aff[aff$LINE_THAT_ENDED == "ALL", ]
  pick <- function(basis, cls) {
    r <- all_rows[all_rows$MATCH_BASIS == basis & all_rows$CLASS == cls, ]
    if (nrow(r)) r$N_PATIENTS[1] else 0
  }
  say("   ", n1(pick("EXACT_TOKEN", "AFFECTED")),
      " patients: an old drug came back and that alone splits the line today.")
  say("   ", n1(pick("EXACT_TOKEN", "SAME_DAY_NEW_AGENT")),
      " more: an old drug came back, but a new drug started the same day,")
  say("   so the split stays either way.")
  say("   If a biosimilar counts as the same drug, the two numbers are ",
      n1(pick("SUBSTITUTE_FAMILY", "AFFECTED")), " and ",
      n1(pick("SUBSTITUTE_FAMILY", "SAME_DAY_NEW_AGENT")), ".")
  roster <- find_file("^aug15_qs_map_splitting_review_roster_.*\\.csv$")
  if (!is.null(roster))
    say("   List of these patients: ", basename(roster))
}
fp <- read_any("^foldin_patients\\.csv$")
if (!is.null(fp)) {
  say("")
  say("   We also built a test copy of the line table with the rule switched")
  say("   on. The study tables are untouched. Result: ", n1(fp$N_DIFFERENT),
      " of ", n1(fp$N_PATIENTS), " patients change,")
  say("   and ", n1(fp$N_LINE_COUNT_DIFFERENT),
      " of them end up with a different number of lines.")
  ch <- find_file("^foldin_changed_lines\\.csv$")
  if (!is.null(ch)) say("   Before and after for each: ", basename(ch))
  say("   Three choices went into this build - please confirm each:")
  say("   - a drug from any old line folds in, not just the last line's")
  say("   - the drug extends the line's dates but is not added to its regimen")
  say("   - it folds in even when the line had already ended")
}
say("")

# ---- 2. the MELP rules ------------------------------------------------------
say("2) The MELP rules")
mp <- read_any("^melp_modes_patients\\.csv$")
mv <- read_any("^melp_vs_reference\\.csv$")
if (is.null(mv) && is.null(mp)) {
  say("   No melphalan comparison files yet - run the melphalan package first.")
} else {
  vs <- function(d, cellname, metric) {
    r <- d[d$cell == cellname & d$metric == metric, ]
    if (nrow(r)) paste0(n1(r$reference), " -> ", n1(r$observed)) else "?"
  }
  if (!is.null(mv)) {
    say("   Your July rule, built as a test copy next to the study build:")
    say("   total lines ", vs(mv, "as_asked", "n_lines"),
        ". Melphalan-only lines ", vs(mv, "as_asked", "n_melp_mono_lines"), ".")
    say("   Lines that melphalan alone started ",
        vs(mv, "as_asked", "n_melp_mono_adv"), ".")
  }
  if (!is.null(mp))
    say("   ", n1(mp$N_DIFFERENT), " patients come out differently depending ",
        "on how we treat a dose next to a transplant.")
}
sp <- read_any("^melp_simple_patients\\.csv$")
if (!is.null(sp))
  say("   The simple 28-day version changes ", n1(sp$N_DIFFERENT), " of ",
      n1(sp$N_PATIENTS), " patients.")
say("   To keep in mind: the study numbers are unchanged. Melphalan with a")
say("   steroid still counts as melphalan alone, because steroids are not in")
say("   the captured drug list. And 28 vs 30 days is about course length -")
say("   changing the assumed days supplied would be a separate change.")
say("")

# ---- 3. the 12-month CE funnel ----------------------------------------------
say("3) Discontinued the prior line, then 12 months of coverage")
fu <- read_any("^aug15_qs_discontinued_then_12mo_ce_.*\\.csv$")
if (is.null(fu)) {
  say("   No funnel file yet - run aug15_studyteam_qs.R first.")
} else {
  for (i in seq_len(nrow(fu))) {
    say("   ", fu$COHORT[i], ": ", n1(fu$N_DISCONTINUED_PRIOR[i]),
        " patients stopped ", fu$PRIOR_LINE_DISCONTINUED[i], ". ",
        n1(fu$N_ALSO_HAS_NEXT_LINE[i]), " of them went on to ", fu$COHORT[i],
        ". ", n1(fu$N_ALSO_12MO_CE_BEFORE_IT[i]),
        " of those also had 12 months of")
    say("       coverage before it started.")
  }
  say("   12 months = enrolled for the full 365 days before the line starts")
  say("   (small gaps merged). Stopped = the line's recorded end reason.")
  attr_f <- find_file("^aug15_qs_subsequent_cohort_attrition_.*\\.csv$")
  if (!is.null(attr_f))
    say("   The official 2L/3L cohort funnel is in ", basename(attr_f), ".")
  else
    say("   The official 2L/3L cohort file was not written - rebuild it ",
        "after this LOT run.")
}
say("")

# ---- checks -----------------------------------------------------------------
say("Checks")
aud <- read_any("^lot_audit_counts\\.csv$")
if (!is.null(aud)) {
  b <- aud[aud$finding == "transplant-belonging-to-no-line", ]
  if (nrow(b)) {
    say("   Transplants outside every line (should be 0 after the rebuild):")
    for (r in unique(b$row)) {
      rr <- b[b$row == r, ]
      say("     ", paste(paste0(rr$metric, "=", rr$value), collapse = "  "))
    }
  }
}
say("   The QC report and lot_scenarios.xlsx have the rest. The workbook's")
say("   Open questions sheet lists what is still not settled.")
say("")

say("What we need Julia to decide")
say("   - MAP rule: use it or not. If yes: any old line's drugs or just the")
say("     last line's? Add the drug to the regimen, or just extend the line?")
say("     Fold it in even after the line ended?")
say("   - MELP: the July rule or the simple 28-day one? What happens to a")
say("     dose next to a transplant? 28 or 30 days? And is melphalan+DEX")
say("     'melphalan alone'?")
say("   - Tandems: today a treatment stop between two transplants does not")
say("     break the pair, but a new drug does. Is that right?")

txt <- paste(out, collapse = "\n")
dest <- file.path(if (dir.exists(res_dir)) res_dir else ".",
                  paste0("results_summary_", stamp, ".txt"))
writeLines(txt, dest)
cat(txt, "\n\nWrote ", dest, "\n", sep = "")
