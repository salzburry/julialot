#!/usr/bin/env Rscript
# Remove steroid rows from the production MMA rollup.
#
#   Rscript "Jul 28/tools/remove_steroids_from_rollup.R"            # report only
#   Rscript "Jul 28/tools/remove_steroids_from_rollup.R" --write    # make the edit
#
# Steroid codes are maintained in a separate file, so cl_mma_codelist.csv has
# none. The rollup still listing them means every run reports medications whose
# codes are deliberately absent. The LOT build filters them in SQL as well, but
# that hides the disagreement rather than fixing it - this corrects the file.
#
# Kept rows are written back byte for byte. The parser only decides WHICH lines
# to drop; it never reformats quoting, spacing or line endings, because this is
# a governed file and a reformat would obscure the real change in review.

argv    <- commandArgs(trailingOnly = TRUE)
do_write <- "--write" %in% argv
dir     <- Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist")
path    <- file.path(dir, "cl_mma_rollup.csv")

say <- function(...) cat(..., "\n", sep = "")

if (!file.exists(path)) stop("No rollup at ", path, call. = FALSE)
say("File : ", path)
say("md5  : ", unname(tools::md5sum(path)))

lines <- readLines(path, warn = FALSE)
df <- read.csv(path, stringsAsFactors = FALSE, colClasses = "character",
               check.names = FALSE)

# Row i of the frame is line i+1 of the file. That only holds when no field
# contains a newline; if it does not hold, stop rather than delete the wrong
# lines.
if (nrow(df) != length(lines) - 1L)
  stop("This file has ", nrow(df), " rows but ", length(lines) - 1L,
       " data lines - a field probably contains a newline. Edit it by hand.",
       call. = FALSE)

cls <- grep("^CL_MED_CLASS$", names(df), ignore.case = TRUE)
abb <- grep("^CL_MED_ABBR$",  names(df), ignore.case = TRUE)
if (!length(cls) || !length(abb))
  stop("Expected CL_MED_CLASS and CL_MED_ABBR; found: ",
       paste(names(df), collapse = ", "), call. = FALSE)

is_steroid <- toupper(trimws(df[[cls[1]]])) == "STEROID"
say("Rows : ", nrow(df), " total, ", sum(is_steroid), " steroid")

if (!any(is_steroid)) {
  say("Nothing to do - the rollup already has no steroid rows.")
  quit(status = 0L)
}
say("Removing: ", paste(sort(unique(trimws(df[[abb[1]]][is_steroid]))), collapse = ", "))

# A surviving row may still name a steroid as its dual-maintenance partner.
# That is harmless - the dual-maintenance rule needs BOTH drugs to be induction
# meds, and a steroid has no codes so it can never be one - but say so, because
# it looks like a dangling reference on inspection.
dual <- grep("^DUALMAINTENANCEWITH$", names(df), ignore.case = TRUE)
if (length(dual)) {
  gone <- toupper(trimws(df[[abb[1]]][is_steroid]))
  refs <- vapply(df[[dual[1]]][!is_steroid], function(v) {
    if (is.na(v) || !nzchar(trimws(v))) return(FALSE)
    any(toupper(trimws(strsplit(v, ",")[[1]])) %in% gone)
  }, logical(1), USE.NAMES = FALSE)
  if (any(refs))
    say("Note : ", sum(refs), " kept row(s) list a removed steroid as a ",
        "dual-maintenance partner. Harmless - both drugs must be induction ",
        "meds, and a steroid never is - but worth knowing.")
}

if (!do_write) {
  say("")
  say("Report only. Re-run with --write to make the edit.")
  quit(status = 0L)
}

bak <- paste0(path, ".bak.", format(Sys.time(), "%Y%m%d%H%M%S"))
if (!file.copy(path, bak)) stop("Could not write a backup at ", bak, call. = FALSE)
say("Backup: ", bak)

writeLines(lines[c(TRUE, !is_steroid)], path)

# Read it back rather than trusting the write.
chk <- read.csv(path, stringsAsFactors = FALSE, colClasses = "character",
                check.names = FALSE)
left <- sum(toupper(trimws(chk[[cls[1]]])) == "STEROID")
if (left > 0 || nrow(chk) != sum(!is_steroid)) {
  file.copy(bak, path, overwrite = TRUE)
  stop("Verification failed (", nrow(chk), " rows, ", left,
       " steroid). Restored from the backup.", call. = FALSE)
}
say("Wrote: ", nrow(chk), " rows, 0 steroid")
say("md5  : ", unname(tools::md5sum(path)), "  (record this with the run)")
say("")
say("The SQL filter in the LOT build stays as a defensive guard. With the file")
say("corrected it now removes nothing, and uncoded_meds can once again show a")
say("real disagreement between the rollup and the code list.")
