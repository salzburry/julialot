#!/usr/bin/env Rscript
# What the protocol's safety and utilisation code lists still need.
#
#   # against the templates in this folder
#   Rscript lot/safety/run_safety_codelists.R
#
#   # against the filled lists on the mounted path
#   CODELIST_DIR=/mnt/code/codelist Rscript lot/safety/run_safety_codelists.R
#
# Reads nothing but the CSVs. No warehouse, no connection.
#
# Exit status is 0 when every condition the protocol names carries at least one
# code and 1 while any is still a placeholder, so this can gate the safety
# analysis rather than letting it run on a half-filled list. A condition with no
# codes matches no claim, and its rate would come out zero - not as a finding,
# but as a missing code list wearing one.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in a path as ~+~, so a folder with one in its name
  # resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "codelists_safety.R"))

# The templates ship beside the code; the filled lists live where every other
# code list does. Default to the templates so this runs anywhere, and say which
# was read - the difference is the whole status.
DIR <- Sys.getenv("CODELIST_DIR", unset = file.path(.script_dir, "codelists"))
IS_TEMPLATE <- identical(normalizePath(DIR, mustWork = FALSE),
                         normalizePath(file.path(.script_dir, "codelists"),
                                       mustWork = FALSE))

st <- safety_fill_status(DIR)
total <- nrow(safety_roster())

cat("\n", strrep("=", 70), "\n", sep = "")
cat("  KEY SAFETY AND UTILISATION CODE LISTS\n")
cat(strrep("=", 70), "\n", sep = "")
cat("\n  read from   ", DIR, "\n", sep = "")
cat("              ", if (IS_TEMPLATE) "the templates in this folder"
                      else "the mounted code list directory", "\n", sep = "")
cat("  safety_events.csv  md5 ", st$safety_md5, "\n", sep = "")
cat("  hcru_events.csv    md5 ", st$hcru_md5, "\n", sep = "")
cat("\n  Timing for every condition below: ", SAFETY_TIMING, ".\n", sep = "")

for (d in SAFETY_DOMAINS) {
  cs <- names(SAFETY_CONDITIONS[[d]])
  cat("\n  ", toupper(d), "\n", sep = "")
  for (c_i in cs) {
    n <- st$n_codes[[c_i]]
    cat(sprintf("    %-46s %s\n", c_i,
                if (c_i %in% st$absent) "NOT IN THE FILE"
                else if (n == 0L) "no codes yet"
                else paste0(n, " code", if (n == 1L) "" else "s")))
  }
}
cat("\n  HEALTHCARE UTILISATION\n")
h <- read.csv(file.path(DIR, "hcru_events.csv"), stringsAsFactors = FALSE,
              colClasses = "character")
for (e in names(HCRU_EVENTS)) {
  n <- st$n_hcru[[e]]
  # Which fields the placeholder rows are drafted against. An event with no
  # codes is not featureless - it already says where its codes would go, and
  # that is most of the question when the value list has not arrived.
  want <- unique(h$code_type[h$event == e & nzchar(h$code_type)])
  cat(sprintf("    %-46s %s\n", e,
              if (n == 0L)
                paste0("no codes yet",
                       if (length(want))
                         paste0("  (placeholder on ", paste(want, collapse = ", "), ")")
                       else "")
              else paste0(n, " code", if (n == 1L) "" else "s")))
}

filled <- total - length(st$unfilled) - length(st$absent)
cat("\n", strrep("-", 70), "\n", sep = "")
cat(sprintf("  %d of %d conditions carry codes; %d of %d utilisation events\n",
            filled, total, length(HCRU_EVENTS) - length(st$hcru_unfilled),
            length(HCRU_EVENTS)))

# Drafted against a field that has not been confirmed queryable. Empty is fine
# and expected - that is what a placeholder is, and it is not a reason to
# refuse, so it is reported here rather than by safety_refuse().
if (length(st$drafted))
  cat("  placeholder(s) drafted on field(s) not confirmed queryable: ",
      paste(st$drafted, collapse = ", "), "\n", sep = "")

# The verdict is safety_codelist()'s, not this script's. Everything the strict
# read would refuse on is listed, in its words, and the exit status is whether
# there was anything - so this command cannot report ready on a list the
# analysis would then be unable to read. It used to decide for itself, on
# completeness alone, and would print a warning about a filled unconfirmed
# field and "Ready." two lines apart.
bad <- safety_refuse(st)
if (length(bad)) {
  cat("\n  Not ready - ", length(bad),
      if (length(bad) == 1L) " reason:\n" else " reasons:\n", sep = "")
  for (b in bad) {
    w <- strwrap(b, width = 66, prefix = "      ", initial = "    * ")
    cat(paste(w, collapse = "\n"), "\n", sep = "")
  }
  cat("\n  The codes come from the protocol's annex and the Optum\n")
  cat("  documentation; the roster of conditions is already fixed here, so\n")
  cat("  filling one is adding rows to the CSV, not deciding what to measure.\n")
  cat("  One row per code, repeating the condition name.\n\n")
  quit(status = 1L)
}
cat("\n  Ready.\n\n")
