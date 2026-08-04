#!/usr/bin/env Rscript
# The study folder names no other delivery.
#
#   Rscript validation/hygiene/study_folder_standalone.R
#
# Production will not take code that references another delivery, so the folder
# has to stand on its own: no sibling delivery named, no path leaving it, and no
# mention of the machinery in this directory - which exists precisely to compare
# the folder against an earlier one.
#
# That comparison is not going away. It runs from here, outside the folder,
# which is where it belongs: it is a check on the port, not part of the
# deliverable. This suite is the seam between the two, and it lives on this side
# of it for the same reason.
#
# Comments count. A comment naming a sibling folder is still a reference to it
# in a file somebody reads, and it is the way one has come back before.

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
REPO <- dirname(dirname(HERE))
FOLDER <- Sys.getenv("STUDY_FOLDER", unset = "Jul 28")
ROOT <- file.path(REPO, FOLDER)
if (!dir.exists(ROOT)) {
  cat("SKIP: no ", FOLDER, " folder beside this one.\n", sep = "")
  quit(status = 3L)
}

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}

files <- list.files(ROOT, pattern = "[.](R|md|csv|txt)$", recursive = TRUE,
                    full.names = TRUE)
rel <- sub(paste0("^", ROOT, "/"), "", files)
text <- lapply(files, readLines, warn = FALSE)
names(text) <- rel

# Every directory beside the study folder is another delivery or a working area,
# and naming any of them is the thing production refuses. Read off the disk
# rather than listed here, so a delivery added later is covered without an edit.
siblings <- setdiff(list.dirs(REPO, recursive = FALSE, full.names = FALSE), "")
siblings <- setdiff(siblings[!startsWith(siblings, ".")], c(FOLDER, "docs"))
ok(length(siblings) > 0, paste0("there are sibling folders to check against (",
                                length(siblings), ")"))

# Some sibling names are also ordinary words - "validation" is one, and this
# folder has a lot_validation package and writes validation summaries. Those are
# matched only as a path segment. A name carrying a digit or an underscore is
# distinctive enough that any mention of it is a reference, so those are matched
# bare - which is the case that matters, since a delivery is dated.
# ...and the path form needs a boundary in front of it, or "validation/" is
# found inside this folder's own lot_validation/.
distinctive <- grepl("[0-9_]", siblings)
esc <- function(s) gsub("([^A-Za-z0-9_])", "\\\\\\1", s)
hits <- unlist(lapply(names(text), function(nm) {
  ls <- text[[nm]]
  unlist(lapply(seq_along(siblings), function(k) {
    s <- siblings[k]
    pat <- if (distinctive[k]) esc(s)
           else paste0("(^|[^A-Za-z0-9_])", esc(s), "/")
    i <- grep(pat, ls, perl = TRUE)
    if (length(i)) paste0(nm, ":", min(i), "  names '", s, "'") else NULL
  }))
}))
ok(!length(hits),
   if (length(hits)) paste0("a file names another delivery: ", hits[1],
                            if (length(hits) > 1) paste0(" (+", length(hits) - 1, " more)") else "")
   else paste0("no file names any of the ", length(siblings), " sibling folders"))

# The comparison machinery is in this directory, and this directory compares the
# folder against an earlier delivery. Pointing at it from inside points at that.
ours <- c("validation/port", "validation/hygiene", "validation/run_all",
          "port suite", "port/lot", "port/ndmm", "port/overall")
hits <- unlist(lapply(names(text), function(nm) {
  i <- unlist(lapply(ours, function(o) grep(o, text[[nm]], fixed = TRUE)))
  if (length(i)) paste0(nm, ":", min(i)) else NULL
}))
ok(!length(hits),
   if (length(hits)) paste0("a file points at the comparison suites: ", hits[1])
   else "no file points at the suites in this directory")

# A path leaving the folder reaches something that is not being delivered,
# whatever it is called. Intra-folder hops are how the packages read each
# other's config, so the test is where the path lands, not that it uses "..".
path_lines <- unlist(lapply(names(text), function(nm) {
  ls <- grep("file\\.path\\(|normalizePath\\(|source\\(", text[[nm]], value = TRUE)
  ls <- grep("\\.\\.", ls, value = TRUE)
  if (length(ls)) paste0(nm, ": ", trimws(ls)) else NULL
}))
# Each package sits one level down, so a single ".." lands in the folder itself
# and two leaves it.
escapes <- grep('\\.\\..*\\.\\.|"\\.\\./\\.\\.', path_lines, value = TRUE)
ok(!length(escapes),
   if (length(escapes)) paste0("a path leaves the folder: ", escapes[1])
   else paste0("every relative path stays inside the folder (",
               length(path_lines), " checked)"))

# The folder's own name in a path is the same problem from the other side: it
# only resolves from outside, so a reader who moved the folder is broken.
hits <- unlist(lapply(names(text), function(nm) {
  i <- grep(paste0(FOLDER, "/"), text[[nm]], fixed = TRUE)
  if (length(i)) paste0(nm, ":", i[1]) else NULL
}))
ok(!length(hits),
   if (length(hits)) paste0("a file hard-codes the folder's own name: ", hits[1])
   else "no file hard-codes the folder's own name in a path")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
