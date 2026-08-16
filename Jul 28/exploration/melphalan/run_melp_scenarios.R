#!/usr/bin/env Rscript
# The study team's worked melphalan scenarios, and the induction-window
# variants they do not cover, run through the shipped rule.
#
#   Rscript exploration/melphalan/run_melp_scenarios.R
#
# No warehouse, no connection, no run: the branch decision is a function of the
# dose dates and the settings, so it can be shown on its own. Exit status is 0
# when every case lands where the branch table puts it and 1 when one does not,
# so this can gate a handover the same way the QC does.
#
# What it is for. The study team's drawings are the only statement of the rule
# that names dates rather than branches, and each shape is its own test: example
# 1 is the only one in which the later dose of a B.2 pair is a patient's last
# exposure, which is a dose no branch judges. The window cases carry the other
# axis - "inside induction" is the line's own window, and the drawings only ever
# use a 60-day or 30-day line.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in a path as ~+~, so a folder with one in its name
  # resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "..", "lot", "engine"), mustWork = TRUE)

`%||%` <- function(a, b) if (is.null(a)) b else a
# glue writes the SQL the decision is lifted out of. The small stand-in keeps
# this runnable where the package is absent, the way the suites do.
if (requireNamespace("glue", quietly = TRUE)) {
  library(glue)
} else {
  glue <- function(..., .envir = parent.frame()) {
    t <- paste0(..., collapse = "")
    m <- gregexpr("\\{[^{}]+\\}", t)[[1]]
    if (m[1] == -1L) return(t)
    len <- attr(m, "match.length"); out <- character(0); pos <- 1L
    for (i in seq_along(m)) {
      out <- c(out, substr(t, pos, m[i] - 1L),
               paste(as.character(eval(parse(
                 text = substr(t, m[i] + 1L, m[i] + len[i] - 2L)), .envir)),
                 collapse = ""))
      pos <- m[i] + len[i]
    }
    paste0(c(out, substr(t, pos, nchar(t))), collapse = "")
  }
}
source(file.path(LOT_ROOT, "R", "melp_rule.R"))
source(file.path(.script_dir, "R", "scenarios.R"))

# The shipped settings, read from the engine's own config rather than repeated,
# so a changed threshold shows up here as a moved branch instead of silently
# disagreeing with the build.
cfg_rows <- utils::read.csv(file.path(LOT_ROOT, "config.csv"),
                            stringsAsFactors = FALSE, comment.char = "#")
setting <- function(nm, default) {
  v <- cfg_rows[[2]][trimws(cfg_rows[[1]]) == nm]
  if (!length(v) || !nzchar(trimws(v[1]))) default else as.integer(trimws(v[1]))
}
CFG <- list(apply_melp_rule    = "as_asked",
            melp_med_abbr      = "MELP",
            melp_exposure_days = setting("MELP_EXPOSURE_DAYS", 30L),
            melp_restart_days  = setting("MELP_RESTART_DAYS",  60L),
            melp_advance_days  = setting("MELP_ADVANCE_DAYS", 180L),
            melp_sct_days      = setting("MELP_SCT_DAYS",      14L))

fmt <- function(v) if (!length(v)) "none" else paste(v, collapse = ", ")

cat("\n", strrep("=", 74), "\n", sep = "")
cat("  THE STUDY TEAM'S MELPHALAN SCENARIOS, RUN THROUGH THE SHIPPED RULE\n")
cat(strrep("=", 74), "\n", sep = "")
cat("\n  Settings, from the engine's config.csv:\n")
cat(sprintf("    one administration    doses < %d days apart\n", CFG$melp_exposure_days))
cat(sprintf("    B.1 boundary          a next exposure < %d days\n", CFG$melp_restart_days))
cat(sprintf("    advancing gap         a next exposure >= %d days\n", CFG$melp_advance_days))
cat("\n  Day 0 is the start of the line the melphalan falls in. The branch and\n")
cat("  the decision are lifted from the SQL the build runs, not restated.\n")

