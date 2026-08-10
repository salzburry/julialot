#!/usr/bin/env Rscript
# Remove steroid rows from the production MMA rollup.
#
#   Rscript "lot/tools/remove_steroids_from_rollup.R"            # report only
#   Rscript "lot/tools/remove_steroids_from_rollup.R" --write    # make the edit
#
# Steroid codes live in their own file, so the rollup should not list them
# too. Reports by default. --write makes a checked copy, keeps a backup, and
# renames it into place.
#
# It refuses rather than guesses: the premise is checked against
# cl_mma_codelist.csv, and both md5s are re-checked before the rename. Kept
# rows go back byte for byte.

argv     <- commandArgs(trailingOnly = TRUE)
do_write <- "--write" %in% argv
unknown  <- setdiff(argv, "--write")
if (length(unknown))
  stop("Unknown argument(s): ", paste(unknown, collapse = ", "),
       ". Only --write is understood.", call. = FALSE)

dir       <- Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist")
path      <- file.path(dir, "cl_mma_rollup.csv")
code_path <- file.path(dir, "cl_mma_codelist.csv")

# 01_codelists.R stops the build below this many rollup medications. The tests
# check the two agree.
MIN_ROLLUP_MEDS <- 20L

say <- function(...) cat(..., "\n", sep = "")
col <- function(df, name) {
  i <- grep(paste0("^", name, "$"), names(df), ignore.case = TRUE)
  if (!length(i)) NULL else df[[i[1]]]
}

if (!file.exists(path)) stop("No rollup at ", path, call. = FALSE)
md5_before <- unname(tools::md5sum(path))
say("File : ", path)
say("md5  : ", md5_before)

# Whole lines, newline included, so a kept row goes back out unchanged.
bytes  <- readBin(path, "raw", file.size(path))
nl     <- which(bytes == as.raw(0x0A))
starts <- c(1L, nl + 1L)
ends   <- c(nl, length(bytes))
ok_ln  <- starts <= ends
lines_raw <- Map(function(a, b) bytes[a:b], starts[ok_ln], ends[ok_ln])

df <- read.csv(path, stringsAsFactors = FALSE, colClasses = "character",
               check.names = FALSE)

# Row i of the frame is line i+1 of the file, unless a field holds a newline.
# Stop if the counts disagree - otherwise we delete the wrong lines.
if (nrow(df) != length(lines_raw) - 1L)
  stop("This file has ", nrow(df), " rows but ", length(lines_raw) - 1L,
       " data lines - a field probably contains a newline. Edit it by hand.",
       call. = FALSE)

cls <- col(df, "CL_MED_CLASS")
abb <- col(df, "CL_MED_ABBR")
if (is.null(cls) || is.null(abb))
  stop("Expected CL_MED_CLASS and CL_MED_ABBR; found: ",
       paste(names(df), collapse = ", "), call. = FALSE)

is_steroid <- toupper(trimws(cls)) == "STEROID"
say("Rows : ", nrow(df), " total, ", sum(is_steroid), " steroid")

if (!any(is_steroid)) {
  say("Nothing to do - the rollup already has no steroid rows.")
  quit(status = 0L)
}
gone <- sort(unique(toupper(trimws(abb[is_steroid]))))
say("Removing: ", paste(gone, collapse = ", "))

# Check the premise, don't assume it. If the code list does carry codes for one
# of these, dropping its rollup row changes who counts as treated: claims would
# still pull the drug in, now with no class and no flags.
if (!file.exists(code_path))
  stop("Cannot verify the premise: no code list at ", code_path,
       ". These rows are only safe to remove because a steroid has no codes.",
       call. = FALSE)
code_md5_before <- unname(tools::md5sum(code_path))
cdf <- read.csv(code_path, stringsAsFactors = FALSE, colClasses = "character",
                check.names = FALSE)
c_abb <- col(cdf, "CL_MED_ABBR")
c_cls <- col(cdf, "CL_MED_CLASS")
# Both columns. The claim is that the code list holds no steroids, and the
# class column is the only way to show it.
missing <- c("CL_MED_ABBR", "CL_MED_CLASS")[c(is.null(c_abb), is.null(c_cls))]
if (length(missing))
  stop(code_path, " has no ", paste(missing, collapse = " or "),
       "; the premise cannot be verified without it.", call. = FALSE)
