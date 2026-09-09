#!/usr/bin/env Rscript
# Checks on the edge-case vignette catalogue.
#
# The catalogue's whole claim is that it cannot drift from the algorithm. These
# are the checks that make that true rather than aspirational: the parameters
# have to exist, the offsets have to move when a setting moves, the files the
# rules are quoted from have to be there, and a boundary that stops being a
# boundary has to fail.
#
#   Rscript "lot/validation/tests/test_vignettes.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
# The LOT group this package sits in, and the study folder above it. Both are
# resolved from this file rather than named, so either can be renamed. The
# catalogue cites source locations from the study root - one frame that reaches
# the engine and the cohort builds alike - so a citation resolves against STUDY,
# while this package's own reads of the engine go through PARENT.
PARENT <- dirname(ROOT)
STUDY  <- dirname(PARENT)

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  # `cond` is evaluated HERE, not by the caller, so an assertion whose
  # expression raises is a FAILED assertion rather than a dead run. It used to
  # propagate: a mutation that made qc_outcome() stop took the whole suite
  # down, printing no count and losing every result after it.
  cond <- tryCatch(cond, error = function(e) {
    what <<- paste0(what, "  [raised: ", conditionMessage(e), "]")
    FALSE
  })
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
runs  <- function(expr, what) ok(is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)
stops <- function(expr, what) ok(!is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)

source(file.path(ROOT, "R", "vignettes.R"))

# The settings the engine carries, read the way the build reads them.
P <- local({
  lot_root <- file.path(PARENT, "engine")
  e <- new.env(parent = globalenv())
  sys.source(file.path(lot_root, "R", "load_inputs.R"), envir = e)
  e$load_pipeline_inputs(lot_root, "config.csv")
  sys.source(file.path(lot_root, "R", "config_lot.R"), envir = e)
  cfg <- get("cfg_defaults", envir = e)
  p <- cfg[names(VIGNETTE_PARAMS)]; names(p) <- names(VIGNETTE_PARAMS)
  lapply(p, function(v) as.integer(v)[1])
})

cat("\n-- the catalogue holds against the settings that ship --\n")
runs(check_vignettes(P), "every vignette resolves and every boundary straddles")
ok(length(VIGNETTES) >= 15,
   paste0("there is a catalogue to check (", length(VIGNETTES), " vignettes)"))
df <- render_vignettes(P)
ok(nrow(df) == length(VIGNETTES) && !anyNA(df$expected),
   "...and every one renders an expected outcome")
# The idea named these cases specifically. A catalogue that quietly drops one
# is a catalogue that answers a different question.
for (want in c("tandem", "cart_bridge", "biosimilar", "maintenance",
               "overlapping_oral_refills", "map_gap", "allo_after_failed_auto"))
  ok(any(grepl(want, df$id, fixed = TRUE)),
     paste0("...including the '", want, "' case that was asked for"))

cat("\n-- it moves when a setting moves, which is the point --\n")
# Hardcoding "day 181" is what makes a catalogue rot. Every offset is derived,
# so a changed parameter has to move the timeline with it.
P2 <- modifyList(P, list(sct_tandem_days = 365L))
d1 <- render_vignettes(P)[render_vignettes(P)$id == "tandem_beyond", "timeline"]
d2 <- render_vignettes(P2)[render_vignettes(P2)$id == "tandem_beyond", "timeline"]
ok(!identical(d1, d2) && grepl("d+396", d2, fixed = TRUE),
   "doubling the tandem window moves the tandem vignette's timeline")
runs(check_vignettes(P2), "...and the catalogue still holds at the new value")
ok(grepl("365", render_vignettes(P2)[render_vignettes(P2)$id == "tandem_within",
                                     "parameter"], fixed = TRUE),
   "...with the parameter printed beside the case, so the reader sees which value applied")

cat("\n-- and fails rather than describing a rule that is gone --\n")
# A renamed setting is the failure this is built to catch: the prose would
# still read fine while naming a setting the build does not have.
stops(check_vignettes(modifyList(P, list(sct_tandem_days = NA_integer_))),
      "a parameter missing from the config stops the catalogue")
bogus <- c(VIGNETTES, list(list(id = "x", title = "x", param = "no_such_setting",
                                confidence = "derived", where = "nowhere",
                                events = function(p) ev(0, "MED"),
                                expected = function(p) "x", why = "x")))
stops(check_vignettes(P, bogus), "...and so does a vignette naming a setting that does not exist")
dup <- c(VIGNETTES, VIGNETTES[1])
stops(check_vignettes(P, dup), "...and a duplicate id")
# A boundary where both sides expect the same thing tests nothing.
same <- lapply(VIGNETTES, function(x) {
  if (identical(x$id, "tandem_beyond")) x$expected <- function(p)
    "The two AUTOs are one tandem pair. A tandem is allowed, so LOT1 is not ended by the second one."
  x
})
stops(check_vignettes(P, same),
      "...and a boundary whose two sides agree, which would be testing nothing")
