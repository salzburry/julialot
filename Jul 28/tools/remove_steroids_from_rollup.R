#!/usr/bin/env Rscript
# Remove steroid rows from the production MMA rollup.
#
#   Rscript "Jul 28/tools/remove_steroids_from_rollup.R"            # report only
#   Rscript "Jul 28/tools/remove_steroids_from_rollup.R" --write    # make the edit
#
# Steroid codes are maintained in a separate file, so the rollup should not
# list them either. Report only by default; --write builds a checked
# replacement beside the original, keeps a backup, and renames it into place.
#
# It refuses rather than guesses: the premise is verified against
# cl_mma_codelist.csv, and both files' md5s are re-checked before the rename.
# Kept rows go back byte for byte. Jul 28/lot/README.md has the reasoning, and
# Jul 28/tools/tests/ has the checks.

argv     <- commandArgs(trailingOnly = TRUE)
do_write <- "--write" %in% argv
unknown  <- setdiff(argv, "--write")
if (length(unknown))
  stop("Unknown argument(s): ", paste(unknown, collapse = ", "),
       ". Only --write is understood.", call. = FALSE)

dir       <- Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist")
path      <- file.path(dir, "cl_mma_rollup.csv")
code_path <- file.path(dir, "cl_mma_codelist.csv")

# 01_codelists.R stops the build below this many distinct rollup medications.
# Keep the two in step; the tests check that they agree.
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

# Whole lines, terminator included, so the bytes of a kept row are the bytes
# that go back out. A file ending in a newline has no empty line after it.
bytes  <- readBin(path, "raw", file.size(path))
nl     <- which(bytes == as.raw(0x0A))
starts <- c(1L, nl + 1L)
ends   <- c(nl, length(bytes))
ok_ln  <- starts <= ends
lines_raw <- Map(function(a, b) bytes[a:b], starts[ok_ln], ends[ok_ln])

df <- read.csv(path, stringsAsFactors = FALSE, colClasses = "character",
               check.names = FALSE)

# Row i of the frame is line i+1 of the file. That only holds when no field
# contains a newline; if it does not hold, stop rather than delete the wrong
# lines.
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

# The premise, checked rather than asserted. If the code list does carry codes
# for one of these, deleting its rollup row DOES change who counts as treated:
# the medication would still be extracted from claims and would then have no
# class, no maintenance flag and no conditioning flag.
if (!file.exists(code_path))
  stop("Cannot verify the premise: no code list at ", code_path,
       ". These rows are only safe to remove because a steroid has no codes.",
       call. = FALSE)
code_md5_before <- unname(tools::md5sum(code_path))
cdf <- read.csv(code_path, stringsAsFactors = FALSE, colClasses = "character",
                check.names = FALSE)
c_abb <- col(cdf, "CL_MED_ABBR")
c_cls <- col(cdf, "CL_MED_CLASS")
# Both, not just the abbreviation. The claim below is that the code list has no
# steroids, and that cannot be shown without the class column - and 01_codelists
# requires it of this same file anyway, so a code list without it would not
# build.
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

# The build refuses to run on a short rollup, so say now whether this edit
# would produce one rather than discovering it on the next run.
kept_meds <- length(unique(toupper(trimws(abb[!is_steroid]))))
say("Meds : ", kept_meds, " distinct medications would remain (minimum ",
    MIN_ROLLUP_MEDS, ")")
if (kept_meds < MIN_ROLLUP_MEDS)
  stop("That is below the minimum 01_codelists.R enforces, so the build would ",
       "stop on the result. Not editing.", call. = FALSE)

# A surviving row may still name a steroid as its dual-maintenance partner.
# That is harmless - the dual-maintenance rule needs BOTH drugs to be induction
# meds, and a steroid has no codes so it can never be one - but say so, because
# it looks like a dangling reference on inspection.
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

# Beside the original, so the rename below stays on one filesystem and is
# therefore atomic: the file is either the old one or the new one, never a
# half-written one, whatever happens to this process.
tmp <- paste0(path, ".tmp.", Sys.getpid())
on.exit(if (file.exists(tmp)) unlink(tmp), add = TRUE)
writeBin(unlist(lines_raw[keep]), tmp)

# The rename replaces the inode, so the new file keeps the temporary file's
# mode - umask, not the original's. On a shared file that quietly withdraws
# group write. Only the mode bits: as an ordinary user this cannot restore the
# owner, and POSIX ACLs beyond the mode are not visible here, so check those on
# the server if the directory uses them.
mode <- file.info(path)$mode
if (!is.na(mode)) Sys.chmod(tmp, mode, use_umask = FALSE)

# The kept bytes are the original's bytes, so the sizes have to add up exactly.
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

# Someone else may have written to either file while this ran. Replacing the
# rollup now would discard an edit to it - or act on a premise that has since
# stopped being true, if the code list gained codes for a medication about to
# be removed.
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