coded <- intersect(gone, toupper(trimws(c_abb)))
if (length(coded))
  stop("The code list carries codes for ", paste(coded, collapse = ", "),
       ". Removing those rollup rows would leave a medication that claims ",
       "still extract with no class or flags. Fix the code list first.",
       call. = FALSE)
n_st <- sum(toupper(trimws(c_cls)) == "STEROID")
if (n_st > 0)
  stop("The code list has ", n_st, " row(s) classed STEROID. Steroids are ",
       "supposed to live in a separate file; resolve that before editing ",
       "the rollup.", call. = FALSE)
say("Premise: none of these appear in cl_mma_codelist.csv, and it has no")
say("         STEROID rows of its own.")
say("         md5 ", code_md5_before)

# The build refuses a short rollup. Say so now, not on the next run.
kept_meds <- length(unique(toupper(trimws(abb[!is_steroid]))))
say("Meds : ", kept_meds, " distinct medications would remain (minimum ",
    MIN_ROLLUP_MEDS, ")")
if (kept_meds < MIN_ROLLUP_MEDS)
  stop("That is below the minimum 01_codelists.R enforces, so the build would ",
       "stop on the result. Not editing.", call. = FALSE)

# A kept row may still name a removed steroid as its dual-maintenance partner.
# Harmless: that rule needs both drugs to be induction meds and a steroid never
# is. Say so anyway, because it looks like a dangling reference.
dual <- col(df, "DUALMAINTENANCEWITH")
if (!is.null(dual)) {
  refs <- vapply(dual[!is_steroid], function(v) {
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

keep <- c(TRUE, !is_steroid)
bak  <- paste0(path, ".bak.", format(Sys.time(), "%Y%m%d%H%M%S"))
if (!file.copy(path, bak)) stop("Could not write a backup at ", bak, call. = FALSE)
say("Backup: ", bak)

# Same folder, so the rename stays on one filesystem and is atomic. The file
# is either the old one or the new one, never half-written.
tmp <- paste0(path, ".tmp.", Sys.getpid())
on.exit(if (file.exists(tmp)) unlink(tmp), add = TRUE)
writeBin(unlist(lines_raw[keep]), tmp)

# The rename swaps the inode, so the new file would keep the temp file's mode
# from umask. On a shared file that quietly drops group write. Mode bits only -
# we cannot restore the owner, and ACLs are not visible here.
mode <- file.info(path)$mode
if (!is.na(mode)) Sys.chmod(tmp, mode, use_umask = FALSE)

# Kept bytes are unchanged bytes, so the sizes must add up exactly.
dropped <- sum(lengths(lines_raw[!keep]))
if (file.size(tmp) != file.size(path) - dropped)
  stop("The new file is ", file.size(tmp), " bytes, expected ",
       file.size(path) - dropped, ". Not replacing anything.", call. = FALSE)

chk <- read.csv(tmp, stringsAsFactors = FALSE, colClasses = "character",
                check.names = FALSE)
left <- sum(toupper(trimws(col(chk, "CL_MED_CLASS"))) == "STEROID")
if (left > 0 || nrow(chk) != sum(!is_steroid))
  stop("Verification failed (", nrow(chk), " rows, ", left,
       " steroid). Nothing was replaced.", call. = FALSE)

# Someone may have written to either file while this ran. Replacing now would
# discard their edit, or act on a premise that has stopped being true.
if (!identical(unname(tools::md5sum(path)), md5_before))
  stop("The rollup changed while this was running (md5 is no longer ",
       md5_before, "). Nothing was replaced - re-run and look at the diff.",
       call. = FALSE)
if (!identical(unname(tools::md5sum(code_path)), code_md5_before))
  stop("The code list changed while this was running (md5 is no longer ",
       code_md5_before, "), so the premise checked above may no longer hold. ",
       "Nothing was replaced - re-run.", call. = FALSE)

if (!file.rename(tmp, path))
  stop("Could not replace ", path, ". The original is untouched.", call. = FALSE)

say("Wrote: ", nrow(chk), " rows, 0 steroid")
say("md5  : ", unname(tools::md5sum(path)), "  (record this with the run)")
say("")
say("The SQL filter in the LOT build stays as a defensive guard. With the file")
say("corrected it now removes nothing, and uncoded_meds can once again show a")
say("real disagreement between the rollup and the code list.")
