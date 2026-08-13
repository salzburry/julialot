#!/usr/bin/env Rscript
# The LOT contracts answer to the engine, and something has to run them.
#
#   Rscript validation/hygiene/lot_contract_binding.R
#
# The lot-contracts skill holds one file per tumor: the governed rule set that
# makes the engine portable. multiple_myeloma.yaml is special - it IS the
# engine's shipped behavior, so it is pinned to build_lot.R's CONTRACT and the
# two cannot drift apart.
#
# Except that they did. The pin was a hand-written copy of the values the engine
# was believed to ship, and a copy cannot notice the original moving: three
# settings were added to CONTRACT - apply_cart_induction_rule,
# apply_no_belantamab, lot_discon_confirm_days - and the contract went on
# validating clean, because nothing in it had ever read build_lot.R. Worse,
# nothing ran the validator either: it was not in this gate, so even a live pin
# would have sat there unexecuted.
#
# Both halves are fixed, and this suite is the second half. It lives here rather
# than inside the study folder for the reason the port suites do: it is a check
# ON the deliverable, comparing it against a specification that sits outside it.
#
# It shells out rather than sourcing, because the validator is a standalone
# base-R script that runs on its own anywhere - that portability is the point of
# it, and sourcing its internals here would quietly make this gate its only
# caller.

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
REPO  <- dirname(dirname(HERE))
SKILL <- file.path(REPO, ".claude", "skills", "lot-contracts")
VALIDATOR <- file.path(SKILL, "scripts", "validate_contracts.R")

if (!file.exists(VALIDATOR)) {
  cat("SKIP: the lot-contracts skill is not installed beside this repository.\n")
  quit(status = 3L)
}

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}

run <- function(...) {
  out <- suppressWarnings(system2("Rscript", c(shQuote(VALIDATOR), ...),
                                  stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status"); if (is.null(st)) st <- 0L
  list(out = paste(out, collapse = "\n"), status = st)
}

cat("\n-- every contract validates against the engine as it stands --\n")
v <- run()
ok(v$status == 0L,
   if (v$status == 0L) "the contracts and the engine agree"
   else paste0("the validator refused them:\n", v$out))
ok(grepl("multiple_myeloma", v$out, fixed = TRUE),
   "...and the myeloma baseline is among the files it read")

cat("\n-- and the checks can fail, which is what makes the green mean something --\n")
s <- run("--selftest")
ok(s$status == 0L,
   if (s$status == 0L) "every planted violation was caught"
   else paste0("a planted violation went uncaught:\n", s$out))
# Named individually: these two are the ones whose absence let the engine drift.
ok(grepl("an axis the engine gained and the contract lacks is refused",
         s$out, fixed = TRUE),
   "...including an engine axis the contract does not carry")
ok(grepl("an engine setting bound to nothing is refused", s$out, fixed = TRUE),
   "...and an engine setting no binding accounts for")

cat("\n-- the pin reads the engine rather than restating it --\n")
src <- readLines(VALIDATOR, warn = FALSE)
ok(any(grepl("engine_contract", src, fixed = TRUE)),
   "the validator reads CONTRACT out of build_lot.R")
ok(any(grepl("STUDY_FOLDER", src, fixed = TRUE)),
   "...from the folder this gate is pointed at, not a hard-coded one")
# A pin that lists values inline is a copy again, however it got there.
binding <- grep("^BINDING <- list\\(", src)
notaxis <- grep("^NOT_AN_AXIS <- c\\(", src)
ok(length(binding) == 1L && length(notaxis) == 1L,
   "...and every engine setting is either bound to a field or ruled out by name")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
