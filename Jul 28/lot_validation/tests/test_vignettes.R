#!/usr/bin/env Rscript
# Checks on the edge-case vignette catalogue.
#
# The catalogue's whole claim is that it cannot drift from the algorithm. These
# are the checks that make that true rather than aspirational: the parameters
# have to exist, the offsets have to move when a setting moves, the files the
# rules are quoted from have to be there, and a boundary that stops being a
# boundary has to fail.
#
#   Rscript "lot_validation/tests/test_vignettes.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
JUL28 <- dirname(ROOT)

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
runs  <- function(expr, what) ok(is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)
stops <- function(expr, what) ok(!is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)

source(file.path(ROOT, "R", "vignettes.R"))

# The shipped settings, read the way the build reads them.
P <- local({
  lot_root <- file.path(JUL28, "lot")
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
# still read fine while naming something the build no longer has.
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
# The quoted location is the difference between a claim and a citation. A file
# that has been renamed or removed takes the catalogue with it.
missing <- character(0)
for (v in VIGNETTES) {
  f <- sub("[: ].*$", "", v$where)
  if (!nzchar(f) || identical(f, "nowhere")) next
  if (!file.exists(file.path(JUL28, f))) missing <- c(missing, paste0(v$id, " -> ", f))
}
ok(!length(missing),
   if (length(missing)) paste0("quotes a file that is not here: ",
                               paste(missing, collapse = "; "))
   else "every quoted rule names a file that exists")
# The two facts the catalogue leans on hardest, checked against the code rather
# than trusted: an ALLO line has no regimen, and no_belantamab is patient-level.
sct <- readLines(file.path(JUL28, "lot", "R", "steps", "10_lot2_5_base.R"), warn = FALSE)
ok(any(grepl("ALLO singleton LOTs contain no MM therapies", sct, fixed = TRUE)),
   "...and the ALLO no-regimen case the catalogue describes is really in the build")
lc <- readLines(file.path(JUL28, "lot", "R", "line_criteria.R"), warn = FALSE)
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

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