notime <- lapply(VIGNETTES, function(x) {
  if (identical(x$id, "allo_single_day"))
    x$events <- function(p) rbind(ev(10, "MED"), ev(2, "ALLO"))
  x
})
stops(check_vignettes(P, notime), "...and a timeline that runs backwards")

cat("\n-- every rule it quotes is somewhere a reader can go --\n")
# A citation is "path | anchor", and the anchor is a literal that has to appear
# in that file. It used to be "path:line", and line numbers do not survive
# editing: twelve of the fourteen pointed at whatever had drifted into their
# slot, and nothing here noticed because only the FILE was checked. An anchor
# moves with the code it names, and when the code goes the citation fails.
missing <- character(0)
adrift  <- character(0)
for (v in VIGNETTES) {
  parts <- strsplit(v$where, " | ", fixed = TRUE)[[1]]
  f <- trimws(parts[1])
  if (!nzchar(f) || identical(f, "nowhere")) next
  path <- file.path(STUDY, f)
  if (!file.exists(path)) { missing <- c(missing, paste0(v$id, " -> ", f)); next }
  if (length(parts) < 2L) { adrift <- c(adrift, paste0(v$id, " -> no anchor")); next }
  anchor <- trimws(paste(parts[-1], collapse = " | "))
  src <- readLines(path, warn = FALSE)
  if (!any(grepl(anchor, src, fixed = TRUE)))
    adrift <- c(adrift, paste0(v$id, " -> '", anchor, "' is not in ", f))
}
ok(!length(missing),
   if (length(missing)) paste0("quotes a file that is not here: ",
                               paste(missing, collapse = "; "))
   else "every quoted rule names a file that exists")
ok(!length(adrift),
   if (length(adrift)) paste0("...and the quoted line is gone: ",
                              paste(adrift, collapse = "; "))
   else "...and the line each one quotes is still in that file")
# The two facts the catalogue leans on hardest, checked against the code rather
# than trusted: an ALLO line has no regimen, and no_belantamab is patient-level.
sct <- readLines(file.path(PARENT, "engine", "R", "steps", "10_lot2_5_base.R"), warn = FALSE)
ok(any(grepl("ALLO LOT holds no MM therapy", sct, fixed = TRUE)),
   "...and the ALLO no-regimen case the catalogue describes is really in the build")
lc <- readLines(file.path(PARENT, "engine", "R", "line_criteria.R"), warn = FALSE)
ok(any(grepl('on_fail = "truncate"', lc, fixed = TRUE)) &&
     any(grepl("Patient-level, not line-level", lc, fixed = TRUE)),
   "...and so is the patient-level belantamab truncate")

cat("\n-- what has been seen, and what has only been read --\n")
# Confidence is a claim about US, not about the algorithm. Keeping the two
# apart is what stops the catalogue reading as a set of results.
ok(all(df$confidence %in% c("derived", "to_confirm")),
   "every vignette says how far its expectation is from having been seen")
ok(sum(df$confidence == "to_confirm") > 0,
   "...and the ones that need a real run are marked rather than asserted")

cat("\n-- and the rules document cites this catalogue, not a copy of it --\n")
# LOT_RULES.md names the vignette that tests each rule, so the rules and the
# machine-checked cases live in one file rather than two that can drift apart.
#
# Checked in both directions. A renamed or deleted vignette leaves the document
# pointing at a case that does not exist, and a vignette no rule cites is a case
# nothing claims to be about.
rules <- paste(readLines(file.path(PARENT, "LOT_RULES.md"), warn = FALSE),
               collapse = "\n")
# Every backticked token in the document, which is where an id would be written.
# Read this way rather than off "vignette `x`" so a pair written `a` / `b`, or a
# reference phrased some other way, still counts as a citation.
ticked <- unique(unlist(regmatches(
  rules, gregexpr("`[A-Za-z0-9_]+`", rules))))
ticked <- gsub("`", "", ticked, fixed = TRUE)
cited  <- intersect(ticked, df$id)
ok(length(cited) > 0,
   paste0("the rules document names vignettes by id (", length(cited), ")"))
uncited <- setdiff(df$id, cited)
ok(!length(uncited),
   if (length(uncited)) paste0("...and every vignette is cited by a rule - not cited: ",
                               paste(uncited, collapse = ", "))
   else "...and every vignette here is cited by a rule, so neither side grew alone")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
