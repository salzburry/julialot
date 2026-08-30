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
# folder has a lot/validation package and writes validation summaries. Those are
# matched only as a path segment. A name carrying a digit or an underscore is
# distinctive enough that any mention of it is a reference, so those are matched
# bare - which is the case that matters, since a delivery is dated.
#
# One of those names is now also one of this folder's own packages:
# lot/validation/ is not the delivery beside it. What separates the two is not
# the character in front of the match - excusing everything after a "/" would
# excuse "./validation/" and an absolute path just as readily - but whether the
# path the match sits in resolves inside this folder. So the boundary stays as
# loose as it was, and a hit is dropped only when it is demonstrably ours.
distinctive <- grepl("[0-9_]", siblings)
esc <- function(s) gsub("([^A-Za-z0-9_])", "\\\\\\1", s)
# Resolved against the folder, so ".." disqualifies a token however it resolves
# on this disk: a path that hops out and back is reaching outside by any
# reading, and an absolute path was never ours to begin with.
inside <- function(tok)
  !startsWith(tok, "/") &&
  !any(strsplit(tok, "/", fixed = TRUE)[[1]] == "..") &&
  file.exists(file.path(ROOT, tok))
ours_own <- function(line, s) {
  toks <- regmatches(line, gregexpr("[A-Za-z0-9_.~/-]+", line))[[1]]
  toks <- grep(paste0("(^|/)", esc(s), "/"), toks, value = TRUE)
  length(toks) > 0L && all(vapply(toks, inside, logical(1)))
}
hits <- unlist(lapply(names(text), function(nm) {
  ls <- text[[nm]]
  unlist(lapply(seq_along(siblings), function(k) {
    s <- siblings[k]
    pat <- if (distinctive[k]) esc(s)
           else paste0("(^|[^A-Za-z0-9_])", esc(s), "/")
    i <- grep(pat, ls, perl = TRUE)
    if (!distinctive[k] && length(i))
      i <- i[!vapply(ls[i], ours_own, logical(1), s = s)]
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
# How many hops a file can afford is how deep its PACKAGE sits, which is not how
# deep the file sits. A file under R/ or tests/ is sourced, and builds its paths
# from the package root it is handed rather than from its own directory - so
# counting its own depth would hand a step file two hops it could never
# legitimately spend, and one of those leaves the folder. Counted per file
# rather than assumed at one flat level, because the packages stopped sitting at
# one when the LOT ones moved under lot/: lot/qc/ is two directories down, so
# two hops land on the folder itself and a third leaves it.
hops <- function(l) {
  # A parent hop is ".." exactly; R's own "..." is three dots and not a path.
  m <- gregexpr("(?<!\\.)\\.\\.(?!\\.)", l, perl = TRUE)[[1]]
  if (m[1] == -1L) 0L else length(m)
}
pkg_depth <- function(nm) {
  seg <- strsplit(nm, "/", fixed = TRUE)[[1]]
  d <- length(seg) - 1L
  while (d > 0L && seg[d] %in% c("R", "steps", "tests")) d <- d - 1L
  d
}
checked <- 0L
escapes <- unlist(lapply(names(text), function(nm) {
  depth <- pkg_depth(nm)
  ls <- grep("file\\.path\\(|normalizePath\\(|source\\(", text[[nm]], value = TRUE)
  ls <- grep("\\.\\.", ls, value = TRUE)
  checked <<- checked + length(ls)
  ls <- ls[vapply(ls, hops, integer(1)) > depth]
  if (length(ls)) paste0(nm, ": ", trimws(ls)) else NULL
}))
ok(!length(escapes),
   if (length(escapes)) paste0("a path leaves the folder: ", escapes[1])
   else paste0("every relative path stays inside the folder (",
               checked, " checked)"))

# The folder's own name in a path is the same problem from the other side: it
# only resolves from outside, so a reader who moved the folder is broken.
hits <- unlist(lapply(names(text), function(nm) {
  i <- grep(paste0(FOLDER, "/"), text[[nm]], fixed = TRUE)
  if (length(i)) paste0(nm, ":", i[1]) else NULL
}))
ok(!length(hits),
   if (length(hits)) paste0("a file hard-codes the folder's own name: ", hits[1])
   else "no file hard-codes the folder's own name in a path")

# A source() that reaches ACROSS packages has to resolve to a file that is
# there. Nothing checked this, and it cost: moving the melphalan package from
# exploration/ to lot/ left run_foldin_cells.R sourcing a path that no longer
# existed. That script needs a warehouse, so no suite runs it and the gate
# stayed green over a file that could not load.
#
# Only the `file.path(.script_dir, ...)` form, and only where every other part
# is a string literal. That is the one form whose base is known without running
# the file - .script_dir is the script's own directory everywhere in this
# folder - and it is the form a package move breaks. Paths built from a
# package-root variable (ROOT, LOT_ROOT) resolve against something this cannot
# know, and a same-package source() does not survive a move to begin with.
srcs <- unlist(lapply(names(text), function(nm) {
  hits <- grep("source(file.path(.script_dir", text[[nm]], fixed = TRUE, value = TRUE)
  unlist(lapply(hits, function(l) {
    m <- regmatches(l, regexpr("file\\.path\\([^)]*\\)", l))
    if (!length(m)) return(NULL)
    parts <- trimws(strsplit(sub("^file\\.path\\(", "", sub("\\)$", "", m)), ",")[[1]])
    if (!identical(parts[1], ".script_dir")) return(NULL)
    rest <- parts[-1]
    if (!length(rest) || !all(grepl('^".*"$', rest))) return(NULL)
    rel  <- do.call(file.path, as.list(gsub('"', "", rest)))
    if (file.exists(file.path(dirname(file.path(ROOT, nm)), rel))) NULL
    else paste0(nm, " -> ", rel)
  }))
}))
ok(!length(srcs),
   if (length(srcs)) paste0("sources a file that is not there: ",
                            paste(srcs, collapse = "; "))
   else "every cross-package source() path resolves to a file that exists")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