fails <- 0L
ALL <- c(MELP_SCENARIOS, MELP_WINDOW_CASES)
for (sc in ALL) {
  if (identical(sc$id, MELP_WINDOW_CASES[[1]]$id)) {
    cat("\n", strrep("=", 74), "\n", sep = "")
    cat("  AND THE SAME DOSES ON A LINE WITH A DIFFERENT INDUCTION WINDOW\n")
    cat(strrep("=", 74), "\n", sep = "")
    cat("\n  Not the study team's drawings. \"Inside induction\" is the line's\n")
    cat("  own window - 45 days on a CAR-T-started line, 30 on a drug-started\n")
    cat("  one - so the same pair of doses is a different branch on each.\n")
  }
  r <- melp_scenario_run(CFG, sc)
  agrees <- identical(as.numeric(r$starts), as.numeric(sc$starts))
  if (!agrees) fails <- fails + 1L

  cat("\n", strrep("-", 74), "\n", sep = "")
  cat(sprintf("  %s\n", toupper(gsub("_", " ", sc$id))))
  cat(sprintf("  %s\n", sc$what))
  cat(sprintf("\n  MELP doses (day)      %s\n", fmt(sc$doses)))
  cat(sprintf("  induction ends        day %d\n", sc$induction_end))
  cat(sprintf("  exposures             %s%s\n", fmt(r$rows$EXPO_DT),
              if (length(sc$doses) != nrow(r$rows))
                sprintf("   (%d doses merged)", length(sc$doses) - nrow(r$rows)) else ""))
  cat("\n     exposure   next    gap   inside   branch   the rule\n")
  cat("     ", strrep("-", 62), "\n", sep = "")
  for (i in seq_len(nrow(r$rows))) {
    row <- r$rows[i, ]
    act <- if (row$EXPO_DT %in% r$suppress && row$EXPO_DT %in% r$inject) "removed, then added"
           else if (row$EXPO_DT %in% r$suppress) "boundary removed"
           else if (row$EXPO_DT %in% r$inject)   "boundary added"
           else "left to the engine"
    cat(sprintf("     %8s %6s %6s %8s   %-8s %s\n",
                row$EXPO_DT,
                if (is.na(row$NEXT_DT)) "-" else row$NEXT_DT,
                if (is.na(row$GAP)) "-" else row$GAP,
                if (row$INSIDE == 1L) "yes" else "no",
                melp_branch(row, CFG), act))
  }
  cat(sprintf("\n  melphalan in the regimen   %s\n",
              if (r$in_regimen) "yes - a repeat extends the line" else "no"))
  cat(sprintf("  without the rule           %s\n", fmt(r$starts_off)))
  cat(sprintf("  new line at                %s\n", fmt(r$starts)))
  add <- setdiff(r$starts, r$starts_off)
  rem <- setdiff(r$starts_off, r$starts)
  cat(sprintf("  so melphalan               %s\n",
      if (!length(add) && !length(rem)) "changes nothing - the same lines either way"
      else paste(c(if (length(rem)) paste0("no longer advances at ", fmt(rem)),
                   if (length(add)) paste0("advances at ", fmt(add))),
                 collapse = ", and ")))
  cat(sprintf("  the study team's drawing   %s\n", sc$drawn))
  cat(sprintf("  %s\n", if (agrees) "  AGREES" else "  *** DISAGREES ***"))
}

cat("\n", strrep("=", 74), "\n", sep = "")
cat(sprintf("  %d of %d cases land where the branch table puts them\n",
            length(ALL) - fails, length(ALL)))
cat(sprintf("  (%d of them are the study team's worked drawings)\n",
            length(MELP_SCENARIOS)))
# In the shape every other suite reports, so the merge gate can read this one
# too. It is a check the study README advertises, and a check nothing runs is
# a check in name only.
cat(sprintf("  %d passed, %d failed\n", length(ALL) - fails, fails))
cat(strrep("=", 74), "\n", sep = "")
cat("\n  What this does and does not say. The branch and the boundary are the\n")
cat("  build's own, lifted from its SQL. Where a boundary is left to the\n")
cat("  engine, what the engine then does is modelled here from the recorded\n")
cat("  behaviour rather than run - so an agreement says the branches line up,\n")
cat("  not that a warehouse run reproduces the drawing.\n")
cat("\n  Still open, and not decided by any of these: whether the rule is\n")
cat("  melphalan alone or any conditioning agent, what happens when the\n")
cat("  transplant procedure code is on the same event, and whether B.2 should\n")
cat("  hold the line open to the second dose. No scenario carries a coded\n")
cat("  transplant, and in every one the base regimen still covers.\n")
cat("\n  One more, and it is in the code rather than the scope: under the\n")
cat("  optional yield_to_sct mode, a boundary falling on the LATER dose is\n")
cat("  suppressed when the FIRST dose sat beside a transplant, even with no\n")
cat("  transplant at the later one. Whether that is right turns on whether a\n")
cat("  conditioning dose still starts the 180-day clock. Because no scenario\n")
cat("  here carries a transplant, none of them can tell the two readings\n")
cat("  apart - see the note in engine/R/melp_rule.R.\n\n")

if (fails > 0L) quit(status = 1L)
